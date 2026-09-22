-- 0049: call the drain (2026-09-12). 0047 built the whole notification pipeline
-- except its last link. `notification_tick()` (scheduled by 0047 every 15 minutes)
-- ENQUEUES rows; `functions/notify` DELIVERS them. Nothing called the deliverer,
-- so the outbox would fill and never empty — verified live on 2026-09-12 right
-- after 0047 went out: cron.job held `notification-tick` and nothing else.
--
-- Postgres cannot invoke an edge function on its own. pg_net can: it issues an
-- ASYNC HTTP request from a background worker, so `net.http_post` returns a
-- request id immediately and never blocks the cron slot on Apple's or Resend's
-- latency. That is the whole reason this is pg_net and not a foreign data
-- wrapper or a plpython block.
--
-- ── THE KEY ──────────────────────────────────────────────────────────────────
-- functions/notify is service-role only, on purpose (a caller that could drain
-- the outbox could read every workspace's messages out of a claimed batch,
-- 0047 says so at notify/index.ts:58-60). So the drain has to present the
-- service-role key, and that key must not sit in plaintext in `cron.job.command`
-- where every `select * from cron.job` would show it. It is read at call time
-- from Supabase Vault (`vault.decrypted_secrets`), which is installed on this
-- project. The secret is INSERTED SEPARATELY, never by this file — see
-- DEPLOYMENT.md §11. Until it exists, `notification_drain()` raises a notice and
-- returns null: the queue simply waits, exactly as it does with no APNs key.
--
-- ── IDEMPOTENT ───────────────────────────────────────────────────────────────
-- `create or replace`, `if not exists`, and the job is unscheduled before it is
-- scheduled. CI applies this file twice.
--
-- ── GUARDED, in the same shape as 0022 ───────────────────────────────────────
-- pg_net, like pg_cron, does not exist on a plain `postgres:16`, and CI replays
-- every migration against exactly that. Availability is checked before the
-- extension, pg_extension is re-checked before scheduling, and the whole thing
-- sits under `exception when others` so a surprise degrades to a loud NOTICE
-- rather than failing this migration and every migration after it.
--
-- ** MANUAL GATE. ** If the run log shows either notice below, delivery is NOT
-- scheduled. Nothing is lost while it is unscheduled — rows stay `queued` until
-- 0047's sweep expires them at 72h — but nothing is sent either.

-- ── 1. the drain caller ──────────────────────────────────────────────────────
-- Unconditional: the function is created whatever this Postgres can schedule,
-- so it can always be called by hand or from an external scheduler. It is the
-- scheduling below that is conditional.

create or replace function public.notification_drain(p_limit integer default 50)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key     text;
  v_base    text;
  v_request bigint;
begin
  -- Nothing to send: skip the HTTP round trip entirely. `queued` here means
  -- due now — notification_claim_batch() applies the same scheduled_for filter,
  -- so this predicate and the claim cannot disagree about what is drainable.
  if not exists (
    select 1 from public.notification_outbox
     where state = 'queued' and scheduled_for <= now()
  ) then
    return null;
  end if;

  -- The key and the project base come from Vault, not from this file and not
  -- from the job command. A missing secret is a wait, never an error.
  begin
    select decrypted_secret into v_key
      from vault.decrypted_secrets where name = 'notify_service_key';
    select decrypted_secret into v_base
      from vault.decrypted_secrets where name = 'notify_functions_base';
  exception when others then
    raise notice '0049: Vault is not readable (% — %) — nothing drained.', SQLSTATE, SQLERRM;
    return null;
  end;

  if v_key is null or v_base is null then
    raise notice '0049: the Vault secrets notify_service_key / notify_functions_base are not set — the outbox is NOT being drained. See DEPLOYMENT.md section 11.';
    return null;
  end if;

  -- ASYNC by design: net.http_post queues the request in pg_net's worker and
  -- returns at once, so a slow APNs or Resend call can never hold the cron
  -- slot. The reply is not inspected here — functions/notify records every
  -- outcome on the row itself (state, attempts, last_error), and 0047's sweep
  -- returns a batch whose drain died. Reading net._http_response would only
  -- duplicate that, one layer further from the truth.
  select net.http_post(
           url     := rtrim(v_base, '/') || '/notify?limit=' || greatest(1, least(200, p_limit))::text,
           headers := jsonb_build_object(
                        'Authorization', 'Bearer ' || v_key,
                        'Content-Type',  'application/json'),
           body    := '{}'::jsonb,
           timeout_milliseconds := 25000
         ) into v_request;

  return v_request;
end;
$$;

comment on function public.notification_drain(integer) is
  'Asks functions/notify to deliver the due outbox rows, via an async pg_net POST '
  'authenticated with the service-role key from Vault (notify_service_key + '
  'notify_functions_base). Returns the pg_net request id, or null when there is '
  'nothing due or the secrets are unset. Scheduled every minute by 0049; safe to '
  'call by hand. Concurrent calls are safe — notification_claim_batch() locks '
  'FOR UPDATE SKIP LOCKED (0047).';

revoke execute on function public.notification_drain(integer) from public, anon, authenticated;
grant  execute on function public.notification_drain(integer) to service_role;

-- ── 2. schedule it ───────────────────────────────────────────────────────────
-- Every minute. The function returns immediately when the outbox is empty, so
-- the cost of a quiet minute is one index probe on (state, scheduled_for) —
-- and a lead notification that waits fifteen minutes is not a lead
-- notification. This is the one message whose latency is the product.

do $$
declare
  v_id bigint;
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    execute 'create extension if not exists pg_net';
  end if;

  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice '0049: pg_net is NOT available on this Postgres — the outbox drain was NOT scheduled. public.notification_drain() exists and can be called from an external scheduler (a Cloudflare Worker cron trigger hitting POST /notify with the service-role key is the documented alternative). THIS IS A MANUAL GATE: enable pg_net (Dashboard -> Database -> Extensions) and re-run this migration.';
    return;
  end if;

  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice '0049: pg_cron is NOT available on this Postgres — the outbox drain was NOT scheduled, though pg_net is present. public.notification_drain() can still be called externally. THIS IS A MANUAL GATE: see 0022 and DEPLOYMENT.md.';
    return;
  end if;

  execute 'grant usage on schema cron to postgres';

  select jobid into v_id from cron.job where jobname = 'notification-drain';
  if v_id is not null then perform cron.unschedule(v_id); end if;
  perform cron.schedule('notification-drain', '* * * * *',
    $job$ select public.notification_drain(50); $job$);

  raise notice '0049: pg_net and pg_cron are available — notification-drain scheduled every minute (calls public.notification_drain(50)). Delivery still requires the Vault secrets notify_service_key and notify_functions_base, plus the APNs and/or Resend secrets on the function.';
exception
  when others then
    raise notice '0049: drain scheduling did not finish (% — %) — the outbox is NOT being drained automatically. public.notification_drain() still exists and can be called externally. THIS IS A MANUAL GATE: resolve whatever this reports on THIS server, then re-run this migration.', SQLSTATE, SQLERRM;
end $$;
