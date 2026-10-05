\set ON_ERROR_STOP on
begin;
do $$begin
 if current_database()<>'rendprop_testing_grant' or inet_server_addr() is not null then
  raise exception 'Use only the owned socket-only testing-grant fixture';
 end if;
end $$;
create temp table testing_checks(label text primary key,passed boolean not null);
create function pg_temp.testing_ok(label text,value boolean)returns void language plpgsql security definer as $$begin
 if value is distinct from true then raise exception 'TESTING GRANT FAIL: %',label;end if;
 insert into pg_temp.testing_checks values(label,true);
end $$;
create function pg_temp.testing_denied(label text,command text,prefix text)returns void language plpgsql as $$declare message text;begin
 begin execute command;exception when others then message:=sqlerrm;end;
 perform pg_temp.testing_ok(label,message like prefix||'%');
end $$;
create temp table testing_fixture(owner_id uuid,member_id uuid,extra_id uuid,outsider_id uuid,org_id uuid,ordinary_org uuid,listing_id uuid,asset_id uuid,job_id uuid);
insert into auth.users(id,email,is_anonymous) values
 ('cb100505-0000-4000-8000-000000000001','testing-owner@fixture.invalid',false),
 ('cb100505-0000-4000-8000-000000000002','testing-member@fixture.invalid',false),
 ('cb100505-0000-4000-8000-000000000003','testing-extra@fixture.invalid',false),
 ('cb100505-0000-4000-8000-000000000004','testing-outsider@fixture.invalid',false);
insert into testing_fixture select
 'cb100505-0000-4000-8000-000000000001','cb100505-0000-4000-8000-000000000002',
 'cb100505-0000-4000-8000-000000000003','cb100505-0000-4000-8000-000000000004',
 (select org_id from memberships where user_id='cb100505-0000-4000-8000-000000000001'),
 (select org_id from memberships where user_id='cb100505-0000-4000-8000-000000000004'),
 'cb100505-0000-4000-8000-000000000011','cb100505-0000-4000-8000-000000000012','cb100505-0000-4000-8000-000000000013';
-- Synthetic IDs only; anon must reach the intentional helper-ACL probe.
grant select on testing_fixture to anon,authenticated,service_role;
update orgs set plan='team',plan_source='manual' where id in(select org_id from testing_fixture union select ordinary_org from testing_fixture);
update profiles set is_admin=true where id=(select owner_id from testing_fixture);
insert into memberships(user_id,org_id,role) select member_id,org_id,'agent'from testing_fixture;
insert into listings(id,org_id,agent_id,address)select listing_id,org_id,owner_id,'Synthetic testing property'from testing_fixture;
insert into capture_assets(id,listing_id,kind,storage_key,uploaded)select asset_id,listing_id,'video','synthetic/testing-capture.mp4',true from testing_fixture;
insert into render_jobs(listing_id,capture_asset_id,status,source)
 select listing_id,asset_id,'failed','worker'from testing_fixture cross join generate_series(1,25);
insert into render_jobs(id,listing_id,capture_asset_id,status,source)select job_id,listing_id,asset_id,'failed','app'from testing_fixture;
create temp table retail_snapshot as select
 (select jsonb_agg(to_jsonb(p)order by p.plan)from plan_entitlements p)plans,
 (select jsonb_agg(to_jsonb(o)order by o.plan,o.space_type)from plan_entitlement_overrides o)overrides;
select pg_temp.testing_ok('grant starts empty',not exists(select 1 from org_internal_testing_grants));
select pg_temp.testing_ok('private grant RLS has no client policies',(select relrowsecurity from pg_class where oid='org_internal_testing_grants'::regclass)and not exists(select 1 from pg_policy where polrelid='org_internal_testing_grants'::regclass));
select pg_temp.testing_ok('private grant denies all client privileges '||r,not has_table_privilege(r,'org_internal_testing_grants','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'))from unnest(array['anon','authenticated'])r;
select pg_temp.testing_ok('helper is pinned and not public',(select prosecdef and proconfig=array['search_path=""']and not has_function_privilege('anon',oid,'execute')from pg_proc where oid='org_has_internal_testing_grant(uuid)'::regprocedure));
set local role service_role;
select pg_temp.testing_ok('ordinary manual Team has exact standard allowances',(select plan='team'and renders_per_month=25 and photo_edits_per_month=400 and reels_per_month=25 and aerials_per_month=8 and topaz_per_month=2 and seats=2 and cogs_ceiling_cents=6000 and price_cents=24900 from org_entitlement(org_id)))from testing_fixture;
select pg_temp.testing_ok('ordinary Team has two seats',org_seats_allowed(org_id)=2 and org_seats_used(org_id)=2)from testing_fixture;
select pg_temp.testing_denied('ordinary Team refuses third-seat invitation',format('select create_org_invite(%L,%L,NULL,''agent'',%L)',owner_id,org_id,repeat('a',64)),'RP402:')from testing_fixture;
select pg_temp.testing_denied('ordinary Team refuses video hold beyond monthly budget',format('select app_video_cost_reserve(%L,%L,''before-grant-budget'',''reel'',''fal'',''fixture-model'',%L,6001,1,6001,''{}'')',owner_id,org_id,repeat('a',64)),'RP402:')from testing_fixture;
reset role;
select set_config('request.jwt.claim.sub',(select owner_id::text from testing_fixture),true);
set local role authenticated;
select pg_temp.testing_denied('ordinary Team refuses twenty-sixth worker render',format('select create_render_job(%L,%L,''smooth'',''{}'',''before-grant-render'',''worker'')',listing_id,asset_id),'RP402:')from testing_fixture;
reset role;
select set_config('request.jwt.claim.sub','',true);
set local role service_role;
insert into org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances,note)select org_id,owner_id,true,'Synthetic internal testing'from testing_fixture;
select pg_temp.testing_ok('service sees explicit active authority',org_has_internal_testing_grant(org_id))from testing_fixture;
select pg_temp.testing_ok('all business allowances use Int32 compatibility projection',(select plan='team'and price_cents=24900 and renders_per_month=2147483647 and photo_edits_per_month=2147483647 and reels_per_month=2147483647 and aerials_per_month=2147483647 and topaz_per_month=2147483647 and seats=2147483647 and cogs_ceiling_cents=2147483647 from org_entitlement(org_id)))from testing_fixture;
select pg_temp.testing_ok('seat RPC projects same testing authority',org_seats_allowed(org_id)=2147483647)from testing_fixture;
select create_org_invite(owner_id,org_id,null,'agent',repeat('b',64))from testing_fixture;
select accept_org_invite(extra_id,repeat('b',64))from testing_fixture;
select pg_temp.testing_ok('third named member joins through actual atomic invite RPCs',org_seats_used(org_id)=3 and exists(select 1 from memberships where org_id=f.org_id and user_id=f.extra_id and role='agent'))from testing_fixture f;
select pg_temp.testing_denied('ordinary agent cannot invite despite testing grant',format('select create_org_invite(%L,%L,NULL,''agent'',%L)',member_id,org_id,repeat('c',64)),'RP403:')from testing_fixture;
select pg_temp.testing_ok('actual video reservation accepts spend above retail budget',(app_video_cost_reserve(owner_id,org_id,'after-grant-budget','reel','fal','fixture-model',repeat('a',64),6001,1,6001,'{}')->>'reserved')::boolean)from testing_fixture;
select pg_temp.testing_ok('actual settlement retains priced ledger',(app_video_cost_settle(owner_id,org_id,'after-grant-budget','synthetic-provider-receipt')->>'settled')::boolean)from testing_fixture;
select pg_temp.testing_denied('testing grant never redispatches identical reservation',format('select app_video_cost_reserve(%L,%L,''after-grant-budget'',''reel'',''fal'',''fixture-model'',%L,6001,1,6001,''{}'')',owner_id,org_id,repeat('a',64)),'RP409:')from testing_fixture;
select pg_temp.testing_denied('reservation technical numeric bound remains',format('select app_video_cost_reserve(%L,%L,''oversized-hold'',''reel'',''fal'',''fixture-model'',%L,100000000,1,6001,''{}'')',owner_id,org_id,repeat('a',64)),'RP400:')from testing_fixture;
select pg_temp.testing_ok('actual ledger admits spend above retail ceiling',log_job_cost(job_id,org_id,'synthetic_cost','fixture','fixture-model',1,7000,'{}',8000)=7000)from testing_fixture;
select pg_temp.testing_denied('per-job cost ceiling remains enforced',format('select log_job_cost(%L,%L,''synthetic_cost'',''fixture'',''fixture-model'',1,1001,''{}'',8000)',job_id,org_id),'RP402:')from testing_fixture;
select pg_temp.testing_ok('ledger remains auditable',org_month_spend_cents(org_id)=13001)from testing_fixture;
reset role;
select set_config('request.jwt.claim.sub',(select member_id::text from testing_fixture),true);
set local role authenticated;
-- /me reads invoker entitlement with service_role. Do not manufacture client
-- SELECT on the pre-existing private brokerage table to test that path.
select pg_temp.testing_ok('verified member sees testing authority',org_has_internal_testing_grant(org_id))from testing_fixture;
select create_render_job(listing_id,asset_id,'smooth','{}','after-grant-render-1','worker')from testing_fixture;
select create_render_job(listing_id,asset_id,'smooth','{}','after-grant-render-2','worker')from testing_fixture;
select create_render_job(listing_id,asset_id,'smooth','{}','after-grant-render-3','worker')from testing_fixture;
select pg_temp.testing_ok('actual worker render exceeds retail monthly allowance',(select count(*)=28 from render_jobs r join listings l on l.id=r.listing_id where l.org_id=f.org_id and r.source='worker'))from testing_fixture f;
select pg_temp.testing_denied('three concurrent worker render limit remains',format('select create_render_job(%L,%L,''smooth'',''{}'',''after-grant-render-4'',''worker'')',listing_id,asset_id),'RP429:')from testing_fixture;
select set_config('request.jwt.claim.sub',(select owner_id::text from testing_fixture),true);
select pg_temp.testing_denied('owner cannot directly read private grant','select * from org_internal_testing_grants','permission denied');
select pg_temp.testing_denied('owner cannot directly change private grant','update org_internal_testing_grants set revoked_at=now()','permission denied');
select pg_temp.testing_denied('owner cannot directly remove private grant','delete from org_internal_testing_grants','permission denied');
select pg_temp.testing_denied('owner cannot self-grant another workspace',format('insert into org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)values(%L,%L,true)',ordinary_org,member_id),'permission denied')from testing_fixture;
reset role;
select set_config('request.jwt.claim.sub',(select outsider_id::text from testing_fixture),true);
set local role authenticated;
select pg_temp.testing_ok('foreign authenticated caller never receives testing benefit',not org_has_internal_testing_grant(org_id))from testing_fixture;
select pg_temp.testing_denied('foreign nested render cannot borrow testing benefit',format('select create_render_job(%L,%L,''smooth'',''{}'',''foreign-grant-render'',''worker'')',listing_id,asset_id),'RP403:')from testing_fixture;
select pg_temp.testing_ok('foreign JWT cannot borrow postgres fixture session',session_user='postgres'and current_setting('role')='authenticated'and not org_has_internal_testing_grant(org_id))from testing_fixture;
reset role;
select set_config('request.jwt.claim.sub','',true);
set local role authenticated;
select pg_temp.testing_ok('authenticated role without user receives no grant',not org_has_internal_testing_grant(org_id))from testing_fixture;
reset role;
set local role anon;
select pg_temp.testing_denied('anonymous role cannot call authority helper',format('select org_has_internal_testing_grant(%L)',org_id),'permission denied')from testing_fixture;
reset role;
-- Each independently removed authority must immediately return retail limits.
update org_internal_testing_grants set revoked_at=now();
select pg_temp.testing_ok('revoked authority returns retail limits',(org_entitlement(org_id)).seats=2 and not org_has_internal_testing_grant(org_id))from testing_fixture;
update org_internal_testing_grants set revoked_at=null,starts_at=now()-interval '2 hours',expires_at=now()-interval '1 hour';
select pg_temp.testing_ok('expired authority returns retail limits',(org_entitlement(org_id)).seats=2 and not org_has_internal_testing_grant(org_id))from testing_fixture;
update org_internal_testing_grants set starts_at=now()+interval '1 hour',expires_at=null;
select pg_temp.testing_ok('future authority returns retail limits',not org_has_internal_testing_grant(org_id))from testing_fixture;
update org_internal_testing_grants set starts_at=now(),unmetered_business_allowances=false;
select pg_temp.testing_ok('explicit disabled grant has no benefit',not org_has_internal_testing_grant(org_id))from testing_fixture;
update org_internal_testing_grants set unmetered_business_allowances=true;
update profiles set is_admin=false where id=(select owner_id from testing_fixture);
select pg_temp.testing_ok('product admin removal disables authority',not org_has_internal_testing_grant(org_id))from testing_fixture;
update profiles set is_admin=true where id=(select owner_id from testing_fixture);
update memberships set role='admin'where org_id=(select org_id from testing_fixture)and user_id=(select owner_id from testing_fixture);
select pg_temp.testing_ok('workspace owner role removal disables authority',not org_has_internal_testing_grant(org_id))from testing_fixture;
delete from memberships where org_id=(select org_id from testing_fixture)and user_id=(select owner_id from testing_fixture);
select pg_temp.testing_ok('owner membership loss disables authority',not org_has_internal_testing_grant(org_id))from testing_fixture;
insert into memberships(user_id,org_id,role)select owner_id,org_id,'owner'from testing_fixture;
update auth.users set is_anonymous=true where id=(select owner_id from testing_fixture);
select pg_temp.testing_ok('anonymous identity cannot own testing authority',not org_has_internal_testing_grant(org_id))from testing_fixture;
update auth.users set is_anonymous=false where id=(select owner_id from testing_fixture);
insert into deletion_requests(user_id,status)select owner_id,'pending'from testing_fixture;
select pg_temp.testing_ok('pending owner deletion disables authority',not org_has_internal_testing_grant(org_id))from testing_fixture;
update deletion_requests set status='processing'where user_id=(select owner_id from testing_fixture);
select pg_temp.testing_ok('processing owner deletion disables authority',not org_has_internal_testing_grant(org_id))from testing_fixture;
delete from deletion_requests where user_id=(select owner_id from testing_fixture);
update orgs set deleted_at=now()where id=(select org_id from testing_fixture);
select pg_temp.testing_ok('deleted workspace disables authority',not org_has_internal_testing_grant(org_id))from testing_fixture;
update orgs set deleted_at=null,plan_source='apple',plan_expires_at=now()+interval '30 days'where id=(select org_id from testing_fixture);
select pg_temp.testing_ok('nonmanual Team disables authority',not org_has_internal_testing_grant(org_id))from testing_fixture;
update orgs set plan_source='manual',plan='pro'where id=(select org_id from testing_fixture);
select pg_temp.testing_ok('nonTeam manual plan disables authority',not org_has_internal_testing_grant(org_id))from testing_fixture;
update orgs set plan='team'where id=(select org_id from testing_fixture);
insert into brokerage_contracts(org_id,seats,price_cents_per_seat)select org_id,10,14900 from testing_fixture;
select pg_temp.testing_ok('active contract takes precedence over stale manual Team',(org_entitlement(org_id)).plan='brokerage'and(org_entitlement(org_id)).seats=10 and org_seats_allowed(org_id)=10 and not org_has_internal_testing_grant(org_id))from testing_fixture;
select set_config('request.jwt.claim.sub',(select owner_id::text from testing_fixture),true);
set local role authenticated;
-- Real authenticated caller-owned temp tables, with fresh cached resolution.
-- Their presence must not remove the actual qualified contract boundary.
create temp table brokerage_contracts(org_id uuid,status text,starts_at timestamptz,ends_at timestamptz);
create temp table orgs(id uuid,plan text,plan_source text,trial_ends_at timestamptz,plan_expires_at timestamptz);
insert into pg_temp.orgs(id,plan,plan_source)select org_id,'team','manual'from testing_fixture;
discard plans;
select pg_temp.testing_ok('authority ignores authenticated caller temp-shadowed contract',not public.org_has_internal_testing_grant(org_id))from testing_fixture;
drop table pg_temp.orgs,pg_temp.brokerage_contracts;
reset role;
select set_config('request.jwt.claim.sub','',true);
update brokerage_contracts set status='suspended'where org_id=(select org_id from testing_fixture);
select pg_temp.testing_ok('inactive contract does not block valid testing authority',org_has_internal_testing_grant(org_id))from testing_fixture;
update brokerage_contracts set status='active',starts_at=now()-interval '2 hours',ends_at=now()-interval '1 hour'where org_id=(select org_id from testing_fixture);
select pg_temp.testing_ok('expired contract does not block valid testing authority',org_has_internal_testing_grant(org_id))from testing_fixture;
set local role service_role;
select pg_temp.testing_denied('grant identity is immutable',format('update org_internal_testing_grants set org_id=%L',ordinary_org),'RP400:')from testing_fixture;
update org_internal_testing_grants set revoked_at=now();
select pg_temp.testing_denied('revoked grant refuses further oversubscribed invitation',format('select create_org_invite(%L,%L,NULL,''agent'',%L)',owner_id,org_id,repeat('c',64)),'RP402:')from testing_fixture;
select pg_temp.testing_denied('revoked grant refuses new paid reservation over retail budget',format('select app_video_cost_reserve(%L,%L,''revoked-grant-budget'',''reel'',''fal'',''fixture-model'',%L,1,1,1,''{}'')',owner_id,org_id,repeat('a',64)),'RP402:')from testing_fixture;
reset role;
select pg_temp.testing_ok('ungranted ordinary Team remains unchanged',(org_entitlement(ordinary_org)).seats=2 and(org_entitlement(ordinary_org)).cogs_ceiling_cents=6000 and not org_has_internal_testing_grant(ordinary_org))from testing_fixture;
select pg_temp.testing_ok('all retail plans and industry overrides remain unchanged',plans=(select jsonb_agg(to_jsonb(p)order by p.plan)from plan_entitlements p)and overrides=(select jsonb_agg(to_jsonb(o)order by o.plan,o.space_type)from plan_entitlement_overrides o))from retail_snapshot;
select count(*)as testing_grant_assertions from testing_checks;
select 'PASS: internal testing grant SQL assertions; all fixtures rolled back.';
rollback;
