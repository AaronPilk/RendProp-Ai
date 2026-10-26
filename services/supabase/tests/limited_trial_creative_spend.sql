-- Disposable local PostgreSQL fixture. All identities and financial attempts
-- are synthetic and rolled back. No provider or hosted database is contacted.
begin;
create temporary table trial_checks(n integer not null default 0);
insert into trial_checks default values;
grant all on trial_checks to service_role;
create temporary table trial_oneoff_fixture(actor uuid,org uuid,listing uuid);
grant select on trial_oneoff_fixture to service_role;
create temporary table trial_renewal_fixture(actor uuid,org uuid,listing uuid);
grant select on trial_renewal_fixture to service_role;
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

select pg_temp.trial_ok((select renders_per_month=0 and photo_edits_per_month=5
  and reels_per_month=0 and aerials_per_month=0 and topaz_per_month=0
  and cogs_ceiling_cents=500 from public.plan_entitlements where plan='trial'),
  'trial catalog allows five photo edits but no walkthrough render or generated video');
select pg_temp.trial_ok((select count(*)=5 from public.plan_entitlement_overrides
  where plan='trial' and renders_per_month=0 and photo_edits_per_month=5 and reels_per_month=0
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
  and not has_function_privilege('authenticated','public.trial_intro_publication_guard()','execute')
  and not has_function_privilege('authenticated','public.trial_intro_listing_guard()','execute')
  and not has_function_privilege('authenticated','public.trial_intro_upload_guard()','execute'),
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
    and (public.org_entitlement(sandbox_org)).renders_per_month=0
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
    and intro.renders_per_month=0 and intro.photo_edits_per_month=5
    and intro.reels_per_month=0 and intro.aerials_per_month=0
    and intro.topaz_per_month=0 and intro.cogs_ceiling_cents=500,
    'verified Apple free week keeps SKU identity but clamps creative use');
  perform pg_temp.trial_ok(public.plan_serving_ceiling(apple_org)->>'kind'='trial'
    and public.plan_serving_ceiling(apple_org)->>'window'='intro_window'
    and (public.plan_serving_ceiling(apple_org)->>'period_end')::timestamptz>now()
    and (public.plan_serving_ceiling(apple_org)->>'ceiling_cents')::numeric=500,
    'atomic wallet reports live intro_window and agrees with five-edit entitlement');
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
    (intro_listing,apple_org,actor,'Synthetic introductory listing');
  insert into trial_oneoff_fixture values(actor,apple_org,intro_listing);
  insert into trial_renewal_fixture values(actor,apple_org,second_listing);
  perform pg_temp.trial_ok((select count(*)=1
    from public.workspace_publication_slots where org_id=apple_org),
    'Apple intro consumes exactly one listing slot when creating its draft');
  perform pg_temp.trial_refuses(format(
    'insert into public.listings(id,org_id,agent_id,address) values(%L,%L,%L,''Second trial listing'')',
    second_listing,apple_org,actor),'RP402: The introductory week includes one listing',
    'Apple intro cannot create a second draft listing before payment');
  update public.listings set address='Updated introductory listing' where id=intro_listing;
  perform pg_temp.trial_ok((select count(*)=1
    from public.listings where id=intro_listing and address='Updated introductory listing'),
    'first draft remains editable without consuming another slot');
  perform pg_temp.trial_refuses(format(
    'insert into public.render_jobs(listing_id,source) values(%L,''app'')',intro_listing),
    'RP402: Video and public website creation start after payment',
    'Apple intro cannot publish on-device video without payment');
  perform pg_temp.trial_refuses(format(
    'insert into public.render_jobs(listing_id,source) values(%L,''worker'')',intro_listing),
    'RP402: Video and public website creation start after payment',
    'Apple intro cannot start a server render without payment');

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

-- Reserve a representative batch of forty 8 MiB iPhone photos on the one
-- introductory draft. Transport holds each single upload at twice its bytes,
-- so this batch needs 640 MiB of photo headroom, not supplier credits.
set local role service_role;
do $$declare f record;photos jsonb;r jsonb;video jsonb;video_id uuid:=gen_random_uuid();begin
  select * into f from trial_oneoff_fixture;
  select jsonb_agg(jsonb_build_object(
    'id',a.id,'listing_id',f.listing,'kind','photo','bucket','renders',
    'storage_key','renders/'||f.org||'/'||f.listing||'/gallery-'||a.id||'.jpg',
    'bytes',8388608,'content_type','image/jpeg','content_type_declared',true,
    'idem_key','trial-photo-'||a.n) order by a.n) into photos
  from (select gen_random_uuid()id,n from generate_series(1,40)n)a;
  r:=public.reserve_upload_assets(f.actor,photos);
  perform pg_temp.trial_ok(jsonb_array_length(r)=40 and
    (select count(*)=40 and sum(held_bytes)=671088640
      from public.upload_reservations where listing_id=f.listing),
    'one introductory draft reserves forty ordinary iPhone photos under the fixed technical cap');
  video:=jsonb_build_array(jsonb_build_object(
    'id',video_id,'listing_id',f.listing,'kind','video','bucket','renders',
    'storage_key','renders/'||f.org||'/'||f.listing||'/'||video_id||'.mp4',
    'bytes',10485760,'content_type','video/mp4','content_type_declared',true,
    'idem_key','trial-video-denied'));
  perform pg_temp.trial_refuses(format(
    'select public.reserve_upload_assets(%L,%L::jsonb)',f.actor,video),
    'RP402: Video uploads start after payment',
    'photo upload headroom cannot be spent on an unpaid video upload');
  perform pg_temp.trial_ok(not exists(select 1 from public.capture_assets a where a.id=video_id),
    'refused video upload leaves no source asset');
end$$;
reset role;

-- A one-time property website purchase is a separate payment. It unlocks
-- on-device publication for that exact property, but not supplier renders or
-- another introductory listing. The RPC itself verifies and binds the credit.
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
set local role service_role;
do $$declare f record;video_id uuid:=gen_random_uuid();video jsonb;r jsonb;begin
  select * into f from trial_oneoff_fixture;
  video:=jsonb_build_array(jsonb_build_object(
    'id',video_id,'listing_id',f.listing,'kind','video','bucket','renders',
    'storage_key','renders/'||f.org||'/'||f.listing||'/'||video_id||'.mp4',
    'bytes',10485760,'content_type','video/mp4','content_type_declared',true,
    'idem_key','paid-website-video'));
  r:=public.reserve_upload_assets(f.actor,video);
  perform pg_temp.trial_ok(jsonb_array_length(r)=1 and exists(
    select 1 from public.capture_assets a where a.id=video_id and a.kind='video'),
    'verified one-time website credit allows its own on-device video upload');
end$$;
reset role;
insert into public.render_jobs(listing_id,source)
  select listing,'app' from trial_oneoff_fixture;
select pg_temp.trial_refuses($q$insert into public.render_jobs(listing_id,source)
  select listing,'worker' from trial_oneoff_fixture$q$,
  'RP402: Video and public website creation start after payment',
  'paid website credit does not buy a supplier render');
select pg_temp.trial_ok((select count(*)=1 from public.workspace_publication_slots s
  join trial_oneoff_fixture f on f.org=s.org_id and f.listing=s.listing_id),
  'one-time website credit does not mint another free-listing slot');

do $$declare actor uuid;apple_org uuid;second_listing uuid;paid public.plan_entitlements;r jsonb;h text:=repeat('a',64);begin
  select f.actor,f.org,f.listing into actor,apple_org,second_listing from trial_renewal_fixture f;

  -- Renewed paid term: same org, same subscription and old ledger, only the
  -- signed current transaction dates change. Full purchased quotas return.
  update public.apple_subscriptions set
    transaction_purchased_at=now(),transaction_signed_at=now(),
    expires_at=now()+interval '29 days'
  where org_id=apple_org;
  update public.orgs set plan_expires_at=now()+interval '29 days'
  where id=apple_org;
  paid:=public.org_entitlement(apple_org);
  perform pg_temp.trial_ok(paid.plan='starter' and paid.renders_per_month=4 and paid.photo_edits_per_month=100
    and paid.reels_per_month=30 and paid.aerials_per_month=2
    and paid.cogs_ceiling_cents>=2032
    and public.plan_serving_ceiling(apple_org)->>'kind'='retail',
    'paid renewal restores Starter allowance without changing SKU or account');
  -- A previously bound introductory original transaction may remain active
  -- even though the org snapshot and current signed term are now paid.
  insert into public.apple_subscriptions(
    original_transaction_id,org_id,user_id,product_id,plan,environment,status,
    expires_at,auto_renew,last_transaction_id,transaction_purchased_at,
    transaction_signed_at)
  values('limited-trial-stale-original',apple_org,actor,
    'com.rendprop.app.starter.monthly','starter','Production','active',
    now()+interval '7 days',false,'limited-trial-stale-intro',now(),now());
  paid:=public.org_entitlement(apple_org);
  perform pg_temp.trial_ok(paid.photo_edits_per_month=100
    and paid.reels_per_month=30 and paid.aerials_per_month=2
    and public.plan_serving_ceiling(apple_org)->>'kind'='retail',
    'stale active intro row cannot clamp current paid service term');
  insert into public.listings(id,org_id,agent_id,address)
    values(second_listing,apple_org,actor,'Synthetic second paid listing');
  insert into public.render_jobs(listing_id,source)
    values(second_listing,'app');
  perform pg_temp.trial_ok((select count(*)=1
    from public.workspace_publication_slots where org_id=apple_org),
    'paid renewal publishes a second listing without using a trial slot');
  r:=public.app_video_cost_reserve(actor,apple_org,'paid-renewal-reel',
    'reel','kie','synthetic/reel',h,25,5,5,'{}');
  perform pg_temp.trial_ok((r->>'reserved')::boolean,
    'paid renewal can reserve video through the real atomic gate');

end$$;

-- A Team intro shares one publication allowance across two agent-owned
-- private libraries; each listing still retains its original content org.
insert into auth.users(id,email,is_anonymous) values
  ('a9010001-0000-4000-8000-000000000001','limited-team-owner@example.invalid',false),
  ('a9010001-0000-4000-8000-000000000002','limited-team-agent-one@example.invalid',false),
  ('a9010001-0000-4000-8000-000000000003','limited-team-agent-two@example.invalid',false);
create temporary table trial_team_fixture as select
  'a9010001-0000-4000-8000-000000000001'::uuid owner_id,
  'a9010001-0000-4000-8000-000000000002'::uuid agent_one,
  'a9010001-0000-4000-8000-000000000003'::uuid agent_two,
  (select org_id from public.memberships where user_id='a9010001-0000-4000-8000-000000000001') team_org,
  (select org_id from public.memberships where user_id='a9010001-0000-4000-8000-000000000002') first_org,
  (select org_id from public.memberships where user_id='a9010001-0000-4000-8000-000000000003') second_org,
  gen_random_uuid() first_listing,gen_random_uuid() second_listing;
grant select on trial_team_fixture to service_role;
update public.plan_entitlements set seats=3 where plan='team';
set local role service_role;
do $$declare f record;r jsonb;begin
  select * into f from trial_team_fixture;
  perform public.apply_apple_entitlement_v2(f.team_org,f.owner_id,
    'limited-team-intro-original','limited-team-intro-transaction',
    'com.rendprop.app.team.monthly','team','Production','active',
    now()+interval '7 days',true,'SUBSCRIBED',now(),now(),now(),now());
  r:=public.create_org_invite(f.owner_id,f.team_org,null,'agent',repeat('a',64));
  perform public.accept_org_invite(f.agent_one,repeat('a',64));
  r:=public.create_org_invite(f.owner_id,f.team_org,null,'agent',repeat('b',64));
  perform public.accept_org_invite(f.agent_two,repeat('b',64));
  perform pg_temp.trial_ok(public.library_billing_org(f.first_org)=f.team_org
    and public.library_billing_org(f.second_org)=f.team_org,
    'private libraries are charged to their common Team parent');
  perform pg_temp.trial_ok(public.plan_serving_ceiling(f.first_org)->>'kind'='trial',
    'private library inherits the parent introductory service term');
end$$;
reset role;
insert into public.listings(id,org_id,agent_id,address)
  select first_listing,first_org,agent_one,'Synthetic first private listing'
  from trial_team_fixture;
select pg_temp.trial_ok((select count(*)=1 from public.workspace_publication_slots s
  join trial_team_fixture f on f.team_org=s.org_id
  where s.listing_id=f.first_listing),
  'first private Team listing consumes parent trial slot');
select pg_temp.trial_refuses($q$insert into public.listings(id,org_id,agent_id,address)
  select second_listing,second_org,agent_two,'Synthetic second private listing'
  from trial_team_fixture$q$,
  'RP402: The introductory week includes one listing',
  'second private Team library cannot create another trial listing');

-- If the dormant funded-serving mode is deliberately enabled later, the
-- owner policy still allows one draft and refuses video. It does not depend
-- on the current ceiling-mode switch.
insert into auth.users(id,email,is_anonymous) values
  ('a9020001-0000-4000-8000-000000000001','limited-funded-trial@example.invalid',false);
create temporary table trial_funded_fixture as select
  'a9020001-0000-4000-8000-000000000001'::uuid actor,
  gen_random_uuid()org,gen_random_uuid()first_listing,gen_random_uuid()second_listing;
grant select on trial_funded_fixture to service_role;
insert into public.orgs(id,name,plan,plan_source,trial_ends_at)
  select org,'Synthetic funded trial','trial','trial',now()+interval '7 days'
  from trial_funded_fixture;
insert into public.memberships(user_id,org_id,role)
  select actor,org,'owner' from trial_funded_fixture;
update public.app_config set value=value||'{"mode":"funded"}'::jsonb
where key='serving_mode';
insert into public.listings(id,org_id,agent_id,address)
  select first_listing,org,actor,'Funded first draft' from trial_funded_fixture;
select pg_temp.trial_ok((select count(*)=1 from public.listings l
  join trial_funded_fixture f on l.id=f.first_listing),
  'funded trial retains its first draft without a video grant');
select pg_temp.trial_refuses($q$insert into public.listings(id,org_id,agent_id,address)
  select second_listing,org,actor,'Funded second draft' from trial_funded_fixture$q$,
  'RP402: The introductory week includes one listing',
  'funded trial also refuses a second draft');
select pg_temp.trial_refuses($q$insert into public.render_jobs(listing_id,source)
  select first_listing,'app' from trial_funded_fixture$q$,
  'RP402:',
  'funded trial cannot publish app-source video');
update public.app_config set value=value||'{"mode":"ceiling"}'::jsonb
where key='serving_mode';

-- An account that finishes the free week without paying cannot obtain a new
-- video through the remaining free plan. Its prepared listing stays intact.
update public.orgs set plan='free',plan_source=null,trial_ends_at=null
where id=(select org from trial_funded_fixture);
select pg_temp.trial_ok((select public.plan_serving_ceiling(org)->>'kind'='free'
  from trial_funded_fixture),
  'expired unpaid account has the free serving envelope');
do $$declare f record;h text:=repeat('a',64);begin
  select * into f from trial_funded_fixture;
  perform pg_temp.trial_refuses(format(
    'select public.app_video_cost_reserve(%L,%L,%L,''reel'',''kie'',''synthetic/reel'',%L,25,5,5,''{}'')',
    f.actor,f.org,'free-reel-denied',h),'RP402:',
    'post-intro free account cannot reserve a paid supplier reel');
  perform pg_temp.trial_refuses(format(
    'select public.app_video_cost_reserve(%L,%L,%L,''aerial'',''kie'',''synthetic/aerial'',%L,100,1,100,''{}'')',
    f.actor,f.org,'free-aerial-denied',h),'RP402:',
    'post-intro free account cannot reserve an aerial supplier clip');
end$$;
select pg_temp.trial_refuses($q$insert into public.render_jobs(listing_id,source)
  select first_listing,'app' from trial_funded_fixture$q$,
  'RP402: Video and public website creation start after payment',
  'post-intro free account cannot publish a new on-device video');
select pg_temp.trial_refuses($q$insert into public.render_jobs(listing_id,source)
  select first_listing,'worker' from trial_funded_fixture$q$,
  'RP402: Video and public website creation start after payment',
  'post-intro free account cannot start a new supplier render');
set local role service_role;
do $$declare f record;v uuid:=gen_random_uuid();spec jsonb;begin
  select * into f from trial_funded_fixture;
  spec:=jsonb_build_array(jsonb_build_object(
    'id',v,'listing_id',f.first_listing,'kind','video','bucket','renders',
    'storage_key','renders/'||f.org||'/'||f.first_listing||'/'||v||'.mp4',
    'bytes',10485760,'content_type','video/mp4','content_type_declared',true,
    'idem_key','free-video-denied'));
  perform pg_temp.trial_refuses(format(
    'select public.reserve_upload_assets(%L,%L::jsonb)',f.actor,spec),
    'RP402: Video uploads start after payment',
    'post-intro free account cannot reserve video transport');
end$$;
reset role;

select jsonb_build_object('passed',true,'assertions',(select n from trial_checks));
rollback;
