-- 0044: plan rework + the industry-aware free week (owner decision, 2026-09-12).
--
-- ── THE DECISION ─────────────────────────────────────────────────────────────
--
-- Prices do not move. The paid allowances do — this is the owner-approved
-- line-up as of 2026-09-12 — and the COGS ceilings follow so the hard monthly
-- backstop in log_job_cost() tracks the new sizes:
--
--   plan     renders  photo_edits  reels  aerials  topaz  seats  ceiling  price
--   starter     4        100         6       2       0      1     1200¢   $49   (solo = alias)
--   pro        10        200        12       4       0      1     2400¢   $99
--   team       25        400        25       8       2      2     6000¢   $249
--   trial       3         60         4       2       1      1     1200¢   $0    (0032, unchanged)
--   free        1          5         0       0       0      1      300¢   $0    (0032, unchanged)
--
-- Team goes from 3 seats to 2. `solo` stays a byte-identical alias of starter
-- so older org rows keep working (0010 §2).
--
-- ── THE INDUSTRY-AWARE TRIAL ─────────────────────────────────────────────────
--
-- A real-estate agent has a pipeline of homes; a venue, restaurant, store, gym
-- or "other" business has ONE location. The same 3-tour free week therefore
-- means something different to each, so the trial — and ONLY the trial — now
-- reads `orgs.space_type`:
--
--   real_estate ............................. the 0032 base row (3 tours)
--   venue|restaurant|retail|fitness|other ... 1 tour, 60 edits, 4 reels,
--                                             1 aerial, 1 topaz, 1000¢ ceiling
--
-- The mechanism is a second, sparse table: plan_entitlement_overrides keyed by
-- (plan, space_type), where a NULL column inherits the base row. Paid plans and
-- free have no override rows and are deliberately not industry-aware; a paid
-- customer buys the same allowance whatever they film.
--
-- org_entitlement(org) is the new single read path: the base row for
-- effective_plan(org), each numeric column coalesced against the override for
-- (that plan, the org's space_type). create_render_job() and log_job_cost() are
-- re-created below reading it; functions/_shared/entitlements.ts reads it over
-- RPC (with a fallback to the old effective_plan()+table path while this file
-- is not yet deployed). plan_entitlement(text), plan_render_cap(text),
-- effective_plan(uuid) and org_seats_allowed(uuid) are NOT changed — they stay
-- the plan-only base lookups, and tests/invariants.sql pins them.
--
-- orgs.space_type existed since 0001 (text not null default 'real_estate') but
-- nothing wrote it. PATCH /me/brand now accepts it (the column is already in
-- the tenant UPDATE grant, 0005/0019), so it gains the CHECK constraint the
-- listings column has always had in code. It is added NOT VALID (no table scan
-- under the exclusive lock) and then VALIDATED — deliberately unguarded, so a
-- stray value on an existing row fails this migration loudly instead of being
-- skipped and surfacing later as a 400 on a brand save.
--
-- Idempotent: upserts, `create table if not exists`, `create or replace`, a
-- guarded ADD CONSTRAINT and a VALIDATE that is a no-op once validated. CI
-- applies this file twice (tools/audit/run_database_regression.py).
--
-- KEEP IN SYNC: services/edge/tour-host/public/pricing.html, the App Store
-- description ("WHAT A PLAN INCLUDES"), functions/coach/knowledge.ts
-- PLAN_ALLOWANCES and apps/ios CoachOffline — tests/invariants.sql asserts
-- the table equals these numbers.

-- ── 1. Paid plans ────────────────────────────────────────────────────────────
-- Every column, including price_cents and cogs_ceiling_cents, so a replay of
-- 0010 (which re-upserts the 2026-09-01 sizes) followed by this file lands on
-- exactly this matrix. trial/free are the 0032 rows and are not touched here.

insert into public.plan_entitlements
  (plan, renders_per_month, photo_edits_per_month, reels_per_month, aerials_per_month, topaz_per_month, seats, cogs_ceiling_cents, price_cents)
values
  ('starter',  4, 100,  6, 2, 0, 1, 1200,  4900),
  ('solo',     4, 100,  6, 2, 0, 1, 1200,  4900),
  ('pro',     10, 200, 12, 4, 0, 1, 2400,  9900),
  ('team',    25, 400, 25, 8, 2, 2, 6000, 24900)
on conflict (plan) do update set
  renders_per_month     = excluded.renders_per_month,
  photo_edits_per_month = excluded.photo_edits_per_month,
  reels_per_month       = excluded.reels_per_month,
  aerials_per_month     = excluded.aerials_per_month,
  topaz_per_month       = excluded.topaz_per_month,
  seats                 = excluded.seats,
  cogs_ceiling_cents    = excluded.cogs_ceiling_cents,
  price_cents           = excluded.price_cents;

-- ── 2. Per-industry overrides (sparse: NULL = inherit the base row) ──────────

create table if not exists public.plan_entitlement_overrides (
  plan                  text not null references public.plan_entitlements(plan),
  space_type            text not null
                        constraint plan_entitlement_overrides_space_type_check
                        check (space_type in ('real_estate','venue','restaurant','retail','fitness','other')),
  renders_per_month     integer,
  photo_edits_per_month integer,
  reels_per_month       integer,
  aerials_per_month     integer,
  topaz_per_month       integer,
  seats                 integer,
  cogs_ceiling_cents    integer,
  primary key (plan, space_type)
);

comment on table public.plan_entitlement_overrides is
  'Per-(plan, orgs.space_type) allowance overrides read by org_entitlement(). A NULL '
  'column inherits plan_entitlements. Only the trial carries rows (0044): the '
  'single-location industries get a 1-tour free week. No price column on purpose — '
  'price is a property of the plan, never of the industry.';

-- Same posture as plan_entitlements (0010 §2): readable by everyone (the app
-- shows allowances), writable only by the service role. ci-bootstrap mirrors
-- Supabase's default ALL grant, so the revoke is load-bearing.
alter table public.plan_entitlement_overrides enable row level security;
drop policy if exists "entitlement overrides readable" on public.plan_entitlement_overrides;
create policy "entitlement overrides readable" on public.plan_entitlement_overrides for select using (true);
grant select on public.plan_entitlement_overrides to authenticated, anon;
revoke insert, update, delete on public.plan_entitlement_overrides from authenticated, anon;

insert into public.plan_entitlement_overrides
  (plan, space_type, renders_per_month, photo_edits_per_month, reels_per_month, aerials_per_month, topaz_per_month, seats, cogs_ceiling_cents)
values
  ('trial', 'venue',      1, 60, 4, 1, 1, null, 1000),
  ('trial', 'restaurant', 1, 60, 4, 1, 1, null, 1000),
  ('trial', 'retail',     1, 60, 4, 1, 1, null, 1000),
  ('trial', 'fitness',    1, 60, 4, 1, 1, null, 1000),
  ('trial', 'other',      1, 60, 4, 1, 1, null, 1000)
on conflict (plan, space_type) do update set
  renders_per_month     = excluded.renders_per_month,
  photo_edits_per_month = excluded.photo_edits_per_month,
  reels_per_month       = excluded.reels_per_month,
  aerials_per_month     = excluded.aerials_per_month,
  topaz_per_month       = excluded.topaz_per_month,
  seats                 = excluded.seats,
  cogs_ceiling_cents    = excluded.cogs_ceiling_cents;

-- ── 3. orgs.space_type is now a real enum ────────────────────────────────────
-- Exactly the six values functions/listings/index.ts and the iOS SpaceType
-- know. NOT VALID first (no scan under the ACCESS EXCLUSIVE lock), then
-- VALIDATE (SHARE UPDATE EXCLUSIVE, scans). The VALIDATE is unguarded on
-- purpose: an existing row outside the set must fail this migration.

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.orgs'::regclass
       and conname  = 'orgs_space_type_check'
  ) then
    alter table public.orgs
      add constraint orgs_space_type_check
      check (space_type in ('real_estate','venue','restaurant','retail','fitness','other'))
      not valid;
  end if;
end $$;

-- A no-op once the constraint is marked valid, a check_violation otherwise.
alter table public.orgs validate constraint orgs_space_type_check;

comment on column public.orgs.space_type is
  'The workspace''s industry (real_estate | venue | restaurant | retail | fitness | '
  'other). Written by PATCH /me/brand. Read by org_entitlement(): only the trial '
  'plan is industry-aware (0044).';

-- ── 4. org_entitlement(): the one read path for what an org may spend ────────
-- Same grants and security as effective_plan()/plan_entitlement() (0010 §3,
-- 0019 §5): STABLE, pinned search_path, SECURITY INVOKER like them.
-- create_render_job()/log_job_cost() call it from their own definer context;
-- the edge functions call it with the service role; a signed-in tenant may
-- call it for an org its RLS lets it read.
--
-- The base row is copied whole and then overridden column by column, so a
-- column added to plan_entitlements later simply inherits (an explicit SQL
-- select list would stop matching the composite return type at call time and
-- take create_render_job() down with it).

create or replace function public.org_entitlement(p_org uuid)
returns public.plan_entitlements
language plpgsql stable
set search_path = public
as $$
declare
  v_base public.plan_entitlements;
  v_over public.plan_entitlement_overrides;
begin
  v_base := plan_entitlement(effective_plan(p_org));

  select o.* into v_over
    from plan_entitlement_overrides o
    join orgs g on g.id = p_org
   where o.plan = v_base.plan and o.space_type = g.space_type;
  if found then
    v_base.renders_per_month     := coalesce(v_over.renders_per_month,     v_base.renders_per_month);
    v_base.photo_edits_per_month := coalesce(v_over.photo_edits_per_month, v_base.photo_edits_per_month);
    v_base.reels_per_month       := coalesce(v_over.reels_per_month,       v_base.reels_per_month);
    v_base.aerials_per_month     := coalesce(v_over.aerials_per_month,     v_base.aerials_per_month);
    v_base.topaz_per_month       := coalesce(v_over.topaz_per_month,       v_base.topaz_per_month);
    v_base.seats                 := coalesce(v_over.seats,                 v_base.seats);
    v_base.cogs_ceiling_cents    := coalesce(v_over.cogs_ceiling_cents,    v_base.cogs_ceiling_cents);
  end if;

  return v_base;
end;
$$;

comment on function public.org_entitlement(uuid) is
  'The allowances an org is entitled to right now: plan_entitlement(effective_plan(org)) '
  'with every numeric column coalesced against plan_entitlement_overrides for '
  '(that plan, orgs.space_type). Unknown org -> the trial base row, like plan_entitlement().';

revoke execute on function public.org_entitlement(uuid) from public, anon;
grant  execute on function public.org_entitlement(uuid) to authenticated, service_role;

-- ── 5. create_render_job(): the monthly cap reads org_entitlement() ──────────
-- Reproduced verbatim from 0015 §3 (the LATEST definition: 0011's signature,
-- 0015's lease-aware in-flight predicate). Signature, security definer,
-- search_path, every authorization check, the in-flight cap, the RP402 message
-- format and the grants are UNCHANGED. The single edit is the cap lookup:
--
--     was:  v_cap := coalesce(plan_render_cap(v_plan), 0);
--     now:  select renders_per_month into v_cap from public.org_entitlement(v_org);
--           v_cap := coalesce(v_cap, 0);
--
-- v_plan is still effective_plan() so the message keeps naming the plan.

create or replace function public.create_render_job(
  p_listing uuid,
  p_asset uuid,
  p_tier text default 'smooth',
  p_enhancements jsonb default '{}'::jsonb,
  p_idem text default null,
  p_source text default 'worker'
) returns public.render_jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_role text;
  v_plan text;
  v_cap integer;
  v_used integer;
  v_active integer;
  v_recent integer;
  v_job render_jobs;
  v_asset capture_assets;
  v_source text := coalesce(nullif(trim(p_source), ''), 'worker');
  v_idem text := case when p_idem is not null and length(p_idem) between 8 and 128 then p_idem else null end;
begin
  if v_source not in ('worker','app') then
    raise exception 'RP400: source must be worker or app';
  end if;

  select l.org_id into v_org from listings l where l.id = p_listing and l.deleted_at is null;
  if v_org is null then raise exception 'RP404: listing not found'; end if;

  -- Role, not just membership: marketing is read-only on product data and must
  -- not be able to spend the workspace's paid render entitlement.
  v_role := org_role(v_org);
  if v_role is null then raise exception 'RP403: not a member of this workspace'; end if;
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit creating renders';
  end if;

  -- The asset must exist for this listing AND actually be uploaded (audit:
  -- creating a job for an unuploaded asset burned entitlement, then failed).
  select a.* into v_asset from capture_assets a
    where a.id = p_asset and a.listing_id = p_listing and a.uploaded is true;
  if not found then
    raise exception 'RP409: asset not found for this listing, or its upload is not complete';
  end if;
  -- An app publish must point at a role=render upload; checking here (not only
  -- in publish_render) means a bad asset fails BEFORE a job row exists.
  if v_source = 'app' then
    if coalesce(v_asset.bucket, 'uploads') <> 'renders' then
      raise exception 'RP400: an app publish must reference a role=render upload (renders bucket)';
    end if;
    if v_asset.kind <> 'video' then
      raise exception 'RP400: the publish asset must be a video';
    end if;
  end if;

  if p_tier not in ('smooth','premium4k','cinematic') then
    raise exception 'RP400: tier must be smooth, premium4k, or cinematic';
  end if;

  -- Fast path: an already-recorded idempotent replay.
  if v_idem is not null then
    select rj.* into v_job from render_jobs rj
      where rj.listing_id = p_listing and rj.idem_key = v_idem;
    if found then return v_job; end if;
  end if;

  -- Serialize job creation per org so caps can't be raced past.
  perform pg_advisory_xact_lock(hashtextextended('render_jobs:' || v_org::text, 42));

  -- RE-CHECK after the lock: a concurrent caller with the same key may have
  -- inserted while we waited (audit: the loser hit the unique index).
  if v_idem is not null then
    select rj.* into v_job from render_jobs rj
      where rj.listing_id = p_listing and rj.idem_key = v_idem;
    if found then return v_job; end if;
  end if;

  -- Self-heal: an app-source job that never reached publish_render (a crash
  -- between the two RPCs) is dead after an hour. Mark it failed so it can never
  -- be mistaken for in-flight work by anything that lists this org's jobs.
  update render_jobs rj
     set status = 'failed',
         finished_at = now(),
         error = coalesce(rj.error, '{}'::jsonb)
                 || jsonb_build_object('message', 'publish did not complete', 'code', 'stale_app_job')
    from listings l
   where l.id = rj.listing_id and l.org_id = v_org
     and rj.source = 'app' and rj.status = 'created'
     and rj.created_at < now() - interval '1 hour';

  if v_source = 'worker' then
    -- In-flight guard counts ONLY worker jobs: app jobs are transient (created →
    -- ready in the same request) and must never lock a workspace (F-supabase-05).
    select count(*) into v_active
      from render_jobs rj join listings l on l.id = rj.listing_id
      where l.org_id = v_org and rj.source = 'worker'
        and (
          rj.status in ('created','queued','claimed')
          or (rj.status = 'processing'
              and (rj.lease_expires_at is null or rj.lease_expires_at > now()))
        );
    if v_active >= 3 then
      raise exception 'RP429: this workspace already has % renders in flight — wait for one to finish', v_active;
    end if;

    -- Monthly cap from org_entitlement() — plan_entitlements via effective_plan()
    -- (an expired trial is `free` here exactly as it is for the AI routes),
    -- coalesced against the org's industry override (0044: the single-location
    -- free week). App publishes are excluded from the count: pricing promises
    -- publishing is free.
    v_plan := coalesce(effective_plan(v_org), 'free');
    select renders_per_month into v_cap from public.org_entitlement(v_org);
    v_cap := coalesce(v_cap, 0);
    select count(*) into v_used
      from render_jobs rj join listings l on l.id = rj.listing_id
      where l.org_id = v_org and rj.source = 'worker'
        and rj.created_at >= date_trunc('month', now());
    if v_used >= v_cap then
      raise exception 'RP402: monthly render limit reached for the % plan (% of %)', v_plan, v_used, v_cap;
    end if;
  else
    -- Free, but not unbounded: a runaway client loop must not mint slugs forever.
    select count(*) into v_recent
      from render_jobs rj join listings l on l.id = rj.listing_id
      where l.org_id = v_org and rj.source = 'app'
        and rj.created_at >= now() - interval '1 hour';
    if v_recent >= 60 then
      raise exception 'RP429: too many publishes in the last hour for this workspace — try again later';
    end if;
  end if;

  insert into render_jobs (listing_id, capture_asset_id, tier, enhancements, status, progress, idem_key, source)
  values (p_listing, p_asset, p_tier, coalesce(p_enhancements, '{}'::jsonb), 'created', 0, v_idem, v_source)
  returning * into v_job;
  return v_job;
end;
$$;

revoke execute on function public.create_render_job(uuid, uuid, text, jsonb, text, text) from public, anon;
grant  execute on function public.create_render_job(uuid, uuid, text, jsonb, text, text) to authenticated, service_role;

-- ── 6. log_job_cost(): the monthly ceiling reads org_entitlement() ───────────
-- Reproduced verbatim from 0024 (the LATEST definition: 0010's body plus the
-- per-org advisory lock). Signature, security definer, search_path, per-job
-- cap, lock, error messages and grants are UNCHANGED. The single edit:
--
--     was:  select cogs_ceiling_cents into v_ceiling from plan_entitlement(v_plan);
--     now:  select cogs_ceiling_cents into v_ceiling from public.org_entitlement(v_org);

create or replace function public.log_job_cost(
  p_job uuid,
  p_org uuid,
  p_feature text,
  p_provider text,
  p_model text,
  p_units numeric,
  p_unit_cost numeric,
  p_meta jsonb,
  p_cap_cents numeric
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total numeric;
  v_line numeric;
  v_org uuid := p_org;
  v_plan text;
  v_ceiling integer;
  v_month numeric;
begin
  perform 1 from render_jobs where id = p_job for update;
  if not found then raise exception 'RP404: render job not found'; end if;

  -- Resolve the org from the job when the caller didn't supply one, so the
  -- monthly ceiling can never be skipped by omitting org_id.
  if v_org is null then
    select l.org_id into v_org
      from render_jobs rj join listings l on l.id = rj.listing_id
     where rj.id = p_job;
  end if;

  select coalesce(sum(total_cents), 0) into v_total from cost_ledger where job_id = p_job;
  v_line := round((coalesce(p_units, 1) * coalesce(p_unit_cost, 0))::numeric, 4);

  -- Per-job cap (unchanged).
  if v_total + v_line > p_cap_cents then
    raise exception 'RP402: cost cap exceeded — job at %¢, +%¢ would pass the %¢ cap', v_total, v_line, p_cap_cents;
  end if;

  -- Per-org MONTHLY ceiling.
  if v_org is not null then
    -- audit P0-3: serialize read+insert per org so two concurrent jobs can
    -- never both read the pre-spend total and both pass. Acquired BEFORE the
    -- sum below and held for the rest of this transaction (through the
    -- insert), so a second caller for the same org blocks here until the
    -- first caller's transaction actually completes, then sees the true,
    -- up-to-date total rather than a stale snapshot.
    perform pg_advisory_xact_lock(hashtextextended('org_month_spend:' || v_org::text, 42));

    v_plan := effective_plan(v_org);
    select cogs_ceiling_cents into v_ceiling from public.org_entitlement(v_org);
    v_month := org_month_spend_cents(v_org);
    if v_ceiling is not null and v_month + v_line > v_ceiling then
      raise exception
        'RP402: monthly AI spend ceiling reached for the % plan (%¢ of %¢) — upgrade or wait for the next cycle',
        v_plan, round(v_month), v_ceiling;
    end if;
  end if;

  insert into cost_ledger (job_id, org_id, feature, provider, model, units, unit_cost_cents, total_cents, meta)
  values (p_job, v_org, p_feature, p_provider, p_model, coalesce(p_units, 1), coalesce(p_unit_cost, 0), v_line, coalesce(p_meta, '{}'::jsonb));

  update render_jobs set cost_cents = round(v_total + v_line) where id = p_job;
  return v_total + v_line;
end;
$$;

revoke execute on function public.log_job_cost(uuid, uuid, text, text, text, numeric, numeric, jsonb, numeric) from public, anon, authenticated;
grant  execute on function public.log_job_cost(uuid, uuid, text, text, text, numeric, numeric, jsonb, numeric) to service_role;
