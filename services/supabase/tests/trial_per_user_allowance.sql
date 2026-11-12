\set ON_ERROR_STOP on
-- Per-user free-trial allowance (migration 20261112223000). Synthetic rows
-- only; everything is rolled back. Run against a database that has every
-- migration applied:
--   psql -X -v ON_ERROR_STOP=1 -f services/supabase/tests/trial_per_user_allowance.sql
begin;
create temporary table per_user_case(n integer not null default 0);
insert into per_user_case default values;
grant all on per_user_case to service_role;
create function pg_temp.pu_ok(v boolean,label text) returns void language plpgsql as $$
begin
 if v is distinct from true then raise exception 'PER-USER TRIAL FAIL: %',label;end if;
 update per_user_case set n=n+1;
end$$;
create function pg_temp.pu_refuses(q text,needle text,label text) returns void language plpgsql as $$
begin
 begin execute q;exception when others then
  if position(needle in sqlerrm)>0 then perform pg_temp.pu_ok(true,label);return;end if;
  raise exception 'PER-USER TRIAL FAIL: % refused for another reason: %',label,sqlerrm;
 end;
 raise exception 'PER-USER TRIAL FAIL admitted: %',label;
end$$;
create function pg_temp.pu_user(n integer) returns void language plpgsql as $$
begin
 insert into auth.users(id,email,is_anonymous,email_confirmed_at)
  values(('f7100000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'per-user-'||n||'@example.invalid',false,now());
 insert into public.orgs(id,name,plan,plan_source)
  values(('f7200000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'Per user '||n,'free',null);
 insert into public.memberships(user_id,org_id,role)
  values(('f7100000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
         ('f7200000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'owner')
  on conflict do nothing;
end$$;
create function pg_temp.pu_actor(n integer) returns uuid language sql immutable as
 $$select ('f7100000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid$$;
create function pg_temp.pu_org(n integer) returns uuid language sql immutable as
 $$select ('f7200000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid$$;
grant execute on function pg_temp.pu_actor(integer),pg_temp.pu_org(integer) to service_role;

-- Installed state and privileges.
select pg_temp.pu_ok((select mode='pool' from public.subscription_trial_admission_policy where singleton),
 'the migration installs the policy dormant (pool rules)');
select pg_temp.pu_ok(public.subscription_trial_admission_mode()='pool','mode reader agrees');
select pg_temp.pu_ok(not has_table_privilege('authenticated','public.subscription_trial_admission_policy','SELECT')
 and not has_table_privilege('anon','public.subscription_trial_admission_policy','SELECT'),
 'the policy is not client-readable');
select pg_temp.pu_ok(not has_function_privilege('authenticated','public.subscription_trial_per_user_readiness()','EXECUTE')
 and not has_function_privilege('authenticated','public.trial_spend_summary(timestamptz,timestamptz)','EXECUTE')
 and not has_function_privilege('authenticated','public.trial_spend_alerts()','EXECUTE')
 and not has_function_privilege('authenticated','public.subscription_trial_admission_mode()','EXECUTE'),
 'the new functions are service-only');

-- The live situation of 12 Nov 2026: trial switched on, the legacy sponsor
-- allocation ended, a hosting record, and NO current supplier attestation.
insert into public.app_config(key,value) values
 ('serving_mode','{"mode":"ceiling","free_published_listings":1}')
 on conflict(key) do update set value=excluded.value;
insert into public.app_config(key,value) values
 ('trial_sponsor_pool',jsonb_build_object('cap_cents',29000,'starts_at',now()-interval '35 days','ends_at',now()-interval '4 days'))
 on conflict(key) do update set value=excluded.value;
update public.subscription_trial_config set enabled=true where singleton;
set local role service_role;
select public.provision_trial_card_budget_authority('per-user-fixture-authority',
 now()-interval '1 hour',now()+interval '120 days',repeat('1',64)) as authority \gset
select public.record_trial_card_provider_verification(:'authority',now()+interval '7 days 2 minutes',
 true,true,true,true,1000,1000,repeat('2',64),repeat('3',64),repeat('4',64)) is not null as verified \gset
select public.provision_trial_card_media_account_reserve(:'authority','per-user-fixture-card-reserve',
 (select starts_at from public.trial_card_budget_authorities where id=:'authority'),
 (select ends_at from public.trial_card_budget_authorities where id=:'authority'),
 10000,repeat('5',64),
 '{"r2_a_cents_per_million":450,"r2_b_cents_per_million":36,"worker_cents_per_million":30,"worker_cpu_cents_per_million_ms":2,"edge_cents_per_million":200,"db_cents":1500,"logs_cents":300,"storage_cents_per_gb_month":1.5}',
 '{"storage":300,"delivery":3096,"compute":3012,"email":100,"support":500,"retention":300,"uncertainty":500}') is not null as reserve_ok \gset
reset role;
-- The attestation is two days old, as it has been in production since 30 Oct.
update public.trial_card_provider_verifications
 set verified_at=verified_at-interval '2 days',valid_until=valid_until-interval '2 days';
update public.subscription_trial_media_template set enabled=true,
 account_reserve_ref='per-user-fixture-card-reserve',request_limit=10000,
 byte_limit=21474836480,storage_limit=2147483648,evidence_sha256=repeat('8',64) where singleton;
insert into public.serving_sponsor_pools(collection_ref,source,funded_cents,starts_at,ends_at,
 evidence_sha256,admissions_enabled,funding_basis,card_authority_id)
values('per-user-fixture-first100','trial',50000,now()-interval '1 hour',now()+interval '20 days',
 repeat('6',64),true,'card_backed_auto_refill',:'authority') returning id as pool \gset
insert into public.apple_serving_schedules(product_id,storefront,currency,price_milliunits,
 net_proceeds_floor_cents,service_months,starts_at,ends_at,reserve_components,trial_sponsored_cents,
 trial_reserve_components,trial_days,trial_pool_id,evidence_sha256)
values('com.rendprop.app.pro29.monthly','USA','USD',29990,2099,1,now()-interval '1 hour',now()+interval '20 days',
 '{"email":10,"compute":50,"storage":50,"support":50,"delivery":50,"retention":50,"uncertainty":50}',500,
 '{"email":5,"compute":25,"storage":14,"support":15,"delivery":25,"retention":6,"uncertainty":10}',7,:'pool',repeat('7',64));
select pg_temp.pu_user(n) from generate_series(1,8) n;

-- Dormant: with mode=pool the function still applies the first-100 rules.
set local role service_role;
select pg_temp.pu_refuses(format('select public.prepare_production_intro_trial_purchase(%L,%L,%L)',
 pg_temp.pu_actor(1),pg_temp.pu_org(1),'com.rendprop.app.pro29.monthly'),
 'RP402: Seven-day trial media coverage is unavailable',
 'pool mode: a stale supplier attestation still refuses a new subscriber');
select pg_temp.pu_refuses(format('select public.prepare_sandbox_intro_trial_purchase(%L,%L,%L)',
 pg_temp.pu_actor(2),pg_temp.pu_org(2),'com.rendprop.app.pro29.monthly'),
 'RP402: Test-trial sponsor allocation is closed or too short',
 'pool mode: an ended sponsor allocation still refuses a TestFlight trial');
reset role;

-- Activation, as 20261112223100 performs it.
insert into public.media_account_reserves(receipt_ref,account_id,cash_source,cash_evidence_sha256,
 starts_at,ends_at,cash_paid_cents,tariff,reserves,allocated_org_cents,card_authority_id,
 card_authorized_cents,card_evidence_sha256)
select 'per-user-fixture-standing',a.account_id,'per_user_allowance',null,date_trunc('day',now()),
 'infinity',0,a.tariff,a.reserves,0,null,0,repeat('9',64)
from public.media_account_reserves a where a.receipt_ref='per-user-fixture-card-reserve';
update public.subscription_trial_media_template set account_reserve_ref='per-user-fixture-standing' where singleton;
update public.subscription_trial_admission_policy set mode='per_user' where singleton;
select pg_temp.pu_refuses(
 $q$update public.media_account_reserves set cash_paid_cents=1 where receipt_ref='per-user-fixture-standing'$q$,
 'media_account_reserves_funding_basis_check','a standing record cannot claim paid cash');
select pg_temp.pu_refuses(
 $q$update public.media_account_reserves set ends_at='infinity' where receipt_ref='per-user-fixture-card-reserve'$q$,
 'media_account_reserves_check','only the per-user basis may have no end date');
-- An open unlimited internal QA hold: the thing that fails the legacy report.
insert into public.serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,
 input_sha256,tariff_version,hold_cents,sponsored_unlimited,state)
values(pg_temp.pu_org(8),pg_temp.pu_actor(8),'per-user-qa-open','photo.stage:0','gemini','fixture',
 repeat('a',64),'fixture',1,true,'reserved');
select pg_temp.pu_ok(not public.subscription_trial_private_authority_clear()
 and not public.trial_card_authority_active(:'authority')
 and (public.trial_sponsor_pool()->>'ends_at')::timestamptz<now(),
 'internal QA authority is open, supplier attestation is stale and the old allocation has ended');
select pg_temp.pu_ok((public.subscription_trial_per_user_readiness()->>'new_trials_admitted')='true',
 'per-user readiness: new trials are admitted');

-- App Store (Production) path.
set local role service_role;
select pg_temp.pu_ok((public.prepare_production_intro_trial_purchase(pg_temp.pu_actor(1),pg_temp.pu_org(1),
 'com.rendprop.app.pro29.monthly')#>>'{trial_offer,photo_edits}')='5',
 'a new confirmed owner is admitted with the configured five edits');
reset role;
select pg_temp.pu_ok((select pool_id is null and schedule_id is null and sponsored_cents=500
  and public.serving_reserve_total(reserve_components)=100 and photo_cap=5 and max_days=7
  and trial_media_account_ref='per-user-fixture-standing'
 from public.subscription_trial_purchase_reservations where actor_id=pg_temp.pu_actor(1)),
 'the hold names no pool, carries the per-user budget and the standing hosting record');
select pg_temp.pu_ok((select count(*)=0 from public.subscription_trial_purchase_reservations where pool_id=:'pool'),
 'nothing is drawn from the first-100 pool');
select pg_temp.pu_refuses(
 $q$update public.subscription_trial_purchase_reservations set schedule_id=(select id from public.apple_serving_schedules limit 1) where pool_id is null$q$,
 'subscription_trial_reservation_basis','a hold names a pool and a schedule together or neither');
set local role service_role;
select pg_temp.pu_ok((public.prepare_production_intro_trial_purchase(pg_temp.pu_actor(1),pg_temp.pu_org(1),
 'com.rendprop.app.pro29.monthly')->>'reservation_id')=
 (select id::text from public.subscription_trial_purchase_reservations where actor_id=pg_temp.pu_actor(1)),
 'asking again returns the same hold');
select pg_temp.pu_refuses(format('select public.prepare_production_intro_trial_purchase(%L,%L,%L)',
 pg_temp.pu_actor(1),pg_temp.pu_org(1),'com.rendprop.app.pro.monthly'),
 'RP409','one lifetime trial per account: another plan is refused');
select pg_temp.pu_refuses(format('select public.prepare_production_intro_trial_purchase(%L,%L,%L)',
 pg_temp.pu_actor(3),pg_temp.pu_org(3),'com.rendprop.app.pro.annual'),
 'RP402: An inclusive funded trial schedule is required','annual products carry no trial, as before');
select public.apply_apple_entitlement_v2(pg_temp.pu_org(1),pg_temp.pu_actor(1),
 'per-user-original-1','per-user-tx-1','com.rendprop.app.pro29.monthly','pro','Production','active',
 now()+interval '7 days',true,'SUBSCRIBED',now(),now(),now(),now());
select pg_temp.pu_refuses(format(
 'select public.serving_cost_reserve(%L,%L,''per-user-early'',''photo.stage:0'',''gemini'',''fixture'',repeat(''c'',64),1,''fixture'')',
 pg_temp.pu_actor(1),pg_temp.pu_org(1)),
 'RP402: Verified trial funding is unavailable','a signed intro spends nothing before its hold converts');
select pg_temp.pu_ok((public.fund_reserved_subscription_trial(pg_temp.pu_actor(1),pg_temp.pu_org(1),
 'per-user-original-1','per-user-tx-1','com.rendprop.app.pro29.monthly',0,'USD','USA',1,'FREE_TRIAL',
 now(),now()+interval '7 days',now(),repeat('d',64))->>'funded')='true',
 'the signed Apple free trial converts the per-user hold');
select pg_temp.pu_ok(public.serving_trial_funded_actor(pg_temp.pu_actor(1),pg_temp.pu_org(1)),
 'the converted trial is the funded actor (NULL pool on both sides)');
select pg_temp.pu_ok((public.subscription_serving_activation(pg_temp.pu_actor(1),pg_temp.pu_org(1))->>'authority')='funded_trial',
 'serving activation reports a funded trial');
select pg_temp.pu_ok((public.serving_cost_reserve(pg_temp.pu_actor(1),pg_temp.pu_org(1),'per-user-edit-'||n,
 'photo.stage:0','gemini','gemini-3.1-flash-image',repeat('c',64),11.7185,'fixture')->>'reserved')='true',
 'included photo edit '||n) from generate_series(1,5) n;
select pg_temp.pu_refuses(format(
 'select public.serving_cost_reserve(%L,%L,''per-user-edit-6'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',repeat(''c'',64),11.7185,''fixture'')',
 pg_temp.pu_actor(1),pg_temp.pu_org(1)),
 'RP402: The included trial photo edits are exhausted','the sixth edit is refused: the per-user cap holds');
select pg_temp.pu_ok((public.serving_cost_reserve(pg_temp.pu_actor(1),pg_temp.pu_org(1),'photo-qc:per-user-'||n,
 'photo.qc:0','anthropic','claude-sonnet-5',repeat('b',64),9.8694,'fixture')->>'reserved')='true',
 'advisory quality check '||n||' of an included edit is admitted') from generate_series(1,5) n;
select pg_temp.pu_refuses(format(
 'select public.serving_cost_reserve(%L,%L,''photo-qc:per-user-6'',''photo.qc:0'',''anthropic'',''claude-sonnet-5'',repeat(''b'',64),9.8694,''fixture'')',
 pg_temp.pu_actor(1),pg_temp.pu_org(1)),
 'RP402: The included trial photo checks are exhausted','quality checks are bounded by the edit allowance');
select pg_temp.pu_refuses(format(
 'select public.serving_cost_reserve(%L,%L,''per-user-helper'',''photo.improve_prompt'',''gemini'',''fixture'',repeat(''c'',64),1,''fixture'')',
 pg_temp.pu_actor(1),pg_temp.pu_org(1)),
 'not included in the bounded subscription trial','prompt helpers stay outside the trial');
select pg_temp.pu_refuses(format(
 'select public.serving_cost_reserve(%L,%L,''per-user-video'',''video.property_reel_clip_kie'',''kie'',''kling-3.0/video'',repeat(''c'',64),167.5,''fixture'')',
 pg_temp.pu_actor(1),pg_temp.pu_org(1)),
 'RP402: This generation feature is not included in the subscription trial','AI video stays outside the trial');
select pg_temp.pu_ok((public.media_delivery_admit(pg_temp.pu_org(1),1000,true)->>'admitted')='true',
 'the trial workspace has its bounded hosting budget');
reset role;
select pg_temp.pu_ok((select f.sponsored_cents=500 and f.recurring_reserve_cents=100 and f.sponsor_pool_id is null
  and sl.total_budget_cents-sl.recurring_reserve_cents=400
 from public.serving_funding f join public.serving_funding_slices sl on sl.funding_id=f.id
 where f.org_id=pg_temp.pu_org(1) and f.source='trial'),
 'money rows: USD 5.00 per user, USD 1.00 reserved, USD 4.00 of AI at most');
select pg_temp.pu_ok((select count(*)=10 and sum(hold_cents)=107.9395
 from public.serving_cost_reservations where org_id=pg_temp.pu_org(1) and state<>'rejected'),
 'every attempt is journaled: five edits and five checks, 107.94 cents held');

-- A second user with a larger remaining budget proves the dollar bound.
set local role service_role;
select public.prepare_production_intro_trial_purchase(pg_temp.pu_actor(4),pg_temp.pu_org(4),'com.rendprop.app.pro29.monthly') is not null;
select public.apply_apple_entitlement_v2(pg_temp.pu_org(4),pg_temp.pu_actor(4),
 'per-user-original-4','per-user-tx-4','com.rendprop.app.pro29.monthly','pro','Production','active',
 now()+interval '7 days',true,'SUBSCRIBED',now(),now(),now(),now());
select public.fund_reserved_subscription_trial(pg_temp.pu_actor(4),pg_temp.pu_org(4),
 'per-user-original-4','per-user-tx-4','com.rendprop.app.pro29.monthly',0,'USD','USA',1,'FREE_TRIAL',
 now(),now()+interval '7 days',now(),repeat('d',64)) is not null;
select pg_temp.pu_ok((public.serving_cost_reserve(pg_temp.pu_actor(4),pg_temp.pu_org(4),'per-user-big-1',
 'photo.custom:0','gemini','fixture',repeat('c',64),399,'fixture')->>'reserved')='true',
 'one user may hold up to the per-user AI budget');
select pg_temp.pu_refuses(format(
 'select public.serving_cost_reserve(%L,%L,''per-user-big-2'',''photo.custom:0'',''gemini'',''fixture'',repeat(''c'',64),1.5,''fixture'')',
 pg_temp.pu_actor(4),pg_temp.pu_org(4)),
 'RP402: This attempt exceeds the shared funded serving allowance','and not one cent past it');

-- Volume: far more than the old head count.
reset role;
select pg_temp.pu_user(n) from generate_series(100,249) n;
set local role service_role;
select pg_temp.pu_ok(count(*)=150,'150 further new subscribers are all admitted (the old cap was 100)') from (
 select public.prepare_production_intro_trial_purchase(pg_temp.pu_actor(n),pg_temp.pu_org(n),
  'com.rendprop.app.pro29.monthly') from generate_series(100,249) n) admitted;

-- TestFlight (Sandbox) path.
select pg_temp.pu_ok(public.prepare_sandbox_intro_trial_purchase(pg_temp.pu_actor(2),pg_temp.pu_org(2),
 'com.rendprop.app.pro29.monthly') is not null,'TestFlight preflight passes with the old allocation ended');
select pg_temp.pu_ok((public.grant_sandbox_intro_trial(pg_temp.pu_org(2),pg_temp.pu_actor(2),'per-user-sbx-2',
 'per-user-sbx-tx-2','com.rendprop.app.pro29.monthly','active',now()+interval '3 minutes',now(),now(),0,
 'USD','USA',1,'FREE_TRIAL',pg_temp.pu_actor(2),'Auto-Renewable Subscription')->>'granted')='true',
 'the signed Sandbox free trial is granted');
select pg_temp.pu_ok((public.serving_cost_reserve(pg_temp.pu_actor(2),pg_temp.pu_org(2),'per-user-sbx-edit',
 'photo.stage:0','gemini','gemini-3.1-flash-image',repeat('c',64),11.7185,'fixture')->>'kind')='trial',
 'its AI edit is admitted with no shared allocation');
select pg_temp.pu_ok((e->>'kind')='trial' and (e#>>'{pool,cap_cents}')::numeric=500
 and (e#>>'{pool,spent_cents}')::numeric=11.72 and (e#>>'{pool,starts_at}')::timestamptz<=now()
 and (e#>>'{pool,ends_at}')::timestamptz=(e->>'period_end')::timestamptz
 and (e#>>'{pool,ends_at}')::timestamptz>now()+interval '6 days',
 'the apps are shown this workspace''s own allowance and trial end, not the ended shared allocation: '||e::text)
from (select public.serving_envelope_state(pg_temp.pu_org(2)) e) shown;
select pg_temp.pu_ok((public.grant_sandbox_intro_trial(pg_temp.pu_org(2),pg_temp.pu_actor(2),'per-user-sbx-2',
 'per-user-sbx-tx-2','com.rendprop.app.pro29.monthly','active',now()+interval '3 minutes',now(),now(),0,
 'USD','USA',1,'FREE_TRIAL',pg_temp.pu_actor(2),'Auto-Renewable Subscription')->>'reason')='already_granted',
 'replaying the same Apple transaction changes nothing');
select pg_temp.pu_refuses(format($q$select public.grant_sandbox_intro_trial(%L,%L,'per-user-sbx-2b','per-user-sbx-tx-2b','com.rendprop.app.pro29.monthly','active',now()+interval '3 minutes',now(),now(),0,'USD','USA',1,'FREE_TRIAL',%L,'Auto-Renewable Subscription')$q$,
 pg_temp.pu_org(2),pg_temp.pu_actor(2),pg_temp.pu_actor(2)),
 'RP409: This account has already used its free trial','a second test trial on the same account is refused');
select pg_temp.pu_refuses(format('select public.prepare_sandbox_intro_trial_purchase(%L,%L,%L)',
 pg_temp.pu_actor(2),pg_temp.pu_org(2),'com.rendprop.app.pro29.monthly'),
 'RP409','and refused before the Apple sheet');
select pg_temp.pu_ok((public.serving_cost_reserve(pg_temp.pu_actor(2),pg_temp.pu_org(2),'per-user-sbx-big',
 'photo.stage:0','gemini','gemini-3.1-flash-image',repeat('c',64),480,'fixture')->>'reserved')='true',
 'a test trial may use its own 500-cent ceiling');
select pg_temp.pu_refuses(format(
 'select public.serving_cost_reserve(%L,%L,''per-user-sbx-over'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',repeat(''c'',64),10,''fixture'')',
 pg_temp.pu_actor(2),pg_temp.pu_org(2)),
 'RP402: AI usage limit reached [kind=trial]','and is refused past it: the per-user ceiling is the bound');
reset role;

-- Reporting and owner alerts. Holds are back-dated one minute because every
-- row in this transaction otherwise shares now().
alter table public.serving_cost_reservations disable trigger user;
update public.serving_cost_reservations set created_at=created_at-interval '1 minute'
 where request_key like 'per-user-%' or request_key like 'photo-qc:per-user-%';
alter table public.serving_cost_reservations enable trigger user;
select pg_temp.pu_ok((s->>'app_store_cents')::numeric=506.9395 and (s->>'test_cents')::numeric=491.7185
 and (s->>'workspaces')::integer=3 and (s->>'attempts')::integer=13,
 'spend summary separates App Store and TestFlight trials and ignores the unlimited QA hold: '||s::text)
from (select public.trial_spend_summary(now()-interval '1 hour',now()) s) summary;
select pg_temp.pu_ok(not exists(select 1 from public.ops_health_findings() where code like 'trial_pool%' or code='trial_sponsor_near_cap'),
 'no pool notice is raised in per-user mode');
update public.subscription_trial_admission_policy set alert_thresholds_cents=array[500,900,100000]::bigint[];
select pg_temp.pu_ok((select count(*)=1 and bool_and(code like 'trial_spend:%:900' and body like '%Nobody is blocked%'
  and body like '%Next alert at 1000.00 USD%') from public.ops_health_findings() where code like 'trial_spend:%'),
 'crossing a level raises one owner alert for the highest level crossed');
update public.subscription_trial_admission_policy set alert_thresholds_cents=array[400]::bigint[];
select pg_temp.pu_ok((select count(*)=1 and bool_and(code like 'trial_spend:%:800') from public.trial_spend_alerts()),
 'past the last listed level, every further multiple alerts');
update public.subscription_trial_config set enabled=false where singleton;
select pg_temp.pu_ok(exists(select 1 from public.ops_health_findings() where code='trial_admission_blocked'),
 'a switched-off trial is reported as a configuration fault');
set local role service_role;
select pg_temp.pu_refuses(format('select public.prepare_production_intro_trial_purchase(%L,%L,%L)',
 pg_temp.pu_actor(5),pg_temp.pu_org(5),'com.rendprop.app.pro29.monthly'),
 'RP402: The funded subscription trial is not activated','the one switch still stops new trials');
reset role;

-- The allowance is one row.
update public.subscription_trial_config set enabled=true,photo_edits=10 where singleton;
set local role service_role;
select pg_temp.pu_ok((public.prepare_production_intro_trial_purchase(pg_temp.pu_actor(5),pg_temp.pu_org(5),
 'com.rendprop.app.pro29.monthly')#>>'{trial_offer,photo_edits}')='10',
 'changing subscription_trial_config.photo_edits changes the next user''s allowance');
select pg_temp.pu_ok((public.subscription_trial_context(pg_temp.pu_actor(1),pg_temp.pu_org(1))#>>'{trial_usage,photo_edits,cap}')='5',
 'a trial already running keeps the allowance it was promised');
reset role;

-- Rollback: one row restores the pool rules; admitted users keep their trial.
update public.subscription_trial_admission_policy set mode='pool' where singleton;
set local role service_role;
select pg_temp.pu_refuses(format('select public.prepare_production_intro_trial_purchase(%L,%L,%L)',
 pg_temp.pu_actor(6),pg_temp.pu_org(6),'com.rendprop.app.pro29.monthly'),
 'RP402','rollback: a new subscriber is refused again by the pool rules');
select pg_temp.pu_ok(public.serving_trial_funded_actor(pg_temp.pu_actor(1),pg_temp.pu_org(1)),
 'rollback: an already converted per-user trial is still served');
select pg_temp.pu_ok((public.serving_envelope_state(pg_temp.pu_org(2))#>>'{pool,cap_cents}')::numeric=29000,
 'rollback: the apps are shown the shared allocation again');
select pg_temp.pu_refuses(format(
 'select public.serving_cost_reserve(%L,%L,''per-user-sbx-after'',''photo.stage:0'',''gemini'',''gemini-3.1-flash-image'',repeat(''c'',64),1,''fixture'')',
 pg_temp.pu_actor(2),pg_temp.pu_org(2)),
 'RP402: Free-trial AI limit reached [pool=closed]','rollback: the shared allocation refuses test trials again');
reset role;

select jsonb_build_object('passed',true,'assertions',n,'scope','rolled-back local synthetic PostgreSQL')
 from per_user_case;
rollback;
