\set ON_ERROR_STOP on
-- Studio gallery upload order: actual migrations/RPCs/roles; fixtures rolled back.
-- One transaction means every attach below has the SAME created_at (a clock
-- tie), and photo UUIDs sort in the reverse of upload order on purpose.
begin;
create temporary table checks(n integer);insert into checks values(0);grant all on checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'ORDER FAIL: %',label;end if;update checks set n=n+1;end$$;
create function pg_temp.refuse(command text,needle text,label text)returns void language plpgsql as $$begin begin execute command;exception when others then if position(needle in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception'ORDER FAIL: allowed %',label;end$$;

-- fixture:begin (the race runner commits this exact section in its own database)
insert into auth.users(id,email,is_anonymous)values('fc100000-0000-4000-8000-000000000001','order-owner@fixture.invalid',false),('fc100000-0000-4000-8000-000000000002','order-outsider@fixture.invalid',false),('fc100000-0000-4000-8000-000000000003','order-teammate@fixture.invalid',false);
create table order_bf as select'fc100000-0000-4000-8000-000000000001'::uuid actor,'fc100000-0000-4000-8000-000000000002'::uuid outsider,
 (select org_id from memberships where user_id='fc100000-0000-4000-8000-000000000001'and role='owner'limit 1)org,
 'fc200000-0000-4000-8000-000000000001'::uuid listing,'fc200000-0000-4000-8000-000000000002'::uuid legacy_listing,'fc200000-0000-4000-8000-000000000003'::uuid race_listing;
grant select on order_bf to service_role,authenticated;
-- Upload-order tests use an entitled synthetic workspace for three listings.
update orgs set plan='starter',plan_source='manual' where id=(select org from order_bf);
-- A teammate with write access: two people can upload to one property at once.
insert into memberships(org_id,user_id,role)select org,'fc100000-0000-4000-8000-000000000003','agent'from order_bf;
insert into listings(id,org_id,agent_id,address)select listing,org,actor,'Upload order property'from order_bf union all select legacy_listing,org,actor,'Legacy order property'from order_bf union all select race_listing,org,actor,'Race order property'from order_bf;
-- Batch A (IMG_0001..3), batch B restarting at IMG_0001, a later batch C, an edit E of A2,
-- legacy rows L1..L3 and race photos R1..R10. Lower UUID = LATER upload.
create table order_assets as select * from(values
 ('A1','fc300000-0000-4000-8000-000000000095'::uuid,'listing','IMG_0001'),('A2','fc300000-0000-4000-8000-000000000094','listing','IMG_0002'),('A3','fc300000-0000-4000-8000-000000000093','listing','IMG_0003'),
 ('B1','fc300000-0000-4000-8000-000000000092','listing','IMG_0001'),('B2','fc300000-0000-4000-8000-000000000091','listing','IMG_0002'),
 ('C1','fc300000-0000-4000-8000-000000000090','listing','IMG_0001'),('E1','fc300000-0000-4000-8000-000000000089','listing','IMG_0002 edit'),
 ('L1','fc300000-0000-4000-8000-000000000079','legacy_listing','IMG_0001'),('L2','fc300000-0000-4000-8000-000000000078','legacy_listing','IMG_0002'),('L3','fc300000-0000-4000-8000-000000000077','legacy_listing','IMG_0003'),
 ('N1','fc300000-0000-4000-8000-000000000076','legacy_listing','IMG_0001'))v(label,id,place,caption)
 union all select 'R'||i,('fc300000-0000-4000-8000-0000000001'||lpad((99-i)::text,2,'0'))::uuid,'race_listing','IMG_000'||i from generate_series(1,10)i;
grant select on order_assets to service_role,authenticated;
insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded)
 select a.id,case a.place when'listing'then b.listing when'legacy_listing'then b.legacy_listing else b.race_listing end,'photo','renders',
  'renders/'||b.org||'/'||case a.place when'listing'then b.listing when'legacy_listing'then b.legacy_listing else b.race_listing end||'/gallery-'||a.id||'.jpg',true
 from order_assets a cross join order_bf b;
insert into media_provenance(id,org_id,listing_id,kind,original_key,altered_key,disclosure,model_id)
 select'fc400000-0000-4000-8000-000000000001',org,listing,'photo_edit','renders/'||org||'/'||listing||'/gallery-fc300000-0000-4000-8000-000000000094.jpg','renders/'||org||'/'||listing||'/gallery-fc300000-0000-4000-8000-000000000089.jpg','Virtually staged','fixture-model'from order_bf;
-- Legacy rows written by the old attach: sort 0, distinct attach times, adversarial UUIDs.
insert into photos(id,listing_id,original_key,caption,sort,created_at)
 select a.id,b.legacy_listing,'renders/'||b.org||'/'||b.legacy_listing||'/gallery-'||a.id||'.jpg',a.caption,0,timestamptz'2026-10-01 12:00:00+00'+(right(a.label,1)::int*interval'1 second')
 from order_assets a cross join order_bf b where a.label in('L1','L2','L3');
-- fixture:end

create function pg_temp.asset(label text)returns uuid language sql as $$select id from order_assets where order_assets.label=$1$$;
create function pg_temp.attach(label text)returns jsonb language sql as $$select studio_attach_photo(b.actor,b.org,case a.place when'listing'then b.listing when'legacy_listing'then b.legacy_listing else b.race_listing end,a.id,a.caption,null)from order_assets a cross join order_bf b where a.label=$1$$;
create function pg_temp.labels(p_listing uuid)returns text[] language sql as $$select array_agg(a.label order by p.sort,p.created_at,p.id)from photos p join order_assets a on a.id=p.id where p.listing_id=p_listing$$;
create function pg_temp.legacy_labels(p_listing uuid)returns text[] language sql as $$select array_agg(a.label order by p.sort,p.id)from photos p join order_assets a on a.id=p.id where p.listing_id=p_listing$$;
create function pg_temp.ids(labels text[])returns jsonb language sql as $$select jsonb_agg(pg_temp.asset(l)order by n)from unnest(labels)with ordinality u(l,n)$$;
create function pg_temp.reorder(p_listing uuid,expected text[],next text[])returns jsonb language sql as $$select studio_gallery_update_v2(b.actor,b.org,p_listing,'reorder',null,pg_temp.ids(expected),pg_temp.ids(next))from order_bf b$$;
-- A refused reorder must name the guarantee it broke, not only the RPC error.
create function pg_temp.reorder_ok(p_listing uuid,expected text[],next text[],label text)returns void language plpgsql as $$begin
 begin perform pg_temp.reorder(p_listing,expected,next);exception when others then raise exception'ORDER FAIL: % (%)',label,sqlerrm;end;
 perform pg_temp.ok(pg_temp.labels(p_listing)=next,label);end$$;

set local role service_role;
-- 1. Two uploads, repeated file names, tied attach times.
select pg_temp.attach(l)from unnest(array['A1','A2','A3','B1','B2'])l;
select pg_temp.ok(pg_temp.labels((select listing from order_bf))=array['A1','A2','A3','B1','B2'],'two uploads with repeated filenames and tied attach times keep upload order');
select pg_temp.ok(pg_temp.legacy_labels((select listing from order_bf))=array['A1','A2','A3','B1','B2'],'a reader still ordering by (sort,id) also sees upload order');
select pg_temp.ok((select array_agg(caption order by sort)=array['IMG_0001','IMG_0002','IMG_0003','IMG_0001','IMG_0002']and count(distinct sort)=5 from photos where listing_id=(select listing from order_bf)),'file names restart without colliding; each upload has its own position');
select pg_temp.ok(pg_temp.attach('A2')->>'created'='false'and pg_temp.labels((select listing from order_bf))=array['A1','A2','A3','B1','B2'],'attach replay keeps the original position');

-- 2. An explicit reorder survives, a later batch and a saved edit land underneath.
select pg_temp.ok(pg_temp.reorder((select listing from order_bf),array['A1','A2','A3','B1','B2'],array['B1','A1','A2','A3','B2'])->>'ok'='true','reorder accepted for the displayed order');
select pg_temp.ok(pg_temp.labels((select listing from order_bf))=array['B1','A1','A2','A3','B2'],'explicit reorder is saved');
select pg_temp.ok(pg_temp.reorder((select listing from order_bf),array['A1','A2','A3','B1','B2'],array['B1','A1','A2','A3','B2'])->>'ok'='true','lost reorder reply replays');
select pg_temp.refuse($q$select pg_temp.reorder((select listing from order_bf),array['A1','A2','A3','B1','B2'],array['A2','A1','A3','B1','B2'])$q$,'RP409: The gallery changed on another device','stale reorder is refused');
select pg_temp.attach('C1');
select pg_temp.ok(pg_temp.labels((select listing from order_bf))=array['B1','A1','A2','A3','B2','C1'],'a later batch lands underneath after an explicit reorder');
create temporary table e1 as select studio_attach_photo((select actor from order_bf),(select org from order_bf),(select listing from order_bf),pg_temp.asset('E1'),'IMG_0002',null)r;
select pg_temp.ok((select r->>'created'='true'from e1)and(select is_staged and caption='IMG_0002 · Virtually staged'from photos where id=pg_temp.asset('E1')),'saved edit keeps its disclosure');
select pg_temp.ok(pg_temp.labels((select listing from order_bf))=array['B1','A1','A2','A3','B2','C1','E1'],'saving an edited version never moves existing photos');

-- 3. Legacy rows (sort 0 from the old attach) keep attach-time order; both client generations can reorder.
select pg_temp.ok(pg_temp.labels((select legacy_listing from order_bf))=array['L1','L2','L3'],'legacy ties follow attach time, not UUID');
select pg_temp.ok(pg_temp.legacy_labels((select legacy_listing from order_bf))=array['L3','L2','L1'],'fixture UUIDs really are adversarial');
select pg_temp.attach('N1');
select pg_temp.ok(pg_temp.labels((select legacy_listing from order_bf))=array['L1','L2','L3','N1'],'a new upload appends after legacy photos');
select pg_temp.reorder_ok((select legacy_listing from order_bf),array['L1','L2','L3','N1'],array['L2','L1','L3','N1'],'the current client reorders a tied legacy gallery by its displayed order');
reset role;update photos set sort=0 where listing_id=(select legacy_listing from order_bf)and id<>pg_temp.asset('N1');set local role service_role;
select pg_temp.reorder_ok((select legacy_listing from order_bf),array['L3','L2','L1','N1'],array['L2','L3','L1','N1'],'a pre-fix client naming (sort,id) still reorders the same tied snapshot');

-- 4. Authority is unchanged.
select pg_temp.refuse($q$select studio_attach_photo(outsider,org,listing,pg_temp.asset('C1'),'x',null)from order_bf$q$,'RP403','outsider cannot attach');
select pg_temp.refuse($q$select pg_temp.reorder((select listing from order_bf),array['B1','A1'],array['A1','B1'])$q$,'RP409','partial gallery cannot reorder');
reset role;
select pg_temp.ok(not has_function_privilege('authenticated','public.studio_attach_photo(uuid,uuid,uuid,uuid,text,uuid)','execute')and not has_function_privilege('authenticated','public.studio_gallery_update_v2(uuid,uuid,uuid,text,uuid,jsonb,jsonb)','execute')
 and has_function_privilege('service_role','public.studio_attach_photo(uuid,uuid,uuid,uuid,text,uuid)','execute'),'gallery RPCs stay service-only');
select jsonb_build_object('passed',true,'assertions',n)from checks;
rollback;
