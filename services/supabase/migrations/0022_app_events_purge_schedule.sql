-- 0022: nightly analytics purge (2026-09-05). app_events must not grow forever:
-- purge_app_events(interval) (0020) deletes rows older than the retention window,
-- measured on received_at. pg_cron runs it at 04:17 UTC daily. Idempotent: the job
-- is unscheduled first if it already exists. Applied to production 2026-09-05.
create extension if not exists pg_cron;
grant usage on schema cron to postgres;

do $$
declare v_id bigint;
begin
  select jobid into v_id from cron.job where jobname = 'purge-app-events';
  if v_id is not null then perform cron.unschedule(v_id); end if;
  perform cron.schedule('purge-app-events', '17 4 * * *',
    $job$ select public.purge_app_events(interval '180 days'); $job$);
end $$;
