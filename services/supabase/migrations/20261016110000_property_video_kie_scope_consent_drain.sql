-- Kie property-video authority, permission and drain accounting
-- (kie-kling3-4k-steady-v1). Nothing here activates Kie, enables the pinned
-- route, creates a grant, publishes a disclosure or changes any FAL/legacy job,
-- price, receipt, hold or historical recovery path.
--
-- 1. Drain allowance floor. paid_quality_processing_budget followed only the
--    current selector, so a default rollback (or a new-admission hold) could
--    refuse the next reservation of an already admitted Kie job (first send, the
--    single quality retry or a capacity resume) with RP402. The floor now also
--    holds for a billing org while it has its own not-cancelled, pre-deadline
--    Kie job whose frozen identity is exactly the reviewed one. FAL accounting
--    still follows the selector, unchanged.
-- 2. Processor permission. A new Kie job requires the fresh permission token
--    property-video-jobs-v2 for the CURRENT published disclosure revision
--    (app_config.property_video_processor_consent, which this migration never
--    seeds, so Kie admission fails closed until Codex's disclosure ships). The
--    permission is persisted on the job (consent_revision + processor_consent)
--    and immutable. The old v1 permission can never admit Kie; legacy/FAL jobs
--    keep v1 and their frozen recovery. An operator acknowledgement is not user
--    permission and is not accepted here.
-- 3. Owner-only quality-test grant. property_video_kie_test_grants pins one
--    approved actor, logical library, physical listing, the reviewed Kie
--    identity, the exact ordered source identities (asset, version, provenance,
--    prepared-bytes SHA-256) and the allowed job operation ids, with an expiry
--    (at most 72 h after creation) and a bounded createTask count and cost.
--    Admission under a grant works while the global selector stays unchanged
--    (FAL/legacy); every prospective paid Kie dispatch first calls
--    property_video_kie_dispatch_authority, which re-checks the exact scope and
--    consumes one create (167.5 cents) atomically, idempotent per attempt.
--    Expiry or revocation refuses new creates; accepted-task polling, retention
--    and every other read path never consult the grant. No grant row exists
--    until an owner-approved operator step (docs/handoff/KIE-OWNER-TEST-GRANT.sql)
--    creates one; this migration creates none.
-- A selector hold value (docs/handoff/KIE-HOLD-NEW-ADMISSIONS.sql) needs no
-- schema: property_video_quality_profile() already refuses every value it does
-- not recognise (RP503), and property_video_quality_profile_for() calls it first,
-- so a hold also stops grant-scoped admissions.
begin;

-- Before ANY DDL, replay accepts only the reviewed helper bodies AND their
-- existing security/ACL/type contracts, plus the exact enabled row triggers.
-- The one reviewed old dispatch body is an explicit upgrade input; arbitrary
-- changes are never silently replaced. Missing objects are the first apply.
do $kie_scope_replay_guard$
declare e record;p pg_catalog.pg_proc;t pg_catalog.pg_trigger;oid_expected oid;owner_expected oid;service_oid oid;
begin
 select proowner into owner_expected from pg_catalog.pg_proc where oid='public.property_video_job_admit(uuid,jsonb,numeric,text)'::regprocedure;
 select oid into service_oid from pg_catalog.pg_roles where rolname='service_role';
 for e in select *from(values
('public.property_video_kie_test_grant_guard()',array['3c545bb02fde8d1b6f09e0b45444f542'],null::text[],'trigger','v',false),
('public.property_video_kie_test_grant_use_guard()',array['6655d3fd835bbb83e153c69bc69de004'],null::text[],'trigger','v',false),
('public.property_video_processor_consent_current()',array['d4ff3c39e941e33a5716cb20eaa5d8fb'],null::text[],'jsonb','s',true),
('public.property_video_processor_consent_record(text,jsonb)',array['05898fc5f19891e5073ae9bd3adc43f2'],array['p_profile','p_consent'],'jsonb','s',true),
('public.property_video_kie_test_grant_scope(uuid,uuid,jsonb)',array['41cd158b07cbc42f260d3e5857ed9318'],array['p_grant','p_actor','p_manifest'],'public.property_video_kie_test_grants','v',true),
('public.property_video_quality_profile_for(uuid,jsonb,uuid)',array['f98df8fc96bcd64543768cbbc2a0b0cb'],array['p_actor','p_manifest','p_grant'],'text','v',true),
('public.property_video_job_admit_v2(uuid,jsonb,numeric,text,jsonb,uuid)',array['b913c19929f246bd4632ecb422fac7da'],array['p_actor','p_manifest','p_quote','p_quality_profile','p_consent','p_test_grant'],'jsonb','v',true),
('public.property_video_kie_dispatch_authority(uuid,uuid,uuid)',array['885a3afac24b2b52d95c30c96f2d4adc','b2e484036e8d6803afa40e30fb41fbcf'],array['p_job','p_lease','p_attempt'],'jsonb','v',true)
 )v(signature,body_md5s,arg_names,result_type,volatility,service_execute)loop
  oid_expected:=to_regprocedure(e.signature);
  if oid_expected is not null then
   select *into p from pg_catalog.pg_proc where oid=oid_expected;
   if not(md5(p.prosrc)=any(e.body_md5s))or p.proowner<>owner_expected
    or p.prokind<>'f'or p.prolang<>(select oid from pg_catalog.pg_language where lanname='plpgsql')
    or not p.prosecdef or p.provolatile::text<>e.volatility or p.proisstrict or p.proleakproof or p.proparallel<>'u'
    or p.proconfig is distinct from array['search_path=""']::text[]
    or p.proargnames is distinct from e.arg_names or p.proargmodes is not null or p.proallargtypes is not null
    or p.provariadic<>0 or p.pronargdefaults<>0 or p.proargdefaults is not null
    or p.prorettype is distinct from to_regtype(e.result_type)::oid
    or exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a
      where a.grantor<>owner_expected or a.privilege_type<>'EXECUTE'or a.is_grantable
       or(a.grantee<>owner_expected and(not e.service_execute or a.grantee<>service_oid)))
    or(select count(*)from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))))<>(case when e.service_execute and service_oid<>owner_expected then 2 else 1 end)
    or not exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a where a.grantee=owner_expected)
    or(e.service_execute and not exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a where a.grantee=service_oid))then
    raise exception'Review changed Kie scope helper: %',e.signature;
   end if;
  end if;
 end loop;
 for e in select *from(values
  ('property_video_kie_test_grant_guard','public.property_video_kie_test_grants','public.property_video_kie_test_grant_guard()',23),
  ('property_video_kie_test_grant_use_guard','public.property_video_kie_test_grant_uses','public.property_video_kie_test_grant_use_guard()',19)
 )v(name,relation,signature,kind)loop
  for t in select *from pg_catalog.pg_trigger where tgname=e.name loop
   if t.tgrelid is distinct from to_regclass(e.relation)::oid or t.tgfoid is distinct from to_regprocedure(e.signature)::oid
    or t.tgtype<>e.kind or t.tgenabled<>'O'or t.tgisinternal or t.tgqual is not null
    or t.tgnargs<>0 or octet_length(t.tgargs)<>0 or t.tgattr::text<>''
    or t.tgconstraint<>0 or t.tgconstrrelid<>0 or t.tgconstrindid<>0 or t.tgparentid<>0
    or t.tgdeferrable or t.tginitdeferred or t.tgoldtable is not null or t.tgnewtable is not null then
    raise exception'Review changed Kie scope trigger: %',e.name;
   end if;
  end loop;
 end loop;
end$kie_scope_replay_guard$;

-- ── Owner-only quality-test grants ───────────────────────────────────────────
create table if not exists public.property_video_kie_test_grants(
 id uuid primary key default gen_random_uuid(),
 profile text not null check(profile='kie-kling3-4k-steady-v1'),
 quality_identity jsonb not null,
 actor_id uuid not null references auth.users(id)on delete cascade,
 library_org_id uuid not null,
 listing_id uuid not null references public.listings(id)on delete cascade,
 operation_ids uuid[] not null check(cardinality(operation_ids)between 1 and 4 and array_position(operation_ids,null)is null),
 sources jsonb not null check(jsonb_typeof(sources)='array'and jsonb_array_length(sources)between 1 and 10),
 max_creates integer not null check(max_creates between 1 and 20),
 max_cents numeric not null check(max_cents>0),
 creates_used integer not null default 0 check(creates_used>=0),
 cents_used numeric not null default 0 check(cents_used>=0),
 approval_ref text not null check(approval_ref~'^[!-~]{1,200}$'),
 created_at timestamptz not null default now(),
 expires_at timestamptz not null,
 revoked_at timestamptz,
 revoked_reason text check(revoked_reason is null or revoked_reason~'^[ -~]{1,200}$'),
 check(expires_at>created_at and expires_at<=created_at+interval'72 hours'),
 check(creates_used<=max_creates and cents_used<=max_cents),
 check(max_cents<=max_creates*167.5),
 check((revoked_at is null)=(revoked_reason is null)));
create table if not exists public.property_video_kie_test_grant_uses(
 grant_id uuid not null references public.property_video_kie_test_grants(id)on delete cascade,
 job_id uuid not null references public.property_video_jobs(id)on delete cascade,
 attempt_id uuid not null,
 request_key text not null unique check(request_key='bgvideo:'||attempt_id::text),
 cents numeric not null check(cents=167.5),
 created_at timestamptz not null default now(),
 primary key(grant_id,attempt_id));
do $$declare t text;begin foreach t in array array['property_video_kie_test_grants','property_video_kie_test_grant_uses']loop
 execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);execute format('grant select on public.%I to service_role',t);end loop;end$$;

-- Scope is immutable; usage only grows; revocation is one-way.
create or replace function public.property_video_kie_test_grant_guard()returns trigger language plpgsql security definer set search_path=''as $$declare e jsonb;i integer;begin
 if TG_OP='INSERT'then
  if new.profile<>'kie-kling3-4k-steady-v1'or new.quality_identity is distinct from public.property_video_quality_identity(new.profile)then raise exception'RP409: An owner quality test must pin the reviewed Kie identity';end if;
  if new.creates_used<>0 or new.cents_used<>0 or new.revoked_at is not null or new.expires_at<=now()or new.created_at>now()+interval'1 minute'then raise exception'RP409: A new owner quality test starts unused, unrevoked and unexpired';end if;
  if new.library_org_id is distinct from public.listing_owner_library(new.listing_id)then raise exception'RP409: The owner quality-test library must own its listing';end if;
  for i in 0..jsonb_array_length(new.sources)-1 loop e:=new.sources->i;
   if jsonb_typeof(e)is distinct from'object'or(e-array['photo_asset_id','photo_version_id','photo_provenance_id','sha256'])<>'{}'::jsonb
    or coalesce(e->>'photo_asset_id','')!~'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or jsonb_typeof(e->'photo_version_id')is distinct from'string'or length(e->>'photo_version_id')not between 1 and 200
    or(e->>'photo_provenance_id'is not null and e->>'photo_provenance_id'!~'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    or coalesce(e->>'sha256','')!~'^[a-f0-9]{64}$'then raise exception'RP400: Owner quality-test sources must be exact photo identities';end if;
  end loop;
  return new;
 end if;
 if row(new.id,new.profile,new.quality_identity,new.actor_id,new.library_org_id,new.listing_id,new.operation_ids,new.sources,new.max_creates,new.max_cents,new.approval_ref,new.created_at,new.expires_at)
  is distinct from row(old.id,old.profile,old.quality_identity,old.actor_id,old.library_org_id,old.listing_id,old.operation_ids,old.sources,old.max_creates,old.max_cents,old.approval_ref,old.created_at,old.expires_at)then
  raise exception'RP409: An owner quality-test scope is immutable';end if;
 if new.creates_used<old.creates_used or new.cents_used<old.cents_used
  or(old.revoked_at is not null and(new.revoked_at is distinct from old.revoked_at or new.revoked_reason is distinct from old.revoked_reason))then
  raise exception'RP409: Owner quality-test usage and revocation are append-only';end if;
 return new;end$$;
drop trigger if exists property_video_kie_test_grant_guard on public.property_video_kie_test_grants;
create trigger property_video_kie_test_grant_guard before insert or update on public.property_video_kie_test_grants for each row execute function public.property_video_kie_test_grant_guard();
create or replace function public.property_video_kie_test_grant_use_guard()returns trigger language plpgsql security definer set search_path=''as $$begin
 raise exception'RP409: An owner quality-test create is an immutable receipt';end$$;
drop trigger if exists property_video_kie_test_grant_use_guard on public.property_video_kie_test_grant_uses;
create trigger property_video_kie_test_grant_use_guard before update on public.property_video_kie_test_grant_uses for each row execute function public.property_video_kie_test_grant_use_guard();

-- ── Saved job: permission and test scope ─────────────────────────────────────
alter table public.property_video_jobs add column if not exists processor_consent jsonb;
alter table public.property_video_jobs add column if not exists kie_test_grant_id uuid references public.property_video_kie_test_grants(id);
do $column$begin
 if(select format_type(atttypid,atttypmod)||':'||attnotnull||':'||atthasdef from pg_attribute where attrelid='public.property_video_jobs'::regclass and attname='processor_consent'and not attisdropped)is distinct from'jsonb:false:false'
  or(select format_type(atttypid,atttypmod)||':'||attnotnull||':'||atthasdef from pg_attribute where attrelid='public.property_video_jobs'::regclass and attname='kie_test_grant_id'and not attisdropped)is distinct from'uuid:false:false'then
  raise exception'Review changed saved video permission columns';end if;
end$column$;
comment on column public.property_video_jobs.processor_consent is'Fresh processor permission persisted at admission (token, disclosure_revision, processors, recorded_at) when consent_revision is property-video-jobs-v2; NULL for v1. Immutable.';
comment on column public.property_video_jobs.kie_test_grant_id is'Owner-only Kie quality-test grant this job was admitted under; NULL for every other job. Immutable.';
do $constraint$declare actual text;begin
 select pg_get_constraintdef(oid)into actual from pg_constraint where conrelid='public.property_video_jobs'::regclass and conname='property_video_jobs_consent_revision_check'and contype='c'and convalidated;
 if actual=$old$CHECK ((consent_revision = 'property-video-jobs-v1'::text))$old$ then
  alter table public.property_video_jobs drop constraint property_video_jobs_consent_revision_check;
  alter table public.property_video_jobs add constraint property_video_jobs_consent_revision_check check(consent_revision in('property-video-jobs-v1','property-video-jobs-v2'));
 elsif actual is distinct from $expected$CHECK ((consent_revision = ANY (ARRAY['property-video-jobs-v1'::text, 'property-video-jobs-v2'::text])))$expected$ then raise exception'Review changed saved video consent constraint';end if;
 if not exists(select 1 from pg_constraint where conrelid='public.property_video_jobs'::regclass and conname='property_video_jobs_processor_consent_check')then
  alter table public.property_video_jobs add constraint property_video_jobs_processor_consent_check check((consent_revision='property-video-jobs-v1'and processor_consent is null)or(consent_revision='property-video-jobs-v2'and jsonb_typeof(processor_consent)='object'));end if;
 if not exists(select 1 from pg_constraint where conrelid='public.property_video_jobs'::regclass and conname='property_video_jobs_kie_consent_check')then
  alter table public.property_video_jobs add constraint property_video_jobs_kie_consent_check check(quality_profile<>'kie-kling3-4k-steady-v1'or consent_revision='property-video-jobs-v2');end if;
 if not exists(select 1 from pg_constraint where conrelid='public.property_video_jobs'::regclass and conname='property_video_jobs_kie_test_grant_check')then
  alter table public.property_video_jobs add constraint property_video_jobs_kie_test_grant_check check(kie_test_grant_id is null or quality_profile='kie-kling3-4k-steady-v1');end if;
end$constraint$;
-- The drain floor reads only Kie jobs: a tiny partial index keeps the hot
-- entitlement path from scanning every saved video.
create index if not exists property_video_jobs_kie_drain on public.property_video_jobs(deadline)where quality_profile='kie-kling3-4k-steady-v1'and cancelled_at is null;

-- ── Processor permission ─────────────────────────────────────────────────────
-- The published disclosure contract, or NULL while none is published/valid.
create or replace function public.property_video_processor_consent_current()returns jsonb language plpgsql stable security definer set search_path=''as $$declare c jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select value into c from public.app_config where key='property_video_processor_consent';
 if c is null or jsonb_typeof(c)is distinct from'object'or c->>'token'is distinct from'property-video-jobs-v2'
  or jsonb_typeof(c->'disclosure_revision')is distinct from'string'or c->>'disclosure_revision'!~'^[!-~]{1,200}$'
  or jsonb_typeof(c->'processors')is distinct from'array'or not(c->'processors')?'kie'
  or jsonb_typeof(c->'profiles')is distinct from'array'or not(c->'profiles')?'kie-kling3-4k-steady-v1'
  or(c-array['token','disclosure_revision','processors','profiles'])<>'{}'::jsonb then return null;end if;
 return c;end$$;
-- What a new job persists. NULL = the original v1 permission (legacy/FAL only).
create or replace function public.property_video_processor_consent_record(p_profile text,p_consent jsonb)returns jsonb language plpgsql stable security definer set search_path=''as $$declare c jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_consent is null or p_consent='{"token":"property-video-jobs-v1"}'::jsonb then
  if p_profile='kie-kling3-4k-steady-v1'then raise exception'RP403: Allow the listed AI processors for this native-4K video before creating it';end if;
  return null;
 end if;
 c:=public.property_video_processor_consent_current();
 if c is null then raise exception'RP403: The AI processor disclosure for this video is not published yet';end if;
 if jsonb_typeof(p_consent)is distinct from'object'or p_consent->>'token'is distinct from c->>'token'
  or p_consent->'disclosure_revision'is distinct from c->'disclosure_revision'or(p_consent-array['token','disclosure_revision'])<>'{}'::jsonb then
  raise exception'RP403: Allow the current AI processor disclosure before creating this video';end if;
 return jsonb_build_object('token',c->'token','disclosure_revision',c->'disclosure_revision','processors',c->'processors','recorded_at',now());end$$;

-- ── Grant scope and the profile a request may quote ──────────────────────────
create or replace function public.property_video_kie_test_grant_scope(p_grant uuid,p_actor uuid,p_manifest jsonb)returns public.property_video_kie_test_grants
language plpgsql security definer set search_path=''as $$declare g public.property_video_kie_test_grants;s jsonb;e jsonb;i integer;n integer;ref jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select *into g from public.property_video_kie_test_grants where id=p_grant for update;
 if g.id is null or g.revoked_at is not null or g.expires_at<=now()then raise exception'RP403: The owner quality-test permission is not active';end if;
 if g.quality_identity is distinct from public.property_video_quality_identity(g.profile)then raise exception'RP409: The owner quality-test recipe changed';end if;
 if jsonb_typeof(p_manifest->'sources')is distinct from'array'then raise exception'RP403: This video is outside the owner quality-test permission';end if;
 n:=jsonb_array_length(p_manifest->'sources');
 if g.actor_id<>p_actor or g.listing_id is distinct from(p_manifest->>'listing_id')::uuid
  or g.library_org_id is distinct from public.listing_owner_library((p_manifest->>'listing_id')::uuid)
  or not((p_manifest->>'operation_id')::uuid=any(g.operation_ids))or n<>jsonb_array_length(g.sources)
  or g.creates_used+n>g.max_creates or g.cents_used+n*(g.quality_identity->>'attempt_cents')::numeric>g.max_cents then
  raise exception'RP403: This video is outside the owner quality-test permission';end if;
 for i in 0..n-1 loop
  s:=p_manifest->'sources'->i;e:=g.sources->i;
  if s->>'photo_asset_id'is distinct from e->>'photo_asset_id'or s->>'photo_version_id'is distinct from e->>'photo_version_id'
   or s->>'photo_provenance_id'is distinct from e->>'photo_provenance_id'then raise exception'RP403: This video is outside the owner quality-test permission';end if;
  ref:=public.property_photo_reference(p_actor,g.listing_id,(s->>'photo_asset_id')::uuid,(s->>'photo_provenance_id')::uuid);
  if ref->>'sha256'is distinct from e->>'sha256'then raise exception'RP409: An owner quality-test photo changed';end if;
 end loop;
 return g;end$$;
-- The selector decides first (a hold or a broken value refuses every new
-- admission, grants included); a named grant may only narrow to Kie exactly.
create or replace function public.property_video_quality_profile_for(p_actor uuid,p_manifest jsonb,p_grant uuid)returns text
language plpgsql security definer set search_path=''as $$declare base text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 base:=public.property_video_quality_profile();
 if p_grant is null then return base;end if;
 perform public.property_video_kie_test_grant_scope(p_grant,p_actor,p_manifest);
 return'kie-kling3-4k-steady-v1';end$$;

-- New admission entrypoint: the request's permission and optional grant travel
-- as transaction-local settings into the unchanged admission and freeze path.
create or replace function public.property_video_job_admit_v2(p_actor uuid,p_manifest jsonb,p_quote numeric,p_quality_profile text,p_consent jsonb,p_test_grant uuid)returns jsonb
language plpgsql security definer set search_path=''as $$declare prior_consent text;prior_grant text;result jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_consent is null or jsonb_typeof(p_consent)is distinct from'object'or p_consent->>'token'is null or p_consent->>'token'not in('property-video-jobs-v1','property-video-jobs-v2')
  or(p_consent->>'token'='property-video-jobs-v1'and p_consent<>'{"token":"property-video-jobs-v1"}'::jsonb)then
  raise exception'RP403: Allow AI processing of these selected photos before creating the video';end if;
 prior_consent:=current_setting('rendprop.property_video_consent',true);prior_grant:=current_setting('rendprop.property_video_test_grant',true);
 perform set_config('rendprop.property_video_consent',p_consent::text,true);
 perform set_config('rendprop.property_video_test_grant',coalesce(p_test_grant::text,''),true);
 result:=public.property_video_job_admit(p_actor,p_manifest,p_quote,p_quality_profile);
 perform set_config('rendprop.property_video_consent',coalesce(prior_consent,''),true);
 perform set_config('rendprop.property_video_test_grant',coalesce(prior_grant,''),true);
 return result;end$$;

-- ── Before every prospective paid Kie dispatch ───────────────────────────────
-- Called by ai-video after its pre-money checks and before any allowance,
-- reservation or provider request. A globally activated Kie job only proves its
-- frozen recipe and permission; an owner-test job also re-checks the exact
-- grant scope against the saved job and consumes one create atomically
-- (idempotent per attempt). Polling never calls this.
create or replace function public.property_video_kie_dispatch_authority(p_job uuid,p_lease uuid,p_attempt uuid)returns jsonb
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;g public.property_video_kie_test_grants;u public.property_video_kie_test_grant_uses;src public.property_video_job_sources;e jsonb;cost numeric;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.property_video_job_worker_scope(p_job,p_lease,p_attempt);
 select *into j from public.property_video_jobs where id=p_job;
 select *into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt;
 if j.quality_profile is distinct from'kie-kling3-4k-steady-v1'or j.quality_identity is distinct from public.property_video_quality_identity('kie-kling3-4k-steady-v1')
  or j.consent_revision is distinct from'property-video-jobs-v2'or jsonb_typeof(j.processor_consent)is distinct from'object'then
  raise exception'RP409: This saved video is not an exact native-4K Kie recipe with its processor permission';end if;
 if s.state is distinct from'dispatching'or s.receipt is not null or s.request_key is distinct from'bgvideo:'||s.attempt_id::text then
  raise exception'RP409: Only an unsent clip can ask for supplier authority';end if;
 if j.kie_test_grant_id is null then return jsonb_build_object('authority','activated_profile','job_id',j.id,'attempt_id',s.attempt_id);end if;
 select *into g from public.property_video_kie_test_grants where id=j.kie_test_grant_id for update;
 select *into u from public.property_video_kie_test_grant_uses where grant_id=g.id and attempt_id=s.attempt_id;
 -- An existing use is accounting only. Every prospective unsent POST still
 -- requires an active grant, including a lost-authority-reply recovery.
 if g.id is null or g.revoked_at is not null or g.expires_at<=now()then raise exception'RP403: The owner quality-test permission has ended. No new clip was sent.';end if;
 if u.grant_id is not null then
  if u.job_id<>j.id or u.request_key<>s.request_key then raise exception'RP409: Owner quality-test authority changed';end if;
  return jsonb_build_object('authority','owner_quality_test','grant_id',g.id,'attempt_id',s.attempt_id,'creates_used',g.creates_used,'cents_used',g.cents_used,'replayed',true);
 end if;
 if g.actor_id<>j.actor_id or g.listing_id<>j.listing_id or g.library_org_id<>j.library_org_id or not(j.operation_id=any(g.operation_ids))
  or g.quality_identity is distinct from j.quality_identity or jsonb_array_length(g.sources)<>j.source_count then
  raise exception'RP403: This clip is outside the owner quality-test permission';end if;
 for src in select *from public.property_video_job_sources where job_id=p_job order by position loop
  e:=g.sources->src.position;
  if e is null or e->>'photo_asset_id'is distinct from src.asset_id::text or e->>'photo_version_id'is distinct from src.version_id
   or e->>'photo_provenance_id'is distinct from src.photo_provenance_id::text or e->>'sha256'is distinct from src.source->>'sha256'then
   raise exception'RP403: This clip is outside the owner quality-test permission';end if;
 end loop;
 cost:=(j.quality_identity->>'attempt_cents')::numeric;
 if g.creates_used+1>g.max_creates or g.cents_used+cost>g.max_cents then raise exception'RP403: The owner quality-test budget is used up. No new clip was sent.';end if;
 insert into public.property_video_kie_test_grant_uses(grant_id,job_id,attempt_id,request_key,cents)values(g.id,j.id,s.attempt_id,s.request_key,cost);
 update public.property_video_kie_test_grants set creates_used=creates_used+1,cents_used=cents_used+cost where id=g.id returning *into g;
 return jsonb_build_object('authority','owner_quality_test','grant_id',g.id,'attempt_id',s.attempt_id,'creates_used',g.creates_used,'cents_used',g.cents_used,'replayed',false);end$$;

-- ── Exact md5-verified anchors in the current (Kie profile) bodies ───────────
do $patch$declare p record;body text;original text;definition text;i integer;begin
 for p in select *from(values
('public.paid_quality_processing_budget(uuid)','a28d26cfc04c43b1fd12b58cc7d49cb4','618a85ee6ec7e94fa6f0d2c02dab8188',array[$anchor$quality:=coalesce(v->'enabled'='true'::jsonb and(v->>'profile'in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')or(v->>'profile'='kie-kling3-4k-steady-v1'and v->'vendor_content_license'=public.property_video_quality_identity('kie-kling3-4k-steady-v1')->'content_license_ack')),false);$anchor$],array[$replacement$quality:=coalesce(v->'enabled'='true'::jsonb and(v->>'profile'in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')or(v->>'profile'='kie-kling3-4k-steady-v1'and v->'vendor_content_license'=public.property_video_quality_identity('kie-kling3-4k-steady-v1')->'content_license_ack')),false);
 -- Admitted Kie work keeps this bounded floor after the selector changes (default
 -- rollback, new-admission hold or an owner quality-test window), but only for this
 -- billing org's own not-cancelled, pre-deadline Kie jobs whose frozen identity is
 -- exactly the reviewed one. FAL accounting is unchanged: it follows the selector.
 if not quality then quality:=exists(select 1 from public.property_video_jobs j where j.quality_profile='kie-kling3-4k-steady-v1'and j.quality_identity=public.property_video_quality_identity('kie-kling3-4k-steady-v1')
  and j.state in('queued','generating','quality_review','composing','failed')and j.cancelled_at is null and j.deadline>now()and public.library_billing_org(j.org_id)=public.library_billing_org(p_org));end if;$replacement$]),
('public.property_video_quality_freeze()','8690864e9d4e01a5c8fa5d4699bfdc20','a3dd833254a27901b7c79cc70f18ad61',array[$anchor$declare expected text;quoted text;begin$anchor$,$anchor$if new.quality_identity::text is distinct from old.quality_identity::text then raise exception'RP409: A saved video quality identity is immutable';end if;$anchor$,$anchor$expected:=public.property_video_quality_profile();$anchor$,$anchor$new.quality_profile:=quoted;new.quality_identity:=public.property_video_quality_identity(quoted);$anchor$],array[$replacement$declare expected text;quoted text;consent jsonb;begin$replacement$,$replacement$if new.quality_identity::text is distinct from old.quality_identity::text then raise exception'RP409: A saved video quality identity is immutable';end if;
  if new.kie_test_grant_id is distinct from old.kie_test_grant_id or new.processor_consent::text is distinct from old.processor_consent::text
   or new.consent_revision is distinct from old.consent_revision then raise exception'RP409: A saved video permission or test scope is immutable';end if;$replacement$,$replacement$expected:=public.property_video_quality_profile_for(new.actor_id,new.manifest,nullif(current_setting('rendprop.property_video_test_grant',true),'')::uuid);$replacement$,$replacement$new.quality_profile:=quoted;new.quality_identity:=public.property_video_quality_identity(quoted);
 -- Fresh processor permission (required for Kie, persisted, immutable) and the exact
 -- owner quality-test scope that property_video_quality_profile_for just validated.
 consent:=public.property_video_processor_consent_record(quoted,nullif(current_setting('rendprop.property_video_consent',true),'')::jsonb);
 new.consent_revision:=coalesce(consent->>'token',new.consent_revision);new.processor_consent:=consent;
 new.kie_test_grant_id:=case when quoted='kie-kling3-4k-steady-v1'then nullif(current_setting('rendprop.property_video_test_grant',true),'')::uuid end;$replacement$]),
('public.property_video_job_admit(uuid,jsonb,numeric,text)','27144ffabf1bcb6a36ea6023d169cbd8','2077ba4e86e2002e94fdc3e43cd8954d',array[$anchor$p_quality_profile<>public.property_video_quality_profile()then raise exception'RP409: The video quality quote changed before admission';end if;$anchor$],array[$replacement$p_quality_profile<>public.property_video_quality_profile_for(p_actor,p_manifest,nullif(current_setting('rendprop.property_video_test_grant',true),'')::uuid)then raise exception'RP409: The video quality quote changed before admission';end if;$replacement$])
 )v(signature,before_md5,after_md5,anchors,replacements)loop
  select prosrc into body from pg_proc where oid=p.signature::regprocedure;
  if md5(body)not in(p.before_md5,p.after_md5)then raise exception'Review changed Kie scope dependency: %',p.signature;end if;
  if md5(body)=p.before_md5 then
   original:=body;
   for i in 1..array_length(p.anchors,1)loop
    if(length(body)-length(replace(body,p.anchors[i],'')))/length(p.anchors[i])<>1 then raise exception'Exact Kie scope anchor changed: %',p.signature;end if;
    body:=replace(body,p.anchors[i],p.replacements[i]);
   end loop;
   if md5(body)<>p.after_md5 then raise exception'Unexpected Kie scope body: %',p.signature;end if;
   definition:=pg_get_functiondef(p.signature::regprocedure);
   if position(original in definition)=0 then raise exception'Kie scope function definition changed: %',p.signature;end if;
   execute replace(definition,original,body);
  end if;
 end loop;
end$patch$;

revoke all on function public.property_video_kie_test_grant_guard(),public.property_video_kie_test_grant_use_guard(),public.property_video_processor_consent_current(),public.property_video_processor_consent_record(text,jsonb),
 public.property_video_kie_test_grant_scope(uuid,uuid,jsonb),public.property_video_quality_profile_for(uuid,jsonb,uuid),public.property_video_job_admit_v2(uuid,jsonb,numeric,text,jsonb,uuid),
 public.property_video_kie_dispatch_authority(uuid,uuid,uuid)from public,anon,authenticated,service_role;
grant execute on function public.property_video_processor_consent_current(),public.property_video_processor_consent_record(text,jsonb),public.property_video_kie_test_grant_scope(uuid,uuid,jsonb),
 public.property_video_quality_profile_for(uuid,jsonb,uuid),public.property_video_job_admit_v2(uuid,jsonb,numeric,text,jsonb,uuid),public.property_video_kie_dispatch_authority(uuid,uuid,uuid)to service_role;
commit;
