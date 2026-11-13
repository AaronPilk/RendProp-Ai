-- Activation audit is read-only and does not turn a public free trial on.
begin;
\ir trial_media_fixture.sql
create temporary table trial_ready_checks(n integer not null default 0);
insert into trial_ready_checks default values;
grant all on trial_ready_checks to service_role;
create function pg_temp.ready_ok(v boolean,label text) returns void language plpgsql as $$
begin if v is distinct from true then raise exception 'TRIAL READINESS FAIL: %',label;end if;
  update trial_ready_checks set n=n+1;end$$;
create function pg_temp.ready_refuses(statement text,needle text,label text)
returns void language plpgsql as $$
begin begin execute statement; exception when others then
 if position(needle in sqlerrm)>0 then perform pg_temp.ready_ok(true,label);return;end if;
 raise;end;raise exception 'TRIAL READINESS FAIL admitted: %',label;end$$;

select pg_temp.ready_ok(not has_function_privilege('authenticated',
  'public.subscription_trial_activation_readiness()','execute'),
  'tenants cannot query sponsor readiness details');
set local role service_role;
select pg_temp.ready_ok(
  (public.subscription_trial_activation_readiness()->>'currently_enabled')::boolean=false and
  jsonb_array_length(public.subscription_trial_activation_readiness()->'missing_funded_skus')=4 and
  (public.subscription_trial_activation_readiness()->>'local_prerequisites_met')::boolean=false,
  'migration remains dormant with all four SKU commitments missing');
reset role;

update public.app_config set value=jsonb_build_object('cap_cents',29000,
  'starts_at',now()-interval '1 day','ends_at',now()+interval '20 days')
  where key='trial_sponsor_pool';
insert into public.serving_sponsor_pools(
  collection_ref,source,funded_cents,starts_at,ends_at,evidence_sha256,admissions_enabled)
values('synthetic-trial-readiness','trial',3000,now()-interval '1 day',
  now()+interval '20 days',repeat('a',64),true);
insert into public.apple_serving_schedules(
  product_id,storefront,currency,price_milliunits,net_proceeds_floor_cents,
  service_months,starts_at,ends_at,reserve_components,
  trial_sponsored_cents,trial_reserve_components,trial_days,trial_pool_id,evidence_sha256)
select sku,'USA','USD',price,least(price/20,3000),1,
  now()-interval '1 day',now()+interval '20 days',
  '{"storage":1,"delivery":1,"compute":1,"email":1,"support":1,"retention":1,"uncertainty":1}',
  500,'{"storage":8,"delivery":3,"compute":4,"email":5,"support":6,"retention":8,"uncertainty":8}',
  7,(select id from public.serving_sponsor_pools
    where collection_ref='synthetic-trial-readiness'),repeat('b',64)
from (values
  ('com.rendprop.app.pro29.monthly',29990),
  ('com.rendprop.app.starter.monthly',49000),
  ('com.rendprop.app.pro.monthly',99990),
  ('com.rendprop.app.team.monthly',249990)) products(sku,price);
set local role service_role;
select pg_temp.ready_ok(
  (public.subscription_trial_activation_readiness()->>'local_prerequisites_met')::boolean and
  (public.subscription_trial_activation_readiness()->>'private_launch_authority_clear')::boolean and
  jsonb_array_length(public.subscription_trial_activation_readiness()->'missing_funded_skus')=0 and
  (public.subscription_trial_activation_readiness()->>'purchase_pool_available_cents')::integer=3000 and
  (public.subscription_trial_activation_readiness()->>'currently_enabled')::boolean=false,
  'bounded sponsor and all four SKU schedules become locally ready without activation');
reset role;
-- A one-cent overlap above the $500 shared allocation must close both
-- readiness and per-SKU media coverage before any StoreKit purchase.
update public.app_config set value=jsonb_build_object('cap_cents',29001,
  'starts_at',now()-interval '1 day','ends_at',now()+interval '20 days')
  where key='trial_sponsor_pool';
set local role service_role;
select pg_temp.ready_ok(
  (public.subscription_trial_activation_readiness()->>'local_prerequisites_met')::boolean=false and
  jsonb_array_length(public.subscription_trial_activation_readiness()->'missing_funded_skus')=4,
  'shared media account plus legacy cap above 500 dollars closes readiness');
reset role;
update public.app_config set value=jsonb_build_object('cap_cents',29000,
  'starts_at',now()-interval '1 day','ends_at',now()+interval '20 days')
  where key='trial_sponsor_pool';
update public.app_config set value=jsonb_build_object('cap_cents',1,
  'starts_at',now()-interval '1 day','ends_at',now()-interval '1 hour')
  where key='trial_sponsor_pool';
set local role service_role;
select pg_temp.ready_ok(
  (public.subscription_trial_activation_readiness()->>'local_prerequisites_met')::boolean and
  (public.subscription_trial_activation_readiness()->>'trial_funded_dispatch_ready')::boolean and
  (public.subscription_trial_activation_readiness()->>'serving_envelope_ready')::boolean=false,
  'funded trial readiness does not double-count expired legacy ceiling');
reset role;
update public.serving_sponsor_pools set admissions_enabled=false
 where collection_ref='synthetic-trial-readiness';
set local role service_role;
select pg_temp.ready_ok(
  jsonb_array_length(public.subscription_trial_activation_readiness()->'missing_funded_skus')=4 and
  (public.subscription_trial_activation_readiness()->>'local_prerequisites_met')::boolean=false,
  'disabling cash admission immediately revokes launch readiness');
reset role;

insert into auth.users(id,email,is_anonymous,email_confirmed_at)
values('61111111-1111-4111-8111-111111111111','trial-pro29@example.invalid',false,now());
insert into public.orgs(id,name,plan,plan_source)
values('6aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Trial Pro29 fixture','free',null);
insert into public.memberships(user_id,org_id,role)
values('61111111-1111-4111-8111-111111111111',
  '6aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner');
set local role service_role;
select pg_temp.ready_refuses(
  'select public.prepare_subscription_trial_purchase(''61111111-1111-4111-8111-111111111111'',''6aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'',''com.rendprop.app.pro29.monthly'')',
  'RP402:','new Pro29 SKU passes the allowlist but the dormant trial still refuses purchase');
select pg_temp.ready_ok((select enabled=false and photo_edits=5 and max_days=7
  from public.subscription_trial_config where singleton),
  'readiness and SKU audit never enable the seven-day trial');
reset role;
select json_build_object('passed',true,'assertions',(select n from trial_ready_checks));
rollback;
