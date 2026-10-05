\set ON_ERROR_STOP on
begin;
do $$begin if current_database()<>'rendprop_audit' or inet_server_addr() is not null then
 raise exception 'Run only in the owned socket-only rendprop_audit fixture';end if;end$$;
create temp table gallery_checks(name text primary key,passed boolean not null);
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin
 if v is distinct from true then raise exception 'GALLERY FAIL: %',label;end if;
 insert into gallery_checks values(label,true);end$$;
create function pg_temp.denied(command text,label text,prefix text default 'RP400:')returns void language plpgsql as $$declare message text;begin
 begin execute command;exception when others then message:=sqlerrm;end;
 perform pg_temp.ok(message like prefix||'%',label);end$$;
create temp table gallery_fixture(actor uuid,other_actor uuid,marketing uuid,org uuid,other_org uuid,listing uuid,other_listing uuid,p1 uuid,p2 uuid,unready uuid,video uuid,headshot uuid,foreign_photo uuid,forged_org uuid,forged_listing uuid);
do $$declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();m uuid:=gen_random_uuid();o uuid;oo uuid;l uuid:=gen_random_uuid();ol uuid:=gen_random_uuid();p1 uuid:=gen_random_uuid();p2 uuid:=gen_random_uuid();u uuid:=gen_random_uuid();v uuid:=gen_random_uuid();h uuid:=gen_random_uuid();f uuid:=gen_random_uuid();fo uuid:=gen_random_uuid();fl uuid:=gen_random_uuid();begin
 insert into auth.users(id,email,is_anonymous)values(a,'gallery-owner@fixture.invalid',false),(b,'gallery-other@fixture.invalid',false),(m,'gallery-marketing@fixture.invalid',false);
 select org_id into o from memberships where user_id=a;select org_id into oo from memberships where user_id=b;
 insert into memberships(user_id,org_id,role)values(m,o,'marketing');
 insert into listings(id,org_id,agent_id,address)values(l,o,a,'Synthetic gallery property'),(ol,oo,b,'Other synthetic gallery property');
 insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded)values
  (p1,l,'photo','renders','renders/'||o||'/'||l||'/gallery-'||p1||'.jpg',true),
  (p2,l,'photo','renders','renders/'||o||'/'||l||'/gallery-'||p2||'.jpg',true),
  (u,l,'photo','renders','renders/'||o||'/'||l||'/gallery-'||u||'.jpg',false),
  (v,l,'video','renders','renders/'||o||'/'||l||'/gallery-'||v||'.mp4',true),
  (h,l,'photo','renders','renders/'||o||'/'||l||'/contact-'||h||'.jpg',true),
  (f,ol,'photo','renders','renders/'||oo||'/'||ol||'/gallery-'||f||'.jpg',true),
  (fo,l,'photo','renders','renders/'||oo||'/'||l||'/gallery-'||fo||'.jpg',true),
  (fl,l,'photo','renders','renders/'||o||'/'||ol||'/gallery-'||fl||'.jpg',true);
 insert into gallery_fixture values(a,b,m,o,oo,l,ol,p1,p2,u,v,h,f,fo,fl);
end$$;
grant all on gallery_checks to authenticated,service_role;
grant select on gallery_fixture to authenticated,service_role;
select pg_temp.ok((select gallery_asset_ids is null from listings where id=(select listing from gallery_fixture)),'legacy and new default remains NULL');
select pg_temp.ok(has_column_privilege('authenticated','public.listings','gallery_asset_ids','UPDATE')and not has_column_privilege('anon','public.listings','gallery_asset_ids','UPDATE'),'selection grant preserves signed-in membership authority');
select pg_temp.ok(not has_function_privilege('authenticated','public.validate_listing_gallery_selection()','EXECUTE')and not has_function_privilege('anon','public.validate_listing_gallery_selection()','EXECUTE'),'trigger helper is not a client callable API');
select pg_temp.ok(provenance_disclosure('virtual_stage')='This photo was virtually staged with AI: furniture and decor were digitally added or restyled. Compare with the original to check fixed features, layout and access before publication.'and position('unchanged'in provenance_disclosure('declutter'))=0 and position('Compare with the original'in provenance_disclosure('declutter'))>0,'new photo audit disclosures require review rather than certify geometry');
select pg_temp.ok(has_function_privilege('authenticated','public.provenance_disclosure(text,text)','EXECUTE')and has_function_privilege('service_role','public.provenance_disclosure(text,text)','EXECUTE')and not has_function_privilege('anon','public.provenance_disclosure(text,text)','EXECUTE'),'pure disclosure helper retains its existing non-anonymous grants');
set local role authenticated;
select set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true)from gallery_fixture;
do $$declare f record;k1 text;k2 text;bad uuid;begin select * into f from gallery_fixture;
 k1:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p1||'.jpg';
 k2:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p2||'.jpg';
 update listings set gallery_asset_ids=array[f.p2,f.p1],main_photo_key=k1 where id=f.listing;
 perform pg_temp.ok((select gallery_asset_ids=array[f.p2,f.p1]and main_photo_key=k1 from listings where id=f.listing),'owner direct REST selection retains order and canonical cover');
end$$;
reset role;
set local role service_role;
do $$declare f record;k1 text;begin select * into f from gallery_fixture;
 k1:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p1||'.jpg';
 perform save_listing_facts(f.actor,f.org,f.listing,
  jsonb_build_object('address',(select address from listings where id=f.listing)),
  '{"address":"Changed without touching publication"}','{}','{}');
 perform pg_temp.ok((select gallery_asset_ids=array[f.p2,f.p1]and main_photo_key=k1 from listings where id=f.listing),'omitted photo columns preserve current publication');
end$$;
reset role;
set local role authenticated;
do $$declare f record;k1 text;k2 text;bad uuid;begin select * into f from gallery_fixture;
 k1:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p1||'.jpg';
 k2:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p2||'.jpg';
 update listings set gallery_asset_ids=array[f.p2]where id=f.listing;
 perform pg_temp.ok((select gallery_asset_ids=array[f.p2]and main_photo_key is null from listings where id=f.listing),'retiring a cover clears it without deleting media');
 perform pg_temp.denied(format('update listings set main_photo_key=%L where id=%L',k1,f.listing),'cover must belong to explicit gallery');
 update listings set main_photo_key=k2 where id=f.listing;
 update listings set gallery_asset_ids='{}'::uuid[]where id=f.listing;
 perform pg_temp.ok((select cardinality(gallery_asset_ids)=0 and main_photo_key is null from listings where id=f.listing),'empty selection intentionally hides photos and clears cover');
 update listings set gallery_asset_ids=null,main_photo_key=k1 where id=f.listing;
 perform pg_temp.ok((select gallery_asset_ids is null and main_photo_key=k1 from listings where id=f.listing),'NULL restores legacy auto gallery with valid cover');
 perform pg_temp.denied(format('update listings set gallery_asset_ids=array[%L,%L]::uuid[]where id=%L',f.p1,f.p1,f.listing),'duplicate selection is rejected');
 perform pg_temp.denied(format('update listings set gallery_asset_ids=array[%L,null]::uuid[]where id=%L',f.p1,f.listing),'NULL IDs are rejected');
 perform pg_temp.denied(format('update listings set gallery_asset_ids=array_fill(%L::uuid,array[41])where id=%L',f.p1,f.listing),'selection is bounded to 40 photos');
 foreach bad in array array[f.unready,f.video,f.headshot,f.foreign_photo,f.forged_org,f.forged_listing,gen_random_uuid()]loop
  perform pg_temp.denied(format('update listings set gallery_asset_ids=array[%L]::uuid[]where id=%L',bad,f.listing),'ineligible asset '||bad);
 end loop;
 perform pg_temp.denied(format('update listings set main_photo_key=%L where id=%L','https://other.invalid/arbitrary.jpg',f.listing),'arbitrary cover URL is rejected by direct REST fence');
 perform pg_temp.denied(format('update listings set main_photo_key=%L where id=%L','renders/'||f.org||'/'||f.listing||'/contact-'||f.headshot||'.jpg',f.listing),'headshot cannot become property cover');
 perform pg_temp.ok((select count(*)=7 from capture_assets where listing_id=f.listing),'selection keeps all originals and edit history assets');
end$$;
select set_config('request.jwt.claims',jsonb_build_object('sub',marketing,'role','authenticated')::text,true)from gallery_fixture;
do $$declare f record;n integer;begin select * into f from gallery_fixture;
 update listings set gallery_asset_ids='{}'::uuid[]where id=f.listing;get diagnostics n=row_count;
 perform pg_temp.ok(n=0 and exists(select 1 from listings where id=f.listing and main_photo_key is not null),'marketing reads listing but cannot change publication selection');end$$;
select set_config('request.jwt.claims',jsonb_build_object('sub',other_actor,'role','authenticated')::text,true)from gallery_fixture;
do $$declare f record;n integer;begin select * into f from gallery_fixture;
 update listings set gallery_asset_ids='{}'::uuid[]where id=f.listing;get diagnostics n=row_count;
 perform pg_temp.ok(n=0 and not exists(select 1 from listings where id=f.listing),'another workspace cannot select or mutate property gallery');end$$;
reset role;
select pg_temp.ok(has_function_privilege('service_role','public.append_listing_gallery(uuid,uuid,uuid,uuid[],boolean,text)','EXECUTE')and
 not has_function_privilege('authenticated','public.append_listing_gallery(uuid,uuid,uuid,uuid[],boolean,text)','EXECUTE')and
 not has_function_privilege('anon','public.append_listing_gallery(uuid,uuid,uuid,uuid[],boolean,text)','EXECUTE'),'atomic gallery append is service-only');
set local role service_role;
do $$declare f record;r jsonb;k1 text;k2 text;bad uuid;before_row jsonb;ids uuid[];generated uuid;begin
 select * into f from gallery_fixture;
 k1:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p1||'.jpg';
 k2:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.p2||'.jpg';
 r:=append_listing_gallery(f.actor,f.org,f.listing,array[f.p2]);
 perform pg_temp.ok((select gallery_asset_ids=(select array_agg(id order by created_at,id)from capture_assets where id in(f.p1,f.p2))and main_photo_key=k1 from listings where id=f.listing),'cloud append initializes NULL from eligible legacy photos without losing existing cover');
 update listings set gallery_asset_ids=array[f.p1],main_photo_key=k1 where id=f.listing;
 r:=append_listing_gallery(f.actor,f.org,f.listing,array[f.p2],true,k2);
 perform pg_temp.ok((select gallery_asset_ids=array[f.p1,f.p2]and main_photo_key=k2 from listings where id=f.listing),'cloud append adds photo and chooses new cover in one transaction');
 r:=append_listing_gallery(f.actor,f.org,f.listing,array[f.p2]);
 perform pg_temp.ok((select gallery_asset_ids=array[f.p1,f.p2]and main_photo_key=k2 from listings where id=f.listing),'repeated additions preserve order and do not duplicate uploads');
 r:=append_listing_gallery(f.actor,f.org,f.listing,'{}'::uuid[],true,null);
 perform pg_temp.ok((select gallery_asset_ids=array[f.p1,f.p2]and main_photo_key is null from listings where id=f.listing),'explicit cover clear does not erase cloud gallery');
 select to_jsonb(l)into before_row from listings l where id=f.listing;
 foreach bad in array array[f.unready,f.video,f.headshot,f.foreign_photo,f.forged_org,f.forged_listing,gen_random_uuid()]loop
  perform pg_temp.denied(format('select append_listing_gallery(%L,%L,%L,array[%L]::uuid[],true,%L)',f.actor,f.org,f.listing,bad,k1),'cloud append rejects ineligible asset '||bad);
 end loop;
 perform pg_temp.ok((select to_jsonb(l)=before_row from listings l where id=f.listing),'failed additions cannot partially change gallery or cover');
 perform pg_temp.denied(format('select append_listing_gallery(%L,%L,%L,array[%L]::uuid[])',f.marketing,f.org,f.listing,f.p1),'marketing cannot use privileged append','RP403:');
 perform pg_temp.denied(format('select append_listing_gallery(%L,%L,%L,array[%L]::uuid[])',f.other_actor,f.org,f.listing,f.p1),'nonmember cannot use privileged append','RP404:');
 perform pg_temp.denied(format('select append_listing_gallery(%L,%L,%L,array[%L]::uuid[])',f.actor,f.other_org,f.listing,f.p1),'explicit wrong workspace cannot append','RP404:');
 perform pg_temp.denied(format('select append_listing_gallery(%L,%L,%L,array[%L,%L]::uuid[])',f.actor,f.org,f.listing,f.p1,f.p1),'cloud append rejects duplicate request IDs');
 perform pg_temp.denied(format('select append_listing_gallery(%L,%L,%L,null)',f.actor,f.org,f.listing),'cloud append rejects null request');
 update orgs set deleted_at=now()where id=f.org;
 perform pg_temp.denied(format('select append_listing_gallery(%L,%L,%L,array[%L]::uuid[])',f.actor,f.org,f.listing,f.p1),'deleted workspace cannot append','RP404:');
 update orgs set deleted_at=null where id=f.org;
 ids:='{}'::uuid[];
 for n in 1..40 loop
  generated:=gen_random_uuid();ids:=array_append(ids,generated);
  insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded)values(generated,f.listing,'photo','renders','renders/'||f.org||'/'||f.listing||'/gallery-'||generated||'.jpg',true);
 end loop;
 update listings set gallery_asset_ids=ids where id=f.listing;
 perform pg_temp.denied(format('select append_listing_gallery(%L,%L,%L,array[%L]::uuid[],true,%L)',f.actor,f.org,f.listing,f.p1,k1),'overflow never discards an old cloud photo to fit a new one');
 perform pg_temp.ok((select gallery_asset_ids=ids and main_photo_key is null from listings where id=f.listing),'overflow leaves both publication fields unchanged');
end$$;
reset role;
select name,passed from gallery_checks order by name;
rollback;
