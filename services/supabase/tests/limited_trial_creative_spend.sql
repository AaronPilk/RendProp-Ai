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
select pg_temp.trial_ok((select renders_per_month=0 and photo_edits_per_month=0
  and reels_per_month=0 and aerials_per_month=0 and topaz_per_month=0
  and cogs_ceiling_cents=0 from public.plan_entitlements where plan='free'),
  'post-intro Free catalog promises no new AI edits or generated media');
select pg_temp.trial_ok((select count(*)=5 from public.plan_entitlement_overrides
  where plan='trial' and renders_per_month=0 and photo_edits_per_month=5 and reels_per_month=0
    and aerials_per_month=0 and topaz_per_month=0 and cogs_ceiling_cents=500),
  'industry overrides cannot resurrect trial video or larger spend');
select pg_temp.trial_ok((select value->'trial_ceiling_cents'='500'::jsonb
  and value->'free_lifetime_cents'='0'::jsonb
  from public.app_config where key='serving_envelope'),
  'shared financial trial ceiling is five dollars and Free has no new AI spend');
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
    second_listing,apple_org,actor),'RP402: Unpaid access includes one listing',
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

  insert into public.listings(org_id,agent_id,address)
    values(sandbox_org,actor,'Saved intro draft after expiry');
  update public.orgs set trial_ends_at=now()-interval '1 minute'
    where id=sandbox_org;
  paid:=public.org_entitlement(sandbox_org);
  perform pg_temp.trial_ok(paid.plan='free' and paid.photo_edits_per_month=0
    and paid.renders_per_month=0 and paid.cogs_ceiling_cents=0
    and public.plan_serving_ceiling(sandbox_org)->>'kind'='free'
    and (public.plan_serving_ceiling(sandbox_org)->>'ceiling_cents')::numeric=0,
    'expired seven-day trial retains its account but has no new AI allowance');
  perform pg_temp.trial_ok(exists(select 1 from public.listings l
    where l.org_id=sandbox_org and l.address='Saved intro draft after expiry'),
    'expired intro retains its prepared listing');
  perform pg_temp.trial_refuses(format(
    'select public.serving_envelope_admit(%L,1,%L)',sandbox_org,'expired-photo-edit'),
    'RP402: AI usage limit reached',
    'expired intro cannot create a new paid photo-edit hold');
end$$;

-- Reserve a representative batch of forty 8 MiB iPhone photos on the one
-- introductory draft. Transport holds each single upload at twice its bytes,
-- so this batch needs 640 MiB of photo headroom, not supplier credits.
set local role service_role;
do $$declare f record;photos jsonb;r jsonb;video jsonb;video_id uuid:=gen_random_uuid();begin
  select * into f from trial_oneoff_fixture;
  r:=public.subscription_trial_context(f.actor,f.org);
  perform pg_temp.trial_ok(r->'trial_usage'='null'::jsonb
    and r->'trial_offer'='null'::jsonb
    and public.subscription_trial_held_offer(f.actor,f.org) is null,
    'ceiling-mode Apple intro exposes no incompatible legacy bounded-trial response');
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

-- Apple's introductory transaction can remain marked active while its
-- seven-day expiry passes and the paid renewal notification is delayed. The
-- purchased SKU remains visible, but no unpaid creative work or new ingress
-- may start. A previously purchased website credit is still property-bound.
update public.apple_subscriptions set expires_at=now()-interval '1 minute'
where org_id=(select org from trial_oneoff_fixture);
-- The chronology trigger deliberately clears signatures when term identity
-- changes. Reattach the synthetic verified date in a separate statement,
-- exactly as apply_apple_entitlement_v2 does after writing the snapshot.
update public.apple_subscriptions set
  transaction_purchased_at=now()-interval '7 days',
  transaction_signed_at=now()
where org_id=(select org from trial_oneoff_fixture);
update public.orgs set plan_expires_at=now()-interval '1 minute'
where id=(select org from trial_oneoff_fixture);
select pg_temp.trial_ok((select (public.org_entitlement(org)).plan='starter'
  and (public.org_entitlement(org)).photo_edits_per_month=0
  and (public.org_entitlement(org)).renders_per_month=0
  and (public.org_entitlement(org)).cogs_ceiling_cents=0
  and public.plan_serving_ceiling(org)->>'kind'='trial'
  and (public.plan_serving_ceiling(org)->>'ceiling_cents')::integer=0
  from trial_oneoff_fixture),
  'expired Apple intro keeps SKU identity but offers zero creative allowance');
select pg_temp.trial_refuses($q$insert into public.listings(org_id,agent_id,address)
  select org,actor,'Expired Apple intro extra draft' from trial_oneoff_fixture$q$,
  'RP402: Listing creation starts after the free week',
  'expired Apple intro cannot prepare another listing');
set local role service_role;
do $$declare f record;spec jsonb;ticket uuid:=gen_random_uuid();begin
  select * into f from trial_oneoff_fixture;
  spec:=jsonb_build_array(jsonb_build_object(
    'id',ticket,'listing_id',f.listing,'kind','photo','bucket','renders',
    'storage_key','renders/'||f.org||'/'||f.listing||'/gallery-'||ticket||'.jpg',
    'bytes',8388608,'content_type','image/jpeg','content_type_declared',true,
    'idem_key','expired-intro-photo-denied'));
  perform pg_temp.trial_refuses(format(
    'select public.reserve_upload_assets(%L,%L::jsonb)',f.actor,spec),
    'RP402: Photo uploads start after the free week',
    'expired Apple intro cannot reserve a new photo');
  perform pg_temp.trial_refuses(format(
    'select public.serving_envelope_admit(%L,1,%L)',f.org,'expired-apple-edit'),
    'RP402: AI usage limit reached',
    'expired Apple intro cannot reserve paid supplier work');
  spec:=jsonb_build_array(jsonb_build_object(
    'id',ticket,'listing_id',f.listing,'kind','video','bucket','renders',
    'storage_key','renders/'||f.org||'/'||f.listing||'/'||ticket||'.mp4',
    'bytes',10485760,'content_type','video/mp4','content_type_declared',true,
    'idem_key','paid-expired-website-video'));
  perform pg_temp.trial_ok(jsonb_array_length(public.reserve_upload_assets(f.actor,spec))=1,
    'exact paid website credit can still upload its video after intro expiry');
end$$;
reset role;

update public.apple_subscriptions set status='grace',
  expires_at=now()+interval '27 days'
where org_id=(select org from trial_oneoff_fixture);
update public.orgs set plan_expires_at=now()+interval '27 days'
where id=(select org from trial_oneoff_fixture);
select pg_temp.trial_ok((select (public.org_entitlement(org)).plan='starter'
  and (public.org_entitlement(org)).photo_edits_per_month=0
  and (public.org_entitlement(org)).renders_per_month=0
  and (public.org_entitlement(org)).cogs_ceiling_cents=0
  and public.plan_serving_ceiling(org)->>'kind'='grace'
  and (public.plan_serving_ceiling(org)->>'ceiling_cents')::integer=0
  from trial_oneoff_fixture),
  'unfunded Apple grace keeps SKU but cannot advertise paid creative use');
select pg_temp.trial_refuses($q$insert into public.listings(org_id,agent_id,address)
  select org,actor,'Unfunded grace extra draft' from trial_oneoff_fixture$q$,
  'RP402: Listing creation starts after the free week',
  'unfunded Apple grace cannot prepare a new listing');
set local role service_role;
do $$declare f record;spec jsonb;ticket uuid:=gen_random_uuid();begin
  select * into f from trial_oneoff_fixture;
  spec:=jsonb_build_array(jsonb_build_object(
    'id',ticket,'listing_id',f.listing,'kind','photo','bucket','renders',
    'storage_key','renders/'||f.org||'/'||f.listing||'/gallery-'||ticket||'.jpg',
    'bytes',8388608,'content_type','image/jpeg','content_type_declared',true,
    'idem_key','grace-photo-denied'));
  perform pg_temp.trial_refuses(format(
    'select public.reserve_upload_assets(%L,%L::jsonb)',f.actor,spec),
    'RP402: Photo uploads start after the free week',
    'unfunded Apple grace cannot reserve a new photo');
end$$;
reset role;

do $$declare actor uuid;apple_org uuid;second_listing uuid;paid public.plan_entitlements;r jsonb;h text:=repeat('a',64);begin
  select f.actor,f.org,f.listing into actor,apple_org,second_listing from trial_renewal_fixture f;

  -- Renewed paid term: same org, same subscription and old ledger, only the
  -- signed current transaction dates change. Full purchased quotas return.
  update public.apple_subscriptions set
    status='active',
    expires_at=now()+interval '29 days'
  where org_id=apple_org;
  update public.apple_subscriptions set
    transaction_purchased_at=now(),transaction_signed_at=now()
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

set local role service_role;
do $$declare f record;operation uuid:=gen_random_uuid();result jsonb;begin
  select * into f from trial_renewal_fixture;
  result:=public.prepare_org_brand_logo(f.actor,f.org,operation,null,100,
    'image/png',repeat('a',64),
    'https://cdn.fixture.invalid/renders/'||f.org||'/brand/'||operation||'.png');
  perform pg_temp.trial_ok((result->>'dispatch')::boolean and exists(
    select 1 from public.upload_reservations r
    where r.asset_id=operation and r.org_id=f.org and r.listing_id=f.org
      and r.spec->>'role'='business_logo' and r.state='cancelled'),
    'paid business-logo sentinel reservation bypasses listing-photo guard');
end$$;
reset role;

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
  'RP402: Unpaid access includes one listing',
  'second private Team library cannot create another trial listing');

-- The parent Team binding can disappear on downgrade. A paid job in a child's
-- second listing retains its admission-time parent payer and content identity,
-- so completing it must not re-resolve to the now-Free child billing org.
do $$declare f record;app_job uuid;worker_job uuid;begin
  select * into f from trial_team_fixture;
  update public.apple_subscriptions set transaction_purchased_at=now(),
    transaction_signed_at=now(),expires_at=now()+interval '29 days'
    where org_id=f.team_org;
  update public.orgs set plan_expires_at=now()+interval '29 days'
    where id=f.team_org;
  perform pg_temp.trial_ok(public.library_billing_org(f.second_org)=f.team_org
    and public.plan_serving_ceiling(f.team_org)->>'kind'='retail',
    'renewed Team binds the second private library to its paid parent');
  insert into public.listings(id,org_id,agent_id,address)
    values(f.second_listing,f.second_org,f.agent_two,'Paid Team second library listing');
  insert into public.render_jobs(listing_id,billing_org_id,source)
    values(f.second_listing,f.team_org,'app') returning id into app_job;
  insert into public.render_jobs(listing_id,billing_org_id,source)
    values(f.second_listing,f.team_org,'worker') returning id into worker_job;
  update public.render_jobs set status='processing',started_at=now()
    where id=worker_job;
  perform pg_temp.trial_ok((select billing_org_id=f.team_org and content_org_id=f.second_org
    from public.trial_intro_render_admissions where job_id=app_job),
    'private library admission freezes its parent payer and child content identity');
  update public.orgs set plan='free',plan_source=null,plan_expires_at=null
    where id=f.team_org;
  perform pg_temp.trial_ok(public.library_billing_org(f.second_org)=f.second_org,
    'Team downgrade revokes the live child-to-parent billing binding');
  insert into public.renders(job_id,listing_id,slug,duration_s,speed_factor,published_at)
    values(app_job,f.second_listing,'team-prior-paid-app-'||app_job::text,8,2,now());
  insert into public.renders(job_id,listing_id,slug,duration_s,speed_factor,published_at)
    values(worker_job,f.second_listing,'team-prior-paid-worker-'||worker_job::text,8,2,now());
  perform pg_temp.trial_ok((select count(*)=2 from public.renders
    where job_id in(app_job,worker_job)),
    'paid Team child app and cost-admitted worker complete after parent downgrade');
  perform pg_temp.trial_refuses(format(
    'insert into public.render_jobs(listing_id,source) values(%L,''app'')',f.second_listing),
    'RP402: Video and public website creation start after payment',
    'downgraded Team child cannot start another app video');
end$$;

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
  'RP402: Unpaid access includes one listing',
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
select pg_temp.trial_refuses($q$insert into public.listings(id,org_id,agent_id,address)
  select second_listing,org,actor,'Expired-intro second draft'
  from trial_funded_fixture$q$,
  'RP402: Listing creation starts after the free week',
  'expired introductory account cannot create a second free draft');

-- A fresh Free account has no new-listing allowance. An active trial can
-- prepare one draft, reserve its photos, and replay those tickets after its
-- free week expires; the saved draft remains readable.
insert into auth.users(id,email,is_anonymous) values
  ('a9030001-0000-4000-8000-000000000002','limited-new-free@example.invalid',false);
select pg_temp.trial_refuses($q$insert into public.listings(org_id,agent_id,address)
  select org_id,user_id,'Free account first draft' from public.memberships
  where user_id='a9030001-0000-4000-8000-000000000002' and role='owner'$q$,
  'RP402: Listing creation starts after the free week',
  'fresh Free account cannot prepare even its first listing');
insert into auth.users(id,email,is_anonymous) values
  ('a9030001-0000-4000-8000-000000000001','limited-free-account@example.invalid',false);
create temporary table trial_free_fixture as select
  'a9030001-0000-4000-8000-000000000001'::uuid actor,
  (select org_id from public.memberships
    where user_id='a9030001-0000-4000-8000-000000000001' and role='owner' limit 1)org,
  gen_random_uuid()first_listing,gen_random_uuid()second_listing;
grant select on trial_free_fixture to service_role;
update public.orgs set plan='trial',plan_source='trial',trial_ends_at=now()+interval '7 days'
where id=(select org from trial_free_fixture);
insert into public.listings(id,org_id,agent_id,address)
  select first_listing,org,actor,'Saved introductory draft' from trial_free_fixture;
select pg_temp.trial_ok((select count(*)=1 from public.workspace_publication_slots s
  join trial_free_fixture f on s.org_id=f.org and s.listing_id=f.first_listing),
  'introductory account reserves its single lifetime listing slot at draft creation');
select pg_temp.trial_refuses($q$insert into public.listings(id,org_id,agent_id,address)
  select second_listing,org,actor,'Trial second draft' from trial_free_fixture$q$,
  'RP402: Unpaid access includes one listing',
  'introductory account cannot prepare a second lifetime listing');
create temporary table trial_free_photo_specs(photos jsonb);
grant select,insert on trial_free_photo_specs to service_role;
set local role service_role;
do $$declare f record;photos jsonb;r jsonb;begin
  select * into f from trial_free_fixture;
  select jsonb_agg(jsonb_build_object(
    'id',a.id,'listing_id',f.first_listing,'kind','photo','bucket','renders',
    'storage_key','renders/'||f.org||'/'||f.first_listing||'/gallery-'||a.id||'.jpg',
    'bytes',8388608,'content_type','image/jpeg','content_type_declared',true,
    'idem_key','free-photo-'||a.n) order by a.n) into photos
  from (select gen_random_uuid()id,n from generate_series(1,40)n)a;
  insert into trial_free_photo_specs values(photos);
  r:=public.reserve_upload_assets(f.actor,photos);
  perform pg_temp.trial_ok(jsonb_array_length(r)=40 and
    (select count(*)=40 and sum(held_bytes)=671088640
      from public.upload_reservations where listing_id=f.first_listing),
    'introductory listing reserves forty ordinary photos inside the 2 GiB technical cap');
  r:=public.reserve_upload_assets(f.actor,photos);
  perform pg_temp.trial_ok(jsonb_array_length(r)=40 and
    (select bool_and((x.value->>'replayed')::boolean) from jsonb_array_elements(r)x)
    and (select count(*)=40 from public.upload_reservations where listing_id=f.first_listing),
    'introductory photo ticket replay does not consume another budget');
  select jsonb_agg(jsonb_build_object(
    'id',a.id,'listing_id',f.first_listing,'kind','photo','bucket','renders',
    'storage_key','renders/'||f.org||'/'||f.first_listing||'/gallery-'||a.id||'.jpg',
    'bytes',8388608,'content_type','image/jpeg','content_type_declared',true,
    'idem_key','free-extra-photo-'||a.n) order by a.n) into photos
  from (select gen_random_uuid()id,n from generate_series(1,100)n)a;
  perform pg_temp.trial_refuses(format(
    'select public.reserve_upload_assets(%L,%L::jsonb)',f.actor,photos),
    'RP429: monthly technical upload reservation ceiling exhausted',
    'introductory week cannot reserve fresh photos beyond its 2 GiB technical cap');
  perform pg_temp.trial_ok((select count(*)=40 from public.upload_reservations
    where listing_id=f.first_listing),
    'denied over-cap batch created no partial photo tickets');
end$$;
reset role;
update public.orgs set plan='free',plan_source=null,trial_ends_at=null
where id=(select org from trial_free_fixture);
select pg_temp.trial_ok((select count(*)=1 from public.listings l
  join trial_free_fixture f on l.id=f.first_listing and l.org_id=f.org),
  'expired free week retains its saved introductory listing');
select pg_temp.trial_refuses($q$insert into public.listings(id,org_id,agent_id,address)
  select second_listing,org,actor,'Expired-intro extra draft' from trial_free_fixture$q$,
  'RP402: Listing creation starts after the free week',
  'expired free week cannot prepare another listing');
set local role service_role;
do $$declare f record;photos jsonb;r jsonb;new_photo jsonb;ticket uuid:=gen_random_uuid();
  legacy uuid:=gen_random_uuid();counterfeit uuid:=gen_random_uuid();begin
  select * into f from trial_free_fixture;
  select s.photos into photos from trial_free_photo_specs s;
  r:=public.reserve_upload_assets(f.actor,photos);
  perform pg_temp.trial_ok(jsonb_array_length(r)=40 and
    (select bool_and((x.value->>'replayed')::boolean) from jsonb_array_elements(r)x)
    and (select count(*)=40 from public.upload_reservations where listing_id=f.first_listing),
    'expired free week replays previously admitted photo tickets');
  new_photo:=jsonb_build_array(jsonb_build_object(
    'id',ticket,'listing_id',f.first_listing,'kind','photo','bucket','renders',
    'storage_key','renders/'||f.org||'/'||f.first_listing||'/gallery-'||ticket||'.jpg',
    'bytes',8388608,'content_type','image/jpeg','content_type_declared',true,
    'idem_key','free-photo-after-week-denied'));
  perform pg_temp.trial_refuses(format(
    'select public.reserve_upload_assets(%L,%L::jsonb)',f.actor,new_photo),
    'RP402: Photo uploads start after the free week',
    'expired Free account cannot reserve another source photo');
  insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,
    uploaded,transport_version,bytes)
    values(legacy,f.first_listing,'photo','uploads',
      'uploads/'||f.org||'/'||f.first_listing||'/legacy-trial-cleanup.jpg',false,1,10),
      (counterfeit,f.first_listing,'photo','uploads',
      'uploads/'||f.org||'/'||f.first_listing||'/legacy-counterfeit.jpg',false,1,10);
  r:=public.cancel_legacy_upload(legacy,f.actor);
  perform pg_temp.trial_ok((r->>'upload_aborted')::boolean and exists(
    select 1 from public.upload_reservations where asset_id=legacy
      and state='cancelled' and held_bytes=0),
    'expired Free account can cancel a previously admitted v1 upload');
  perform pg_temp.trial_refuses(format(
    'insert into public.upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes) values(%L,%L,%L,%L,current_date,%L::jsonb,1)',
    counterfeit,f.org,f.first_listing,f.actor,'{"legacy_physical_bytes":"unknown"}'),
    'RP403: Invalid legacy upload cancellation',
    'legacy cleanup marker cannot disguise a fresh positive-byte reservation');
end$$;
reset role;
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

-- A paid app job and a worker admitted to processing can finish after a
-- downgrade on a second listing. A queued worker job has not entered costed
-- work, so a later claim must recheck current payment and stop before spend.
set local role service_role;
do $$declare f record;app_job uuid;started_worker uuid;queued_worker uuid;
  bg_job uuid:=gen_random_uuid();bg_asset uuid:=gen_random_uuid();source_asset uuid:=gen_random_uuid();
  bg_render_job uuid;attempt uuid:=gen_random_uuid();lease uuid:=gen_random_uuid();
  bg_key text:='bgvideo:'||gen_random_uuid()::text;reserved jsonb;
  third_listing uuid:=gen_random_uuid();begin
  select * into f from trial_funded_fixture;
  update public.orgs set plan='starter',plan_source='manual' where id=f.org;
  insert into public.listings(id,org_id,agent_id,address)
    values(f.second_listing,f.org,f.actor,'Second listing after payment');
  perform pg_temp.trial_ok(exists(select 1 from public.listings
    where id=f.second_listing),
    'manual paid upgrade can create a second listing');
  insert into public.render_jobs(listing_id,source)
    values(f.second_listing,'app') returning id into app_job;
  insert into public.render_jobs(listing_id,source)
    values(f.second_listing,'worker') returning id into started_worker;
  update public.render_jobs set status='processing',started_at=now()
    where id=started_worker;
  insert into public.render_jobs(listing_id,source)
    values(f.second_listing,'worker') returning id into queued_worker;
  -- Paid supplier admission is frozen before the background result exists.
  -- The eventual public render job is created only when the saved output is
  -- published, so it needs a separate exact paid-attempt receipt.
  reserved:=public.app_video_cost_reserve(f.actor,f.org,bg_key,'reel','kie',
    'synthetic/background-reel',repeat('a',64),25,5,5,'{}');
  perform pg_temp.trial_ok((reserved->>'reserved')::boolean and exists(
    select 1 from public.trial_intro_paid_video_attempts a
    where a.reservation_id=(reserved->>'id')::uuid and a.content_org_id=f.org),
    'paid supplier reservation freezes background generation authority');
  perform public.app_video_cost_settle(f.actor,f.org,bg_key,'synthetic-paid-bg');
  insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,bytes,
    content_type,content_type_declared,uploaded,transport_version,sha256) values
    (source_asset,f.second_listing,'photo','uploads',
      'uploads/'||f.org||'/'||f.second_listing||'/original-'||source_asset||'.jpg',
      1000,'image/jpeg',true,true,2,repeat('b',64)),
    (bg_asset,f.second_listing,'video','renders',
      'renders/'||f.org||'/'||f.second_listing||'/background/'||bg_job||'/'||lease||'/master.mp4',
      100000,'video/mp4',true,true,2,repeat('c',64));
  insert into public.property_video_jobs(id,operation_id,actor_id,listing_id,org_id,
    library_org_id,manifest,manifest_sha256,source_count,state,consent_revision,
    output_asset_id,result) values(bg_job,gen_random_uuid(),f.actor,f.second_listing,
    f.org,f.org,'{"purpose":"listing"}'::jsonb,repeat('d',64),1,'queued',
    'property-video-jobs-v1',bg_asset,'{}'::jsonb);
  insert into public.property_video_job_sources(job_id,position,photo_id,asset_id,
    version_id,source,motion,state,attempt_id,request_key,receipt) values
    (bg_job,0,'source-photo',source_asset,'original', '{}'::jsonb,'push_in',
      'ready',attempt,bg_key,'{"request_id":"synthetic-paid-bg"}'::jsonb);
  insert into public.property_video_job_outputs(asset_id,job_id,lease_token,kind,
    storage_key,bytes,sha256,content_type,etag,state)
    select bg_asset,bg_job,lease,'video',a.storage_key,a.bytes,a.sha256,
      'video/mp4','synthetic-etag','ready' from public.capture_assets a where a.id=bg_asset;
  perform pg_temp.trial_ok(not public.trial_intro_paid_background_result(bg_asset,f.second_listing),
    'charged but unfinished background preflight is not publication authority');
  perform pg_temp.trial_ok((select work_admitted_at is not null
    from public.trial_intro_render_admissions where job_id=started_worker)
    and (select work_admitted_at is null
    from public.trial_intro_render_admissions where job_id=queued_worker),
    'only the started worker has frozen paid cost admission');
  update public.orgs set plan='free',plan_source=null where id=f.org;
  perform pg_temp.trial_ok((public.org_entitlement(f.org)).renders_per_month=0
    and (public.org_entitlement(f.org)).photo_edits_per_month=0
    and (public.org_entitlement(f.org)).cogs_ceiling_cents=0
    and (public.plan_serving_ceiling(f.org)->>'ceiling_cents')::numeric=0,
    'downgraded Free /me and wallet offer no new AI work');
  perform pg_temp.trial_refuses(format(
    'select public.serving_envelope_admit(%L,1,%L)',f.org,'downgraded-photo-edit'),
    'RP402: AI usage limit reached',
    'downgraded former subscriber cannot start a new paid photo edit');
  perform pg_temp.trial_refuses(format(
    'insert into public.listings(id,org_id,agent_id,address) values(%L,%L,%L,''Third unpaid listing'')',
    third_listing,f.org,f.actor),
    'RP402: Listing creation starts after the free week',
    'downgraded account cannot create another free listing');
  perform pg_temp.trial_refuses(format(
    'insert into public.render_jobs(listing_id,capture_asset_id,source) values(%L,%L,''app'')',
    f.second_listing,bg_asset),
    'RP402: Video and public website creation start after payment',
    'paid supplier receipt alone does not publish an unfinished background video');
  update public.property_video_jobs set state='ready' where id=bg_job;
  perform pg_temp.trial_ok(public.trial_intro_paid_background_result(bg_asset,f.second_listing),
    'exact ready output and settled paid supplier receipt authorize late publication');
  insert into public.render_jobs(listing_id,capture_asset_id,source)
    values(f.second_listing,bg_asset,'app') returning id into bg_render_job;
  insert into public.renders(job_id,listing_id,slug,duration_s,speed_factor,published_at)
    values(bg_render_job,f.second_listing,'prior-paid-background-'||bg_render_job::text,8,2,now());
  perform pg_temp.trial_ok(exists(select 1 from public.renders where job_id=bg_render_job),
    'ready paid background video publishes after downgrade on second listing');
  perform pg_temp.trial_refuses(format(
    'update public.render_jobs set status=''processing'',started_at=now() where id=%L',
    queued_worker),
    'RP402: A queued render needs paid service before processing',
    'paid preflight-only worker cannot start costed work after downgrade');
  perform pg_temp.trial_refuses(format(
    'insert into public.renders(job_id,listing_id,slug,duration_s,speed_factor,published_at) values(%L,%L,%L,8,2,now())',
    queued_worker,f.second_listing,'queued-'||queued_worker::text),
    'RP402: Video completion needs a paid admission',
    'queued preflight-only job cannot publish after downgrade');
  insert into public.renders(job_id,listing_id,slug,duration_s,speed_factor,published_at)
    values(app_job,f.second_listing,'prior-paid-app-'||app_job::text,8,2,now());
  perform pg_temp.trial_ok(exists(select 1 from public.renders where job_id=app_job),
    'previously admitted paid app video on second listing completes after downgrade');
  insert into public.renders(job_id,listing_id,slug,duration_s,speed_factor,published_at)
    values(started_worker,f.second_listing,'prior-paid-worker-'||started_worker::text,8,2,now());
  perform pg_temp.trial_ok(exists(select 1 from public.renders where job_id=started_worker),
    'paid cost-admitted worker on second listing completes after downgrade');
  perform pg_temp.trial_refuses(format(
    'insert into public.render_jobs(listing_id,source) values(%L,''app'')',f.second_listing),
    'RP402: Video and public website creation start after payment',
    'downgrade does not admit another app publication job');
end$$;
reset role;

select jsonb_build_object('passed',true,'assertions',(select n from trial_checks));
rollback;
