-- Per-user free-trial allowance (owner decision 2026-11-12, 15:50-15:56 ET).
--
-- "The 7-day free trial is part of the product for every new user. A global
-- pool or date limit that refuses trials makes no sense. Pricing and margins
-- are baked into the paid plans."
--
-- Before this migration a new subscriber's trial was refused by any of:
--   * app_config.trial_sponsor_pool: one dollar cap and one end date shared by
--     every trial user (ended 2026-11-08);
--   * the first-100 purchase pool: 100 holds, USD 500, last hold 2026-11-22;
--   * trial_card_authority_active(): a supplier attestation that has to be
--     re-recorded every 24 hours (lapsed 2026-10-30).
-- Each of those is a total that runs out. None of them limits what one user
-- can spend, which is what actually keeps the cost of a trial known.
--
-- This migration is DORMANT. It installs a policy row whose mode is 'pool', so
-- every function below behaves exactly as it does today until the companion
-- migration 20261112223100 (or an operator) sets mode = 'per_user'. In that
-- mode:
--   * a trial is admitted for every confirmed, named owner who has not had one
--     (the existing lifetime uniqueness on account, e-mail identity and
--     workspace, plus Apple's one introductory offer per customer);
--   * the cost bound is that user's own allowance: subscription_trial_config
--     (photo edits) and subscription_trial_admission_policy.per_user_budget_cents;
--   * nothing shared is consulted, so internal QA grants, a spent total or a
--     past date cannot refuse a member of the public;
--   * every attempt still writes its serving_cost_reservations hold and its
--     cost_ledger row, and ops_health_findings() reports total trial spend to
--     the owner instead of refusing anyone.
--
-- Safe to apply twice: tables and constraints are created idempotently and each
-- function rewrite is pinned to the md5 of the body it replaces and of the body
-- it installs. A function that is neither refuses the whole migration.

do $guard$
begin
 if to_regclass('public.subscription_trial_purchase_reservations') is null
  or to_regclass('public.subscription_trial_media_template') is null
  or to_regclass('public.media_account_reserves') is null
  or to_regclass('public.apple_sandbox_receipts') is null
  or to_regprocedure('public.prepare_sandbox_intro_trial_purchase(uuid,uuid,text)') is null
  or to_regprocedure('public.serving_reserve_total(jsonb)') is null then
  raise exception 'trial per-user allowance: apply 20261111203217_sandbox_intro_purchase_preflight and its predecessors first';
 end if;
end $guard$;

-- 1. The admission policy. One row. `mode` is the only switch.
create table if not exists public.subscription_trial_admission_policy(
 singleton boolean primary key default true check(singleton),
 mode text not null default 'pool' check(mode in('pool','per_user')),
 -- What one admitted trial may cost in total, hosting reserve included.
 per_user_budget_cents integer not null default 500
  check(per_user_budget_cents between 100 and 500),
 -- The part of that budget set aside for hosting, delivery, e-mail and
 -- support. The remainder is the user's AI provider budget.
 per_user_reserve_components jsonb not null default
  '{"email":5,"compute":25,"storage":14,"support":15,"delivery":25,"retention":6,"uncertainty":10}'::jsonb,
 -- Month-to-date trial spend levels (cents) at which the owner is told.
 alert_thresholds_cents bigint[] not null default
  array[5000,10000,25000,50000,100000,250000,500000,1000000]::bigint[],
 evidence_sha256 text not null check(evidence_sha256 ~ '^[a-f0-9]{64}$'),
 note text,
 updated_at timestamptz not null default now(),
 constraint subscription_trial_admission_policy_reserve check(
  public.serving_reserve_total(per_user_reserve_components) is not null
  and public.serving_reserve_total(per_user_reserve_components)<per_user_budget_cents),
 constraint subscription_trial_admission_policy_thresholds check(
  cardinality(alert_thresholds_cents) between 1 and 40
  and 0<all(alert_thresholds_cents))
);
alter table public.subscription_trial_admission_policy enable row level security;
revoke all on public.subscription_trial_admission_policy from public,anon,authenticated;
grant select on public.subscription_trial_admission_policy to service_role;
insert into public.subscription_trial_admission_policy(singleton,mode,evidence_sha256,note)
values(true,'pool',
 encode(sha256(convert_to('Rendprop owner decision 2026-11-12 15:50-15:56 ET: the 7-day free trial is part of the product for every new user; a global pool or date limit that refuses trials is removed; cost is bounded per user.','UTF8')),'hex'),
 'Installed dormant by 20261112223000. mode=pool keeps the first-100 pool rules.')
on conflict(singleton) do nothing;

create or replace function public.subscription_trial_admission_mode()
returns text language sql stable security definer set search_path='' as $$
 -- A missing row means the legacy pool rules, never an unbounded admission.
 select coalesce((select mode from public.subscription_trial_admission_policy where singleton),'pool');
$$;
revoke all on function public.subscription_trial_admission_mode() from public,anon,authenticated;
grant execute on function public.subscription_trial_admission_mode() to service_role;

-- 2. A per-user hold names no pool and no schedule. Both or neither.
alter table public.subscription_trial_purchase_reservations
 alter column pool_id drop not null,
 alter column schedule_id drop not null;
alter table public.subscription_trial_purchase_reservations
 drop constraint if exists subscription_trial_reservation_basis;
alter table public.subscription_trial_purchase_reservations
 add constraint subscription_trial_reservation_basis
 check((pool_id is null)=(schedule_id is null));

-- 3. A standing hosting record for per-user trials. The two existing bases
-- (paid cash, one 180-day card authority) both end; a trial that is part of
-- the product cannot depend on a record that expires. The new basis carries no
-- cash and no card amount: each trial's hosting reserve is inside its own
-- per-user budget, and media_account_committed_capacity() stays 0 for it, so
-- it can never fund an unfunded workspace.
alter table public.media_account_reserves
 drop constraint if exists media_account_reserves_check;
alter table public.media_account_reserves
 add constraint media_account_reserves_check check(
  ends_at>starts_at and (ends_at<=starts_at+interval '466 days'
   or (cash_source='per_user_allowance' and ends_at='infinity'::timestamptz)));
alter table public.media_account_reserves
 drop constraint if exists media_account_reserves_funding_basis_check;
alter table public.media_account_reserves
 add constraint media_account_reserves_funding_basis_check check(
  (cash_source in('owner_paid_cash','business_paid_cash')
   and cash_paid_cents between 1 and 1000000000
   and cash_evidence_sha256 is not null and card_authority_id is null
   and card_authorized_cents=0 and card_evidence_sha256 is null)
  or (cash_source='card_backed_auto_refill' and cash_paid_cents=0
   and cash_evidence_sha256 is null and card_authority_id is not null
   and card_authorized_cents between 1 and 50000
   and card_evidence_sha256 ~ '^[a-f0-9]{64}$')
  or (cash_source='per_user_allowance' and cash_paid_cents=0
   and cash_evidence_sha256 is null and card_authority_id is null
   and card_authorized_cents=0 and card_evidence_sha256 ~ '^[a-f0-9]{64}$'));

-- 4. Pinned function rewrites.
create function pg_temp.trial_allowance_patch(
 p_fn regprocedure,p_before text,p_after text,p_pairs text[])
returns void language plpgsql as $$
declare d text;cur text;i integer;a text;b text;
begin
 d:=pg_get_functiondef(p_fn);cur:=md5(d);
 if cur=p_after then
  raise notice 'trial per-user allowance: % is already installed',p_fn;return;
 end if;
 if cur<>p_before then
  raise exception 'trial per-user allowance: % changed since 2026-11-12 (md5 %); review before applying',p_fn,cur;
 end if;
 for i in 1..cardinality(p_pairs)/2 loop
  a:=p_pairs[2*i-1];b:=p_pairs[2*i];
  if (length(d)-length(replace(d,a,'')))/length(a)<>1 then
   raise exception 'trial per-user allowance: anchor % of % is not present exactly once',i,p_fn;
  end if;
  d:=replace(d,a,b);
 end loop;
 execute d;
 if md5(pg_get_functiondef(p_fn))<>p_after then
  raise exception 'trial per-user allowance: % did not produce the reviewed body (md5 %)',
   p_fn,md5(pg_get_functiondef(p_fn));
 end if;
end$$;

-- 4a/4b. Serving admission of a trial workspace (Sandbox/TestFlight trials and
-- any other ceiling-mode trial). The workspace's own trial ceiling is checked
-- a few lines above this anchor and is unchanged.
select pg_temp.trial_allowance_patch(
 'public.serving_envelope_admit(uuid,numeric,text)'::regprocedure,
 '5975f604e04877937ace40fd21d386b1','4ba2d6e87c05ec36b5240047fb3d80dd',
 array[
$a$ if kind='trial' then
  perform pg_advisory_xact_lock(hashtextextended('serving:trial-sponsor',72452));$a$,
$b$ -- Per-user trial allowance (owner decision 2026-11-12): the workspace's own
 -- trial ceiling above is the bound. In that mode the shared sponsor window
 -- and cap refuse nobody; ops_health_findings() reports total trial spend.
 if kind='trial' and public.subscription_trial_admission_mode()<>'per_user' then
  perform pg_advisory_xact_lock(hashtextextended('serving:trial-sponsor',72452));$b$]);

select pg_temp.trial_allowance_patch(
 'public.library_serving_envelope_admit(uuid,uuid,numeric,text)'::regprocedure,
 '440c789323bf0c8e51cf1302e1bb1c34','8bfe5c0c09b01ecbab33c9e36a45bad2',
 array[
$a$ if kind='trial' then
  perform pg_advisory_xact_lock(hashtextextended('serving:trial-sponsor',72452));$a$,
$b$ -- Per-user trial allowance (owner decision 2026-11-12): the workspace's own
 -- trial ceiling above is the bound. In that mode the shared sponsor window
 -- and cap refuse nobody; ops_health_findings() reports total trial spend.
 if kind='trial' and public.subscription_trial_admission_mode()<>'per_user' then
  perform pg_advisory_xact_lock(hashtextextended('serving:trial-sponsor',72452));$b$]);

-- 4b2. What the apps show a trial workspace. Studio (and the admin budget row
-- on iPhone) print "Trial AI is temporarily unavailable" whenever this `pool`
-- object is closed or spent. In per-user mode there is no shared capacity, so
-- it describes the workspace's own allowance and its own trial window. The
-- shipped clients then say trial AI is available until the trial ends, and
-- unavailable only once this user has used their own allowance.
select pg_temp.trial_allowance_patch(
 'public.serving_envelope_state(uuid)'::regprocedure,
 '854fe792dd39d278f416e9b82d4b1e4b','4c81afaab5131dceb448fa9acee41143',
 array[
$a$ pool:=case when env->>'kind'='trial' then public.trial_sponsor_pool()||jsonb_build_object('spent_cents',public.trial_sponsor_spent_cents()) end;$a$,
$b$ pool:=case
  when env->>'kind'='trial' and public.subscription_trial_admission_mode()='per_user' then
   jsonb_build_object('cap_cents',(env->>'ceiling_cents')::numeric,
    'spent_cents',least((env->>'ceiling_cents')::numeric,round(spent+held,2)),
    'starts_at',ps,'ends_at',pe)
  when env->>'kind'='trial' then public.trial_sponsor_pool()||jsonb_build_object('spent_cents',public.trial_sponsor_spent_cents()) end;$b$]);

-- 4c. Signed Sandbox free-intro grant. Without the shared cap, a tester who
-- resets Apple's Sandbox eligibility could open one USD 5 window after
-- another, so the per-user rule is one granted test trial per account and per
-- workspace for life. A replay of the same Apple transaction is unaffected.
select pg_temp.trial_allowance_patch(
 'public.grant_sandbox_intro_trial(uuid,uuid,text,text,text,text,timestamptz,timestamptz,timestamptz,bigint,text,text,integer,text,uuid,text)'::regprocedure,
 '9be7a0113a759a649df763a00c726e41','50b43fb343cf9248a8fde4d6b48d6c5d',
 array[
$a$ verdict:=public.grant_sandbox_trial(p_org,p_actor,p_original,p_transaction,
   p_product,p_status,p_expires_at,p_signed_at);
 if (verdict->>'granted')::boolean then$a$,
$b$ if public.subscription_trial_admission_mode()='per_user' and exists(
   select 1 from public.apple_sandbox_receipts r
   where r.trial_granted_at is not null
     and r.original_transaction_id<>p_original
     and (r.actor_id=p_actor or r.org_id=p_org)) then
   raise exception 'RP409: This account has already used its free trial';end if;
 verdict:=public.grant_sandbox_trial(p_org,p_actor,p_original,p_transaction,
   p_product,p_status,p_expires_at,p_signed_at);
 if (verdict->>'granted')::boolean
   and public.subscription_trial_admission_mode()<>'per_user' then$b$]);

-- 4d. Sandbox preflight before the Apple sheet: the same two rules.
select pg_temp.trial_allowance_patch(
 'public.prepare_sandbox_intro_trial_purchase(uuid,uuid,text)'::regprocedure,
 '2c9e4c34389c5b9073c424d92713b4b9','a9b979555368bdac56e7a89f2e211e12',
 array[
$a$ pool:=public.trial_sponsor_pool();
 if pool is null or now()<(pool->>'starts_at')::timestamptz
  or (pool->>'ends_at')::timestamptz<=now()+interval '7 days' then
  raise exception 'RP402: Test-trial sponsor allocation is closed or too short';end if;
 if (pool->>'cap_cents')::numeric-public.trial_sponsor_spent_cents()<500 then
  raise exception 'RP402: Test-trial sponsor allocation has less than one trial envelope';end if;$a$,
$b$ if public.subscription_trial_admission_mode()='per_user' then
  -- No shared window or cap. One test trial per account and per workspace.
  if exists(select 1 from public.apple_sandbox_receipts r
    where r.trial_granted_at is not null
      and (r.actor_id=p_actor or r.org_id=p_org)) then
   raise exception 'RP409: This account has already used its free trial';end if;
 else
 pool:=public.trial_sponsor_pool();
 if pool is null or now()<(pool->>'starts_at')::timestamptz
  or (pool->>'ends_at')::timestamptz<=now()+interval '7 days' then
  raise exception 'RP402: Test-trial sponsor allocation is closed or too short';end if;
 if (pool->>'cap_cents')::numeric-public.trial_sponsor_spent_cents()<500 then
  raise exception 'RP402: Test-trial sponsor allocation has less than one trial envelope';end if;
 end if;$b$]);

-- 4e. The hold taken before Apple's purchase sheet (Production and Sandbox).
-- Every identity, ownership, uniqueness and prior-service check above the
-- first anchor is unchanged, and so is the insert below the last one. Only the
-- source of the allowance changes: the policy row instead of a schedule and a
-- pool. The hosting snapshot is still validated by subscription_trial_held_offer
-- -> subscription_trial_frozen_media_ready before any offer is returned.
select pg_temp.trial_allowance_patch(
 'public.prepare_subscription_trial_purchase(uuid,uuid,text)'::regprocedure,
 'f312fafe19dc6b1f7aaddfe899a43732','36887b97b997bb9e6c334180b54f00ba',
 array[
$a$media_template public.subscription_trial_media_template;offer jsonb;$a$,
$b$media_template public.subscription_trial_media_template;offer jsonb;policy public.subscription_trial_admission_policy;$b$,
$a$ select * into s from public.apple_serving_schedules where product_id=p_product and storefront='USA'and currency='USD'and starts_at<=now()and ends_at>=now()+interval '168 hours'$a$,
$b$ select * into policy from public.subscription_trial_admission_policy where singleton;
 if policy.mode='per_user' then
  -- Owner decision 2026-11-12: every new subscriber's seven-day trial is
  -- admitted with a fixed per-user allowance. No shared pool, end date, head
  -- count or daily supplier attestation can refuse it. s and p carry the
  -- policy's values so the insert below is the same statement in both modes.
  if p_product not in('com.rendprop.app.pro29.monthly','com.rendprop.app.starter.monthly',
    'com.rendprop.app.pro.monthly','com.rendprop.app.team.monthly') or c.max_days<>7 then
   raise exception 'RP402: An inclusive funded trial schedule is required';end if;
  s.trial_sponsored_cents:=policy.per_user_budget_cents;
  s.trial_reserve_components:=policy.per_user_reserve_components;
  s.trial_days:=c.max_days;
  s.evidence_sha256:=policy.evidence_sha256;p.evidence_sha256:=policy.evidence_sha256;
  select * into media_template from public.subscription_trial_media_template where singleton for share;
  if media_template.enabled is distinct from true or media_template.account_reserve_ref is null
   or media_template.evidence_sha256 is null then
   raise exception 'RP402: Seven-day trial media coverage is unavailable';end if;
 else
 select * into s from public.apple_serving_schedules where product_id=p_product and storefront='USA'and currency='USD'and starts_at<=now()and ends_at>=now()+interval '168 hours'$b$,
$a$ if committed+s.trial_sponsored_cents>p.funded_cents then raise exception 'RP402: The trial sponsor commitment is exhausted';end if;$a$,
$b$ if committed+s.trial_sponsored_cents>p.funded_cents then raise exception 'RP402: The trial sponsor commitment is exhausted';end if;
 end if;$b$]);

-- 4f. A per-user hold and its funding both carry a NULL pool.
select pg_temp.trial_allowance_patch(
 'public.serving_trial_funded_actor(uuid,uuid)'::regprocedure,
 '4895487e5e3d1b63012a6e140001e721','ec4c9d14c4fb3059d8077c1f22726cbe',
 array[
$a$h.pool_id=f.sponsor_pool_id$a$,
$b$h.pool_id is not distinct from f.sponsor_pool_id$b$]);

-- 4g. The advisory quality check of an included photo edit is part of that
-- edit. Until now the guard refused its reservation, so a real trial user's
-- check could never run. It is admitted here at most once per included edit;
-- it is not counted as an edit, and its hold still comes out of this user's
-- own budget (serving_cost_reserve checked the slice before this trigger).
select pg_temp.trial_allowance_patch(
 'public.subscription_trial_cost_guard()'::regprocedure,
 'a9912ad38bd71b48e132f771beb5bf8e','1c7c21e7abe8fbce02fab03b5da8a44a',
 array[
$a$ if new.stage in('photo.suggest','photo.improve_prompt')then$a$,
$b$ if new.stage ~ '^photo\.qc:[0-9]+$' then
  if (select count(*) from public.serving_cost_reservations r
      where r.funding_id=f.id and r.stage ~ '^photo\.qc:[0-9]+$' and r.state<>'rejected')>=g.photo_cap then
   raise exception 'RP402: The included trial photo checks are exhausted';end if;
  return new;
 end if;
 if new.stage in('photo.suggest','photo.improve_prompt')then$b$]);

-- 5. Truthful reporting. A trial attempt is a serving_cost_reservations row
-- that is either funded by a trial serving_funding row (App Store trials) or
-- flagged trial_kind on the ceiling budget (TestFlight/Sandbox trials). Holds
-- are the documented upper bound of what the supplier can bill.
create or replace function public.trial_spend_summary(p_from timestamptz,p_to timestamptz)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('from',p_from,'to',p_to,
  'committed_cents',coalesce(sum(r.hold_cents),0),
  'attempts',count(*),
  'workspaces',count(distinct coalesce(r.billing_org_id,r.org_id)),
  'app_store_cents',coalesce(sum(r.hold_cents) filter(where f.id is not null),0),
  'test_cents',coalesce(sum(r.hold_cents) filter(where f.id is null),0))
 from public.serving_cost_reservations r
 left join public.serving_funding f on f.id=r.funding_id and f.source='trial'
 where r.created_at>=p_from and r.created_at<p_to
  and r.state<>'rejected' and not r.sponsored_unlimited
  and (f.id is not null or (r.trial_kind and r.budget_source='ceiling'));
$$;
revoke all on function public.trial_spend_summary(timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.trial_spend_summary(timestamptz,timestamptz) to service_role;

-- Owner alerts in per-user mode. Returned through ops_health_findings(), so
-- they use the existing hourly ops_health_check() -> notification_outbox ->
-- push/e-mail path. A spend finding exists for 24 hours after a threshold is
-- crossed; nobody is refused at any level.
create or replace function public.trial_spend_alerts()
returns table(code text,title text,body text,data jsonb)
language plpgsql stable security definer set search_path='' as $$
declare pol public.subscription_trial_admission_policy;c public.subscription_trial_config;
 t public.subscription_trial_media_template;a public.media_account_reserves;
 month_start timestamptz:=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC';
 summary jsonb;mtd numeric;prior numeric;crossed numeric;upcoming numeric;top numeric;why text;
begin
 select * into pol from public.subscription_trial_admission_policy where singleton;
 if pol.mode is distinct from 'per_user' then return;end if;
 select * into c from public.subscription_trial_config where singleton;
 select * into t from public.subscription_trial_media_template where singleton;
 select * into a from public.media_account_reserves where receipt_ref=t.account_reserve_ref;
 why:=case
  when c.enabled is distinct from true then 'the trial switch is off (subscription_trial_config.enabled)'
  when t.enabled is distinct from true or t.account_reserve_ref is null or t.evidence_sha256 is null
   then 'the trial hosting template is off (subscription_trial_media_template)'
  when a.receipt_ref is null or a.starts_at>now() or a.ends_at<now()+interval '97 days'
   then 'the trial hosting record is missing or ends within 97 days (media_account_reserves)'
  when public.serving_mode()<>'ceiling' then 'serving mode is not ceiling, which TestFlight trials need (app_config.serving_mode)'
 end;
 if why is not null then
  code:='trial_admission_blocked';title:='New free trials are being refused';
  body:='New subscribers cannot start the 7-day free trial because '||why||'. Trials already running are not affected. This is a configuration fault, not a spending limit.';
  data:=jsonb_build_object('reason',why);return next;
 end if;
 summary:=public.trial_spend_summary(month_start,now());
 mtd:=(summary->>'committed_cents')::numeric;
 prior:=case when now()-interval '24 hours'<=month_start then 0
  else (public.trial_spend_summary(month_start,now()-interval '24 hours')->>'committed_cents')::numeric end;
 select max(x) into top from unnest(pol.alert_thresholds_cents) x;
 select max(x) into crossed from unnest(pol.alert_thresholds_cents) x where x<=mtd and x>prior;
 -- Past the last listed level, every further multiple of it.
 if floor(mtd/top)>=2 and floor(mtd/top)>floor(prior/top) then crossed:=floor(mtd/top)*top;end if;
 if crossed is null then return;end if;
 select min(x) into upcoming from unnest(pol.alert_thresholds_cents) x where x>mtd;
 if upcoming is null then upcoming:=(floor(mtd/top)+1)*top;end if;
 code:='trial_spend:'||to_char(month_start at time zone 'UTC','YYYY-MM')||':'||crossed::bigint;
 title:='Free-trial AI spend passed '||to_char(crossed/100,'FM999999990.00')||' USD this month';
 body:=to_char(mtd/100,'FM999999990.00')||' USD of AI has been committed for '||(summary->>'workspaces')
  ||' free-trial workspace(s) since '||to_char(month_start at time zone 'UTC','YYYY-MM-DD')
  ||' (UTC). Nobody is blocked: each trial user is limited to their own allowance ('
  ||c.photo_edits||' photo edits, at most '
  ||to_char((pol.per_user_budget_cents-public.serving_reserve_total(pol.per_user_reserve_components))/100.0,'FM999990.00')
  ||' USD of AI). Next alert at '||to_char(upcoming/100,'FM999999990.00')||' USD.';
 data:=summary||jsonb_build_object('threshold_cents',crossed,'next_threshold_cents',upcoming,
  'photo_edits',c.photo_edits,'per_user_budget_cents',pol.per_user_budget_cents);
 return next;
end$$;
revoke all on function public.trial_spend_alerts() from public,anon,authenticated;
grant execute on function public.trial_spend_alerts() to service_role;

-- 5a. Finding 8 of ops_health_findings(): in per-user mode the pool notices
-- ("attempts are refused...") would be false, so the spend alerts replace them.
select pg_temp.trial_allowance_patch(
 'public.ops_health_findings()'::regprocedure,
 '471c7721342be438b92ff0ee77e18793','1236114b1e3b1902c1436c31e50a699f',
 array[
$a$ pool:=public.trial_sponsor_pool();
 if pool is null then
  code:='trial_pool_missing';title:='No trial sponsor pool is recorded';$a$,
$b$ if public.subscription_trial_admission_mode()='per_user' then
  -- Per-user trial allowance: nobody is refused by a total. Report spend.
  return query select a.code,a.title,a.body,a.data from public.trial_spend_alerts() a;
 else
 pool:=public.trial_sponsor_pool();
 if pool is null then
  code:='trial_pool_missing';title:='No trial sponsor pool is recorded';$b$,
$a$
 -- 9. Paying ceiling-mode workspaces must carry a hosting retention record (policy subscriptions only).$a$,
$b$ end if;

 -- 9. Paying ceiling-mode workspaces must carry a hosting retention record (policy subscriptions only).$b$]);

drop function pg_temp.trial_allowance_patch(regprocedure,text,text,text[]);

-- 6. One read that answers "can a new user start a trial right now?" in
-- per-user mode, with the reasons when the answer is no. Read-only.
create or replace function public.subscription_trial_per_user_readiness()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare pol public.subscription_trial_admission_policy;c public.subscription_trial_config;
 t public.subscription_trial_media_template;a public.media_account_reserves;
 blockers text[]:=array[]::text[];month_start timestamptz:=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC';
begin
 select * into pol from public.subscription_trial_admission_policy where singleton;
 select * into c from public.subscription_trial_config where singleton;
 select * into t from public.subscription_trial_media_template where singleton;
 select * into a from public.media_account_reserves where receipt_ref=t.account_reserve_ref;
 if pol.mode is distinct from 'per_user' then blockers:=array_append(blockers,'admission mode is pool (legacy first-100 rules apply)');end if;
 if c.enabled is distinct from true then blockers:=array_append(blockers,'subscription_trial_config.enabled is false');end if;
 if c.max_days is distinct from 7 then blockers:=array_append(blockers,'subscription_trial_config.max_days is not 7');end if;
 if t.enabled is distinct from true or t.account_reserve_ref is null or t.evidence_sha256 is null then
  blockers:=array_append(blockers,'subscription_trial_media_template is off or incomplete');end if;
 if a.receipt_ref is null or a.starts_at>now() or a.ends_at<now()+interval '97 days' then
  blockers:=array_append(blockers,'the trial hosting record is missing or ends within 97 days');end if;
 if public.serving_mode()<>'ceiling' then
  blockers:=array_append(blockers,'serving mode is not ceiling (TestFlight trials are refused)');end if;
 return jsonb_build_object(
  'admission_mode',pol.mode,
  'new_trials_admitted',cardinality(blockers)=0,
  'blockers',to_jsonb(blockers),
  'allowance',jsonb_build_object('photo_edits',c.photo_edits,'walkthroughs',c.walkthroughs,
   'published_listings',c.published_listings,'max_video_seconds',c.max_video_seconds,
   'max_days',c.max_days,'upload_budget_bytes',c.upload_budget_bytes),
  'per_user_budget_cents',pol.per_user_budget_cents,
  'per_user_ai_budget_cents',pol.per_user_budget_cents-public.serving_reserve_total(pol.per_user_reserve_components),
  'hosting_record',a.receipt_ref,'hosting_record_basis',a.cash_source,
  'alert_thresholds_cents',to_jsonb(pol.alert_thresholds_cents),
  'month_to_date',public.trial_spend_summary(month_start,now()),
  'holds_without_a_pool',(select count(*) from public.subscription_trial_purchase_reservations where pool_id is null),
  'checked_at',now());
end$$;
revoke all on function public.subscription_trial_per_user_readiness() from public,anon,authenticated;
grant execute on function public.subscription_trial_per_user_readiness() to service_role;
