\set ON_ERROR_STOP on
begin;
create temporary table card_trial_case(
 authority_id uuid,pool_id uuid,schedule_id uuid,actor_id uuid,org_id uuid,
 second_actor uuid,second_org uuid,n integer not null default 0
);
grant all on card_trial_case to service_role;
insert into card_trial_case(actor_id,org_id,second_actor,second_org)
 values('ed100000-0000-4000-8000-000000000001','ed200000-0000-4000-8000-000000000001',
        'ed100000-0000-4000-8000-000000000002','ed200000-0000-4000-8000-000000000002');
create function pg_temp.card_ok(v boolean,label text) returns void language plpgsql as $$
begin
 if v is distinct from true then raise exception 'CARD TRIAL FAIL: %',label;end if;
 update card_trial_case set n=n+1;
end$$;
create function pg_temp.card_refuses(q text,needle text,label text) returns void language plpgsql as $$
begin
 begin execute q;exception when others then
  if position(needle in sqlerrm)>0 then perform pg_temp.card_ok(true,label);return;end if;
  raise;
 end;
 raise exception 'CARD TRIAL FAIL admitted: %',label;
end$$;

select pg_temp.card_ok(not has_table_privilege('authenticated',
 'public.trial_card_budget_authorities','SELECT'),
 'card authorization is not client-readable');
select pg_temp.card_ok(not has_function_privilege('authenticated',
 'public.provision_trial_card_budget_authority(text,timestamptz,timestamptz,text)','EXECUTE'),
 'card provisioning is service-only');
select pg_temp.card_ok(not has_function_privilege('authenticated',
 'public.record_trial_card_provider_verification(uuid,timestamptz,boolean,boolean,boolean,boolean,integer,integer,text,text,text)','EXECUTE'),
 'provider verification is service-only');
select pg_temp.card_ok((select not enabled from public.subscription_trial_config where singleton),
 'migration does not enable public trial');
select pg_temp.card_ok(not exists(select 1 from public.trial_card_budget_authorities),
 'migration creates no card authority or evidence');

set local role service_role;
update card_trial_case set authority_id=public.provision_trial_card_budget_authority(
 'local-card-backed-cohort',now()-interval '1 hour',now()+interval '120 days',repeat('1',64));
select pg_temp.card_ok(not public.trial_card_authority_active(authority_id),
 'saved card without provider verification is not funded authority') from card_trial_case;
select pg_temp.card_refuses(format(
 'select public.record_trial_card_provider_verification(%L,now()+interval ''7 days 2 minutes'',false,true,true,true,1000,1000,%L,%L,%L)',
 (select authority_id from card_trial_case),repeat('2',64),repeat('3',64),repeat('4',64)),
 'RP402','disabled Kie refill refuses verification');
select public.record_trial_card_provider_verification(authority_id,
 now()+interval '7 days 2 minutes',true,true,true,true,1000,1000,
 repeat('2',64),repeat('3',64),repeat('4',64)) from card_trial_case;
select pg_temp.card_ok(public.trial_card_authority_active(authority_id),
 'current Kie/FAL/card evidence activates only the bounded authority') from card_trial_case;
select public.provision_trial_card_media_account_reserve(
 authority_id,'local-card-media-reserve',
 (select starts_at from public.trial_card_budget_authorities where id=authority_id),
 (select ends_at from public.trial_card_budget_authorities where id=authority_id),
 50000,repeat('5',64),
 '{"r2_a_cents_per_million":450,"r2_b_cents_per_million":36,"worker_cents_per_million":30,"worker_cpu_cents_per_million_ms":2,"edge_cents_per_million":200,"db_cents":100,"logs_cents":100,"storage_cents_per_gb_month":1.5}',
 '{"storage":0,"delivery":5000,"compute":5000,"email":0,"support":0,"retention":0,"uncertainty":0}')
 from card_trial_case;
select pg_temp.card_ok(cash_paid_cents=0 and cash_evidence_sha256 is null
 and card_authorized_cents=50000 and cash_source='card_backed_auto_refill',
 'card authorization records zero paid cash, separate maximum liability')
 from public.media_account_reserves where receipt_ref='local-card-media-reserve';
reset role;
select pg_temp.card_refuses(
 'update public.media_account_reserves set cash_paid_cents=1 where receipt_ref=''local-card-media-reserve''',
 'media_account_reserves_funding_basis_check',
 'card-backed row cannot fabricate a paid-cash amount');

insert into public.serving_sponsor_pools(collection_ref,source,funded_cents,
 starts_at,ends_at,evidence_sha256,admissions_enabled,funding_basis,card_authority_id)
select 'local-card-trial-pool','trial',50000,now()-interval '1 hour',now()+interval '20 days',
 repeat('6',64),true,'card_backed_auto_refill',authority_id from card_trial_case
returning id \gset
update card_trial_case set pool_id=:'id';
insert into public.apple_serving_schedules(
 product_id,storefront,currency,price_milliunits,net_proceeds_floor_cents,
 service_months,starts_at,ends_at,reserve_components,trial_sponsored_cents,
 trial_reserve_components,trial_days,trial_pool_id,evidence_sha256)
select 'com.rendprop.app.pro29.monthly','USA','USD',29990,2549,1,
 now()-interval '1 hour',now()+interval '20 days',
 '{"storage":1,"delivery":1,"compute":1,"email":1,"support":1,"retention":1,"uncertainty":1}',
 500,'{"storage":8,"delivery":3,"compute":4,"email":5,"support":6,"retention":8,"uncertainty":8}',
 7,pool_id,repeat('7',64) from card_trial_case
returning id \gset
update card_trial_case set schedule_id=:'id';
update public.subscription_trial_media_template set enabled=true,
 account_reserve_ref='local-card-media-reserve',request_limit=1000,
 byte_limit=1073741824,storage_limit=1342177280,evidence_sha256=repeat('8',64)
 where singleton;
update public.app_config set value=jsonb_build_object('cap_cents',0,
 'starts_at',now()-interval '1 day','ends_at',now()-interval '1 hour')
 where key='trial_sponsor_pool';
update public.subscription_trial_config set enabled=true where singleton;
insert into auth.users(id,email,is_anonymous,email_confirmed_at)
select actor_id,'card-trial-first@example.invalid',false,now() from card_trial_case
union all select second_actor,'card-trial-second@example.invalid',false,now() from card_trial_case;
insert into public.orgs(id,name,plan,plan_source)
select org_id,'Card first','free',null from card_trial_case
union all select second_org,'Card second','free',null from card_trial_case;
insert into public.memberships(user_id,org_id,role)
select actor_id,org_id,'owner' from card_trial_case
union all select second_actor,second_org,'owner' from card_trial_case;

set local role service_role;
select pg_temp.card_ok(public.subscription_trial_media_template_ready(schedule_id),
 'card pool and $0-cash account reserve are correctly bound and covered') from card_trial_case;
select pg_temp.card_ok((public.prepare_subscription_trial_purchase(actor_id,org_id,
 'com.rendprop.app.pro29.monthly')#>>'{trial_offer,photo_edits}')='5',
 'first confirmed owner receives exactly five photo admissions') from card_trial_case;
select pg_temp.card_ok((select count(*) from public.subscription_trial_purchase_reservations
 where pool_id=c.pool_id)=1,'one immutable $5 hold exists before StoreKit') from card_trial_case c;
reset role;

update public.trial_card_provider_verifications set kie_auto_refill_enabled=false;
set local role service_role;
select pg_temp.card_ok(not public.trial_card_authority_active(authority_id),
 'disabled provider refill closes new authority') from card_trial_case;
select pg_temp.card_refuses(format(
 'select public.prepare_subscription_trial_purchase(%L,%L,%L)',
 (select second_actor from card_trial_case),(select second_org from card_trial_case),
 'com.rendprop.app.pro29.monthly'),
 'RP402: Seven-day trial media coverage is unavailable',
 'provider shutdown refuses new hold before Apple sheet');
select pg_temp.card_ok((select count(*) from public.subscription_trial_purchase_reservations
 where pool_id=c.pool_id)=1,'provider shutdown cannot erase previous commitment') from card_trial_case c;
select public.apply_apple_entitlement_v2(
 'ed200000-0000-4000-8000-000000000001',
 'ed100000-0000-4000-8000-000000000001',
 'card-trial-original','card-trial-tx','com.rendprop.app.pro29.monthly',
 'pro','Production','active',now()+interval '168 hours',true,'SUBSCRIBED',
 now(),now(),now(),now());
select pg_temp.card_ok((result->>'funded')='true',
 'previously committed signed trial converts despite later refill disablement: '||result::text)
from (select public.fund_reserved_subscription_trial(
 'ed100000-0000-4000-8000-000000000001',
 'ed200000-0000-4000-8000-000000000001',
 'card-trial-original','card-trial-tx','com.rendprop.app.pro29.monthly',
 0,'USD','USA',1,'FREE_TRIAL',now(),now()+interval '168 hours',now(),repeat('d',64)) as result) converted;
select pg_temp.card_ok((select funding_id is not null and account_reserve_ref='local-card-media-reserve'
 from public.media_delivery_budgets where org_id='ed200000-0000-4000-8000-000000000001'),
 'card-backed conversion creates finite media budget without paid-cash fiction');
reset role;
update public.trial_card_provider_verifications set kie_auto_refill_enabled=true;
update public.app_config set value=jsonb_build_object('cap_cents',1,
 'starts_at',now()-interval '1 day','ends_at',now()+interval '20 days')
 where key='trial_sponsor_pool';
set local role service_role;
select pg_temp.card_ok(not public.subscription_trial_media_template_ready(schedule_id),
 'legacy future spend cannot overlap entire $500 shared card allocation') from card_trial_case;
reset role;
update public.app_config set value=jsonb_build_object('cap_cents',0,
 'starts_at',now()-interval '1 day','ends_at',now()-interval '1 hour')
 where key='trial_sponsor_pool';

-- 99 tiny synthetic prior holds make the 100-count guard decisive while
-- leaving almost all of the $500 supplier balance unused.
insert into public.subscription_trial_purchase_reservations(
 actor_id,identity_sha256,org_id,product_id,pool_id,schedule_id,sponsored_cents,
 reserve_components,schedule_evidence_sha256,pool_evidence_sha256,
 walkthrough_cap,photo_cap,listing_cap,max_days,max_video_seconds,upload_budget_bytes)
select gen_random_uuid(),encode(sha256(convert_to('card-fixture-'||series.i,'UTF8')),'hex'),
 gen_random_uuid(),'com.rendprop.app.pro29.monthly',c.pool_id,c.schedule_id,1,
 '{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}',
 repeat('7',64),repeat('6',64),0,5,0,7,0,1073741824
from generate_series(1,99) series(i) cross join card_trial_case c;
set local role service_role;
select pg_temp.card_refuses(format(
 'select public.prepare_subscription_trial_purchase(%L,%L,%L)',
 (select second_actor from card_trial_case),(select second_org from card_trial_case),
 'com.rendprop.app.pro29.monthly'),
 'First 100 trial commitments exceed the owner allocation',
 '101st hold refused even when $500 pool still has cash headroom');
select pg_temp.card_ok((select count(*) from public.subscription_trial_purchase_reservations
 where pool_id=c.pool_id)=100,'first-100 cap cannot be bypassed by one extra account') from card_trial_case c;
select pg_temp.card_ok(public.revoke_trial_card_budget_authority(authority_id,repeat('e',64)),
 'service-only emergency stop revokes future card authority') from card_trial_case;
select pg_temp.card_ok(not public.trial_card_authority_active(authority_id),
 'revoked card authority cannot open another trial purchase') from card_trial_case;
select pg_temp.card_ok(public.serving_trial_funded_actor(actor_id,org_id),
 'revocation preserves the previously signed seven-day customer commitment') from card_trial_case;
select pg_temp.card_refuses(
 'select public.provision_trial_card_budget_authority(''second-card-backed-cohort'',now()-interval ''1 hour'',now()+interval ''120 days'',repeat(''f'',64))',
 'one_trial_card_authority_per_operator',
 'revoking the first budget cannot silently authorize another $1,000 cohort');
reset role;

select jsonb_build_object('passed',true,'assertions',n,'scope','rolled-back local synthetic PostgreSQL')
 from card_trial_case;
rollback;
