-- 0009: make enforced entitlement match PUBLISHED entitlement (2026-09-01).
--
-- Production history: supabase_migrations.schema_migrations version
-- 20260901183949 "plan_coherence" — never committed (audit F-supabase-03).
-- Superseded the SAME DAY by 0010, which replaces plan_render_cap() and the
-- orgs_plan_check constraint, and by 0011, which replaces create_render_job().
-- It is committed for history parity and so a fresh database passes through
-- the same states production did.
--
-- IDEMPOTENCY / REPLAY SAFETY: every statement is guarded so that re-running
-- this file on a database where 0010/0011 are already applied is a NO-OP.
-- Unguarded, a stray replay would (a) narrow orgs_plan_check back to four plans
-- and fail on any 'trial'/'starter' org, (b) reinstate hardcoded 2/5/15 render
-- caps, and (c) re-create the 5-argument create_render_job overload next to the
-- 6-argument one, which makes PostgREST RPC calls ambiguous.
--
-- Original rationale (2026-09-01): rendprop.com/pricing sold Solo/Pro/Team at
-- 2/5/15 AI tour renders per month. The database only had free/pro/team (no
-- 'solo' at all — a paying Solo customer had nowhere to land), and
-- create_render_job allowed 20/100/400, i.e. up to 27x the published number.

-- ── 1. orgs.plan gains 'solo' — only when still on the 0001 three-plan set ────
do $$
declare v_def text;
begin
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint
   where conrelid = 'public.orgs'::regclass and conname = 'orgs_plan_check';
  if v_def is null or v_def not like '%solo%' then
    execute 'alter table public.orgs drop constraint if exists orgs_plan_check';
    execute $c$alter table public.orgs add constraint orgs_plan_check
              check (plan in ('free','solo','pro','team'))$c$;
  end if;
end $$;

-- ── 2. plan_render_cap(): hardcoded 2/5/15 — only when no version exists yet ──
-- (0010 replaces it with the plan_entitlements-driven version.)
do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'plan_render_cap'
  ) then
    execute $fn$
      create function public.plan_render_cap(p_plan text) returns integer
      language sql immutable
      as $body$
        select case p_plan
                 when 'team' then 15
                 when 'pro'  then 5
                 when 'solo' then 2
                 else 2               -- free / early access = Solo allowance
               end;
      $body$;
    $fn$;
  end if;
end $$;

-- ── 3. create_render_job(): cap via plan_render_cap() — 5-argument version ────
-- Only when the 6-argument version from 0011 (p_source) is NOT installed.
do $$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'create_render_job' and p.pronargs >= 6
  ) then
    raise notice '0009: create_render_job(p_source) already installed — skipping the 5-argument version';
    return;
  end if;

  execute $fn$
    create or replace function public.create_render_job(
      p_listing uuid,
      p_asset uuid,
      p_tier text default 'smooth',
      p_enhancements jsonb default '{}'::jsonb,
      p_idem text default null
    ) returns public.render_jobs
    language plpgsql
    security definer
    set search_path = public
    as $body$
    declare
      v_org uuid;
      v_role text;
      v_plan text;
      v_cap integer;
      v_used integer;
      v_active integer;
      v_job render_jobs;
      v_idem text := case when p_idem is not null and length(p_idem) between 8 and 128 then p_idem else null end;
    begin
      select l.org_id into v_org from listings l where l.id = p_listing and l.deleted_at is null;
      if v_org is null then raise exception 'RP404: listing not found'; end if;

      v_role := org_role(v_org);
      if v_role is null then raise exception 'RP403: not a member of this workspace'; end if;
      if v_role not in ('owner','admin','agent') then
        raise exception 'RP403: your role does not permit creating renders';
      end if;

      perform 1 from capture_assets a
        where a.id = p_asset and a.listing_id = p_listing and a.uploaded is true;
      if not found then
        raise exception 'RP409: asset not found for this listing, or its upload is not complete';
      end if;

      if p_tier not in ('smooth','premium4k','cinematic') then
        raise exception 'RP400: tier must be smooth, premium4k, or cinematic';
      end if;

      if v_idem is not null then
        select rj.* into v_job from render_jobs rj
          where rj.listing_id = p_listing and rj.idem_key = v_idem;
        if found then return v_job; end if;
      end if;

      perform pg_advisory_xact_lock(hashtextextended('render_jobs:' || v_org::text, 42));

      if v_idem is not null then
        select rj.* into v_job from render_jobs rj
          where rj.listing_id = p_listing and rj.idem_key = v_idem;
        if found then return v_job; end if;
      end if;

      select count(*) into v_active
        from render_jobs rj join listings l on l.id = rj.listing_id
        where l.org_id = v_org and rj.status in ('created','queued','claimed','processing');
      if v_active >= 3 then
        raise exception 'RP429: this workspace already has % renders in flight — wait for one to finish', v_active;
      end if;

      select o.plan into v_plan from orgs o where o.id = v_org;
      v_cap := plan_render_cap(coalesce(v_plan, 'free'));
      select count(*) into v_used
        from render_jobs rj join listings l on l.id = rj.listing_id
        where l.org_id = v_org and rj.created_at >= date_trunc('month', now());
      if v_used >= v_cap then
        raise exception 'RP402: monthly render limit reached for the % plan (% of %)', coalesce(v_plan,'free'), v_used, v_cap;
      end if;

      insert into render_jobs (listing_id, capture_asset_id, tier, enhancements, status, progress, idem_key)
      values (p_listing, p_asset, p_tier, coalesce(p_enhancements, '{}'::jsonb), 'created', 0, v_idem)
      returning * into v_job;
      return v_job;
    end;
    $body$;
  $fn$;

  execute 'revoke execute on function public.create_render_job(uuid, uuid, text, jsonb, text) from public, anon';
  execute 'grant  execute on function public.create_render_job(uuid, uuid, text, jsonb, text) to authenticated, service_role';
end $$;
