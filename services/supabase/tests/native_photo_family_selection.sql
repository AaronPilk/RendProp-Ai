\set ON_ERROR_STOP on
begin;
do $$begin if current_database()<>'native_selection_proof' or inet_server_addr()is not null then raise exception 'Disposable socket-only native_selection_proof required';end if;end$$;
create temp table checks(label text primary key);
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception 'NATIVE SELECTION FAIL: %',label;end if;insert into checks values(label);end$$;
create function pg_temp.denied(command text,label text,prefix text)returns void language plpgsql as $$declare msg text;begin begin execute command;exception when others then msg:=sqlerrm;end;perform pg_temp.ok(msg like prefix||'%',label);end$$;
-- BEGIN FIXTURE
create temp table gf(actor uuid,outsider uuid,marketing uuid,org uuid,other_org uuid,listing uuid,other_listing uuid,
 p1 uuid,p2 uuid,p3 uuid,foreign_photo uuid,unready uuid,video uuid,headshot uuid,forged uuid);
do $$declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();m uuid:=gen_random_uuid();o uuid;oo uuid;
 l uuid:=gen_random_uuid();ol uuid:=gen_random_uuid();p1 uuid:=gen_random_uuid();p2 uuid:=gen_random_uuid();p3 uuid:=gen_random_uuid();
 f uuid:=gen_random_uuid();u uuid:=gen_random_uuid();v uuid:=gen_random_uuid();h uuid:=gen_random_uuid();z uuid:=gen_random_uuid();begin
 insert into auth.users(id,email,is_anonymous)values(a,'remove-owner@fixture.invalid',false),(b,'remove-outsider@fixture.invalid',false),(m,'remove-marketing@fixture.invalid',false);
 select org_id into o from public.memberships where user_id=a;select org_id into oo from public.memberships where user_id=b;
 insert into public.memberships(user_id,org_id,role)values(m,o,'marketing');
 insert into public.listings(id,org_id,agent_id,address)values(l,o,a,'Synthetic selected home'),(ol,oo,b,'Synthetic other home');
 insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,created_at,bytes,sha256)values
 (p1,l,'photo','renders','renders/'||o||'/'||l||'/gallery-'||p1||'.jpg',true,now()-interval'3 minutes',100,repeat('1',64)),
 (p2,l,'photo','renders','renders/'||o||'/'||l||'/gallery-'||p2||'.jpg',true,now()-interval'2 minutes',200,repeat('2',64)),
 (p3,l,'photo','renders','renders/'||o||'/'||l||'/gallery-'||p3||'.jpg',true,now()-interval'1 minute',300,repeat('3',64)),
 (f,ol,'photo','renders','renders/'||oo||'/'||ol||'/gallery-'||f||'.jpg',true,now(),100,repeat('4',64)),
 (u,l,'photo','renders','renders/'||o||'/'||l||'/gallery-'||u||'.jpg',false,now(),100,repeat('5',64)),
 (v,l,'video','renders','renders/'||o||'/'||l||'/gallery-'||v||'.mp4',true,now(),100,repeat('6',64)),
 (h,l,'photo','renders','renders/'||o||'/'||l||'/contact-'||h||'.jpg',true,now(),100,repeat('7',64)),
 (z,l,'photo','renders','renders/'||oo||'/'||l||'/gallery-'||z||'.jpg',true,now(),100,repeat('8',64));
 insert into public.media_provenance(org_id,listing_id,kind,label,edit,original_key,altered_key,disclosure)
 values(o,l,'declutter','Synthetic retained edit','declutter','renders/'||o||'/'||l||'/gallery-'||p1||'.jpg','renders/'||o||'/'||l||'/gallery-'||p2||'.jpg','Synthetic immutable disclosure');
 insert into gf values(a,b,m,o,oo,l,ol,p1,p2,p3,f,u,v,h,z);
 update public.listings set gallery_asset_ids=array[p1,p3,p2],main_photo_key='renders/'||o||'/'||l||'/gallery-'||p1||'.jpg'where id=l;
end$$;
grant select on gf to service_role;
grant select,insert on checks to service_role;

-- END FIXTURE
create function pg_temp.intent(family uuid[],target uuid,sha text,bytes bigint,ids uuid[],cover text,follow boolean default false,reviewed boolean default false)returns jsonb language sql as $$select jsonb_build_object('family_asset_ids',family,'target',case when target is null then 'null'::jsonb else jsonb_build_object('asset_id',target,'sha256',sha,'bytes',bytes)end,'expected_selection',jsonb_build_object('gallery_asset_ids',ids,'main_photo_key',cover),'follow_family_cover',follow,'reviewed',reviewed)$$;
select pg_temp.ok(has_function_privilege('service_role','native_gallery_selection_change(uuid,uuid,uuid,uuid,uuid,jsonb)','EXECUTE')and not has_function_privilege('authenticated','native_gallery_selection_change(uuid,uuid,uuid,uuid,uuid,jsonb)','EXECUTE')and not has_function_privilege('anon','native_gallery_selection_snapshot(uuid,uuid,uuid,uuid,uuid)','EXECUTE'),'only trusted Edge may execute');
select pg_temp.ok((select relrowsecurity from pg_class where oid='native_gallery_selection_operations'::regclass)and not has_table_privilege('service_role','native_gallery_selection_operations','INSERT,UPDATE,DELETE,SELECT')and not has_table_privilege('authenticated','native_gallery_selection_operations','SELECT'),'receipt cannot be forged read or rewritten by client roles');
-- Synthetic metadata fixture helper only; no production permission is changed.
create function pg_temp.set_evidence(p_actor uuid,p_org uuid,p_listing uuid,p_purpose text,p_state text)returns void language plpgsql security definer set search_path='' as $$declare m uuid;begin
 select id into m from public.media_provenance where listing_id=p_listing;
 delete from public.photo_edit_evidence where org_id=p_org and actor_id=p_actor and request_key='native-selection-fixture';
 delete from public.serving_operations where org_id=p_org and actor_id=p_actor and request_key='native-selection-fixture';
 if p_purpose is not null then
  insert into public.serving_operations(org_id,actor_id,request_key,operation,input_sha256)values(p_org,p_actor,'native-selection-fixture','synthetic-photo-evidence',repeat('a',64));
  insert into public.photo_edit_evidence(org_id,actor_id,listing_id,library_org_id,request_key,request_sha256,policy,edit,input,provenance_id,state,purpose)
  values(p_org,p_actor,p_listing,p_org,'native-selection-fixture',repeat('a',64),'photo-fixed-features-v1','declutter','{}',m,p_state,p_purpose);
 end if;
end$$;
set local role service_role;
do $$declare f record;r jsonb;request jsonb;op uuid:=gen_random_uuid();k1 text;k2 text;k3 text;bad uuid;before_assets jsonb;before_provenance jsonb;retained_original jsonb;begin
select *into f from gf;k1:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p1||'.jpg';k2:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p2||'.jpg';k3:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p3||'.jpg';
select jsonb_agg(to_jsonb(a)order by id)into before_assets from capture_assets a where listing_id=f.listing;
select jsonb_agg(to_jsonb(a)order by id)into before_provenance from media_provenance a where listing_id=f.listing;
r:=native_gallery_selection_snapshot(f.actor,f.org,f.org,f.listing,null);
perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p1,f.p3,f.p2])and r->>'main_photo_key'=k1 and r->'operation'='null','read keeps raw ordered selection cover and absent receipt');
perform pg_temp.ok(r->'schema'='1'and r->>'actor_id'=f.actor::text and r->>'library_org_id'=f.org::text and r->>'org_id'=f.org::text and r->>'listing_id'=f.listing::text,'read binds actor physical org logical library and listing');
perform pg_temp.ok(r->'gallery_assets'->0=jsonb_build_object('asset_id',f.p1,'sha256',repeat('1',64),'bytes',100,'storage_key',k1),'read exposes exact selected byte identity and canonical key');
update listings set gallery_asset_ids=array[f.p3,f.p2],main_photo_key=k3 where id=f.listing;
request:=pg_temp.intent(array[f.p1,f.p2],f.p1,repeat('1',64),100,array[f.p3,f.p2],k3);
r:=native_gallery_selection_change(f.actor,f.org,f.org,f.listing,op,request);
perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p3,f.p1])and r->>'main_photo_key'=k3,'Original replaces edited family in place while preserving unrelated cover and slot');
perform pg_temp.ok(r->'ok'='true'and r->'replayed'='false'and r->'operation'->>'operation_id'=op::text and r->'operation'->'request'=request and r->'operation'->'result'=jsonb_build_object('gallery_asset_ids',array[f.p3,f.p1],'main_photo_key',k3),'first exact immutable operation receipt matches intent and effect');
r:=native_gallery_selection_change(f.actor,f.org,f.org,f.listing,op,request);
perform pg_temp.ok(r->'replayed'='true'and r->'gallery_asset_ids'=to_jsonb(array[f.p3,f.p1]),'same operation replays without requiring old CAS');
update listings set gallery_asset_ids=array[f.p1,f.p3,f.p2],main_photo_key=k1 where id=f.listing;
r:=native_gallery_selection_change(f.actor,f.org,f.org,f.listing,op,request);
perform pg_temp.ok(r->'replayed'='true'and r->'gallery_asset_ids'=to_jsonb(array[f.p1,f.p3,f.p2])and r->>'main_photo_key'=k1 and r->'operation'->'result'->'gallery_asset_ids'=to_jsonb(array[f.p3,f.p1]),'historical replay returns current state and cannot overwrite later choices');
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,op,request||'{"reviewed":true}'),'operation cannot be rebound to changed intent','RP409:');
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'stale ordered selection refuses before mutation','RP409: The listing photo selection changed');
request:=pg_temp.intent(array[f.p1],null,null,null,array[f.p1,f.p3,f.p2],null);
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'stale cover alone refuses','RP409: The listing photo selection changed');
request:=pg_temp.intent(array[f.p1,f.p2],null,null,null,array[f.p1,f.p3,f.p2],k1);
r:=native_gallery_selection_change(f.actor,f.org,f.org,f.listing,gen_random_uuid(),request);
perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p3])and r->'main_photo_key'='null','unselect removes whole declared family and clears only its cover');
request:=pg_temp.intent(array[f.p1,f.p2],f.p2,repeat('2',64),200,array[f.p3],null,false,true);
r:=native_gallery_selection_change(f.actor,f.org,f.org,f.listing,gen_random_uuid(),request);
perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p3,f.p2])and r->'main_photo_key'='null','reviewed accepted edit can be appended after unselect without choosing a cover');
update listings set main_photo_key=k2 where id=f.listing;
request:=pg_temp.intent(array[f.p1,f.p2],f.p1,repeat('1',64),100,array[f.p3,f.p2],k2,true,false);
r:=native_gallery_selection_change(f.actor,f.org,f.org,f.listing,gen_random_uuid(),request);
perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p3,f.p1])and r->>'main_photo_key'=k1,'explicit family cover follows exact original without false AI review');
request:=pg_temp.intent(array[f.p1,f.p2],f.p2,repeat('2',64),200,array[f.p3,f.p1],k1,false,true);
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'family cover replacement needs explicit follow confirmation','RP409: Confirm the current family cover');
request:=pg_temp.intent(array[f.p1,f.p2],f.p2,repeat('2',64),200,array[f.p3,f.p1],k1,true,false);
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'accepted altered photo needs explicit comparison review','RP409: Compare the accepted edit');
request:=pg_temp.intent(array[f.p1,f.p2],f.p2,repeat('2',64),200,array[f.p3,f.p1],k1,true,true);
perform pg_temp.set_evidence(f.actor,f.org,f.listing,'prospective','accept');
r:=native_gallery_selection_change(f.actor,f.org,f.org,f.listing,gen_random_uuid(),request);
perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p3,f.p2])and r->>'main_photo_key'=k2,'accepted prospective evidence admits reviewed exact edit');
update listings set gallery_asset_ids=array[f.p3,f.p1],main_photo_key=k1 where id=f.listing;
perform pg_temp.set_evidence(f.actor,f.org,f.listing,'calibration','accept');
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'accepted calibration evidence is never deliverable','RP409: Compare the accepted edit');
perform pg_temp.set_evidence(f.actor,f.org,f.listing,'prospective','hold');
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'held prospective evidence refuses despite legacy QC absence','RP409: Compare the accepted edit');
perform pg_temp.set_evidence(f.actor,f.org,f.listing,null,null);
update media_provenance set kind='aerial'where listing_id=f.listing;
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'non-photo provenance cannot justify edited photo','RP409: Compare the accepted edit');
update media_provenance set kind='declutter',original_key=k2 where listing_id=f.listing;
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'edited target cannot be its own retained original','RP409: Compare the accepted edit');
update media_provenance set original_key=k1 where listing_id=f.listing;
update media_provenance set qc='{"publishable":false,"action":"hold"}'where listing_id=f.listing;
request:=pg_temp.intent(array[f.p1,f.p2],f.p2,repeat('2',64),200,array[f.p3,f.p1],k1,true,true);
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'held altered target refuses even after client review','RP409: Compare the accepted edit');
update media_provenance set qc=null where listing_id=f.listing;
select to_jsonb(a)into retained_original from capture_assets a where id=f.p1;
update listings set gallery_asset_ids=array[f.p3],main_photo_key=null where id=f.listing;
delete from capture_assets where id=f.p1;
request:=pg_temp.intent(array[f.p2],f.p2,repeat('2',64),200,array[f.p3],null,false,true);
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'missing retained original refuses edited target','RP409: The retained original is unavailable');
insert into capture_assets select *from jsonb_populate_record(null::public.capture_assets,retained_original);
update listings set gallery_asset_ids=array[f.p3,f.p1],main_photo_key=k1 where id=f.listing;
request:=pg_temp.intent(array[f.p1,f.p2],f.p1,repeat('9',64),100,array[f.p3,f.p1],k1,true,false);
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'changed target fingerprint refuses','RP409: The exact prepared photo changed');
request:=pg_temp.intent(array[f.p1,f.p2],f.p1,repeat('1',64),101,array[f.p3,f.p1],k1,true,false);
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'changed target byte length refuses','RP409: The exact prepared photo changed');
foreach bad in array array[f.foreign_photo,f.unready,f.video,f.headshot,f.forged,gen_random_uuid()]loop
request:=pg_temp.intent(array[bad],null,null,null,array[f.p3,f.p1],k1);
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'unavailable footprint refuses '||bad,'RP409: One of the exact family assets');end loop;
request:=pg_temp.intent(array[f.p1],null,null,null,array[f.p3,f.p1],k1);
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.outsider,f.org,f.org,f.listing,gen_random_uuid(),request),'outsider cannot mutate','RP404:');
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.marketing,f.org,f.org,f.listing,gen_random_uuid(),request),'read-only member cannot mutate','RP403:');
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.other_org,f.listing,gen_random_uuid(),request),'wrong logical library cannot mutate','RP404:');
perform pg_temp.denied(format('select native_gallery_selection_snapshot(%L,%L,%L,%L,%L)',f.actor,f.org,f.other_org,f.listing,op),'wrong logical library cannot read receipt','RP404:');
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request||'{"org_id":"forged"}'),'unknown body fields refuse','RP400:');
request:=pg_temp.intent(array[f.p1,f.p1],null,null,null,array[f.p3,f.p1],k1);
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'duplicate family footprints refuse','RP400:');
update listings set gallery_asset_ids='{}',main_photo_key=null where id=f.listing;
request:=pg_temp.intent(array[f.p1],null,null,null,null,null);
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),request),'raw NULL does not match explicit empty selection','RP409: The listing photo selection changed');
request:=pg_temp.intent(array[f.p1],f.p1,repeat('1',64),100,'{}',null);
r:=native_gallery_selection_change(f.actor,f.org,f.org,f.listing,gen_random_uuid(),request);
perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p1]),'explicit empty can add exact Original without legacy fallback');
update listings set gallery_asset_ids=null,main_photo_key=k1 where id=f.listing;
r:=native_gallery_selection_snapshot(f.actor,f.org,f.org,f.listing,null);
request:=pg_temp.intent(array[f.p1],null,null,null,null,k1);
r:=native_gallery_selection_change(f.actor,f.org,f.org,f.listing,gen_random_uuid(),request);
perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p2,f.p3])and r->'main_photo_key'='null','legacy NULL follows current projection and preserves other upload order');
perform pg_temp.ok((select jsonb_agg(to_jsonb(a)order by id)=before_assets from capture_assets a where listing_id=f.listing),'all historical source assets remain byte-identical');
perform pg_temp.ok((select jsonb_agg(to_jsonb(a)order by id)=before_provenance from media_provenance a where listing_id=f.listing),'all provenance and disclosures remain byte-identical');
update orgs set deleted_at=now()where id=f.org;
perform pg_temp.denied(format('select native_gallery_selection_snapshot(%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,op),'revoked authority cannot read old receipt','RP404:');
end$$;
reset role;
select jsonb_build_object('passed',true,'assertions',count(*))from checks;
rollback;
