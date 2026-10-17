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

select pg_temp.ok((select relrowsecurity from pg_class where oid='native_gallery_selection_abandonments'::regclass)and not has_table_privilege('service_role','native_gallery_selection_abandonments','SELECT,INSERT,UPDATE,DELETE'),'tombstones remain private and unforgeable');
create function pg_temp.operation_counts(actor uuid,op uuid)returns jsonb language sql security definer set search_path='' as $$select jsonb_build_object('accepted',(select count(*)from public.native_gallery_selection_operations where actor_id=actor and operation_id=op),'abandoned',(select count(*)from public.native_gallery_selection_abandonments where actor_id=actor and operation_id=op))$$;
set local role service_role;
do $$declare f record;r jsonb;q jsonb;op uuid;accepted jsonb;k1 text;k2 text;k3 text;before_assets jsonb;before_provenance jsonb;begin
select *into f from gf;k1:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p1||'.jpg';k2:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p2||'.jpg';k3:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p3||'.jpg';
select jsonb_agg(to_jsonb(a)order by id)into before_assets from capture_assets a where listing_id=f.listing;
select jsonb_agg(to_jsonb(a)order by id)into before_provenance from media_provenance a where listing_id=f.listing;
r:=native_gallery_selection_snapshot_v2(f.actor,f.org,f.org,f.listing,null);
perform pg_temp.ok(r->'operation_status'='null'and r->'abandoned_operation'='null'and r->'operation'='null','no requested operation has null status');
op:=gen_random_uuid();r:=native_gallery_selection_snapshot_v2(f.actor,f.org,f.org,f.listing,op);
perform pg_temp.ok(r->>'operation_status'='not_found'and r->'operation'='null','absence is explicit not_found without a terminal acknowledgement');
q:=pg_temp.intent(array[f.p1],null,null,null,array[f.p1,f.p3,f.p2],k1);
r:=native_gallery_selection_abandon(f.actor,f.org,f.org,f.listing,op,q);
perform pg_temp.ok(r->'ok'='true'and r->'abandoned'='true'and r->'replayed'='false'and r->>'operation_status'='abandoned'and r->'operation'='null'and r->'abandoned_operation'=jsonb_build_object('operation_id',op,'request',q),'abandon records exact immutable request and explicit terminal status');
perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p1,f.p3,f.p2])and r->>'main_photo_key'=k1,'abandon never changes gallery or cover');
r:=native_gallery_selection_abandon(f.actor,f.org,f.org,f.listing,op,q);
perform pg_temp.ok(r->'replayed'='true'and r->'abandoned'='true','same abandonment is idempotent');
perform pg_temp.denied(format('select native_gallery_selection_abandon(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,op,q||'{"reviewed":true}'),'abandon cannot rebind exact request','RP400:');
perform pg_temp.denied(format('select native_gallery_selection_abandon(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,op,q||jsonb_build_object('expected_selection',jsonb_build_object('gallery_asset_ids',array[f.p1,f.p3,f.p2],'main_photo_key',null))),'abandon cannot rebind valid changed frozen snapshot','RP409:');
perform pg_temp.denied(format('select native_gallery_selection_abandon(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.other_org,f.listing,op,q),'abandon cannot borrow another library','RP404:');
perform pg_temp.denied(format('select native_gallery_selection_change_v2(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,op,q),'delayed new PATCH cannot start abandoned operation','RP409: This saved photo operation was abandoned');
perform pg_temp.denied(format('select native_gallery_selection_change(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,op,q),'delayed legacy PATCH cannot start abandoned operation','RP409: This saved photo operation was abandoned');
perform pg_temp.ok(pg_temp.operation_counts(f.actor,op)='{"accepted":0,"abandoned":1}'::jsonb,'abandoned operation has exactly one tombstone and no accepted receipt');
-- Even an obsolete expected selection can be abandoned: it never changes current photos.
update listings set gallery_asset_ids=array[f.p3,f.p1],main_photo_key=k3 where id=f.listing;
r:=native_gallery_selection_snapshot_v2(f.actor,f.org,f.org,f.listing,op);
perform pg_temp.ok(r->>'operation_status'='abandoned'and r->'gallery_asset_ids'=to_jsonb(array[f.p3,f.p1])and r->>'main_photo_key'=k3,'tombstone GET returns fresh current state');
r:=native_gallery_selection_abandon(f.actor,f.org,f.org,f.listing,gen_random_uuid(),q);
perform pg_temp.ok(r->'abandoned'='true'and r->'gallery_asset_ids'=to_jsonb(array[f.p3,f.p1]),'stale never-accepted request can be safely abandoned');
q:=pg_temp.intent(array[f.p1,f.p2],f.p1,repeat('1',64),100,array[f.p3,f.p1],k3);op:=gen_random_uuid();
r:=native_gallery_selection_change(f.actor,f.org,f.org,f.listing,op,q);accepted:=r->'operation';
update listings set main_photo_key=null where id=f.listing;
r:=native_gallery_selection_abandon(f.actor,f.org,f.org,f.listing,op,q);
perform pg_temp.ok(r->'abandoned'='false'and r->>'operation_status'='accepted'and r->'operation'=accepted and r->'main_photo_key'='null','accepted legacy receipt wins untouched while current state is fresh');
perform pg_temp.ok(pg_temp.operation_counts(f.actor,op)->'abandoned'='0','accepted operation never gains a conflicting tombstone');
perform pg_temp.denied(format('select native_gallery_selection_abandon(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,op,q||'{"promote_cover":true}'),'accepted operation cannot be abandoned under another intent','RP409:');
q:=pg_temp.intent(array[f.p1,f.p2],f.p1,repeat('1',64),100,array[f.p3,f.p1],null);op:=gen_random_uuid();
r:=native_gallery_selection_change_v2(f.actor,f.org,f.org,f.listing,op,q||'{"promote_cover":false}');
perform pg_temp.ok(r->>'operation_status'='accepted'and r->'operation'->'request'=q and not(r->'operation'->'request'?'promote_cover')and r->'main_photo_key'='null'and r->'gallery_asset_ids'=to_jsonb(array[f.p3,f.p1]),'false cover intent retains exact old five-key receipt without cover mutation');
r:=native_gallery_selection_abandon(f.actor,f.org,f.org,f.listing,op,q);
perform pg_temp.ok(r->'abandoned'='false'and r->'operation'->'request'=q,'accepted v2 normal receipt wins abandonment');
q:=pg_temp.intent(array[f.p1,f.p2],f.p1,repeat('1',64),100,array[f.p3,f.p1],null)||'{"promote_cover":true}';op:=gen_random_uuid();
r:=native_gallery_selection_change_v2(f.actor,f.org,f.org,f.listing,op,q);accepted:=r->'operation';
perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p3,f.p1])and r->>'main_photo_key'=k1 and r->'operation'->'result'=jsonb_build_object('gallery_asset_ids',array[f.p3,f.p1],'main_photo_key',k1),'explicit promotion changes only cover preserving exact selection slots');
update listings set gallery_asset_ids=array[f.p3],main_photo_key=k3 where id=f.listing;
r:=native_gallery_selection_change_v2(f.actor,f.org,f.org,f.listing,op,q);
perform pg_temp.ok(r->'replayed'='true'and r->'operation'=accepted and r->'gallery_asset_ids'=to_jsonb(array[f.p3])and r->>'main_photo_key'=k3,'cover replay cannot reapply over later gallery and cover choices');
q:=pg_temp.intent(array[f.p1],f.p1,repeat('1',64),100,array[f.p3],k3)||'{"promote_cover":true}';
perform pg_temp.denied(format('select native_gallery_selection_change_v2(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),q),'cover star cannot implicitly select missing target','RP409: Select this exact family version');
update listings set gallery_asset_ids=array[f.p1,f.p3,f.p2],main_photo_key=k3 where id=f.listing;
q:=pg_temp.intent(array[f.p1,f.p2],f.p1,repeat('1',64),100,array[f.p1,f.p3,f.p2],k3)||'{"promote_cover":true}';
perform pg_temp.denied(format('select native_gallery_selection_change_v2(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),q),'cover star cannot collapse two selected family members','RP409: Select this exact family version');
update listings set gallery_asset_ids=null,main_photo_key=k3 where id=f.listing;
q:=pg_temp.intent(array[f.p1],f.p1,repeat('1',64),100,null,k3)||'{"promote_cover":true}';
r:=native_gallery_selection_change_v2(f.actor,f.org,f.org,f.listing,gen_random_uuid(),q);
perform pg_temp.ok(r->'gallery_asset_ids'='null'and r->'operation'->'result'->'gallery_asset_ids'='null'and r->>'main_photo_key'=k1,'explicit promotion preserves raw NULL gallery');
update listings set gallery_asset_ids='{}',main_photo_key=null where id=f.listing;
q:=pg_temp.intent(array[f.p1],f.p1,repeat('1',64),100,'{}',null)||'{"promote_cover":true}';
perform pg_temp.denied(format('select native_gallery_selection_change_v2(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),q),'explicit empty selection never becomes implicit selected photo','RP409: Select this exact family version');
update listings set gallery_asset_ids=array[f.p3,f.p2],main_photo_key=k3 where id=f.listing;
q:=pg_temp.intent(array[f.p1,f.p2],f.p2,repeat('2',64),200,array[f.p3,f.p2],k3)||'{"promote_cover":true}';
perform pg_temp.denied(format('select native_gallery_selection_change_v2(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),q),'cover target still requires actual edit review','RP409: Compare the accepted edit');
q:=q||'{"reviewed":true}';r:=native_gallery_selection_change_v2(f.actor,f.org,f.org,f.listing,gen_random_uuid(),q);
perform pg_temp.ok(r->'gallery_asset_ids'=to_jsonb(array[f.p3,f.p2])and r->>'main_photo_key'=k2,'reviewed eligible edited target may explicitly become cover');
perform pg_temp.denied(format('select native_gallery_selection_change_v2(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),q),'promotion stale cover CAS refuses','RP409: The listing photo selection changed');
q:=q||jsonb_build_object('expected_selection',jsonb_build_object('gallery_asset_ids',array[f.p2,f.p3],'main_photo_key',k2));
perform pg_temp.denied(format('select native_gallery_selection_change_v2(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),q),'promotion stale ordered gallery CAS refuses','RP409: The listing photo selection changed');
q:=q||'{"follow_family_cover":true}';perform pg_temp.denied(format('select native_gallery_selection_change_v2(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),q),'promotion cannot combine follow-cover intent','RP400: Cover promotion');
q:=pg_temp.intent(array[f.p1],null,null,null,array[f.p3,f.p2],k2)||'{"promote_cover":true}';perform pg_temp.denied(format('select native_gallery_selection_abandon(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.org,f.listing,gen_random_uuid(),q),'abandon validates original promotion syntax','RP400: Cover promotion');
perform pg_temp.ok((select jsonb_agg(to_jsonb(a)order by id)from capture_assets a where listing_id=f.listing)=before_assets and(select jsonb_agg(to_jsonb(a)order by id)from media_provenance a where listing_id=f.listing)=before_provenance,'promotion and abandonment never alter photo history or provenance');
end$$;
reset role;
select jsonb_build_object('passed',true,'assertions',count(*))from checks;
rollback;
