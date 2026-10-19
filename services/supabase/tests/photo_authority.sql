begin;
create temporary table photo_checks(label text primary key,ok boolean not null);
create function pg_temp.photo_ok(label text,v boolean)returns void language plpgsql security definer as $$begin if v is distinct from true then raise exception 'PHOTO FAIL: %',label;end if;insert into pg_temp.photo_checks values(label,true);end$$;
create function pg_temp.photo_denied(label text,s text,fragment text)returns void language plpgsql as $$declare e text;begin begin execute s;exception when others then e:=sqlerrm;end;if e is null or position(fragment in e)=0 then raise exception 'PHOTO FAIL: % wrong denial: %',label,coalesce(e,'accepted');end if;perform pg_temp.photo_ok(label,true);end$$;
insert into auth.users(id,email,is_anonymous)values
 ('fa200505-0000-4000-8000-000000000001','photo-owner@fixture.invalid',false),
 ('fa200505-0000-4000-8000-000000000002','photo-agent@fixture.invalid',false),
 ('fa200505-0000-4000-8000-000000000003','photo-outsider@fixture.invalid',false),
 ('fa200505-0000-4000-8000-000000000004','photo-guest@fixture.invalid',true);
create temporary table photo_fixture as select org_id org,user_id actor from memberships where user_id::text like 'fa200505-%';
grant select on photo_fixture to service_role,authenticated,anon;
insert into memberships(org_id,user_id,role)select org,'fa200505-0000-4000-8000-000000000002','agent'from photo_fixture where actor='fa200505-0000-4000-8000-000000000001';
insert into listings(id,org_id,agent_id,address)select 'fa200505-0000-4000-8000-000000000011',org,actor,'Synthetic photo property'from photo_fixture where actor='fa200505-0000-4000-8000-000000000001';
insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded)
 select ('fa200505-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'fa200505-0000-4000-8000-000000000011','photo','renders','renders/'||org||'/fa200505-0000-4000-8000-000000000011/gallery-photo-'||n||'.jpg',n<>15
 from photo_fixture cross join generate_series(12,16)n where actor='fa200505-0000-4000-8000-000000000001';
insert into media_provenance(id,org_id,listing_id,kind,original_key,altered_key,disclosure,model_id)
 select 'fa200505-0000-4000-8000-000000000021',org,'fa200505-0000-4000-8000-000000000011','photo_edit','renders/'||org||'/fa200505-0000-4000-8000-000000000011/gallery-photo-12.jpg','renders/'||org||'/fa200505-0000-4000-8000-000000000011/gallery-photo-13.jpg','AI-altered photo','fixture-model'
 from photo_fixture where actor='fa200505-0000-4000-8000-000000000001';
select pg_temp.photo_ok('client photo mutations revoked',not has_table_privilege('authenticated','photos','INSERT,UPDATE,DELETE')and not has_column_privilege('authenticated','photos','caption','UPDATE')and not has_column_privilege('authenticated','photos','is_staged','UPDATE'));
select pg_temp.photo_ok('client photo reads retained',has_table_privilege('authenticated','photos','SELECT'));
select pg_temp.photo_ok('photo RPC service only',not has_function_privilege('authenticated','studio_attach_photo(uuid,uuid,uuid,uuid,text,uuid)','EXECUTE')and has_function_privilege('service_role','studio_attach_photo(uuid,uuid,uuid,uuid,text,uuid)','EXECUTE')and not has_function_privilege('anon','studio_photo_caption(uuid,uuid,uuid,uuid,text,text)','EXECUTE'));
select pg_temp.photo_ok('old gallery mutation denied',not has_function_privilege('authenticated','studio_gallery_update(uuid,uuid,text,uuid,jsonb,jsonb)','EXECUTE'));
select pg_temp.photo_ok('brokerage pricing private',not has_function_privilege('anon','brokerage_price_cents(integer)','EXECUTE')and not has_function_privilege('authenticated','brokerage_quote(integer,integer,integer,integer,integer)','EXECUTE'));
set local role service_role;
select pg_temp.photo_ok('brokerage fixed price unchanged',brokerage_price_cents(50)=11900 and brokerage_price_floor_cents()=5000 and exists(select 1 from brokerage_quote(50)));
select pg_temp.photo_ok('original attach created',(studio_attach_photo('fa200505-0000-4000-8000-000000000002',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','fa200505-0000-4000-8000-000000000012','Original')->>'created')='true');
select pg_temp.photo_ok('original replay no second insert',(studio_attach_photo('fa200505-0000-4000-8000-000000000002',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','fa200505-0000-4000-8000-000000000012','Ignored replay')->>'created')='false');
select studio_attach_photo('fa200505-0000-4000-8000-000000000002',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','fa200505-0000-4000-8000-000000000013','Living room');
select pg_temp.photo_ok('known altered photo disclosure derived',(select is_staged and enhanced_key like '%gallery-photo-13.jpg'and original_key like '%gallery-photo-12.jpg'and caption='Living room · AI-altered photo'from photos where id='fa200505-0000-4000-8000-000000000013'));
select studio_photo_caption('fa200505-0000-4000-8000-000000000002',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','fa200505-0000-4000-8000-000000000013','Living room · AI-altered photo','Sunny room');
select pg_temp.photo_ok('caption cannot strip required disclosure',(select caption='Sunny room · AI-altered photo'and is_staged and enhanced_key like '%gallery-photo-13.jpg'from photos where id='fa200505-0000-4000-8000-000000000013'));
select pg_temp.photo_denied('stale caption conflict',format('select studio_photo_caption(%L,%L,%L,%L,%L,%L)','fa200505-0000-4000-8000-000000000002',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','fa200505-0000-4000-8000-000000000013','Living room · AI-altered photo','Wrong'),'RP409');
select studio_photo_caption('fa200505-0000-4000-8000-000000000002',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','fa200505-0000-4000-8000-000000000013','Living room · AI-altered photo','Sunny room');
select pg_temp.photo_ok('same desired caption replay retains flag',(select caption='Sunny room · AI-altered photo'and is_staged from photos where id='fa200505-0000-4000-8000-000000000013'));
select pg_temp.photo_denied('unuploaded photo denied',format('select studio_attach_photo(%L,%L,%L,%L,%L)','fa200505-0000-4000-8000-000000000002',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','fa200505-0000-4000-8000-000000000015','No'),'RP400');
select pg_temp.photo_denied('outsider actor denied',format('select studio_attach_photo(%L,%L,%L,%L,%L)','fa200505-0000-4000-8000-000000000003',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','fa200505-0000-4000-8000-000000000014','No'),'RP403');
select pg_temp.photo_denied('anonymous actor denied',format('select studio_attach_photo(%L,%L,%L,%L,%L)','fa200505-0000-4000-8000-000000000004',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','fa200505-0000-4000-8000-000000000014','No'),'RP403');
select pg_temp.photo_denied('foreign org denied',format('select studio_attach_photo(%L,%L,%L,%L,%L)','fa200505-0000-4000-8000-000000000003',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000003'),'fa200505-0000-4000-8000-000000000011','fa200505-0000-4000-8000-000000000014','No'),'RP404');
select pg_temp.photo_denied('foreign proof denied',format('select studio_attach_photo(%L,%L,%L,%L,%L,%L)','fa200505-0000-4000-8000-000000000002',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','fa200505-0000-4000-8000-000000000014','No','fa200505-0000-4000-8000-000000000099'),'RP400');
select studio_gallery_update_v2('fa200505-0000-4000-8000-000000000002',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','cover','fa200505-0000-4000-8000-000000000013','null',null);
select pg_temp.photo_ok('cover resolves disclosed canonical key',(select main_photo_key like '%gallery-photo-13.jpg'from listings where id='fa200505-0000-4000-8000-000000000011')and(select is_main from photos where id='fa200505-0000-4000-8000-000000000013'));
select pg_temp.photo_denied('stale cover denied',format('select studio_gallery_update_v2(%L,%L,%L,%L,%L,%L,null)','fa200505-0000-4000-8000-000000000002',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','cover','fa200505-0000-4000-8000-000000000012','null'),'RP409');
select studio_gallery_update_v2('fa200505-0000-4000-8000-000000000002',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','reorder',null,'["fa200505-0000-4000-8000-000000000012","fa200505-0000-4000-8000-000000000013"]','["fa200505-0000-4000-8000-000000000013","fa200505-0000-4000-8000-000000000012"]');
select pg_temp.photo_ok('reorder preserves disclosure',(select sort=0 and is_staged from photos where id='fa200505-0000-4000-8000-000000000013'));
reset role;
select set_config('request.jwt.claim.sub','fa200505-0000-4000-8000-000000000002',true);set local role authenticated;
select pg_temp.photo_ok('agent reads gallery',(select count(*)=2 from photos where listing_id='fa200505-0000-4000-8000-000000000011'));
select pg_temp.photo_denied('actual direct flag strip denied','update photos set is_staged=false,caption=null,enhanced_key=null where id=''fa200505-0000-4000-8000-000000000013''','permission denied');
select pg_temp.photo_denied('actual direct insert denied','insert into photos(listing_id,original_key)values(''fa200505-0000-4000-8000-000000000011'',''fake'')','permission denied');
select pg_temp.photo_denied('actual direct delete denied','delete from photos where id=''fa200505-0000-4000-8000-000000000013''','permission denied');
select pg_temp.photo_denied('actual service RPC denial','select studio_attach_photo(null,null,null,null,'''')','permission denied');
select pg_temp.photo_denied('actual authenticated price denial','select brokerage_quote(50)','permission denied');
reset role;set local role anon;
select pg_temp.photo_denied('actual anon price denial','select brokerage_price_cents(50)','permission denied');
reset role;
update memberships set role='marketing'where user_id='fa200505-0000-4000-8000-000000000002'and org_id=(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001');
set local role service_role;
select pg_temp.photo_denied('revoked edit role denied at write',format('select studio_attach_photo(%L,%L,%L,%L,%L)','fa200505-0000-4000-8000-000000000002',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','fa200505-0000-4000-8000-000000000014','No'),'RP403');
reset role;update memberships set role='agent'where user_id='fa200505-0000-4000-8000-000000000002';
set local role service_role;
select prepare_account_deletion('fa200505-0000-4000-8000-000000000002','fixture-uploads','fixture-renders');
select pg_temp.photo_denied('deleting actor denied at write',format('select studio_attach_photo(%L,%L,%L,%L,%L)','fa200505-0000-4000-8000-000000000002',(select org from photo_fixture where actor='fa200505-0000-4000-8000-000000000001'),'fa200505-0000-4000-8000-000000000011','fa200505-0000-4000-8000-000000000014','No'),'RP409');
reset role;
select count(*)as photo_assertions from photo_checks;
select 'PASS: photo authority SQL assertions; all fixtures rolled back.';
rollback;
