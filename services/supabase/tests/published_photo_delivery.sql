\set ON_ERROR_STOP on
begin;
do $$begin if current_database()<>'photo_delivery' or inet_server_addr()is not null then raise exception 'Owned socket-only photo fixture required';end if;end$$;
create temporary table checks(n integer);insert into checks values(0);grant all on checks to service_role,authenticated,anon;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception 'PHOTO_DELIVERY FAIL: %',label;end if;update checks set n=n+1;end$$;
create function pg_temp.refuse(command text,needle text,label text)returns void language plpgsql as $$begin begin execute command;exception when others then if position(needle in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception 'PHOTO_DELIVERY FAIL: allowed %',label;end$$;
insert into auth.users(id,email,is_anonymous)values('d1800000-0000-4000-8000-000000000001','photo-authority@fixture.invalid',false);
create temporary table f as select 'd1800000-0000-4000-8000-000000000001'::uuid actor,
 (select org_id from memberships where user_id='d1800000-0000-4000-8000-000000000001'limit 1)org,
 'd1800000-0000-4000-8000-000000000002'::uuid listing;
alter table f add column prefix text;update f set prefix='renders/'||org||'/'||listing||'/';grant select on f to service_role,authenticated,anon;
insert into listings(id,org_id,agent_id,address)select listing,org,actor,'Synthetic photo authority'from f;
insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,bytes,sha256,content_type)
 select('d1800000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,listing,'photo',case when n=21 then'uploads'else'renders'end,
 case n when 10 then prefix||'gallery-original.jpg'when 11 then prefix||'gallery-stage-complete-v1.jpg'
 when 12 then prefix||'gallery-declutter-complete-v2.jpg'when 20 then prefix||'original-master.jpg'when 22 then prefix||'incomplete-original.jpg'
 else 'uploads/'||org||'/'||listing||'/retained-original.jpg'end,n<>22,1000,repeat('a',64),'image/jpeg'from f cross join unnest(array[10,11,12,20,21,22])n;
update listings set gallery_asset_ids=array['d1800000-0000-4000-8000-000000000010'::uuid,'d1800000-0000-4000-8000-000000000011'::uuid,'d1800000-0000-4000-8000-000000000012'::uuid]where id=(select listing from f);
insert into render_jobs(id,listing_id,source,status)select'd1800000-0000-4000-8000-000000000030',listing,'app','completed'from f;
insert into renders(id,job_id,listing_id,slug,duration_s,published_at)
 select'd1800000-0000-4000-8000-000000000031','d1800000-0000-4000-8000-000000000030',listing,'photo-authority',3,now()from f;
insert into media_provenance(id,org_id,listing_id,kind,edit,original_key,altered_key,disclosure,qc)
 select('d1800000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,org,listing,
 case n when 41 then'virtual_stage'else'declutter'end,case n when 41 then'stage'else'declutter'end,
 prefix||'original-master.jpg',prefix||case n when 41 then'gallery-stage-complete-v1.jpg'else'gallery-declutter-complete-v2.jpg'end,
 'Existing canonical public disclosure','{"publishable":false}'::jsonb from f cross join unnest(array[41,42])n;
create temporary table money_before as select (select count(*)from cost_ledger)ledger,(select count(*)from serving_cost_reservations)holds,
 (select count(*)from serving_funding)funding,(select coalesce(jsonb_agg(to_jsonb(b)order by id),'[]'::jsonb)from media_delivery_budgets b)budgets;
grant select on money_before to service_role;
select pg_temp.ok(not has_function_privilege(r,'public.published_photo_delivery(text,text,bigint)','execute'),'service-only RPC '||r)from unnest(array['anon','authenticated'])r;
select pg_temp.ok((select prosecdef and provolatile='v'and proconfig=array['search_path=""']::text[]from pg_proc where oid='public.published_photo_delivery(text,text,bigint)'::regprocedure),'pinned volatile definer');
set local role service_role;
select pg_temp.ok(public.published_photo_delivery('photo-authority',prefix||'gallery-original.jpg',0)=
 jsonb_build_object('schema',1,'slug','photo-authority','objects',jsonb_build_object(prefix||'gallery-original.jpg','renders'),'stream_uid',null),'Original exact one-object envelope')from f;
select pg_temp.ok((select count(*)from jsonb_object_keys(public.published_photo_delivery('photo-authority',prefix||'gallery-stage-complete-v1.jpg',100)->'objects'))=1,'Stage has exact named original and only requested result')from f;
select pg_temp.ok(public.published_photo_delivery('photo-authority',prefix||'gallery-declutter-complete-v2.jpg',2097152)#>>array['objects',prefix||'gallery-declutter-complete-v2.jpg']='renders','Declutter accepts exact 2MiB bound')from f;
select pg_temp.ok((select used_requests=3 and used_bytes=2097252 from media_serving_usage where org_id=f.org),'required exact request/byte meter')from f;
select pg_temp.ok((select count(*)from cost_ledger)=(select ledger from money_before)and(select count(*)from serving_cost_reservations)=(select holds from money_before)
 and(select count(*)from serving_funding)=(select funding from money_before)and(select coalesce(jsonb_agg(to_jsonb(b)order by id),'[]'::jsonb)from media_delivery_budgets b)=(select budgets from money_before),'no fabricated cash holds or budget reset');
select pg_temp.refuse(format('select published_photo_delivery(%L,%L,2097153)','photo-authority',prefix||'gallery-original.jpg'),'RP400:','preview upper bound')from f;
select pg_temp.refuse(format('select published_photo_delivery(%L,%L,-1)','photo-authority',prefix||'gallery-original.jpg'),'RP400:','negative bytes')from f;
select pg_temp.refuse(format('select published_photo_delivery(%L,%L,null)','photo-authority',prefix||'gallery-original.jpg'),'RP400:','null bytes')from f;
select pg_temp.refuse(format('select published_photo_delivery(%L,%L,0)','photo-authority',prefix||'gallery-missing.jpg'),'RP404:','missing photo refused')from f;
select pg_temp.refuse(format('select published_photo_delivery(%L,%L,0)','not-published',prefix||'gallery-original.jpg'),'RP404:','unpublished slug refused')from f;
select pg_temp.refuse('select published_photo_delivery(''photo-authority'',''renders/aaaaaaaa-0000-4000-8000-000000000000/bbbbbbbb-0000-4000-8000-000000000000/gallery-foreign.jpg'',0)','RP404:','foreign key refused');
reset role;
update media_provenance set original_key=(select 'uploads/'||org||'/'||listing||'/retained-original.jpg'from f),kind='other'where id='d1800000-0000-4000-8000-000000000041';
set local role service_role;
select pg_temp.ok(public.published_photo_delivery('photo-authority',prefix||'gallery-stage-complete-v1.jpg',0)is not null,'uploads original and existing non-whitelisted kind supported')from f;
reset role;
update media_provenance set original_key=null where id='d1800000-0000-4000-8000-000000000041';
set local role service_role;
select pg_temp.ok(public.published_photo_delivery('photo-authority',prefix||'gallery-stage-complete-v1.jpg',0)is null,'unknown legacy original delegates')from f;
reset role;
update media_provenance set original_key=(select prefix||'original-missing.jpg'from f)where id='d1800000-0000-4000-8000-000000000041';
set local role service_role;
select pg_temp.ok(public.published_photo_delivery('photo-authority',prefix||'gallery-stage-complete-v1.jpg',0)is null,'canonically visible legacy original without capture row delegates')from f;
reset role;
update media_provenance set original_key='renders/old-original.jpg'where id='d1800000-0000-4000-8000-000000000041';
set local role service_role;
select pg_temp.ok(public.published_photo_delivery('photo-authority',prefix||'gallery-stage-complete-v1.jpg',0)is null,'unsupported noncanonical legacy original delegates')from f;
reset role;
update media_provenance set original_key='renders/aaaaaaaa-0000-4000-8000-000000000000/bbbbbbbb-0000-4000-8000-000000000000/original.jpg'where id='d1800000-0000-4000-8000-000000000041';
set local role service_role;
select pg_temp.refuse(format('select published_photo_delivery(%L,%L,0)','photo-authority',prefix||'gallery-stage-complete-v1.jpg'),'RP404:','named foreign original refused instead of fallback')from f;
reset role;
update media_provenance set original_key=(select prefix||'original-master.jpg'from f)where id='d1800000-0000-4000-8000-000000000041';
update media_provenance set original_key=(select prefix||'incomplete-original.jpg'from f)where id='d1800000-0000-4000-8000-000000000041';
set local role service_role;
select pg_temp.refuse(format('select published_photo_delivery(%L,%L,0)','photo-authority',prefix||'gallery-stage-complete-v1.jpg'),'RP404:','incomplete original refused')from f;
reset role;
update media_provenance set original_key=(select prefix||'original-master.jpg'from f)where id='d1800000-0000-4000-8000-000000000041';
savepoint revoke;
insert into studio_presenter_jobs(id,org_id,listing_id,actor_id,subject_user_id,author_user_id,draft_id,profile_id,draft_revision,profile_revision,quote_id,idempotency_key,runtime_revision,price_version,quote_cents,hold_cents,held_cents,state,output_key,import_storage_key)
 select'd1800000-0000-4000-8000-000000000050',org,listing,actor,actor,actor,gen_random_uuid(),gen_random_uuid(),1,1,gen_random_uuid(),gen_random_uuid(),1,'synthetic',1,1,0,'invalidated',
 'presenter-private/'||org||'/d1800000-0000-4000-8000-000000000050/output.mp4',prefix||'original-master.jpg'from f;
set local role service_role;
select pg_temp.refuse(format('select published_photo_delivery(%L,%L,0)','photo-authority',prefix||'gallery-stage-complete-v1.jpg'),'RP404:','canonical revoked original refused')from f;
reset role;
update media_provenance set original_key=(select prefix||'original-missing.jpg'from f)where id='d1800000-0000-4000-8000-000000000041';
update studio_presenter_jobs set import_storage_key=(select prefix||'original-missing.jpg'from f)where id='d1800000-0000-4000-8000-000000000050';
set local role service_role;
select pg_temp.refuse(format('select published_photo_delivery(%L,%L,0)','photo-authority',prefix||'gallery-stage-complete-v1.jpg'),'RP404:','revoked legacy source without capture row is not fallback')from f;
reset role;
rollback to revoke;
select pg_temp.ok(true,'canonical revocation oracle completed before fixture rollback');
savepoint ambiguity;
insert into media_provenance(id,org_id,listing_id,kind,original_key,altered_key,disclosure)
 select'd1800000-0000-4000-8000-000000000043',org,listing,'other',prefix||'original-master.jpg',prefix||'gallery-stage-complete-v1.jpg','Existing canonical disclosure'from f;
set local role service_role;
select pg_temp.ok(public.published_photo_delivery('photo-authority',prefix||'gallery-stage-complete-v1.jpg',0)is null,'ambiguous lineage delegates')from f;
reset role;rollback to ambiguity;
select pg_temp.ok(true,'ambiguous lineage oracle completed');
savepoint descriptor;
insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,bytes,content_type)
 select'd1800000-0000-4000-8000-000000000023',listing,'photo','renders',prefix||'gallery-unsupported.jpg',true,1000,'application/octet-stream'from f;
update listings set gallery_asset_ids=gallery_asset_ids||'d1800000-0000-4000-8000-000000000023'::uuid where id=(select listing from f);
set local role service_role;
select pg_temp.ok(public.published_photo_delivery('photo-authority',prefix||'gallery-unsupported.jpg',0)is null,'unsupported owned descriptor delegates')from f;
reset role;
rollback to descriptor;
select pg_temp.ok(true,'unsupported descriptor oracle completed');
-- Local-only historical shape fixtures: the current write trigger rejects
-- these shapes, but historical reads must keep the old helper's NULL fallback.
alter table listings disable trigger trg_validate_listing_gallery_selection;
update listings set gallery_asset_ids=array_fill('d1800000-0000-4000-8000-000000000010'::uuid,array[101])where id=(select listing from f);
set local role service_role;
select pg_temp.ok(public.published_photo_delivery('photo-authority',prefix||'gallery-original.jpg',0)is null,'oversized explicit legacy gallery delegates')from f;
reset role;
update listings set gallery_asset_ids=array[null::uuid]where id=(select listing from f);
set local role service_role;
select pg_temp.ok(public.published_photo_delivery('photo-authority',prefix||'gallery-original.jpg',0)is null,'null-item explicit legacy gallery delegates')from f;
reset role;
update listings set gallery_asset_ids=array[['d1800000-0000-4000-8000-000000000010'::uuid]]where id=(select listing from f);
set local role service_role;
select pg_temp.ok(public.published_photo_delivery('photo-authority',prefix||'gallery-original.jpg',0)is null,'nested explicit legacy gallery delegates')from f;
reset role;
update listings set gallery_asset_ids=null where id=(select listing from f);
alter table listings enable trigger trg_validate_listing_gallery_selection;
update listings set gallery_asset_ids='{}'where id=(select listing from f);
set local role service_role;
select pg_temp.refuse(format('select published_photo_delivery(%L,%L,0)','photo-authority',prefix||'gallery-original.jpg'),'RP404:','explicit empty selection refuses')from f;
reset role;
update listings set gallery_asset_ids=null where id=(select listing from f);
insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,bytes,content_type,created_at)
 select('d1800000-0000-4000-8001-'||lpad(n::text,12,'0'))::uuid,listing,'photo','renders',prefix||'gallery-old-'||n||'.jpg',true,1000,'image/jpeg','2020-01-01'::timestamptz+n*interval'1 second'from f cross join generate_series(1,101)n;
set local role service_role;
select pg_temp.ok(public.published_photo_delivery('photo-authority',prefix||'gallery-old-100.jpg',0)is not null,'legacy first100 admitted')from f;
select pg_temp.refuse(format('select published_photo_delivery(%L,%L,0)','photo-authority',prefix||'gallery-old-101.jpg'),'RP404:','legacy101 excluded')from f;
reset role;
update listings set main_photo_key=(select prefix||'gallery-old-101.jpg'from f)where id=(select listing from f);
set local role service_role;
select pg_temp.ok(public.published_photo_delivery('photo-authority',prefix||'gallery-old-101.jpg',0)is not null,'legacy explicit cover beyond100 admitted')from f;
reset role;
update renders set published_at=null where slug='photo-authority';
set local role service_role;
select pg_temp.refuse(format('select published_photo_delivery(%L,%L,0)','photo-authority',prefix||'gallery-old-100.jpg'),'RP404:','withdrawn publication refused')from f;
reset role;
set local role authenticated;
select pg_temp.refuse(format('select published_photo_delivery(%L,%L,0)','photo-authority',prefix||'gallery-original.jpg'),'permission denied','authenticated cannot call point authority')from f;
reset role;
select jsonb_build_object('passed',true,'assertions',(select n from checks),'scope','Actual canonical visibility/hosting/metering, synthetic local property')::text;
rollback;
