\set ON_ERROR_STOP on
begin;
\ir trial_media_fixture.sql
create temporary table hybrid_checks(n integer not null default 0);
insert into hybrid_checks default values;
grant all on hybrid_checks to service_role;
create function pg_temp.hybrid_ok(v boolean,label text) returns void language plpgsql as $$
begin if v is distinct from true then raise exception 'HYBRID FAIL: %',label;end if;
 update hybrid_checks set n=n+1;end$$;
create function pg_temp.hybrid_refuses(q text,needle text,label text) returns void language plpgsql as $$
begin begin execute q;exception when others then
 if position(needle in sqlerrm)>0 then perform pg_temp.hybrid_ok(true,label);return;end if;
 raise;end;raise exception 'HYBRID FAIL admitted: %',label;end$$;

select pg_temp.hybrid_ok(not enabled,'migration leaves public trial disabled')
 from public.subscription_trial_config where singleton;
select pg_temp.hybrid_ok(not has_function_privilege('authenticated',
 'public.serving_trial_funded_actor(uuid,uuid)','EXECUTE'),
 'per-actor funding status is service-only');
select pg_temp.hybrid_ok(not has_function_privilege('authenticated',
 'public.subscription_trial_private_authority_clear()','EXECUTE'),
 'private launch authority audit remains service-only');
update public.app_config set value=jsonb_build_object('mode','ceiling','free_published_listings',1)
 where key='serving_mode';
update public.app_config set value=jsonb_build_object('cap_cents',1,
 'starts_at',now()-interval '1 day','ends_at',now()-interval '1 hour')
 where key='trial_sponsor_pool';
update public.subscription_trial_config set enabled=true;
insert into auth.users(id,email,is_anonymous,email_confirmed_at) values
 ('e4100000-0000-4000-8000-000000000001','hybrid-trial@example.invalid',false,now()),
 ('e4100000-0000-4000-8000-000000000002','hybrid-manual@example.invalid',false,now()),
 ('e4100000-0000-4000-8000-000000000003','hybrid-unheld@example.invalid',false,now());
insert into public.orgs(id,name,plan,plan_source) values
 ('e4200000-0000-4000-8000-000000000001','Hybrid trial fixture','free',null),
 ('e4200000-0000-4000-8000-000000000002','Hybrid manual fixture','pro','manual'),
 ('e4200000-0000-4000-8000-000000000003','Hybrid unheld fixture','free',null),
 ('e4200000-0000-4000-8000-000000000004','Hybrid QA fixture','team','manual');
insert into public.memberships(user_id,org_id,role) values
 ('e4100000-0000-4000-8000-000000000001','e4200000-0000-4000-8000-000000000001','owner'),
 ('e4100000-0000-4000-8000-000000000002','e4200000-0000-4000-8000-000000000002','owner'),
 ('e4100000-0000-4000-8000-000000000003','e4200000-0000-4000-8000-000000000003','owner'),
 ('e4100000-0000-4000-8000-000000000002','e4200000-0000-4000-8000-000000000004','owner');
-- Model an existing saved draft independently of the new listing gate.
alter table public.listings disable trigger trial_intro_listing_admission;
insert into public.listings(id,org_id,agent_id,address) values
 ('e4300000-0000-4000-8000-000000000003',
  'e4200000-0000-4000-8000-000000000003',
  'e4100000-0000-4000-8000-000000000003','Saved pre-intro draft');
alter table public.listings enable trigger trial_intro_listing_admission;
update public.profiles set is_admin=true
 where id='e4100000-0000-4000-8000-000000000002';
insert into public.org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)
 values('e4200000-0000-4000-8000-000000000004',
 'e4100000-0000-4000-8000-000000000002',true);
insert into public.serving_sponsor_pools(
 collection_ref,source,funded_cents,starts_at,ends_at,evidence_sha256,admissions_enabled)
values('synthetic-hybrid-cash','trial',500,now()-interval '1 day',
 now()+interval '20 days',repeat('a',64),true);
insert into public.apple_serving_schedules(
 product_id,storefront,currency,price_milliunits,net_proceeds_floor_cents,
 service_months,starts_at,ends_at,reserve_components,trial_sponsored_cents,
 trial_reserve_components,trial_days,trial_pool_id,evidence_sha256)
select 'com.rendprop.app.pro29.monthly','USA','USD',29990,2549,1,
 now()-interval '1 day',now()+interval '20 days',
 '{"storage":1,"delivery":1,"compute":1,"email":1,"support":1,"retention":1,"uncertainty":1}',
 500,'{"storage":8,"delivery":3,"compute":4,"email":5,"support":6,"retention":8,"uncertainty":8}',
 7,id,repeat('b',64) from public.serving_sponsor_pools
 where collection_ref='synthetic-hybrid-cash';

set local role service_role;
select pg_temp.hybrid_ok(not public.serving_trial_funded_actor(
 'e4100000-0000-4000-8000-000000000001',
 'e4200000-0000-4000-8000-000000000001'),
 'a cash hold alone does not authorize funded serving');
reset role;
update public.subscription_trial_media_template set enabled=false where singleton;
set local role service_role;
select pg_temp.hybrid_refuses(
 'select public.prepare_subscription_trial_purchase(''e4100000-0000-4000-8000-000000000001'',''e4200000-0000-4000-8000-000000000001'',''com.rendprop.app.pro29.monthly'')',
 'RP402: Seven-day trial media coverage is unavailable',
 'missing media template refuses without a sponsor hold');
reset role;
update public.subscription_trial_media_template set enabled=true where singleton;
update public.app_config set value=jsonb_build_object('cap_cents',29001,
 'starts_at',now()-interval '1 day','ends_at',now()+interval '20 days')
 where key='trial_sponsor_pool';
set local role service_role;
select pg_temp.hybrid_refuses(
 'select public.prepare_subscription_trial_purchase(''e4100000-0000-4000-8000-000000000001'',''e4200000-0000-4000-8000-000000000001'',''com.rendprop.app.pro29.monthly'')',
 'RP402: Seven-day trial media coverage is unavailable',
 'overlapping shared media and legacy cap above 500 dollars refuses before StoreKit');
select pg_temp.hybrid_ok(not exists(select 1 from public.subscription_trial_purchase_reservations
 where org_id='e4200000-0000-4000-8000-000000000001'),
 'shared-cost overlap refusal leaves no partial sponsor hold');
select pg_temp.hybrid_ok(not public.subscription_trial_private_authority_clear(),
 'active unbounded QA grant closes launch readiness without revoking QA');
reset role;
update public.app_config set value=jsonb_build_object('cap_cents',1,
 'starts_at',now()-interval '1 day','ends_at',now()-interval '1 hour')
 where key='trial_sponsor_pool';
update public.media_account_reserves set ends_at=now()+interval '50 days'
 where receipt_ref='synthetic-trial-media-account';
set local role service_role;
select pg_temp.hybrid_refuses(
 'select public.prepare_subscription_trial_purchase(''e4100000-0000-4000-8000-000000000001'',''e4200000-0000-4000-8000-000000000001'',''com.rendprop.app.pro29.monthly'')',
 'RP402: Seven-day trial media coverage is unavailable',
 'expired account coverage refuses before StoreKit');
select pg_temp.hybrid_ok(not exists(select 1 from public.subscription_trial_purchase_reservations
 where org_id='e4200000-0000-4000-8000-000000000001'),
 'missing media coverage leaves no partial cash hold');
reset role;
update public.media_account_reserves set ends_at=now()+interval '130 days'
 where receipt_ref='synthetic-trial-media-account';
set local role service_role;
select pg_temp.hybrid_ok((public.prepare_subscription_trial_purchase(
 'e4100000-0000-4000-8000-000000000001',
 'e4200000-0000-4000-8000-000000000001',
 'com.rendprop.app.pro29.monthly')#>>'{trial_offer,max_days}')='7',
 'ceiling-mode purchase still reserves exact seven-day cash');
select public.apply_apple_entitlement_v2(
 'e4200000-0000-4000-8000-000000000001',
 'e4100000-0000-4000-8000-000000000001',
 'hybrid-trial-original','hybrid-trial-tx','com.rendprop.app.pro29.monthly',
 'pro','Production','active',now()+interval '7 days',true,'SUBSCRIBED',
 now(),now(),now(),now());
select pg_temp.hybrid_ok((public.subscription_serving_activation(
 'e4100000-0000-4000-8000-000000000001',
 'e4200000-0000-4000-8000-000000000001')->>'available')::boolean=false,
 'signed unconverted intro does not advertise serving authority');
select pg_temp.hybrid_refuses(
 'select public.serving_cost_reserve(''e4100000-0000-4000-8000-000000000001'',''e4200000-0000-4000-8000-000000000001'',''hybrid-before-001'',''photo.custom:0'',''gemini'',''fixture'',repeat(''c'',64),1,''fixture'')',
 'RP402: Verified trial funding is unavailable',
 'signed intro before cash conversion cannot use legacy ceiling');
select pg_temp.hybrid_ok((public.fund_reserved_subscription_trial(
 'e4100000-0000-4000-8000-000000000001',
 'e4200000-0000-4000-8000-000000000001',
 'hybrid-trial-original','hybrid-trial-tx','com.rendprop.app.pro29.monthly',
 0,'USD','USA',1,'FREE_TRIAL',now(),now()+interval '7 days',now(),repeat('d',64))->>'funded')='true',
 'signed exact held receipt converts to one funded slice');
select pg_temp.hybrid_ok((select (public.trial_sponsor_pool()->>'ends_at')::timestamptz<now()),
 'converted trial never depended on expired legacy runtime window');
select pg_temp.hybrid_ok(public.serving_trial_funded_actor(
 'e4100000-0000-4000-8000-000000000001',
 'e4200000-0000-4000-8000-000000000001'),
 'only converted Production trial actor uses hybrid funded path');
select pg_temp.hybrid_ok(
 public.subscription_serving_activation(
 'e4100000-0000-4000-8000-000000000001',
 'e4200000-0000-4000-8000-000000000001')->>'authority'='funded_trial',
 'serving status reports the exact funded trial');
select pg_temp.hybrid_ok(
 (public.subscription_trial_context('e4100000-0000-4000-8000-000000000001',
  'e4200000-0000-4000-8000-000000000001')#>>'{trial_usage,photo_edits,cap}')='5'
 and (public.subscription_trial_context('e4100000-0000-4000-8000-000000000001',
  'e4200000-0000-4000-8000-000000000001')#>>'{trial_usage,walkthroughs,cap}')='0',
 'funded intro exposes photo-only lifetime usage despite global ceiling');
select set_config('request.jwt.claim.sub','e4100000-0000-4000-8000-000000000001',true);
insert into public.listings(id,org_id,agent_id,address) values
 ('e4300000-0000-4000-8000-000000000001',
  'e4200000-0000-4000-8000-000000000001',
  'e4100000-0000-4000-8000-000000000001','Funded trial draft');
select pg_temp.hybrid_refuses(
 'insert into public.listings(id,org_id,agent_id,address) values(''e4300000-0000-4000-8000-000000000002'',''e4200000-0000-4000-8000-000000000001'',''e4100000-0000-4000-8000-000000000001'',''Second funded draft'')',
 'RP402: Unpaid access includes one listing',
 'funded trial creates only one draft without the unrelated runtime ceiling');
select pg_temp.hybrid_refuses(
 'insert into public.render_jobs(listing_id,source) values(''e4300000-0000-4000-8000-000000000001'',''app'')',
 'RP402: Video and public website creation start after payment',
 'funded trial cannot publish a hosted walkthrough');
select pg_temp.hybrid_ok(jsonb_array_length(public.reserve_upload_assets(
 'e4100000-0000-4000-8000-000000000001',jsonb_build_array(jsonb_build_object(
 'id','e4400000-0000-4000-8000-000000000001','listing_id','e4300000-0000-4000-8000-000000000001',
 'kind','photo','bucket','renders','storage_key','renders/e4200000-0000-4000-8000-000000000001/e4300000-0000-4000-8000-000000000001/gallery-e4400000-0000-4000-8000-000000000001.jpg',
 'bytes',1024,'content_type','image/jpeg','content_type_declared',true,'idem_key','hybrid-funded-photo'))))=1,
 'converted trial can upload its saved draft photos');
select pg_temp.hybrid_ok((select funding_id is not null and request_limit=1000
 and storage_limit=1342177280 and used_requests=0 from public.media_delivery_budgets
 where org_id='e4200000-0000-4000-8000-000000000001'),
 'signed conversion atomically creates one finite photo media budget');
select pg_temp.hybrid_ok((public.media_storage_reserve(
 'e4200000-0000-4000-8000-000000000001','uploads',
 'uploads/e4200000-0000-4000-8000-000000000001/e4300000-0000-4000-8000-000000000001/photo.jpg',1024)->>'reserved')='true',
 'converted trial photo storage reserves finite retained bytes');
select pg_temp.hybrid_ok((public.media_delivery_admit(
 'e4200000-0000-4000-8000-000000000001',1024,true)->>'admitted')='true',
 'converted trial photo read consumes its finite media budget');
reset role;
update public.media_delivery_budgets set used_requests=request_limit
 where org_id='e4200000-0000-4000-8000-000000000001';
set local role service_role;
select pg_temp.hybrid_refuses(
 'select public.media_delivery_admit(''e4200000-0000-4000-8000-000000000001'',1,true)',
 'RP429: Media serving allowance exhausted',
 'trial read request limit stops product delivery');
select pg_temp.hybrid_ok((select used_requests=1 and used_bytes=1024
 from public.media_serving_usage where org_id='e4200000-0000-4000-8000-000000000001'
 and usage_day=(now() at time zone 'UTC')::date),
 'refused trial read creates no unpriced product usage');
reset role;
update public.media_delivery_budgets set used_requests=2,used_bytes=byte_limit-1
 where org_id='e4200000-0000-4000-8000-000000000001';
set local role service_role;
select pg_temp.hybrid_refuses(
 'select public.media_delivery_admit(''e4200000-0000-4000-8000-000000000001'',2,true)',
 'RP429: Media serving allowance exhausted',
 'trial read byte limit stops product delivery');
select pg_temp.hybrid_ok((select used_requests=1 and used_bytes=1024
 from public.media_serving_usage where org_id='e4200000-0000-4000-8000-000000000001'
 and usage_day=(now() at time zone 'UTC')::date),
 'refused byte overdraw creates no partial usage');
reset role;
update public.media_delivery_budgets set used_requests=2,used_bytes=1024
 where org_id='e4200000-0000-4000-8000-000000000001';
set local role service_role;
select pg_temp.hybrid_ok((public.serving_cost_reserve(
 'e4100000-0000-4000-8000-000000000001',
 'e4200000-0000-4000-8000-000000000001','hybrid-funded-001',
 'photo.custom:0','gemini','fixture',repeat('c',64),458,'fixture')->>'reserved')='true',
 'trial provider attempt admits up to 500 minus seven media-inclusive reserves');
select pg_temp.hybrid_ok((select funding_id is not null and budget_source is distinct from 'ceiling'
 from public.serving_cost_reservations where request_key='hybrid-funded-001'),
 'trial hold is charged to its funded slice, not the shared ceiling');
select pg_temp.hybrid_refuses(
 'select public.serving_cost_reserve(''e4100000-0000-4000-8000-000000000001'',''e4200000-0000-4000-8000-000000000001'',''hybrid-over-001'',''photo.custom:1'',''gemini'',''fixture'',repeat(''c'',64),0.0001,''fixture'')',
 'RP402: This attempt exceeds the shared funded serving allowance',
 'one ten-thousandth cent above net slice refuses before dispatch');
select pg_temp.hybrid_ok((select count(*)=1 from public.serving_cost_reservations
 where org_id='e4200000-0000-4000-8000-000000000001'),
 'rejected overdraw leaves no second trial hold');

select public.apply_apple_entitlement_v2(
 'e4200000-0000-4000-8000-000000000003',
 'e4100000-0000-4000-8000-000000000003',
 'hybrid-unheld-original','hybrid-unheld-tx','com.rendprop.app.pro29.monthly',
 'pro','Production','active',now()+interval '7 days',true,'SUBSCRIBED',
 now(),now(),now(),now());
select pg_temp.hybrid_ok((public.subscription_serving_activation(
 'e4100000-0000-4000-8000-000000000003',
 'e4200000-0000-4000-8000-000000000003')->>'available')::boolean=false,
 'old-client unheld intro does not advertise ceiling authority');
select set_config('request.jwt.claim.sub','e4100000-0000-4000-8000-000000000003',true);
select pg_temp.hybrid_refuses(
 'insert into public.listings(id,org_id,agent_id,address) values(''e4300000-0000-4000-8000-000000000004'',''e4200000-0000-4000-8000-000000000003'',''e4100000-0000-4000-8000-000000000003'',''Unheld intro draft'')',
 'RP402: Verified trial funding is unavailable',
 'old-client unheld intro cannot create a new draft or consume a slot');
select pg_temp.hybrid_refuses(
 'select public.reserve_upload_assets(''e4100000-0000-4000-8000-000000000003'',''[{"id":"e4400000-0000-4000-8000-000000000003","listing_id":"e4300000-0000-4000-8000-000000000003","kind":"photo","bucket":"renders","storage_key":"renders/e4200000-0000-4000-8000-000000000003/e4300000-0000-4000-8000-000000000003/gallery-e4400000-0000-4000-8000-000000000003.jpg","bytes":1024,"content_type":"image/jpeg","content_type_declared":true,"idem_key":"hybrid-unheld-photo"}]''::jsonb)',
 'RP402: Verified trial funding is unavailable',
 'old-client unheld intro cannot reserve photo storage on a saved draft');
select pg_temp.hybrid_ok(not exists(select 1 from public.upload_reservations
 where asset_id='e4400000-0000-4000-8000-000000000003'),
 'denied old-client upload leaves no transport hold');
select pg_temp.hybrid_refuses(
 'select public.serving_cost_reserve(''e4100000-0000-4000-8000-000000000003'',''e4200000-0000-4000-8000-000000000003'',''hybrid-unheld-001'',''photo.custom:0'',''gemini'',''fixture'',repeat(''c'',64),1,''fixture'')',
 'RP402: Verified trial funding is unavailable',
 'old-client unheld Production intro cannot dispatch against ceiling');
select pg_temp.hybrid_ok((public.serving_cost_reserve(
 'e4100000-0000-4000-8000-000000000002',
 'e4200000-0000-4000-8000-000000000002','hybrid-manual-001',
 'photo.custom:0','gemini','fixture',repeat('c',64),1,'fixture')->>'budget')='ceiling',
 'manual paid 1.0.4 workspace stays on its ceiling path');
select pg_temp.hybrid_ok((select funding_id is null and budget_source='ceiling'
 from public.serving_cost_reservations where request_key='hybrid-manual-001'),
 'manual hold never consumes trial funded cash');
select pg_temp.hybrid_ok((public.serving_cost_reserve(
 'e4100000-0000-4000-8000-000000000002',
 'e4200000-0000-4000-8000-000000000004','hybrid-qa-001',
 'photo.custom:0','gemini','fixture',repeat('c',64),1,
 'unpriced-private-sponsorship')->>'sponsored_unlimited')::boolean,
 'existing manual Team internal QA remains explicitly sponsored');
reset role;
update public.serving_funding set revoked_at=now(),revocation_kind='operator'
 where collection_ref='apple-trial:hybrid-trial-original';
set local role service_role;
select pg_temp.hybrid_refuses(
 'select public.serving_cost_reserve(''e4100000-0000-4000-8000-000000000001'',''e4200000-0000-4000-8000-000000000001'',''hybrid-revoked-001'',''photo.custom:1'',''gemini'',''fixture'',repeat(''c'',64),1,''fixture'')',
 'RP402: Verified trial funding is unavailable',
 'revoked trial cannot fall back to legacy ceiling');
select pg_temp.hybrid_ok((select count(*)=0 from public.serving_cost_reservations
 where request_key in('hybrid-before-001','hybrid-over-001','hybrid-unheld-001','hybrid-revoked-001')),
 'all denied operations leave no supplier hold');
reset role;
select jsonb_build_object('passed',true,'assertions',(select n from hybrid_checks));
rollback;
