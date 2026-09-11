-- CLI scaffold: supabase migration new spatial_jobs; 0040 is the reserved repo
-- sequence (0039 belongs to deletion). This file does not enable GPU spending.
create table if not exists public.spatial_runtime (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  daily_budget_cents integer not null default 0 check (daily_budget_cents between 0 and 100000),
  org_monthly_budget_cents integer not null default 0 check (org_monthly_budget_cents between 0 and 100000),
  job_cap_cents integer not null default 600 check (job_cap_cents between 600 and 600),
  -- This first deployment profile includes dependency compilation. A smaller
  -- lifetime needs a measured/prebuilt profile, not a knob that always fails
  -- the provider's 2400s remaining-lifetime admission after image transfer.
  max_seconds integer not null default 7200 check (max_seconds = 7200),
  max_training_seconds integer not null default 900 check (max_training_seconds between 1 and 1800),
  max_iterations integer not null default 3000 check (max_iterations between 100 and 7000),
  max_gaussians integer not null default 500000 check (max_gaussians between 1000 and 500000)
);
insert into public.spatial_runtime(singleton) values(true) on conflict do nothing;
-- No cascading foreign keys: output/upload identities must survive a listing
-- deletion until external cleanup is confirmed. Reads always join live ownership.
create table if not exists public.spatial_jobs (
  id uuid primary key default gen_random_uuid(), org_id uuid not null, listing_id uuid not null,
  actor_id uuid not null, origin_actor_id uuid, capture_id uuid not null, idem_key uuid not null,
  room_label text not null check (length(room_label) between 1 and 80),
  capture_manifest jsonb not null check (octet_length(capture_manifest::text) <= 65536),
  status text not null default 'uploading' check (status in ('uploading','queued','processing','review','ready','failed')),
  attempt_number integer not null default 1 check (attempt_number between 1 and 3),
  attempt_key uuid not null default gen_random_uuid(), reserved_at timestamptz,
  inputs_complete boolean not null default false, provider_stopped boolean not null default false,
  progress numeric not null default 0 check (progress between 0 and 1), failure_code text,
  max_cost_cents integer, max_seconds integer, max_training_seconds integer, max_iterations integer, max_gaussians integer,
  cost_cents integer not null default 0 check (cost_cents >= 0),
  lease_token uuid, worker_id uuid, lease_expires_at timestamptz, deadline_at timestamptz,
  started_at timestamptz, artifact_revision uuid, output_key text,
  output_bytes integer check (output_bytes between 1 and 33554432), output_sha256 text,
  output_state text check (output_state in ('planned','dispatching','stored')),
  output_etag text, scene_manifest jsonb,
  review_revision uuid, reviewed_by uuid, approved boolean not null default false,
  excluded boolean not null default false, redactions jsonb not null default '[]',
  published_at timestamptz,
  created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
  unique(listing_id,idem_key), unique(listing_id,capture_id)
);
create table if not exists public.spatial_inputs (
  job_id uuid not null references public.spatial_jobs(id), relative_path text not null,
  ticket_id uuid not null, storage_key text not null, bytes bigint not null,
  frame jsonb not null check (octet_length(frame::text) <= 1048576),
  primary key(job_id,relative_path), unique(job_id,ticket_id),
  check (relative_path ~ '^images/[0-9]{6}\.jpg$'), check (bytes between 1 and 33554432)
);
create table if not exists public.spatial_budget_windows (
  scope text not null, window_start date not null, committed_cents integer not null default 0 check(committed_cents >= 0),
  primary key(scope,window_start)
);
-- Retry keeps the same capture/job identity but never erases a prior provider
-- lease or object key. Cleanup and billing reconciliation consume this history.
create table if not exists public.spatial_attempt_history (
  job_id uuid not null references public.spatial_jobs(id), attempt_key uuid not null,
  attempt_number integer not null check (attempt_number between 1 and 3),
  snapshot jsonb not null, archived_at timestamptz not null default clock_timestamp(),
  primary key(job_id,attempt_key), unique(job_id,attempt_number)
);
create index if not exists idx_spatial_listing on public.spatial_jobs(listing_id,created_at desc);
create index if not exists idx_spatial_queue on public.spatial_jobs(created_at) where status='queued';
create index if not exists idx_spatial_leases on public.spatial_jobs(lease_expires_at) where status='processing';
alter table public.spatial_runtime enable row level security;
alter table public.spatial_jobs enable row level security;
alter table public.spatial_inputs enable row level security;
alter table public.spatial_budget_windows enable row level security;
alter table public.spatial_attempt_history enable row level security;
revoke all on public.spatial_runtime,public.spatial_jobs,public.spatial_inputs,public.spatial_budget_windows from public,anon,authenticated;
grant select,insert,update on public.spatial_runtime,public.spatial_jobs,public.spatial_inputs,public.spatial_budget_windows to service_role;
revoke all on public.spatial_attempt_history from public,anon,authenticated;
grant select,insert on public.spatial_attempt_history to service_role;

-- 0038 changes listing attribution under Auth/profile/org/listing locks. Carry
-- pending and running spatial ownership through that same transaction, or a
-- successful anonymous-to-Apple handoff would strand an already paid GPU lease.
create or replace function public.spatial_follow_listing_owner() returns trigger
language plpgsql security definer set search_path='' as $$ begin
  if new.agent_id is distinct from old.agent_id then
    update public.spatial_jobs set actor_id=new.agent_id,updated_at=clock_timestamp()
      where listing_id=new.id and org_id=new.org_id and actor_id=old.agent_id;
  end if;
  return new;
end $$;
drop trigger if exists spatial_follow_listing_owner on public.listings;
create trigger spatial_follow_listing_owner after update of agent_id on public.listings
for each row execute function public.spatial_follow_listing_owner();

create or replace function public.spatial_service_only() returns void
language plpgsql security invoker set search_path=public as $$ begin
  if current_user <> 'service_role' then raise exception 'RP403: spatial service role required'; end if;
end $$;

-- Matches adoption/deletion order: actor profile, org, listing, job. Membership
-- is read under the same org lock that removal/adoption must acquire.
create or replace function public.spatial_access(p_actor uuid,p_listing uuid,p_write boolean default true)
returns uuid language plpgsql security invoker set search_path=public as $$
declare o uuid;
begin
  perform spatial_service_only();
  perform 1 from profiles where id=p_actor for update;
  if not found or exists
    (select 1 from deletion_requests where user_id=p_actor and status <> 'completed') then
    raise exception 'RP403: workspace is unavailable'; end if;
  select org_id into o from listings where id=p_listing;
  perform 1 from orgs where id=o and deleted_at is null for update;
  if not found then raise exception 'RP404: home not found'; end if;
  perform 1 from listings where id=p_listing and org_id=o and deleted_at is null for update;
  if not found or not exists(select 1 from memberships where org_id=o and user_id=p_actor
    and (not p_write or role in ('owner','admin','agent'))) then raise exception 'RP403: home is not accessible'; end if;
  return o;
end $$;

create or replace function public.spatial_create(p_actor uuid,p_listing uuid,p_capture uuid,p_idem uuid,p_label text,p_manifest jsonb)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare o uuid; j spatial_jobs; n integer;
begin
  o:=spatial_access(p_actor,p_listing);
  if p_capture is null or p_idem is null or p_label is null or length(trim(p_label)) not between 1 and 80 or p_label ~ '[[:cntrl:]]'
    or jsonb_typeof(p_manifest) is distinct from 'object' or octet_length(p_manifest::text)>65536
    or p_manifest->>'status' is distinct from 'complete' or p_manifest->>'session_id' is distinct from p_capture::text
    or jsonb_typeof(p_manifest->'frames') is distinct from 'array' then raise exception 'RP400: invalid completed capture'; end if;
  n:=jsonb_array_length(p_manifest->'frames');
  if n not between 20 and 400 or (select count(distinct value) from jsonb_array_elements_text(p_manifest->'frames'))<>n
    then raise exception 'RP400: capture requires 20..400 unique frames'; end if;
  select * into j from spatial_jobs where listing_id=p_listing and (idem_key=p_idem or capture_id=p_capture);
  if j.id is not null then
    if j.capture_id<>p_capture or j.capture_manifest<>p_manifest or j.room_label<>trim(p_label) then
      raise exception 'RP409: capture replay does not match the saved job'; end if;
    return to_jsonb(j);
  end if;
  if (select count(*) from spatial_jobs where org_id=o and status in ('uploading','queued','processing')) >= 3 then
    raise exception 'RP429: finish an existing room before starting another'; end if;
  insert into spatial_jobs(org_id,listing_id,actor_id,origin_actor_id,capture_id,idem_key,attempt_key,room_label,capture_manifest)
    values(o,p_listing,p_actor,p_actor,p_capture,p_idem,p_idem,trim(p_label),p_manifest) returning * into j;
  return to_jsonb(j);
end $$;

create or replace function public.spatial_attach_inputs(p_actor uuid,p_job uuid,p_files jsonb)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare j spatial_jobs; f jsonb; a capture_assets; existing spatial_inputs; listing uuid; expected text;
begin
  select listing_id into listing from spatial_jobs where id=p_job;
  perform spatial_access(p_actor,listing);
  select * into strict j from spatial_jobs where id=p_job for update;
  if j.org_id is distinct from (select org_id from listings where id=j.listing_id) then raise exception 'RP403: room workspace changed'; end if;
  if j.status<>'uploading' then raise exception 'RP409: inputs are already frozen'; end if;
  if jsonb_typeof(p_files) is distinct from 'array' or jsonb_array_length(p_files) not between 1 and 16 then
    raise exception 'RP400: expected 1..16 input frames'; end if;
  for f in select value from jsonb_array_elements(p_files) loop
    expected:=replace(f->>'relative_path','images/','frames/'); expected:=replace(expected,'.jpg','.json');
    if f->>'relative_path' !~ '^images/[0-9]{6}\.jpg$' or not (j.capture_manifest->'frames' ? expected)
      or jsonb_typeof(f->'frame') is distinct from 'object'
      or f->'frame'->>'session_id' is distinct from j.capture_id::text
      or f->'frame'->>'image' is distinct from f->>'relative_path'
      or f->'frame'->'tracking_state'->>'state' is distinct from 'normal' then raise exception 'RP400: frame does not match capture'; end if;
    select * into a from capture_assets where id=(f->>'ticket_id')::uuid for update;
    if a.id is null or a.listing_id<>j.listing_id or a.transport_version<>2 or not a.uploaded or a.upload_aborted
      or a.kind<>'photo' or a.bucket<>'uploads' or a.content_type<>'image/jpeg'
      or a.bytes not between 1 and 33554432 or not exists(select 1 from upload_reservations
        where asset_id=a.id and org_id=j.org_id and state='completed') then
      raise exception 'RP409: image needs a completed private upload ticket'; end if;
    select * into existing from spatial_inputs where job_id=p_job and relative_path=f->>'relative_path';
    if existing.job_id is not null then
      if existing.ticket_id<>a.id or existing.frame<>f->'frame' or existing.storage_key<>a.storage_key then
        raise exception 'RP409: input replay differs'; end if;
    else
      insert into spatial_inputs(job_id,relative_path,ticket_id,storage_key,bytes,frame)
        values(p_job,f->>'relative_path',a.id,a.storage_key,a.bytes,f->'frame');
    end if;
  end loop;
  if (select coalesce(sum(bytes),0) from spatial_inputs where job_id=p_job)>2147483648 then raise exception 'RP400: room exceeds 2 GiB'; end if;
  if (select coalesce(sum(octet_length(frame::text)),0) from spatial_inputs where job_id=p_job)>16777216 then raise exception 'RP400: room metadata exceeds 16 MiB'; end if;
  update spatial_jobs set progress=0.25*(select count(*)::numeric from spatial_inputs where job_id=p_job)/jsonb_array_length(capture_manifest->'frames'),
    updated_at=clock_timestamp() where id=p_job returning * into j;
  return to_jsonb(j);
end $$;

create or replace function public.spatial_start(p_actor uuid,p_job uuid) returns jsonb
language plpgsql security invoker set search_path=public as $$
declare j spatial_jobs; c spatial_runtime; l uuid; day date:=(clock_timestamp() at time zone 'UTC')::date; month date; orgscope text;
begin
  select listing_id into l from spatial_jobs where id=p_job; perform spatial_access(p_actor,l);
  select * into strict j from spatial_jobs where id=p_job for update;
  if j.org_id is distinct from (select org_id from listings where id=j.listing_id) then raise exception 'RP403: room workspace changed'; end if;
  if j.status in ('queued','processing','review','ready') then return to_jsonb(j); end if;
  if j.status<>'uploading' then raise exception 'RP409: use the explicit retry action for a failed generation'; end if;
  if (select count(*) from spatial_inputs where job_id=p_job)<>jsonb_array_length(j.capture_manifest->'frames') then
    raise exception 'RP409: finish uploading every capture frame'; end if;
  if (select sum(bytes) from spatial_inputs where job_id=p_job) is distinct from (j.capture_manifest->>'image_bytes')::bigint
    or exists(select 1 from (select (frame->>'timestamp')::double precision as t,
      lag((frame->>'timestamp')::double precision) over(order by relative_path) as prior
      from spatial_inputs where job_id=p_job) ordered where t is null or t<0 or t<=prior)
    or (select coalesce(sum(jsonb_array_length(frame->'raw_feature_points')),0) from spatial_inputs where job_id=p_job)=0 then
    raise exception 'RP400: image byte total, frame times or measured point coverage does not match capture'; end if;
  if exists(select 1 from spatial_inputs i left join capture_assets a on a.id=i.ticket_id
    where i.job_id=p_job and (a.id is null or not a.uploaded or a.upload_aborted or a.storage_key<>i.storage_key)) then
    raise exception 'RP409: capture input is no longer available'; end if;
  select * into strict c from spatial_runtime where singleton for update;
  if not c.enabled or c.daily_budget_cents=0 or c.org_monthly_budget_cents=0 then
    raise exception 'RP503: 3D generation is not configured yet; your capture is saved'; end if;
  if j.reserved_at is not null then
    -- Cancelling a queued job retains its undispatched authority. Resuming that
    -- same attempt must not charge twice just because it paused before a claim.
    if j.started_at is not null then raise exception 'RP409: a dispatched attempt cannot reuse a reservation'; end if;
    update spatial_jobs set status='queued',progress=0.25,inputs_complete=true,updated_at=clock_timestamp()
      where id=p_job returning * into j;
    return to_jsonb(j);
  end if;
  month:=date_trunc('month',day)::date; orgscope:='org:'||j.org_id;
  insert into spatial_budget_windows(scope,window_start) values('global',day),(orgscope,month) on conflict do nothing;
  perform 1 from spatial_budget_windows where (scope='global' and window_start=day) or (scope=orgscope and window_start=month)
    order by scope,window_start for update;
  if (select committed_cents from spatial_budget_windows where scope='global' and window_start=day)+c.job_cap_cents>c.daily_budget_cents
    or (select committed_cents from spatial_budget_windows where scope=orgscope and window_start=month)+c.job_cap_cents>c.org_monthly_budget_cents then
    raise exception 'RP429: 3D generation capacity is reached; your capture is saved'; end if;
  -- Worst-case authority is consumed once on queue, never refunded on ambiguous
  -- provider outcomes. Retries of /start cannot mint another paid attempt.
  update spatial_budget_windows set committed_cents=committed_cents+c.job_cap_cents
    where (scope='global' and window_start=day) or (scope=orgscope and window_start=month);
  update spatial_jobs set status='queued',progress=0.25,inputs_complete=true,reserved_at=clock_timestamp(),max_cost_cents=c.job_cap_cents,max_seconds=c.max_seconds,
    max_training_seconds=c.max_training_seconds,max_iterations=c.max_iterations,max_gaussians=c.max_gaussians,updated_at=clock_timestamp() where id=p_job returning * into j;
  return to_jsonb(j);
end $$;

create or replace function public.spatial_expire(p_listing uuid default null) returns integer
language plpgsql security invoker set search_path=public as $$
declare n integer;
begin
  perform spatial_service_only();
  -- Separate short transaction: never take a job lock and then an ownership
  -- lock, which would invert the upload/adoption lock order.
  update spatial_jobs set status='failed',failure_code='worker_lease_expired',updated_at=clock_timestamp()
    where status='processing' and (p_listing is null or listing_id=p_listing)
      and (lease_expires_at<=clock_timestamp() or deadline_at<=clock_timestamp());
  get diagnostics n=row_count; return n;
end $$;
create or replace function public.spatial_claim(p_worker uuid) returns jsonb
language plpgsql security invoker set search_path=public as $$
declare j spatial_jobs; candidate spatial_jobs;
begin
  perform spatial_service_only();
  if p_worker is null then raise exception 'RP400: worker id required'; end if;
  -- An expired lease is terminal, not permission for a second GPU to overlap a
  -- possibly still running first host. Provider TTL is separately mandatory.
  if not exists(select 1 from spatial_runtime where singleton and enabled) then return null; end if;
  select q.* into candidate from spatial_jobs q join listings l on l.id=q.listing_id and l.org_id=q.org_id and l.deleted_at is null
    join orgs o on o.id=q.org_id and o.deleted_at is null
    where q.status='queued' and exists(select 1 from memberships m where m.user_id=q.actor_id and m.org_id=q.org_id and m.role in ('owner','admin','agent'))
    and not exists(select 1 from deletion_requests d where d.user_id=q.actor_id and d.status<>'completed')
    order by q.created_at limit 1;
  if candidate.id is null then return null; end if;
  perform spatial_access(candidate.actor_id,candidate.listing_id);
  select * into j from spatial_jobs where id=candidate.id and status='queued' for update skip locked;
  if j.id is null then return null; end if;
  update spatial_jobs set status='processing',worker_id=p_worker,lease_token=gen_random_uuid(),started_at=clock_timestamp(),
    lease_expires_at=clock_timestamp()+interval '2 minutes',deadline_at=clock_timestamp()+make_interval(secs=>max_seconds),
    progress=0.3,updated_at=clock_timestamp() where id=j.id returning * into j;
  return to_jsonb(j)||jsonb_build_object('inputs',(select jsonb_agg(to_jsonb(i) order by relative_path) from spatial_inputs i where job_id=j.id));
end $$;

create or replace function public.spatial_worker_update(p_job uuid,p_lease uuid,p_action text,p_data jsonb)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare j spatial_jobs; n integer; l uuid; actor uuid; cost integer; rev uuid;
begin
  perform spatial_service_only();
  select listing_id,actor_id into l,actor from spatial_jobs where id=p_job;
  perform spatial_access(actor,l);
  select * into strict j from spatial_jobs where id=p_job for update;
  if j.status<>'processing' or j.lease_token is distinct from p_lease or j.lease_expires_at<=clock_timestamp()
    or j.deadline_at<=clock_timestamp() or not exists(select 1 from listings where id=l and org_id=j.org_id and deleted_at is null)
    or not exists(select 1 from orgs where id=j.org_id and deleted_at is null)
    or exists(select 1 from deletion_requests where user_id=j.actor_id and status<>'completed') then
    raise exception 'RP409: worker lease is no longer current'; end if;
  if p_action='heartbeat' then
    cost:=(p_data->>'cost_cents')::integer;
    if cost is null or cost<j.cost_cents or cost>j.max_cost_cents or (p_data->>'progress')::numeric not between 0 and 0.95 then
      raise exception 'RP400: invalid bounded worker progress/cost'; end if;
    update spatial_jobs set cost_cents=cost,progress=greatest(progress,(p_data->>'progress')::numeric),
      lease_expires_at=least(deadline_at,clock_timestamp()+interval '2 minutes'),updated_at=clock_timestamp() where id=p_job returning * into j;
  elsif p_action='output_ticket' then
    n:=(p_data->>'bytes')::integer;
    if n is null or n not between 1 and 33554432 or coalesce(p_data->>'sha256','') !~ '^[0-9a-f]{64}$' then raise exception 'RP400: output exceeds its bound'; end if;
    if j.output_state is not null then
      if j.output_bytes<>n or j.output_sha256<>p_data->>'sha256' then raise exception 'RP409: output ticket replay differs'; end if;
    else
      rev:=gen_random_uuid();
      update spatial_jobs set output_bytes=n,output_sha256=p_data->>'sha256',artifact_revision=rev,output_state='planned',
        output_key='spatial/'||org_id||'/'||listing_id||'/'||id||'/'||rev||'/model.sog',updated_at=clock_timestamp()
        where id=p_job returning * into j;
    end if;
  elsif p_action='output_claim' then
    if j.output_state='planned' then
      update spatial_jobs set output_state='dispatching',updated_at=clock_timestamp() where id=p_job returning * into j;
      return to_jsonb(j)||'{"dispatch":true}'::jsonb;
    end if;
    return to_jsonb(j)||'{"dispatch":false}'::jsonb;
  elsif p_action='output_stored' then
    if j.output_state not in ('dispatching','stored') or coalesce(p_data->>'etag','')='' then raise exception 'RP409: output dispatch not journaled'; end if;
    update spatial_jobs set output_state='stored',output_etag=p_data->>'etag',updated_at=clock_timestamp() where id=p_job returning * into j;
  elsif p_action='complete' then
    if j.output_state is distinct from 'stored' or p_data->'manifest'->>'artifact_revision' is distinct from j.artifact_revision::text
      or p_data->'manifest'->>'sha256' is distinct from j.output_sha256
      or (p_data->'manifest'->>'bytes')::integer is distinct from j.output_bytes
      or p_data->'manifest'->>'provenance' is distinct from 'captured' then raise exception 'RP409: output is not sealed for this lease'; end if;
    cost:=(p_data->>'cost_cents')::integer;
    if cost is null or cost<j.cost_cents or cost>j.max_cost_cents then raise exception 'RP400: invalid bounded final cost'; end if;
    update spatial_jobs set status='review',progress=1,scene_manifest=p_data->'manifest',cost_cents=cost,
      lease_expires_at=null,approved=false,published_at=null,updated_at=clock_timestamp() where id=p_job returning * into j;
  elsif p_action='fail' then
    if coalesce(p_data->>'failure_code','') !~ '^[a-z][a-z0-9_]{0,79}$' then raise exception 'RP400: invalid failure code'; end if;
    cost:=(p_data->>'cost_cents')::integer;
    if cost is null or cost<j.cost_cents or cost>j.max_cost_cents then raise exception 'RP400: invalid bounded failure cost'; end if;
    update spatial_jobs set status='failed',failure_code=p_data->>'failure_code',lease_expires_at=null,
      provider_stopped=coalesce(p_data->'provider_stopped'='true'::jsonb,false),
      cost_cents=cost,updated_at=clock_timestamp() where id=p_job returning * into j;
  else raise exception 'RP400: unknown worker transition'; end if;
  return to_jsonb(j);
end $$;

create or replace function public.spatial_review(p_actor uuid,p_job uuid,p_revision uuid,p_approved boolean,p_excluded boolean,p_redactions jsonb)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare j spatial_jobs; l uuid;
begin
  select listing_id into l from spatial_jobs where id=p_job; perform spatial_access(p_actor,l);
  select * into strict j from spatial_jobs where id=p_job for update;
  if j.org_id is distinct from (select org_id from listings where id=j.listing_id) then raise exception 'RP403: room workspace changed'; end if;
  if j.status not in ('review','ready') or j.artifact_revision is distinct from p_revision or p_revision is null then
    raise exception 'RP409: review the current reconstructed room'; end if;
  if p_approved is null or p_excluded is null or jsonb_typeof(p_redactions) is distinct from 'array'
    or jsonb_array_length(p_redactions)>64 then raise exception 'RP400: invalid privacy review'; end if;
  -- A review can revoke access immediately. A browser overlay never counts as
  -- redaction: nonempty requests remain private until an actual derivative exists.
  update spatial_jobs set status='review',review_revision=p_revision,reviewed_by=p_actor,excluded=p_excluded,
    redactions=p_redactions,approved=p_approved and not p_excluded and jsonb_array_length(p_redactions)=0,
    published_at=null,updated_at=clock_timestamp() where id=p_job returning * into j;
  return to_jsonb(j);
end $$;
create or replace function public.spatial_publish(p_actor uuid,p_job uuid) returns jsonb
language plpgsql security invoker set search_path=public as $$
declare j spatial_jobs; l uuid;
begin
  select listing_id into l from spatial_jobs where id=p_job; perform spatial_access(p_actor,l);
  select * into strict j from spatial_jobs where id=p_job for update;
  if j.org_id is distinct from (select org_id from listings where id=j.listing_id) then raise exception 'RP403: room workspace changed'; end if;
  if j.status not in ('review','ready') or not j.approved or j.excluded or j.review_revision is distinct from j.artifact_revision
    or j.artifact_revision is null or j.output_state is distinct from 'stored' or j.redactions<>'[]'::jsonb then
    raise exception 'RP409: a current privacy-approved artifact is required; requested redactions are not processed'; end if;
  update spatial_jobs set status='ready',published_at=coalesce(published_at,clock_timestamp()),updated_at=clock_timestamp()
    where id=p_job returning * into j;
  return to_jsonb(j);
end $$;

create or replace function public.spatial_recover(p_actor uuid,p_job uuid,p_action text,p_idem uuid default null)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare j spatial_jobs; l uuid; prior_attempt integer;
begin
  select listing_id into l from spatial_jobs where id=p_job; perform spatial_access(p_actor,l);
  select * into strict j from spatial_jobs where id=p_job for update;
  if j.org_id is distinct from (select org_id from listings where id=j.listing_id) then raise exception 'RP403: room workspace changed'; end if;
  if p_action='cancel' then
    if j.status='failed' and j.failure_code='user_cancelled' then return to_jsonb(j); end if;
    if j.status not in ('uploading','queued') then raise exception 'RP409: only an undispatched room can be cancelled here'; end if;
    update spatial_jobs set status='failed',failure_code='user_cancelled',published_at=null,updated_at=clock_timestamp()
      where id=p_job returning * into j;
    return to_jsonb(j);
  elsif p_action='resume' then
    if j.status in ('uploading','queued') then return to_jsonb(j); end if;
    if j.status<>'failed' or j.failure_code is distinct from 'user_cancelled' or j.started_at is not null then
      raise exception 'RP409: only an undispatched cancelled capture can resume'; end if;
    if (select count(*) from spatial_jobs where org_id=j.org_id and status in ('uploading','queued','processing'))>=3 then
      raise exception 'RP429: finish another active room first'; end if;
    update spatial_jobs set status='uploading',failure_code=null,updated_at=clock_timestamp() where id=p_job returning * into j;
    return to_jsonb(j);
  elsif p_action<>'retry' or p_idem is null then raise exception 'RP400: explicit retry idempotency key is required'; end if;
  -- An exact transport replay acknowledges the already-created attempt even if
  -- that attempt subsequently finished. It never starts a third run by accident.
  if j.attempt_key=p_idem then
    if j.attempt_number=1 then raise exception 'RP409: retry needs a new operation key'; end if;
    return to_jsonb(j);
  end if;
  select attempt_number into prior_attempt from spatial_attempt_history where job_id=p_job and attempt_key=p_idem;
  if prior_attempt is not null then
    if prior_attempt=1 then raise exception 'RP409: retry needs a new operation key'; end if;
    return to_jsonb(j);
  end if;
  if j.status<>'failed' or j.failure_code='user_cancelled' or not j.inputs_complete then
    raise exception 'RP409: retry requires a failed generation with its complete saved capture'; end if;
  if j.attempt_number>=3 then raise exception 'RP429: this capture reached its three-attempt limit'; end if;
  if j.started_at is not null and not j.provider_stopped and (j.deadline_at is null or j.deadline_at>clock_timestamp()) then
    raise exception 'RP409: previous GPU termination is not confirmed; retry after its deadline'; end if;
  if (select count(*) from spatial_jobs where org_id=j.org_id and status in ('uploading','queued','processing'))>=3 then
    raise exception 'RP429: finish another active room first'; end if;
  insert into spatial_attempt_history(job_id,attempt_key,attempt_number,snapshot)
    values(j.id,j.attempt_key,j.attempt_number,to_jsonb(j));
  update spatial_jobs set attempt_number=attempt_number+1,attempt_key=p_idem,actor_id=p_actor,
    status='uploading',progress=0.25,failure_code=null,reserved_at=null,provider_stopped=false,cost_cents=0,
    lease_token=null,worker_id=null,lease_expires_at=null,deadline_at=null,started_at=null,
    artifact_revision=null,output_key=null,output_bytes=null,output_sha256=null,output_state=null,output_etag=null,
    scene_manifest=null,review_revision=null,reviewed_by=null,approved=false,excluded=false,redactions='[]',published_at=null,
    updated_at=clock_timestamp() where id=p_job;
  -- Revalidate the SAME immutable inputs and reserve atomically. A quota/config
  -- failure rolls this entire function back, including the attempted reset.
  return spatial_start(p_actor,p_job);
end $$;

do $$ declare f record; begin
  for f in select oid::regprocedure as signature from pg_proc where pronamespace='public'::regnamespace and proname like 'spatial\_%' escape '\' loop
    execute format('revoke all on function %s from public,anon,authenticated',f.signature);
    execute format('grant execute on function %s to service_role',f.signature);
  end loop;
end $$;
