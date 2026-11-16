\set ON_ERROR_STOP on
begin;
do $$begin if current_database()<>'owner_testing_media' or inet_server_addr() is not null then raise exception 'Owned socket-only media fixture required'; end if; end$$;
create temporary table checks(n integer);insert into checks values(0);
grant all on checks to service_role,authenticated,anon;
create function pg_temp.ok(v boolean,label text) returns void language plpgsql as $$begin
  if v is distinct from true then raise exception 'OWNER_MEDIA FAIL: %',label; end if;
  update checks set n=n+1;
end$$;
create function pg_temp.refuse(command text,needle text,label text) returns void language plpgsql as $$begin
  begin execute command;exception when others then
    if position(needle in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;
  end;
  raise exception 'OWNER_MEDIA FAIL: allowed %',label;
end$$;
create temporary table fixture(actor uuid,ordinary uuid,forged uuid,org uuid,ordinary_org uuid,forged_org uuid);
do $$declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();c uuid:=gen_random_uuid();o uuid;p uuid;q uuid;begin
  insert into auth.users(id,email) values(a,'owner-media@fixture.invalid'),(b,'ordinary-media@fixture.invalid'),(c,'forged-media@fixture.invalid');
  select org_id into o from public.memberships where user_id=a;
  select org_id into p from public.memberships where user_id=b;
  select org_id into q from public.memberships where user_id=c;
  update public.orgs set plan='team',plan_source='manual',plan_expires_at=null where id in(o,p,q);
  update public.profiles set is_admin=true where id=a;
  insert into public.org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)
    values(o,a,true),(q,c,true);
  insert into fixture values(a,b,c,o,p,q);
end$$;
grant select on fixture to service_role,authenticated,anon;
create temporary table money_before as select
  (select count(*) from public.media_account_reserves) reserves,
  (select count(*) from public.media_delivery_budgets) budgets,
  (select count(*) from public.serving_funding) funding,
  (select count(*) from public.cost_ledger) ledgers;
grant select on money_before to service_role;

select pg_temp.ok((select relrowsecurity from pg_class where oid='public.owner_testing_media_usage'::regclass),'usage has RLS');
select pg_temp.ok(not has_table_privilege(r,'public.owner_testing_media_usage','insert,update,delete'),'no direct usage writer '||r)
  from unnest(array['anon','authenticated','service_role'])r;
select pg_temp.ok(not has_table_privilege(r,'public.owner_testing_media_usage','select'),'private usage '||r)
  from unnest(array['anon','authenticated'])r;
select pg_temp.ok(not has_function_privilege(r,fn,'execute'),'service-only media function '||r)
  from unnest(array['anon','authenticated'])r cross join unnest(array[
    'public.media_delivery_admit(uuid,bigint,boolean)',
    'public.media_delivery_admit_before_owner_testing_20261015(uuid,bigint,boolean)'])fn;
select pg_temp.ok((select md5(prosrc)='e1fde5a0b8b7942c07bb95eac48f0ae5' from pg_proc where oid='public.media_delivery_admit_before_owner_testing_20261015(uuid,bigint,boolean)'::regprocedure),'ordinary financial admission remains byte-identical');
select pg_temp.ok((select prosecdef and proconfig=array['search_path=""']::text[] from pg_proc where oid='public.media_delivery_admit(uuid,bigint,boolean)'::regprocedure),'wrapper pinned definer');

set local role service_role;
do $$declare f record;r jsonb;begin select *into f from fixture;
  r:=public.media_delivery_admit(f.org,0,true);
  perform pg_temp.ok(r->>'basis'='owner_internal_testing' and r->>'financial_budget_bypassed'='true' and r->>'infrastructure_cost'='unpriced' and r->>'legacy_unbudgeted'='false','owner is explicit unpriced testing, not financial funding');
  r:=public.media_delivery_admit(f.org,1234,true);
  perform pg_temp.ok(r->>'admitted'='true' and r->>'request_counted'='true' and r->>'bytes_counted'='1234','owner exact byte receipt');
  perform pg_temp.ok((select used_requests=2 and used_bytes=1234 from public.owner_testing_media_usage where org_id=f.org and usage_day=(now()at time zone'UTC')::date),'HEAD and bytes both metered');
  perform pg_temp.refuse(format('select public.media_delivery_admit(%L,268435457,true)',f.org),'RP400:','owner cannot bypass generic byte cap');
  perform pg_temp.refuse(format('select public.media_delivery_admit(%L,-1,true)',f.org),'RP400:','negative bytes refused');
  perform pg_temp.refuse(format('select public.media_delivery_admit(%L,0,null)',f.org),'RP400:','null required flag refused');
  perform pg_temp.refuse(format('select public.media_delivery_admit(%L,0,true)',f.ordinary_org),'RP503:','ordinary Team is not testing authority');
  perform pg_temp.refuse(format('select public.media_delivery_admit(%L,0,true)',f.forged_org),'RP503:','grant without product-admin owner is insufficient');
  perform pg_temp.ok((select used_requests=2 and used_bytes=1234 from public.owner_testing_media_usage where org_id=f.org),'refused inputs do not alter counters');
  perform pg_temp.ok((select count(*) from public.media_account_reserves)=(select reserves from money_before)
    and (select count(*) from public.media_delivery_budgets)=(select budgets from money_before)
    and (select count(*) from public.serving_funding)=(select funding from money_before)
    and (select count(*) from public.cost_ledger)=(select ledgers from money_before),'owner usage mints no reserve funding budget or cost');
end$$;
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',forged,'role','service_role','is_admin',true,'user_metadata',jsonb_build_object('is_admin',true))::text,true)from fixture;
set local role authenticated;
select pg_temp.refuse(format('select public.media_delivery_admit(%L,0,true)',org),'permission denied','forged JWT role/admin cannot call service RPC')from fixture;
reset role;
select set_config('request.jwt.claims','{}',true);
update public.org_internal_testing_grants set revoked_at=now() where org_id=(select org from fixture);
set local role service_role;
select pg_temp.refuse(format('select public.media_delivery_admit(%L,0,true)',org),'RP503:','grant revocation stops new media admission')from fixture;
reset role;
update public.org_internal_testing_grants set revoked_at=null,starts_at=now()-interval'2 hours',expires_at=now()-interval'1 hour'where org_id=(select org from fixture);
set local role service_role;
select pg_temp.refuse(format('select public.media_delivery_admit(%L,0,true)',org),'RP503:','grant expiry stops new media admission')from fixture;
reset role;
update public.org_internal_testing_grants set starts_at=now(),expires_at=null where org_id=(select org from fixture);
update public.profiles set is_admin=false where id=(select actor from fixture);
set local role service_role;
select pg_temp.refuse(format('select public.media_delivery_admit(%L,0,true)',org),'RP503:','admin revocation stops new media admission')from fixture;
reset role;
update public.profiles set is_admin=true where id=(select actor from fixture);
update auth.users set is_anonymous=true where id=(select actor from fixture);
set local role service_role;
select pg_temp.refuse(format('select public.media_delivery_admit(%L,0,true)',org),'RP503:','anonymous owner cannot borrow testing grant')from fixture;
reset role;
update auth.users set is_anonymous=false where id=(select actor from fixture);
update public.orgs set deleted_at=now()where id=(select org from fixture);
set local role service_role;
select pg_temp.refuse(format('select public.media_delivery_admit(%L,0,true)',org),'RP404:','deleted workspace cannot serve media')from fixture;
reset role;
update public.orgs set deleted_at=null where id=(select org from fixture);

-- Synthetic finite budget only; no production cash claim/provisioning.
insert into public.media_delivery_budgets(org_id,receipt_ref,starts_at,ends_at,request_limit,byte_limit,storage_limit,tariff,reserves,evidence_sha256)
  select ordinary_org,'synthetic-owner-media-regression',now()-interval'1 minute',now()+interval'1 day',2,10,10,'{}','{}',repeat('e',64)from fixture;
set local role service_role;
do $$declare f record;r jsonb;begin select *into f from fixture;
  r:=public.media_delivery_admit(f.ordinary_org,7,true);
  perform pg_temp.ok(r->>'admitted'='true' and not(r?'financial_budget_bypassed'),'ordinary finite budget path unchanged');
  perform pg_temp.refuse(format('select public.media_delivery_admit(%L,4,true)',f.ordinary_org),'RP429:','ordinary byte budget still enforced');
  perform pg_temp.ok((select used_requests=1 and used_bytes=7 from public.media_delivery_budgets where org_id=f.ordinary_org),'refused ordinary request has no partial charge');
  r:=public.media_delivery_admit(f.ordinary_org,0,true);
  perform pg_temp.refuse(format('select public.media_delivery_admit(%L,0,true)',f.ordinary_org),'RP429:','ordinary request budget still enforced');
  perform pg_temp.ok(not exists(select 1 from public.owner_testing_media_usage where org_id in(f.ordinary_org,f.forged_org)),'ordinary and forged callers never enter owner meter');
end$$;
select jsonb_build_object('passed',true,'assertions',n)from checks;
rollback;
