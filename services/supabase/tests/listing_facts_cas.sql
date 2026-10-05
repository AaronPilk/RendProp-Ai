begin;
create temp table facts_checks(name text);
create or replace function pg_temp.facts_check(ok boolean,label text) returns void language plpgsql as $$
begin if not coalesce(ok,false) then raise exception 'FAIL: %',label; end if; insert into facts_checks values(label); end $$;
create or replace function pg_temp.facts_refuses(q text,code text,label text) returns void language plpgsql as $$
begin begin execute q; exception when others then
 if sqlstate=code then perform pg_temp.facts_check(true,label); return; end if;
 raise exception 'FAIL: % expected %, got % %',label,code,sqlstate,sqlerrm;
 end;raise exception 'FAIL: % did not refuse',label;end $$;
create temp table facts_ids as select gen_random_uuid() actor,gen_random_uuid() second_actor,gen_random_uuid() viewer,
 gen_random_uuid() outsider,gen_random_uuid() deleting_actor,gen_random_uuid() org,gen_random_uuid() foreign_org,gen_random_uuid() listing;
do $$ declare f facts_ids; begin select * into f from facts_ids;
 insert into auth.users(id,email) values(f.actor,'facts-owner@example.invalid'),(f.second_actor,'facts-agent@example.invalid'),(f.viewer,'facts-viewer@example.invalid'),(f.outsider,'facts-outsider@example.invalid'),(f.deleting_actor,'facts-deleting@example.invalid');
 insert into orgs(id,name,plan) values(f.org,'Synthetic facts CAS','pro'),(f.foreign_org,'Synthetic foreign facts','pro');
 insert into memberships(user_id,org_id,role) values(f.actor,f.org,'owner'),(f.second_actor,f.org,'agent'),(f.viewer,f.org,'marketing'),(f.outsider,f.foreign_org,'owner'),(f.deleting_actor,f.org,'agent');
 insert into deletion_requests(user_id,status) values(f.deleting_actor,'pending');
 insert into listings(id,org_id,agent_id,address,sqft,status,sold_at,price_cents,beds,baths,lat,lng,details)
 values(f.listing,f.org,f.actor,'Office corrected property',2345,'archived','2026-09-30 12:00:00+00',85000000,4,3,35.001,-80.001,
 jsonb_build_object('floor_measurements_v1','{"version":1,"unit":"meters","rooms":[],"updatedAt":1}','floorMeasurementsV9','future-private','floorplan_asset_id','office-plan','office_note','unknown server value','allow_indexing','false','hours',null,'capacitySeated',20,'is247',false));
end $$;
grant all on facts_ids,facts_checks to service_role;
set local role service_role;
do $$ declare f facts_ids; before_row jsonb; r jsonb; sql text; k text; begin
 select * into f from facts_ids;select to_jsonb(l) into before_row from listings l where id=f.listing;
 perform pg_temp.facts_check(has_function_privilege('service_role','public.save_listing_facts(uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb)','execute'),'Service RPC available');
 for k in select unnest(array['anon','authenticated']) loop
  perform pg_temp.facts_check(not has_function_privilege(k,'public.save_listing_facts(uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb)','execute'),'RPC denies client '||k);
 end loop;
 for k in select unnest(array['space_type','address','tagline','details','beds','baths','sqft','price_cents','zillow_url','lat','lng','sold_at','status']) loop
  perform pg_temp.facts_check(not has_column_privilege('authenticated','public.listings',k,'update'),'Direct fact writes are fenced: '||k);
 end loop;
 r:=public.save_listing_facts(f.actor,f.org,f.listing,'{"lat":35.001,"lng":-80.001}','{"lat":35.235,"lng":-80.346}','{}','{}');
 perform pg_temp.facts_check(r->>'lat'='35.235' and r->>'lng'='-80.346','Paired coordinates saved');
 for k in select unnest(array['address','sqft','price_cents','status','sold_at','details']) loop
  perform pg_temp.facts_check(r->k=before_row->k,'Coordinate edit preserves office '||k);
 end loop;
 perform pg_temp.facts_check(public.save_listing_facts(f.actor,f.org,f.listing,'{"lat":35.001,"lng":-80.001}','{"lat":35.235,"lng":-80.346}','{}','{}')=r,'Lost receipt retry returns saved row');
 sql:=format('select public.save_listing_facts(%L,%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,'{"sqft":900}','{"sqft":901}','{}','{}');
 perform pg_temp.facts_refuses(sql,'40001','Conflicting edits keep shared square footage');
 r:=public.save_listing_facts(f.actor,f.org,f.listing,'{"beds":4}','{"beds":5}','{"allow_indexing":{"present":true,"value":"false"}}','{"allow_indexing":"true"}');
 perform pg_temp.facts_check(r->>'beds'='5' and r->'details'->>'allow_indexing'='true','Explicit field and detail edits apply atomically');
 for k in select unnest(array['floorplan_asset_id','office_note','floor_measurements_v1','floorMeasurementsV9']) loop
  perform pg_temp.facts_check(r->'details'->k=before_row->'details'->k,'Detail-key edit preserves '||k);
 end loop;
 sql:=format('select public.save_listing_facts(%L,%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,'{"beds":5}','{"beds":6}','{"allow_indexing":{"present":true,"value":"false"}}','{"allow_indexing":"false"}');
 perform pg_temp.facts_refuses(sql,'40001','A detail conflict rolls back all fields');
 perform pg_temp.facts_check((select beds=5 from listings where id=f.listing),'No partial save after conflict');
 r:=public.save_listing_facts(f.actor,f.org,f.listing,'{"sold_at":"2026-09-30T12:00:00.000Z"}','{"sold_at":null}','{}','{}');
 perform pg_temp.facts_check(r->'sold_at'='null' and r->>'status'='archived','Timestamp spelling normalizes; deliberate un-sell preserves server status');
 update public.listings set sold_at='2026-10-04T12:00:00.123456+00:00' where id=f.listing;
 r:=public.save_listing_facts(f.actor,f.org,f.listing,'{"sold_at":"2026-10-04T12:00:00.123456+00:00"}','{"sold_at":null}','{}','{}');
 perform pg_temp.facts_check(r->'sold_at'='null','Exact raw microsecond timestamp can clear sold status');
 r:=public.save_listing_facts(f.actor,f.org,f.listing,'{"status":"archived"}','{"status":"ready"}','{}','{}');
 perform pg_temp.facts_check(r->>'status'='ready','Explicit Studio restore intent applies');
 sql:=format('select public.save_listing_facts(%L,%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,'{"status":"ready"}','{"status":"invalid"}','{}','{}');
 perform pg_temp.facts_refuses(sql,'22023','Invalid explicit status refused');
 r:=public.save_listing_facts(f.second_actor,f.org,f.listing,'{"tagline":null}','{"tagline":"Agent edit"}','{}','{}');
 perform pg_temp.facts_check(r->>'tagline'='Agent edit','Agent membership permits edit');
 for k in select unnest(array['viewer','outsider','deleting_actor']) loop
  sql:=format('select public.save_listing_facts(%L,%L,%L,%L,%L,%L,%L)',case k when 'viewer' then f.viewer when 'outsider' then f.outsider else f.deleting_actor end,f.org,f.listing,'{"tagline":"Agent edit"}','{"tagline":"Forbidden"}','{}','{}');
  perform pg_temp.facts_refuses(sql,'42501','Refuse unauthorized actor '||k);
 end loop;
 sql:=format('select public.save_listing_facts(%L,%L,%L,%L,%L,%L,%L)',f.actor,f.foreign_org,f.listing,'{"beds":5}','{"beds":6}','{}','{}');
 perform pg_temp.facts_refuses(sql,'P0002','Foreign workspace cannot target listing');
 for k in select unnest(array['org_id','agent_id','main_photo_key']) loop
  sql:=format('select public.save_listing_facts(%L,%L,%L,%L::jsonb,%L::jsonb,%L,%L)',f.actor,f.org,f.listing,jsonb_build_object(k,'old'),jsonb_build_object(k,'new'),'{}','{}');
  perform pg_temp.facts_refuses(sql,'22023','Unrelated server-controlled field refused: '||k);
 end loop;
 sql:=format('select public.save_listing_facts(%L,%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,'{"lat":35.235}','{"lat":36}','{}','{}');
 perform pg_temp.facts_refuses(sql,'22023','A single coordinate is refused');
 sql:=format('select public.save_listing_facts(%L,%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,'{"lat":35.235,"lng":-80.346}','{"lat":null,"lng":-80}','{}','{}');
 perform pg_temp.facts_refuses(sql,'22023','Mixed missing coordinate pair is refused');
 sql:=format('select public.save_listing_facts(%L,%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,'{}','{"beds":6}','{}','{}');
 perform pg_temp.facts_refuses(sql,'22023','Missing expected value refused');
 sql:=format('select public.save_listing_facts(%L,%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,'{}','{}','{"floorplan_asset_id":{"present":true,"value":"office-plan"}}','{"floorplan_asset_id":null}');
 perform pg_temp.facts_refuses(sql,'22023','Phone facts cannot remove Studio attachment');
 sql:=format('select public.save_listing_facts(%L,%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,'{}','{}','{"hours":{"present":false,"value":null}}','{"hours":"9-5"}');
 perform pg_temp.facts_refuses(sql,'40001','Absent detail is distinct from explicit JSON null');
 r:=public.save_listing_facts(f.actor,f.org,f.listing,'{}','{}','{"hours":{"present":true,"value":null}}','{"hours":"9-5"}');
 perform pg_temp.facts_check(r->'details'->>'hours'='9-5','Explicit JSON null baseline edits successfully');
 r:=public.save_listing_facts(f.actor,f.org,f.listing,'{}','{}','{"capacitySeated":{"present":true,"value":20},"is247":{"present":true,"value":false},"website":{"present":false,"value":null}}','{"capacitySeated":"25","is247":"true","website":"https://fixture.invalid"}');
 perform pg_temp.facts_check(r->'details'->>'capacitySeated'='25' and r->'details'->>'is247'='true' and r->'details'->>'website'='https://fixture.invalid','Raw number boolean and absent baselines save');
 sql:=format('select public.save_listing_facts(%L,%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,'{"baths":3}','{"baths":3.25}','{}','{}');
 perform pg_temp.facts_refuses(sql,'22023','Uncanonical bathroom precision refused');
end $$;
reset role;
select jsonb_build_object('passed',true,'assertions',count(*)) from facts_checks;
rollback;
