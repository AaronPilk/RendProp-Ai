\set ON_ERROR_STOP on
begin;
-- Run the boundary in a timezone with DST so the purchase authority cannot
-- silently stretch or shorten the absolute 168-hour Apple term.
set local timezone='America/New_York';

create temporary table trial_window_checks(n integer not null default 0);
insert into trial_window_checks default values;
grant all on trial_window_checks to service_role;
create function pg_temp.window_ok(v boolean, label text) returns void
language plpgsql as $$begin
  if v is distinct from true then raise exception 'TRIAL WINDOW FAIL: %',label;end if;
  update trial_window_checks set n=n+1;
end$$;
create function pg_temp.window_refuses(statement text, label text) returns void
language plpgsql as $$begin
  begin execute statement;
  exception when others then
    if position('RP402:' in sqlerrm)=0 then raise;end if;
    perform pg_temp.window_ok(true,label);
    perform pg_temp.window_ok(
      not exists(select 1 from public.subscription_trial_purchase_reservations
                 where actor_id='e3100000-0000-4000-8000-000000000001') and
      not exists(select 1 from public.serving_funding
                 where org_id='e3200000-0000-4000-8000-000000000001'),
      label||' leaves no partial cash hold');
    return;
  end;
  raise exception 'TRIAL WINDOW FAIL admitted: %',label;
end$$;
select pg_temp.window_ok(
  ('2026-10-30 12:00:00+00'::timestamptz+interval '7 days') <>
  ('2026-10-30 12:00:00+00'::timestamptz+interval '168 hours'),
  'DST boundary distinguishes calendar days from the absolute Apple term');

update public.app_config set value=jsonb_build_object('mode','ceiling','free_published_listings',1)
  where key='serving_mode';
update public.app_config set value=jsonb_build_object('cap_cents',500,
  'starts_at',now()-interval '1 day','ends_at',now()+interval '168 hours'-interval '1 microsecond')
  where key='trial_sponsor_pool';
update public.subscription_trial_config set enabled=true;
insert into auth.users(id,email,is_anonymous,email_confirmed_at)
values('e3100000-0000-4000-8000-000000000001','full-week-owner@example.invalid',false,now());
insert into public.orgs(id,name,plan,plan_source)
values('e3200000-0000-4000-8000-000000000001','Full-week admission fixture','free',null);
insert into public.memberships(user_id,org_id,role)
values('e3100000-0000-4000-8000-000000000001',
       'e3200000-0000-4000-8000-000000000001','owner');
insert into public.serving_sponsor_pools(
  collection_ref,source,funded_cents,starts_at,ends_at,evidence_sha256,admissions_enabled)
values('synthetic-full-week','trial',500,now()-interval '1 day',
       now()+interval '168 hours',repeat('a',64),true);
insert into public.apple_serving_schedules(
  product_id,storefront,currency,price_milliunits,net_proceeds_floor_cents,
  service_months,starts_at,ends_at,reserve_components,
  trial_sponsored_cents,trial_reserve_components,trial_days,trial_pool_id,evidence_sha256)
select 'com.rendprop.app.pro29.monthly','USA','USD',29990,2549,
  1,now()-interval '1 day',now()+interval '168 hours'-interval '1 microsecond',
  '{"storage":1,"delivery":1,"compute":1,"email":1,"support":1,"retention":1,"uncertainty":1}',
  500,'{"storage":1,"delivery":1,"compute":1,"email":1,"support":1,"retention":1,"uncertainty":1}',
  7,id,repeat('b',64) from public.serving_sponsor_pools
  where collection_ref='synthetic-full-week';

set local role service_role;
select pg_temp.window_refuses(
  'select public.prepare_subscription_trial_purchase(''e3100000-0000-4000-8000-000000000001'',''e3200000-0000-4000-8000-000000000001'',''com.rendprop.app.pro29.monthly'')',
  'schedule one microsecond short');
reset role;
update public.apple_serving_schedules set ends_at=now()+interval '168 hours'
  where product_id='com.rendprop.app.pro29.monthly';
update public.serving_sponsor_pools set ends_at=now()+interval '168 hours'-interval '1 microsecond'
  where collection_ref='synthetic-full-week';
set local role service_role;
select pg_temp.window_refuses(
  'select public.prepare_subscription_trial_purchase(''e3100000-0000-4000-8000-000000000001'',''e3200000-0000-4000-8000-000000000001'',''com.rendprop.app.pro29.monthly'')',
  'purchase sponsor pool one microsecond short');
reset role;
update public.serving_sponsor_pools set ends_at=now()+interval '168 hours'
  where collection_ref='synthetic-full-week';
set local role service_role;
select pg_temp.window_refuses(
  'select public.prepare_subscription_trial_purchase(''e3100000-0000-4000-8000-000000000001'',''e3200000-0000-4000-8000-000000000001'',''com.rendprop.app.pro29.monthly'')',
  'runtime ceiling pool one microsecond short');
reset role;
update public.app_config set value=jsonb_set(value,'{ends_at}',to_jsonb(now()+interval '168 hours'))
  where key='trial_sponsor_pool';
update public.app_config set value=jsonb_set(value,'{cap_cents}','499'::jsonb)
  where key='trial_sponsor_pool';
set local role service_role;
select pg_temp.window_refuses(
  'select public.prepare_subscription_trial_purchase(''e3100000-0000-4000-8000-000000000001'',''e3200000-0000-4000-8000-000000000001'',''com.rendprop.app.pro29.monthly'')',
  '499 cents cannot back the 500-cent package');
reset role;
update public.app_config set value=jsonb_set(value,'{cap_cents}','500'::jsonb)
  where key='trial_sponsor_pool';
insert into public.serving_cost_reservations(
  org_id,actor_id,request_key,stage,provider,model,input_sha256,
  tariff_version,hold_cents,budget_source,trial_kind,state)
values('e3200000-0000-4000-8000-000000000001',
       'e3100000-0000-4000-8000-000000000001','trial-spent-0001',
       'photo_edit','gemini','synthetic',repeat('c',64),'synthetic',
       1,'ceiling',true,'uncertain');
set local role service_role;
select pg_temp.window_refuses(
  'select public.prepare_subscription_trial_purchase(''e3100000-0000-4000-8000-000000000001'',''e3200000-0000-4000-8000-000000000001'',''com.rendprop.app.pro29.monthly'')',
  'one spent cent leaves only 499 cents for a 500-cent package');
reset role;
update public.app_config set value=jsonb_set(value,'{cap_cents}','501'::jsonb)
  where key='trial_sponsor_pool';
set local role service_role;
select pg_temp.window_ok(
  (public.prepare_subscription_trial_purchase(
    'e3100000-0000-4000-8000-000000000001',
    'e3200000-0000-4000-8000-000000000001',
    'com.rendprop.app.pro29.monthly')#>>'{trial_offer,max_days}')='7',
  'all windows ending at exactly seven days admit the complete term');
select pg_temp.window_ok(
  (select count(*)=1 and min(sponsored_cents)=500
   from public.subscription_trial_purchase_reservations
   where actor_id='e3100000-0000-4000-8000-000000000001'),
  'last-safe admission makes exactly one immutable 500-cent hold');
reset role;

select jsonb_build_object('passed',true,'assertions',(select n from trial_window_checks));
rollback;
