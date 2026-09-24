-- Durable presenter execution is separate from generic creative dispatch. No
-- runtime is enabled and no price or budget is invented by this migration.
begin;
create or replace function public.studio_presenter_execution_spec() returns jsonb language sql immutable security invoker set search_path='' as $$ select jsonb_build_object('version','presenter-motion-v1','prompt','Replace only the source performer with the approved character reference identity. Preserve the source performance, facial expression, body motion, camera motion, framing, timing, and every property detail. Do not change rooms, architecture, fixtures, furniture, views, lighting, signage, or other people. Do not add, remove, or beautify any property feature.'); $$;
create table if not exists public.studio_presenter_runtime (
 org_id uuid primary key,
 revision integer not null default 1 check(revision>0),
 enabled boolean not null default false,
 enterprise_no_training_confirmed boolean not null default false,
 contract_reference text not null default '',
 price_version text not null default '',
 max_job_cents integer not null default 0 check(max_job_cents>=0),
 total_budget_cents integer not null default 0 check(total_budget_cents>=0)
);
-- Deliberately no identity/org/profile/draft FKs. Deletion must not erase an
-- uncertain paid request, its hold, or its private-object cleanup inventory.
create table if not exists public.studio_presenter_quotes (
 id uuid primary key, org_id uuid not null, listing_id uuid not null,
 actor_id uuid not null, subject_user_id uuid not null, draft_id uuid not null, profile_id uuid not null,
 snapshot jsonb not null, probe jsonb not null, execution_spec jsonb not null default public.studio_presenter_execution_spec(), runtime_revision integer not null,
 price_version text not null, quote_cents integer not null check(quote_cents>0), hold_cents integer not null check(hold_cents>=quote_cents),
 created_at timestamptz not null default clock_timestamp(), expires_at timestamptz not null,
 check(expires_at>created_at and expires_at<=created_at+interval '5 minutes')
);
create table if not exists public.studio_presenter_closed_submissions (
 org_id uuid not null, actor_id uuid not null, listing_id uuid not null,
 idempotency_key uuid not null, quote_id uuid not null, closed_at timestamptz not null default clock_timestamp(),
 primary key(org_id,actor_id,idempotency_key)
);
create table if not exists public.studio_presenter_jobs (
 id uuid primary key default gen_random_uuid(), org_id uuid not null, listing_id uuid not null,
 actor_id uuid not null, subject_user_id uuid not null, author_user_id uuid not null,
 draft_id uuid not null, profile_id uuid not null, draft_revision integer not null, profile_revision integer not null, quote_id uuid not null unique,
 idempotency_key uuid not null, snapshot jsonb, probe jsonb, execution_spec jsonb not null default public.studio_presenter_execution_spec(), runtime_revision integer not null,
 price_version text not null, quote_cents integer not null check(quote_cents>0), hold_cents integer not null check(hold_cents>=quote_cents),
 held_cents integer not null check(held_cents>=0), charged_cents integer check(charged_cents>=0), billing_reference text,
 state text not null check(state in ('reserved','dispatching','uncertain','queued','processing','review','accepted','rejected','importing','imported','cancel_requested','cancelled','failed','invalidated')),
 revision integer not null default 1 check(revision>0),
 dispatch_started_at timestamptz, dispatch_token uuid, provider_terminal_at timestamptz,
 output_lease_token uuid, output_write_deadline timestamptz, cleanup_token uuid, cleanup_deadline timestamptz,
 request_id text, status_url text, response_url text, cancel_url text,
 output_key text not null unique, output_sha256 text, output_bytes bigint, output_duration_s numeric,
 accepted_sha256 text, accepted_at timestamptz,
 import_asset_id uuid, import_storage_key text, provenance_id uuid,
 cancel_requested_at timestamptz, invalidated_at timestamptz,
 cleanup_state text not null default 'none' check(cleanup_state in ('none','pending','done')),
 created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(), last_maintenance_at timestamptz not null default 'epoch',
 unique(org_id,actor_id,idempotency_key),
 check(output_key='presenter-private/'||org_id::text||'/'||id::text||'/output.mp4'),
 check((charged_cents is null) or held_cents=0)
);
create index if not exists studio_presenter_jobs_scope on public.studio_presenter_jobs(org_id,listing_id,created_at desc);
create index if not exists studio_presenter_jobs_subject on public.studio_presenter_jobs(subject_user_id);
create index if not exists studio_presenter_jobs_cleanup on public.studio_presenter_jobs(updated_at) where cleanup_state='pending';
alter table public.capture_assets add column if not exists presenter_job_id uuid references public.studio_presenter_jobs(id);
create unique index if not exists capture_assets_presenter_job on public.capture_assets(presenter_job_id) where presenter_job_id is not null;
alter table public.studio_presenter_runtime enable row level security;
alter table public.studio_presenter_quotes enable row level security;
alter table public.studio_presenter_jobs enable row level security;
alter table public.studio_presenter_closed_submissions enable row level security;
revoke all on public.studio_presenter_runtime,public.studio_presenter_quotes,public.studio_presenter_jobs,public.studio_presenter_closed_submissions from public,anon,authenticated;
grant select,insert,update,delete on public.studio_presenter_runtime,public.studio_presenter_quotes,public.studio_presenter_jobs,public.studio_presenter_closed_submissions to service_role;

create or replace function public.studio_presenter_execution_runtime(p_org_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare r public.studio_presenter_runtime%rowtype; spent bigint; held bigint; ready boolean;
begin
 select * into r from public.studio_presenter_runtime where org_id=p_org_id;
 select coalesce(sum(charged_cents),0),coalesce(sum(held_cents),0) into spent,held from public.studio_presenter_jobs where org_id=p_org_id;
 ready:=coalesce(r.enabled and r.enterprise_no_training_confirmed and length(btrim(r.contract_reference))>0
   and length(btrim(r.price_version))>0 and r.max_job_cents>0 and r.total_budget_cents>0,false);
 return jsonb_build_object('available',ready,'code',case when ready then 'ready' else 'presenter_not_activated' end,
  'reason',case when ready then 'Generation uses this workspace''s approved presenter budget.' else 'AI generation is not activated. A confirmed data agreement, price and workspace budget are required.' end,
  'currency','USD','max_job_cents',coalesce(r.max_job_cents,0),'total_budget_cents',coalesce(r.total_budget_cents,0),'spent_cents',spent,'held_cents',held,'remaining_cents',greatest(0,coalesce(r.total_budget_cents,0)-spent-held),'revision',coalesce(r.revision,0));
end;
$$;
create or replace function public.studio_presenter_execution_member(p_user uuid,p_org uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.users where id=p_user and is_anonymous is false)
  and not exists(select 1 from public.deletion_requests where user_id=p_user and status in ('pending','processing'))
  and exists(select 1 from public.memberships where user_id=p_user and org_id=p_org);
$$;
create or replace function public.studio_presenter_job_valid(j public.studio_presenter_jobs)
returns boolean language plpgsql security invoker set search_path='' as $$
declare d public.studio_presenter_drafts%rowtype; p public.studio_presenter_profiles%rowtype;
begin
 if j.invalidated_at is not null or j.snapshot is null or not public.studio_presenter_execution_member(j.actor_id,j.org_id)
  or not public.studio_presenter_execution_member(j.subject_user_id,j.org_id) or not public.studio_presenter_execution_member(j.author_user_id,j.org_id)
  or not exists(select 1 from public.orgs where id=j.org_id and deleted_at is null)
  or not exists(select 1 from public.listings where id=j.listing_id and org_id=j.org_id and deleted_at is null) then return false; end if;
 select * into d from public.studio_presenter_drafts where id=j.draft_id and org_id=j.org_id and listing_id=j.listing_id;
 select * into p from public.studio_presenter_profiles where id=j.profile_id and org_id=j.org_id;
 return d.id is not null and p.id is not null and p.status='approved' and p.approved_revision=p.revision
  and d.profile_id=p.id and d.profile_revision=p.revision and d.approved_revision=d.revision and d.approved_profile_revision=p.revision
  and d.approval_binding=j.snapshot and j.snapshot->>'draft_revision'=d.revision::text and j.snapshot->>'profile_revision'=p.revision::text
  and d.subject_user_id=j.subject_user_id and p.subject_user_id=j.subject_user_id and d.author_user_id=j.author_user_id
  and j.snapshot->>'title'=d.title and j.snapshot->>'script'=d.script and j.snapshot->>'format'=d.format and j.snapshot->>'resolution'=d.resolution
  and p.reference_snapshot=j.snapshot->'reference_assets'
  and public.studio_presenter_assets(j.org_id,p.source_listing_id,p.reference_asset_ids,'photo')=p.reference_snapshot
  and public.studio_presenter_assets(j.org_id,j.listing_id,array[d.source_asset_id],'video')->0=j.snapshot->'source_asset';
exception when raise_exception then
 if SQLERRM like 'RP422:%' then return false; end if; raise;
end;
$$;
create or replace function public.studio_presenter_asset_access(p_asset uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare a public.capture_assets%rowtype; j public.studio_presenter_jobs%rowtype;
begin
 select * into a from public.capture_assets where id=p_asset;
 if not found then return false; end if;
 if current_setting('role',true)='authenticated' and not public.studio_presenter_execution_member(auth.uid(),(select org_id from public.listings where id=a.listing_id)) then return false; end if;
 if a.presenter_job_id is null then return true; end if;
 select * into j from public.studio_presenter_jobs where id=a.presenter_job_id;
 return j.id is not null and j.state in ('accepted','importing','imported') and j.cancel_requested_at is null
  and j.accepted_sha256=j.output_sha256 and a.sha256=j.accepted_sha256 and a.bytes=j.output_bytes
  and j.import_asset_id=a.id and j.org_id=(select org_id from public.listings where id=a.listing_id)
  and j.listing_id=a.listing_id and public.studio_presenter_job_valid(j);
end;
$$;
-- Generated outputs must never become another person's likeness references or
-- be mistaken for an original source performance.
create or replace function public.studio_presenter_asset_eligible(a public.capture_assets,p_org_id uuid)
returns boolean language sql immutable security invoker set search_path='' as $$
 select coalesce(a.presenter_job_id is null and a.uploaded and a.bucket='uploads' and not a.upload_aborted and a.kind in ('photo','video')
  and a.sha256 ~ '^[0-9a-f]{64}$' and a.bytes>0
  and a.storage_key like 'uploads/'||p_org_id::text||'/'||a.listing_id::text||'/%'
  and a.storage_key not like '%..%' and a.storage_key !~ '[\\?#[:cntrl:]]'
  and (a.kind='photo' or a.duration_s between 4 and 30),false);
$$;
create or replace function public.studio_presenter_job_public(j public.studio_presenter_jobs,p_actor uuid,p_role text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare valid boolean:=public.studio_presenter_job_valid(j); editable boolean:=p_role in ('owner','admin','agent');
begin
 return jsonb_build_object('id',j.id,'org_id',j.org_id,'listing_id',j.listing_id,'draft_id',j.draft_id,'profile_id',j.profile_id,
  'subject_user_id',j.subject_user_id,'requester_user_id',j.actor_id,'revision',j.revision,'state',case when valid or j.state in ('cancelled','failed','rejected') then j.state else 'invalidated' end,
  'status',case when valid or j.state in ('cancelled','failed','rejected') then j.state else 'invalidated' end,'draft_revision',j.draft_revision,'profile_revision',j.profile_revision,
  'quote_id',j.quote_id,'idempotency_key',j.idempotency_key,'quote_cents',j.quote_cents,'max_cost_cents',j.hold_cents,'held_cents',j.held_cents,'charged_cents',j.charged_cents,'currency','USD',
  'output_sha256',case when valid and (p_actor=j.subject_user_id or j.state in ('accepted','importing','imported')) then j.output_sha256 else null end,
  'output_duration_s',case when valid then j.output_duration_s else null end,'asset_id',case when valid and j.state='imported' then j.import_asset_id else null end,
  'imported_asset_id',case when valid and j.state='imported' then j.import_asset_id else null end,
  'output',case when valid and j.output_sha256 is not null and (p_actor=j.subject_user_id or j.state in ('accepted','importing','imported')) then jsonb_build_object('sha256',j.output_sha256,'bytes',j.output_bytes,'duration_s',j.output_duration_s) else null end,
  'created_at',j.created_at,'updated_at',j.updated_at,
  'permissions',jsonb_build_object('can_cancel',editable and valid and j.state in ('reserved','dispatching','uncertain','queued','processing'),
   'can_preview',valid and j.output_sha256 is not null and (j.state='review' and p_actor=j.subject_user_id or j.state in ('accepted','importing','imported')),
   'can_accept',editable and valid and j.state='review' and p_actor=j.subject_user_id,'can_review',editable and valid and j.state='review' and p_actor=j.subject_user_id,
   'can_reject',valid and j.state in ('review','accepted','importing','imported') and p_actor=j.subject_user_id,
   'can_import',editable and valid and j.state in ('accepted','importing','imported')));
end;
$$;
create or replace function public.studio_presenter_invalidate_job(p_job_id uuid)
returns void language plpgsql security invoker set search_path='' as $$
declare j public.studio_presenter_jobs%rowtype;
begin
 select * into j from public.studio_presenter_jobs where id=p_job_id for update;
 if j.id is null or j.invalidated_at is not null then return; end if;
 update public.studio_presenter_jobs set state='invalidated',invalidated_at=clock_timestamp(),cancel_requested_at=coalesce(cancel_requested_at,clock_timestamp()),
  snapshot=null,probe=null,accepted_sha256=null,accepted_at=null,cleanup_state='pending',revision=revision+1,updated_at=clock_timestamp(),
  held_cents=case when dispatch_started_at is null then 0 else held_cents end,
  charged_cents=case when dispatch_started_at is null then 0 else charged_cents end,
  billing_reference=case when dispatch_started_at is null then 'not_dispatched' else billing_reference end where id=j.id;
 -- Keep storage keys and provider request identity in the durable tombstone.
 -- Native renders/reflection work may reference these rows with NO ACTION FKs.
 -- Keep the identity tombstone, deny access through its marker, and remove the
 -- public provenance capability. Storage is deleted by the durable cleanup job.
 update public.media_provenance set altered_key=null where id=j.provenance_id;
end;
$$;
create or replace function public.studio_presenter_execution(p_actor uuid,p_org_id uuid,p_listing_id uuid,p_action text,p_payload jsonb default '{}')
returns jsonb language plpgsql security invoker set search_path='' as $$
declare role_name text; rt jsonb; r public.studio_presenter_runtime%rowtype; q public.studio_presenter_quotes%rowtype; j public.studio_presenter_jobs%rowtype;
 prepared jsonb; d public.studio_presenter_drafts%rowtype; amount integer; v_id uuid; key_id uuid; probe jsonb; jobs jsonb; quotes jsonb; now_at timestamptz:=clock_timestamp();
begin
 role_name:=public.studio_presenter_scope(p_actor,p_org_id,p_listing_id);
 now_at:=clock_timestamp();
 if jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>32768 then raise exception 'RP400: Invalid execution payload'; end if;
 rt:=public.studio_presenter_execution_runtime(p_org_id);
 if p_action in ('quote_prepare','quote_commit') then
  if role_name not in ('owner','admin','agent') then raise exception 'RP403: Your role cannot request presenter generation'; end if;
  if not (rt->>'available')::boolean then raise exception 'RP409: Presenter generation is not activated'; end if;
  prepared:=public.studio_presenter_generation(p_actor,p_org_id,p_listing_id,(p_payload->>'draft_id')::uuid,(p_payload->>'expected_revision')::integer,(p_payload->>'expected_profile_revision')::integer,'prepare');
  select * into r from public.studio_presenter_runtime where org_id=p_org_id for update;
  if p_action='quote_prepare' then return prepared||jsonb_build_object('runtime',rt,'price_version',r.price_version,'max_cost_cents',r.max_job_cents,'execution_spec',public.studio_presenter_execution_spec()); end if;
  if p_payload->'execution_spec' is distinct from public.studio_presenter_execution_spec() then raise exception 'RP409: Presenter execution specification changed'; end if;
  probe:=p_payload->'probe';
  if jsonb_typeof(probe) is distinct from 'object' or probe->>'sha256' is distinct from prepared->'source_asset'->>'sha256'
   or probe->>'bytes' is distinct from prepared->'source_asset'->>'bytes' or coalesce((probe->>'duration_s')::numeric,0) not between 4 and 30 then raise exception 'RP422: A measured source probe bound to the exact original is required'; end if;
  amount:=(p_payload->>'quote_cents')::integer;
  if amount is null or amount<=0 or amount>r.max_job_cents or p_payload->>'price_version' is distinct from r.price_version then raise exception 'RP409: Presenter price changed or exceeds the job limit'; end if;
  v_id:=(p_payload->>'quote_id')::uuid;
  if v_id is null then raise exception 'RP400: A quote ID is required'; end if;
  if exists(select 1 from public.studio_presenter_closed_submissions where org_id=p_org_id and actor_id=p_actor and quote_id=v_id) then raise exception 'RP409: This quote was closed. Get a new quote'; end if;
  insert into public.studio_presenter_quotes(id,org_id,listing_id,actor_id,subject_user_id,draft_id,profile_id,snapshot,probe,runtime_revision,price_version,quote_cents,hold_cents,created_at,expires_at)
   values(v_id,p_org_id,p_listing_id,p_actor,(prepared->'snapshot'->>'subject_user_id')::uuid,(prepared->'snapshot'->>'draft_id')::uuid,(prepared->'snapshot'->>'profile_id')::uuid,prepared->'snapshot',probe,r.revision,r.price_version,amount,r.max_job_cents,now_at,now_at+interval '5 minutes') on conflict(id) do nothing;
  select * into q from public.studio_presenter_quotes where id=v_id;
  if q.actor_id<>p_actor or q.org_id<>p_org_id or q.listing_id<>p_listing_id or q.snapshot is distinct from prepared->'snapshot' or q.probe is distinct from probe or q.quote_cents<>amount or q.price_version<>r.price_version or q.expires_at<=now_at then raise exception 'RP409: Quote ID already belongs to another or expired request'; end if;
  return jsonb_build_object('quote',jsonb_build_object('id',q.id,'draft_id',q.draft_id,'profile_id',q.profile_id,'draft_revision',q.snapshot->'draft_revision','profile_revision',q.snapshot->'profile_revision','quote_cents',q.quote_cents,'max_cost_cents',q.hold_cents,'consumed',false,'currency','USD','expires_at',q.expires_at),'runtime',rt);
 elsif p_action='close_submission' then
  key_id:=(p_payload->>'idempotency_key')::uuid;v_id:=(p_payload->>'quote_id')::uuid;
  if key_id is null or v_id is null then raise exception 'RP400: Quote and request IDs are required'; end if;
  select * into j from public.studio_presenter_jobs where org_id=p_org_id and actor_id=p_actor and (idempotency_key=key_id or quote_id=v_id) for update;
  if found then
   if j.quote_id<>v_id or j.listing_id<>p_listing_id then raise exception 'RP409: Request ID already belongs to another quote'; end if;
   return jsonb_build_object('job',public.studio_presenter_job_public(j,p_actor,role_name),'replayed',true,'runtime',rt);
  end if;
  if exists(select 1 from public.studio_presenter_closed_submissions where org_id=p_org_id and actor_id=p_actor and idempotency_key=key_id and (quote_id<>v_id or listing_id<>p_listing_id)) then raise exception 'RP409: This request key already closed another quote'; end if;
  if exists(select 1 from public.studio_presenter_quotes where id=v_id and (org_id<>p_org_id or actor_id<>p_actor or listing_id<>p_listing_id)) then raise exception 'RP404: Quote is unavailable'; end if;
  insert into public.studio_presenter_closed_submissions(org_id,actor_id,listing_id,idempotency_key,quote_id) values(p_org_id,p_actor,p_listing_id,key_id,v_id) on conflict do nothing;
  delete from public.studio_presenter_quotes where id=v_id and org_id=p_org_id and actor_id=p_actor and listing_id=p_listing_id;
  return jsonb_build_object('closed_submission',jsonb_build_object('quote_id',v_id,'idempotency_key',key_id),'runtime',rt);
 elsif p_action='create' then
  if role_name not in ('owner','admin','agent') then raise exception 'RP403: Your role cannot request presenter generation'; end if;
  key_id:=(p_payload->>'idempotency_key')::uuid;v_id:=(p_payload->>'quote_id')::uuid;
  if key_id is null or v_id is null then raise exception 'RP400: Quote and request IDs are required'; end if;
  select * into j from public.studio_presenter_jobs where org_id=p_org_id and actor_id=p_actor and idempotency_key=key_id for update;
  if found then
   if j.quote_id<>v_id or j.listing_id<>p_listing_id then raise exception 'RP409: Request ID already belongs to another quote'; end if;
   return jsonb_build_object('job',public.studio_presenter_job_public(j,p_actor,role_name),'replayed',true,'runtime',rt);
  end if;
  if exists(select 1 from public.studio_presenter_closed_submissions where org_id=p_org_id and actor_id=p_actor and (idempotency_key=key_id or quote_id=v_id)) then raise exception 'RP409: This submission was closed. Get a fresh quote'; end if;
  select * into q from public.studio_presenter_quotes where id=v_id and org_id=p_org_id and actor_id=p_actor and listing_id=p_listing_id for update;
  if not found or q.expires_at<=now_at then raise exception 'RP409: Get a fresh presenter quote'; end if;
  if p_payload->'cost_consent' is distinct from 'true'::jsonb or (p_payload->>'max_cost_cents')::integer is distinct from q.hold_cents then raise exception 'RP400: Confirm this exact maximum USD cost'; end if;
  if exists(select 1 from public.studio_presenter_jobs where quote_id=q.id) then raise exception 'RP409: This quote already has a durable job'; end if;
  prepared:=public.studio_presenter_generation(p_actor,p_org_id,p_listing_id,q.draft_id,(q.snapshot->>'draft_revision')::integer,(q.snapshot->>'profile_revision')::integer,'prepare');
  if prepared->'snapshot' is distinct from q.snapshot then raise exception 'RP409: Presenter approval changed after this quote'; end if;
  select * into r from public.studio_presenter_runtime where org_id=p_org_id for update;
  if not (public.studio_presenter_execution_runtime(p_org_id)->>'available')::boolean or r.revision<>q.runtime_revision or r.price_version<>q.price_version or q.hold_cents<>r.max_job_cents then raise exception 'RP409: Generation activation or price changed'; end if;
  if (rt->>'remaining_cents')::bigint<q.hold_cents then raise exception 'RP429: Presenter workspace budget is fully reserved'; end if;
  select * into d from public.studio_presenter_drafts where id=q.draft_id;
  v_id:=gen_random_uuid();
  insert into public.studio_presenter_jobs(id,org_id,listing_id,actor_id,subject_user_id,author_user_id,draft_id,profile_id,draft_revision,profile_revision,quote_id,idempotency_key,snapshot,probe,execution_spec,runtime_revision,price_version,quote_cents,hold_cents,held_cents,state,output_key)
   values(v_id,p_org_id,p_listing_id,p_actor,q.subject_user_id,d.author_user_id,q.draft_id,q.profile_id,(q.snapshot->>'draft_revision')::integer,(q.snapshot->>'profile_revision')::integer,q.id,key_id,q.snapshot,q.probe,q.execution_spec,q.runtime_revision,q.price_version,q.quote_cents,q.hold_cents,q.hold_cents,'reserved','presenter-private/'||p_org_id::text||'/'||v_id::text||'/output.mp4') returning * into j;
  return jsonb_build_object('job',public.studio_presenter_job_public(j,p_actor,role_name),'replayed',false,'runtime',public.studio_presenter_execution_runtime(p_org_id));
 elsif p_action='get' then
  delete from public.studio_presenter_quotes where org_id=p_org_id and expires_at<=now_at;
  select coalesce(jsonb_agg(item order by created_at desc),'[]') into jobs from (select public.studio_presenter_job_public(x,p_actor,role_name) item,x.created_at from public.studio_presenter_jobs x where x.org_id=p_org_id and x.listing_id=p_listing_id and (p_payload->>'job_id' is null or x.id=(p_payload->>'job_id')::uuid) order by x.created_at desc limit 100) t;
  select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'draft_id',x.draft_id,'profile_id',x.profile_id,'draft_revision',x.snapshot->'draft_revision','profile_revision',x.snapshot->'profile_revision','quote_cents',x.quote_cents,'max_cost_cents',x.hold_cents,'consumed',false,'currency','USD','expires_at',x.expires_at) order by x.created_at desc),'[]') into quotes from
   (select q0.* from public.studio_presenter_quotes q0 where q0.org_id=p_org_id and q0.listing_id=p_listing_id and q0.actor_id=p_actor and q0.expires_at>now_at and not exists(select 1 from public.studio_presenter_jobs y where y.quote_id=q0.id) order by q0.created_at desc limit 100) x;
  return jsonb_build_object('org_id',p_org_id,'listing_id',p_listing_id,'runtime',rt,'jobs',jobs,'quotes',quotes,'truncated',jsonb_build_object('jobs',(select count(*)>100 from public.studio_presenter_jobs where org_id=p_org_id and listing_id=p_listing_id),'quotes',(select count(*)>100 from public.studio_presenter_quotes q0 where q0.org_id=p_org_id and q0.listing_id=p_listing_id and q0.actor_id=p_actor and q0.expires_at>now_at and not exists(select 1 from public.studio_presenter_jobs y where y.quote_id=q0.id))));
 end if;
 select * into j from public.studio_presenter_jobs where id=(p_payload->>'job_id')::uuid and org_id=p_org_id and listing_id=p_listing_id for update;
 if not found then raise exception 'RP404: Presenter job is unavailable'; end if;
 if not public.studio_presenter_job_valid(j) then raise exception 'RP409: Presenter approval or source identity is no longer current'; end if;
 if p_action='preview' then
  if j.output_sha256 is null or not (j.state='review' and p_actor=j.subject_user_id or j.state in ('accepted','importing','imported')) then raise exception 'RP403: This output is awaiting private subject review'; end if;
  return jsonb_build_object('job',public.studio_presenter_job_public(j,p_actor,role_name),'output_key',j.output_key,'sha256',j.output_sha256,'bytes',j.output_bytes,'duration_s',j.output_duration_s);
 end if;
 if j.revision is distinct from (p_payload->>'expected_revision')::integer then raise exception 'RP409: Presenter job changed. Refresh before continuing'; end if;
 if p_action='cancel' then
  if role_name not in ('owner','admin','agent') then raise exception 'RP403: Your role cannot cancel generation'; end if;
  if j.state not in ('reserved','dispatching','uncertain','queued','processing','cancel_requested') then raise exception 'RP409: This job cannot be cancelled'; end if;
  update public.studio_presenter_jobs set state=case when dispatch_started_at is null then 'cancelled' else 'cancel_requested' end,cancel_requested_at=coalesce(cancel_requested_at,now_at),cleanup_state='pending',
   held_cents=case when dispatch_started_at is null then 0 else held_cents end,charged_cents=case when dispatch_started_at is null then 0 else charged_cents end,billing_reference=case when dispatch_started_at is null then 'not_dispatched' else billing_reference end,revision=revision+1,updated_at=now_at where id=j.id returning * into j;
 elsif p_action in ('accept','reject') then
  if p_actor<>j.subject_user_id then raise exception 'RP403: Only the represented person can approve or reject the generated output'; end if;
  if p_action='accept' then
   if role_name not in ('owner','admin','agent') or j.state<>'review' or p_payload->>'output_sha256' is distinct from j.output_sha256 or p_payload->'output_consent' is distinct from 'true'::jsonb then raise exception 'RP409: Review and approve this exact generated output'; end if;
   update public.studio_presenter_jobs set state='accepted',accepted_sha256=output_sha256,accepted_at=now_at,revision=revision+1,updated_at=now_at where id=j.id returning * into j;
  else
   if j.state not in ('review','accepted','importing','imported') then raise exception 'RP409: This output cannot be rejected'; end if;
   update public.studio_presenter_jobs set state='rejected',accepted_sha256=null,accepted_at=null,cleanup_state='pending',revision=revision+1,updated_at=now_at where id=j.id returning * into j;
   update public.media_provenance set altered_key=null where id=j.provenance_id;
  end if;
 elsif p_action='import_prepare' then
  if role_name not in ('owner','admin','agent') then raise exception 'RP403: Your role cannot import an output'; end if;
  if j.state not in ('accepted','importing','imported') or j.accepted_sha256 is distinct from j.output_sha256 then raise exception 'RP409: Subject approval of this exact output is required'; end if;
  if j.state='accepted' then update public.studio_presenter_jobs set state='importing',revision=revision+1,updated_at=now_at where id=j.id returning * into j; end if;
  return jsonb_build_object('job',public.studio_presenter_job_public(j,p_actor,role_name),'output_key',j.output_key,'sha256',j.output_sha256,'bytes',j.output_bytes,'duration_s',j.output_duration_s,'import_asset_id',j.import_asset_id);
 else raise exception 'RP400: Unsupported execution action';
 end if;
 return jsonb_build_object('job',public.studio_presenter_job_public(j,p_actor,role_name),'runtime',public.studio_presenter_execution_runtime(p_org_id));
exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'RP400: Invalid presenter execution identity or number';
end;
$$;

create or replace function public.studio_presenter_execution_worker(p_job_id uuid,p_action text,p_payload jsonb default '{}')
returns jsonb language plpgsql security invoker set search_path='' as $$
declare j public.studio_presenter_jobs%rowtype; r public.studio_presenter_runtime%rowtype; a public.capture_assets%rowtype;
 org uuid; token uuid; now_at timestamptz:=clock_timestamp(); next_state text; amount integer;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required'; end if;
 if jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>32768 then raise exception 'RP400: Invalid worker payload'; end if;
 if p_action in ('drain','sweep') then
  return public.studio_presenter_execution_due(50);
 end if;
 select org_id into org from public.studio_presenter_jobs where id=p_job_id;
 if org is null then raise exception 'RP404: Presenter job is unavailable'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('studio-presenter:'||org::text,0));
 select * into j from public.studio_presenter_jobs where id=p_job_id for update;
 now_at:=clock_timestamp();
 if not public.studio_presenter_job_valid(j) and j.invalidated_at is null and not (j.cleanup_state='done' and j.state in ('failed','cancelled','rejected')) then
  perform public.studio_presenter_invalidate_job(j.id);
  select * into j from public.studio_presenter_jobs where id=p_job_id;
 end if;
 if p_action in ('get','read','dispatch_prepare') then
  return jsonb_build_object('job',to_jsonb(j),'allowed',j.state='reserved' and j.invalidated_at is null and j.dispatch_started_at is null and (public.studio_presenter_execution_runtime(j.org_id)->>'available')::boolean,'snapshot',j.snapshot,'probe',j.probe,'execution_spec',j.execution_spec,'source_asset',j.snapshot->'source_asset','reference_assets',j.snapshot->'reference_assets','runtime',public.studio_presenter_execution_runtime(j.org_id));
 elsif p_action='dispatch_claim' then
  -- This is an irreversible *permission to POST once*. Expiration, crashes and
  -- HTTP ambiguity never return a request to reserved or issue a second claim.
  if j.state<>'reserved' or j.dispatch_started_at is not null or j.invalidated_at is not null then return jsonb_build_object('claimed',false,'job',to_jsonb(j)); end if;
  select * into r from public.studio_presenter_runtime where org_id=j.org_id for update;
  if not coalesce((public.studio_presenter_execution_runtime(j.org_id)->>'available')::boolean,false) or r.revision<>j.runtime_revision or r.price_version<>j.price_version
   or not exists(select 1 from public.memberships where org_id=j.org_id and user_id=j.actor_id and role in ('owner','admin','agent')) then
   update public.studio_presenter_jobs set state='failed',held_cents=0,charged_cents=0,billing_reference='not_dispatched',revision=revision+1,updated_at=now_at where id=j.id returning * into j;
   return jsonb_build_object('claimed',false,'job',to_jsonb(j));
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('studio-presenter:higgsfield-capacity',0));
  if (select count(*) from public.studio_presenter_jobs where dispatch_started_at is not null and provider_terminal_at is null)>=3 then return jsonb_build_object('claimed',false,'capacity_limited',true,'job',to_jsonb(j)); end if;
  token:=gen_random_uuid();
  update public.studio_presenter_jobs set state='dispatching',dispatch_started_at=now_at,dispatch_token=token,revision=revision+1,updated_at=now_at where id=j.id returning * into j;
  return jsonb_build_object('claimed',true,'dispatch_token',token,'snapshot',j.snapshot,'probe',j.probe,'output_key',j.output_key,'job',to_jsonb(j));
 elsif p_action in ('dispatch_result','ambiguous') then
  if j.dispatch_started_at is null or j.dispatch_token is distinct from (p_payload->>'dispatch_token')::uuid then raise exception 'RP409: This worker did not claim dispatch'; end if;
  if p_action='ambiguous' then
   if j.state='dispatching' then update public.studio_presenter_jobs set state='uncertain',revision=revision+1,updated_at=now_at where id=j.id returning * into j; end if;
  else
   if coalesce(length(p_payload->>'request_id'),0) not between 1 and 200 or coalesce(length(p_payload->>'status_url'),0) not between 10 and 2000 or p_payload->>'status_url' !~ '^https://' or (p_payload->>'response_url' is not null and p_payload->>'response_url' !~ '^https://') or (p_payload->>'cancel_url' is not null and p_payload->>'cancel_url' !~ '^https://') then raise exception 'RP400: Confirmed provider references are required'; end if;
   if j.request_id is not null and (j.request_id is distinct from p_payload->>'request_id' or j.status_url is distinct from p_payload->>'status_url' or j.cancel_url is distinct from p_payload->>'cancel_url' or j.response_url is distinct from p_payload->>'response_url') then raise exception 'RP409: A different provider request is already recorded'; end if;
   if j.request_id is null then
    update public.studio_presenter_jobs set request_id=p_payload->>'request_id',status_url=p_payload->>'status_url',response_url=p_payload->>'response_url',cancel_url=p_payload->>'cancel_url',
     state=case when state in ('dispatching','uncertain') then 'queued' else state end,revision=revision+1,updated_at=now_at where id=j.id returning * into j;
   end if;
  end if;
 elsif p_action='status' then
  next_state:=p_payload->>'state';
  if next_state is null or next_state not in ('queued','processing') or j.request_id is null then raise exception 'RP400: Confirm a known provider job state'; end if;
  if j.state in ('queued','processing') and not (j.state='processing' and next_state='queued') then
   update public.studio_presenter_jobs set state=next_state,revision=revision+case when state=next_state then 0 else 1 end,updated_at=now_at where id=j.id returning * into j;
  end if;
 elsif p_action='completed' then
  if j.request_id is null then raise exception 'RP409: Confirm a known provider request before recording completion'; end if;
  update public.studio_presenter_jobs set provider_terminal_at=coalesce(provider_terminal_at,now_at),
   state=case when state='cancel_requested' then 'cancelled' else state end,
   cleanup_state=case when state in ('cancel_requested','cancelled','invalidated','rejected') then 'pending' else cleanup_state end,
   revision=revision+case when provider_terminal_at is null then 1 else 0 end,updated_at=now_at where id=j.id returning * into j;
 elsif p_action='output_claim' then
  if j.state not in ('queued','processing') or j.request_id is null or j.invalidated_at is not null or j.cancel_requested_at is not null then return jsonb_build_object('claimed',false,'job',to_jsonb(j)); end if;
  if j.output_write_deadline>now_at then return jsonb_build_object('claimed',false,'job',to_jsonb(j)); end if;
  token:=gen_random_uuid();
  update public.studio_presenter_jobs set output_lease_token=token,output_write_deadline=now_at+interval '5 minutes',updated_at=now_at where id=j.id returning * into j;
  return jsonb_build_object('claimed',true,'lease_token',token,'write_deadline',j.output_write_deadline,'output_key',j.output_key,'job',to_jsonb(j));
 elsif p_action='output_ready' then
  if j.output_lease_token is distinct from (p_payload->>'lease_token')::uuid or j.output_write_deadline<=now_at then raise exception 'RP409: Private output write lease expired'; end if;
  if j.state not in ('queued','processing','review') or j.invalidated_at is not null or j.cancel_requested_at is not null then raise exception 'RP409: This job no longer accepts generated output'; end if;
  if coalesce(p_payload->>'sha256','') !~ '^[0-9a-f]{64}$' or coalesce((p_payload->>'bytes')::bigint,0) not between 1 and 50331648 or coalesce((p_payload->>'duration_s')::numeric,0) not between 1 and 31 then raise exception 'RP422: Store a measured bounded MP4 output'; end if;
  if j.output_sha256 is not null and (j.output_sha256 is distinct from p_payload->>'sha256' or j.output_bytes is distinct from (p_payload->>'bytes')::bigint or j.output_duration_s is distinct from (p_payload->>'duration_s')::numeric) then raise exception 'RP409: Generated output bytes are immutable'; end if;
  if j.output_sha256 is null then
   update public.studio_presenter_jobs set output_sha256=p_payload->>'sha256',output_bytes=(p_payload->>'bytes')::bigint,output_duration_s=(p_payload->>'duration_s')::numeric,provider_terminal_at=now_at,state='review',revision=revision+1,updated_at=now_at where id=j.id returning * into j;
  end if;
 elsif p_action in ('settle','failed','cancelled') then
  if p_action<>'settle' and j.state not in ('dispatching','uncertain','queued','processing','cancel_requested','invalidated',p_action) then raise exception 'RP409: This terminal state cannot replace the saved output'; end if;
  if p_payload->'billing_final'='true'::jsonb then
   amount:=(p_payload->>'charged_cents')::integer;
   if amount is null or amount<0 or coalesce(length(btrim(p_payload->>'billing_reference')),0) not between 1 and 200 then raise exception 'RP400: Confirmed final billing evidence is required'; end if;
   if j.charged_cents is not null and (j.charged_cents<>amount or j.billing_reference is distinct from p_payload->>'billing_reference') then raise exception 'RP409: Final billing evidence is immutable'; end if;
   update public.studio_presenter_jobs set charged_cents=amount,held_cents=0,billing_reference=p_payload->>'billing_reference',updated_at=now_at where id=j.id returning * into j;
   if amount>j.hold_cents then update public.studio_presenter_runtime set enabled=false,revision=revision+1 where org_id=j.org_id and enabled; end if;
  elsif p_action='settle' then raise exception 'RP400: Unconfirmed costs remain held'; end if;
  if p_action<>'settle' then
   update public.studio_presenter_jobs set provider_terminal_at=coalesce(provider_terminal_at,now_at) where id=j.id returning * into j;
  end if;
  if p_action<>'settle' and j.state<>'invalidated' then
   update public.studio_presenter_jobs set state=p_action,cleanup_state='pending',revision=revision+1,updated_at=now_at where id=j.id returning * into j;
  end if;
 elsif p_action='import_bind' then
  if j.state<>'importing' or j.accepted_sha256 is distinct from j.output_sha256 or j.invalidated_at is not null then raise exception 'RP409: The output is not approved for import'; end if;
  if j.import_asset_id is not null then
   if j.import_asset_id::text is distinct from p_payload->>'asset_id' then raise exception 'RP409: Resume the existing output import'; end if;
  else
   select * into a from public.capture_assets where id=(p_payload->>'asset_id')::uuid and listing_id=j.listing_id for update;
   if not found or a.uploaded or a.upload_aborted or a.kind<>'video' or a.bucket<>'renders' or a.bytes<>j.output_bytes or a.content_type<>'video/mp4' or a.presenter_job_id is not null
    or not exists(select 1 from public.upload_reservations u where u.asset_id=a.id and u.org_id=j.org_id and u.state='open' and u.expires_at>now_at) then raise exception 'RP409: Reserve the exact output through the existing upload quota flow'; end if;
   update public.studio_presenter_jobs set import_asset_id=a.id,import_storage_key=a.storage_key,revision=revision+1,updated_at=now_at where id=j.id returning * into j;
   update public.capture_assets set presenter_job_id=j.id,sha256=j.output_sha256 where id=a.id;
  end if;
 elsif p_action='import_commit' then
  if j.state not in ('importing','imported') or not public.studio_presenter_asset_access(j.import_asset_id) then raise exception 'RP409: Approved output import is unavailable'; end if;
  select * into a from public.capture_assets where id=j.import_asset_id;
  if not a.uploaded or j.provenance_id is null or not exists(select 1 from public.media_provenance where id=j.provenance_id and altered_key=a.storage_key) then raise exception 'RP409: Confirm exact output upload and disclosure before importing'; end if;
  if j.state='importing' then update public.studio_presenter_jobs set state='imported',revision=revision+1,updated_at=now_at where id=j.id returning * into j; end if;
 elsif p_action in ('cleanup','cleanup_claim') then
  if j.cleanup_state<>'pending' or j.cleanup_deadline>now_at or coalesce(j.output_write_deadline,now_at-interval '2 minutes')+interval '1 minute'>now_at then return jsonb_build_object('claimed',false,'job',to_jsonb(j)); end if;
  token:=gen_random_uuid();
  update public.studio_presenter_jobs set cleanup_token=token,cleanup_deadline=now_at+interval '5 minutes' where id=j.id returning * into j;
  return jsonb_build_object('claimed',true,'cleanup_token',token,'targets',jsonb_build_array(jsonb_build_object('bucket','uploads','key',j.output_key))||case when j.import_storage_key is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('bucket','renders','key',j.import_storage_key)) end,'request_id',j.request_id,'cancel_url',j.cancel_url,'job',to_jsonb(j));
 elsif p_action in ('cleanup_complete','cleanup_done') then
  if j.cleanup_state<>'pending' or j.cleanup_token is distinct from (p_payload->>'cleanup_token')::uuid or j.cleanup_deadline<=now_at or coalesce(j.output_write_deadline,now_at-interval '2 minutes')+interval '1 minute'>now_at or p_payload->'objects_deleted' is distinct from 'true'::jsonb then raise exception 'RP409: Cleanup must wait for all private writes and confirm object deletion'; end if;
  update public.studio_presenter_jobs set cleanup_state='done',snapshot=null,probe=null,updated_at=now_at where id=j.id returning * into j;
 else raise exception 'RP400: Unsupported presenter worker action'; end if;
 return jsonb_build_object('job',to_jsonb(j));
exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'RP400: Invalid presenter worker identity or number';
end;
$$;

create or replace function public.studio_presenter_execution_due(p_limit integer default 50)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required'; end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'RP400: Choose a bounded maintenance batch'; end if;
 delete from public.studio_presenter_quotes where expires_at<=clock_timestamp();
 update public.studio_presenter_jobs set state='uncertain',revision=revision+1,updated_at=clock_timestamp() where state='dispatching' and dispatch_started_at<clock_timestamp()-interval '2 minutes';
 with due as (select id from public.studio_presenter_jobs where state in ('reserved','dispatching','uncertain','queued','processing','cancel_requested') or cleanup_state='pending'
   or (request_id is not null and provider_terminal_at is null) order by last_maintenance_at,updated_at,id limit p_limit for update skip locked),
 touched as (update public.studio_presenter_jobs j set last_maintenance_at=clock_timestamp() from due where j.id=due.id returning j.id,j.state,j.cleanup_state)
 select jsonb_build_object('jobs',coalesce(jsonb_agg(jsonb_build_object('id',id,'state',state,'cleanup_state',cleanup_state)),'[]')) into result from touched;
 return result;
end;
$$;

create or replace function public.guard_presenter_runtime_revision()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if new is distinct from old then new.revision:=old.revision+1; end if;
 return new;
end;
$$;
drop trigger if exists trg_presenter_runtime_revision on public.studio_presenter_runtime;
create trigger trg_presenter_runtime_revision before update on public.studio_presenter_runtime for each row execute function public.guard_presenter_runtime_revision();

create or replace function public.guard_presenter_publication()
returns trigger language plpgsql security invoker set search_path='' as $$
declare j public.studio_presenter_jobs%rowtype; proof uuid;
begin
 if old.presenter_job_id is not null and new.presenter_job_id is distinct from old.presenter_job_id then raise exception 'RP409: Presenter output identity cannot be removed'; end if;
 if new.presenter_job_id is null then return new; end if;
 select * into j from public.studio_presenter_jobs where id=new.presenter_job_id for update;
 if not found or j.state not in ('importing','imported') or j.import_asset_id<>new.id or j.listing_id<>new.listing_id or j.accepted_sha256 is distinct from new.sha256 or j.output_bytes<>new.bytes or new.kind<>'video' or new.bucket<>'renders' or not public.studio_presenter_job_valid(j) then raise exception 'RP409: Presenter output no longer has approval for these exact bytes'; end if;
 if not old.uploaded and new.uploaded then
  if new.content_type<>'video/mp4' then raise exception 'RP409: Presenter output must remain MP4'; end if;
  proof:=coalesce(j.provenance_id,gen_random_uuid());
  insert into public.media_provenance(id,org_id,listing_id,kind,label,model_id,edit,disclosure,altered_key)
   values(proof,j.org_id,j.listing_id,'other','AI Presenter','higgsfield/genjutsu/motion-transfer','agent_presenter','This video contains an AI-generated representation of the agent, approved by the represented person. The video uses a source performance and approved reference images. The represented person reviewed the generated output.',new.storage_key)
   on conflict(id) do nothing;
  update public.studio_presenter_jobs set provenance_id=proof,import_storage_key=new.storage_key,updated_at=clock_timestamp() where id=j.id;
 end if;
 return new;
end;
$$;
drop trigger if exists trg_presenter_publication on public.capture_assets;
create trigger trg_presenter_publication before update on public.capture_assets for each row execute function public.guard_presenter_publication();

-- Narrow restrictive policy adds privacy to existing tenant membership policies.
-- The definer exposes only a boolean and checks the authenticated caller before
-- reading private rows. Service paths must invoke the same predicate explicitly.
drop policy if exists presenter_approved_read on public.capture_assets;
create policy presenter_approved_read on public.capture_assets as restrictive for select to authenticated
 using(presenter_job_id is null or public.studio_presenter_asset_access(id));

create or replace function public.studio_presenter_execution_invalidate()
returns trigger language plpgsql security definer set search_path='' as $$
declare j record; old_data jsonb:=case when tg_op='INSERT' then to_jsonb(new) else to_jsonb(old) end; new_data jsonb:=case when tg_op='DELETE' then null else to_jsonb(new) end; ident uuid;
begin
 ident:=coalesce((old_data->>'id')::uuid,(old_data->>'user_id')::uuid);
 if tg_table_name='studio_presenter_profiles' and tg_op='UPDATE' and new_data->'revision'=old_data->'revision' then return new; end if;
 if tg_table_name='studio_presenter_drafts' and tg_op='UPDATE' and new_data->'revision'=old_data->'revision' then return new; end if;
 if tg_table_name='capture_assets' and tg_op='UPDATE' and (old_data->'sha256',old_data->'bytes',old_data->'storage_key',old_data->'bucket',old_data->'uploaded',old_data->'upload_aborted',old_data->'duration_s') is not distinct from (new_data->'sha256',new_data->'bytes',new_data->'storage_key',new_data->'bucket',new_data->'uploaded',new_data->'upload_aborted',new_data->'duration_s') then return new; end if;
 if tg_table_name in ('orgs','listings') and tg_op='UPDATE' and old_data->'deleted_at' is not distinct from new_data->'deleted_at' then return new; end if;
 if tg_table_name='users' and tg_op='UPDATE' and old_data->'is_anonymous' is not distinct from new_data->'is_anonymous' then return new; end if;
 if tg_table_name='deletion_requests' and (new_data->>'status') not in ('pending','processing') then return new; end if;
 for j in select x.id from public.studio_presenter_jobs x where x.invalidated_at is null and (
  (tg_table_name='studio_presenter_profiles' and x.profile_id=ident) or (tg_table_name='studio_presenter_drafts' and x.draft_id=ident) or
  (tg_table_name='users' and ident in (x.actor_id,x.subject_user_id,x.author_user_id)) or
  (tg_table_name in ('memberships','deletion_requests') and (old_data->>'user_id')::uuid in (x.actor_id,x.subject_user_id,x.author_user_id) and (tg_table_name='deletion_requests' or x.org_id=(old_data->>'org_id')::uuid)) or
  (tg_table_name='orgs' and x.org_id=ident) or (tg_table_name='listings' and (x.listing_id=ident or x.snapshot->'reference_assets'->0->>'listing_id'=ident::text)) or
  (tg_table_name='capture_assets' and ((tg_op='DELETE' and x.import_asset_id=ident) or x.snapshot->'source_asset'->>'id'=ident::text or exists(select 1 from jsonb_array_elements(x.snapshot->'reference_assets') a where a->>'id'=ident::text))))
 loop perform public.studio_presenter_invalidate_job(j.id); end loop;
 -- Quotes are expendable private snapshots; no hold exists before job creation.
 delete from public.studio_presenter_quotes q where
  (tg_table_name='studio_presenter_profiles' and q.profile_id=ident) or (tg_table_name='studio_presenter_drafts' and q.draft_id=ident) or
  (tg_table_name='users' and ident in (q.actor_id,q.subject_user_id)) or
  (tg_table_name in ('memberships','deletion_requests') and (old_data->>'user_id')::uuid in (q.actor_id,q.subject_user_id)) or
  (tg_table_name='orgs' and q.org_id=ident) or (tg_table_name='listings' and (q.listing_id=ident or q.snapshot->'reference_assets'->0->>'listing_id'=ident::text)) or
  (tg_table_name='capture_assets' and (q.snapshot->'source_asset'->>'id'=ident::text or exists(select 1 from jsonb_array_elements(q.snapshot->'reference_assets') a where a->>'id'=ident::text)));
 return case when tg_op='DELETE' then old else new end;
end;
$$;
do $$ declare t text; begin
 foreach t in array array['studio_presenter_profiles','studio_presenter_drafts','capture_assets','listings','orgs','memberships'] loop
  execute format('drop trigger if exists trg_presenter_execution_invalidate on public.%I',t);
  execute format('create trigger trg_presenter_execution_invalidate after update or delete on public.%I for each row execute function public.studio_presenter_execution_invalidate()',t);
 end loop;
end $$;
drop trigger if exists trg_presenter_execution_invalidate on auth.users;
create trigger trg_presenter_execution_invalidate after update or delete on auth.users for each row execute function public.studio_presenter_execution_invalidate();
drop trigger if exists trg_presenter_execution_invalidate on public.deletion_requests;
create trigger trg_presenter_execution_invalidate after insert or update on public.deletion_requests for each row execute function public.studio_presenter_execution_invalidate();

-- Preserve the existing generation quality logic and add the marker gate once.
do $$ begin
 if to_regprocedure('public.assert_studio_asset_quality_before_presenter(uuid)') is null then
  alter function public.assert_studio_asset_quality(uuid) rename to assert_studio_asset_quality_before_presenter;
 end if;
end $$;
create or replace function public.assert_studio_asset_quality(p_asset uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.capture_assets where id=p_asset and presenter_job_id is not null) and not public.studio_presenter_asset_access(p_asset) then raise exception 'RP409: This presenter output is not currently approved for publication'; end if;
 perform public.assert_studio_asset_quality_before_presenter(p_asset);
end;
$$;
revoke all on function public.assert_studio_asset_quality(uuid),public.assert_studio_asset_quality_before_presenter(uuid) from public,anon,authenticated;
revoke all on function public.studio_presenter_execution_runtime(uuid),public.studio_presenter_execution_member(uuid,uuid),public.studio_presenter_job_valid(public.studio_presenter_jobs),public.studio_presenter_job_public(public.studio_presenter_jobs,uuid,text),public.studio_presenter_invalidate_job(uuid),public.studio_presenter_execution(uuid,uuid,uuid,text,jsonb),public.studio_presenter_execution_worker(uuid,text,jsonb),public.guard_presenter_publication(),public.studio_presenter_execution_invalidate(),public.studio_presenter_asset_access(uuid) from public,anon,authenticated;
grant execute on function public.studio_presenter_execution_runtime(uuid),public.studio_presenter_execution_member(uuid,uuid),public.studio_presenter_job_valid(public.studio_presenter_jobs),public.studio_presenter_job_public(public.studio_presenter_jobs,uuid,text),public.studio_presenter_invalidate_job(uuid),public.studio_presenter_execution(uuid,uuid,uuid,text,jsonb),public.studio_presenter_execution_worker(uuid,text,jsonb),public.studio_presenter_asset_access(uuid),public.assert_studio_asset_quality(uuid) to service_role;
grant execute on function public.studio_presenter_asset_access(uuid) to authenticated;
revoke all on function public.studio_presenter_execution_due(integer),public.guard_presenter_runtime_revision() from public,anon,authenticated;
grant execute on function public.studio_presenter_execution_due(integer) to service_role;
revoke all on function public.studio_presenter_execution_spec() from public,anon,authenticated;
grant execute on function public.studio_presenter_execution_spec() to service_role;
commit;
