\set ON_ERROR_STOP on
begin;
create temp table checks(n integer);insert into checks values(0);grant all on checks to service_role,authenticated,anon;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin
 if v is distinct from true then raise exception'DIRECT PROVENANCE FAIL: %',label;end if;update checks set n=n+1;end$$;
create function pg_temp.provenance_count()returns integer language sql security definer set search_path=public as $$select count(*)::integer from media_provenance$$;
create function pg_temp.denied(command text,label text,needle text default'RP409:')returns void language plpgsql as $$declare msg text;before_count integer;begin
 before_count:=pg_temp.provenance_count();
 begin execute command;exception when others then msg:=sqlerrm;end;
 perform pg_temp.ok(position(needle in coalesce(msg,''))>0,label||': '||coalesce(msg,'NO REFUSAL'));
 perform pg_temp.ok(pg_temp.provenance_count()=before_count,'no orphan on refusal: '||label);end$$;
-- Synthetic accepted/held facts only, actual production settlement builds ledgers.
-- Real immutable priced/allowance/serving/ledger rows.
-- no provider accepts or customer media. Prices are existing held facts only.
insert into auth.users(id,email,is_anonymous,email_confirmed_at)values
 ('f8510000-0000-4000-8000-000000000001','direct-owner@fixture.invalid',false,now()),
 ('f8510000-0000-4000-8000-000000000002','direct-other@fixture.invalid',false,now());
create temp table vf as select 'f8510000-0000-4000-8000-000000000001'::uuid actor,
 'f8510000-0000-4000-8000-000000000002'::uuid other,
 (select org_id from memberships where user_id='f8510000-0000-4000-8000-000000000001'and role='owner')org,
 (select org_id from memberships where user_id='f8510000-0000-4000-8000-000000000002'and role='owner')other_org,
 'f8530000-0000-4000-8000-000000000001'::uuid listing,
 'f8530000-0000-4000-8000-000000000002'::uuid other_listing;
insert into listings(id,org_id,agent_id,address)select listing,org,actor,'Synthetic held video home'from vf
 union all select other_listing,other_org,other,'Synthetic foreign video home'from vf;
grant select on vf to service_role,authenticated,anon;
create function pg_temp.ref(i integer)returns jsonb language sql as $$select jsonb_build_object(
 'provider','fal','model','fal-ai/kling-video/v3/4k/image-to-video','id','accepted-'||i,
 'poll_url','https://queue.fal.run/fal-ai/kling-video/requests/accepted-'||i||'/status',
 'submitted_at',to_char(now()at time zone'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))$$;
create function pg_temp.acceptance(i integer,paid boolean default false,hold_state text default'succeeded',wrong_input boolean default false,hold_amount numeric default 210,task text default'video.reel_clip',listing_override uuid default null,omit_allowance boolean default false)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$declare f record;r uuid:=gen_random_uuid();begin
 select*into f from vf;
 insert into app_video_cost_reservations(id,org_id,actor_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents,meta)
 values(r,f.org,f.actor,'direct-fixture:'||i,'reel','fal','fal-ai/kling-video/v3/4k/image-to-video',repeat('a',64),5,42,210,210,jsonb_build_object('task',task));
 if not omit_allowance then
  insert into app_video_allowance_receipts(reservation_id,listing_id,monthly_key,monthly_window_start,burst_key,burst_window_start)
  values(r,coalesce(listing_override,f.listing),'reelmo:'||f.org,now(),'aivideo:'||f.org,now());end if;
 insert into serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,budget_source,state)
 values(f.org,f.actor,'direct-fixture:'||i,'reel','fal','fal-ai/kling-video/v3/4k/image-to-video',repeat(case when wrong_input then'b'else'a'end,64),'synthetic-existing-price',hold_amount,'ceiling',hold_state);
 if paid then perform app_video_cost_settle(f.actor,f.org,'direct-fixture:'||i,'accepted-'||i);end if;
 return r;end$$;
set local role service_role;
select pg_temp.acceptance(1);select pg_temp.acceptance(i,true)from generate_series(2,12)i;
reset role;
-- Retained transport metadata only. No object/provider/QC service is called.
set local session_replication_role=replica;
insert into capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type)
 select ('f8540000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,listing,'photo',case when i=1 then'uploads'else'renders'end,
 case when i=1 then'uploads/'else'renders/'end||org||'/'||listing||'/input-'||i||'.jpg',100,repeat(chr(96+i),64),true,2,'image/jpeg'from vf cross join generate_series(1,3)i;
insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,spent_bytes,state,settled_at)
 select id,(select org from vf),listing_id,(select actor from vf),current_date,'{"key_role":"original"}',0,bytes,'completed',now()from capture_assets where id::text like'f8540000-%';
insert into upload_operations(asset_id,kind,bucket,object_key,bytes,expected_bytes,content_type,content_type_declared,asset_kind,state,etag)
 select id,'copy',bucket,storage_key,bytes,bytes,content_type,true,kind,'retained','"fixture-etag"'from capture_assets where id::text like'f8540000-%';
insert into media_provenance(id,org_id,listing_id,kind,edit,model_id,original_key,altered_key,disclosure,qc)
 select 'f8580000-0000-4000-8000-000000000002',org,listing,'photo_edit','sky','photo-model',
 (select storage_key from capture_assets where id='f8540000-0000-4000-8000-000000000003'),
 (select storage_key from capture_assets where id='f8540000-0000-4000-8000-000000000002'),'Retained saved edit','{"publishable":true,"action":"accept"}'from vf;
set local session_replication_role=origin;
create function pg_temp.direct(i integer,asset uuid default'f8540000-0000-4000-8000-000000000001',prov uuid default null,sha text default repeat('a',64),qc text default repeat('a',32))returns jsonb language sql as $$
 select public.record_direct_property_video_source(actor,org,'direct-fixture:'||i,listing,asset,prov,'accepted-'||i,sha,qc,'Kitchen','side_glide','Bounded requested movement')from vf$$;
create function pg_temp.fault(change text,i integer default 5)returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$begin
 perform set_config('session_replication_role','replica',true);execute change;perform set_config('session_replication_role','origin',true);return pg_temp.direct(i);end$$;
create function pg_temp.photo_fault()returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$begin
 update media_provenance set qc='{"publishable":false}'where id='f8580000-0000-4000-8000-000000000002';
 return pg_temp.direct(5,'f8540000-0000-4000-8000-000000000002','f8580000-0000-4000-8000-000000000002',repeat('b',64));end$$;
set local role service_role;
select pg_temp.acceptance(13);
select app_video_cost_release_rejected(actor,org,'direct-fixture:13',403,'upstream')from vf;
reset role;
-- END SYNTHETIC FIXTURE
create temp table before_money as select
 (select jsonb_object_agg(id,md5(to_jsonb(x)::text))from cost_ledger x)ledger,
 (select jsonb_object_agg(id,md5(to_jsonb(x)::text))from app_video_cost_reservations x)app,
 (select jsonb_object_agg(id,md5(to_jsonb(x)::text))from serving_cost_reservations x)serving,
 (select jsonb_object_agg(reservation_id,md5(to_jsonb(x)::text))from app_video_allowance_receipts x)allowances;
grant select on before_money to service_role;
select pg_temp.ok(not has_function_privilege(r,'record_direct_property_video_source(uuid,uuid,text,uuid,uuid,uuid,text,text,text,text,text,text)','execute'),'service-only RPC ACL '||r)from unnest(array['anon','authenticated'])r;
select pg_temp.ok(has_function_privilege('service_role','record_direct_property_video_source(uuid,uuid,text,uuid,uuid,uuid,text,text,text,text,text,text)','execute'),'service RPC ACL');
select pg_temp.ok((select prosecdef and proconfig=array['search_path=""']from pg_proc where oid='record_direct_property_video_source(uuid,uuid,text,uuid,uuid,uuid,text,text,text,text,text,text)'::regprocedure),'definer empty search path');
set local role service_role;
create temp table first_results as select pg_temp.direct(2)a,pg_temp.direct(3,'f8540000-0000-4000-8000-000000000002','f8580000-0000-4000-8000-000000000002',repeat('b',64))b,pg_temp.direct(4)c;
select pg_temp.ok((select a->>'bound'='true'and b->>'bound'='true'and c->>'bound'='true'from first_results),'Original and saved edited source bind');
select pg_temp.ok((select a->>'provenance_id'<>b->>'provenance_id'and a->>'provenance_id'<>c->>'provenance_id'and b->>'provenance_id'<>c->>'provenance_id'from first_results),'different paid requests within60s get distinct provenance');
select pg_temp.ok(pg_temp.direct(2)=(select a from first_results),'same request replays exact provenance');
select pg_temp.ok((select count(*)=3 from property_video_sources),'one binding per paid request');
select pg_temp.ok((select bool_and(m.model_id=r.model and m.kind='reel'and m.edit='reel'and m.original_key is null and m.altered_key is null and m.disclosure=provenance_disclosure('reel','reel'))from property_video_sources s join media_provenance m on m.id=s.generation_provenance_id join app_video_cost_reservations r on r.provider_request_id=s.request_id),'model/disclosure SQL derived without Original inference');
-- Synthetic QC metadata executes the existing DB stamp, never an AI judge.
select record_media_qc((select(a->>'provenance_id')::uuid from first_results),(select org from vf),'{"fixture":"clip2","publishable":true}');
select record_media_qc((select(b->>'provenance_id')::uuid from first_results),(select org from vf),'{"fixture":"clip3","publishable":false}');
select pg_temp.ok((select m.qc->>'fixture'='clip2'from media_provenance m,first_results r where m.id=(r.a->>'provenance_id')::uuid),'distinct request QC cannot overwrite sibling');
select pg_temp.denied('select pg_temp.direct(1)','unsettled hold cannot create provenance');
select pg_temp.denied('select pg_temp.direct(13)','released request cannot create provenance');
select pg_temp.denied('select pg_temp.photo_fault()','withdrawn photo provenance');
select pg_temp.denied($q$select pg_temp.direct(2,'f8540000-0000-4000-8000-000000000002',null,repeat('b',64))$q$,'same request source immutable');
select pg_temp.denied($q$select pg_temp.direct(5,'f8540000-0000-4000-8000-000000000001',null,repeat('b',64))$q$,'exact source hash');
select pg_temp.denied($q$select pg_temp.direct(5,'f8540000-0000-4000-8000-000000000001','f8580000-0000-4000-8000-000000000099')$q$,'wrong photo provenance','RP404:');
select pg_temp.denied($q$select pg_temp.direct(5,'f8540000-0000-4000-8000-000000000001',null,repeat('a',64),'bad')$q$,'QC hash format','RP400:');
select pg_temp.denied($q$select record_direct_property_video_source(other,org,'direct-fixture:5',listing,'f8540000-0000-4000-8000-000000000001',null,'accepted-5',repeat('a',64),repeat('a',32),null,null,null)from vf$q$,'foreign actor','RP404:');
select pg_temp.denied($q$select record_direct_property_video_source(actor,other_org,'direct-fixture:5',listing,'f8540000-0000-4000-8000-000000000001',null,'accepted-5',repeat('a',64),repeat('a',32),null,null,null)from vf$q$,'foreign org','RP404:');
select pg_temp.denied($q$select record_direct_property_video_source(actor,org,'missing-key',listing,'f8540000-0000-4000-8000-000000000001',null,'accepted-5',repeat('a',64),repeat('a',32),null,null,null)from vf$q$,'missing exact operation');
select pg_temp.denied($q$select record_direct_property_video_source(actor,org,'direct-fixture:5',listing,'f8540000-0000-4000-8000-000000000001',null,'wrong-request',repeat('a',64),repeat('a',32),null,null,null)from vf$q$,'wrong provider request');
select pg_temp.denied($q$select pg_temp.fault('update app_video_cost_reservations set settled_at=null,provider_request_id=null,cost_ledger_id=null where idempotency_key=''direct-fixture:5''')$q$,'unsettled authority');
select pg_temp.denied($q$select pg_temp.fault('update cost_ledger set model=''wrong-paid-model''where meta->>''request_key''=''direct-fixture:5''')$q$,'exact paid model');
select pg_temp.denied($q$select pg_temp.fault('update cost_ledger set total_cents=0 where meta->>''request_key''=''direct-fixture:5''')$q$,'positive exact ledger');
select pg_temp.denied($q$select pg_temp.fault('update cost_ledger set meta=meta||''{"request_id":"forged"}''where meta->>''request_key''=''direct-fixture:5''')$q$,'exact ledger request');
select pg_temp.denied($q$select pg_temp.fault('delete from app_video_allowance_receipts where reservation_id=(select id from app_video_cost_reservations where idempotency_key=''direct-fixture:5'')')$q$,'listing allowance required');
select pg_temp.denied($q$select pg_temp.fault('update capture_assets set uploaded=false where id=''f8540000-0000-4000-8000-000000000001''')$q$,'withdrawn upload');
select pg_temp.denied($q$select pg_temp.fault('update upload_operations set state=''rejected''where asset_id=''f8540000-0000-4000-8000-000000000001''')$q$,'retained receipt required');
select pg_temp.denied($q$select pg_temp.fault('update listings set deleted_at=now()where id=(select listing from vf)')$q$,'deleted listing','RP404:');
select pg_temp.denied($q$select pg_temp.fault('update orgs set deleted_at=now()where id=(select org from vf)')$q$,'deleted org','RP404:');
select pg_temp.denied($q$select pg_temp.fault('update auth.users set is_anonymous=true where id=(select actor from vf)')$q$,'anonymous actor','RP404:');
select pg_temp.denied($q$select pg_temp.fault('update memberships set role=''marketing''where user_id=(select actor from vf)and org_id=(select org from vf)')$q$,'read-only role cannot create source provenance','RP404:');
select pg_temp.denied($q$select pg_temp.fault('insert into deletion_requests(user_id,status)select actor,''pending''from vf')$q$,'deleted actor','RP404:');
reset role;
insert into media_provenance(id,org_id,listing_id,kind,model_id,edit,label,disclosure,qc)
 select 'f8580000-0000-4000-8000-000000000099',org,listing,'reel','fal-ai/kling-video/v3/4k/image-to-video','reel','Legacy same row','Legacy immutable disclosure','{"legacy":true}'from vf;
set local role service_role;
select bind_property_video_source(actor,listing,'f8540000-0000-4000-8000-000000000001',null,'accepted-'||i,'f8580000-0000-4000-8000-000000000099',repeat('a',64),repeat('a',32))from vf cross join generate_series(6,7)i;
create temp table legacy_before as select to_jsonb(m)row from media_provenance m where id='f8580000-0000-4000-8000-000000000099';
select pg_temp.ok(pg_temp.direct(6)->>'provenance_id'='f8580000-0000-4000-8000-000000000099'and pg_temp.direct(7)->>'provenance_id'='f8580000-0000-4000-8000-000000000099','legacy shared bindings retained');
select pg_temp.ok((select to_jsonb(m)=b.row from media_provenance m,legacy_before b where m.id='f8580000-0000-4000-8000-000000000099'),'legacy row and prior QC byte-identical');
select pg_temp.ok((select ledger=(select jsonb_object_agg(id,md5(to_jsonb(x)::text))from cost_ledger x)and app=(select jsonb_object_agg(id,md5(to_jsonb(x)::text))from app_video_cost_reservations x)and serving=(select jsonb_object_agg(id,md5(to_jsonb(x)::text))from serving_cost_reservations x)and allowances=(select jsonb_object_agg(reservation_id,md5(to_jsonb(x)::text))from app_video_allowance_receipts x)from before_money),'all money/holds/allowances unchanged');
reset role;set local role authenticated;
select pg_temp.denied('select pg_temp.direct(8)','authenticated execution denied','permission denied');
reset role;set local role anon;
select pg_temp.denied('select pg_temp.direct(8)','anonymous execution denied','permission denied');
reset role;
select jsonb_build_object('passed',true,'assertions',n)from checks;
rollback;
