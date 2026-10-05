-- CLI-generated, source only. Distinct business logo, immutable raster objects,
-- existing durable byte/write budget and cleanup leases; no listing required.
create table if not exists public.org_brand_assets (
 id uuid primary key, org_id uuid not null, actor_id uuid not null,
 object_key text not null unique, public_url text not null unique,
 expected_url text, bytes integer not null check(bytes between 1 and 524288),
 content_type text not null check(content_type in('image/jpeg','image/png')),
 sha256 text not null check(sha256 ~ '^[a-f0-9]{64}$'),
 state text not null default 'writing' check(state in('writing','published','retired')),
 created_at timestamptz not null default clock_timestamp()
);
alter table public.org_brand_assets enable row level security;
revoke all on public.org_brand_assets from public,anon,authenticated;
grant select,insert,update,delete on public.org_brand_assets to service_role;

create or replace function public.lock_org_brand_authority(p_actor uuid,p_org uuid)
returns public.orgs language plpgsql security invoker set search_path='' as $$
declare o public.orgs;
begin
 perform public.upload_service_only();
 perform 1 from public.profiles where id=p_actor for share;
 if not found then raise exception 'RP403: account is unavailable'; end if;
 select * into o from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP403: workspace is unavailable'; end if;
 perform 1 from public.memberships where user_id=p_actor and org_id=p_org and role in('owner','admin') for share;
 if not found or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') then
  raise exception 'RP403: only a current workspace owner or admin can change its logo'; end if;
 return o;
end $$;

create or replace function public.prepare_org_brand_logo(p_actor uuid,p_org uuid,p_operation uuid,p_expected text,p_bytes integer,p_type text,p_sha256 text,p_url text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare o public.orgs; a public.org_brand_assets; w public.upload_budget_windows;
 d date:=(clock_timestamp() at time zone 'UTC')::date; k text; operation uuid;
begin
 o:=public.lock_org_brand_authority(p_actor,p_org);
 if p_operation is null or p_bytes is null or p_bytes not between 1 and 524288
  or p_type is null or p_type not in('image/jpeg','image/png') or p_sha256 is null or p_sha256 !~ '^[a-f0-9]{64}$'
  or p_url is null or length(p_url)>500 or p_url !~ '^https://[^/[:space:]?#]+/' then raise exception 'RP400: invalid logo specification'; end if;
 k:='renders/'||p_org||'/brand/'||p_operation||case when p_type='image/png' then '.png' else '.jpg' end;
 if right(p_url,length(k))<>k or p_url~'[[:cntrl:]]' then raise exception 'RP400: invalid hosted logo address'; end if;
 select * into a from public.org_brand_assets where id=p_operation for update;
 if found then
  if a.org_id<>p_org or a.actor_id<>p_actor then raise exception 'RP403: logo operation belongs to another account or workspace'; end if;
  if a.expected_url is distinct from p_expected or a.bytes<>p_bytes or a.content_type<>p_type or a.sha256<>p_sha256 or a.public_url<>p_url then raise exception 'RP409: logo operation changed; reload before retrying'; end if;
  if a.state='published' and o.brand_kit->>'business_logo_url'=a.public_url then
   return jsonb_build_object('org_id',p_org,'actor_id',p_actor,'object_key',k,'public_url',a.public_url,'replayed',true,'dispatch',false); end if;
  if a.state<>'writing' or o.brand_kit->>'business_logo_url' is distinct from a.expected_url then raise exception 'RP409: logo changed; reload before retrying'; end if;
  return jsonb_build_object('org_id',p_org,'actor_id',p_actor,'object_key',k,'public_url',a.public_url,'replayed',false,'dispatch',false);
 end if;
 if o.brand_kit->>'business_logo_url' is distinct from p_expected then raise exception 'RP409: logo changed; reload before retrying'; end if;
 if (select count(*) from public.org_brand_assets where org_id=p_org and created_at>=(d::timestamp at time zone 'UTC') and created_at<((d+1)::timestamp at time zone 'UTC'))>=20 then raise exception 'RP429: daily logo upload safety limit reached'; end if;
 insert into public.upload_budget_windows(org_id,day) values(p_org,d) on conflict do nothing;
 select * into strict w from public.upload_budget_windows where org_id=p_org and day=d for update;
 if w.tickets>=2000 or w.held_bytes+w.spent_bytes+p_bytes>214748364800 then raise exception 'RP429: workspace upload safety limit reached'; end if;
 update public.upload_budget_windows set tickets=tickets+1,spent_bytes=spent_bytes+p_bytes where org_id=p_org and day=d;
 insert into public.org_brand_assets(id,org_id,actor_id,object_key,public_url,expected_url,bytes,content_type,sha256)
 values(p_operation,p_org,p_actor,k,p_url,p_expected,p_bytes,p_type,p_sha256);
 -- The reservation's listing_id is an explicit org sentinel, never a fabricated
 -- listing. Only the matching private org_brand_assets row permits deletion.
 insert into public.upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,spent_bytes,state,settled_at)
 values(p_operation,p_org,p_org,p_actor,d,jsonb_build_object('role','business_logo','sha256',p_sha256),0,p_bytes,'cancelled',clock_timestamp());
 operation:=gen_random_uuid();
 insert into public.upload_operations(id,asset_id,kind,bucket,object_key,bytes,expected_bytes,content_type,content_type_declared,asset_kind,state,claim,write_deadline,cleanup_after)
 values(operation,p_operation,'single','renders',k,p_bytes,p_bytes,p_type,true,'photo','dispatching',gen_random_uuid(),clock_timestamp()+interval '2 minutes',clock_timestamp()+interval '62 minutes');
 return jsonb_build_object('org_id',p_org,'actor_id',p_actor,'object_key',k,'public_url',p_url,'replayed',false,'dispatch',true);
end $$;

create or replace function public.publish_org_brand_logo(p_actor uuid,p_org uuid,p_operation uuid,p_etag text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare o public.orgs; a public.org_brand_assets; op public.upload_operations; old text;
begin
 o:=public.lock_org_brand_authority(p_actor,p_org);
 select * into a from public.org_brand_assets where id=p_operation for update;
 if a.id is null or a.org_id<>p_org or a.actor_id<>p_actor then raise exception 'RP403: logo operation is unavailable'; end if;
 if a.state='published' and o.brand_kit->>'business_logo_url'=a.public_url then return jsonb_build_object('org_id',p_org,'business_logo_url',a.public_url,'replayed',true); end if;
 if a.state<>'writing' or o.brand_kit->>'business_logo_url' is distinct from a.expected_url then raise exception 'RP409: logo changed; reload before retrying'; end if;
 perform 1 from public.upload_reservations where asset_id=a.id and org_id=p_org and listing_id=p_org and actor_id=p_actor and spec->>'role'='business_logo' for update;
 if not found then raise exception 'RP409: logo reservation is unavailable'; end if;
 select * into op from public.upload_operations where asset_id=a.id and kind='single' for update;
 if op.id is null or op.object_key<>a.object_key or op.bucket<>'renders' or op.state not in('dispatching','uncertain') or op.write_deadline<=clock_timestamp()
  or p_etag is null or length(p_etag) not between 1 and 256 then raise exception 'RP409: logo upload is no longer publishable'; end if;
 old:=o.brand_kit->>'business_logo_url';
 update public.orgs set brand_kit=brand_kit||jsonb_build_object('business_logo_url',a.public_url) where id=p_org;
 update public.org_brand_assets set state='published' where id=a.id;
 update public.upload_operations set state='retained',etag=p_etag,cleanup_after=null where id=op.id;
 if old is not null then
  update public.upload_operations set state='stored',cleanup_after=clock_timestamp() where asset_id in(select id from public.org_brand_assets where org_id=p_org and public_url=old and id<>a.id) and state='retained';
  update public.org_brand_assets set state='retired' where org_id=p_org and public_url=old and id<>a.id;
 end if;
 return jsonb_build_object('org_id',p_org,'business_logo_url',a.public_url,'replayed',false);
end $$;

create or replace function public.clear_org_brand_logo(p_actor uuid,p_org uuid,p_expected text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare o public.orgs; old text;
begin
 o:=public.lock_org_brand_authority(p_actor,p_org); old:=o.brand_kit->>'business_logo_url';
 if old is not null and old is distinct from p_expected then raise exception 'RP409: logo changed; reload before removing it'; end if;
 update public.orgs set brand_kit=brand_kit-'business_logo_url' where id=p_org;
 update public.upload_operations set state='stored',cleanup_after=clock_timestamp() where asset_id in(select id from public.org_brand_assets where org_id=p_org and public_url=old) and state='retained';
 update public.org_brand_assets set state='retired' where org_id=p_org and public_url=old;
 return jsonb_build_object('org_id',p_org,'business_logo_url',null);
end $$;

-- Existing authenticated brand-kit grants cannot inject/erase a hosted logo.
create or replace function public.guard_business_logo_pointer() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
 if new.brand_kit->'business_logo_url' is distinct from old.brand_kit->'business_logo_url'
  and current_setting('role',true) is distinct from 'service_role' then raise exception 'RP403: use the business logo endpoint'; end if;
 return new;
end $$;
drop trigger if exists guard_business_logo_pointer on public.orgs;
create trigger guard_business_logo_pointer before update of brand_kit on public.orgs for each row execute function public.guard_business_logo_pointer();
revoke execute on function public.lock_org_brand_authority(uuid,uuid),public.prepare_org_brand_logo(uuid,uuid,uuid,text,integer,text,text,text),public.publish_org_brand_logo(uuid,uuid,uuid,text),public.clear_org_brand_logo(uuid,uuid,text),public.guard_business_logo_pointer() from public,anon,authenticated;
grant execute on function public.lock_org_brand_authority(uuid,uuid),public.prepare_org_brand_logo(uuid,uuid,uuid,text,integer,text,text,text),public.publish_org_brand_logo(uuid,uuid,uuid,text),public.clear_org_brand_logo(uuid,uuid,text) to service_role;

-- Explicit ordinary fields merge under the same authority/org lock. A text
-- save cannot replay an old whole brand document over the current logo.
create or replace function public.merge_org_brand_fields(p_actor uuid,p_org uuid,p_brand jsonb,p_org_fields jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare o public.orgs; b jsonb; k text; v jsonb;
begin
 o:=public.lock_org_brand_authority(p_actor,p_org); b:=o.brand_kit;
 if jsonb_typeof(p_brand) is distinct from 'object' or jsonb_typeof(p_org_fields) is distinct from 'object'
  or octet_length(p_brand::text||p_org_fields::text)>10000 then raise exception 'RP400: invalid brand fields'; end if;
 for k,v in select key,value from jsonb_each(p_brand) loop
  if k not in('name','title','brokerage','phone','email','website','avatar_url','headshot_url','instagram','linkedin','tiktok','accent')
   or (v<>'null'::jsonb and (jsonb_typeof(v)<>'string' or length(v#>>'{}')>300)) then raise exception 'RP400: unsupported brand field'; end if;
  if k='name' and (v#>>'{}') like '%@%' then raise exception 'RP400: enter a display name'; end if;
  if k='accent' and v<>'null'::jsonb and (v#>>'{}')!~'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$' then raise exception 'RP400: invalid accent color'; end if;
  if v='null'::jsonb then b:=b-k; else b:=b||jsonb_build_object(k,v); end if;
 end loop;
 for k,v in select key,value from jsonb_each(p_org_fields) loop
  if k not in('name','handle','space_type') or (v<>'null'::jsonb and jsonb_typeof(v)<>'string') then raise exception 'RP400: unsupported workspace field'; end if;
  if k='name' and (v='null'::jsonb or length(v#>>'{}') not between 1 and 120 or (v#>>'{}') like '%@%') then raise exception 'RP400: enter a business name'; end if;
  if k='handle' and v<>'null'::jsonb and ((v#>>'{}')!~'^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$' or (v#>>'{}')in('admin','api','app','www','rendprop','f','a','tours','tour','pricing','privacy','terms','support','help','login','signup','me','leads','static','assets','demo','estate-demo','about','blog','contact','portfolio','agent','agents')) then raise exception 'RP409: choose another public handle'; end if;
  if k='space_type' and (v='null'::jsonb or (v#>>'{}') not in('real_estate','venue','restaurant','retail','fitness','other')) then raise exception 'RP400: invalid business type'; end if;
 end loop;
 if octet_length(b::text)>8000 then raise exception 'RP400: brand card is too large'; end if;
 if not(p_org_fields?'name') and p_brand->'name' is not null and p_brand->'name'<>'null'::jsonb and (o.name='' or o.name='My business' or o.name like '%@%') then p_org_fields:=p_org_fields||jsonb_build_object('name',p_brand->'name'); end if;
 update public.orgs set brand_kit=b,
  name=case when p_org_fields?'name' then p_org_fields->>'name' else name end,
  handle=case when p_org_fields?'handle' then p_org_fields->>'handle' else handle end,
  space_type=case when p_org_fields?'space_type' then p_org_fields->>'space_type' else space_type end
 where id=p_org returning * into o;
 return jsonb_build_object('id',o.id,'name',o.name,'handle',o.handle,'space_type',o.space_type,'brand_kit',o.brand_kit);
end $$;
revoke all on function public.merge_org_brand_fields(uuid,uuid,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.merge_org_brand_fields(uuid,uuid,jsonb,jsonb) to service_role;

-- Exact0039 deletion function retained below, with only logo journal proof,
-- inventory and row purge additions. Its Auth/profile/org locks, provider
-- receipts, storage_not_before and leased payload remain the same.
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
  if exists(select 1 from public.upload_reservations r where r.org_id=any(solo) and not(r.listing_id=any(listing_ids)) and
    not exists(select 1 from public.org_brand_assets b where b.id=r.asset_id and b.org_id=r.org_id and b.actor_id=r.actor_id
      and r.listing_id=r.org_id and r.spec->>'role'='business_logo' and r.spec->>'sha256'=b.sha256)) then
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
  -- Org logo destinations are private service-journaled identities, never
  -- inferred from a user-editable brand URL. Preserve retired/orphan attempts too.
  if exists(select 1 from public.org_brand_assets b where b.org_id=any(solo) and not exists(
    select 1 from public.upload_reservations r join public.upload_operations op on op.asset_id=r.asset_id
    where r.asset_id=b.id and r.org_id=b.org_id and r.actor_id=b.actor_id and r.listing_id=b.org_id
      and r.spec->>'role'='business_logo' and r.spec->>'sha256'=b.sha256 and op.kind='single' and op.bucket='renders' and op.object_key=b.object_key)) then
    raise exception 'RP409: logo ownership requires assisted deletion; nothing was deleted';
  end if;
  select object_targets||coalesce(jsonb_agg(jsonb_build_object('bucket',p_render_bucket,'key',b.object_key,'valid',
    b.object_key='renders/'||b.org_id||'/brand/'||b.id||case when b.content_type='image/png' then '.png' else '.jpg' end)), '[]')
    into object_targets from public.org_brand_assets b where b.org_id=any(solo);
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
  delete from public.org_brand_assets where org_id=any(solo);
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
