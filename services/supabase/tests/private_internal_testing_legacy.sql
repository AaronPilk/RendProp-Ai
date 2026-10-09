-- Historical 2026-10-05 authorization fixture. Used only before the explicit
-- Team-owner content-grant migration; it is not a current launch oracle.
\set ON_ERROR_STOP on
begin;
do $$begin
 if current_database()<>'rendprop_private_testing' or inet_server_addr()is not null then raise exception 'Owned socket-only private testing fixture required';end if;
end$$;
create temp table private_checks(label text primary key,passed boolean not null);
create function pg_temp.private_ok(label text,value boolean)returns void language plpgsql security definer as $$begin
 if value is distinct from true then raise exception 'PRIVATE TESTING FAIL: %',label;end if;
 insert into pg_temp.private_checks values(label,true);
end$$;
create function pg_temp.private_denied(label text,command text,prefix text)returns void language plpgsql as $$declare message text;begin
 begin execute command;exception when others then message:=sqlerrm;end;
 perform pg_temp.private_ok(label,message like prefix||'%');
end$$;
create temp table private_fixture(host uuid,benef uuid,third uuid,foreign_user uuid,guest uuid,retail_user uuid,
 host_org uuid,private_org uuid,empty_org uuid,third_org uuid,foreign_org uuid,retail_org uuid,
 host_listing uuid,private_listing uuid,asset uuid,job uuid,receipt jsonb,raw_private jsonb,raw_profile jsonb);
insert into auth.users(id,email,is_anonymous)values
 ('cb100508-0000-4000-8000-000000000001','private-host@fixture.invalid',false),
 ('cb100508-0000-4000-8000-000000000002','private-benef@fixture.invalid',false),
 ('cb100508-0000-4000-8000-000000000003','private-third@fixture.invalid',false),
 ('cb100508-0000-4000-8000-000000000004','private-foreign@fixture.invalid',false),
 ('cb100508-0000-4000-8000-000000000005','private-guest@fixture.invalid',true),
 ('cb100508-0000-4000-8000-000000000006','private-retail@fixture.invalid',false);
insert into private_fixture select
 'cb100508-0000-4000-8000-000000000001','cb100508-0000-4000-8000-000000000002',
 'cb100508-0000-4000-8000-000000000003','cb100508-0000-4000-8000-000000000004',
 'cb100508-0000-4000-8000-000000000005','cb100508-0000-4000-8000-000000000006',
 (select org_id from memberships where user_id='cb100508-0000-4000-8000-000000000001'),
 (select org_id from memberships where user_id='cb100508-0000-4000-8000-000000000002'),
 'cb100508-0000-4000-8000-000000000021',
 (select org_id from memberships where user_id='cb100508-0000-4000-8000-000000000003'),
 (select org_id from memberships where user_id='cb100508-0000-4000-8000-000000000004'),
 (select org_id from memberships where user_id='cb100508-0000-4000-8000-000000000006'),
 'cb100508-0000-4000-8000-000000000011','cb100508-0000-4000-8000-000000000012',
 'cb100508-0000-4000-8000-000000000013','cb100508-0000-4000-8000-000000000014',null,null,null;
grant select on private_fixture to anon,authenticated,service_role;
insert into orgs(id,name,plan,plan_source)select empty_org,'Empty preserved workspace','trial','trial'from private_fixture;
insert into memberships(user_id,org_id,role)select benef,empty_org,'owner'from private_fixture;
insert into user_workspace_state(user_id,active_org_id)select benef,empty_org from private_fixture;
update orgs set plan='team',plan_source='manual'where id in(select host_org from private_fixture union select retail_org from private_fixture);
update orgs set plan='trial',plan_source='trial',trial_ends_at=now()-interval '1 day'where id=(select private_org from private_fixture);
update profiles set is_admin=true where id=(select host from private_fixture);
insert into memberships(user_id,org_id,role)select benef,host_org,'agent'from private_fixture;
insert into memberships(user_id,org_id,role)select foreign_user,host_org,'admin'from private_fixture;
insert into listings(id,org_id,agent_id,address)select host_listing,host_org,host,'Host private house'from private_fixture
 union all select private_listing,private_org,benef,'Beneficiary private house'from private_fixture;
insert into capture_assets(id,listing_id,kind,storage_key,uploaded)select asset,private_listing,'video','synthetic/private-capture.mp4',true from private_fixture;
insert into leads(org_id,listing_id,name)select host_org,host_listing,'Synthetic host inquiry'from private_fixture
 union all select private_org,private_listing,'Synthetic own inquiry'from private_fixture;
insert into render_jobs(listing_id,capture_asset_id,status,source)select private_listing,asset,'failed','worker'from private_fixture cross join generate_series(1,25);
insert into render_jobs(id,listing_id,capture_asset_id,status,source)select job,private_listing,asset,'failed','app'from private_fixture;
update private_fixture f set raw_private=to_jsonb(o),raw_profile=to_jsonb(p)from orgs o,profiles p where o.id=f.private_org and p.id=f.benef;
select pg_temp.private_ok('service-only tables deny client DML '||r||' '||t,not has_table_privilege(r,t,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'))from unnest(array['anon','authenticated'])r cross join unnest(array['private_internal_testing_hosts','private_internal_testing_sponsorships'])t;
select pg_temp.private_ok('service-only tables have RLS and no policies '||t,(select relrowsecurity from pg_class where oid=t::regclass)and not exists(select 1 from pg_policy where polrelid=t::regclass))from unnest(array['private_internal_testing_hosts','private_internal_testing_sponsorships'])t;
select pg_temp.private_ok('every private RPC pinned and service-only '||p.oid::regprocedure,p.prosecdef and p.proconfig=array['search_path=""']and not has_function_privilege('authenticated',p.oid,'execute')and not has_function_privilege('anon',p.oid,'execute'))from pg_proc p where p.oid in('private_internal_testing_master_owner(uuid)'::regprocedure,'private_internal_testing_context(uuid,uuid)'::regprocedure,'private_internal_testing_host_mode(uuid,uuid)'::regprocedure,'private_internal_testing_members(uuid,uuid)'::regprocedure,'enroll_private_internal_tester(uuid,uuid,uuid,uuid)'::regprocedure,'accept_private_internal_test_invite(uuid,text)'::regprocedure,'remove_private_internal_tester(uuid,uuid,uuid)'::regprocedure);
set local role service_role;
insert into org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)select host_org,host,true from private_fixture;
select pg_temp.private_ok('configured active host mode is explicit',(private_internal_testing_host_mode(host,host_org)->>'active')::boolean and(private_internal_testing_host_mode(host,host_org)->>'access_mode')='private_testing')from private_fixture;
select pg_temp.private_denied('private host refuses admin invitations',format('select create_org_invite(%L,%L,null,''admin'',%L)',host,host_org,repeat('1',64)),'RP400:')from private_fixture;
select pg_temp.private_denied('private host refuses marketing invitations',format('select create_org_invite(%L,%L,null,''marketing'',%L)',host,host_org,repeat('2',64)),'RP400:')from private_fixture;
select create_org_invite(foreign_user,host_org,null,'agent',repeat('3',64))from private_fixture;
select pg_temp.private_ok('new invitation captures private mode',(select private_testing from org_invites where token_hash=repeat('3',64)));
select accept_org_invite(benef,repeat('3',64))from private_fixture;
reset role;
delete from memberships where org_id=(select host_org from private_fixture)and user_id=(select foreign_user from private_fixture);
update private_fixture set receipt=(select private_testing_receipt from org_invites where token_hash=repeat('3',64));
select pg_temp.private_ok('old accept contract routes own org and owner role',receipt->>'org_id'=private_org::text and receipt->>'org_name'=(select name from orgs where id=private_org)and receipt->>'role'='owner'and receipt->>'team_name'=(select name from orgs where id=host_org)and receipt->>'access_mode'='private_testing')from private_fixture;
select pg_temp.private_ok('content workspace preferred over empty default',(select active_org_id=f.private_org from user_workspace_state where user_id=f.benef)and exists(select 1 from orgs where id=f.empty_org))from private_fixture f;
select pg_temp.private_ok('no shared content membership or admin promotion',not exists(select 1 from memberships where org_id=f.host_org and user_id=f.benef)and not(select is_admin from profiles where id=f.benef))from private_fixture f;
select pg_temp.private_ok('raw plan binding and own identity are untouched',raw_private=(select to_jsonb(o)from orgs o where id=private_org)and raw_profile=(select to_jsonb(p)from profiles p where id=benef))from private_fixture;
set local role service_role;
select pg_temp.private_ok('beneficiary allowance has Team max business but one seat',(select plan='team'and seats=1 and renders_per_month=2147483647 and photo_edits_per_month=2147483647 and reels_per_month=2147483647 and aerials_per_month=2147483647 and topaz_per_month=2147483647 and cogs_ceiling_cents=2147483647 and price_cents=0 from org_entitlement(private_org))and org_seats_allowed(private_org)=1)from private_fixture;
select pg_temp.private_ok('host seat ledger includes private allocation',org_seats_used(host_org)=2 and org_seats_allowed(host_org)=2147483647)from private_fixture;
select pg_temp.private_ok('safe context uses exact beneficiary binding',private_internal_testing_context(benef,private_org)->>'sponsor_org_id'=host_org::text and private_internal_testing_context(foreign_user,private_org)is null and private_internal_testing_context(benef,foreign_org)is null)from private_fixture;
select pg_temp.private_ok('roster exposes no private workspace or content',jsonb_array_length(private_internal_testing_members(host,host_org))=1 and not(private_internal_testing_members(host,host_org)->0?'private_org_id')and(private_internal_testing_members(host,host_org)->0->>'access_mode')='private_testing')from private_fixture;
select pg_temp.private_denied('beneficiary cannot inspect host roster',format('select private_internal_testing_members(%L,%L)',benef,host_org),'RP403:')from private_fixture;
select pg_temp.private_denied('ordinary agent cannot allocate sponsorship',format('select enroll_private_internal_tester(%L,%L,%L,%L)',benef,host_org,third,third_org),'RP403:')from private_fixture;
select pg_temp.private_denied('allocation rejects a foreign private workspace',format('select enroll_private_internal_tester(%L,%L,%L,%L)',host,host_org,benef,foreign_org),'RP409:')from private_fixture;
select pg_temp.private_denied('allocation rejects an anonymous beneficiary',format('select enroll_private_internal_tester(%L,%L,%L,null)',host,host_org,guest),'RP403:')from private_fixture;
select pg_temp.private_denied('anonymous cannot accept private seat',format('select accept_org_invite(%L,%L)',guest,repeat('3',64)),'RP403:')from private_fixture;
select pg_temp.private_denied('foreign user cannot replay accepted private code',format('select accept_org_invite(%L,%L)',foreign_user,repeat('3',64)),'RP404:')from private_fixture;
select pg_temp.private_denied('private single-seat org cannot invite another',format('select create_org_invite(%L,%L,null,''agent'',%L)',benef,private_org,repeat('4',64)),'RP402:')from private_fixture;
select pg_temp.private_denied('accepted private receipt cannot be retargeted',format('update org_invites set accepted_private_org_id=%L where token_hash=%L',foreign_org,repeat('3',64)),'RP400:')from private_fixture;
select pg_temp.private_denied('accepted private receipt cannot be erased early',format('update org_invites set accepted_private_org_id=null where token_hash=%L',repeat('3',64)),'RP400:')from private_fixture;
select pg_temp.private_denied('accepted private receipt cannot be rewritten','update org_invites set private_testing_receipt=''{}''where token_hash=repeat(''3'',64)','RP400:');
select pg_temp.private_denied('private invite cannot revert to shared','update org_invites set private_testing=false where token_hash=repeat(''3'',64)','RP400:');
select pg_temp.private_ok('paid video hold above retail uses private ledger',(app_video_cost_reserve(benef,private_org,'private-budget-hold','reel','fal','fixture-model',repeat('a',64),6001,1,6001,'{}')->>'reserved')::boolean)from private_fixture;
select pg_temp.private_ok('paid video settlement remains auditable',(app_video_cost_settle(benef,private_org,'private-budget-hold','synthetic-private-provider-receipt')->>'settled')::boolean and org_month_spend_cents(private_org)=6001 and org_month_spend_cents(host_org)=0)from private_fixture;
select pg_temp.private_denied('accepted hold never allows duplicate dispatch',format('select app_video_cost_reserve(%L,%L,''private-budget-hold'',''reel'',''fal'',''fixture-model'',%L,6001,1,6001,''{}'')',benef,private_org,repeat('a',64)),'RP409:')from private_fixture;
select pg_temp.private_denied('video numeric bound remains',format('select app_video_cost_reserve(%L,%L,''private-oversized-hold'',''reel'',''fal'',''fixture-model'',%L,100000000,1,1,''{}'')',benef,private_org,repeat('a',64)),'RP400:')from private_fixture;
select pg_temp.private_ok('cost writer allows testing monthly spend',log_job_cost(job,private_org,'fixture','fixture','fixture-model',1,7000,'{}',8000)=7000)from private_fixture;
select pg_temp.private_denied('per-job cost ceiling remains',format('select log_job_cost(%L,%L,''fixture'',''fixture'',''fixture-model'',1,1001,''{}'',8000)',job,private_org),'RP402:')from private_fixture;
reset role;
select set_config('request.jwt.claim.sub',(select benef::text from private_fixture),true);
set local role authenticated;
select pg_temp.private_ok('beneficiary helper works without host membership',org_has_private_internal_testing(private_org)and not org_has_internal_testing_grant(host_org))from private_fixture;
select pg_temp.private_ok('beneficiary sees only own listings through actual RLS',(select count(*)=1 from listings where id in(f.private_listing,f.host_listing)))from private_fixture f;
select pg_temp.private_ok('beneficiary sees only own inquiries through actual RLS',(select count(*)=1 from leads where org_id in(f.private_org,f.host_org)))from private_fixture f;
select create_render_job(private_listing,asset,'smooth','{}','private-render-one','worker')from private_fixture;
select create_render_job(private_listing,asset,'smooth','{}','private-render-two','worker')from private_fixture;
select create_render_job(private_listing,asset,'smooth','{}','private-render-three','worker')from private_fixture;
select pg_temp.private_ok('nested worker render exceeds retail quota',(select count(*)=28 from render_jobs where listing_id=f.private_listing and source='worker'))from private_fixture f;
select pg_temp.private_denied('worker concurrency remains three',format('select create_render_job(%L,%L,''smooth'',''{}'',''private-render-four'',''worker'')',private_listing,asset),'RP429:')from private_fixture;
select pg_temp.private_denied('beneficiary cannot call service enrollment',format('select enroll_private_internal_tester(%L,%L,%L,%L)',benef,host_org,third,third_org),'permission denied')from private_fixture;
reset role;
select set_config('request.jwt.claim.sub',(select host::text from private_fixture),true);
set local role authenticated;
select pg_temp.private_ok('host cannot borrow beneficiary private allowance',not org_has_private_internal_testing(private_org))from private_fixture;
select pg_temp.private_ok('host cannot read beneficiary houses or inquiries',(select count(*)=1 from listings where id in(f.private_listing,f.host_listing))and(select count(*)=1 from leads where org_id in(f.private_org,f.host_org)))from private_fixture f;
reset role;
select set_config('request.jwt.claim.sub','',true);
set local role service_role;
select pg_temp.private_ok('exact accepted replay returns immutable receipt',accept_org_invite(benef,repeat('3',64))=receipt)from private_fixture;
reset role;
update user_workspace_state set active_org_id=(select empty_org from private_fixture)where user_id=(select benef from private_fixture);
set local role service_role;
select accept_org_invite(benef,repeat('3',64))from private_fixture;
select pg_temp.private_ok('receipt replay does not change later workspace choice',(select active_org_id=f.empty_org from user_workspace_state where user_id=f.benef))from private_fixture f;
reset role;
update private_internal_testing_sponsorships set revoked_at=now()where beneficiary_user_id=(select benef from private_fixture);
select pg_temp.private_ok('revoked sponsorship restores raw allowance',not org_has_private_internal_testing(private_org)and(org_entitlement(private_org)).plan='free'and(org_entitlement(private_org)).reels_per_month=0 and raw_private=(select to_jsonb(o)from orgs o where id=private_org))from private_fixture;
set local role service_role;
select pg_temp.private_denied('accepted replay cannot reactivate removed sponsorship',format('select accept_org_invite(%L,%L)',benef,repeat('3',64)),'RP404:')from private_fixture;
reset role;
update private_internal_testing_sponsorships set revoked_at=null where beneficiary_user_id=(select benef from private_fixture);
update private_internal_testing_sponsorships set starts_at=now()-interval '2 hours',expires_at=now()-interval '1 hour'where beneficiary_user_id=(select benef from private_fixture);
select pg_temp.private_ok('expired sponsorship disables benefits',not org_has_private_internal_testing(private_org))from private_fixture;
update private_internal_testing_sponsorships set starts_at=now(),expires_at=null where beneficiary_user_id=(select benef from private_fixture);
update profiles set is_admin=false where id=(select host from private_fixture);
select pg_temp.private_ok('host admin revocation disables private benefit',not org_has_private_internal_testing(private_org))from private_fixture;
update profiles set is_admin=true where id=(select host from private_fixture);
update auth.users set is_anonymous=true where id=(select benef from private_fixture);
select pg_temp.private_ok('anonymous beneficiary cannot inherit benefits',not org_has_private_internal_testing(private_org))from private_fixture;
update auth.users set is_anonymous=false where id=(select benef from private_fixture);
insert into deletion_requests(user_id,status)select benef,'pending'from private_fixture;
select pg_temp.private_ok('beneficiary deletion disables private benefits',not org_has_private_internal_testing(private_org))from private_fixture;
delete from deletion_requests where user_id=(select benef from private_fixture);
update orgs set deleted_at=now()where id=(select private_org from private_fixture);
select pg_temp.private_ok('deleted private org cannot inherit benefits',not org_has_private_internal_testing(private_org))from private_fixture;
update orgs set deleted_at=null where id=(select private_org from private_fixture);
update memberships set role='agent'where org_id=(select private_org from private_fixture)and user_id=(select benef from private_fixture);
select pg_temp.private_ok('beneficiary ownership loss disables benefit',not org_has_private_internal_testing(private_org))from private_fixture;
update memberships set role='owner'where org_id=(select private_org from private_fixture)and user_id=(select benef from private_fixture);
insert into memberships(user_id,org_id,role)select third,private_org,'agent'from private_fixture;
select pg_temp.private_ok('private org sharing disables projection',not org_has_private_internal_testing(private_org))from private_fixture;
delete from memberships where user_id=(select third from private_fixture)and org_id=(select private_org from private_fixture);
insert into memberships(user_id,org_id,role)select benef,host_org,'agent'from private_fixture;
select pg_temp.private_ok('host content membership disables private status',not org_has_private_internal_testing(private_org)and jsonb_array_length(private_internal_testing_members(host,host_org))=0 and org_seats_used(host_org)=2)from private_fixture;
delete from memberships where user_id=(select benef from private_fixture)and org_id=(select host_org from private_fixture);
insert into brokerage_contracts(org_id,seats,price_cents_per_seat)select private_org,10,14900 from private_fixture;
select pg_temp.private_ok('real beneficiary contract wins',(org_entitlement(private_org)).plan='brokerage'and not org_has_private_internal_testing(private_org))from private_fixture;
delete from brokerage_contracts where org_id=(select private_org from private_fixture);
update orgs set plan='pro',plan_source='apple',plan_expires_at=now()+interval '1 month'where id=(select private_org from private_fixture);
select pg_temp.private_ok('existing Apple plan remains stored while testing',(org_entitlement(private_org)).plan='team'and(select plan_source='apple'from orgs where id=private_org))from private_fixture;
update private_internal_testing_sponsorships set revoked_at=now()where beneficiary_user_id=(select benef from private_fixture);
select pg_temp.private_ok('revocation restores original Apple entitlement',(org_entitlement(private_org)).plan='pro'and(select plan_source='apple'from orgs where id=private_org))from private_fixture;
update private_internal_testing_sponsorships set revoked_at=null where beneficiary_user_id=(select benef from private_fixture);
-- A mistaken extra master row must never turn a beneficiary into a sponsor.
update orgs set plan='team',plan_source='manual'where id=(select private_org from private_fixture);
update profiles set is_admin=true where id=(select benef from private_fixture);
insert into org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)select private_org,benef,true from private_fixture;
select pg_temp.private_ok('no sponsored org chaining',not org_has_internal_testing_grant(private_org)and private_internal_testing_master_owner(private_org)is null and org_seats_allowed(private_org)=1)from private_fixture;
delete from org_internal_testing_grants where org_id=(select private_org from private_fixture);
update profiles set is_admin=false where id=(select benef from private_fixture);
update orgs set plan='trial',plan_source='trial',trial_ends_at=now()-interval '1 day',plan_expires_at=null where id=(select private_org from private_fixture);
set local role service_role;
select create_org_invite(host,host_org,null,'agent',repeat('5',64))from private_fixture;
select accept_org_invite(third,repeat('5',64))from private_fixture;
select pg_temp.private_ok('second private tester is a third host seat',org_seats_used(host_org)=3 and org_seats_allowed(third_org)=1 and not exists(select 1 from memberships where org_id=f.host_org and user_id=f.third))from private_fixture f;
select prepare_account_deletion(third,'synthetic-uploads','synthetic-renders')from private_fixture;
select pg_temp.private_ok('actual account deletion clears private FK without touching host',exists(select 1 from deletion_requests where user_id=f.third and status='processing'and snapshot_version=2)and not exists(select 1 from orgs where id=f.third_org)and exists(select 1 from orgs where id=f.host_org)and(select accepted_private_org_id is null from org_invites where token_hash=repeat('5',64)))from private_fixture f;
select pg_temp.private_denied('deleted private receipt cannot replay',format('select accept_org_invite(%L,%L)',third,repeat('5',64)),'RP409:')from private_fixture;
reset role;
delete from auth.users where id=(select third from private_fixture);
select pg_temp.private_ok('real profile FK cleanup preserves historical receipt',(select accepted_by is null and accepted_private_org_id is null and private_testing_receipt is not null from org_invites where token_hash=repeat('5',64)));
update org_internal_testing_grants set revoked_at=now()where org_id=(select host_org from private_fixture);
set local role service_role;
select pg_temp.private_ok('inactive host remains explicitly private',(private_internal_testing_host_mode(host,host_org)->>'configured')::boolean and not(private_internal_testing_host_mode(host,host_org)->>'active')::boolean)from private_fixture;
select pg_temp.private_denied('inactive configured host cannot mint shared invite',format('select create_org_invite(%L,%L,null,''agent'',%L)',host,host_org,repeat('6',64)),'RP402:')from private_fixture;
select pg_temp.private_denied('inactive host trigger independently refuses invitation',format('insert into org_invites(org_id,invited_by,token_hash,role)values(%L,%L,%L,''agent'')',host_org,host,repeat('e',64)),'RP402:')from private_fixture;
select pg_temp.private_denied('inactive captured invite cannot fall back shared',format('select accept_org_invite(%L,%L)',benef,repeat('3',64)),'RP403:')from private_fixture;
reset role;
delete from org_internal_testing_grants where org_id=(select host_org from private_fixture);
set local role service_role;
select pg_temp.private_denied('hard deleted grant cannot mint shared invite',format('select create_org_invite(%L,%L,null,''agent'',%L)',host,host_org,repeat('7',64)),'RP402:')from private_fixture;
select pg_temp.private_denied('hard deleted grant retains private insertion fence',format('insert into org_invites(org_id,invited_by,token_hash,role)values(%L,%L,%L,''agent'')',host_org,host,repeat('f',64)),'RP402:')from private_fixture;
insert into org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)select host_org,host,true from private_fixture;
select remove_private_internal_tester(host,host_org,benef)from private_fixture;
select pg_temp.private_ok('removal preserves private content and default',not org_has_private_internal_testing(private_org)and org_seats_used(host_org)=1 and exists(select 1 from listings where id=f.private_listing)and(select active_org_id=f.empty_org from user_workspace_state where user_id=f.benef))from private_fixture f;
select pg_temp.private_ok('retail Team context is absent and standard',private_internal_testing_host_mode(retail_user,retail_org)is null and private_internal_testing_context(retail_user,retail_org)is null and(org_entitlement(retail_org)).seats=2 and(org_entitlement(retail_org)).cogs_ceiling_cents=6000)from private_fixture;
select create_org_invite(retail_user,retail_org,null,'marketing',repeat('8',64))from private_fixture;
select accept_org_invite(foreign_user,repeat('8',64))from private_fixture;
select pg_temp.private_ok('ordinary customer join remains shared marketing',exists(select 1 from memberships where user_id=f.foreign_user and org_id=f.retail_org and role='marketing')and(select not private_testing from org_invites where token_hash=repeat('8',64)))from private_fixture f;
select pg_temp.private_denied('ordinary Team third seat still refused',format('select create_org_invite(%L,%L,null,''agent'',%L)',retail_user,retail_org,repeat('9',64)),'RP402:')from private_fixture;
reset role;
delete from auth.users where id=(select foreign_user from private_fixture);
select pg_temp.private_ok('real inviter profile FK cleanup preserves receipt',(select invited_by is null and private_testing_receipt is not null from org_invites where token_hash=repeat('3',64)));
select count(*)as private_testing_assertions from private_checks;
select 'PASS: private internal testing SQL assertions; fixtures rolled back.';
rollback;
