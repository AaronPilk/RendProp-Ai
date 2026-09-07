-- 0024: close the per-org monthly AI spend ceiling race (audit P0-3, critical).
--
-- log_job_cost() (0010_pricing_entitlements_and_spend_ceiling.sql) takes a row
-- lock on the JOB it's logging for ("perform 1 from render_jobs where id =
-- p_job for update"), but two DIFFERENT jobs for the SAME org never contend
-- for that lock — each locks its own row. That leaves the per-org MONTHLY
-- ceiling check completely unserialized across concurrent jobs:
--
--   select ... into v_month from cost_ledger where org_id = v_org ...   -- READ
--   if v_month + v_line > v_ceiling then raise exception ...            -- CHECK
--   insert into cost_ledger (...) ...                                   -- ACT
--
-- Two concurrent render jobs for the same org can both run READ before
-- either runs ACT: both see the same pre-spend total, both pass CHECK, both
-- insert — a classic TOCTOU race that lets total spend sail past the
-- ceiling by however much the racing jobs cost. Verified live 2026-09-07
-- against a local Postgres (database `rendprop`, migrations 0001-0023
-- already applied): with a $2.00 ceiling and $0 spent this month, two
-- genuinely concurrent $1.50 jobs for the same org BOTH passed and BOTH
-- inserted — final spend $3.00, 50% over a ceiling neither job should have
-- been able to clear alone twice over. Full transcript in
-- docs/handoff/audit-fixes.md.
--
-- Fix: take a per-ORG pg_advisory_xact_lock BEFORE reading the monthly
-- total — exactly the pattern 0015_job_lease.sql (render job creation) and
-- 0016_enhancement_outcome.sql (publish_render) already use for their own
-- per-org / per-job races. A distinct string prefix ('org_month_spend:')
-- keeps this lock's key space from colliding with theirs ('render_jobs:',
-- 'publish_render:'), since hashtextextended() hashes the whole prefixed
-- string, not just the bare id — same convention, new namespace.
--
-- The lock is transaction-scoped (pg_advisory_xact_lock, not
-- pg_advisory_lock) and taken from INSIDE the function body, so it's held
-- for exactly the lifetime of this one RPC call — a Postgres function
-- invocation runs as a single implicit transaction unless the caller wraps
-- several statements in an explicit BEGIN, which nothing in this codebase
-- does for log_job_cost. That covers the READ, the CHECK, the cost_ledger
-- INSERT and the render_jobs UPDATE under one lock hold, and releases it
-- automatically the instant the function returns or raises — never leaked
-- across calls, never held across a network round-trip.
--
-- Only reached when v_org is not null — a job with no resolvable org has no
-- monthly ceiling to enforce (unchanged from 0010), so there's nothing to
-- serialize and no lock is taken on that path.
--
-- Everything else — signature, per-job cap, error messages, grants — is
-- byte-for-byte unchanged: this is `create or replace function`, so every
-- existing caller (the worker pipeline, ai-photo, ai-video) keeps working
-- with no code change on their side. Idempotent (create or replace) like
-- every other migration in this repo.

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
