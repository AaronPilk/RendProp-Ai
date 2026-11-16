\set ON_ERROR_STOP on
begin;
create temporary table measurement_cas_assertions(n int not null default 0);
insert into measurement_cas_assertions default values;
create temporary table measurement_cas_ids(actor uuid,second_actor uuid,viewer uuid,outsider uuid,deleting_actor uuid,org uuid,foreign_org uuid,listing uuid,conflict_listing uuid);
insert into measurement_cas_ids select gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid();
create function pg_temp.cas_check(ok boolean,label text) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL: %',label; end if;
 update measurement_cas_assertions set n=n+1;
end $$;
create function pg_temp.cas_refuses(statement text,expected_code text,label text) returns void language plpgsql as $$
begin
 begin execute statement; exception when others then
  if sqlstate=expected_code then perform pg_temp.cas_check(true,label); return; end if;
  raise exception 'FAIL: % expected SQLSTATE %, got %: %',label,expected_code,sqlstate,sqlerrm;
 end;
 raise exception 'FAIL: % did not refuse',label;
end $$;
do $$
declare f measurement_cas_ids; old_plan text:='{"version":1,"unit":"feet","rooms":[],"updatedAt":812345678}';
begin
 select * into f from measurement_cas_ids;
 insert into auth.users(id,email) values(f.actor,'cas-owner@example.invalid'),(f.second_actor,'cas-second@example.invalid'),(f.viewer,'cas-viewer@example.invalid'),(f.outsider,'cas-outsider@example.invalid'),(f.deleting_actor,'cas-deleting@example.invalid');
 insert into orgs(id,name,plan) values(f.org,'Synthetic measurement CAS','pro'),(f.foreign_org,'Synthetic foreign CAS','pro');
 insert into memberships(user_id,org_id,role) values(f.actor,f.org,'owner'),(f.second_actor,f.org,'agent'),(f.viewer,f.org,'marketing'),(f.outsider,f.foreign_org,'owner'),(f.deleting_actor,f.org,'agent');
 insert into deletion_requests(user_id,status) values(f.deleting_actor,'pending');
 insert into listings(id,org_id,agent_id,address,sqft,status,sold_at,price_cents,beds,baths,details)
 values(f.listing,f.org,f.actor,'Synthetic measured property',2345,'archived','2026-09-30 12:00:00+00',50000000,3,2.5,
  jsonb_build_object('floorMeasurementsV1',old_plan,'floorMeasurementsV9','opaque-future-version','floor_plan_asset_id','studio-authoritative-attachment','tagline','Studio updated'));
 insert into listings(id,org_id,agent_id,address,details) values(f.conflict_listing,f.org,f.actor,'Synthetic aliases',
  jsonb_build_object('floorMeasurementsV1',old_plan,'floor_measurements_v1','{"version":2,"unit":"meters","rooms":[],"outlines":[],"updatedAt":812345678}'));
end $$;
grant all on measurement_cas_ids,measurement_cas_assertions to service_role;
set local role service_role;
do $$
declare f measurement_cas_ids; before_row listings; after_row listings; r jsonb; saved text;
 old_plan text:='{"version":1,"unit":"feet","rooms":[],"updatedAt":812345678}';
 new_plan text:='{"version":2,"unit":"meters","rooms":[],"outlines":[],"updatedAt":812345678}';
 bad text; role_name text;
begin
 select * into f from measurement_cas_ids;
 select * into before_row from listings where id=f.listing;
 perform pg_temp.cas_check(before_row.details->>'floor_measurements_v1'=old_plan and not before_row.details ? 'floorMeasurementsV1','insert canonicalizes legacy key');
 perform pg_temp.cas_check(before_row.details->>'floorMeasurementsV9'='opaque-future-version','unknown future key preserved');
 foreach role_name in array array['anon','authenticated'] loop
  perform pg_temp.cas_check(not has_function_privilege(role_name,'public.save_listing_measurements(uuid,uuid,uuid,text,text)','execute'),'CAS service only');
 end loop;
 perform pg_temp.cas_check(has_function_privilege('service_role','public.save_listing_measurements(uuid,uuid,uuid,text,text)','execute'),'CAS service grant');
 perform pg_temp.cas_check(not (select prosecdef from pg_proc where oid='public.save_listing_measurements(uuid,uuid,uuid,text,text)'::regprocedure),'CAS remains invoker');
 r:=public.save_listing_measurements(f.actor,f.org,f.listing,old_plan,new_plan);
 select * into after_row from listings where id=f.listing;
 perform pg_temp.cas_check(after_row.details->>'floor_measurements_v1'=new_plan,'exact new plan persisted');
 perform pg_temp.cas_check((after_row.sqft,after_row.status,after_row.sold_at,after_row.price_cents,after_row.beds,after_row.baths,after_row.address) is not distinct from
  (before_row.sqft,before_row.status,before_row.sold_at,before_row.price_cents,before_row.beds,before_row.baths,before_row.address),'all listing facts unchanged by measurements');
 perform pg_temp.cas_check(after_row.details->>'floor_plan_asset_id'='studio-authoritative-attachment' and after_row.details->>'tagline'='Studio updated','Studio attachment and unrelated details preserved');
 perform pg_temp.cas_check(after_row.details->>'floorMeasurementsV9'='opaque-future-version','unknown alias survives measurement save');
 r:=public.save_listing_measurements(f.actor,f.org,f.listing,old_plan,new_plan);
 perform pg_temp.cas_check(r->'details'->>'floor_measurements_v1'=new_plan,'lost response same-value replay accepts stale expectation');
 perform pg_temp.cas_refuses(format('select save_listing_measurements(%L,%L,%L,%L,%L)',f.second_actor,f.org,f.listing,old_plan,old_plan),'PT409','second stale writer conflicts');
 perform pg_temp.cas_refuses(format('select save_listing_measurements(%L,%L,%L,%L,%L)',f.actor,f.foreign_org,f.listing,new_plan,old_plan),'P0002','wrong org does not disclose or modify listing');
 perform pg_temp.cas_refuses(format('select save_listing_measurements(%L,%L,%L,%L,%L)',f.outsider,f.org,f.listing,new_plan,old_plan),'42501','non-member denied');
 perform pg_temp.cas_refuses(format('select save_listing_measurements(%L,%L,%L,%L,%L)',f.viewer,f.org,f.listing,new_plan,old_plan),'42501','read-only marketing viewer denied');
 perform pg_temp.cas_refuses(format('select save_listing_measurements(%L,%L,%L,%L,%L)',f.actor,f.org,f.conflict_listing,null,new_plan),'PT409','conflicting legacy aliases refuse ambiguous overwrite');
 perform pg_temp.cas_check((select details ? 'floorMeasurementsV1' and details ? 'floor_measurements_v1' from listings where id=f.conflict_listing),'conflicting aliases stay intact and recoverable');
 -- A stale build writes its renamed map, then an empty map. Existing private
 -- measurement namespaces survive both, and known aliases remain canonical.
 update listings set details=jsonb_build_object('floorMeasurementsV1',old_plan,'legacy_note','older client') where id=f.listing;
 select details->>'floor_measurements_v1' into saved from listings where id=f.listing;
 perform pg_temp.cas_check(saved=new_plan,'stale renamed ordinary PATCH cannot overwrite plan');
 perform pg_temp.cas_check((select not details ? 'floorMeasurementsV1' and details->>'floorMeasurementsV9'='opaque-future-version' from listings where id=f.listing),'stale PATCH retains canonical and future namespace');
 update listings set details='{}'::jsonb where id=f.listing;
 perform pg_temp.cas_check((select details->>'floor_measurements_v1'=new_plan and details->>'floorMeasurementsV9'='opaque-future-version' from listings where id=f.listing),'empty ordinary PATCH cannot delete private measurement namespace');
 perform pg_temp.cas_check(coalesce(current_setting('rendprop.measurement_cas',true),'')<>'allowed','RPC restores bypass setting');
 foreach bad in array array['{}','{"rooms":[],"unit":"meters","updatedAt":812345678}', '{"version":1,"rooms":[],"updatedAt":812345678}', '{"version":1,"unit":"meters","rooms":[]}', '{"version":1,"unit":"yards","rooms":[],"updatedAt":812345678}', '{"version":1,"unit":"meters","rooms":[],"updatedAt":"yesterday"}','{"version":3,"rooms":[]}','{"version":"2","rooms":[],"outlines":[]}','{"version":2,"rooms":[]}','{"version":2,"rooms":[],"outlines":null}','{"version":1,"rooms":null}','[]'] loop
  perform pg_temp.cas_refuses(format('select save_listing_measurements(%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,new_plan,bad),'22023','invalid plan shape/version refused: '||bad);
 end loop;
 perform pg_temp.cas_refuses(format('select save_listing_measurements(%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,new_plan,repeat('x',10001)),'22023','plan byte cap refused');
 perform pg_temp.cas_refuses(format('update listings set details=%L::jsonb where id=%L',jsonb_build_object('caption',repeat('é',8000))::text,f.listing),'22023','ordinary merged details UTF-8 byte envelope refused');
 perform pg_temp.cas_check((select details->>'floor_measurements_v1'=new_plan and not details ? 'caption' from listings where id=f.listing),'failed full-envelope edit preserves exact plan');
 update listings set details=jsonb_build_object('existing_note',repeat('n',7000)) where id=f.listing;
 bad:=jsonb_build_object('version',2,'unit','meters','rooms','[]'::jsonb,'outlines','[]'::jsonb,'updatedAt',812345678,'memo',repeat('m',9400))::text;
 perform pg_temp.cas_check(octet_length(bad)<10000,'synthetic new plan fits its own cap');
 perform pg_temp.cas_refuses(format('select save_listing_measurements(%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,new_plan,bad),'22023','CAS merged details envelope refused despite plan under cap');
 perform pg_temp.cas_check((select details->>'floor_measurements_v1'=new_plan and length(details->>'existing_note')=7000 from listings where id=f.listing),'CAS envelope failure retains plan and unrelated metadata');
 bad:=jsonb_build_object('version',1,'unit','meters','rooms',jsonb_agg('{}'::jsonb),'updatedAt',812345678)::text from generate_series(1,25);
 perform pg_temp.cas_refuses(format('select save_listing_measurements(%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,new_plan,bad),'22023','room count cap refused');
 bad:=jsonb_build_object('version',2,'unit','meters','rooms','[]'::jsonb,'outlines',jsonb_agg('{}'::jsonb),'updatedAt',812345678)::text from generate_series(1,13);
 perform pg_temp.cas_refuses(format('select save_listing_measurements(%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,new_plan,bad),'22023','outline count cap refused');

 perform pg_temp.cas_refuses(format('select save_listing_measurements(%L,%L,%L,%L,%L)',f.deleting_actor,f.org,f.listing,new_plan,old_plan),'42501','deleting account denied');
 update orgs set deleted_at=now() where id=f.org;
 perform pg_temp.cas_refuses(format('select save_listing_measurements(%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,new_plan,old_plan),'42501','deleted workspace denied');
 update orgs set deleted_at=null where id=f.org;
 update listings set deleted_at=now() where id=f.listing;
 perform pg_temp.cas_refuses(format('select save_listing_measurements(%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,new_plan,old_plan),'P0002','deleted listing denied');
end $$;
reset role;
select jsonb_build_object('assertions',n,'passed',true) from measurement_cas_assertions;
rollback;
