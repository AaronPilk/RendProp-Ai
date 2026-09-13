-- 0052: take two dated bombs out of the routing table (2026-09-13).
--
-- Found by an audit today, 19 days before the first one goes off.
--
-- ── BOMB ONE: the legacy rows ──────────────────────────────────────────────
-- `gemini-2.5-flash-image` shuts down 2026-10-02. Live traffic does NOT use it
-- — app_config.ai_router is enabled, so photo.* resolves to
-- gemini-3.1-flash-lite-image / gemini-3.1-flash-image / flux-pro/kontext, all
-- verified in production today. The danger is not what runs now; it is what
-- runs the moment anything falls back.
--
-- router.ts reverts to the `note='legacy'` row in THREE situations, and two of
-- them are one click away:
--   1. the router flag is turned off  (POST /admin/routing/flag)
--   2. the routing table read THROWS  (a transient DB error)
--   3. every enabled step for a task is disabled in the admin console
-- In all three it returns the legacy row with `enabled` forced true, bypassing
-- orderSteps entirely — so the retire_after filter never even runs. All six
-- photo.* legacy rows still named the dead model. A single admin toggle on
-- 2026-10-03 would have 502'd every photo edit in the product, and since the
-- chain is then length 1, runChain rethrows the vendor error rather than
-- producing a 503 anyone would recognise as a routing failure.
--
-- Pointing them at gemini-3.1-flash-image makes the fallback safe instead of
-- fatal. They stay `enabled=false` and stay legacy — nothing about the routing
-- behaviour changes, only what the parachute is made of.
--
-- ── BOMB TWO: haiku on the QC judge ────────────────────────────────────────
-- `claude-haiku-4-5` retires on or after 2026-10-15 and has no successor.
-- judge.qc_drift position 1 is haiku with claude-sonnet-5 at position 2, so the
-- edge path self-heals by failover — but silently, at 2x cost, on every single
-- QC judgement, and provider_health only records the submit for video tasks so
-- the circuit breaker would not even open. vision.room_label position 2 is the
-- same. Promote sonnet to position 1 and leave haiku behind it while it lives:
-- if it dies early the order is already right, and if it outlives the estimate
-- nothing is lost but a cent.
--
-- judge.fair_housing position 2 is deliberately left alone — its note says it
-- is an OR with step 3, not a failover, and the real fair-housing gate is the
-- offline regex in _shared/fairhousing.ts. Changing an OR term's order would
-- change the gate's meaning, and that gate is not something to touch casually.
--
-- ── WHAT THIS FILE DOES NOT FIX ────────────────────────────────────────────
-- The Python render worker does not read this table AT ALL — no reference to
-- ai_routes, resolveRoute or provider_health exists anywhere under
-- services/pipeline or services/worker. Its models are defaults in
-- services/pipeline/config.py, fixed in the same commit as this migration, and
-- its env vars live in the WORKER's environment, not in the Supabase function
-- secrets. Two places, always.
--
-- Idempotent: plain UPDATEs matched on the old value, so a second run is a
-- no-op and a partially-applied run completes.

-- ── 1. the legacy parachutes ────────────────────────────────────────────────

update public.ai_routes
   set model = 'gemini-3.1-flash-image',
       note  = 'legacy — repointed 2026-09-13 off gemini-2.5-flash-image, which '
               'shuts down 2026-10-02. This row is what router.ts runs when the '
               'flag is off, when the table read throws, or when every enabled '
               'step for the task is disabled; it bypasses orderSteps so a '
               'retire_after here would never be honoured.'
 where note like 'legacy%'
   and provider = 'gemini'
   and model = 'gemini-2.5-flash-image'
   and task like 'photo.%';

-- ── 2. the QC judge ─────────────────────────────────────────────────────────
-- Swap positions rather than deleting haiku: it still works today and it is
-- cheaper. This only changes which one is TRIED FIRST.

do $$
declare v_task text;
begin
  foreach v_task in array array['judge.qc_drift', 'vision.room_label'] loop
    -- only act if haiku is genuinely ahead of sonnet on this task
    if exists (
      select 1 from public.ai_routes h
       where h.task = v_task and h.model = 'claude-haiku-4-5' and h.enabled
         and exists (select 1 from public.ai_routes s
                      where s.task = v_task and s.model = 'claude-sonnet-5' and s.enabled
                        and s.position > h.position)
    ) then
      -- park haiku out of the way, promote sonnet, then put haiku behind it
      update public.ai_routes set position = 900
       where task = v_task and model = 'claude-haiku-4-5' and enabled;
      update public.ai_routes set position = 1
       where task = v_task and model = 'claude-sonnet-5' and enabled;
      update public.ai_routes
         set position = 2,
             note = 'demoted below claude-sonnet-5 on 2026-09-13: haiku-4-5 '
                    'retires >= 2026-10-15 with no successor. Kept enabled '
                    'because it still works and is cheaper; it is simply no '
                    'longer what a QC judgement depends on.'
       where task = v_task and model = 'claude-haiku-4-5' and position = 900;
      raise notice '0052: % — sonnet promoted to position 1, haiku demoted to 2', v_task;
    else
      raise notice '0052: % — no haiku-ahead-of-sonnet pair to swap, left alone', v_task;
    end if;
  end loop;
end $$;

-- ── 3. make the next one loud ───────────────────────────────────────────────
-- The CI invariant only asserts "no ENABLED step is past its retire_after", and
-- legacy rows carry retire_after = NULL by design, so nothing in the table can
-- currently warn about a model that is about to die on a path that executes.
-- This view is the thing a human or a cron can actually read.

create or replace view public.ai_routes_expiring as
  select task, position, provider, model, enabled,
         retire_after,
         (retire_after - current_date) as days_left,
         case
           when not enabled and note like 'legacy%' then 'fallback parachute'
           when not enabled                          then 'tombstone'
           else                                           'LIVE'
         end as kind
    from public.ai_routes
   where retire_after is not null
     and retire_after <= current_date + interval '90 days'
   order by retire_after, task, position;

comment on view public.ai_routes_expiring is
  'Every route with a retire_after inside 90 days, and what it would actually '
  'do. `kind = LIVE` is the one that matters — a model that still gets chosen. '
  'Read it before a model shutdown date, because nothing alerts on its own: '
  'the CI invariant runs against a rebuilt database on push only, and the '
  'legacy rows it cannot see are exactly the ones that run on a fallback.';

grant select on public.ai_routes_expiring to service_role;
