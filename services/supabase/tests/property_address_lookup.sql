\set ON_ERROR_STOP on
-- Disposable PostgreSQL only: actual resolver, publication rows, roles and
-- retention/deletion fences. All addresses and identities are synthetic.
begin;
create temporary table address_checks(n integer);insert into address_checks values(0);
grant all on address_checks to service_role;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin
  if v is distinct from true then raise exception 'ADDRESS LOOKUP FAIL: %',label;end if;
  update address_checks set n=n+1;
end$$;
select pg_temp.ok(not has_function_privilege('anon','public.public_property_address_lookup(text)','execute')
  and not has_function_privilege('authenticated','public.public_property_address_lookup(text)','execute')
  and has_function_privilege('service_role','public.public_property_address_lookup(text)','execute'),
  'public RPC execute is service role only');
select pg_temp.ok(not has_function_privilege('anon','public.property_address_descriptor(text)','execute')
  and not has_function_privilege('authenticated','public.property_address_descriptor(text)','execute'),
  'descriptor helper is not a public RPC');
select pg_temp.ok(public.property_address_descriptor('Élan / </script> & Suite #2')='elan-script-suite-2',
  'NFKD, combining marks and punctuation match the host');
select pg_temp.ok(public.property_address_descriptor('  123 Main St, Charlotte, NC  ')='123-main-st-charlotte-nc',
  'ordinary address matches host casing and separators');
select pg_temp.ok(public.property_address_descriptor(repeat('x',500))=repeat('x',120),
  '500 UTF-16 unit input and 120 character output bounds');
select pg_temp.ok(public.property_address_descriptor(repeat('a',498)||'😀'||'z')=repeat('a',120),
  'supplementary character consumes two UTF-16 units before truncation');
select pg_temp.ok(public.property_address_descriptor('') is null,
  'empty descriptor cannot claim a route');

insert into auth.users(id,email,is_anonymous)values
 ('ad100000-0000-4000-8000-000000000001','address-one@fixture.invalid',false),
 ('ad100000-0000-4000-8000-000000000002','address-two@fixture.invalid',false);
create temporary table af as select
 (select org_id from public.memberships where user_id='ad100000-0000-4000-8000-000000000001'limit 1) org_one,
 (select org_id from public.memberships where user_id='ad100000-0000-4000-8000-000000000002'limit 1) org_two;
grant select on af to service_role;
select pg_temp.ok((select org_one is not null and org_two is not null and org_one<>org_two from af),
  'synthetic owners have distinct workspaces');
-- Seed the homes lawfully, then restore the original Free state so the
-- retention-expiry assertion still exercises unpaid hosting.
create temporary table address_org_before as select id,plan,plan_source,plan_expires_at,trial_ends_at
  from public.orgs where id in(select org_one from af union select org_two from af);
update public.orgs set plan='starter',plan_source='manual' where id in(select org_one from af union select org_two from af);
insert into public.listings(id,org_id,agent_id,space_type,address,status)values
 ('ad200000-0000-4000-8000-000000000001',(select org_one from af),'ad100000-0000-4000-8000-000000000001','real_estate','123 Main St','ready'),
 ('ad200000-0000-4000-8000-000000000002',(select org_two from af),'ad100000-0000-4000-8000-000000000002','real_estate','55 Other Road','ready'),
 ('ad200000-0000-4000-8000-000000000003',(select org_two from af),'ad100000-0000-4000-8000-000000000002','real_estate','77 Future Lane','ready');
update public.orgs o set plan=b.plan,plan_source=b.plan_source,plan_expires_at=b.plan_expires_at,trial_ends_at=b.trial_ends_at
  from address_org_before b where o.id=b.id;
-- Direct publication seed only; no render/provider execution. The test runs
-- the real lookup after restoring all triggers and role authority.
set local session_replication_role=replica;
insert into public.render_jobs(id,listing_id,status,source)values
 ('ad300000-0000-4000-8000-000000000001','ad200000-0000-4000-8000-000000000001','ready','app'),
 ('ad300000-0000-4000-8000-000000000002','ad200000-0000-4000-8000-000000000002','ready','app'),
 ('ad300000-0000-4000-8000-000000000003','ad200000-0000-4000-8000-000000000003','ready','app');
insert into public.renders(id,job_id,listing_id,slug,duration_s,published_at)values
 ('ad400000-0000-4000-8000-000000000001','ad300000-0000-4000-8000-000000000001','ad200000-0000-4000-8000-000000000001','published-main-1',15,now()-interval '2 minutes'),
 ('ad400000-0000-4000-8000-000000000002','ad300000-0000-4000-8000-000000000002','ad200000-0000-4000-8000-000000000002','published-other-2',15,now()-interval '1 minute'),
 ('ad400000-0000-4000-8000-000000000003','ad300000-0000-4000-8000-000000000003','ad200000-0000-4000-8000-000000000003','future-3',15,now()+interval '1 day');
set local session_replication_role=origin;
set local role service_role;
select pg_temp.ok(not exists(select 1 from public.public_property_tour_rows()),
  'all synthetic publications are noindex and absent from sitemap authority');
select pg_temp.ok(public.public_property_address_lookup('123-main-st')=
  '{"status":"unique","slug":"published-main-1"}'::jsonb,
  'unique current published noindex address resolves');
select pg_temp.ok(public.public_property_address_lookup('77-future-lane') is null,
  'future publication cannot claim an address');
select pg_temp.ok(public.public_property_address_lookup('demo')='{"status":"ambiguous"}'::jsonb
  and public.public_property_address_lookup('estate-demo')='{"status":"ambiguous"}'::jsonb,
  'synthetic demo aliases remain reserved');
reset role;

-- An identical address in a second, still noindex workspace is ambiguous.
update public.listings set address='123 Main St'where id='ad200000-0000-4000-8000-000000000002';
set local role service_role;
select pg_temp.ok(public.public_property_address_lookup('123-main-st')='{"status":"ambiguous"}'::jsonb,
  'cross-workspace duplicate includes noindex page');
reset role;
-- Listing B has an older approved publication and a newer revoked one. The
-- newest *hostable* render is B's older publication, so A is still ambiguous.
-- Moving the presenter check outside the lateral LIMIT incorrectly returns A.
set local session_replication_role=replica;
insert into public.render_jobs(id,listing_id,status,source)values
 ('ad300000-0000-4000-8000-000000000004','ad200000-0000-4000-8000-000000000002','ready','app');
insert into public.renders(id,job_id,listing_id,slug,duration_s,published_at)values
 ('ad400000-0000-4000-8000-000000000004','ad300000-0000-4000-8000-000000000004',
  'ad200000-0000-4000-8000-000000000002','newer-revoked-b',15,now()-interval '30 seconds');
set local session_replication_role=origin;
create temporary table saved_presenter_selection_def as
  select pg_get_functiondef('public.studio_presenter_render_access(uuid)'::regprocedure) body;
create or replace function public.studio_presenter_render_access(p_render uuid)
  returns boolean language sql security definer set search_path='' as $$
  select p_render<>'ad400000-0000-4000-8000-000000000004'::uuid$$;
set local role service_role;
select pg_temp.ok(not public.studio_presenter_render_access('ad400000-0000-4000-8000-000000000004')
  and public.studio_presenter_render_access('ad400000-0000-4000-8000-000000000002'),
  'B newer render is revoked while its older publication is approved');
select pg_temp.ok(public.public_property_address_lookup('123-main-st')='{"status":"ambiguous"}'::jsonb,
  'older approved B still prevents false uniqueness for A');
reset role;
do $$begin execute (select body from saved_presenter_selection_def);end$$;
set local session_replication_role=replica;
update public.renders set published_at=null where id='ad400000-0000-4000-8000-000000000004';
update public.listings set status='archived'where id='ad200000-0000-4000-8000-000000000002';
set local session_replication_role=origin;
set local role service_role;
select pg_temp.ok(public.public_property_address_lookup('123-main-st')->>'slug'='published-main-1',
  'withdrawn duplicate no longer blocks current address');
reset role;
set local session_replication_role=replica;
update public.listings set status='ready',address='55 Renamed Road'where id='ad200000-0000-4000-8000-000000000002';
set local session_replication_role=origin;
set local role service_role;
select pg_temp.ok(public.public_property_address_lookup('55-other-road') is null
  and public.public_property_address_lookup('55-renamed-road')->>'slug'='published-other-2',
  'renamed address loses old lookup and gains only new current descriptor');
reset role;

-- A one-segment legacy slug is still owned by its prior publication, even
-- when its current listing address has different words.
set local session_replication_role=replica;
update public.renders set slug='123-main-st'where id='ad400000-0000-4000-8000-000000000002';
set local session_replication_role=origin;
set local role service_role;
select pg_temp.ok(public.public_property_address_lookup('123-main-st')='{"status":"ambiguous"}'::jsonb,
  'legacy slug alias cannot be stolen by address route');
reset role;
update public.renders set published_at=null where id='ad400000-0000-4000-8000-000000000002';
set local role service_role;
select pg_temp.ok(public.public_property_address_lookup('123-main-st')->>'slug'='published-main-1',
  'unpublished alias no longer claims the route');
reset role;

-- Even if a render publication marker has not yet been cleared, the resolver
-- independently enforces listing deletion and presenter approval.
set local session_replication_role=replica;
update public.listings set deleted_at=now() where id='ad200000-0000-4000-8000-000000000001';
set local session_replication_role=origin;
set local role service_role;
select pg_temp.ok(public.public_property_address_lookup('123-main-st') is null,
  'soft-deleted listing cannot retain address route');
reset role;
set local session_replication_role=replica;
update public.listings set deleted_at=null where id='ad200000-0000-4000-8000-000000000001';
update public.renders set published_at=null where id='ad400000-0000-4000-8000-000000000001';
set local session_replication_role=origin;
set local role service_role;
select pg_temp.ok(public.public_property_address_lookup('123-main-st') is null,
  'unpublished primary render cannot retain address route');
reset role;
set local session_replication_role=replica;
update public.renders set published_at=now()-interval '2 minutes'
  where id='ad400000-0000-4000-8000-000000000001';
set local session_replication_role=origin;

create temporary table saved_presenter_definition as
  select pg_get_functiondef('public.studio_presenter_render_access(uuid)'::regprocedure) body;
create or replace function public.studio_presenter_render_access(p_render uuid)
  returns boolean language sql security definer set search_path='' as $$select false$$;
set local role service_role;
select pg_temp.ok(public.public_property_address_lookup('123-main-st') is null,
  'revoked presenter approval withdraws address');
reset role;
do $$begin execute (select body from saved_presenter_definition);end$$;

insert into public.deletion_requests(user_id,status)values('ad100000-0000-4000-8000-000000000001','pending');
set local role service_role;
select pg_temp.ok(public.public_property_address_lookup('123-main-st') is null,
  'pending owner erasure withdraws address');
reset role;
delete from public.deletion_requests where user_id='ad100000-0000-4000-8000-000000000001';
insert into public.serving_funding(org_id,source,collection_ref,actor_id,net_receipts_cents,sponsored_cents,starts_at,ends_at,retention_ends_at,service_months,recurring_reserve_cents,reserve_components,evidence_sha256)
 values((select org_one from af),'trial','fixture-address-expired','ad100000-0000-4000-8000-000000000001',0,500,now()-interval '120 days',now()-interval '119 days',now()-interval '29 days',1,0,'{}',repeat('a',64));
set local role service_role;
select pg_temp.ok(public.public_property_address_lookup('123-main-st') is null,
  'expired hosting retention withdraws address');
reset role;
select jsonb_build_object('passed',true,'assertions',n,'scope','actual disposable PostgreSQL and service-role authority')from address_checks;
rollback;
