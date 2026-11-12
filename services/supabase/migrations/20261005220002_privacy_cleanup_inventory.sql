-- Durable media/legacy CRM cleanup intent. Recording intent is not a claim
-- that known public URLs have been revoked; object/proxy rollout is separate.
begin;
create table if not exists public.privacy_runtime(
 singleton boolean primary key default true check(singleton),
 legacy_crm_cutoff timestamptz not null default now()
);
insert into public.privacy_runtime(singleton)values(true)on conflict do nothing;
alter table public.privacy_runtime enable row level security;
revoke all on public.privacy_runtime from public,anon,authenticated,service_role;
grant select on public.privacy_runtime to service_role;

create table if not exists public.private_ai_outputs(
 id uuid primary key default gen_random_uuid(),org_id uuid not null,user_id uuid not null,listing_id uuid,
 bucket text not null check(bucket='renders'),storage_key text not null unique,
 bytes bigint not null check(bytes>0 and bytes<=536870912),created_at timestamptz not null default now(),
 check(storage_key like 'ai-router/'||org_id||'/%'or storage_key like 'presenter-private/'||org_id||'/%')
);
create index if not exists private_ai_outputs_listing on public.private_ai_outputs(org_id,listing_id);
alter table public.private_ai_outputs enable row level security;
revoke all on public.private_ai_outputs from public,anon,authenticated,service_role;
grant select on public.private_ai_outputs to service_role;
create or replace function public.register_private_ai_output(p_user uuid,p_org uuid,p_listing uuid,p_bucket text,p_key text,p_bytes bigint)returns jsonb
language plpgsql security definer set search_path='' as $$
declare row public.private_ai_outputs;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 perform 1 from public.profiles where id=p_user for update;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or not exists(select 1 from public.memberships where user_id=p_user and org_id=p_org)
  or not exists(select 1 from auth.users where id=p_user)
  or exists(select 1 from public.deletion_requests where user_id=p_user and status in('pending','processing'))then raise exception 'RP403: generation workspace is unavailable';end if;
 if p_listing is not null then
  perform 1 from public.listings where id=p_listing and org_id=p_org and deleted_at is null for update;
  if not found then raise exception 'RP404: generation listing is unavailable';end if;
 end if;
 if p_bucket is distinct from 'renders'or p_key is null or length(p_key)>4096
  or p_key~'[[:cntrl:]]'or p_key~'(^|/)\.\.?(/|$)'or
  not(p_key like 'ai-router/'||p_org||'/%'or p_key like 'presenter-private/'||p_org||'/%')
  or p_bytes is null or p_bytes<1 or p_bytes>536870912 then raise exception 'RP400: invalid persisted output receipt';end if;
 insert into public.private_ai_outputs(org_id,user_id,listing_id,bucket,storage_key,bytes)values(p_org,p_user,p_listing,p_bucket,p_key,p_bytes)
 on conflict(storage_key)do nothing returning * into row;
 if not found then
  select * into row from public.private_ai_outputs where storage_key=p_key;
  if row.org_id<>p_org or row.user_id<>p_user or row.listing_id is distinct from p_listing or row.bucket<>p_bucket or row.bytes<>p_bytes then raise exception 'RP409: output receipt already belongs to another generation';end if;
 end if;
 return jsonb_build_object('ok',true,'id',row.id,'key',row.storage_key);
end$$;

create table if not exists public.privacy_cleanup_jobs(
 id uuid primary key default gen_random_uuid(),kind text not null check(kind in('lead','listing')),
 org_id uuid not null,source_id uuid not null,source_user_id uuid,
 payload jsonb not null check(jsonb_typeof(payload)='object'and octet_length(payload::text)<=8388608),
 remaining jsonb not null,not_before timestamptz not null default now(),
 state text not null default 'pending'check(state in('pending','processing','completed','manual_review')),
 lease_token uuid,lease_until timestamptz,attempts integer not null default 0,
 next_attempt_at timestamptz not null default now(),last_error text,created_at timestamptz not null default now(),completed_at timestamptz,
 unique(kind,source_id)
);
alter table public.privacy_cleanup_jobs enable row level security;
revoke all on public.privacy_cleanup_jobs from public,anon,authenticated,service_role;
grant select on public.privacy_cleanup_jobs to service_role;

create or replace function public.delete_workspace_lead(p_user uuid,p_org uuid,p_lead uuid)returns jsonb
language plpgsql security definer set search_path='' as $$
declare lead public.leads;payload jsonb;pending boolean:=false;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 perform 1 from public.profiles where id=p_user for update;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or not exists(select 1 from auth.users where id=p_user and not is_anonymous)
  or not exists(select 1 from public.memberships where org_id=p_org and user_id=p_user and role in('owner','admin','agent'))
  or exists(select 1 from public.deletion_requests where user_id=p_user and status in('pending','processing'))then raise exception 'RP403: this workspace does not permit deleting inquiries';end if;
 select * into lead from public.leads where id=p_lead and org_id=p_org for update;
 if not found then raise exception 'RP404: inquiry not found in this workspace';end if;
 if(lead.synced_crm or lead.created_at<=(select legacy_crm_cutoff from public.privacy_runtime where singleton))and
  (nullif(btrim(lead.email),'')is not null or nullif(btrim(lead.phone),'')is not null)then
  payload:=jsonb_build_object('r2','[]'::jsonb,'stream_uids','[]'::jsonb,'ghl_targets',jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('org_id',p_org,'email',nullif(lower(btrim(lead.email)),''),'phone',nullif(btrim(lead.phone),'')))));
  insert into public.privacy_cleanup_jobs(kind,org_id,source_id,source_user_id,payload,remaining)values('lead',p_org,p_lead,p_user,payload,payload)on conflict(kind,source_id)do nothing;
  pending:=true;
 end if;
 -- Client delivery FK cascades remove frozen buyer snapshots and their outbox
 -- rows. Ordinary inbox alerts have no lead FK, so remove their payload too.
 delete from public.notification_outbox o where o.payload#>>'{data,lead_id}'=p_lead::text;
 delete from public.leads where id=p_lead and org_id=p_org;
 return jsonb_build_object('ok',true,'lead_id',p_lead,'deleted',true,'cleanup_pending',pending);
end$$;

-- Listing RLS admits the actual write. This trigger freezes only exact keys
-- already attached to that listing and exact persisted-output journal rows.
create or replace function public.queue_deleted_listing_media()returns trigger
language plpgsql security definer set search_path='' as $$
declare payload jsonb;wait_until timestamptz;needs_review boolean:=false;
begin
 if old.deleted_at is not null or new.deleted_at is null then return new;end if;
 select jsonb_build_object('r2',coalesce(jsonb_agg(distinct jsonb_build_object('bucket',q.bucket,'key',q.key)),'[]'::jsonb),
  'stream_uids',coalesce((select jsonb_agg(distinct stream_uid)from public.renders where listing_id=new.id and stream_uid is not null),'[]'::jsonb),'ghl_targets','[]'::jsonb)
 into payload from(
  select bucket,storage_key as key from public.capture_assets where listing_id=new.id
  union select case when starts_with(original_key,'uploads/')then 'uploads'else 'renders'end,original_key from public.photos where listing_id=new.id
  union select 'renders',enhanced_key from public.photos where listing_id=new.id
  union select 'renders',video_key from public.renders where listing_id=new.id
  union select 'renders',poster_key from public.renders where listing_id=new.id
  union select 'renders',hero_key from public.renders where listing_id=new.id
  union select 'renders',new.main_photo_key
  union select bucket,storage_key from public.private_ai_outputs where listing_id=new.id and org_id=new.org_id
  union select 'uploads',output_key from public.studio_presenter_jobs where listing_id=new.id and org_id=new.org_id
  union select 'renders',import_storage_key from public.studio_presenter_jobs where listing_id=new.id and org_id=new.org_id
 )q where q.key is not null and q.key<>'';
 if exists(select 1 from jsonb_array_elements(payload->'r2')t where t->>'bucket'not in('uploads','renders')or length(t->>'key')>4096 or t->>'key'~'(^|/)[.]{1,2}(/|$)'or not(
  starts_with(t->>'key',(t->>'bucket')||'/'||new.org_id||'/'||new.id||'/')or
  (t->>'bucket'='renders'and starts_with(t->>'key','renders/'||new.id||'/'))or
  exists(select 1 from public.private_ai_outputs p where p.org_id=new.org_id and p.listing_id=new.id and p.bucket=t->>'bucket'and p.storage_key=t->>'key')or
  exists(select 1 from public.studio_presenter_jobs j where j.org_id=new.org_id and j.listing_id=new.id and
   ((t->>'bucket'='uploads'and j.output_key=t->>'key'and j.output_key='presenter-private/'||new.org_id||'/'||j.id||'/output.mp4')or(t->>'bucket'='renders'and j.import_storage_key=t->>'key'and starts_with(j.import_storage_key,'renders/'||new.org_id||'/'||new.id||'/'))))))then needs_review:=true;end if;
 select greatest(now()+interval '1 hour',max(expires_at)+interval '1 hour')into wait_until
 from public.upload_reservations where listing_id=new.id;
 if exists(select 1 from public.capture_assets where listing_id=new.id and transport_version=1)then wait_until:=greatest(wait_until,now()+interval '75 minutes');end if;
 select greatest(wait_until,max(output_write_deadline)+interval '1 hour')into wait_until from public.studio_presenter_jobs where listing_id=new.id and org_id=new.org_id;
 if exists(select 1 from public.render_jobs where listing_id=new.id and source='worker'and status='processing')then needs_review:=true;end if;
 insert into public.privacy_cleanup_jobs(kind,org_id,source_id,source_user_id,payload,remaining,not_before,state,last_error)
 values('listing',new.org_id,new.id,new.agent_id,payload,payload,wait_until,case when needs_review then 'manual_review'else 'pending'end,case when needs_review then 'Storage ownership or an unjournaled worker requires assisted cleanup.'else null end)on conflict(kind,source_id)do nothing;
 return new;
end$$;
drop trigger if exists trg_deleted_listing_media on public.listings;
create trigger trg_deleted_listing_media after update of deleted_at on public.listings for each row execute function public.queue_deleted_listing_media();

create or replace function public.privacy_cleanup_claim(p_id uuid)returns jsonb
language plpgsql security definer set search_path='' as $$
declare row public.privacy_cleanup_jobs;token uuid;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 select * into row from public.privacy_cleanup_jobs where id=p_id for update;
 if not found or row.state in('completed','manual_review')or row.not_before>clock_timestamp()or row.next_attempt_at>clock_timestamp()
  or(row.state='processing'and row.lease_until>clock_timestamp())then return null;end if;
 token:=gen_random_uuid();
 update public.privacy_cleanup_jobs set state='processing',lease_token=token,lease_until=clock_timestamp()+interval '2 minutes',attempts=attempts+1 where id=p_id;
 return jsonb_build_object('id',p_id,'token',token,'org_id',row.org_id,'payload',row.remaining);
end$$;
create or replace function public.privacy_cleanup_due()returns uuid[]
language plpgsql stable security definer set search_path='' as $$
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 return array(select id from public.privacy_cleanup_jobs where state in('pending','processing')and not_before<=now()and next_attempt_at<=now()
  and(state='pending'or lease_until<=now())order by next_attempt_at,id limit 5);
end$$;
create or replace function public.privacy_cleanup_finish(p_id uuid,p_token uuid,p_remaining jsonb,p_notes text)returns jsonb
language plpgsql security definer set search_path='' as $$
declare row public.privacy_cleanup_jobs;field text;done boolean;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 select * into row from public.privacy_cleanup_jobs where id=p_id for update;
 if not found or row.state<>'processing'or row.lease_token is distinct from p_token or row.lease_until<=clock_timestamp()then raise exception 'RP409: privacy cleanup lease is stale';end if;
 if jsonb_typeof(p_remaining)is distinct from 'object'or exists(select 1 from jsonb_object_keys(p_remaining)k where k not in('r2','stream_uids','ghl_targets'))then raise exception 'RP400: invalid privacy cleanup receipt';end if;
 foreach field in array array['r2','stream_uids','ghl_targets']loop
  if jsonb_typeof(p_remaining->field)is distinct from 'array'or not((row.remaining->field) @> (p_remaining->field))then raise exception 'RP403: privacy cleanup targets changed';end if;
 end loop;
 done:=jsonb_array_length(p_remaining->'r2')+jsonb_array_length(p_remaining->'stream_uids')+jsonb_array_length(p_remaining->'ghl_targets')=0;
 if done and row.kind='listing'then delete from public.private_ai_outputs where org_id=row.org_id and listing_id=row.source_id;end if;
 update public.privacy_cleanup_jobs set payload=case when done then p_remaining else payload end,remaining=p_remaining,state=case when done then 'completed'when attempts>=12 and remaining=p_remaining then 'manual_review'else 'pending'end,
  lease_token=null,lease_until=null,next_attempt_at=clock_timestamp()+interval '5 minutes',last_error=case when done then null else nullif(left(p_notes,1000),'')end,completed_at=case when done then clock_timestamp()else null end where id=p_id;
 return jsonb_build_object('ok',true,'id',p_id,'cleanup_complete',done);
end$$;

-- Existing service-only journals bind these exact objects to their workspace.
-- Account cleanup inventories them before profile/workspace FK deletion, and
-- waits beyond any already leased write. No arbitrary object key is accepted.
create or replace function public.account_private_output_targets(p_orgs uuid[],p_upload_bucket text,p_render_bucket text)returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 if exists(select 1 from public.privacy_cleanup_jobs where org_id=any(p_orgs)and state='manual_review')then raise exception 'RP409: retained cleanup requires assisted account deletion';end if;
 return coalesce((select jsonb_agg(distinct jsonb_build_object('bucket',bucket,'key',key,'valid',valid))from(
  select p_render_bucket bucket,o.storage_key key,
   starts_with(o.storage_key,'ai-router/'||o.org_id||'/')and o.storage_key!~'(^|/)[.]{1,2}(/|$)' valid
   from public.private_ai_outputs o where o.org_id=any(p_orgs)
  union all select p_upload_bucket,j.output_key,j.output_key='presenter-private/'||j.org_id||'/'||j.id||'/output.mp4'
   from public.studio_presenter_jobs j where j.org_id=any(p_orgs)and j.output_key is not null
  union all select p_render_bucket,j.import_storage_key,starts_with(j.import_storage_key,'renders/'||j.org_id||'/'||j.listing_id||'/')and j.import_storage_key!~'(^|/)[.]{1,2}(/|$)'
   from public.studio_presenter_jobs j where j.org_id=any(p_orgs)and j.import_storage_key is not null
  union all select case t->>'bucket'when 'uploads'then p_upload_bucket else p_render_bucket end,t->>'key',true
   from public.privacy_cleanup_jobs j cross join lateral jsonb_array_elements(j.remaining->'r2')t
   where j.org_id=any(p_orgs)and j.state in('pending','processing')
 )outputs),'[]'::jsonb);
end$$;
-- Account inventory includes phone-only legacy CRM contacts and fixed output
-- namespaces for solely-owned orgs. Shared workspaces never get enumerated.
do $$declare body text;old text;patched text;begin
 body:=pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);
 old:='''ghl_targets'',coalesce((select jsonb_agg(jsonb_build_object(''email'',email,''org_id'',org_id)) from('||E'\n'||
  '      select distinct lower(email) email,org_id from public.leads where org_id=any(solo) and email is not null'||E'\n'||
  '    ) targets),''[]''::jsonb),';
 patched:='''ghl_targets'',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(''email'',email,''phone'',phone,''org_id'',org_id))) from('||E'\n'||
  '      select distinct nullif(lower(btrim(email)),'''') email,nullif(btrim(phone),'''') phone,org_id from public.leads where org_id=any(solo)'||E'\n'||
  '       and(synced_crm or created_at<=(select legacy_crm_cutoff from public.privacy_runtime where singleton))and(nullif(btrim(email),'''')is not null or nullif(btrim(phone),'''')is not null)'||E'\n'||
  '      union select nullif(t->>''email'',''''),nullif(t->>''phone'',''''),j.org_id from public.privacy_cleanup_jobs j cross join lateral jsonb_array_elements(j.remaining->''ghl_targets'')t where j.org_id=any(solo)and j.state in(''pending'',''processing'')'||E'\n'||
  '    ) targets),''[]''::jsonb),'||E'\n'||
  '    ''r2_prefixes'',coalesce((select jsonb_agg(jsonb_build_object(''bucket'',bucket,''org_id'',owned.org_id,''prefix'',prefix,''removed_count'',0))from unnest(solo)owned(org_id) cross join lateral(values(p_render_bucket,''ai-router/''||owned.org_id||''/''),(p_upload_bucket,''presenter-private/''||owned.org_id||''/''))p(bucket,prefix)),''[]''::jsonb),';
 if position(patched in body)=0 then
  if position(old in body)=0 then raise exception 'RP409: unexpected account CRM inventory body';end if;
  body:=replace(body,old,patched);
  execute body;
 end if;
 body:=pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);
 old:='  if exists(select 1 from jsonb_array_elements(object_targets) t where t->>''valid'' is distinct from ''true'') then';
 patched:='  object_targets:=object_targets||public.account_private_output_targets(solo,p_upload_bucket,p_render_bucket);'||E'\n'||
  '  select greatest(storage_after,clock_timestamp()+interval ''1 hour'',max(output_write_deadline)+interval ''1 hour'')into storage_after from public.studio_presenter_jobs where org_id=any(solo);'||E'\n'||
  '  select greatest(storage_after,max(not_before)+interval ''1 hour'')into storage_after from public.privacy_cleanup_jobs where org_id=any(solo)and state in(''pending'',''processing'');'||E'\n'||old;
 if position(patched in body)=0 then
  if position(old in body)=0 then raise exception 'RP409: unexpected account output inventory body';end if;
  body:=replace(body,old,patched);
  old:='starts_with(key,''_staging/uploads/''||l.org_id||''/''||l.id||''/'') or starts_with(key,''_staging/renders/''||l.org_id||''/''||l.id||''/''))))';
  patched:='starts_with(key,''_staging/uploads/''||l.org_id||''/''||l.id||''/'') or starts_with(key,''_staging/renders/''||l.org_id||''/''||l.id||''/'') or exists(select 1 from public.private_ai_outputs own where own.org_id=l.org_id and own.listing_id=l.id and own.bucket=''renders''and own.storage_key=key))))';
  if position(old in body)=0 then raise exception 'RP409: unexpected account media ownership predicate';end if;
  body:=replace(body,old,patched);
  old:='''stream_uids'',coalesce((select jsonb_agg(distinct stream_uid) from public.renders where listing_id=any(listing_ids) and stream_uid is not null),''[]''::jsonb),';
  patched:='''stream_uids'',coalesce((select jsonb_agg(distinct uid)from(select stream_uid uid from public.renders where listing_id=any(listing_ids)and stream_uid is not null union select t.value#>>''{}''from public.privacy_cleanup_jobs j cross join lateral jsonb_array_elements(j.remaining->''stream_uids'')t(value)where j.org_id=any(solo)and j.state in(''pending'',''processing''))streams),''[]''::jsonb),';
  if position(old in body)=0 then raise exception 'RP409: unexpected account video inventory body';end if;
  body:=replace(body,old,patched);execute body;
 end if;
end$$;

create or replace function public.account_cleanup_prefixes_valid(p_original jsonb,p_remaining jsonb)returns boolean
language plpgsql immutable security definer set search_path='' as $$
declare item jsonb;prior jsonb;count numeric;
begin
 if jsonb_typeof(p_original)is distinct from 'array'or jsonb_typeof(p_remaining)is distinct from 'array'or jsonb_array_length(p_remaining)>jsonb_array_length(p_original)then return false;end if;
 if(select count(*)from jsonb_array_elements(p_remaining))<>(select count(distinct value->>'prefix')from jsonb_array_elements(p_remaining))then return false;end if;
 for item in select value from jsonb_array_elements(p_remaining)loop
  if jsonb_typeof(item)is distinct from 'object'or exists(select 1 from jsonb_object_keys(item)k where k not in('bucket','org_id','prefix','removed_count'))then return false;end if;
  select value into prior from jsonb_array_elements(p_original)where value->>'prefix'=item->>'prefix';
  if prior is null or(item-'removed_count')is distinct from(prior-'removed_count')or jsonb_typeof(item->'removed_count')is distinct from 'number'then return false;end if;
  count:=(item->>'removed_count')::numeric;
  if count<>trunc(count)or count<(prior->>'removed_count')::numeric or count>(prior->>'removed_count')::numeric+32 then return false;end if;
 end loop;return true;
end$$;
do $$declare body text;old text;patched text;begin
 body:=pg_get_functiondef('public.finish_account_deletion(uuid,uuid,jsonb,text)'::regprocedure);
 old:='  foreach field in array array[''apple_refresh_token'',''analytics_user_id'',''profile_id'',''auth_user_id''] loop';
 patched:='  if not public.account_cleanup_prefixes_valid(coalesce(r.payload->''r2_prefixes'',''[]''::jsonb),coalesce(p_remaining->''r2_prefixes'',''[]''::jsonb))then raise exception ''RP403: owned output prefixes changed'';end if;'||E'\n'||
  '  if coalesce(p_remaining->''r2_prefixes'',''[]''::jsonb)is distinct from coalesce(r.payload->''r2_prefixes'',''[]''::jsonb)then'||E'\n'||
  '    if r.payload->>''storage_not_before''is not null and(r.payload->>''storage_not_before'')::timestamptz>clock_timestamp()then raise exception ''RP409: owned output writes have not drained'';end if;'||E'\n'||
  '    if jsonb_array_length(r.payload->''unresolved_uploads'')+jsonb_array_length(r.payload->''unresolved_render_jobs'')>0 then raise exception ''RP409: owned output writes need reconciliation'';end if;'||E'\n'||
  '    for target in select value from jsonb_array_elements(r.payload->''provider_leases'')loop if not public.account_deletion_provider_ready((target->>''job_id'')::uuid,(target->>''lease_token'')::uuid)then raise exception ''RP409: owned output provider writes have not drained'';end if;end loop;'||E'\n'||
  '  end if;'||E'\n'||old;
 if position(patched in body)=0 then
  if position(old in body)=0 then raise exception 'RP409: unexpected account cleanup finish body';end if;
  body:=replace(body,old,patched);
  old:='''unresolved_uploads'',''storage_not_before'',''unresolved_render_jobs'']))';
  if position(old in body)=0 then raise exception 'RP409: unknown account cleanup key guard';end if;
  body:=replace(body,old,'''unresolved_uploads'',''storage_not_before'',''unresolved_render_jobs'',''r2_prefixes'']))');
  old:='done:=jsonb_array_length(p_remaining->''r2'')';
  if position(old in body)=0 then raise exception 'RP409: unknown account cleanup completion guard';end if;
  body:=replace(body,old,'done:=jsonb_array_length(coalesce(p_remaining->''r2_prefixes'',''[]''::jsonb))+jsonb_array_length(p_remaining->''r2'')');
  execute body;
 end if;
 body:=pg_get_functiondef('public.finish_account_deletion(uuid,uuid,jsonb,text)'::regprocedure);
 old:='  update public.deletion_requests set payload=p_remaining,status=case when done then''completed''else''pending''end,';
 patched:='  if done then'||E'\n'||
  '    delete from public.private_ai_outputs where org_id in(select value::uuid from jsonb_array_elements_text(r.ownership_scope->''solo_orgs''));'||E'\n'||
  '    update public.privacy_cleanup_jobs set payload=jsonb_build_object(''r2'',''[]''::jsonb,''stream_uids'',''[]''::jsonb,''ghl_targets'',''[]''::jsonb),remaining=jsonb_build_object(''r2'',''[]''::jsonb,''stream_uids'',''[]''::jsonb,''ghl_targets'',''[]''::jsonb),state=''completed'',completed_at=clock_timestamp(),lease_token=null,lease_until=null,last_error=null where org_id in(select value::uuid from jsonb_array_elements_text(r.ownership_scope->''solo_orgs''));'||E'\n'||
  '  end if;'||E'\n'||old;
 if position(patched in body)=0 then
  if position(old in body)=0 then raise exception 'RP409: unexpected account privacy completion body';end if;
  execute replace(body,old,patched);
 end if;
end$$;

revoke execute on function public.register_private_ai_output(uuid,uuid,uuid,text,text,bigint),public.delete_workspace_lead(uuid,uuid,uuid),public.queue_deleted_listing_media(),public.privacy_cleanup_claim(uuid),public.privacy_cleanup_due(),public.privacy_cleanup_finish(uuid,uuid,jsonb,text),public.account_cleanup_prefixes_valid(jsonb,jsonb),public.account_private_output_targets(uuid[],text,text)from public,anon,authenticated;
grant execute on function public.register_private_ai_output(uuid,uuid,uuid,text,text,bigint),public.delete_workspace_lead(uuid,uuid,uuid),public.privacy_cleanup_claim(uuid),public.privacy_cleanup_due(),public.privacy_cleanup_finish(uuid,uuid,jsonb,text),public.account_cleanup_prefixes_valid(jsonb,jsonb),public.account_private_output_targets(uuid[],text,text)to service_role;
commit;
