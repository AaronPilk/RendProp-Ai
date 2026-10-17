-- Launch blockers — 2026-10-08 (Codex review CODEX-CLAUDE-LAUNCH-ALIGNMENT-20261008).
--
-- 5. serving_mode() fails CLOSED: only an explicit, well-formed ceiling row enables
--    ceiling mode. A missing or malformed row is funded mode and is alerted hourly.
-- 2. SKU-aware serving envelope: the monthly AI ceiling of a paid workspace is
--    25% of its net-of-Apple receipts for the SKU it actually bought (annual SKUs
--    are ten monthly prices over twelve months) minus a hosting reserve. The
--    introductory week and Sandbox trials are capped at trial_ceiling_cents and
--    draw from one global monthly sponsor pool. The free tier is a lifetime sample.
-- 1. Every ceiling-mode paid attempt reserves money atomically BEFORE dispatch
--    through serving_cost_reserve (budget_source='ceiling'), under the existing
--    per-workspace advisory lock; open holds share the envelope with the ledger
--    and with video/erase holds; uncertain outcomes keep their hold all month.
-- 3. Sandbox trial grants validate the receipt's status and expiry, persist the
--    receipt, grant once per receipt, replay without restarting, and never
--    downgrade a paid workspace.
-- 4. The free published-listing slot is a durable row consumed under a lock.
-- 6. Hosting retention is recorded independently of AI funding rows for every
--    applied Production entitlement and every Sandbox trial (service end + 90
--    days, never shortened); owner-granted and brokerage plans stay preserved.
-- Every rewrite anchors on the exact live body and fails loudly if it drifted.
begin;

create function pg_temp.rp_patch(fn regprocedure,needle text,replacement text)returns void
language plpgsql as $$
declare def text;n integer;
begin
 def:=pg_get_functiondef(fn);
 n:=(length(def)-length(replace(def,needle,'')))/length(needle);
 if n<>1 then raise exception 'launch-blockers migration: anchor for % found % times; refusing to patch',fn,n;end if;
 execute replace(def,needle,replacement);
end$$;

-- ---------------------------------------------------------------- 5. fail closed
create or replace function public.serving_mode()returns text
language sql stable security definer set search_path='' as $$
 select case when exists(select 1 from public.app_config where key='serving_mode'
   and jsonb_typeof(value)='object' and value->>'mode'='ceiling'
   and jsonb_typeof(value->'free_published_listings')='number'
   and (value->>'free_published_listings')::numeric between 0 and 100)
  then 'ceiling' else 'funded' end;
$$;
-- 'ceiling' | 'funded' | 'missing' | 'invalid' — for the hourly alert, never for admission.
create or replace function public.serving_mode_config_state()returns text
language sql stable security definer set search_path='' as $$
 select case
  when not exists(select 1 from public.app_config where key='serving_mode') then 'missing'
  when public.serving_mode()='ceiling' then 'ceiling'
  when (select value->>'mode' from public.app_config where key='serving_mode')='funded' then 'funded'
  else 'invalid' end;
$$;
revoke all on function public.serving_mode_config_state()from public,anon,authenticated;
grant execute on function public.serving_mode_config_state()to service_role,postgres;

-- ---------------------------------------------------------------- 2. envelope
insert into public.app_config(key,value)values('serving_envelope',jsonb_build_object(
 'apple_commission_bps',1500,'net_margin_bps',7500,'hosting_reserve_cents',50,
 'trial_ceiling_cents',500,'trial_sponsor_cap_cents',29000,'free_lifetime_cents',300,
 'note','Monthly AI envelope = net-of-Apple receipts x (1 - net_margin) - hosting reserve. apple_commission_bps 1500 assumes the App Store Small Business Program; set 3000 until enrollment is confirmed. Trial = introductory week or Sandbox; the sponsor cap is the approved launch testing budget.'))
on conflict(key)do nothing;

create or replace function public.serving_envelope_int(p_key text,p_default integer)returns integer
language sql stable security definer set search_path='' as $$
 select coalesce((select case when jsonb_typeof(value->p_key)='number' and (value->>p_key)::numeric between 0 and 100000000
  then (value->>p_key)::integer end from public.app_config where key='serving_envelope'),p_default);
$$;
revoke all on function public.serving_envelope_int(text,integer)from public,anon,authenticated;
grant execute on function public.serving_envelope_int(text,integer)to service_role,postgres;

-- Serving ceiling for one workspace: {ceiling_cents, basis: month|lifetime, kind, plan, sku}.
-- Never null: an unknown shape yields a zero ceiling, which refuses every paid attempt.
create or replace function public.plan_serving_ceiling(p_org uuid)returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare o public.orgs;e public.plan_entitlements;plan text;annual boolean;commission integer;margin integer;reserve integer;
 monthly_net numeric;envelope integer;intro boolean;sku text;trial_cap integer;
begin
 select * into o from public.orgs where id=p_org and deleted_at is null;
 if o.id is null then raise exception 'RP404: Workspace unavailable';end if;
 if public.org_has_private_internal_testing(p_org)or public.org_has_internal_testing_grant(p_org)then
  return jsonb_build_object('ceiling_cents',2147483647,'basis','month','kind','sponsored','plan','team','sku',null);end if;
 if public.org_has_app_review_funding(p_org)then
  return jsonb_build_object('ceiling_cents',500,'basis','month','kind','app_review','plan','pro','sku',null);end if;
 e:=public.org_entitlement(p_org);plan:=e.plan;trial_cap:=public.serving_envelope_int('trial_ceiling_cents',500);
 if plan='brokerage'then return jsonb_build_object('ceiling_cents',coalesce(e.cogs_ceiling_cents,0),'basis','month','kind','brokerage','plan',plan,'sku',null);end if;
 if plan='free'then return jsonb_build_object('ceiling_cents',public.serving_envelope_int('free_lifetime_cents',300),'basis','lifetime','kind','free','plan',plan,'sku',null);end if;
 if plan='trial'then return jsonb_build_object('ceiling_cents',trial_cap,'basis','month','kind','trial','plan',plan,'sku',null);end if;
 if plan in('starter','solo','pro','team')then
  if o.plan_source='manual'then return jsonb_build_object('ceiling_cents',coalesce(e.cogs_ceiling_cents,0),'basis','month','kind','manual','plan',plan,'sku',null);end if;
  sku:=o.apple_product_id;annual:=coalesce(sku,'')like '%.annual';
  commission:=public.serving_envelope_int('apple_commission_bps',1500);margin:=public.serving_envelope_int('net_margin_bps',7500);
  reserve:=public.serving_envelope_int('hosting_reserve_cents',50);
  -- Annual SKUs are ten monthly prices for twelve months of service.
  monthly_net:=case when annual then coalesce(e.price_cents,0)*10.0*(10000-commission)/10000/12 else coalesce(e.price_cents,0)*(10000-commission)/10000.0 end;
  envelope:=greatest(0,floor(monthly_net*(10000-margin)/10000.0)::integer-reserve);
  -- An introductory week is sponsored, not retail receipts: it is capped like a trial.
  intro:=exists(select 1 from public.apple_subscriptions s where s.org_id=p_org and s.environment='Production' and s.status in('active','grace')
   and s.transaction_purchased_at is not null and s.expires_at is not null and s.expires_at>now()
   and s.expires_at<=s.transaction_purchased_at+interval '8 days');
  if intro then return jsonb_build_object('ceiling_cents',least(envelope,trial_cap),'basis','month','kind','trial','plan',plan,'sku',sku);end if;
  return jsonb_build_object('ceiling_cents',envelope,'basis','month','kind','retail','plan',plan,'sku',sku);
 end if;
 return jsonb_build_object('ceiling_cents',coalesce(e.cogs_ceiling_cents,0),'basis','month','kind','other','plan',plan,'sku',null);
end$$;
revoke all on function public.plan_serving_ceiling(uuid)from public,anon,authenticated;
grant execute on function public.plan_serving_ceiling(uuid)to service_role,postgres;

-- ---------------------------------------------------------------- 1. reservations
alter table public.serving_cost_reservations add column if not exists budget_source text not null default 'funding';
alter table public.serving_cost_reservations add column if not exists trial_kind boolean not null default false;
alter table public.serving_cost_reservations drop constraint if exists serving_cost_reservations_budget_source_check;
alter table public.serving_cost_reservations add constraint serving_cost_reservations_budget_source_check check(budget_source in('funding','ceiling'));
alter table public.serving_cost_reservations drop constraint if exists serving_cost_reservations_check;
alter table public.serving_cost_reservations add constraint serving_cost_reservations_check check(
 (sponsored_unlimited and funding_id is null and slice_index is null)
 or(not sponsored_unlimited and budget_source='ceiling' and funding_id is null and slice_index is null)
 or(not sponsored_unlimited and budget_source='funding' and funding_id is not null and slice_index is not null));
create index if not exists serving_cost_reservations_ceiling_open on public.serving_cost_reservations(org_id,created_at)where budget_source='ceiling';
create index if not exists serving_cost_reservations_trial_kind on public.serving_cost_reservations(created_at)where trial_kind;

-- Money already committed by this workspace: ledger spend (month or lifetime),
-- every open ceiling hold (reserved, or uncertain = potentially billable), a
-- settled success for two more minutes (its ledger row lands right after), and
-- the video/erase holds that settle into the ledger minutes after dispatch.
create or replace function public.serving_ceiling_spent_cents(p_org uuid,p_basis text)returns numeric
language sql stable security definer set search_path='' as $$
 select coalesce((select sum(total_cents)from public.cost_ledger where org_id=p_org and(p_basis='lifetime' or created_at>=date_trunc('month',now()))),0)
  +coalesce((select sum(hold_cents)from public.serving_cost_reservations where org_id=p_org and budget_source='ceiling'
     and(p_basis='lifetime' or created_at>=date_trunc('month',now()))
     and(state in('reserved','uncertain')or(state='succeeded' and settled_at>now()-interval '2 minutes'))),0)
  +public.app_video_held_cents(p_org)+public.video_erase_held_cents(p_org);
$$;
revoke all on function public.serving_ceiling_spent_cents(uuid,text)from public,anon,authenticated;
grant execute on function public.serving_ceiling_spent_cents(uuid,text)to service_role,postgres;

create or replace function public.trial_sponsor_spent_cents()returns numeric
language sql stable security definer set search_path='' as $$
 select coalesce(sum(hold_cents),0)from public.serving_cost_reservations
  where trial_kind and budget_source='ceiling' and state<>'rejected' and created_at>=date_trunc('month',now());
$$;
revoke all on function public.trial_sponsor_spent_cents()from public,anon,authenticated;
grant execute on function public.trial_sponsor_spent_cents()to service_role,postgres;

do $$
begin
 perform pg_temp.rp_patch('public.serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text)'::regprocedure,
  $n$ unlimited boolean;spent numeric;reservation uuid;$n$,
  $r$ unlimited boolean;spent numeric;reservation uuid;envelope jsonb;ceiling numeric;basis text;kind text;$r$);
 perform pg_temp.rp_patch('public.serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text)'::regprocedure,
  $n$  if p_tariff_version='unpriced-private-sponsorship' then raise exception 'RP403: An unpriced route is restricted to unlimited private sponsorship';end if;$n$,
  $r$  if p_tariff_version='unpriced-private-sponsorship' then raise exception 'RP403: An unpriced route is restricted to unlimited private sponsorship';end if;
  if public.serving_mode()='ceiling' then
   -- Ceiling mode (2026-10-08): the workspace's serving envelope is the budget.
   -- Admission is atomic under the per-workspace advisory lock taken above.
   envelope:=public.plan_serving_ceiling(p_org);
   ceiling:=(envelope->>'ceiling_cents')::numeric;basis:=envelope->>'basis';kind:=envelope->>'kind';
   spent:=public.serving_ceiling_spent_cents(p_org,basis);
   if ceiling is null or basis is null or spent is null or spent+p_hold_cents>ceiling then
    raise exception 'RP402: AI usage limit reached for this workspace (% of % cents this %)',round(coalesce(spent,0)),coalesce(ceiling,0),coalesce(basis,'month');end if;
   if kind='trial' then
    perform pg_advisory_xact_lock(hashtextextended('serving:trial-sponsor',72452));
    if public.trial_sponsor_spent_cents()+p_hold_cents>public.serving_envelope_int('trial_sponsor_cap_cents',29000)then raise exception 'RP402: Free-trial AI limit reached for this month';end if;
   end if;
   insert into public.serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,sponsored_unlimited,budget_source,trial_kind)
   values(p_org,p_actor,p_key,p_stage,p_provider,p_model,p_input_sha256,p_tariff_version,p_hold_cents,false,'ceiling',kind='trial')returning id into reservation;
   return jsonb_build_object('reserved',true,'id',reservation,'hold_cents',p_hold_cents,'sponsored_unlimited',false,'budget','ceiling','ceiling_cents',ceiling,'spent_cents',spent,'basis',basis,'kind',kind);
  end if;$r$);
 -- Reservations exist again in ceiling mode; restore the strict result check.
 perform pg_temp.rp_patch('public.serving_operation_complete(uuid,uuid,text,jsonb)'::regprocedure,
  $n$ if public.serving_mode()<>'ceiling'and not exists(select 1 from public.serving_cost_reservations where org_id=p_org and actor_id=p_actor and request_key=p_key and state<>'rejected')then raise exception 'RP409: Generated result has no admitted provider attempt';end if;$n$,
  $r$ if not exists(select 1 from public.serving_cost_reservations where org_id=p_org and actor_id=p_actor and request_key=p_key and state<>'rejected')then raise exception 'RP409: Generated result has no admitted provider attempt';end if;$r$);
end$$;

-- ---------------------------------------------------------------- 6. retention
create table if not exists public.hosting_retention_enrollments(
 id uuid primary key default gen_random_uuid(),
 org_id uuid not null references public.orgs(id)on delete cascade,
 source text not null check(source in('apple_subscription','sandbox_trial')),
 reference text not null check(length(reference)between 1 and 200),
 service_ends_at timestamptz,
 retention_ends_at timestamptz not null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(org_id,source,reference));
alter table public.hosting_retention_enrollments enable row level security;
revoke all on public.hosting_retention_enrollments from public,anon,authenticated,service_role;
grant select,insert,update on public.hosting_retention_enrollments to service_role;
create index if not exists hosting_retention_enrollments_deadline on public.hosting_retention_enrollments(retention_ends_at);

-- Service end + 90 days. A renewal extends the deadline; a refund never shortens
-- the promised grace. Callable only by the service role / migrations and from
-- SECURITY DEFINER writers (privilege is checked against the definer).
create or replace function public.hosting_retention_enroll(p_org uuid,p_source text,p_reference text,p_service_ends_at timestamptz)returns jsonb
language plpgsql security definer set search_path='' as $$
declare deadline timestamptz;row public.hosting_retention_enrollments;
begin
 if p_source not in('apple_subscription','sandbox_trial')or p_reference is null or length(p_reference)not between 1 and 200 then raise exception 'RP400: A hosting enrollment needs a source and reference';end if;
 if p_service_ends_at is null or not pg_catalog.isfinite(p_service_ends_at)then raise exception 'RP400: A hosting enrollment needs the service end';end if;
 if not exists(select 1 from public.orgs where id=p_org and deleted_at is null)then raise exception 'RP404: Workspace unavailable';end if;
 deadline:=p_service_ends_at+interval '90 days';
 insert into public.hosting_retention_enrollments(org_id,source,reference,service_ends_at,retention_ends_at)
 values(p_org,p_source,p_reference,p_service_ends_at,deadline)
 on conflict(org_id,source,reference)do update set
  service_ends_at=greatest(public.hosting_retention_enrollments.service_ends_at,excluded.service_ends_at),
  retention_ends_at=greatest(public.hosting_retention_enrollments.retention_ends_at,excluded.retention_ends_at),updated_at=now()
 returning * into row;
 return jsonb_build_object('enrolled',true,'id',row.id,'retention_ends_at',row.retention_ends_at);
end$$;
revoke all on function public.hosting_retention_enroll(uuid,text,text,timestamptz)from public,anon,authenticated;
grant execute on function public.hosting_retention_enroll(uuid,text,text,timestamptz)to service_role,postgres;

do $$
begin
 -- Deadline = the latest of funded-model rows and ceiling-model enrollments.
 perform pg_temp.rp_patch('public.hosting_retention_state(uuid)'::regprocedure,
  $n$declare deadline timestamptz;qa boolean;$n$,
  $r$declare deadline timestamptz;qa boolean;comped boolean:=false;$r$);
 perform pg_temp.rp_patch('public.hosting_retention_state(uuid)'::regprocedure,
  $n$ select max(retention_ends_at)into deadline from public.serving_funding where org_id=p_org and source in('retail','trial');$n$,
  $r$ select greatest((select max(retention_ends_at)from public.serving_funding where org_id=p_org and source in('retail','trial')),
  (select max(retention_ends_at)from public.hosting_retention_enrollments where org_id=p_org))into deadline;
 -- An owner-granted paid plan or a signed brokerage contract is not subject to
 -- a lapsed App Store subscription's grace deadline.
 comped:=(exists(select 1 from public.orgs o where o.id=p_org and o.plan_source='manual')and public.effective_plan(p_org)in('starter','solo','pro','team'))or public.effective_plan(p_org)='brokerage';$r$);
 perform pg_temp.rp_patch('public.hosting_retention_state(uuid)'::regprocedure,
  $n$ if qa or deadline is null then return$n$,
  $r$ if qa or comped or deadline is null then return$r$);
 perform pg_temp.rp_patch('public.queue_hosting_retention_notices()'::regprocedure,
  $n$  with latest as(select distinct on(org_id)id,org_id,retention_ends_at from public.serving_funding where source in('retail','trial')order by org_id,retention_ends_at desc,id)$n$,
  $r$  with latest as(select distinct on(org_id)id,org_id,retention_ends_at from(
   select id,org_id,retention_ends_at from public.serving_funding where source in('retail','trial')
   union all select e.id,e.org_id,e.retention_ends_at from public.hosting_retention_enrollments e join public.orgs eo on eo.id=e.org_id
    where not(eo.plan_source='manual' and public.effective_plan(e.org_id)in('starter','solo','pro','team'))and public.effective_plan(e.org_id)<>'brokerage')x order by org_id,retention_ends_at desc,id)$r$);
 -- Every applied Production entitlement (device sync and server notification)
 -- records or extends the workspace's hosting retention in ceiling mode.
 perform pg_temp.rp_patch('public.apply_apple_entitlement_v2(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text,timestamptz,timestamptz,timestamptz,timestamptz)'::regprocedure,
  $n$declare s public.apple_subscriptions; signed_at timestamptz;$n$,
  $r$declare s public.apple_subscriptions; signed_at timestamptz; retention_org uuid;$r$);
 perform pg_temp.rp_patch('public.apply_apple_entitlement_v2(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text,timestamptz,timestamptz,timestamptz,timestamptz)'::regprocedure,
  $n$    where original_transaction_id=p_original_transaction_id;
  return r;$n$,
  $r$    where original_transaction_id=p_original_transaction_id;
  if public.serving_mode()='ceiling' and coalesce((r->>'org_updated')::boolean,false) and next_expiry is not null and next_status in('active','grace','expired') then
    select org_id into retention_org from public.apple_subscriptions where original_transaction_id=p_original_transaction_id;
    if retention_org is not null then perform public.hosting_retention_enroll(retention_org,'apple_subscription',p_original_transaction_id,next_expiry);end if;
  end if;
  return r;$r$);
end$$;

-- Existing Production subscribers get their 90-day grace recorded now.
select public.hosting_retention_enroll(s.org_id,'apple_subscription',s.original_transaction_id,s.expires_at)
from public.apple_subscriptions s join public.orgs o on o.id=s.org_id and o.deleted_at is null
where s.environment='Production' and s.status in('active','grace','expired') and s.expires_at is not null;

-- ---------------------------------------------------------------- 4. free slot
create table if not exists public.workspace_publication_slots(
 org_id uuid not null references public.orgs(id)on delete cascade,
 listing_id uuid not null,
 consumed_at timestamptz not null default now(),
 source text not null default 'free' check(source in('free')),
 primary key(org_id,listing_id));
alter table public.workspace_publication_slots enable row level security;
revoke all on public.workspace_publication_slots from public,anon,authenticated,service_role;
grant select,insert on public.workspace_publication_slots to service_role;

-- Consumes a slot atomically: concurrent first publications serialize on the
-- workspace lock, so only `free_published_listings()` distinct listings can ever
-- be admitted. Re-admitting a listing that holds a slot is free and idempotent.
create or replace function public.free_publication_admit(p_org uuid,p_listing uuid)returns boolean
language plpgsql volatile security definer set search_path='' as $$
declare used integer;
begin
 if public.serving_mode()<>'ceiling' or p_org is null or p_listing is null then return false;end if;
 perform pg_advisory_xact_lock(hashtextextended('free_publication:'||p_org,72454));
 if exists(select 1 from public.workspace_publication_slots where org_id=p_org and listing_id=p_listing)then return true;end if;
 select count(*)into used from public.workspace_publication_slots where org_id=p_org;
 if used>=public.free_published_listings()then return false;end if;
 insert into public.workspace_publication_slots(org_id,listing_id)values(p_org,p_listing);
 return true;
end$$;
revoke all on function public.free_publication_admit(uuid,uuid)from public,anon,authenticated;
grant execute on function public.free_publication_admit(uuid,uuid)to service_role,postgres;

-- Read-only view of the same rule (console/support); never consumes a slot.
create or replace function public.free_publication_admitted(p_org uuid,p_listing uuid)returns boolean
language sql stable security definer set search_path='' as $$
 select public.serving_mode()='ceiling' and p_listing is not null and(
  exists(select 1 from public.workspace_publication_slots where org_id=p_org and listing_id=p_listing)
  or(select count(*)from public.workspace_publication_slots where org_id=p_org)<public.free_published_listings());
$$;

-- Listings that already published keep their slot, so they can be re-published.
insert into public.workspace_publication_slots(org_id,listing_id,consumed_at)
select l.org_id,r.listing_id,min(r.created_at)from public.renders r join public.listings l on l.id=r.listing_id
group by l.org_id,r.listing_id on conflict do nothing;

do $$
begin
 perform pg_temp.rp_patch('public.subscription_trial_render_guard()'::regprocedure,
  $n$ if public.free_publication_admitted(org,listing)then return new;end if;$n$,
  $r$ if public.free_publication_admit(org,listing)then return new;end if;$r$);
end$$;

-- ---------------------------------------------------------------- 3. Sandbox trial
alter table public.apple_sandbox_receipts add column if not exists trial_granted_at timestamptz;
alter table public.apple_sandbox_receipts add column if not exists trial_ends_at timestamptz;
alter table public.apple_sandbox_receipts add column if not exists receipt_expires_at timestamptz;
create index if not exists apple_sandbox_receipts_trial_org on public.apple_sandbox_receipts(org_id)where trial_granted_at is not null;

drop function if exists public.grant_sandbox_trial(uuid,uuid,text,text);
create or replace function public.grant_sandbox_trial(p_org uuid,p_actor uuid,p_original text,p_transaction text,p_product text,
 p_status text,p_expires_at timestamptz,p_signed_at timestamptz)returns jsonb
language plpgsql security definer set search_path='' as $$
declare o public.orgs;receipt public.apple_sandbox_receipts;ends timestamptz;current_plan text;
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
 -- The receipt is always persisted with its latest facts; grant fields are written once.
 insert into public.apple_sandbox_receipts(original_transaction_id,org_id,actor_id,transaction_id,product_id,status,signed_at,receipt_expires_at)
 values(p_original,p_org,p_actor,p_transaction,p_product,p_status,p_signed_at,p_expires_at)
 on conflict(original_transaction_id)do update set transaction_id=excluded.transaction_id,product_id=excluded.product_id,status=excluded.status,
  signed_at=greatest(public.apple_sandbox_receipts.signed_at,excluded.signed_at),receipt_expires_at=excluded.receipt_expires_at,updated_at=now()
 returning * into receipt;
 current_plan:=public.effective_plan(p_org);
 -- Replay of an already granted receipt reports its window; it never restarts.
 if receipt.trial_granted_at is not null then
  return jsonb_build_object('plan',case when receipt.trial_ends_at>now()then 'trial' else current_plan end,
   'source',case when receipt.trial_ends_at>now()then 'trial' else o.plan_source end,'expires_at',receipt.trial_ends_at,
   'granted',false,'replay',true,'reason','already_granted','original_transaction_id',p_original,'product_id',p_product);
 end if;
 -- A paid workspace is never downgraded by a test receipt.
 if current_plan in('starter','solo','pro','team','brokerage')then
  return jsonb_build_object('plan',current_plan,'source',o.plan_source,'expires_at',o.plan_expires_at,'granted',false,'replay',false,'reason','paid_workspace',
   'original_transaction_id',p_original,'product_id',p_product);
 end if;
 -- Only a currently valid receipt opens a sponsored window (recorded either way).
 if p_status not in('active','grace')or p_expires_at is null or p_expires_at<=now()then
  return jsonb_build_object('plan',current_plan,'source',o.plan_source,'expires_at',case when o.plan='trial'then o.trial_ends_at else o.plan_expires_at end,
   'granted',false,'replay',false,'reason','receipt_inactive','receipt_status',p_status,'original_transaction_id',p_original,'product_id',p_product);
 end if;
 -- A window that is still open is reported, not extended.
 if o.plan='trial' and o.trial_ends_at is not null and o.trial_ends_at>now() then
  return jsonb_build_object('plan','trial','source','trial','expires_at',o.trial_ends_at,'granted',false,'replay',false,'reason','trial_active',
   'original_transaction_id',p_original,'product_id',p_product);
 end if;
 ends:=now()+interval '7 days';
 update public.apple_sandbox_receipts set trial_granted_at=now(),trial_ends_at=ends,updated_at=now()where original_transaction_id=p_original;
 update public.orgs set plan='trial',plan_source='trial',trial_ends_at=ends where id=p_org;
 perform public.hosting_retention_enroll(p_org,'sandbox_trial',p_original,ends);
 return jsonb_build_object('plan','trial','source','trial','expires_at',ends,'granted',true,'replay',false,'reason','granted','original_transaction_id',p_original,'product_id',p_product);
end$$;
revoke all on function public.grant_sandbox_trial(uuid,uuid,text,text,text,text,timestamptz,timestamptz)from public,anon,authenticated;
grant execute on function public.grant_sandbox_trial(uuid,uuid,text,text,text,text,timestamptz,timestamptz)to service_role;

-- ---------------------------------------------------------------- 7. provider evidence
-- Blocker 7: 28 Seedance failures left no HTTP status behind, so "upstream"
-- could not be told apart as a dead key (401), an empty balance (402) or an
-- outage (5xx). The breaker now keeps the last upstream status; the router
-- reports it from ProviderError.status. Same body as 0018 plus one column.
alter table public.provider_health add column if not exists last_status integer;
drop function if exists public.report_provider_outcome(text,text,boolean,integer,text);
create or replace function public.report_provider_outcome(p_provider text,p_model text,p_ok boolean,p_latency_ms integer default null,p_error_class text default null,p_status integer default null)
returns void language plpgsql security definer set search_path='public' as $$
declare
  v_provider text := btrim(coalesce(p_provider, ''));
  v_model    text := btrim(coalesce(p_model, ''));
  v_ok       boolean := coalesce(p_ok, false);
  v_lat      integer := case when coalesce(p_latency_ms, 0) > 0 then p_latency_ms else null end;
  v_class    text := nullif(btrim(coalesce(p_error_class, '')), '');
  v_status   integer := case when p_status between 100 and 599 then p_status else null end;
  v_prev     integer;
  v_fails    integer;
begin
  if v_provider = '' or v_model = '' then
    return;
  end if;
  insert into provider_health (provider, model) values (v_provider, v_model)
  on conflict (provider, model) do nothing;
  select consecutive_failures, p95_latency_ms
    into v_fails, v_prev
    from provider_health
   where provider = v_provider and model = v_model
   for update;
  if v_ok then
    update provider_health
       set consecutive_failures = 0,
           open_until           = null,
           last_ok_at           = now(),
           p95_latency_ms       = case
                                    when v_lat is null then p95_latency_ms
                                    when v_prev is null then v_lat
                                    when v_lat > v_prev then round(v_prev * 0.7 + v_lat * 0.3)::integer
                                    else round(v_prev * 0.95 + v_lat * 0.05)::integer
                                  end
     where provider = v_provider and model = v_model;
  else
    v_fails := coalesce(v_fails, 0) + 1;
    update provider_health
       set consecutive_failures = v_fails,
           last_fail_at         = now(),
           last_error_class     = v_class,
           last_status          = v_status,
           open_until           = case
                                    when v_class = 'rate_limit' or v_fails >= 3
                                      then now() + interval '10 minutes'
                                    else open_until
                                  end,
           p95_latency_ms       = case
                                    when v_lat is null then p95_latency_ms
                                    when v_prev is null then v_lat
                                    when v_lat > v_prev then round(v_prev * 0.7 + v_lat * 0.3)::integer
                                    else round(v_prev * 0.95 + v_lat * 0.05)::integer
                                  end
     where provider = v_provider and model = v_model;
  end if;
end;
$$;
revoke execute on function public.report_provider_outcome(text,text,boolean,integer,text,integer) from public,anon,authenticated;
grant execute on function public.report_provider_outcome(text,text,boolean,integer,text,integer) to service_role;
comment on function public.report_provider_outcome(text,text,boolean,integer,text,integer) is
  'Records ONE provider attempt into provider_health (3 consecutive failures or any rate_limit opens the circuit 10 minutes; a success closes it). p_status keeps the last upstream HTTP status so a dead key (401), an empty balance (402) and an outage (5xx) are distinguishable.';

-- ---------------------------------------------------------------- alerts
create or replace function public.ops_health_findings()returns table(code text,title text,body text,data jsonb)
language plpgsql stable security definer set search_path='' as $$
declare r record;attempts bigint;successes bigint;n bigint;spent numeric;cfg text;cap integer;
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

 -- 8. Trial sponsorship pool near its monthly cap.
 cap:=public.serving_envelope_int('trial_sponsor_cap_cents',29000);spent:=public.trial_sponsor_spent_cents();
 if spent>=0.8*cap then
  code:='trial_sponsor_near_cap';title:='Free-trial AI sponsorship at '||round(100*spent/greatest(cap,1))||'% of the monthly cap';
  body:=to_char(spent/100,'FM999990.00')||' of '||to_char(cap/100.0,'FM999990.00')||' USD of trial AI usage this month. New trial attempts are refused at the cap.';
  data:=jsonb_build_object('spent_cents',spent,'cap_cents',cap);return next;
 end if;

 -- 9. Paying ceiling-mode workspaces must carry a hosting retention record.
 if public.serving_mode()='ceiling' then
  select count(*) into n from public.orgs o where o.deleted_at is null and o.plan_source='apple' and public.effective_plan(o.id)in('starter','solo','pro','team')
   and not exists(select 1 from public.hosting_retention_enrollments e where e.org_id=o.id)
   and not exists(select 1 from public.serving_funding f where f.org_id=o.id and f.source in('retail','trial'));
  if n>0 then
   code:='retention_missing';title:=n||' paid workspace(s) without a hosting retention record';
   body:='A subscription was applied without a hosting retention deadline. Replay the purchase sync (Restore in the app) or enroll it manually with hosting_retention_enroll().';
   data:=jsonb_build_object('orgs',n);return next;
  end if;
 end if;

 -- 10. Spend anomalies: more than $50 of provider cost in 24h, or any workspace at 80% of its ceiling.
 select coalesce(sum(total_cents),0) into spent from public.cost_ledger where created_at>now()-interval '24 hours';
 if spent>5000 then
  code:='spend_spike_24h';title:='Provider spend '||to_char(spent/100,'FM999990.00')||' USD in 24h';
  body:='More than $50 of AI provider cost was recorded in the last 24 hours. Check the cost ledger for a runaway workspace or a pricing bug.';
  data:=jsonb_build_object('cents',spent);return next;
 end if;
 for r in select o.id,o.name,c.envelope from public.orgs o cross join lateral public.plan_serving_ceiling(o.id) as c(envelope) where o.deleted_at is null
 loop
  spent:=public.serving_ceiling_spent_cents(r.id,r.envelope->>'basis');
  if (r.envelope->>'ceiling_cents')::numeric>0 and (r.envelope->>'ceiling_cents')::numeric<2147483647 and spent>=0.8*(r.envelope->>'ceiling_cents')::numeric then
   code:='org_near_ceiling:'||r.id;title:='Workspace near its AI ceiling: '||coalesce(r.name,r.id::text);
   body:=to_char(spent/100.0,'FM999990.00')||' of '||to_char((r.envelope->>'ceiling_cents')::numeric/100.0,'FM999990.00')||' USD used this '||(r.envelope->>'basis')||' on plan '||(r.envelope->>'plan')||'. Further AI requests are refused at the ceiling.';
   data:=jsonb_build_object('org_id',r.id,'spent_cents',spent,'ceiling_cents',(r.envelope->>'ceiling_cents')::numeric,'basis',r.envelope->>'basis','plan',r.envelope->>'plan','kind',r.envelope->>'kind');
   return next;
  end if;
 end loop;
 return;
end$$;

commit;
