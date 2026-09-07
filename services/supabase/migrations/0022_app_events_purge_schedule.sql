-- 0022: nightly analytics purge (2026-09-05). app_events must not grow forever:
-- purge_app_events(interval) (0020) deletes rows older than the retention window,
-- measured on received_at, and is created UNCONDITIONALLY in 0020 regardless of
-- what this migration can do — it can always be called by hand or wired to an
-- external scheduler. This migration only tries to put pg_cron in charge of
-- calling it at 04:17 UTC daily. Idempotent: the job is unscheduled first if it
-- already exists. Applied to production 2026-09-05.
--
-- pg_cron is a shared_preload_libraries extension — it must be compiled in and
-- loaded at server start, so a plain/off-the-shelf Postgres (a bare `postgres:16`
-- image, most local dev installs) simply does not have it, with no control file
-- to install from. `create extension pg_cron` on such a host does not no-op, it
-- ERRORS ("extension \"pg_cron\" is not available"), which is what turned the
-- CI `db-migrations` job red: it replays every migration against plain
-- `postgres:16`. So the block below is a GUARD, not a courtesy: it checks
-- pg_available_extensions before attempting the extension, then pg_extension
-- before attempting to schedule, and RAISES NOTICE (loudly, in the migration
-- run's own log) on either miss instead of silently skipping.
--
-- ** THIS IS A MANUAL GATE IN PRODUCTION, NOT JUST IN CI. ** A fresh Supabase
-- project does not have pg_cron enabled by default either. If this migration's
-- log shows the "pg_cron is not available" (or "did not finish") notice, the
-- nightly purge is NOT scheduled and app_events will grow without bound until
-- a human enables pg_cron (Dashboard → Database → Extensions) and re-runs
-- this file (safe: everything below is idempotent). See
-- services/supabase/DEPLOYMENT.md, "Scheduling the app_events purge (pg_cron
-- is a manual gate)".
--
-- Belt AND braces: the whole block also has an `exception when others`
-- fallback, because "available" turns out to have more failure modes than
-- "no control file" — e.g. pg_cron pins its SQL objects to exactly ONE
-- database cluster-wide (`cron.database_name`; verified live while writing
-- this fix, on a shared cluster where another process had pg_cron loaded but
-- pointed at a different database: `create extension pg_cron` there is a hard
-- ERROR — "can only create extension in database X" — not a graceful no-op).
-- Any such surprise now degrades to the same loud notice instead of aborting
-- this migration (and every migration after it, since CI applies them in one
-- transaction each but in one continuous run).
do $$
declare
  v_id bigint;
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    execute 'create extension if not exists pg_cron';
  end if;

  -- Re-check via pg_extension (not the availability check above) so a
  -- create-extension that silently no-op'd for any other reason also
  -- degrades to the same loud skip, rather than proceeding to schedule
  -- against a `cron` schema that was never actually installed.
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute 'grant usage on schema cron to postgres';

    select jobid into v_id from cron.job where jobname = 'purge-app-events';
    if v_id is not null then perform cron.unschedule(v_id); end if;
    perform cron.schedule('purge-app-events', '17 4 * * *',
      $job$ select public.purge_app_events(interval '180 days'); $job$);

    raise notice '0022: pg_cron is available — purge-app-events scheduled for 04:17 UTC daily (calls public.purge_app_events(''180 days'')).';
  else
    raise notice '0022: pg_cron is NOT available on this Postgres — the nightly app_events purge was NOT scheduled. public.purge_app_events() (created unconditionally in 0020) still exists and can be invoked manually or from an external scheduler (e.g. a Cloudflare Worker cron trigger). THIS IS A MANUAL GATE: once pg_cron is enabled, re-run this migration to schedule it. See services/supabase/DEPLOYMENT.md.';
  end if;
exception
  when others then
    -- Never let a pg_cron surprise (wrong cron.database_name, a permission
    -- quirk, anything not anticipated above) fail this migration outright.
    -- purge_app_events() (0020) is unaffected either way.
    raise notice '0022: pg_cron setup did not finish (% — %) — the nightly app_events purge was NOT scheduled. public.purge_app_events() still exists and can be invoked manually or from an external scheduler. THIS IS A MANUAL GATE: resolve whatever this reports on THIS server, then re-run this migration. See services/supabase/DEPLOYMENT.md.', SQLSTATE, SQLERRM;
end $$;
