-- Synthetic owned-DB proof; every fixture and mutation is rolled back.
begin;
create temporary table logo_checks(label text primary key,ok boolean not null);
create function pg_temp.logo_ok(label text,value boolean) returns void language plpgsql security definer as $$begin
 if value is distinct from true then raise exception 'LOGO FAIL: %',label; end if;
 insert into pg_temp.logo_checks values(label,true);
end $$;
create function pg_temp.logo_denied(label text,statement text,message text) returns void language plpgsql as $$declare e text;begin
 begin execute statement;exception when others then e:=sqlerrm;end;
 if e is null or position(message in e)=0 then raise exception 'LOGO FAIL: % wrong denial: %',label,coalesce(e,'accepted');end if;
 perform pg_temp.logo_ok(label,true);
end $$;
insert into auth.users(id,email,is_anonymous) values
 ('b0100501-0000-4000-8000-000000000001','owner@fixture.invalid',false),
 ('b0100501-0000-4000-8000-000000000002','foreign@fixture.invalid',false),
 ('b0100501-0000-4000-8000-000000000003','member@fixture.invalid',false),
 ('b0100501-0000-4000-8000-000000000004','delete@fixture.invalid',false);
create temporary table logo_fixture as select user_id actor,org_id org from public.memberships where user_id::text like 'b0100501-%';
grant select on logo_fixture to service_role,authenticated;
update public.orgs set brand_kit='{"avatar_url":"https://portrait.fixture.invalid/one.jpg","name":"Owner"}' where id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001');
insert into public.memberships(user_id,org_id,role)select 'b0100501-0000-4000-8000-000000000003',org,'agent' from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select pg_temp.logo_ok('private table denies anonymous/authenticated',not has_table_privilege('authenticated','org_brand_assets','SELECT') and not has_table_privilege('anon','org_brand_assets','INSERT'));
select pg_temp.logo_ok('all logo helpers service only',not has_function_privilege('authenticated','public.prepare_org_brand_logo(uuid,uuid,uuid,text,integer,text,text,text)','EXECUTE') and not has_function_privilege('anon','public.publish_org_brand_logo(uuid,uuid,uuid,text)','EXECUTE') and not has_function_privilege('authenticated','public.merge_org_brand_fields(uuid,uuid,jsonb,jsonb)','EXECUTE'));
set local role service_role;
select pg_temp.logo_denied('agent prepare denied',format('select prepare_org_brand_logo(%L,%L,%L,null,100,%L,%L,%L)','b0100501-0000-4000-8000-000000000003',(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001'),'b0100502-0000-4000-8000-000000000001','image/png',repeat('a',64),'https://cdn.fixture.invalid/no'), 'RP403');
select pg_temp.logo_denied('foreign org prepare denied',format('select prepare_org_brand_logo(%L,%L,%L,null,100,%L,%L,%L)','b0100501-0000-4000-8000-000000000001',(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000002'),'b0100502-0000-4000-8000-000000000001','image/png',repeat('a',64),'https://cdn.fixture.invalid/no'), 'RP403');
select pg_temp.logo_denied('invalid raster size denied',format('select prepare_org_brand_logo(%L,%L,%L,null,524289,%L,%L,%L)',actor,org,'b0100502-0000-4000-8000-000000000001','image/png',repeat('a',64),'https://cdn.fixture.invalid/no'), 'RP400')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select prepare_org_brand_logo(actor,org,'b0100502-0000-4000-8000-000000000001',null,100,'image/png',repeat('a',64),'https://cdn.fixture.invalid/renders/'||org||'/brand/b0100502-0000-4000-8000-000000000001.png')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select pg_temp.logo_ok('dispatch actual bytes charged once',(select spent_bytes=100 and held_bytes=0 and tickets=1 from upload_budget_windows where org_id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001')));
select pg_temp.logo_ok('prepared orphan cleanup waits beyond write deadline',(select state='dispatching' and cleanup_after>=write_deadline+interval '1 hour' from upload_operations where asset_id='b0100502-0000-4000-8000-000000000001'));
select pg_temp.logo_ok('prepare has no public pointer',(select not(brand_kit?'business_logo_url')from orgs where id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001')));
select publish_org_brand_logo(actor,org,'b0100502-0000-4000-8000-000000000001','"synthetic-etag"')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select pg_temp.logo_ok('published pointer preserves portrait',(select brand_kit->>'avatar_url'='https://portrait.fixture.invalid/one.jpg' and brand_kit->>'business_logo_url' like '%000000000001.png'from orgs where id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001')));
select pg_temp.logo_ok('retained current logo cannot be swept',(select state='retained' and cleanup_after is null from upload_operations where asset_id='b0100502-0000-4000-8000-000000000001'));
reset role;
select set_config('request.jwt.claim.sub','b0100501-0000-4000-8000-000000000001',true);
set local role authenticated;
select pg_temp.logo_denied('authenticated owner cannot erase protected logo directly',format('update public.orgs set brand_kit=brand_kit-%L where id=%L','business_logo_url',(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001')),'RP403');
select pg_temp.logo_denied('authenticated owner cannot inject arbitrary logo directly',format('update public.orgs set brand_kit=brand_kit||%L::jsonb where id=%L','{"business_logo_url":"https://foreign.fixture.invalid/logo.png"}',(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001')),'RP403');
reset role;set local role service_role;
select pg_temp.logo_ok('lost receipt replay does not dispatch',(prepare_org_brand_logo(actor,org,'b0100502-0000-4000-8000-000000000001',null,100,'image/png',repeat('a',64),'https://cdn.fixture.invalid/renders/'||org||'/brand/b0100502-0000-4000-8000-000000000001.png')->>'replayed')='true')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select pg_temp.logo_ok('replay never charges another write',(select spent_bytes=100 and tickets=1 from upload_budget_windows where org_id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001')));
select merge_org_brand_fields(actor,org,'{"title":"New title"}','{}')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select pg_temp.logo_ok('text save after logo preserves both',(select brand_kit->>'title'='New title' and brand_kit->>'business_logo_url' like '%000000000001.png'from orgs where id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001')));
select pg_temp.logo_denied('ordinary logo injection refused',format('select merge_org_brand_fields(%L,%L,%L::jsonb,%L::jsonb)',actor,org,'{"business_logo_url":"https://evil.fixture.invalid/x.png"}','{}'), 'RP400')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select pg_temp.logo_denied('ordinary plan injection refused',format('select merge_org_brand_fields(%L,%L,%L::jsonb,%L::jsonb)',actor,org,'{}','{"plan":"team"}'), 'RP400')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select prepare_org_brand_logo(actor,org,'b0100502-0000-4000-8000-000000000002',(select public_url from org_brand_assets where id='b0100502-0000-4000-8000-000000000001'),120,'image/png',repeat('b',64),'https://cdn.fixture.invalid/renders/'||org||'/brand/b0100502-0000-4000-8000-000000000002.png')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select merge_org_brand_fields(actor,org,'{"phone":"5551234567"}','{}')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select publish_org_brand_logo(actor,org,'b0100502-0000-4000-8000-000000000002','"synthetic-etag2"')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select pg_temp.logo_ok('logo after text preserves both',(select brand_kit->>'phone'='5551234567' and brand_kit->>'business_logo_url' like '%000000000002.png'from orgs where id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001')));
select pg_temp.logo_ok('only replaced logo becomes cleanup eligible',(select state='stored' and cleanup_after<=clock_timestamp() from upload_operations where asset_id='b0100502-0000-4000-8000-000000000001'));
select pg_temp.logo_denied('old published operation cannot resurrect after replacement',format('select prepare_org_brand_logo(%L,%L,%L,null,100,%L,%L,%L)',actor,org,'b0100502-0000-4000-8000-000000000001','image/png',repeat('a',64),'https://cdn.fixture.invalid/renders/'||org||'/brand/b0100502-0000-4000-8000-000000000001.png'),'RP409')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select claim_upload_cleanup(id,'b0100503-0000-4000-8000-000000000001')from upload_operations where asset_id='b0100502-0000-4000-8000-000000000001';
select finish_upload_cleanup(id,'b0100503-0000-4000-8000-000000000001',false)from upload_operations where asset_id='b0100502-0000-4000-8000-000000000001';
select pg_temp.logo_ok('failed cleanup remains journaled for retry',(select state='uncertain' and cleaned_at is null and cleanup_after>clock_timestamp()from upload_operations where asset_id='b0100502-0000-4000-8000-000000000001'));
select prepare_org_brand_logo(actor,org,'b0100502-0000-4000-8000-000000000003',(select public_url from org_brand_assets where id='b0100502-0000-4000-8000-000000000002'),130,'image/png',repeat('c',64),'https://cdn.fixture.invalid/renders/'||org||'/brand/b0100502-0000-4000-8000-000000000003.png')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
reset role;
update memberships set role='agent' where user_id='b0100501-0000-4000-8000-000000000001';
set local role service_role;
select pg_temp.logo_denied('role revoked after storage blocks publication',format('select publish_org_brand_logo(%L,%L,%L,%L)',actor,org,'b0100502-0000-4000-8000-000000000003','synthetic-etag'),'RP403')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select pg_temp.logo_denied('role revoked also blocks text write',format('select merge_org_brand_fields(%L,%L,%L::jsonb,%L::jsonb)',actor,org,'{"name":"Wrong"}','{}'),'RP403')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select pg_temp.logo_ok('revoked write preserves old public version',(select brand_kit->>'business_logo_url' like '%000000000002.png'from orgs where id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001')));
reset role;update memberships set role='owner' where user_id='b0100501-0000-4000-8000-000000000001';
update orgs set deleted_at=now()where id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001');
set local role service_role;
select pg_temp.logo_denied('deleted org after write blocks publication',format('select publish_org_brand_logo(%L,%L,%L,%L)',actor,org,'b0100502-0000-4000-8000-000000000003','synthetic-etag'),'RP403')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select pg_temp.logo_denied('deleted org before preparation charges nothing',format('select prepare_org_brand_logo(%L,%L,%L,null,100,%L,%L,%L)',actor,org,'b0100502-0000-4000-8000-000000000099','image/png',repeat('a',64),'https://cdn.fixture.invalid/no'),'RP403')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select pg_temp.logo_ok('deleted preparation leaves byte budget and journal unchanged',(select spent_bytes=350 and tickets=3 from upload_budget_windows where org_id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001')) and not exists(select 1 from org_brand_assets where id='b0100502-0000-4000-8000-000000000099'));
reset role;update orgs set deleted_at=null where id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001');
update upload_operations set write_deadline=now()-interval'1 minute',cleanup_after=now()-interval'1 minute' where asset_id='b0100502-0000-4000-8000-000000000003';
set local role service_role;
select pg_temp.logo_denied('expired write cannot publish even with storage receipt',format('select publish_org_brand_logo(%L,%L,%L,%L)',actor,org,'b0100502-0000-4000-8000-000000000003','synthetic-etag'),'RP409')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select claim_upload_cleanup(id,'b0100503-0000-4000-8000-000000000002')from upload_operations where asset_id='b0100502-0000-4000-8000-000000000003';
select pg_temp.logo_denied('cleanup winner cannot become public',format('select publish_org_brand_logo(%L,%L,%L,%L)',actor,org,'b0100502-0000-4000-8000-000000000003','synthetic-etag'),'RP409')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select finish_upload_cleanup(id,'b0100503-0000-4000-8000-000000000002',true)from upload_operations where asset_id='b0100502-0000-4000-8000-000000000003';
select pg_temp.logo_ok('orphan cleanup success records terminal receipt',(select state='deleted' and cleaned_at is not null from upload_operations where asset_id='b0100502-0000-4000-8000-000000000003'));
select pg_temp.logo_denied('stale clear cannot remove replacement logo',format('select clear_org_brand_logo(%L,%L,%L)',actor,org,(select public_url from org_brand_assets where id='b0100502-0000-4000-8000-000000000001')),'RP409')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select clear_org_brand_logo(actor,org,(select public_url from org_brand_assets where id='b0100502-0000-4000-8000-000000000002'))from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
select pg_temp.logo_ok('clear leaves portrait/text intact',(select not(brand_kit?'business_logo_url') and brand_kit->>'avatar_url'='https://portrait.fixture.invalid/one.jpg' and brand_kit->>'title'='New title'from orgs where id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001')));
select pg_temp.logo_ok('clear never refunds physical bytes',(select spent_bytes=350 and held_bytes=0 and tickets=3 from upload_budget_windows where org_id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000001')));
-- Account deletion includes both retained pointer and unknown in-flight write.
select prepare_org_brand_logo(actor,org,'b0100502-0000-4000-8000-000000000004',null,140,'image/png',repeat('d',64),'https://cdn.fixture.invalid/renders/'||org||'/brand/b0100502-0000-4000-8000-000000000004.png')from logo_fixture where actor='b0100501-0000-4000-8000-000000000004';
select publish_org_brand_logo(actor,org,'b0100502-0000-4000-8000-000000000004','synthetic-etag4')from logo_fixture where actor='b0100501-0000-4000-8000-000000000004';
select prepare_org_brand_logo(actor,org,'b0100502-0000-4000-8000-000000000005',(select public_url from org_brand_assets where id='b0100502-0000-4000-8000-000000000004'),150,'image/png',repeat('e',64),'https://cdn.fixture.invalid/renders/'||org||'/brand/b0100502-0000-4000-8000-000000000005.png')from logo_fixture where actor='b0100501-0000-4000-8000-000000000004';
select prepare_account_deletion('b0100501-0000-4000-8000-000000000004','fixture-uploads','fixture-renders');
select pg_temp.logo_ok('deletion inventories current and staged immutable logos',(select jsonb_array_length(payload->'r2')=2 and (payload->>'storage_not_before')::timestamptz>=now()+interval'61 minutes'from deletion_requests where user_id='b0100501-0000-4000-8000-000000000004' and snapshot_version=2));
select pg_temp.logo_ok('deletion inventory uses existing exact physical bucket',(select bool_and(t->>'bucket'='fixture-renders' and t->>'key' like 'renders/%/brand/%')from deletion_requests d,jsonb_array_elements(d.payload->'r2')t where d.user_id='b0100501-0000-4000-8000-000000000004'and snapshot_version=2));
select pg_temp.logo_ok('solo deletion purges metadata not cleanup receipt',not exists(select 1 from org_brand_assets where actor_id='b0100501-0000-4000-8000-000000000004') and exists(select 1 from deletion_requests where user_id='b0100501-0000-4000-8000-000000000004'));
select pg_temp.logo_denied('deleted actor cannot publish late storage write',format('select publish_org_brand_logo(%L,%L,%L,%L)',actor,org,'b0100502-0000-4000-8000-000000000005','synthetic-etag'),'RP403')from logo_fixture where actor='b0100501-0000-4000-8000-000000000004';
-- Actual transport safety caps, charged sanitized bytes and dispatches only.
reset role;
insert into upload_budget_windows(org_id,day,held_bytes,spent_bytes,tickets)select org,(clock_timestamp()at time zone'UTC')::date,0,214748364799,0 from logo_fixture where actor='b0100501-0000-4000-8000-000000000002';
set local role service_role;
select pg_temp.logo_denied('actual byte safety ceiling denies before journal insertion',format('select prepare_org_brand_logo(%L,%L,%L,null,2,%L,%L,%L)',actor,org,'b0100506-0000-4000-8000-000000000001','image/png',repeat('a',64),'https://cdn.fixture.invalid/renders/'||org||'/brand/b0100506-0000-4000-8000-000000000001.png'),'RP429')from logo_fixture where actor='b0100501-0000-4000-8000-000000000002';
reset role;update upload_budget_windows set spent_bytes=0,tickets=2000 where org_id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000002');set local role service_role;
select pg_temp.logo_denied('existing dispatch safety cap denies before journal insertion',format('select prepare_org_brand_logo(%L,%L,%L,null,2,%L,%L,%L)',actor,org,'b0100506-0000-4000-8000-000000000001','image/png',repeat('a',64),'https://cdn.fixture.invalid/renders/'||org||'/brand/b0100506-0000-4000-8000-000000000001.png'),'RP429')from logo_fixture where actor='b0100501-0000-4000-8000-000000000002';
reset role;update upload_budget_windows set tickets=0 where org_id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000002');set local role service_role;
do $$declare a uuid:='b0100501-0000-4000-8000-000000000002';o uuid;k uuid;begin select org into o from logo_fixture where actor=a;
 for n in 1..20 loop k:=('b0100506-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;perform prepare_org_brand_logo(a,o,k,null,2,'image/png',repeat('a',64),'https://cdn.fixture.invalid/renders/'||o||'/brand/'||k||'.png');end loop;end$$;
select pg_temp.logo_denied('twenty-first actual logo dispatch is bounded',format('select prepare_org_brand_logo(%L,%L,%L,null,2,%L,%L,%L)',actor,org,'b0100506-0000-4000-8000-000000000021','image/png',repeat('a',64),'https://cdn.fixture.invalid/renders/'||org||'/brand/b0100506-0000-4000-8000-000000000021.png'),'RP429')from logo_fixture where actor='b0100501-0000-4000-8000-000000000002';
select pg_temp.logo_ok('denied dispatches leave exact successful byte count',(select spent_bytes=40 and tickets=20 from upload_budget_windows where org_id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000002')) and not exists(select 1 from org_brand_assets where id='b0100506-0000-4000-8000-000000000021'));
select publish_org_brand_logo(actor,org,'b0100506-0000-4000-8000-000000000001','synthetic-etag-shared')from logo_fixture where actor='b0100501-0000-4000-8000-000000000002';
select pg_temp.logo_denied('cross-account operation retry cannot bind foreign operation',format('select prepare_org_brand_logo(%L,%L,%L,null,2,%L,%L,%L)',actor,org,'b0100506-0000-4000-8000-000000000001','image/png',repeat('a',64),'https://cdn.fixture.invalid/renders/'||org||'/brand/b0100506-0000-4000-8000-000000000001.png'),'RP403')from logo_fixture where actor='b0100501-0000-4000-8000-000000000001';
reset role;
insert into memberships(user_id,org_id,role)select 'b0100501-0000-4000-8000-000000000003',org,'admin'from logo_fixture where actor='b0100501-0000-4000-8000-000000000002';
set local role service_role;
select pg_temp.logo_denied('sole shared owner must transfer ownership before account deletion','select prepare_account_deletion(''b0100501-0000-4000-8000-000000000002'',''fixture-uploads'',''fixture-renders'')','RP409: Transfer ownership');
select pg_temp.logo_ok('refused shared owner deletion preserves custody logo journal and no intent',
 exists(select 1 from memberships where user_id='b0100501-0000-4000-8000-000000000002'and org_id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000002')and role='owner')
 and exists(select 1 from memberships where user_id='b0100501-0000-4000-8000-000000000003'and org_id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000002')and role='admin')
 and exists(select 1 from orgs where id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000002')and brand_kit->>'business_logo_url'like'%000000000001.png')
 and exists(select 1 from org_brand_assets where id='b0100506-0000-4000-8000-000000000001'and state='published')
 and exists(select 1 from upload_operations where asset_id='b0100506-0000-4000-8000-000000000001'and state='retained')
 and not exists(select 1 from deletion_requests where user_id='b0100501-0000-4000-8000-000000000002'));
-- Explicit synthetic custody transfer: the retained workspace already has a
-- surviving owner before the deleting owner leaves. No deletion auto-promotion.
reset role;
update memberships set role='owner'where user_id='b0100501-0000-4000-8000-000000000003'and org_id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000002');
set local role service_role;
select prepare_account_deletion('b0100501-0000-4000-8000-000000000002','fixture-uploads','fixture-renders');
select pg_temp.logo_ok('shared account deletion retains office logo and its journal',exists(select 1 from orgs where id=(select org from logo_fixture where actor='b0100501-0000-4000-8000-000000000002') and brand_kit->>'business_logo_url'like'%000000000001.png')and exists(select 1 from org_brand_assets where id='b0100506-0000-4000-8000-000000000001'and state='published')and exists(select 1 from upload_operations where asset_id='b0100506-0000-4000-8000-000000000001'and state='retained'));
select pg_temp.logo_ok('shared account deletion never schedules office objects',(select jsonb_array_length(payload->'r2')=0 from deletion_requests where user_id='b0100501-0000-4000-8000-000000000002'and snapshot_version=2));
reset role;
select count(*) as logo_assertions from logo_checks;
select 'PASS: org logo lifecycle SQL assertions; all fixtures rolled back.';
rollback;
