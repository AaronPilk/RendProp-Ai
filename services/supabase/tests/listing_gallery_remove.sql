\set ON_ERROR_STOP on
begin;
do $$begin if current_database()<>'gallery_remove_proof' or inet_server_addr()is not null then
 raise exception 'Use only the disposable socket-only gallery_remove_proof database';end if;end$$;
create temp table checks(label text primary key);
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin
 if v is distinct from true then raise exception 'GALLERY REMOVE FAIL: %',label;end if;insert into checks values(label);end$$;
create function pg_temp.denied(command text,label text,prefix text default 'RP400:')returns void language plpgsql as $$declare msg text;begin
 begin execute command;exception when others then msg:=sqlerrm;end;
 perform pg_temp.ok(msg like prefix||'%',label);end$$;
-- BEGIN FIXTURE
create temp table gf(actor uuid,outsider uuid,marketing uuid,org uuid,other_org uuid,listing uuid,other_listing uuid,
 p1 uuid,p2 uuid,p3 uuid,foreign_photo uuid,unready uuid,video uuid,headshot uuid,forged uuid);
do $$declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();m uuid:=gen_random_uuid();o uuid;oo uuid;
 l uuid:=gen_random_uuid();ol uuid:=gen_random_uuid();p1 uuid:=gen_random_uuid();p2 uuid:=gen_random_uuid();p3 uuid:=gen_random_uuid();
 f uuid:=gen_random_uuid();u uuid:=gen_random_uuid();v uuid:=gen_random_uuid();h uuid:=gen_random_uuid();z uuid:=gen_random_uuid();begin
 insert into auth.users(id,email,is_anonymous)values(a,'remove-owner@fixture.invalid',false),(b,'remove-outsider@fixture.invalid',false),(m,'remove-marketing@fixture.invalid',false);
 select org_id into o from public.memberships where user_id=a;select org_id into oo from public.memberships where user_id=b;
 insert into public.memberships(user_id,org_id,role)values(m,o,'marketing');
 -- Gallery removal is tested on existing paid homes, not Free creation.
 update public.orgs set plan='starter',plan_source='manual' where id in(o,oo);
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
select pg_temp.ok(has_function_privilege('service_role','public.remove_listing_gallery(uuid,uuid,uuid,uuid,uuid[],uuid[],text)','EXECUTE')
 and not has_function_privilege('authenticated','public.remove_listing_gallery(uuid,uuid,uuid,uuid,uuid[],uuid[],text)','EXECUTE')
 and not has_function_privilege('anon','public.remove_listing_gallery(uuid,uuid,uuid,uuid,uuid[],uuid[],text)','EXECUTE'),'RPC remains service-only');
select pg_temp.ok((select relrowsecurity from pg_class where oid='public.listing_gallery_removals'::regclass)
 and not has_table_privilege('authenticated','public.listing_gallery_removals','SELECT')
 and not has_table_privilege('anon','public.listing_gallery_removals','SELECT')
 and not has_table_privilege('service_role','public.listing_gallery_removals','UPDATE,DELETE,INSERT'),'operation journal cannot be forged or rewritten through clients');
set local role service_role;
do $$declare f record;r jsonb;op uuid:=gen_random_uuid();k1 text;k2 text;bad uuid;before_assets jsonb;before_provenance jsonb;n integer;begin
 select *into f from gf;k1:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p1||'.jpg';k2:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p2||'.jpg';
 r:=public.listing_gallery_snapshot(f.actor,f.org,f.listing);
 perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p1,f.p3,f.p2])and r->>'main_photo_key'=k1,'snapshot preserves exact raw gallery and cover CAS');
 perform pg_temp.ok(r->'gallery_assets'=jsonb_build_array(jsonb_build_object('asset_id',f.p1,'sha256',repeat('1',64),'bytes',100),jsonb_build_object('asset_id',f.p3,'sha256',repeat('3',64),'bytes',300),jsonb_build_object('asset_id',f.p2,'sha256',repeat('2',64),'bytes',200)),'snapshot exposes exact selected same-listing hash byte identities only');
 select jsonb_agg(to_jsonb(a)order by id)into before_assets from public.capture_assets a where listing_id=f.listing;
 select jsonb_agg(to_jsonb(m)order by id)into before_provenance from public.media_provenance m where listing_id=f.listing;
 r:=public.remove_listing_gallery(f.actor,f.org,f.listing,op,array[f.p1],array[f.p1,f.p3,f.p2],k1);
 perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p3,f.p2]),'subtract preserves unknown remote photos and order');
 perform pg_temp.ok(r->>'main_photo_key'is null,'removing cover clears only removed cover');
 perform pg_temp.ok(r->'gallery_remove'=jsonb_build_object('operation_id',op,'actor_id',f.actor,'replayed',false,'requested_asset_ids',array[f.p1],'removed_asset_ids',array[f.p1]),'first removal exact immutable acknowledgment');
 r:=public.listing_gallery_snapshot(f.actor,f.org,f.listing);
 perform pg_temp.ok(jsonb_array_length(r->'gallery_assets')=2 and not exists(select 1 from jsonb_array_elements(r->'gallery_assets')a where a->>'asset_id'=f.p1::text),'snapshot cannot match an unselected historical upload');
 r:=public.remove_listing_gallery(f.actor,f.org,f.listing,op,array[f.p1],array[f.p1,f.p3,f.p2],k1);
 perform pg_temp.ok(r->'gallery_remove'=jsonb_build_object('operation_id',op,'actor_id',f.actor,'replayed',true,'requested_asset_ids',array[f.p1],'removed_asset_ids',array[f.p1]),'repeated operation retains exact actor and original removal receipt');
 update public.listings set gallery_asset_ids=array[f.p1,f.p3,f.p2],main_photo_key=k1 where id=f.listing;
 r:=public.remove_listing_gallery(f.actor,f.org,f.listing,op,array[f.p1],array[f.p1,f.p3,f.p2],k1);
 perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p1,f.p3,f.p2])and r->>'main_photo_key'=k1 and(r->'gallery_remove'->>'replayed')::boolean,'old operation replay cannot remove a later re-addition');
 perform pg_temp.ok((select count(*)=1 from public.listing_gallery_removals where actor_id=f.actor),'one action retains exactly one operation receipt');
 perform pg_temp.denied(format('select public.remove_listing_gallery(%L,%L,%L,%L,array[%L]::uuid[],array[%L,%L,%L]::uuid[],%L)',f.actor,f.org,f.listing,op,f.p2,f.p1,f.p3,f.p2,k1),'same operation cannot be rebound','RP409:');
 perform pg_temp.denied(format('select public.remove_listing_gallery(%L,%L,%L,%L,array[%L]::uuid[],array[%L,%L,%L]::uuid[],%L)',f.actor,f.org,f.listing,gen_random_uuid(),f.p1,f.p1,f.p2,f.p3,k1),'ordered stale gallery CAS refuses','RP409:');
 perform pg_temp.denied(format('select public.remove_listing_gallery(%L,%L,%L,%L,array[%L]::uuid[],array[%L,%L,%L]::uuid[],null)',f.actor,f.org,f.listing,gen_random_uuid(),f.p1,f.p1,f.p3,f.p2),'stale cover CAS refuses','RP409:');
 foreach bad in array array[f.foreign_photo,f.unready,f.video,f.headshot,f.forged,gen_random_uuid()]loop
  perform pg_temp.denied(format('select public.remove_listing_gallery(%L,%L,%L,%L,array[%L]::uuid[],array[%L,%L,%L]::uuid[],%L)',f.actor,f.org,f.listing,gen_random_uuid(),bad,f.p1,f.p3,f.p2,k1),'refuse unavailable or cross-property asset '||bad);
 end loop;
 perform pg_temp.denied(format('select public.remove_listing_gallery(%L,%L,%L,%L,array[%L]::uuid[],array[%L,%L,%L]::uuid[],%L)',f.outsider,f.org,f.listing,gen_random_uuid(),f.p1,f.p1,f.p3,f.p2,k1),'outsider cannot remove','RP404:');
 perform pg_temp.denied(format('select public.remove_listing_gallery(%L,%L,%L,%L,array[%L]::uuid[],array[%L,%L,%L]::uuid[],%L)',f.marketing,f.org,f.listing,gen_random_uuid(),f.p1,f.p1,f.p3,f.p2,k1),'read-only member cannot remove','RP403:');
 perform pg_temp.denied(format('select public.remove_listing_gallery(%L,%L,%L,%L,array[%L]::uuid[],array[%L,%L,%L]::uuid[],%L)',f.actor,f.other_org,f.listing,gen_random_uuid(),f.p1,f.p1,f.p3,f.p2,k1),'wrong explicit organization cannot remove','RP404:');
 perform pg_temp.denied(format('select public.remove_listing_gallery(%L,%L,%L,%L,array[%L,%L]::uuid[],array[%L,%L,%L]::uuid[],%L)',f.actor,f.org,f.listing,gen_random_uuid(),f.p1,f.p1,f.p1,f.p3,f.p2,k1),'duplicate removal IDs refuse');
 perform pg_temp.denied(format('select public.remove_listing_gallery(%L,%L,%L,%L,null,array[%L,%L,%L]::uuid[],%L)',f.actor,f.org,f.listing,gen_random_uuid(),f.p1,f.p3,f.p2,k1),'null removal IDs refuse');
 perform pg_temp.denied(format('select public.remove_listing_gallery(%L,%L,%L,%L,''{}''::uuid[],array[%L,%L,%L]::uuid[],%L)',f.actor,f.org,f.listing,gen_random_uuid(),f.p1,f.p3,f.p2,k1),'empty removal request refuses');
 -- Removing a known but currently absent photo is an acknowledged no-op.
 update public.listings set gallery_asset_ids=array[f.p2,f.p3],main_photo_key=k2 where id=f.listing;
 r:=public.remove_listing_gallery(f.actor,f.org,f.listing,gen_random_uuid(),array[f.p1],array[f.p2,f.p3],k2);
 perform pg_temp.ok(r->'gallery_remove'->'removed_asset_ids'='[]'::jsonb and r->'gallery_asset_ids'=to_jsonb(array[f.p2,f.p3])and r->>'main_photo_key'=k2,'already absent request preserves gallery and unrelated cover');
 r:=public.remove_listing_gallery(f.actor,f.org,f.listing,gen_random_uuid(),array[f.p2,f.p3],array[f.p2,f.p3],k2);
 perform pg_temp.ok(r->'gallery_asset_ids'='[]'::jsonb and r->>'main_photo_key'is null,'last removal stores explicit empty gallery and clears cover');
 perform pg_temp.ok((select gallery_asset_ids is not null and cardinality(gallery_asset_ids)=0 from public.listings where id=f.listing),'empty gallery never becomes legacy automatic fallback');
 update public.listings set gallery_asset_ids=null,main_photo_key=k1 where id=f.listing;
 r:=public.remove_listing_gallery(f.actor,f.org,f.listing,gen_random_uuid(),array[f.p2],null,k1);
 perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p1,f.p3])and r->>'main_photo_key'=k1,'legacy NULL materializes remaining uploaded photos without losing unknown cover');
 perform pg_temp.ok((select jsonb_agg(to_jsonb(a)order by id)=before_assets from public.capture_assets a where listing_id=f.listing),'all originals uploaded variants and media receipts remain byte-identical');
 perform pg_temp.ok((select jsonb_agg(to_jsonb(m)order by id)=before_provenance from public.media_provenance m where listing_id=f.listing),'all provenance and disclosures remain immutable');
 update public.orgs set deleted_at=now()where id=f.org;
 perform pg_temp.denied(format('select public.remove_listing_gallery(%L,%L,%L,%L,array[%L]::uuid[],array[%L,%L,%L]::uuid[],%L)',f.actor,f.org,f.listing,op,f.p1,f.p1,f.p3,f.p2,k1),'revoked workspace cannot replay an old receipt','RP404:');
end$$;
reset role;
select jsonb_build_object('passed',true,'assertions',count(*))from checks;
rollback;
