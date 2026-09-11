-- Owned socket-only PostgreSQL only; no external deletion occurs in this test.
\set ON_ERROR_STOP on
do $$ begin
  if current_database()<>'rendprop_deletion_audit' or current_setting('listen_addresses')<>''
    or current_setting('data_directory') !~ '^/tmp/rendprop-deletion-db-[^/]+/cluster$' then
    raise exception 'deletion fixture refuses non-disposable database';
  end if;
end $$;
begin;
create temp table _checks(name text primary key, pass boolean not null check(pass));
create temp table _fixture(n integer primary key, source uuid, dest uuid, org uuid, listing uuid, receipt jsonb);
create function pg_temp.a(ok boolean,label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'deletion assertion failed: %',label; end if;
  insert into _checks values(label,true);
end $$;
create function pg_temp.denied(command text,expected text,label text) returns void language plpgsql as $$ begin
  begin execute command; raise exception 'fixture accepted forbidden operation';
  exception when others then
    if sqlerrm not like expected then raise exception 'wrong failure for %: %',label,sqlerrm; end if;
  end;
  perform pg_temp.a(true,label);
end $$;
do $$ declare s uuid; d uuid; o uuid; l uuid; a uuid; j uuid; r uuid; prefix text; begin
  for n in 1..8 loop
    s:=('a0390000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    d:=('a0391000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    l:=('a0392000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    a:=('a0393000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    j:=('a0394000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    r:=('a0395000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    insert into auth.users(id,email,raw_user_meta_data,is_anonymous) values
      (s,'delete-source-'||n||'@fixture.invalid','{}',true),(d,'delete-dest-'||n||'@fixture.invalid','{}',false);
    select org_id into strict o from public.memberships where user_id=s;
    prefix:='renders/'||l||'/'||r;
    insert into public.listings(id,org_id,agent_id,status,main_photo_key) values(l,o,s,'ready',prefix||'-main.jpg');
    insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,bytes,transport_version)
      values(a,l,'video','uploads','uploads/'||o||'/'||l||'/capture.mov',true,1,2);
    insert into public.render_jobs(id,listing_id,capture_asset_id,source,status) values(j,l,a,'worker','ready');
    insert into public.renders(id,job_id,listing_id,slug,duration_s,video_key,poster_key,hero_key,stream_uid,published_at)
      values(r,j,l,'deletion-fixture-'||n,30,prefix||'.mp4',prefix||'-poster.jpg',prefix||'-hero.mp4','synthetic-stream-'||n,now());
    insert into public.photos(listing_id,original_key,enhanced_key) values(l,prefix||'-staged-0-orig.jpg',prefix||'-staged-0.jpg');
    insert into public.leads(listing_id,org_id,render_id,email) values(l,o,r,'lead@fixture.invalid');
    insert into _fixture values(n,s,d,o,l,null);
  end loop;
end $$;
create function pg_temp.prepare(n integer) returns jsonb language sql as $$
  select public.prepare_account_deletion(source,'fixture-uploads','fixture-renders') from _fixture where _fixture.n=$1
$$;
grant select,insert on _checks to service_role,anon,authenticated;
grant select,update on _fixture to service_role,anon,authenticated;
grant execute on function pg_temp.a(boolean,text),pg_temp.denied(text,text,text),pg_temp.prepare(integer) to service_role,anon,authenticated;
do $$ declare ns text; begin
  select nspname into ns from pg_namespace where oid=pg_my_temp_schema();
  execute format('grant usage on schema %I to service_role,anon,authenticated',ns);
end $$;
select pg_temp.a(not has_table_privilege('service_role','public.deletion_requests','INSERT') and
  not has_table_privilege('service_role','public.deletion_requests','UPDATE') and
  not has_table_privilege('service_role','public.deletion_requests','DELETE'),'old service handlers cannot forge or advance receipts');
select pg_temp.denied('select pg_temp.prepare(1)','service role required','no internal role rejected');
set local role anon;
select pg_temp.denied('select pg_temp.prepare(1)','permission denied%','anon rejected');
reset role;
set local role authenticated;
select pg_temp.denied('select pg_temp.prepare(1)','permission denied%','member rejected');
reset role;
-- Actual DB writes verify the intent already exists at the first destruction.
create function pg_temp.intent_before_delete() returns trigger language plpgsql as $$ begin
  if not exists(select 1 from public.deletion_requests where user_id=old.agent_id and snapshot_version=2) then
    raise exception 'first destruction has no durable intent';
  end if;
  return old;
end $$;
create trigger fixture_intent before delete on public.listings for each row execute function pg_temp.intent_before_delete();
set local role service_role;
update _fixture set receipt=pg_temp.prepare(1) where n=1;
select pg_temp.a((select receipt->>'ok'='true' and receipt->>'snapshot_version'='2' and
  receipt->'scope'->>'source_user_id'=source::text and receipt->'scope'->>'db_purged'='true' from _fixture where n=1),'bound snapshot returned');
select pg_temp.a((select jsonb_array_length(receipt->'payload'->'r2')=7 from _fixture where n=1),'all seven distinct media keys enumerated');
select pg_temp.a((select receipt->'payload'->'r2' @> jsonb_build_array(jsonb_build_object('bucket','fixture-renders',
  'key','renders/'||listing||'/a0395000-0000-4000-8000-000000000001-staged-0-orig.jpg')) from _fixture where n=1),'original enhancement uses renders bucket');
select pg_temp.a((select receipt->'payload'->'stream_uids'='["synthetic-stream-1"]' and
  jsonb_array_length(receipt->'payload'->'ghl_targets')=1 from _fixture where n=1),'Stream and tenant-bound CRM targets retained');
select pg_temp.denied('select pg_temp.prepare(1)','RP409: deletion cleanup is already running','duplicate DELETE does not start another cleaner');
select pg_temp.denied('select public.finish_account_deletion((receipt->>''request_id'')::uuid,gen_random_uuid(),receipt->''payload'','''') from _fixture where n=1',
  'RP409:%','wrong cleanup token rejected');
select pg_temp.denied('select public.finish_account_deletion((receipt->>''request_id'')::uuid,(receipt->>''lease_token'')::uuid,
  jsonb_set(receipt->''payload'',''{r2}'',''[{"bucket":"fixture-renders","key":"foreign"}]''),'''') from _fixture where n=1',
  'RP403:%','remaining cleanup cannot inject foreign media');
select pg_temp.denied('select public.finish_account_deletion((receipt->>''request_id'')::uuid,(receipt->>''lease_token'')::uuid,
  jsonb_set(receipt->''payload'',''{auth_user_id}'',''null''),'''') from _fixture where n=1',
  'RP409: sign-in record still exists','false Auth success rejected by real row');
select pg_temp.denied('select public.finish_account_deletion((receipt->>''request_id'')::uuid,(receipt->>''lease_token'')::uuid,
  jsonb_set(receipt->''payload'',''{profile_id}'',''null''),'''') from _fixture where n=1',
  'RP409: profile still exists','false profile success rejected by real row');
reset role;
select pg_temp.a((select not exists(select 1 from public.orgs where id=f.org) and
  not exists(select 1 from public.listings where id=f.listing) and
  not exists(select 1 from public.renders where listing_id=f.listing) from _fixture f where n=1),'scope purged and share render revoked transactionally');
select pg_temp.a((select exists(select 1 from auth.users where id=f.source) from _fixture f where n=1),'prepare alone never deletes Auth');
-- Shared team remains; the departing user's attribution is reassigned.
insert into public.memberships(org_id,user_id,role) select org,dest,'agent' from _fixture where n=2;
set local role service_role;
update _fixture set receipt=pg_temp.prepare(2) where n=2;
reset role;
select pg_temp.a((select l.agent_id=f.dest and exists(select 1 from public.orgs where id=f.org)
  and not exists(select 1 from public.memberships where org_id=f.org and user_id=f.source)
  and jsonb_array_length(f.receipt->'payload'->'r2')=0 from _fixture f join public.listings l on l.id=f.listing where n=2),'shared team and its media survive');
-- Failure midway through SQL must roll back the already inserted intent too.
create function pg_temp.fail_photo_delete() returns trigger language plpgsql as $$ begin raise exception 'synthetic photo failure'; end $$;
create trigger fixture_photo_failure before delete on public.photos for each row execute function pg_temp.fail_photo_delete();
set local role service_role;
select pg_temp.denied('select pg_temp.prepare(3)','synthetic photo failure','mid-purge failure surfaced');
reset role;
select pg_temp.a((select exists(select 1 from public.renders where listing_id=f.listing) and exists(select 1 from public.orgs where id=f.org)
  and not exists(select 1 from public.deletion_requests where user_id=f.source) from _fixture f where n=3),'mid-purge rollback restores data and removes tentative receipt');
drop trigger fixture_photo_failure on public.photos;
-- A writable photo reference must not authorize deleting a different tenant.
update public.photos set enhanced_key='renders/00000000-0000-4000-8000-000000000099/foreign.jpg' where listing_id=(select listing from _fixture where n=4);
set local role service_role;
select pg_temp.denied('select pg_temp.prepare(4)','RP409: unverified media ownership%','foreign photo reference fails before destruction');
reset role;
select pg_temp.a((select exists(select 1 from public.orgs where id=f.org) and not exists(select 1 from public.deletion_requests where user_id=f.source)
  from _fixture f where n=4),'unverified object leaves source untouched');
update public.photos p set enhanced_key='renders/'||f.listing||'/../../foreign.jpg' from _fixture f where f.n=4 and p.listing_id=f.listing;
set local role service_role;
select pg_temp.denied('select pg_temp.prepare(4)','RP409: unverified media ownership%','listing-prefix path traversal rejected');
reset role;
-- After an adoption winner, the old source has no authority over that org.
set local role service_role;
select public.adopt_anonymous_org(dest,source,org,gen_random_uuid()) from _fixture where n=5;
update _fixture set receipt=pg_temp.prepare(5) where n=5;
reset role;
select pg_temp.a((select l.agent_id=f.dest and jsonb_array_length(f.receipt->'payload'->'r2')=0
  and f.receipt->'scope'->'solo_orgs'='[]' from _fixture f join public.listings l on l.id=f.listing where n=5),'adoption winner excluded from later deletion snapshot');
-- Old arbitrary payload is retained, not executed or falsely completed.
insert into public.deletion_requests(user_id,status,payload) select source,'pending','{"db":{"org_ids":["legacy-unbound"]},"r2":[{"bucket":"old","key":"retain-exactly"}]}' from _fixture where n=6;
set local role service_role;
select pg_temp.a((public.claim_account_deletion((select id from public.deletion_requests where user_id=(select source from _fixture where n=6)))->>'manual_review_required')::boolean,'legacy receipt quarantined');
reset role;
select pg_temp.a((select manual_review_required and status='pending' and payload->'r2'->0->>'key'='retain-exactly'
  from public.deletion_requests where user_id=(select source from _fixture where n=6)),'legacy payload retained without false completion');
set local role service_role;
update _fixture set receipt=pg_temp.prepare(6) where n=6;
select pg_temp.a((select (receipt->>'manual_review_required')::boolean from _fixture where n=6),'new receipt reports historical manual leftovers');
reset role;
-- Expired lease may be reclaimed; a stale cleaner cannot advance the new one.
update public.deletion_requests set cleanup_lease_until=clock_timestamp()-interval '1 second' where id=(select (receipt->>'request_id')::uuid from _fixture where n=1);
set local role service_role;
select pg_temp.denied('select public.finish_account_deletion((receipt->>''request_id'')::uuid,(receipt->>''lease_token'')::uuid,receipt->''payload'','''') from _fixture where n=1',
  'RP409:%','expired cleaner rejected');
select pg_temp.a((select public.claim_account_deletion((receipt->>'request_id')::uuid)->>'lease_token'<>receipt->>'lease_token' from _fixture where n=1),'expired work gets new fencing token');
select pg_temp.denied('select public.finish_account_deletion((receipt->>''request_id'')::uuid,(receipt->>''lease_token'')::uuid,receipt->''payload'','''') from _fixture where n=1',
  'RP409:%','old token rejected after reclaim');
-- A normal durable completion requires actual removal of profile and Auth.
update _fixture set receipt=pg_temp.prepare(7) where n=7;
reset role;
delete from public.profiles where id=(select source from _fixture where n=7);
delete from auth.users where id=(select source from _fixture where n=7);
set local role service_role;
select pg_temp.a((select (public.finish_account_deletion((receipt->>'request_id')::uuid,(receipt->>'lease_token')::uuid,
  '{"r2":[],"stream_uids":[],"ghl_targets":[],"apple_refresh_token":null,"analytics_user_id":null,"profile_id":null,"auth_user_id":null,
    "provider_leases":[],"multipart_uploads":[],"unresolved_uploads":[],"unresolved_render_jobs":[],"storage_not_before":null}','')->>'cleanup_complete')::boolean from _fixture where n=7),'empty real cleanup completes');
select pg_temp.a((select (public.claim_account_deletion((receipt->>'request_id')::uuid)->>'completed')::boolean from _fixture where n=7),'completed work cannot be reclaimed');
reset role;
-- SQL aggregation must cover more than the usual PostgREST 1,000-row limit.
insert into public.photos(listing_id,enhanced_key)
  select f.listing,'renders/'||f.listing||'/extra-'||g.i||'.jpg' from _fixture f cross join generate_series(1,1001) as g(i) where f.n=8;
set local role service_role;
update _fixture set receipt=pg_temp.prepare(8) where n=8;
reset role;
select pg_temp.a((select jsonb_array_length(receipt->'payload'->'r2')=1008 and
  not exists(select 1 from public.photos where listing_id=f.listing) from _fixture f where n=8),'over-1000-row snapshot loses no media');
select pg_temp.a((select count(*)=31 from _checks),'exact registered assertion count');
select 'PASS: 32 deletion SQL assertions; all fixtures rolled back.';
rollback;
