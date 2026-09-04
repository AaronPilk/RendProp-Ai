-- 0010: profitable plan entitlements + the per-org monthly spend ceiling.
--
-- Production history: supabase_migrations.schema_migrations version
-- 20260901192239 "pricing_entitlements_and_spend_ceiling" — never committed
-- (audit F-supabase-03). This is the "migration 0010" that
-- functions/_shared/entitlements.ts, ai-photo and ai-video refer to. Verified
-- 2026-09-03 against project ymgqpbnjpztwjsyvceld: the live plan_entitlements
-- rows, orgs.trial_ends_at, effective_plan(), plan_entitlement(),
-- plan_render_cap(), org_month_spend_cents() and log_job_cost() match this text.
--
-- Idempotent: `if not exists` / `create or replace` / upsert seeds. The one
-- function 0011 later changes (handle_new_user) is guarded so a replay of this
-- file alone cannot regress the 0011 org-name fix.
--
-- Grounded in measured COGS (services/pipeline/providers/costs.py + fal/Google
-- list prices), NOT guesswork:
--   tour render (server ffmpeg, 90s out) .... $0.0075   <- the CHEAP thing
--   AI photo edit (Gemini 2.5 Flash Image) .. $0.039
--   reel clip (Seedance 1.0 Pro Fast, 5s) ... $0.24
--   AI aerial (Veo 3.1 Fast, 8s 1080p) ...... $0.80     <- 3x a reel
--   Topaz drone glide 90s @1080p60 .......... $3.60     <- ADD-ON ONLY
--   Topaz 90s @4K30 / @4K60 ................. $7.20 / $14.40
--   R2 egress ............................... $0.00     <- tours deliver free
--
-- The old caps rationed RENDERS (2/5/15) — the one unit that costs under a
-- cent — while leaving 2,000 photo edits ($78) on a $249 plan. These
-- entitlements meter what actually costs money and hold ~75-78% gross margin
-- at FULL utilization. KEEP IN SYNC with services/edge/tour-host/public/pricing.html —
-- tests/invariants.sql asserts the two agree.

-- ── 1. Plans: add trial + solo/starter, and a trial expiry ─────────────────

alter table public.orgs drop constraint if exists orgs_plan_check;
alter table public.orgs add constraint orgs_plan_check
  check (plan in ('trial','free','solo','starter','pro','team'));

alter table public.orgs add column if not exists trial_ends_at timestamptz;

-- ── 2. One table = the single source of truth for every allowance ───────────
-- cogs_ceiling_cents is the hard monthly spend wall (~1.3x expected COGS) — the
-- backstop that makes any allowance mistake survivable.

create table if not exists public.plan_entitlements (
  plan                  text primary key,
  renders_per_month     integer not null,
  photo_edits_per_month integer not null,
  reels_per_month       integer not null,
  aerials_per_month     integer not null,
  topaz_per_month       integer not null default 0,
  seats                 integer not null default 1,
  cogs_ceiling_cents    integer not null,
  price_cents           integer not null default 0
);
alter table public.plan_entitlements enable row level security;
-- Readable by everyone (the app shows allowances); writable only by service role.
drop policy if exists "entitlements readable" on public.plan_entitlements;
create policy "entitlements readable" on public.plan_entitlements for select using (true);
grant select on public.plan_entitlements to authenticated, anon;
revoke insert, update, delete on public.plan_entitlements from authenticated, anon;

insert into public.plan_entitlements
  (plan, renders_per_month, photo_edits_per_month, reels_per_month, aerials_per_month, topaz_per_month, seats, cogs_ceiling_cents, price_cents)
values
  -- 7-day card-on-file trial. Max exposure ~$0.75.
  ('trial',   1,  10,   1,  0, 0, 1,   200,      0),
  -- Legacy/lapsed: read-only-ish floor, keeps existing tours alive.
  ('free',    1,  10,   1,  0, 0, 1,   200,      0),
  -- Starter $49  → COGS $10.95 @100% = 78% margin
  ('starter', 8,  150,  8,  2, 0, 1,  1500,   4900),
  -- 'solo' kept as an alias of starter so older rows keep working.
  ('solo',    8,  150,  8,  2, 0, 1,  1500,   4900),
  -- Pro $99     → COGS $24.55 @100% = 75% margin
  ('pro',    25,  300, 20,  6, 0, 1,  3200,   9900),
  -- Team $249   → COGS $63.00 @100% = 75% margin
  ('team',   80,  600, 40, 15, 2, 3,  8200,  24900)
on conflict (plan) do update set
  renders_per_month     = excluded.renders_per_month,
  photo_edits_per_month = excluded.photo_edits_per_month,
  reels_per_month       = excluded.reels_per_month,
  aerials_per_month     = excluded.aerials_per_month,
  topaz_per_month       = excluded.topaz_per_month,
  seats                 = excluded.seats,
  cogs_ceiling_cents    = excluded.cogs_ceiling_cents,
  price_cents           = excluded.price_cents;

-- ── 3. Lookup helpers ──────────────────────────────────────────────────────

create or replace function public.plan_entitlement(p_plan text)
returns public.plan_entitlements
language sql stable
set search_path = public
as $$
  select * from plan_entitlements
   where plan = coalesce(nullif(p_plan, ''), 'trial')
   union all
  select * from plan_entitlements where plan = 'trial'
   limit 1;
$$;

/** The plan an org is actually entitled to right now. An expired trial falls
 *  back to 'free' so a lapsed card can't keep spending. */
create or replace function public.effective_plan(p_org uuid)
returns text
language sql stable
set search_path = public
as $$
  select case
           when o.plan = 'trial' and o.trial_ends_at is not null and o.trial_ends_at < now()
             then 'free'
           else coalesce(o.plan, 'trial')
         end
    from orgs o where o.id = p_org;
$$;

-- Render cap now reads the table (replaces the 0009 hardcoded version).
create or replace function public.plan_render_cap(p_plan text) returns integer
language sql stable
set search_path = public
as $$
  select renders_per_month from plan_entitlement(p_plan);
$$;

-- ── 4. Per-org MONTHLY spend ceiling ────────────────────────────────────────
-- The per-JOB cap ($25) never stopped an org from running many jobs. This is
-- the real denial-of-wallet backstop: total metered provider spend per calendar
-- month, per org, enforced inside the same row-locked ledger write.

create or replace function public.org_month_spend_cents(p_org uuid)
returns numeric
language sql stable
set search_path = public
as $$
  select coalesce(sum(total_cents), 0)
    from cost_ledger
   where org_id = p_org
     and created_at >= date_trunc('month', now());
$$;

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
    v_plan := effective_plan(v_org);
    select cogs_ceiling_cents into v_ceiling from plan_entitlement(v_plan);
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

revoke execute on function public.org_month_spend_cents(uuid) from public, anon;
grant  execute on function public.org_month_spend_cents(uuid) to authenticated, service_role;
revoke execute on function public.effective_plan(uuid) from public, anon;
grant  execute on function public.effective_plan(uuid) to authenticated, service_role;
grant  execute on function public.plan_entitlement(text) to authenticated, anon, service_role;

-- ── 5. New signups start a 7-day trial ─────────────────────────────────────
-- Guarded: 0011 replaces this body (org name from user metadata, never the
-- email). Only install this version when the trigger function is still the
-- 0001 shape (org name = email) or missing, so replaying 0010 after 0011 is a
-- no-op rather than a regression.
do $$
declare v_src text;
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'handle_new_user';
  if v_src is not null and v_src like '%My business%' and v_src not like '%coalesce(new.email%' then
    raise notice '0010: handle_new_user already carries the 0011 org-name fix — skipping';
    return;
  end if;

  execute $fn$
    create or replace function public.handle_new_user() returns trigger
    language plpgsql security definer set search_path = public as $body$
    declare new_org uuid;
    begin
      insert into public.profiles (id, email, name)
      values (new.id, new.email, coalesce(new.raw_user_meta_data->>'name', ''))
      on conflict (id) do nothing;
      insert into public.orgs (name, plan, trial_ends_at)
      values (coalesce(new.email, 'My business'), 'trial', now() + interval '7 days')
      returning id into new_org;
      insert into public.memberships (user_id, org_id, role) values (new.id, new_org, 'owner');
      return new;
    end; $body$;
  $fn$;
end $$;
