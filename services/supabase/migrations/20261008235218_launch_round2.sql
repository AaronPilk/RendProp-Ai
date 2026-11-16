-- Launch round 2 — 2026-10-08 (Codex review of f17d2bd).
--
-- 1. ONE money authority. serving_envelope_admit(org, hold, key) is the only
--    place that admits ceiling-mode money: serving_cost_reserve (photo, text,
--    voice, judges, helpers, video submits), app_video_cost_reserve (reel /
--    aerial / Topaz holds) and video_erase_reserve[_direct] (Bria / fal erase)
--    all call it under the same `org_month_spend:<org>` advisory lock.
-- 2. No timer. A hold stays counted until the ledger row for the same attempt
--    lands (cost_ledger AFTER INSERT trigger binds it: request_key + stage,
--    the app-video reservation id, the erase job id, then FIFO by provider
--    and model) or until a definitive non-billable rejection.
-- 3. Allocations follow the paid service window: monthly = the verified Apple
--    transaction's [purchase, expiry); annual = twelve purchase-anchored
--    slices; introductory week and Sandbox trials = their own window, once;
--    grace = the 16-day Apple billing-retry window; free = lifetime. Calendar
--    months only remain for manual, brokerage, sponsored and App Review plans.
-- 4. Sandbox receipts apply facts in signature order and never revive a
--    refunded receipt; every reply reports the CURRENT plan, source and deadline.
-- 5. The hosting-retention notice consumer resolves enrollments too.
-- 6. Admin alerts are re-validated at delivery (ops_alert_current) and labelled;
--    the trial sponsor pool is a dated, finite allocation; the Apple commission
--    assumption is 30% until the Small Business rate is seen on a payout;
--    pre-policy (before 2026-10-06) subscriptions keep their prior hosting.
begin;

create function pg_temp.rp_patch(fn regprocedure,needle text,replacement text)returns void
language plpgsql as $$
declare def text;n integer;
begin
 def:=pg_get_functiondef(fn);
 n:=(length(def)-length(replace(def,needle,'')))/length(needle);
 if n<>1 then raise exception 'launch-round2 migration: anchor for % found % times; refusing to patch',fn,n;end if;
 execute replace(def,needle,replacement);
end$$;
-- Replace everything from start_needle through end_needle (inclusive, each unique).
create function pg_temp.rp_splice(fn regprocedure,start_needle text,end_needle text,replacement text)returns void
language plpgsql as $$
declare def text;a integer;b integer;
begin
 def:=pg_get_functiondef(fn);
 if (length(def)-length(replace(def,start_needle,'')))/length(start_needle)<>1 then raise exception 'launch-round2 migration: start anchor for % not unique',fn;end if;
 if (length(def)-length(replace(def,end_needle,'')))/length(end_needle)<>1 then raise exception 'launch-round2 migration: end anchor for % not unique',fn;end if;
 a:=position(start_needle in def);b:=position(end_needle in def)+length(end_needle);
 if b<=a then raise exception 'launch-round2 migration: anchors out of order for %',fn;end if;
 execute left(def,a-1)||replacement||substr(def,b);
end$$;

-- ---------------------------------------------------------------- config
-- 30% until the Small Business Program rate is observed on a payout; the owner
-- flips it with one update. The trial pool is a dated allocation, not a meter.
update public.app_config set value=(value-'trial_sponsor_cap_cents')||jsonb_build_object(
 'apple_commission_bps',3000,
 'note','Monthly AI envelope = net-of-Apple receipts x (1 - net_margin) - hosting reserve, allocated per paid service window. apple_commission_bps 3000 until the Small Business Program rate is seen on a payout (then 1500). Trial money comes from app_config.trial_sponsor_pool.'),
 updated_at=now() where key='serving_envelope';
insert into public.app_config(key,value)values('trial_sponsor_pool',jsonb_build_object(
 'cap_cents',29000,'starts_at','2026-10-08T00:00:00Z','ends_at','2026-11-08T00:00:00Z',
 'note','Owner-approved launch allocation for introductory-week and Sandbox trial AI (USD 290). When it ends or is used up, trial attempts are refused until the owner records a new allocation.'))
on conflict(key)do nothing;

-- ---------------------------------------------------------------- reservations ↔ ledger
alter table public.serving_cost_reservations add column if not exists ledger_id uuid references public.cost_ledger(id) on delete set null;
create index if not exists serving_cost_reservations_open_holds on public.serving_cost_reservations(org_id,request_key)where budget_source='ceiling' and ledger_id is null;

-- ---------------------------------------------------------------- trial pool
create or replace function public.trial_sponsor_pool()returns jsonb
language sql stable security definer set search_path='' as $$
 select case when jsonb_typeof(value)='object' and jsonb_typeof(value->'cap_cents')='number'
   and (value->>'starts_at')::timestamptz is not null and (value->>'ends_at')::timestamptz is not null
  then jsonb_build_object('cap_cents',(value->>'cap_cents')::integer,'starts_at',(value->>'starts_at')::timestamptz,'ends_at',(value->>'ends_at')::timestamptz) end
 from public.app_config where key='trial_sponsor_pool';
$$;
revoke all on function public.trial_sponsor_pool()from public,anon,authenticated;
grant execute on function public.trial_sponsor_pool()to service_role,postgres;

create or replace function public.trial_sponsor_spent_cents()returns numeric
language sql stable security definer set search_path='' as $$
 select coalesce((select sum(r.hold_cents)from public.serving_cost_reservations r,public.trial_sponsor_pool() p
  where r.trial_kind and r.budget_source='ceiling' and r.state<>'rejected'
   and r.created_at>=(p->>'starts_at')::timestamptz and r.created_at<(p->>'ends_at')::timestamptz),0);
$$;

-- ---------------------------------------------------------------- envelope with its period
create or replace function public.plan_serving_ceiling(p_org uuid)returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare o public.orgs;e public.plan_entitlements;s public.apple_subscriptions;plan text;annual boolean;commission integer;margin integer;reserve integer;
 monthly_net numeric;envelope integer;sku text;trial_cap integer;ps timestamptz;pe timestamptz;term_start timestamptz;term_end timestamptz;slice interval;k integer;
 month_start timestamptz:=date_trunc('month',now());
begin
 select * into o from public.orgs where id=p_org and deleted_at is null;
 if o.id is null then raise exception 'RP404: Workspace unavailable';end if;
 if public.org_has_private_internal_testing(p_org)or public.org_has_internal_testing_grant(p_org)then
  return jsonb_build_object('ceiling_cents',2147483647,'basis','period','kind','sponsored','plan','team','sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');end if;
 if public.org_has_app_review_funding(p_org)then
  return jsonb_build_object('ceiling_cents',500,'basis','period','kind','app_review','plan','pro','sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');end if;
 e:=public.org_entitlement(p_org);plan:=e.plan;trial_cap:=public.serving_envelope_int('trial_ceiling_cents',500);
 if plan='brokerage'then return jsonb_build_object('ceiling_cents',coalesce(e.cogs_ceiling_cents,0),'basis','period','kind','brokerage','plan',plan,'sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');end if;
 if plan='free'then return jsonb_build_object('ceiling_cents',public.serving_envelope_int('free_lifetime_cents',300),'basis','lifetime','kind','free','plan',plan,'sku',null,'period_start',null,'period_end',null,'window','lifetime');end if;
 if plan='trial'then
  -- One Sandbox window: the seven days the grant opened, never a calendar refill.
  if o.trial_ends_at is not null then ps:=o.trial_ends_at-interval '7 days';pe:=o.trial_ends_at;
  else ps:=month_start;pe:=month_start+interval '1 month';end if;
  return jsonb_build_object('ceiling_cents',trial_cap,'basis','period','kind','trial','plan',plan,'sku',null,'period_start',ps,'period_end',pe,'window','trial_window');end if;
 if plan in('starter','solo','pro','team')then
  if o.plan_source='manual'then return jsonb_build_object('ceiling_cents',coalesce(e.cogs_ceiling_cents,0),'basis','period','kind','manual','plan',plan,'sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');end if;
  sku:=o.apple_product_id;annual:=coalesce(sku,'')like '%.annual';
  commission:=public.serving_envelope_int('apple_commission_bps',3000);margin:=public.serving_envelope_int('net_margin_bps',7500);
  reserve:=public.serving_envelope_int('hosting_reserve_cents',50);
  -- Annual SKUs are ten monthly prices for twelve months of service.
  monthly_net:=case when annual then coalesce(e.price_cents,0)*10.0*(10000-commission)/10000/12 else coalesce(e.price_cents,0)*(10000-commission)/10000.0 end;
  envelope:=greatest(0,floor(monthly_net*(10000-margin)/10000.0)::integer-reserve);
  select * into s from public.apple_subscriptions where org_id=p_org and environment='Production' and status in('active','grace')
   order by expires_at desc nulls last limit 1;
  if s.original_transaction_id is not null and s.expires_at is not null and s.expires_at>now() then
   -- The introductory week is sponsored, once, inside its own window.
   if s.transaction_purchased_at is not null and s.expires_at<=s.transaction_purchased_at+interval '8 days' then
    return jsonb_build_object('ceiling_cents',least(envelope,trial_cap),'basis','period','kind','trial','plan',plan,'sku',sku,'period_start',s.transaction_purchased_at,'period_end',s.expires_at,'window','intro_window');end if;
   term_end:=s.expires_at;
   term_start:=coalesce(s.transaction_purchased_at,term_end-(case when annual then interval '1 year' else interval '1 month' end));
   if term_start>=term_end then term_start:=term_end-(case when annual then interval '1 year' else interval '1 month' end);end if;
   if annual then
    slice:=(term_end-term_start)/12;
    k:=least(11,greatest(0,floor(extract(epoch from(now()-term_start))/extract(epoch from slice))::integer));
    return jsonb_build_object('ceiling_cents',envelope,'basis','period','kind','retail','plan',plan,'sku',sku,'period_start',term_start+slice*k,'period_end',term_start+slice*(k+1),'window','apple_slice');end if;
   return jsonb_build_object('ceiling_cents',envelope,'basis','period','kind','retail','plan',plan,'sku',sku,'period_start',term_start,'period_end',term_end,'window','apple_term');
  end if;
  -- Billing retry: Apple asks us to keep serving for up to 16 days after expiry;
  -- a successful renewal is back-dated to the old expiry, so this spend lands in
  -- the renewed window and is never allocated twice.
  if s.original_transaction_id is not null and s.expires_at is not null then
   return jsonb_build_object('ceiling_cents',envelope,'basis','period','kind','grace','plan',plan,'sku',sku,'period_start',s.expires_at,'period_end',s.expires_at+interval '16 days','window','apple_grace');end if;
  return jsonb_build_object('ceiling_cents',envelope,'basis','period','kind','retail','plan',plan,'sku',sku,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');
 end if;
 return jsonb_build_object('ceiling_cents',coalesce(e.cogs_ceiling_cents,0),'basis','period','kind','other','plan',plan,'sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');
end$$;

-- Money committed inside a window: ledger rows, every open ceiling hold (until
-- its ledger row binds it or it is rejected), and the legacy video/erase holds
-- that have no counted serving reservation of their own yet.
drop function if exists public.serving_ceiling_spent_cents(uuid,text);
create or replace function public.serving_ceiling_spent_cents(p_org uuid,p_start timestamptz,p_end timestamptz)returns numeric
language sql stable security definer set search_path='' as $$
 select coalesce((select sum(total_cents)from public.cost_ledger c where c.org_id=p_org and(p_start is null or c.created_at>=p_start)and(p_end is null or c.created_at<p_end)),0)
  +coalesce((select sum(hold_cents)from public.serving_cost_reservations r where r.org_id=p_org and r.budget_source='ceiling' and r.ledger_id is null
     and r.state in('reserved','uncertain','succeeded')and(p_start is null or r.created_at>=p_start)and(p_end is null or r.created_at<p_end)),0)
  +coalesce((select sum(v.hold_cents)from public.app_video_cost_reservations v where v.org_id=p_org and v.cost_ledger_id is null and v.released_at is null
     and(p_start is null or v.created_at>=p_start)and(p_end is null or v.created_at<p_end)
     and not exists(select 1 from public.serving_cost_reservations r where r.org_id=p_org and r.request_key=v.idempotency_key and r.budget_source='ceiling' and r.ledger_id is null and r.state<>'rejected')),0)
  +coalesce((select sum(j.cost_cents)from public.video_erase_jobs j where j.org_id=p_org and j.provider='fal' and j.cost_ledger_id is null and j.cost_hold_released_at is null
     and(p_start is null or j.created_at>=p_start)and(p_end is null or j.created_at<p_end)
     and not exists(select 1 from public.serving_cost_reservations r where r.org_id=p_org and r.request_key=j.idempotency_key::text and r.budget_source='ceiling' and r.ledger_id is null and r.state<>'rejected')),0)
  +coalesce((select sum(st.cost_cents)from public.video_erase_stages st join public.video_erase_jobs j on j.id=st.job_id where j.org_id=p_org and st.cost_ledger_id is null and st.cost_hold_released_at is null
     and(p_start is null or j.created_at>=p_start)and(p_end is null or j.created_at<p_end)),0);
$$;
revoke all on function public.serving_ceiling_spent_cents(uuid,timestamptz,timestamptz)from public,anon,authenticated;
grant execute on function public.serving_ceiling_spent_cents(uuid,timestamptz,timestamptz)to service_role,postgres;

-- THE money authority. Every ceiling-mode writer calls it before holding money.
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
 -- The same attempt may already hold money through the legacy video/erase
 -- writer; its serving reservation replaces that hold rather than adding to it.
 pre:=0;
 if p_request_key is not null then
  pre:=coalesce((select sum(v.hold_cents)from public.app_video_cost_reservations v where v.org_id=p_org and v.idempotency_key=p_request_key and v.cost_ledger_id is null and v.released_at is null),0)
   +coalesce((select sum(j.cost_cents)from public.video_erase_jobs j where j.org_id=p_org and j.idempotency_key::text=p_request_key and j.provider='fal' and j.cost_ledger_id is null and j.cost_hold_released_at is null),0);
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

do $$
begin
 -- serving_cost_reserve: in ceiling mode take the shared money lock BEFORE the
 -- workspace row lock, in the same order as the video/erase writers (the
 -- two-connection harness found the deadlock the other order produces).
 perform pg_temp.rp_patch('public.serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text)'::regprocedure,
  E' perform pg_advisory_xact_lock(hashtextextended(\'serving:\'||p_org,72452));\n perform 1 from public.orgs where id=p_org and deleted_at is null for update;',
  E' perform pg_advisory_xact_lock(hashtextextended(\'serving:\'||p_org,72452));\n if public.serving_mode()=\'ceiling\' then perform pg_advisory_xact_lock(hashtextextended(\'org_month_spend:\'||p_org::text,42));end if;\n perform 1 from public.orgs where id=p_org and deleted_at is null for update;');
 -- serving_cost_reserve: the inline ceiling block becomes a call to the authority.
 perform pg_temp.rp_splice('public.serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text)'::regprocedure,
  E'  if public.serving_mode()=\'ceiling\' then\n   -- Ceiling mode (2026-10-08): the workspace\'s serving envelope is the budget.',
  E'\'basis\',basis,\'kind\',kind);\n  end if;',
  $r$  if public.serving_mode()='ceiling' then
   -- Ceiling mode: serving_envelope_admit is the single money authority shared
   -- with the video and erase writers (same org_month_spend lock).
   envelope:=public.serving_envelope_admit(p_org,p_hold_cents,p_key);
   ceiling:=(envelope->>'ceiling_cents')::numeric;basis:=envelope->>'basis';kind:=envelope->>'kind';spent:=(envelope->>'spent_cents')::numeric;
   insert into public.serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,sponsored_unlimited,budget_source,trial_kind)
   values(p_org,p_actor,p_key,p_stage,p_provider,p_model,p_input_sha256,p_tariff_version,p_hold_cents,false,'ceiling',kind='trial')returning id into reservation;
   return jsonb_build_object('reserved',true,'id',reservation,'hold_cents',p_hold_cents,'sponsored_unlimited',false,'budget','ceiling','ceiling_cents',ceiling,'spent_cents',spent,'basis',basis,'kind',kind,'period_end',envelope->'period_end');
  end if;$r$);
 -- app_video_cost_reserve: legacy entitlement check stays; the envelope is admitted after it.
 perform pg_temp.rp_patch('public.app_video_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb)'::regprocedure,
  E'  if spent is null or spent<0 or spent+p_hold_cents>e.cogs_ceiling_cents then\n    raise exception \'RP402: Workspace monthly processing budget would be exceeded\';\n  end if;',
  E'  if spent is null or spent<0 or spent+p_hold_cents>e.cogs_ceiling_cents then\n    raise exception \'RP402: Workspace monthly processing budget would be exceeded\';\n  end if;\n  if public.serving_mode()=\'ceiling\' then perform public.serving_envelope_admit(p_org,p_hold_cents,p_key);end if;');
 perform pg_temp.rp_patch('public.video_erase_reserve(uuid,uuid,uuid,uuid,uuid,uuid,text,numeric)'::regprocedure,
  E'  if org_month_spend_cents(p_org)+cost>e.cogs_ceiling_cents then raise exception \'RP402: Workspace processing budget reached\'; end if;',
  E'  if org_month_spend_cents(p_org)+cost>e.cogs_ceiling_cents then raise exception \'RP402: Workspace processing budget reached\'; end if;\n  if public.serving_mode()=\'ceiling\' then perform public.serving_envelope_admit(p_org,cost,p_idem::text); end if;');
 perform pg_temp.rp_patch('public.video_erase_reserve_direct(uuid,uuid,uuid,uuid,uuid,uuid,text,numeric,jsonb,text)'::regprocedure,
  E'  if org_month_spend_cents(p_org)+cost>e.cogs_ceiling_cents then raise exception \'RP402: Workspace processing budget reached\'; end if;',
  E'  if org_month_spend_cents(p_org)+cost>e.cogs_ceiling_cents then raise exception \'RP402: Workspace processing budget reached\'; end if;\n  if public.serving_mode()=\'ceiling\' then perform public.serving_envelope_admit(p_org,cost,p_idem::text); end if;');
end$$;

-- A ledger row binds the hold of the attempt it bills. Exact keys first, then
-- the oldest unbound successful hold of the same provider/model in 24h.
create or replace function public.cost_ledger_settle_serving_hold()returns trigger
language plpgsql security definer set search_path='' as $$
declare key text;v_stage text;hold uuid;
begin
 if new.org_id is null then return new;end if;
 key:=new.meta->>'request_key';v_stage:=new.meta->>'stage';
 if key is null and (new.meta->>'app_video_reservation_id')~'^[0-9a-f-]{36}$' then
  select idempotency_key into key from public.app_video_cost_reservations where id=(new.meta->>'app_video_reservation_id')::uuid;end if;
 if key is null and (new.meta->>'erase_job_id')~'^[0-9a-f-]{36}$' then
  select idempotency_key::text into key from public.video_erase_jobs where id=(new.meta->>'erase_job_id')::uuid;end if;
 if key is not null then
  select id into hold from public.serving_cost_reservations r where r.org_id=new.org_id and r.request_key=key and r.budget_source='ceiling' and r.ledger_id is null and r.state<>'rejected'
   order by (v_stage is not null and r.stage=v_stage)desc,r.created_at limit 1 for update skip locked;
 end if;
 if hold is null then
  select id into hold from public.serving_cost_reservations r where r.org_id=new.org_id and r.provider=new.provider and r.model=new.model and r.budget_source='ceiling'
   and r.ledger_id is null and r.state='succeeded' and r.created_at>now()-interval '24 hours' order by r.created_at limit 1 for update skip locked;
 end if;
 if hold is not null then update public.serving_cost_reservations set ledger_id=new.id where id=hold;end if;
 return new;
end$$;
drop trigger if exists cost_ledger_settle_serving_hold on public.cost_ledger;
create trigger cost_ledger_settle_serving_hold after insert on public.cost_ledger for each row execute function public.cost_ledger_settle_serving_hold();

-- ---------------------------------------------------------------- /me
create or replace function public.serving_envelope_state(p_org uuid)returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare env jsonb;ps timestamptz;pe timestamptz;spent numeric;held numeric;pool jsonb;
begin
 env:=public.plan_serving_ceiling(p_org);ps:=(env->>'period_start')::timestamptz;pe:=(env->>'period_end')::timestamptz;
 spent:=coalesce((select sum(total_cents)from public.cost_ledger c where c.org_id=p_org and(ps is null or c.created_at>=ps)and(pe is null or c.created_at<pe)),0);
 held:=greatest(0,public.serving_ceiling_spent_cents(p_org,ps,pe)-spent);
 pool:=case when env->>'kind'='trial' then public.trial_sponsor_pool()||jsonb_build_object('spent_cents',public.trial_sponsor_spent_cents()) end;
 return jsonb_build_object('kind',env->>'kind','plan',env->>'plan','ceiling_cents',(env->>'ceiling_cents')::numeric,'spent_cents',round(spent,2),'held_cents',round(held,2),
  'available_cents',greatest(0,round((env->>'ceiling_cents')::numeric-spent-held,2)),'period_start',ps,'period_end',pe,'window',env->>'window','pool',pool);
end$$;
revoke all on function public.serving_envelope_state(uuid)from public,anon,authenticated;
grant execute on function public.serving_envelope_state(uuid)to service_role,postgres;

-- ---------------------------------------------------------------- Sandbox receipts
create or replace function public.grant_sandbox_trial(p_org uuid,p_actor uuid,p_original text,p_transaction text,p_product text,
 p_status text,p_expires_at timestamptz,p_signed_at timestamptz)returns jsonb
language plpgsql security definer set search_path='' as $$
declare o public.orgs;receipt public.apple_sandbox_receipts;ends timestamptz;stale boolean:=false;
 current_plan text;current_source text;current_deadline timestamptz;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if public.serving_mode()<>'ceiling'then raise exception 'RP403: Sandbox trials require ceiling serving mode';end if;
 if p_original is null or length(p_original)not between 1 and 200 or p_transaction is null or length(p_transaction)not between 1 and 200
  or p_product is null or length(p_product)not between 1 and 200 or p_status is null or p_status not in('active','grace','expired','refunded','revoked')
  or p_signed_at is null or not pg_catalog.isfinite(p_signed_at)or p_signed_at>now()+interval '5 minutes'
  or(p_expires_at is not null and not pg_catalog.isfinite(p_expires_at))then raise exception 'RP400: Verified Sandbox receipt is required';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('apple_sandbox:'||p_original,72451));
 select * into receipt from public.apple_sandbox_receipts where original_transaction_id=p_original for update;
 if receipt.org_id is not null and(receipt.org_id is distinct from p_org or receipt.actor_id is distinct from p_actor)then raise exception 'RP409: This test purchase belongs to another account or workspace';end if;
 select * into o from public.orgs where id=p_org and deleted_at is null for update;
 if o.id is null then raise exception 'RP403: A current workspace is required';end if;
 if not exists(select 1 from public.memberships where org_id=p_org and user_id=p_actor and role in('owner','admin'))then raise exception 'RP403: Only the workspace owner or an admin can add a subscription';end if;
 if not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)then raise exception 'RP403: Sandbox testing requires a current named test account';end if;
 -- Chronology: facts are applied in Apple's signature order. Older evidence
 -- never overwrites a newer status, so a refunded receipt cannot be revived.
 if receipt.original_transaction_id is not null and receipt.signed_at is not null and p_signed_at<receipt.signed_at then stale:=true;
 else
  insert into public.apple_sandbox_receipts(original_transaction_id,org_id,actor_id,transaction_id,product_id,status,signed_at,receipt_expires_at)
  values(p_original,p_org,p_actor,p_transaction,p_product,p_status,p_signed_at,p_expires_at)
  on conflict(original_transaction_id)do update set transaction_id=excluded.transaction_id,product_id=excluded.product_id,status=excluded.status,
   signed_at=excluded.signed_at,receipt_expires_at=excluded.receipt_expires_at,updated_at=now()
  returning * into receipt;
 end if;
 current_plan:=public.effective_plan(p_org);current_source:=o.plan_source;
 current_deadline:=case when o.plan='trial' then o.trial_ends_at when o.plan_source='apple' then o.plan_expires_at end;
 if stale then
  return jsonb_build_object('plan',current_plan,'source',current_source,'expires_at',current_deadline,'granted',false,'replay',false,'reason','stale_receipt',
   'receipt_status',receipt.status,'grant_ends_at',receipt.trial_ends_at,'original_transaction_id',p_original,'product_id',p_product);end if;
 -- A paid workspace is never downgraded by a test receipt.
 if current_plan in('starter','solo','pro','team','brokerage')then
  return jsonb_build_object('plan',current_plan,'source',current_source,'expires_at',current_deadline,'granted',false,'replay',receipt.trial_granted_at is not null,'reason','paid_workspace',
   'receipt_status',receipt.status,'grant_ends_at',receipt.trial_ends_at,'original_transaction_id',p_original,'product_id',p_product);end if;
 -- Replay of an already granted receipt reports the CURRENT state; it never restarts.
 if receipt.trial_granted_at is not null then
  return jsonb_build_object('plan',current_plan,'source',current_source,'expires_at',current_deadline,'granted',false,'replay',true,'reason','already_granted',
   'receipt_status',receipt.status,'grant_ends_at',receipt.trial_ends_at,'original_transaction_id',p_original,'product_id',p_product);end if;
 -- Only a currently valid receipt opens a sponsored window (recorded either way).
 if receipt.status not in('active','grace')or receipt.receipt_expires_at is null or receipt.receipt_expires_at<=now()then
  return jsonb_build_object('plan',current_plan,'source',current_source,'expires_at',current_deadline,'granted',false,'replay',false,'reason','receipt_inactive',
   'receipt_status',receipt.status,'grant_ends_at',null,'original_transaction_id',p_original,'product_id',p_product);end if;
 -- A window that is still open is reported, not extended.
 if o.plan='trial' and o.trial_ends_at is not null and o.trial_ends_at>now() then
  return jsonb_build_object('plan','trial','source','trial','expires_at',o.trial_ends_at,'granted',false,'replay',false,'reason','trial_active',
   'receipt_status',receipt.status,'grant_ends_at',null,'original_transaction_id',p_original,'product_id',p_product);end if;
 ends:=now()+interval '7 days';
 update public.apple_sandbox_receipts set trial_granted_at=now(),trial_ends_at=ends,updated_at=now()where original_transaction_id=p_original;
 update public.orgs set plan='trial',plan_source='trial',trial_ends_at=ends where id=p_org;
 perform public.hosting_retention_enroll(p_org,'sandbox_trial',p_original,ends);
 return jsonb_build_object('plan','trial','source','trial','expires_at',ends,'granted',true,'replay',false,'reason','granted',
  'receipt_status',receipt.status,'grant_ends_at',ends,'original_transaction_id',p_original,'product_id',p_product);
end$$;

-- ---------------------------------------------------------------- retention
do $$
begin
 perform pg_temp.rp_patch('public.hosting_retention_notice_current(uuid)'::regprocedure,
  E'  select id into current_grant from public.serving_funding where org_id=row.org_id and source in(\'retail\',\'trial\')order by retention_ends_at desc,id limit 1;',
  E'  select id into current_grant from(select id,retention_ends_at from public.serving_funding where org_id=row.org_id and source in(\'retail\',\'trial\')\n   union all select id,retention_ends_at from public.hosting_retention_enrollments where org_id=row.org_id)x order by retention_ends_at desc,id limit 1;');
 -- Only subscriptions first seen on/after the policy date are enrolled.
 perform pg_temp.rp_patch('public.apply_apple_entitlement_v2(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text,timestamptz,timestamptz,timestamptz,timestamptz)'::regprocedure,
  E'  if public.serving_mode()=\'ceiling\' and coalesce((r->>\'org_updated\')::boolean,false) and next_expiry is not null and next_status in(\'active\',\'grace\',\'expired\') then',
  E'  if public.serving_mode()=\'ceiling\' and coalesce((r->>\'org_updated\')::boolean,false) and next_expiry is not null and next_status in(\'active\',\'grace\',\'expired\')\n     and coalesce((select created_at from public.apple_subscriptions where original_transaction_id=p_original_transaction_id),now())>=\'2026-10-06\'::timestamptz then');
end$$;
-- Testers who subscribed before the October 6 policy keep their prior hosting arrangement.
delete from public.hosting_retention_enrollments e using public.apple_subscriptions s
 where e.source='apple_subscription' and e.reference=s.original_transaction_id and s.created_at<'2026-10-06'::timestamptz;

-- ---------------------------------------------------------------- admin alerts
create or replace function public.ops_alert_current(p_outbox uuid)returns boolean
language plpgsql security definer set search_path='' as $$
declare row public.notification_outbox;valid boolean:=false;
begin
 if current_setting('role',true)<>'service_role'then raise insufficient_privilege using message='service role required';end if;
 select * into row from public.notification_outbox o where o.id=p_outbox and o.state in('queued','sending','failed')for update;
 if not found or row.category<>'ops_alert' then return false;end if;
 valid:=row.user_id is not null and exists(select 1 from public.profiles p where p.id=row.user_id and p.is_admin)
  and exists(select 1 from public.ops_health_findings()f where f.code=row.payload->>'code');
 if not valid then update public.notification_outbox set state='expired' where id=p_outbox;return false;end if;
 return true;
end$$;
revoke all on function public.ops_alert_current(uuid)from public,anon,authenticated;
grant execute on function public.ops_alert_current(uuid)to service_role;

create or replace function public.ops_health_check()returns jsonb
language plpgsql security definer set search_path='' as $$
declare f record;a record;queued integer:=0;findings integer:=0;day text:=to_char(now()at time zone 'UTC','YYYY-MM-DD');
begin
 for f in select * from public.ops_health_findings() loop
  findings:=findings+1;
  for a in select p.id,p.email,exists(select 1 from public.notification_devices d where d.user_id=p.id and d.disabled_at is null) as has_device
    from public.profiles p where p.is_admin loop
   if a.has_device then
    insert into public.notification_outbox(org_id,user_id,category,channel,dedupe_key,payload)
    values(null,a.id,'ops_alert','push','ops_alert:'||f.code||':'||day||':'||a.id||':push',
      jsonb_build_object('title','Admin alert: '||f.title,'body',f.body,'code',f.code,'data',f.data,'observed_at',now()))
    on conflict(dedupe_key)do nothing;
    if found then queued:=queued+1;end if;
   end if;
   if coalesce(btrim(a.email),'')<>'' then
    insert into public.notification_outbox(org_id,user_id,category,channel,dedupe_key,payload)
    values(null,a.id,'ops_alert','email','ops_alert:'||f.code||':'||day||':'||a.id||':email',
      jsonb_build_object('title','Admin alert: '||f.title,'body',f.body,'code',f.code,'data',f.data,'observed_at',now()))
    on conflict(dedupe_key)do nothing;
    if found then queued:=queued+1;end if;
   end if;
  end loop;
 end loop;
 return jsonb_build_object('findings',findings,'queued',queued,'checked_at',now());
end$$;

create or replace function public.ops_health_findings()returns table(code text,title text,body text,data jsonb)
language plpgsql stable security definer set search_path='' as $$
declare r record;attempts bigint;successes bigint;n bigint;spent numeric;cfg text;pool jsonb;
begin
 -- Read-only; executable by service_role and the cron owner (postgres) only.

 -- 0. Serving configuration must be explicit (missing/invalid = funded = closed).
 cfg:=public.serving_mode_config_state();
 if cfg in('missing','invalid')then
  code:='serving_mode_config';title:='Serving mode configuration is '||cfg||' (running funded = closed)';
  body:='app_config.serving_mode is '||cfg||'. Every workspace without a testing grant is being refused AI generation until the row is set to an explicit ceiling configuration ({"mode":"ceiling","free_published_listings":1}) or to funded mode with funding provisioned.';
  data:=jsonb_build_object('state',cfg);return next;
 end if;

 -- 1. A provider/model with a failure streak and no success since (the Seedance class).
 for r in select provider,model,consecutive_failures,last_error_class,last_status,last_ok_at,last_fail_at from public.provider_health
   where consecutive_failures>=3 and last_fail_at>now()-interval '7 days'
    and last_fail_at>coalesce(last_ok_at,'-infinity'::timestamptz)
 loop
  code:='provider_dead:'||r.provider||':'||r.model;
  title:='AI provider failing: '||r.provider||' / '||r.model;
  body:=r.consecutive_failures||' failures in a row ('||coalesce(r.last_error_class,'unknown')
   ||case when r.last_status is null then '' else ', last HTTP '||r.last_status||case r.last_status when 401 then ' = the provider rejected our API key' when 402 then ' = the provider account is out of balance' when 403 then ' = the provider refused this account or model' when 429 then ' = rate limited' else '' end end
   ||'). Last success '||coalesce(to_char(r.last_ok_at at time zone 'UTC','YYYY-MM-DD HH24:MI')||' UTC','never')||'. Check the provider dashboard (balance, lock, key) and run one real generation.';
  data:=jsonb_build_object('provider',r.provider,'model',r.model,'consecutive_failures',r.consecutive_failures,'last_error_class',r.last_error_class,'last_status',r.last_status,'last_ok_at',r.last_ok_at,'last_fail_at',r.last_fail_at);
  return next;
 end loop;

 -- 2. Video attempts in the last 24h with no settled success.
 select count(*),count(*)filter(where cost_ledger_id is not null) into attempts,successes
  from public.app_video_cost_reservations where created_at>now()-interval '24 hours';
 if attempts>=2 and successes=0 then
  code:='video_no_success_24h';title:='Video generations: '||attempts||' attempts, 0 successes in 24h';
  body:='Reels, aerials or drone renders were attempted '||attempts||' times in the last 24 hours and none settled. Customers are seeing failures.';
  data:=jsonb_build_object('attempts',attempts,'successes',successes);return next;
 end if;

 -- 3. Journaled AI operations (photo/copy/voice/chapters/coach) in 24h with no completion.
 select count(*),count(*)filter(where state='completed') into attempts,successes
  from public.serving_operations where created_at>now()-interval '24 hours';
 if attempts>=3 and successes=0 then
  code:='ai_ops_no_success_24h';title:='AI requests: '||attempts||' started, 0 completed in 24h';
  body:='Photo, copy, voice, chapter or coach requests were started '||attempts||' times in the last 24 hours and none completed. Check the serving mode, provider keys and function logs.';
  data:=jsonb_build_object('attempts',attempts,'completed',successes);return next;
 end if;

 -- 4. Server render jobs stuck longer than 30 minutes.
 select count(*) into n from public.render_jobs where source='worker' and status in('created','queued','claimed','processing') and created_at<now()-interval '30 minutes';
 if n>0 then
  code:='render_jobs_stuck';title:=n||' server render job(s) stuck over 30 minutes';
  body:='Jobs are waiting on the render worker. If no worker is running, customers who chose a server tier are waiting on nothing.';
  data:=jsonb_build_object('stuck',n);return next;
 end if;

 -- 5. Apple notifications still pending after an hour (entitlements not applied).
 select count(*) into n from public.apple_notifications where pending and received_at<now()-interval '1 hour';
 if n>0 then
  code:='apple_notifications_pending';title:=n||' Apple subscription notification(s) pending over 1h';
  body:='Subscription changes from Apple have not been applied. Check the apple-subscriptions function logs and replay pending notifications.';
  data:=jsonb_build_object('pending',n);return next;
 end if;

 -- 6. Notification delivery failing (the alert channel itself).
 select count(*) into n from public.notification_outbox where state='failed' and created_at>now()-interval '24 hours';
 if n>=5 then
  code:='notifications_failing';title:=n||' notifications failed in 24h';
  body:='Push or e-mail delivery is failing. Check APNs/Resend secrets and the notify function logs.';
  data:=jsonb_build_object('failed',n);return next;
 end if;

 -- 7. Funded serving mode with nothing funded (the Oct 6 outage class).
 if public.serving_mode()='funded' and not exists(select 1 from public.serving_funding where revoked_at is null and ends_at>now())
  and (select count(*) from public.orgs where deleted_at is null)>(select count(*) from public.org_internal_testing_grants where revoked_at is null)+1 then
  code:='funded_mode_unfunded';title:='Serving mode is funded but nothing is funded';
  body:='Every workspace without a testing grant is being refused AI generation. Either provision funding or set app_config.serving_mode to an explicit ceiling configuration.';
  data:='{}'::jsonb;return next;
 end if;

 -- 8. Trial sponsor pool: missing, ending within a week, or near its cap.
 pool:=public.trial_sponsor_pool();
 if pool is null then
  code:='trial_pool_missing';title:='No trial sponsor pool is recorded';
  body:='app_config.trial_sponsor_pool is missing or malformed. Introductory-week and Sandbox trial AI attempts are refused until the owner records an allocation {cap_cents, starts_at, ends_at}.';
  data:='{}'::jsonb;return next;
 else
  spent:=public.trial_sponsor_spent_cents();
  if now()>=(pool->>'ends_at')::timestamptz or (pool->>'ends_at')::timestamptz<=now()+interval '7 days' then
   code:='trial_pool_ending';title:='Trial sponsor pool '||case when now()>=(pool->>'ends_at')::timestamptz then 'has ended' else 'ends within 7 days' end;
   body:='The owner-approved trial AI allocation ('||to_char((pool->>'cap_cents')::numeric/100,'FM999990.00')||' USD) '||case when now()>=(pool->>'ends_at')::timestamptz then 'ended' else 'ends' end||' on '||to_char((pool->>'ends_at')::timestamptz at time zone 'UTC','YYYY-MM-DD')||'. Trial attempts are refused after that until a new allocation is recorded.';
   data:=pool||jsonb_build_object('spent_cents',spent);return next;
  end if;
  if spent>=0.8*(pool->>'cap_cents')::numeric then
   code:='trial_sponsor_near_cap';title:='Trial sponsor pool at '||round(100*spent/greatest((pool->>'cap_cents')::numeric,1))||'% of its cap';
   body:=to_char(spent/100,'FM999990.00')||' of '||to_char((pool->>'cap_cents')::numeric/100,'FM999990.00')||' USD of trial AI used in this allocation. New trial attempts are refused at the cap.';
   data:=pool||jsonb_build_object('spent_cents',spent);return next;
  end if;
 end if;

 -- 9. Paying ceiling-mode workspaces must carry a hosting retention record (policy subscriptions only).
 if public.serving_mode()='ceiling' then
  select count(*) into n from public.orgs o where o.deleted_at is null and o.plan_source='apple' and public.effective_plan(o.id)in('starter','solo','pro','team')
   and exists(select 1 from public.apple_subscriptions s where s.org_id=o.id and s.environment='Production' and s.created_at>='2026-10-06'::timestamptz)
   and not exists(select 1 from public.hosting_retention_enrollments e where e.org_id=o.id)
   and not exists(select 1 from public.serving_funding f where f.org_id=o.id and f.source in('retail','trial'));
  if n>0 then
   code:='retention_missing';title:=n||' paid workspace(s) without a hosting retention record';
   body:='A subscription was applied without a hosting retention deadline. Replay the purchase sync (Restore in the app) or enroll it manually with hosting_retention_enroll().';
   data:=jsonb_build_object('orgs',n);return next;
  end if;
 end if;

 -- 10. Successful holds that never received their ledger row (a billing write failed somewhere).
 select count(*) into n from public.serving_cost_reservations where budget_source='ceiling' and state='succeeded' and ledger_id is null and settled_at<now()-interval '1 hour';
 if n>0 then
  code:='holds_unledgered';title:=n||' successful AI attempt(s) have no ledger row after 1h';
  body:='The money stays held against the workspace envelope (safe), but the cost ledger is incomplete. Check the function logs for cost_ledger insert failures.';
  data:=jsonb_build_object('holds',n);return next;
 end if;

 -- 11. Spend anomalies: more than $50 of provider cost in 24h, or any paying workspace at 80% of its envelope.
 select coalesce(sum(total_cents),0) into spent from public.cost_ledger where created_at>now()-interval '24 hours';
 if spent>5000 then
  code:='spend_spike_24h';title:='Provider spend '||to_char(spent/100,'FM999990.00')||' USD in 24h';
  body:='More than $50 of AI provider cost was recorded in the last 24 hours. Check the cost ledger for a runaway workspace or a pricing bug.';
  data:=jsonb_build_object('cents',spent);return next;
 end if;
 for r in select o.id,o.name,c.envelope from public.orgs o cross join lateral public.plan_serving_ceiling(o.id) as c(envelope)
   where o.deleted_at is null and c.envelope->>'kind' in('retail','grace','trial','manual','brokerage','app_review')
 loop
  spent:=public.serving_ceiling_spent_cents(r.id,(r.envelope->>'period_start')::timestamptz,(r.envelope->>'period_end')::timestamptz);
  if (r.envelope->>'ceiling_cents')::numeric>0 and (r.envelope->>'ceiling_cents')::numeric<2147483647 and spent>=0.8*(r.envelope->>'ceiling_cents')::numeric then
   code:='org_near_ceiling:'||r.id;title:='Workspace near its AI envelope: '||coalesce(r.name,r.id::text);
   body:=to_char(spent/100.0,'FM999990.00')||' of '||to_char((r.envelope->>'ceiling_cents')::numeric/100.0,'FM999990.00')||' USD committed in the current '||(r.envelope->>'window')||' on plan '||(r.envelope->>'plan')||' ('||(r.envelope->>'kind')||'). Further AI requests are refused at the envelope until it resets on '||coalesce(to_char((r.envelope->>'period_end')::timestamptz at time zone 'UTC','YYYY-MM-DD'),'(never)')||'.';
   data:=jsonb_build_object('org_id',r.id,'spent_cents',spent,'ceiling_cents',(r.envelope->>'ceiling_cents')::numeric,'window',r.envelope->>'window','plan',r.envelope->>'plan','kind',r.envelope->>'kind','period_end',r.envelope->'period_end');
   return next;
  end if;
 end loop;
 return;
end$$;

commit;
