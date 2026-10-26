-- Disposable local PostgreSQL fixture. All identities and financial attempts
-- are synthetic and rolled back. No provider or hosted database is contacted.
begin;
create temporary table trial_checks(n integer not null default 0);
insert into trial_checks default values;
grant all on trial_checks to service_role;
create temporary table trial_oneoff_fixture(actor uuid,org uuid,listing uuid);
grant select on trial_oneoff_fixture to service_role;
create function pg_temp.trial_ok(v boolean,label text) returns void language plpgsql as $$
begin
  if v is distinct from true then raise exception 'LIMITED-TRIAL FAIL: %',label;end if;
  update trial_checks set n=n+1;
end$$;
create function pg_temp.trial_refuses(statement text,needle text,label text)
returns void language plpgsql as $$
begin
  begin execute statement;exception when others then
    if position(needle in sqlerrm)>0 then perform pg_temp.trial_ok(true,label);return;end if;
    raise;
  end;
  raise exception 'LIMITED-TRIAL FAIL: admitted %',label;
end$$;

select pg_temp.trial_ok((select renders_per_month=3 and photo_edits_per_month=5
  and reels_per_month=0 and aerials_per_month=0 and topaz_per_month=0
  and cogs_ceiling_cents=500 from public.plan_entitlements where plan='trial'),
  'trial catalog retains cheap listing renders and five photo edits, no generated video');
select pg_temp.trial_ok((select count(*)=5 from public.plan_entitlement_overrides
  where plan='trial' and photo_edits_per_month=5 and reels_per_month=0
    and aerials_per_month=0 and topaz_per_month=0 and cogs_ceiling_cents=500),
  'industry overrides cannot resurrect trial video or larger spend');
select pg_temp.trial_ok((select value->'trial_ceiling_cents'='500'::jsonb
  from public.app_config where key='serving_envelope'),
  'shared financial trial ceiling is five dollars');
select pg_temp.trial_ok((select enabled=false and max_days=7 and photo_edits=5
  from public.subscription_trial_config where singleton),
  'separate bounded trial stays disabled and limited to five photo edits');
select pg_temp.trial_ok(has_function_privilege('authenticated',
  'public.org_entitlement(uuid)','execute')
  and not has_function_privilege('anon','public.org_entitlement(uuid)','execute')
  and not has_function_privilege('authenticated','public.plan_serving_ceiling(uuid)','execute')
  and not has_function_privilege('authenticated','public.trial_intro_publication_guard()','execute'),
  'read access and private money authority are unchanged');

-- The real provider route runs app_video_cost_reserve before network dispatch;
-- reflection removal also checks org_entitlement(). No financial reservation
-- may be created for the first week, even though Apple granted a paid SKU.
do $$
declare
  actor uuid:=gen_random_uuid(); sandbox_org uuid:=gen_random_uuid();
  apple_org uuid:=gen_random_uuid(); manual_org uuid:=gen_random_uuid();
  owner_org uuid:=gen_random_uuid(); owner_actor uuid:=gen_random_uuid();
  intro_listing uuid:=gen_random_uuid(); second_listing uuid:=gen_random_uuid();
  intro public.plan_entitlements; paid public.plan_entitlements; r jsonb;
  h text:=repeat('a',64);
begin
  insert into auth.users(id,email,is_anonymous,email_confirmed_at) values
    (actor,'limited-trial-actor@example.invalid',false,now()),
    (owner_actor,'limited-trial-owner@example.invalid',false,now());
  insert into public.orgs(id,name,plan,plan_source,trial_ends_at) values
    (sandbox_org,'Synthetic sandbox trial','trial','trial',now()+interval '7 days');
  insert into public.orgs(id,name,plan,plan_source) values
    (apple_org,'Synthetic Apple intro','free',null),
    (manual_org,'Synthetic paid manual','starter','manual'),
    (owner_org,'Synthetic sponsored owner','team','manual');
  insert into public.memberships(user_id,org_id,role) values
    (actor,sandbox_org,'owner'),(actor,apple_org,'owner'),
    (actor,manual_org,'owner'),(owner_actor,owner_org,'owner');
  update public.profiles set is_admin=true where id=owner_actor;
  insert into public.org_internal_testing_grants
    (org_id,owner_user_id,unmetered_business_allowances,starts_at,note)
    values(owner_org,owner_actor,true,now()-interval '1 minute','Synthetic local test');

  perform pg_temp.trial_ok((public.org_entitlement(sandbox_org)).photo_edits_per_month=5
    and (public.org_entitlement(sandbox_org)).reels_per_month=0
    and public.plan_serving_ceiling(sandbox_org)->>'kind'='trial',
    'unpaid trial org uses photo-only entitlement');
  perform pg_temp.trial_refuses(format(
    'select public.app_video_cost_reserve(%L,%L,%L,''reel'',''kie'',''synthetic/reel'',%L,25,5,5,''{}'')',
    actor,sandbox_org,'trial-reel-denied',h),'RP402:',
    'unpaid trial reel refused before supplier hold');

  perform public.apply_apple_entitlement_v2(apple_org,actor,
    'limited-trial-original','limited-trial-intro-transaction',
    'com.rendprop.app.starter.monthly','starter','Production','active',
    now()+interval '7 days',true,'SUBSCRIBED',now(),now(),now(),now());
  intro:=public.org_entitlement(apple_org);
  perform pg_temp.trial_ok(intro.plan='starter' and intro.price_cents=4900
    and intro.renders_per_month=3 and intro.photo_edits_per_month=5
    and intro.reels_per_month=0 and intro.aerials_per_month=0
    and intro.topaz_per_month=0 and intro.cogs_ceiling_cents=500,
    'verified Apple free week keeps SKU identity but clamps creative use');
  perform pg_temp.trial_ok(public.plan_serving_ceiling(apple_org)->>'kind'='trial'
    and (public.plan_serving_ceiling(apple_org)->>'ceiling_cents')::numeric=500,
    'atomic wallet agrees with Apple intro entitlement');
  perform pg_temp.trial_refuses(format(
    'select public.app_video_cost_reserve(%L,%L,%L,''aerial'',''kie'',''synthetic/aerial'',%L,100,1,100,''{}'')',
    actor,apple_org,'intro-aerial-denied',h),'RP402:',
    'Apple intro aerial refused before supplier hold');
  perform pg_temp.trial_refuses(format(
    'select public.app_video_cost_reserve(%L,%L,%L,''reel'',''kie'',''synthetic/reel'',%L,25,5,5,''{}'')',
    actor,apple_org,'intro-reel-denied',h),'RP402:',
    'Apple intro reel refused before supplier hold');
  perform pg_temp.trial_ok(not exists(select 1 from public.app_video_cost_reservations
    where org_id in(sandbox_org,apple_org)),
    'denied video attempts do not create reservations');
  insert into public.listings(id,org_id,agent_id,address) values
    (intro_listing,apple_org,actor,'Synthetic introductory listing'),
    (second_listing,apple_org,actor,'Synthetic second listing');
  insert into trial_oneoff_fixture values(actor,apple_org,intro_listing);
  insert into public.render_jobs(listing_id,source)
    values(intro_listing,'app');
  perform pg_temp.trial_ok((select count(*)=1
    from public.workspace_publication_slots where org_id=apple_org),
    'Apple intro consumes exactly one listing slot at render admission');
  perform pg_temp.trial_refuses(format(
    'insert into public.render_jobs(listing_id,source) values(%L,''app'')',
    second_listing),'RP402: The included trial listing',
    'Apple intro cannot publish a second listing before payment');
  insert into public.render_jobs(listing_id,source)
    values(intro_listing,'app');
  perform pg_temp.trial_ok((select count(*)=1
    from public.workspace_publication_slots where org_id=apple_org),
    'intro listing can be retried without consuming another slot');

  -- Renewed paid term: same org, same subscription and old ledger, only the
  -- signed current transaction dates change. Full purchased quotas return.
  update public.apple_subscriptions set
    transaction_purchased_at=now(),transaction_signed_at=now(),
    expires_at=now()+interval '29 days'
  where org_id=apple_org;
  update public.orgs set plan_expires_at=now()+interval '29 days'
  where id=apple_org;
  paid:=public.org_entitlement(apple_org);
  perform pg_temp.trial_ok(paid.plan='starter' and paid.photo_edits_per_month=100
    and paid.reels_per_month=30 and paid.aerials_per_month=2
    and paid.cogs_ceiling_cents>=2032
    and public.plan_serving_ceiling(apple_org)->>'kind'='retail',
    'paid renewal restores Starter allowance without changing SKU or account');
  insert into public.render_jobs(listing_id,source)
    values(second_listing,'app');
  perform pg_temp.trial_ok((select count(*)=1
    from public.workspace_publication_slots where org_id=apple_org),
    'paid renewal publishes a second listing without using a trial slot');
  r:=public.app_video_cost_reserve(actor,apple_org,'paid-renewal-reel',
    'reel','kie','synthetic/reel',h,25,5,5,'{}');
  perform pg_temp.trial_ok((r->>'reserved')::boolean,
    'paid renewal can reserve video through the real atomic gate');

  paid:=public.org_entitlement(manual_org);
  perform pg_temp.trial_ok(paid.reels_per_month=30 and paid.photo_edits_per_month=100,
    'manual paid workspace remains unchanged');
  r:=public.app_video_cost_reserve(actor,manual_org,'manual-paid-reel',
    'reel','kie','synthetic/reel',h,25,5,5,'{}');
  perform pg_temp.trial_ok((r->>'reserved')::boolean,
    'manual paid workspace can still reserve video');

  paid:=public.org_entitlement(owner_org);
  perform pg_temp.trial_ok(paid.reels_per_month=2147483647
    and paid.photo_edits_per_month=2147483647
    and paid.cogs_ceiling_cents=2147483647,
    'verified owner testing grant retains its original unmetered entitlement');
end$$;

-- The verified, one-time website credit is independent of subscription
-- meters. Enable its Sandbox SKU only inside this rolled-back fixture.
update public.property_website_products set sandbox_enabled=true
where product_id='com.rendprop.app.website.premium.property';
set local role service_role;
select pg_temp.trial_ok((public.property_website_transaction(
  (select actor from trial_oneoff_fixture),(select listing from trial_oneoff_fixture),
  (select org from trial_oneoff_fixture),'Sandbox','synthetic-oneoff-website',
  'com.rendprop.app.website.premium.property',now(),now(),null,'purchase'
)->'premium_website'->>'unlocked')::boolean,
  'one-time property website credit remains independently redeemable');
select pg_temp.trial_ok((public.property_website_state(
  (select actor from trial_oneoff_fixture),(select listing from trial_oneoff_fixture),
  (select org from trial_oneoff_fixture)
)->'premium_website'->>'unlocked')::boolean,
  'one-time website access persists independently of trial video clamps');
reset role;

select jsonb_build_object('passed',true,'assertions',(select n from trial_checks));
rollback;
