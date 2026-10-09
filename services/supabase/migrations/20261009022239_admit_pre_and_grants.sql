-- Launch audit fixes — 2026-10-09.
--
-- 1. serving_envelope_admit netted the legacy video/erase hold for the same
--    request key EVEN WHEN serving_ceiling_spent_cents had already excluded it
--    (it is excluded once a live serving reservation exists for that key), so
--    every later admission under that key was under-counted by the whole video
--    hold. `pre` now counts only holds that spent actually includes.
-- 2. Index the settlement FK (serving_cost_reservations.ledger_id).
-- 3. Client roles never need TRUNCATE / TRIGGER / REFERENCES on public tables.
-- Replay-safe: create-or-replace, if-not-exists, idempotent revokes.
begin;

create or replace function public.serving_envelope_admit(p_org uuid,p_hold_cents numeric,p_request_key text)returns jsonb
language plpgsql security definer set search_path='' as $$
declare env jsonb;ceiling numeric;kind text;ps timestamptz;pe timestamptz;spent numeric;pre numeric;pool jsonb;pool_spent numeric;
begin
 if p_hold_cents is null or p_hold_cents<=0 then raise exception 'RP400: A positive hold is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||p_org::text,42));
 env:=public.plan_serving_ceiling(p_org);
 ceiling:=(env->>'ceiling_cents')::numeric;kind:=env->>'kind';ps:=(env->>'period_start')::timestamptz;pe:=(env->>'period_end')::timestamptz;
 if kind='sponsored' then return env||jsonb_build_object('spent_cents',0,'hold_cents',p_hold_cents);end if;
 spent:=public.serving_ceiling_spent_cents(p_org,ps,pe);
 -- The first serving reservation for an attempt that already holds money
 -- through the legacy video/erase writer replaces that hold rather than adding
 -- to it. Only net holds that `spent` still counts: once a live serving
 -- reservation exists for the key, spent has already excluded them.
 pre:=0;
 if p_request_key is not null and not exists(select 1 from public.serving_cost_reservations r
   where r.org_id=p_org and r.request_key=p_request_key and r.budget_source='ceiling' and r.ledger_id is null and r.state<>'rejected')then
  pre:=coalesce((select sum(v.hold_cents)from public.app_video_cost_reservations v where v.org_id=p_org and v.idempotency_key=p_request_key and v.cost_ledger_id is null and v.released_at is null
     and(ps is null or v.created_at>=ps)and(pe is null or v.created_at<pe)),0)
   +coalesce((select sum(j.cost_cents)from public.video_erase_jobs j where j.org_id=p_org and j.idempotency_key::text=p_request_key and j.provider='fal' and j.cost_ledger_id is null and j.cost_hold_released_at is null
     and(ps is null or j.created_at>=ps)and(pe is null or j.created_at<pe)),0);
 end if;
 spent:=greatest(0,spent-pre);
 if ceiling is null or spent+p_hold_cents>ceiling then
  raise exception 'RP402: AI usage limit reached [kind=%] (% of % cents this %)',kind,round(spent),coalesce(ceiling,0),case when ps is null then 'lifetime' else 'period' end;end if;
 if kind='trial' then
  perform pg_advisory_xact_lock(hashtextextended('serving:trial-sponsor',72452));
  pool:=public.trial_sponsor_pool();
  if pool is null or now()<(pool->>'starts_at')::timestamptz or now()>=(pool->>'ends_at')::timestamptz then raise exception 'RP402: Free-trial AI limit reached [pool=closed]';end if;
  pool_spent:=public.trial_sponsor_spent_cents();
  if pool_spent+p_hold_cents>(pool->>'cap_cents')::numeric then raise exception 'RP402: Free-trial AI limit reached [pool=cap]';end if;
 end if;
 return env||jsonb_build_object('spent_cents',spent,'hold_cents',p_hold_cents);
end$$;
revoke all on function public.serving_envelope_admit(uuid,numeric,text)from public,anon,authenticated;
grant execute on function public.serving_envelope_admit(uuid,numeric,text)to service_role,postgres;

create index if not exists serving_cost_reservations_ledger_id on public.serving_cost_reservations(ledger_id)where ledger_id is not null;

revoke truncate, trigger, references on all tables in schema public from anon, authenticated;

commit;
