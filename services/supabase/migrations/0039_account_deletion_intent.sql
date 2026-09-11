--0039: the deletion ownership snapshot is a transaction, not an Edge guess.
-- CLI-created scaffold uses the explicitly reserved sequential repo filename.
-- No provider call occurs here. Before journal/parent rows are purged, their
-- immutable cleanup identities MUST survive in the leased deletion intent.
alter table public.deletion_requests add column if not exists snapshot_version integer not null default 0;
alter table public.deletion_requests add column if not exists ownership_scope jsonb not null default'{}';
alter table public.deletion_requests add column if not exists cleanup_token uuid;
alter table public.deletion_requests add column if not exists cleanup_lease_until timestamptz;
alter table public.deletion_requests add column if not exists manual_review_required boolean not null default false;
alter table public.deletion_requests add column if not exists next_cleanup_at timestamptz not null default clock_timestamp();
create index if not exists deletion_work_queue on public.deletion_requests(status,requested_at)
  where not manual_review_required;
create index if not exists deletion_due_queue on public.deletion_requests(next_cleanup_at)
  where status in('pending','processing') and not manual_review_required;
-- Old instances may read existing requests, but cannot create/advance new
-- unfenced snapshots. Already-running old destructive calls still require a
-- controlled rollout drain; SQL cannot retract a provider DELETE already sent.
revoke insert,update,delete on public.deletion_requests from public,anon,authenticated,service_role;
grant select on public.deletion_requests to service_role;

create or replace function public.claim_account_deletion(p_request uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.deletion_requests%rowtype; token uuid;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required'; end if;
  select * into r from public.deletion_requests where id=p_request for update;
  if not found then raise exception 'RP404: deletion request not found'; end if;
  if r.snapshot_version<>2 or r.manual_review_required then
    -- Legacy payloads often contain bare keys but no original ownership map.
    -- Inferring ownership now could erase an adoption winner. Keep every byte
    -- for manual reconciliation; never classify the retained work as complete.
    update public.deletion_requests set status='pending',manual_review_required=true,
      last_error='Unverified legacy ownership snapshot: manual reconciliation required',cleanup_token=null,cleanup_lease_until=null
      where id=r.id;
    return jsonb_build_object('ok',false,'request_id',r.id,'manual_review_required',true);
  end if;
  if r.status='completed' then return jsonb_build_object('ok',false,'request_id',r.id,'completed',true); end if;
  if r.cleanup_lease_until>clock_timestamp() then raise exception 'RP409: deletion cleanup is already running'; end if;
  if r.ownership_scope->>'source_user_id' is distinct from r.user_id::text
     or r.ownership_scope->>'db_purged' is distinct from 'true' then
    raise exception 'RP409: deletion ownership receipt is invalid';
  end if;
  token:=gen_random_uuid();
  update public.deletion_requests set status='processing',cleanup_token=token,
    cleanup_lease_until=clock_timestamp()+interval'15 minutes',next_cleanup_at=clock_timestamp()+interval'15 minutes',
    attempts=attempts+1 where id=r.id;
  return jsonb_build_object('ok',true,'snapshot_version',2,'request_id',r.id,'source_user_id',r.user_id,
    'lease_token',token,'payload',r.payload,'scope',r.ownership_scope,
    'manual_review_required',exists(select 1 from public.deletion_requests where user_id=r.user_id and manual_review_required));
end;
$$;

create or replace function public.prepare_account_deletion(p_user uuid,p_upload_bucket text,p_render_bucket text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  all_orgs uuid[]; solo uuid[]; shared uuid[]; listing_ids uuid[]; asset_ids uuid[]; job_ids uuid[]; render_ids uuid[];
  org uuid; heir uuid; request_id uuid; old_request uuid; payload jsonb; scope jsonb; email_value text; apple_token text;
  object_targets jsonb; spatial_ids uuid[]:='{}'; spatial_keys jsonb:='[]'; provider_targets jsonb:='[]';
  multipart_targets jsonb:='[]'; unresolved_targets jsonb:='[]'; storage_after timestamptz;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required'; end if;
  if p_user is null or coalesce(length(p_upload_bucket),0) not between 3 and 63
     or coalesce(length(p_render_bucket),0) not between 3 and 63 or p_upload_bucket=p_render_bucket then
    raise exception 'RP400: invalid deletion binding';
  end if;
  -- Same mutation order as0038: Auth -> profiles -> sorted orgs. Reading
  -- memberships BEFORE these locks recreates the destructive adoption race.
  perform 1 from auth.users where id=p_user for update;
  if not found then raise exception 'RP401: account no longer exists'; end if;
  perform 1 from public.profiles where id=p_user for update;
  select id into old_request from public.deletion_requests
    where user_id=p_user and snapshot_version=2 and status in('pending','processing') and not manual_review_required
    order by requested_at limit 1;
  if old_request is not null then return public.claim_account_deletion(old_request); end if;
  select coalesce(array_agg(org_id order by org_id),'{}'::uuid[]) into all_orgs from public.memberships where user_id=p_user;
  perform 1 from public.orgs where id=any(all_orgs) order by id for update;
  -- The lock also serializes team joins. Recheck membership rather than
  -- trusting a list read before waiting for somebody else's org transaction.
  if exists(select 1 from unnest(all_orgs) x where not exists(select 1 from public.memberships where org_id=x and user_id=p_user)) then
    raise exception 'RP409: workspace ownership changed; retry deletion';
  end if;
  select coalesce(array_agg(o),'{}'::uuid[]) into solo from unnest(all_orgs) o
    where (select count(*) from public.memberships where org_id=o)=1;
  select coalesce(array_agg(o),'{}'::uuid[]) into shared from unnest(all_orgs) o where not(o=any(solo));
  -- FOR UPDATE prevents new FK children while their keys are inventoried. The
  -- upload and worker transactions also start at listing before asset/job.
  perform 1 from public.listings where org_id=any(all_orgs) order by id for update;
  select coalesce(array_agg(id),'{}'::uuid[]) into listing_ids from public.listings where org_id=any(solo);
  if cardinality(listing_ids)>10000 then raise exception 'RP413: account requires assisted deletion'; end if;
  perform 1 from public.capture_assets where listing_id=any(listing_ids) order by id for update;
  perform 1 from public.photos where listing_id=any(listing_ids) order by id for update;
  perform 1 from public.render_jobs where listing_id=any(listing_ids) order by id for update;
  perform 1 from public.renders where listing_id=any(listing_ids) order by id for update;
  select coalesce(array_agg(id),'{}'::uuid[]) into asset_ids from public.capture_assets where listing_id=any(listing_ids);
  select coalesce(array_agg(id),'{}'::uuid[]) into job_ids from public.render_jobs where listing_id=any(listing_ids);
  select coalesce(array_agg(id),'{}'::uuid[]) into render_ids from public.renders where listing_id=any(listing_ids);
  -- 0039 precedes 0040 in a fresh install. No spatial schema means no spatial
  -- data can exist; a partially installed schema is NOT an empty inventory.
  if to_regclass('public.spatial_jobs') is not null then
    if to_regclass('public.spatial_inputs') is null or to_regclass('public.spatial_attempt_history') is null then
      raise exception 'RP503: spatial cleanup schema is incomplete; nothing was deleted';
    end if;
    perform 1 from public.spatial_jobs where org_id=any(solo) order by id for update;
    select coalesce(array_agg(id),'{}'::uuid[]) into spatial_ids from public.spatial_jobs where org_id=any(solo);
    if exists(select 1 from public.spatial_jobs where id=any(spatial_ids) and not(listing_id=any(listing_ids))) then
      raise exception 'RP409: orphaned spatial ownership requires assisted deletion; nothing was deleted';
    end if;
    perform 1 from public.spatial_inputs where job_id=any(spatial_ids) order by job_id,relative_path for update;
    perform 1 from public.spatial_attempt_history where job_id=any(spatial_ids) order by job_id,attempt_key for update;
    if exists(select 1 from public.spatial_attempt_history h join public.spatial_jobs j on j.id=h.job_id
      where j.id=any(spatial_ids) and (jsonb_typeof(h.snapshot) is distinct from 'object' or
        h.snapshot->>'id' is distinct from j.id::text or h.snapshot->>'org_id' is distinct from j.org_id::text or
        h.snapshot->>'listing_id' is distinct from j.listing_id::text or
        (h.snapshot->>'started_at' is not null and h.snapshot->>'lease_token' is null))) then
      raise exception 'RP409: invalid spatial attempt history; nothing was deleted';
    end if;
    with attempts as (
      select j.id,j.org_id,j.listing_id,to_jsonb(j) snapshot from public.spatial_jobs j where j.id=any(spatial_ids)
      union all select j.id,j.org_id,j.listing_id,h.snapshot from public.spatial_attempt_history h
        join public.spatial_jobs j on j.id=h.job_id where j.id=any(spatial_ids)
    ) select coalesce(jsonb_agg(jsonb_build_object('bucket',p_upload_bucket,'key',snapshot->>'output_key',
        'valid',snapshot->>'id'=id::text and snapshot->>'org_id'=org_id::text and
          snapshot->>'listing_id'=listing_id::text and snapshot->>'artifact_revision' ~
          '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' and
          snapshot->>'output_key'='spatial/'||org_id||'/'||listing_id||'/'||id||'/'||
            (snapshot->>'artifact_revision')||'/model.sog')),'[]'::jsonb)
      into spatial_keys from attempts where snapshot->>'output_key' is not null;
    with attempts as (
      select j.id,to_jsonb(j) snapshot from public.spatial_jobs j where j.id=any(spatial_ids)
      union all select h.job_id,h.snapshot from public.spatial_attempt_history h where h.job_id=any(spatial_ids)
    ) select coalesce(jsonb_agg(distinct jsonb_build_object('job_id',id,'lease_token',snapshot->>'lease_token')),'[]'),
        max((snapshot->>'deadline_at')::timestamptz)+interval '15 minutes'
      into provider_targets,storage_after from attempts where snapshot->>'lease_token' is not null;
    -- Inputs are validated server bindings, not a caller-selected list of URLs.
    select spatial_keys||coalesce(jsonb_agg(jsonb_build_object('bucket',p_upload_bucket,'key',i.storage_key,
      'valid',starts_with(i.storage_key,'uploads/'||j.org_id||'/'||j.listing_id||'/')
        and length(i.storage_key)<=4096 and i.storage_key !~ '(^|/)[.]{1,2}(/|$)')),'[]')
      into spatial_keys from public.spatial_inputs i join public.spatial_jobs j on j.id=i.job_id where j.id=any(spatial_ids);
  end if;
  -- Journaled operations outlive their asset rows. Preserve every destination
  -- and multipart identity before removing that journal; a previously claimed
  -- write may settle AFTER this transaction. Re-delete only after its window.
  perform 1 from public.upload_reservations where org_id=any(solo) order by asset_id for update;
  if exists(select 1 from public.upload_reservations where org_id=any(solo) and not(listing_id=any(listing_ids))) then
    raise exception 'RP409: orphaned upload ownership requires assisted deletion; nothing was deleted';
  end if;
  perform 1 from public.upload_operations where asset_id in(select asset_id from public.upload_reservations where org_id=any(solo))
    order by id for update;
  if exists(select 1 from public.capture_assets where listing_id=any(listing_ids) and
    (bucket not in('uploads','renders') or not starts_with(storage_key,bucket||'/'))) or
    exists(select 1 from public.upload_operations o join public.upload_reservations r using(asset_id) where r.org_id=any(solo) and
      not(starts_with(o.object_key,o.bucket||'/') or starts_with(o.object_key,'_staging/'||o.bucket||'/'))) then
    raise exception 'RP409: storage bucket binding is invalid; nothing was deleted';
  end if;
  select greatest(storage_after,max(coalesce(o.write_deadline,o.expires_at))+interval '1 hour')
    into storage_after from public.upload_operations o join public.upload_reservations r using(asset_id) where r.org_id=any(solo);
  if exists(select 1 from public.capture_assets where listing_id=any(listing_ids) and transport_version=1) then
    storage_after:=greatest(storage_after,clock_timestamp()+interval '75 minutes');
  end if;
  with sessions as (
    select a.bucket,a.storage_key key,a.upload_id from public.capture_assets a where listing_id=any(listing_ids) and upload_id is not null
    union select o.bucket,o.object_key,o.upload_id from public.upload_operations o join public.upload_reservations r using(asset_id)
      where r.org_id=any(solo) and o.upload_id is not null
  ) select coalesce(jsonb_agg(jsonb_build_object('bucket',case bucket when 'uploads' then p_upload_bucket else p_render_bucket end,
    'key',key,'upload_id',upload_id)),'[]') into multipart_targets from sessions;
  select coalesce(jsonb_agg(jsonb_build_object('operation_id',o.id,'bucket',
    case o.bucket when 'uploads' then p_upload_bucket else p_render_bucket end,'key',o.object_key)),'[]')
    into unresolved_targets from public.upload_operations o join public.upload_reservations r using(asset_id)
    where r.org_id=any(solo) and o.kind='init' and o.upload_id is null and o.state in('dispatching','uncertain');
  if cardinality(asset_ids)+cardinality(job_ids)+cardinality(render_ids)>50000 then raise exception 'RP413: account requires assisted deletion'; end if;
  select email into email_value from auth.users where id=p_user;
  select apple_refresh_token into apple_token from public.profiles where id=p_user;
  -- A row's membership is not proof that an arbitrary string in a writable
  -- photo field is its object. Only canonical keys under THAT listing may
  -- authorize deletion; unknown legacy formats require assisted reconciliation
  -- before any destruction. Original enhanced stills live in renders, too.
  with keys as (
    select listing_id,storage_key key from public.capture_assets where listing_id=any(listing_ids)
    union select listing_id,original_key from public.photos where listing_id=any(listing_ids)
    union select listing_id,enhanced_key from public.photos where listing_id=any(listing_ids)
    union select listing_id,video_key from public.renders where listing_id=any(listing_ids)
    union select listing_id,poster_key from public.renders where listing_id=any(listing_ids)
    union select listing_id,hero_key from public.renders where listing_id=any(listing_ids)
    union select id,main_photo_key from public.listings where id=any(listing_ids)
    union select r.listing_id,o.object_key from public.upload_operations o join public.upload_reservations r using(asset_id) where r.org_id=any(solo)
    union select listing_id,'_staging/'||regexp_replace(storage_key,'-complete-[0-9a-f-]{36}([.][a-zA-Z0-9]+)$','\1')
      from public.capture_assets where listing_id=any(listing_ids) and transport_version=1 and parts_total is null
  ) select coalesce(jsonb_agg(jsonb_build_object('bucket',case when key like 'uploads/%' or key like '_staging/uploads/%' then p_upload_bucket else p_render_bucket end,
    'key',key,'valid',length(key) between 1 and 4096 and key !~ '(^|/)[.]{1,2}(/|$)' and
      (starts_with(key,'uploads/'||l.org_id||'/'||l.id||'/') or
       starts_with(key,'renders/'||l.org_id||'/'||l.id||'/') or starts_with(key,'renders/'||l.id||'/') or
       starts_with(key,'_staging/uploads/'||l.org_id||'/'||l.id||'/') or starts_with(key,'_staging/renders/'||l.org_id||'/'||l.id||'/')))), '[]'::jsonb)
    into object_targets from keys join public.listings l on l.id=keys.listing_id where key is not null;
  object_targets:=object_targets||spatial_keys;
  if exists(select 1 from jsonb_array_elements(object_targets) t where t->>'valid' is distinct from 'true') then
    raise exception 'RP409: unverified media ownership requires assisted deletion; nothing was deleted';
  end if;
  select jsonb_build_object(
    'r2',coalesce((select jsonb_agg(distinct t-'valid') from jsonb_array_elements(object_targets) t),'[]'::jsonb),
    'stream_uids',coalesce((select jsonb_agg(distinct stream_uid) from public.renders where listing_id=any(listing_ids) and stream_uid is not null),'[]'::jsonb),
    'ghl_targets',coalesce((select jsonb_agg(jsonb_build_object('email',email,'org_id',org_id)) from(
      select distinct lower(email) email,org_id from public.leads where org_id=any(solo) and email is not null
    ) targets),'[]'::jsonb),
    'apple_refresh_token',apple_token,'analytics_user_id',p_user,'profile_id',p_user,'auth_user_id',p_user
    ,'provider_leases',provider_targets,'multipart_uploads',multipart_targets,'unresolved_uploads',unresolved_targets,
    'storage_not_before',storage_after,'unresolved_render_jobs',coalesce((select jsonb_agg(id) from public.render_jobs
      where id=any(job_ids) and source='worker' and status='processing'),'[]'::jsonb)
  ) into payload;
  if exists(select 1 from jsonb_array_elements(provider_targets) t where
    t->>'lease_token' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception 'RP409: invalid provider identity; nothing was deleted';
  end if;
  if octet_length(payload::text)>8388608 or jsonb_array_length(payload->'r2')>25000 then raise exception 'RP413: account requires assisted deletion'; end if;
  scope:=jsonb_build_object('source_user_id',p_user,'solo_orgs',solo,'shared_orgs',shared,'db_purged',true);
  -- Intent precedes every destructive write. Any subsequent SQL failure rolls
  -- back BOTH the intent and all DB destruction; no Edge cleanup is authorized.
  insert into public.deletion_requests(user_id,email,status,payload,snapshot_version,ownership_scope)
    values(p_user,email_value,'pending',payload,2,scope) returning id into request_id;
  foreach org in array shared loop
    select user_id into heir from public.memberships where org_id=org and user_id<>p_user
      order by case role when'owner'then 0 when'admin'then 1 when'agent'then 2 else 3 end,user_id limit 1;
    if heir is null then raise exception 'RP409: shared workspace ownership changed'; end if;
    update public.listings set agent_id=heir where org_id=org and agent_id=p_user;
    delete from public.memberships where org_id=org and user_id=p_user;
  end loop;
  update public.renders set published_at=null where listing_id=any(listing_ids);
  if cardinality(spatial_ids)>0 then
    update public.spatial_jobs set published_at=null,approved=false,excluded=true,status='failed',failure_code='account_deleted',
      lease_expires_at=clock_timestamp(),updated_at=clock_timestamp() where id=any(spatial_ids);
    delete from public.spatial_inputs where job_id=any(spatial_ids);
    delete from public.spatial_attempt_history where job_id=any(spatial_ids);
    delete from public.spatial_jobs where id=any(spatial_ids);
  end if;
  delete from public.upload_operations where asset_id in(select asset_id from public.upload_reservations where org_id=any(solo));
  delete from public.upload_reservations where org_id=any(solo);
  delete from public.metering where org_id=any(solo) or render_id=any(render_ids);
  delete from public.leads where org_id=any(solo) or render_id=any(render_ids) or listing_id=any(listing_ids);
  delete from public.cost_ledger where org_id=any(solo) or job_id=any(job_ids);
  delete from public.renders where listing_id=any(listing_ids);
  delete from public.render_jobs where listing_id=any(listing_ids);
  delete from public.capture_chapters where asset_id=any(asset_ids);
  delete from public.capture_assets where listing_id=any(listing_ids);
  delete from public.photos where listing_id=any(listing_ids);
  delete from public.listings where org_id=any(solo);
  delete from public.memberships where org_id=any(solo);
  delete from public.orgs where id=any(solo);
  -- Preserve unproven old payloads, but do not let them run against a winner.
  update public.deletion_requests set status='pending',manual_review_required=true,
    last_error='Unverified legacy ownership snapshot: manual reconciliation required'
    where user_id=p_user and snapshot_version<>2 and status<>'completed';
  return public.claim_account_deletion(request_id);
end;
$$;

-- Provider identity survives parent-row erasure. Missing table/row, mere TTL,
-- or provider_stopped from the old worker are never private-file removal proof.
-- 0041 installs this optional journal later in sequential fresh deployments.
create or replace function public.account_deletion_provider_ready(p_job uuid,p_lease uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare ready boolean;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required'; end if;
  if to_regclass('public.spatial_provider_attempts') is null then return false; end if;
  execute 'select files_removed and terminated from public.spatial_provider_attempts where job_id=$1 and lease_token=$2'
    into ready using p_job,p_lease;
  return coalesce(ready,false);
end $$;

create or replace function public.finish_account_deletion(p_request uuid,p_token uuid,p_remaining jsonb,p_notes text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.deletion_requests%rowtype; field text; done boolean; manual boolean; target jsonb;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required'; end if;
  select* into r from public.deletion_requests where id=p_request for update;
  if not found or r.snapshot_version<>2 or r.cleanup_token is distinct from p_token or p_token is null
     or r.status<>'processing' or r.cleanup_lease_until is null
     or r.cleanup_lease_until<=clock_timestamp() or r.manual_review_required then raise exception 'RP409: deletion cleanup lease is stale'; end if;
  if jsonb_typeof(p_remaining) is distinct from 'object' then raise exception 'RP400: invalid remaining cleanup'; end if;
  foreach field in array array['r2','stream_uids','ghl_targets','provider_leases','multipart_uploads','unresolved_uploads','unresolved_render_jobs'] loop
    if jsonb_typeof(p_remaining->field) is distinct from 'array' or not((r.payload->field) @> (p_remaining->field)) then
      raise exception 'RP403: cleanup targets do not belong to this request'; end if;
  end loop;
  if p_remaining->'unresolved_uploads' is distinct from r.payload->'unresolved_uploads' then
    raise exception 'RP409: ambiguous multipart allocation requires assisted reconciliation';
  end if;
  if p_remaining->'unresolved_render_jobs' is distinct from r.payload->'unresolved_render_jobs' then
    raise exception 'RP409: legacy render worker cleanup requires assisted reconciliation';
  end if;
  if not(p_remaining?'storage_not_before') or
    (p_remaining->'storage_not_before' is distinct from r.payload->'storage_not_before'
      and p_remaining->'storage_not_before'<>'null') then
    raise exception 'RP403: cleanup deadline does not belong to this request';
  end if;
  if r.payload->>'storage_not_before' is not null and
    (r.payload->>'storage_not_before')::timestamptz>clock_timestamp() and
    (p_remaining->'r2' is distinct from r.payload->'r2' or
     p_remaining->'multipart_uploads' is distinct from r.payload->'multipart_uploads' or
     p_remaining->'storage_not_before' is distinct from r.payload->'storage_not_before') then
    raise exception 'RP409: storage writes have not drained';
  end if;
  for target in select value from jsonb_array_elements(r.payload->'provider_leases') loop
    if not(p_remaining->'provider_leases' @> jsonb_build_array(target)) and
      not public.account_deletion_provider_ready((target->>'job_id')::uuid,(target->>'lease_token')::uuid) then
      raise exception 'RP409: provider cleanup has not been confirmed';
    end if;
  end loop;
  foreach field in array array['apple_refresh_token','analytics_user_id','profile_id','auth_user_id'] loop
    if not(p_remaining?field) or ((p_remaining->field)<>'null'::jsonb and p_remaining->field is distinct from r.payload->field) then
      raise exception 'RP403: cleanup identity does not belong to this request'; end if;
  end loop;
  if exists(select 1 from jsonb_object_keys(p_remaining) k where k<>all(array['r2','stream_uids','ghl_targets','apple_refresh_token','analytics_user_id','profile_id','auth_user_id',
    'provider_leases','multipart_uploads','unresolved_uploads','storage_not_before','unresolved_render_jobs'])) then
    raise exception 'RP400: unknown remaining cleanup field'; end if;
  -- A successful SDK envelope is not stronger proof than the actual DB row.
  if p_remaining->'auth_user_id'='null'::jsonb and exists(select 1 from auth.users where id=r.user_id) then
    raise exception 'RP409: sign-in record still exists'; end if;
  if p_remaining->'profile_id'='null'::jsonb and exists(select 1 from public.profiles where id=r.user_id) then
    raise exception 'RP409: profile still exists'; end if;
  done:=jsonb_array_length(p_remaining->'r2')+jsonb_array_length(p_remaining->'stream_uids')+jsonb_array_length(p_remaining->'ghl_targets')+
    jsonb_array_length(p_remaining->'provider_leases')+jsonb_array_length(p_remaining->'multipart_uploads')+
    jsonb_array_length(p_remaining->'unresolved_uploads')+jsonb_array_length(p_remaining->'unresolved_render_jobs')=0 and p_remaining->'storage_not_before'='null'::jsonb
    and p_remaining->'apple_refresh_token'='null'::jsonb and p_remaining->'analytics_user_id'='null'::jsonb
    and p_remaining->'profile_id'='null'::jsonb and p_remaining->'auth_user_id'='null'::jsonb;
  select exists(select 1 from public.deletion_requests where user_id=r.user_id and manual_review_required) into manual;
  update public.deletion_requests set payload=p_remaining,status=case when done then'completed'else'pending'end,
    cleanup_token=null,cleanup_lease_until=null,next_cleanup_at=clock_timestamp()+interval '5 minutes',
    last_error=nullif(left(p_notes,2000),''),completed_at=case when done then now()else null end where id=r.id;
  return jsonb_build_object('ok',true,'request_id',r.id,'source_user_id',r.user_id,
    'cleanup_complete',done and not manual,'manual_review_required',manual);
end;
$$;
revoke execute on function public.claim_account_deletion(uuid) from public,anon,authenticated;
revoke execute on function public.prepare_account_deletion(uuid,text,text) from public,anon,authenticated;
revoke execute on function public.finish_account_deletion(uuid,uuid,jsonb,text) from public,anon,authenticated;
revoke execute on function public.account_deletion_provider_ready(uuid,uuid) from public,anon,authenticated;
grant execute on function public.claim_account_deletion(uuid),public.prepare_account_deletion(uuid,text,text),public.finish_account_deletion(uuid,uuid,jsonb,text),
  public.account_deletion_provider_ready(uuid,uuid) to service_role;
