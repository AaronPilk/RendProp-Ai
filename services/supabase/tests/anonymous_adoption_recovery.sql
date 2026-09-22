-- Synthetic, owned socket-only database only. Every fixture rolls back.
\set ON_ERROR_STOP on
do $$ begin
  if current_database() <> 'rendprop_adoption_audit' or current_setting('listen_addresses') <> ''
     or current_setting('data_directory') !~ '^/tmp/rendprop-adoption-db-[^/]+/cluster$' then
    raise exception 'adoption fixture refuses non-disposable database';
  end if;
end $$;
begin;
-- The existing CI bootstrap deliberately models only a subset of Auth. Add
-- this real Auth field ONLY in the disposable transaction, not production.
alter table auth.users add column if not exists is_anonymous boolean not null default false;
create temp table _checks(name text primary key, pass boolean not null check(pass));
create function pg_temp.a(ok boolean, label text) returns void language plpgsql as $$ begin
  if ok is distinct from true then raise exception 'adoption assertion failed: %', label; end if;
  insert into _checks values(label,true);
end $$;
select pg_temp.a(to_regclass('public.anonymous_adoption_receipts') is not null,'durable receipt table exists');
create temp table _fixture(n integer primary key, source uuid, dest uuid, org uuid, personal uuid, operation uuid);
do $$ declare s uuid; d uuid; o uuid; personal uuid; begin
  for n in 1..6 loop
    s := ('a0380000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    d := ('a0381000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    insert into auth.users(id,email,raw_user_meta_data,is_anonymous) values(s,'source-'||n||'@fixture.invalid','{}',true),(d,'dest-'||n||'@fixture.invalid','{}',false);
    select org_id into strict o from public.memberships where user_id=s;
    select org_id into strict personal from public.memberships where user_id=d;
    insert into _fixture values(n,s,d,o,personal,('a0382000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid);
    if n <> 2 then insert into public.listings(org_id,agent_id,status) values(o,s,'draft'); end if;
  end loop;
end $$;
grant select,insert on _checks to service_role,anon,authenticated;
grant select on _fixture to service_role,anon,authenticated;
create function pg_temp.adopt(n integer) returns jsonb language sql as $$
  select public.adopt_anonymous_org(dest,source,org,operation) from _fixture where _fixture.n=$1
$$;
create function pg_temp.denied(command text, expected text, label text) returns void language plpgsql as $$
begin
  begin execute command; raise exception 'fixture accepted forbidden operation';
  exception when others then
    if sqlerrm not like expected then raise exception 'wrong failure for %: %',label,sqlerrm; end if;
  end;
  perform pg_temp.a(true,label);
end $$;
do $$ declare ns text; begin
  select nspname into ns from pg_namespace where oid=pg_my_temp_schema();
  execute format('grant usage on schema %I to service_role,anon,authenticated',ns);
end $$;
grant execute on function pg_temp.a(boolean,text),pg_temp.adopt(integer),pg_temp.denied(text,text,text) to service_role,anon,authenticated;

select pg_temp.a(not has_function_privilege('anon','public.adopt_anonymous_org(uuid,uuid,uuid,uuid)','EXECUTE')
 and not has_function_privilege('authenticated','public.adoption_receipt(uuid,uuid,uuid)','EXECUTE')
 and has_function_privilege('service_role','public.adopt_anonymous_org(uuid,uuid,uuid)','EXECUTE'),'only receipt-aware internal transaction callable');
select pg_temp.a(not has_table_privilege('authenticated','public.anonymous_adoption_receipts','SELECT,INSERT,UPDATE,DELETE')
 and not has_table_privilege('anon','public.anonymous_adoption_receipts','SELECT,INSERT,UPDATE,DELETE'),'no Data API receipt access');
select pg_temp.denied('select pg_temp.adopt(1)','service role required','explicit internal-role guard');
set local role anon;
select pg_temp.denied('select pg_temp.adopt(1)','permission denied%','anon denied actual execute');
reset role;
set local role authenticated;
select pg_temp.denied('select pg_temp.adopt(1)','permission denied%','member denied actual execute');
reset role;
set local role service_role;
select pg_temp.a((pg_temp.adopt(1)->>'adopted')::boolean,'first transfer confirmed');
select pg_temp.a((pg_temp.adopt(2)->>'adopted')::boolean,'empty workspace transfers without deletion');
reset role;
select pg_temp.a((select count(*)=2 from public.memberships m join _fixture f on m.user_id=f.dest and m.org_id in(f.org,f.personal) where f.n=1),'destination personal workspace preserved');
select pg_temp.a((select count(*)=0 from public.memberships m join _fixture f on m.user_id=f.source where f.n=1),'source membership transferred');
select pg_temp.a((select l.agent_id=f.dest from public.listings l join _fixture f on l.org_id=f.org where f.n=1),'listing attribution transferred');
select pg_temp.a((select count(*)=12 from auth.users where id in(select source from _fixture union select dest from _fixture)),'no auth users deleted');
select pg_temp.a((select count(*)=2 from public.anonymous_adoption_receipts where source_user_id in(select source from _fixture)),'receipts commit once per source');
update public.user_workspace_state s set active_org_id=f.personal from _fixture f where f.n=1 and s.user_id=f.dest;
set local role service_role;
select pg_temp.a((select public.adoption_receipt(dest,source,operation)=pg_temp.adopt(1) from _fixture where n=1),'exact replay returns original receipt');
select pg_temp.denied('select public.adopt_anonymous_org(dest,source,personal,operation) from _fixture where n=1','RP403:%','cross-org replay rejected');
select pg_temp.denied('select public.adoption_receipt(f.dest,x.source,f.operation) from _fixture f cross join _fixture x where f.n=1 and x.n=3','RP403:%','cross-source replay rejected');
select pg_temp.denied('select public.adoption_receipt(source,dest,operation) from _fixture where n=1','RP403:%','cross-destination replay rejected');
select pg_temp.denied('select public.adoption_receipt(dest,source,gen_random_uuid()) from _fixture where n=1','RP409:%','source cannot receive another operation');
select pg_temp.denied('select public.adopt_anonymous_org(f.dest,f.source,f.org,x.operation) from _fixture f cross join _fixture x where f.n=3 and x.n=1','RP403:%','operation cannot bind another source');
reset role;
select pg_temp.a((select s.active_org_id=f.personal from public.user_workspace_state s join _fixture f on s.user_id=f.dest where f.n=1),'replay does not reset selected workspace');
select pg_temp.a((select count(*)=1 from public.memberships m join _fixture f on m.user_id=f.source and m.org_id=f.org where f.n=3),'rejected operation leaves source intact');
update public.memberships m set role='marketing' from _fixture f where f.n=3 and m.user_id=f.source;
set local role service_role;
select pg_temp.denied('select pg_temp.adopt(3)','RP409:%','non-owner source fails under transaction');
reset role;
insert into public.memberships(org_id,user_id,role) select f.org,x.dest,'marketing' from _fixture f cross join _fixture x where f.n=4 and x.n=3;
set local role service_role;
select pg_temp.denied('select pg_temp.adopt(4)','RP409:%','shared source workspace fails under transaction');
reset role;
delete from public.memberships m using _fixture f where f.n=1 and m.org_id=f.org and m.user_id=f.dest;
set local role service_role;
select pg_temp.denied('select public.adoption_receipt(dest,source,operation) from _fixture where n=1','RP409:%','removed member receipt cannot regrant access');
reset role;
select pg_temp.a((select count(*)=0 from public.memberships m join _fixture f on m.user_id=f.dest and m.org_id=f.org where f.n=1),'removed access stays absent');
select pg_temp.a((select count(*)=2 from public.anonymous_adoption_receipts where source_user_id in(select source from _fixture)),'rejected/replayed operations add no receipts');
set local role service_role;
select pg_temp.a((select (public.adopt_anonymous_org(dest,source,org)->>'adopted')::boolean from _fixture where n=5),'legacy caller commits receipt');
select pg_temp.a((select public.adopt_anonymous_org(dest,source,org)=public.adopt_anonymous_org(dest,source,org) from _fixture where n=5),'legacy replay is exact');
select pg_temp.denied('select public.adopt_anonymous_org(f.dest,x.source,x.org) from _fixture f cross join _fixture x where f.n=6 and x.n=5','RP403:%','legacy wrong destination rejected');
select pg_temp.denied('select public.adopt_anonymous_org(dest,source,personal) from _fixture where n=5','RP403:%','legacy wrong org rejected');
select pg_temp.a((select public.adopt_anonymous_org(dest,source,org)=public.adoption_receipt(dest,source,(public.adopt_anonymous_org(dest,source,org)->>'operation_id')::uuid) from _fixture where n=5),'legacy receipt replays without source credential');
reset role;
select pg_temp.a((select count(*)=3 from public.anonymous_adoption_receipts where source_user_id in(select source from _fixture)),'legacy repeated calls create one receipt');
select pg_temp.a((select count(*)=2 from public.memberships m join _fixture f on m.user_id=f.dest and m.org_id in(f.org,f.personal) where f.n=5),'legacy preserves personal workspace');
update auth.users set is_anonymous=false where id=(select source from _fixture where n=6);
set local role service_role;
select pg_temp.denied('select pg_temp.adopt(6)','RP403:%','promoted source cannot transfer');
reset role;
update auth.users set is_anonymous=true where id in(select source from _fixture where n=6 union select dest from _fixture where n=6);
set local role service_role;
select pg_temp.denied('select pg_temp.adopt(6)','RP403:%','anonymous destination cannot receive');
reset role;
do $$ begin
  if (select count(*) from _checks) <> 35 then raise exception 'incomplete adoption assertion inventory'; end if;
end $$;
select 'PASS: 35 adoption SQL assertions; all fixtures rolled back.';
rollback;
