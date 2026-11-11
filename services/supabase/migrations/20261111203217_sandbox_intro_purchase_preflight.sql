-- The native client can identify StoreKit's purchase environment before it
-- opens the sheet. A Sandbox introductory purchase needs a current seven-day
-- operational sponsor; a Production purchase retains its immutable original
-- cash hold and its existing signed-receipt recovery semantics.
--
-- This wrapper is one transaction: sponsor refusal precedes any new hold;
-- later refusal rolls a new hold back. An earlier exact hold stays untouched.
-- The signed Sandbox receipt grant rechecks the sponsor at fulfillment time.
begin;

create or replace function public.prepare_sandbox_intro_trial_purchase(
 p_actor uuid,p_org uuid,p_product text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare offer jsonb; pool jsonb; effective text;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 -- Match the grant_sandbox_intro_trial SKU and serving-mode gates. The
 -- ordinary prepare below checks exact buyer, workspace, identity and cash.
 if p_product not in('com.rendprop.app.pro29.monthly',
  'com.rendprop.app.starter.monthly','com.rendprop.app.pro.monthly',
  'com.rendprop.app.team.monthly') then
  raise exception 'RP400: A supported Sandbox trial product is required';end if;
 -- Preserve the existing admission lock order for new reservations and
 -- conversion. The nested prepare reacquires this transaction lock safely.
 perform pg_advisory_xact_lock(hashtextextended('subscription-trial-admission',72456));
 -- Signed Sandbox fulfillment locks the sponsor before the workspace. Take
 -- that lock before ordinary prepare can lock the workspace too.
 perform pg_advisory_xact_lock(hashtextextended('serving:trial-sponsor',72452));
 if public.serving_mode()<>'ceiling' then
  raise exception 'RP403: Sandbox trials require ceiling serving mode';end if;
 pool:=public.trial_sponsor_pool();
 if pool is null or now()<(pool->>'starts_at')::timestamptz
  or (pool->>'ends_at')::timestamptz<=now()+interval '7 days' then
  raise exception 'RP402: Test-trial sponsor allocation is closed or too short';end if;
 if (pool->>'cap_cents')::numeric-public.trial_sponsor_spent_cents()<500 then
  raise exception 'RP402: Test-trial sponsor allocation has less than one trial envelope';end if;
 offer:=public.prepare_subscription_trial_purchase(p_actor,p_org,p_product);
 -- A held Production reservation may predate a paid workspace. The signed
 -- Sandbox grant would return granted=false, so prevent a new Apple sheet.
 effective:=public.effective_plan(p_org);
 if effective in('starter','solo','legacy_pro','pro','max','ultra','team','brokerage')
  or exists(select 1 from public.orgs where id=p_org and plan='trial'
   and trial_ends_at>now()) then
  raise exception 'RP409: This workspace already has subscription service';end if;
 return offer;
end$$;

revoke all on function public.prepare_sandbox_intro_trial_purchase(uuid,uuid,text)
 from public,anon,authenticated;
grant execute on function public.prepare_sandbox_intro_trial_purchase(uuid,uuid,text)
 to service_role;

-- A historical hold may predate the frozen media snapshot migration. It is
-- still a financial tombstone, but an active Production intro bought today
-- would fail when conversion tries to provision its 90-day media retention.
-- Check only that exact frozen receipt and its referenced paid account. Do
-- not reconsult current trial configuration, schedule or sponsor admission.
create or replace function public.subscription_trial_frozen_media_ready(
 p_actor uuid,p_org uuid,p_product text)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare h public.subscription_trial_purchase_reservations;
 a public.media_account_reserves; tariff jsonb; reserves jsonb;
 k text; n numeric; delivery numeric; compute numeric; storage numeric;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 select * into h from public.subscription_trial_purchase_reservations
  where actor_id=p_actor and org_id=p_org and product_id=p_product and funding_id is null;
 if h.id is null or h.trial_media_account_ref is null
  or h.trial_media_evidence_sha256 is null
  or h.trial_media_evidence_sha256!~'^[a-f0-9]{64}$'
  or h.trial_media_requests is null or h.trial_media_requests not between 1000 and 100000
  or h.trial_media_bytes is null or h.trial_media_bytes not between 1073741824 and 107374182400
  or h.trial_media_storage is null or h.trial_media_storage not between 1342177280 and 10737418240
  then return false;end if;
 select * into a from public.media_account_reserves where receipt_ref=h.trial_media_account_ref;
 if a.receipt_ref is null or a.account_id<>'9c332c75b96cc642621dad5d86d4bf18'
  or a.starts_at>now() or a.ends_at<now()+make_interval(days=>h.max_days)+interval '90 days'
  then return false;end if;
 tariff:=a.tariff;
 if jsonb_typeof(tariff)is distinct from 'object'
  or (select count(*) from jsonb_object_keys(tariff))<>8 then return false;end if;
 foreach k in array array['r2_a_cents_per_million','r2_b_cents_per_million',
  'worker_cents_per_million','worker_cpu_cents_per_million_ms',
  'edge_cents_per_million','db_cents','logs_cents','storage_cents_per_gb_month'] loop
  if jsonb_typeof(tariff->k)is distinct from 'number' then return false;end if;
  n:=(tariff->>k)::numeric;
  if n<0 or n>1000000000 then return false;end if;
 end loop;
 if (tariff->>'r2_a_cents_per_million')::numeric<450
  or (tariff->>'r2_b_cents_per_million')::numeric<36
  or (tariff->>'worker_cents_per_million')::numeric<30
  or (tariff->>'worker_cpu_cents_per_million_ms')::numeric<2
  or (tariff->>'edge_cents_per_million')::numeric<200
  or (tariff->>'db_cents')::numeric<=0
  or (tariff->>'storage_cents_per_gb_month')::numeric<1.5 then return false;end if;
 reserves:=jsonb_build_object('delivery',h.reserve_components->'delivery',
  'compute',h.reserve_components->'compute','storage',h.reserve_components->'storage',
  'retention',h.reserve_components->'retention');
 if jsonb_typeof(reserves)is distinct from 'object' then return false;end if;
 foreach k in array array['delivery','compute','storage','retention'] loop
  if jsonb_typeof(reserves->k)is distinct from 'number' then return false;end if;
  n:=(reserves->>k)::numeric;
  if n<0 or n<>trunc(n) or n>1000000000 then return false;end if;
 end loop;
 delivery:=h.trial_media_requests::numeric/1000000*(
  4*(tariff->>'r2_a_cents_per_million')::numeric
  +2*(tariff->>'r2_b_cents_per_million')::numeric
  +(tariff->>'worker_cents_per_million')::numeric);
 compute:=h.trial_media_requests::numeric/1000000*(tariff->>'edge_cents_per_million')::numeric
  +h.trial_media_requests::numeric*1000/1000000*(tariff->>'worker_cpu_cents_per_million_ms')::numeric;
 storage:=ceil(h.trial_media_storage::numeric/1000000000)
  *ceil(extract(epoch from(make_interval(days=>h.max_days)+interval '90 days'))/2592000)
  *(tariff->>'storage_cents_per_gb_month')::numeric;
 return (reserves->>'delivery')::numeric>=ceil(delivery)
  and (reserves->>'compute')::numeric>=ceil(compute)
  and (reserves->>'storage')::numeric+(reserves->>'retention')::numeric>=ceil(storage);
end$$;
revoke all on function public.subscription_trial_frozen_media_ready(uuid,uuid,text)
 from public,anon,authenticated;
grant execute on function public.subscription_trial_frozen_media_ready(uuid,uuid,text)
 to service_role;

-- Billing GET must not advertise an Apple sheet that a signed active trial
-- could never fulfill. This consults only the immutable held snapshot and its
-- referenced media account; valid historical holds still replay after mutable
-- subscription configuration, schedule and sponsor dates change.
do $patch$ declare d text; a text; b text; old_hits integer; new_hits integer;begin
 d:=pg_get_functiondef('public.subscription_trial_held_offer(uuid,uuid)'::regprocedure);
 a:='if h.id is null then return null;end if;';
 b:=a||E'\n if not public.subscription_trial_frozen_media_ready(p_actor,p_org,h.product_id) then return null;end if;';
 old_hits:=(length(d)-length(replace(d,a,'')))/length(a);
 new_hits:=(length(d)-length(replace(d,b,'')))/length(b);
 if old_hits=1 and new_hits=0 then execute replace(d,a,b);
 elsif old_hits=1 and new_hits=1 then null;
 else raise exception 'Review changed held trial offer predecessor';end if;
end $patch$;

-- Legacy installed clients omit purchase_environment. Refuse an incomplete
-- held receipt before their StoreKit sheet too, with the same typed 402 as the
-- explicit Production preflight. No reservation is released or replaced.
do $patch$ declare d text; a text; b text; old_hits integer; new_hits integer;begin
 d:=pg_get_functiondef('public.prepare_subscription_trial_purchase(uuid,uuid,text)'::regprocedure);
 a:='media_template public.subscription_trial_media_template;';
 b:='media_template public.subscription_trial_media_template;offer jsonb;';
 old_hits:=(length(d)-length(replace(d,a,'')))/length(a);
 new_hits:=(length(d)-length(replace(d,b,'')))/length(b);
 if old_hits=1 and new_hits=0 then d:=replace(d,a,b);
 elsif old_hits=1 and new_hits=1 then null;
 else raise exception 'Review changed trial prepare declaration';end if;
 a:='return public.subscription_trial_held_offer(p_actor,p_org);';
 b:='offer:=public.subscription_trial_held_offer(p_actor,p_org); if offer is null then raise exception ''RP402: Cash-held trial media snapshot is unavailable'';end if; return offer;';
 old_hits:=(length(d)-length(replace(d,a,'')))/length(a);
 new_hits:=(length(d)-length(replace(d,b,'')))/length(b);
 if old_hits=2 and new_hits=0 then execute replace(d,a,b);
 elsif old_hits=0 and new_hits=2 then null;
 else raise exception 'Review changed trial prepare replay/insert paths';end if;
end $patch$;

create or replace function public.prepare_production_intro_trial_purchase(
 p_actor uuid,p_org uuid,p_product text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare offer jsonb;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 offer:=public.prepare_subscription_trial_purchase(p_actor,p_org,p_product);
 if not public.subscription_trial_frozen_media_ready(p_actor,p_org,p_product) then
  raise exception 'RP402: Cash-held trial media snapshot is unavailable';end if;
 return offer;
end$$;
revoke all on function public.prepare_production_intro_trial_purchase(uuid,uuid,text)
 from public,anon,authenticated;
grant execute on function public.prepare_production_intro_trial_purchase(uuid,uuid,text)
 to service_role;
commit;
