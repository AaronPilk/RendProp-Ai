\set ON_ERROR_STOP on
-- C2: discard a saved video request the server never accepted. Actual
-- migrations, RPCs, triggers and roles; every fixture row is rolled back.
begin;
create temporary table checks(n integer);insert into checks values(0);grant all on checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'ABANDON FAIL: %',label;end if;update checks set n=n+1;end$$;
create function pg_temp.refuse(command text,needle text,label text)returns void language plpgsql as $$begin begin execute command;exception when others then if position(needle in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception'ABANDON FAIL: allowed %',label;end$$;

-- fixture:begin (the race runner commits this exact section in its own database)
insert into auth.users(id,email,is_anonymous)values('f1900000-0000-4000-8000-000000000001','abandon-owner@fixture.invalid',false),('f1900000-0000-4000-8000-000000000002','abandon-other@fixture.invalid',false),('f1900000-0000-4000-8000-000000000003','abandon-guest@fixture.invalid',true);
create table abandon_bf as select'f1900000-0000-4000-8000-000000000001'::uuid actor,'f1900000-0000-4000-8000-000000000002'::uuid other,'f1900000-0000-4000-8000-000000000003'::uuid guest,
 (select org_id from memberships where user_id='f1900000-0000-4000-8000-000000000001'and role='owner'limit 1)org,(select org_id from memberships where user_id='f1900000-0000-4000-8000-000000000002'and role='owner'limit 1)other_org,
 'f1930000-0000-4000-8000-000000000001'::uuid listing,'f1930000-0000-4000-8000-000000000002'::uuid second_listing,'f1930000-0000-4000-8000-000000000003'::uuid other_listing;
grant select on abandon_bf to service_role,authenticated;
insert into listings(id,org_id,agent_id,address)select listing,org,actor,'Synthetic abandon property'from abandon_bf union all select second_listing,org,actor,'Second synthetic abandon property'from abandon_bf union all select other_listing,other_org,other,'Other agent property'from abandon_bf;
set session_replication_role=replica;
insert into capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type)select md5('abandon-photo:'||i)::uuid,(select listing from abandon_bf),'photo','renders','renders/'||(select org from abandon_bf)||'/'||(select listing from abandon_bf)||'/gallery-'||i||'.jpg',100,repeat('a',64),true,2,'image/jpeg'from generate_series(1,3)i;
insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,spent_bytes,state,settled_at)select id,(select org from abandon_bf),listing_id,(select actor from abandon_bf),current_date,'{}',0,bytes,'completed',now()from capture_assets where listing_id=(select listing from abandon_bf);
insert into upload_operations(asset_id,kind,bucket,object_key,bytes,expected_bytes,content_type,content_type_declared,asset_kind,state,etag)select id,'copy',bucket,storage_key,bytes,bytes,content_type,true,kind,'retained','"source-etag"'from capture_assets where listing_id=(select listing from abandon_bf);
set session_replication_role=origin;
create table abandon_bm as select jsonb_build_object('operation_id','f1970000-0000-4000-8000-000000000000','listing_id',listing,'expected_org_id',org,'purpose','listing','aspect','16:9','allow_original_photo_fallback',false,'presentation',jsonb_build_object('transition','cut','shot_caption_style','off','spoken_captions',false,'title_card',null,'shot_labels',jsonb_build_array(null,null,null)),'music',null,'narration_asset_id',null,'narration_result_id',null,'narration_words','[]'::jsonb,
 'sources',(select jsonb_agg(jsonb_build_object('photo_id','abandon:'||i,'photo_asset_id',md5('abandon-photo:'||i)::uuid,'photo_version_id','abandon-version-'||i,'photo_provenance_id',null,'motion','push_in')order by i)from generate_series(1,3)i))m from abandon_bf;
grant select on abandon_bm to service_role,authenticated;
update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';
update app_config set value='{"mode":"ceiling","free_published_listings":1}'where key='serving_mode';
set role service_role;
select apply_apple_entitlement_v2((select org from abandon_bf),(select actor from abandon_bf),'abandon-paid-original','abandon-paid-transaction','com.rendprop.app.starter.monthly','starter','Production','active',now()+interval'29 days',true,'DID_RENEW',now()-interval'1 day',now()-interval'30 seconds',now()-interval'30 seconds',now()-interval'30 seconds');
reset role;
-- fixture:end

create function pg_temp.recipe(op text)returns jsonb language sql as $$select jsonb_set(m,'{operation_id}',to_jsonb(op))from abandon_bm$$;
create function pg_temp.abandon(op text)returns jsonb language sql as $$select property_video_operation_abandon(actor,listing,org,op::uuid)from abandon_bf$$;
create function pg_temp.lookup(op text)returns jsonb language sql as $$select property_video_operation_lookup(actor,listing,org,op::uuid)from abandon_bf$$;

select pg_temp.ok((select relrowsecurity from pg_class where oid='public.property_video_abandoned_operations'::regclass),'abandon tombstones have RLS');
select pg_temp.ok(not has_table_privilege('authenticated','public.property_video_abandoned_operations','select')and not has_table_privilege('anon','public.property_video_abandoned_operations','select'),'clients cannot read tombstones');
select pg_temp.ok(has_table_privilege('service_role','public.property_video_abandoned_operations','select')and not has_table_privilege('service_role','public.property_video_abandoned_operations','insert')and not has_table_privilege('service_role','public.property_video_abandoned_operations','update')and not has_table_privilege('service_role','public.property_video_abandoned_operations','delete'),'service role can read but never forge or erase tombstones');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_operation_abandon(uuid,uuid,uuid,uuid)','execute')and not has_function_privilege('anon','public.property_video_operation_abandon(uuid,uuid,uuid,uuid)','execute')and has_function_privilege('service_role','public.property_video_operation_abandon(uuid,uuid,uuid,uuid)','execute'),'only the actor-checked service route can discard');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_operation_lookup(uuid,uuid,uuid,uuid)','execute'),'lookup remains service-only');
select pg_temp.ok((select count(*)=2 from pg_trigger where tgname in('property_video_jobs_operation_open','property_video_refused_operation_open')and tgenabled<>'D'),'job and refusal inserts pass the abandonment fence');

set local role service_role;
-- An operation the server never saw is discarded permanently, with exact echoes.
create temporary table a1 as select pg_temp.abandon('f1970000-0000-4000-8000-000000000001')r;
select pg_temp.ok((select r->>'operation_closed'='true'and r->>'closed_reason'='abandoned'and r->'job_id'='null'::jsonb and r->>'operation_id'='f1970000-0000-4000-8000-000000000001'and(r->>'listing_id')::uuid=(select listing from abandon_bf)and(r->>'selected_library_org_id')::uuid=(select org from abandon_bf)and(r->>'org_id')::uuid=(select org from abandon_bf)and r->>'message'like'You discarded this saved request%'from a1),'unseen operation is durably discarded with exact echoes');
create temporary table t1 as select created_at,library_org_id from property_video_abandoned_operations where actor_id=(select actor from abandon_bf)and operation_id='f1970000-0000-4000-8000-000000000001';
select pg_temp.ok((select count(*)=1 and min(library_org_id::text)=(select org::text from abandon_bf)from t1),'one exact tombstone for the actor operation');
select pg_temp.ok(pg_temp.abandon('f1970000-0000-4000-8000-000000000001')=(select r from a1),'lost discard reply replays the identical closure');
select pg_temp.ok((select count(*)=1 and min(created_at)=(select created_at from t1)from property_video_abandoned_operations where operation_id='f1970000-0000-4000-8000-000000000001'),'discard replay never rewrites its tombstone');
select pg_temp.ok(pg_temp.lookup('f1970000-0000-4000-8000-000000000001')=(select r from a1),'lookup reports the same durable abandonment');
select pg_temp.refuse($q$select property_video_job_enqueue((select actor from abandon_bf),pg_temp.recipe('f1970000-0000-4000-8000-000000000001'))$q$,'RP409: This saved video request was discarded','delayed enqueue after abandonment is refused');
select pg_temp.refuse($q$select property_video_job_admit((select actor from abandon_bf),pg_temp.recipe('f1970000-0000-4000-8000-000000000001'),30,'legacy')$q$,'RP409: This saved video request was discarded','delayed funded admission after abandonment is refused');
select pg_temp.refuse($q$select property_video_job_admit((select actor from abandon_bf),pg_temp.recipe('f1970000-0000-4000-8000-000000000001'),9000000,'legacy')$q$,'RP409: This saved video request was discarded','late capacity refusal cannot relabel a discarded request');
select pg_temp.ok(not exists(select 1 from property_video_jobs where actor_id=(select actor from abandon_bf)and operation_id='f1970000-0000-4000-8000-000000000001')and not exists(select 1 from property_video_refused_operations where actor_id=(select actor from abandon_bf)and operation_id='f1970000-0000-4000-8000-000000000001'),'discarded operation has no job and no refusal');
select pg_temp.refuse($q$select property_video_operation_abandon(actor,second_listing,org,'f1970000-0000-4000-8000-000000000001')from abandon_bf$q$,'RP409: This saved operation belongs to another property','discard cannot move to another property');
select pg_temp.refuse($q$select property_video_operation_lookup(actor,second_listing,org,'f1970000-0000-4000-8000-000000000001')from abandon_bf$q$,'RP409: This saved operation belongs to another property','lookup refuses another property for the discarded operation');
select pg_temp.refuse($q$select property_video_job_enqueue((select actor from abandon_bf),jsonb_set(pg_temp.recipe('f1970000-0000-4000-8000-000000000001'),'{listing_id}',to_jsonb((select second_listing::text from abandon_bf))))$q$,'RP409: This saved video request was discarded','the discarded operation cannot start for another property either');

-- Accepted work keeps its job: discard resolves to it and never cancels it.
create temporary table j2 as select property_video_job_admit((select actor from abandon_bf),pg_temp.recipe('f1970000-0000-4000-8000-000000000002'),30,'legacy')r;
select pg_temp.ok((select r->>'accepted'='true'from j2),'funded fixture admits an ordinary recipe');
create temporary table a2 as select pg_temp.abandon('f1970000-0000-4000-8000-000000000002')r;
select pg_temp.ok((select r->>'operation_closed'='false'and r->'closed_reason'='null'::jsonb and r->>'job_id'=(select r#>>'{job,id}'from j2)from a2),'discard resolves an accepted operation to its existing job');
select pg_temp.ok(not exists(select 1 from property_video_abandoned_operations where operation_id='f1970000-0000-4000-8000-000000000002')and(select state='queued'and cancelled_at is null from property_video_jobs where id=(select(r#>>'{job,id}')::uuid from j2)),'accepted job is retained, not cancelled or tombstoned');
select pg_temp.ok((property_video_job_enqueue((select actor from abandon_bf),pg_temp.recipe('f1970000-0000-4000-8000-000000000002'))).id=(select(r#>>'{job,id}')::uuid from j2),'accepted operation still replays its same job');
select pg_temp.ok((select array_agg(photo_id order by position)=array['abandon:1','abandon:2','abandon:3']from property_video_job_sources where job_id=(select(r#>>'{job,id}')::uuid from j2)),'accepted manifest order is unchanged');
select pg_temp.refuse($q$update property_video_jobs set operation_id='f1970000-0000-4000-8000-000000000001'where id=(select(r#>>'{job,id}')::uuid from j2)$q$,'RP409: This saved video request was discarded','a job cannot be moved onto a discarded operation');

-- A durable capacity refusal stays a refusal; discard reports it unchanged.
select pg_temp.ok(property_video_job_admit((select actor from abandon_bf),pg_temp.recipe('f1970000-0000-4000-8000-000000000003'),9000000,'legacy')->>'operation_closed'='true','capacity refusal closes its operation');
create temporary table a3 as select pg_temp.abandon('f1970000-0000-4000-8000-000000000003')r;
select pg_temp.ok((select r->>'operation_closed'='true'and r->>'closed_reason'='capacity_refused'and r->'job_id'='null'::jsonb and r->>'message'=(select message from property_video_refused_operations where operation_id='f1970000-0000-4000-8000-000000000003')from a3),'discard reports an existing capacity refusal unchanged');
select pg_temp.ok(not exists(select 1 from property_video_abandoned_operations where operation_id='f1970000-0000-4000-8000-000000000003')and pg_temp.lookup('f1970000-0000-4000-8000-000000000003')->>'closed_reason'='capacity_refused','refusal is never relabeled as abandonment');

-- Tombstones are per actor; scope, guest and identity checks precede any write.
select pg_temp.ok((select property_video_operation_abandon(other,other_listing,other_org,'f1970000-0000-4000-8000-000000000004')->>'closed_reason'='abandoned'from abandon_bf),'another agent discards their own operation');
select pg_temp.ok(property_video_job_admit((select actor from abandon_bf),pg_temp.recipe('f1970000-0000-4000-8000-000000000004'),30,'legacy')->>'accepted'='true','another account tombstone never blocks this agent operation');
select pg_temp.refuse($q$select property_video_operation_abandon(other,listing,org,'f1970000-0000-4000-8000-000000000005')from abandon_bf$q$,'RP403: This listing is not available to this account','foreign agent cannot discard on this property');
select pg_temp.refuse($q$select property_video_operation_abandon(actor,listing,other_org,'f1970000-0000-4000-8000-000000000005')from abandon_bf$q$,'RP404:','discard requires the selected library');
select pg_temp.refuse($q$select property_video_operation_abandon(guest,listing,org,'f1970000-0000-4000-8000-000000000005')from abandon_bf$q$,'RP403: A named account is required','guest cannot discard');
select pg_temp.refuse($q$select property_video_operation_abandon(actor,listing,org,null)from abandon_bf$q$,'RP400:','discard needs the exact operation');
select pg_temp.ok(not exists(select 1 from property_video_abandoned_operations where operation_id='f1970000-0000-4000-8000-000000000005'),'refused discard attempts write nothing');

-- After a discard the agent's new recipe, in a new order, is admitted normally.
create temporary table j5 as select property_video_job_admit((select actor from abandon_bf),jsonb_set(pg_temp.recipe('f1970000-0000-4000-8000-000000000005'),'{sources}',(select jsonb_agg(e order by n desc)from jsonb_array_elements(pg_temp.recipe('f1970000-0000-4000-8000-000000000005')->'sources')with ordinality s(e,n))),30,'legacy')r;
select pg_temp.ok((select r->>'accepted'='true'from j5)and(select array_agg(photo_id order by position)=array['abandon:3','abandon:2','abandon:1']from property_video_job_sources where job_id=(select(r#>>'{job,id}')::uuid from j5)),'a new operation after discard keeps the agent-chosen order');

-- A stale edge pre-check cannot admit an operation discarded after it.
select pg_temp.ok(pg_temp.lookup('f1970000-0000-4000-8000-000000000006')->>'operation_closed'='false'and pg_temp.lookup('f1970000-0000-4000-8000-000000000006')->'job_id'='null'::jsonb,'edge pre-check sees an open operation');
select pg_temp.ok(pg_temp.abandon('f1970000-0000-4000-8000-000000000006')->>'closed_reason'='abandoned','discard commits after that pre-check');
select pg_temp.refuse($q$select property_video_job_admit((select actor from abandon_bf),pg_temp.recipe('f1970000-0000-4000-8000-000000000006'),30,'legacy')$q$,'RP409: This saved video request was discarded','admission after a stale pre-check is still refused');

reset role;set local role authenticated;
select pg_temp.refuse($q$select property_video_operation_abandon('f1900000-0000-4000-8000-000000000001','f1930000-0000-4000-8000-000000000001',null,'f1970000-0000-4000-8000-000000000007')$q$,'permission denied','client role cannot call discard directly');
reset role;select jsonb_build_object('passed',true,'assertions',n)from checks;
rollback;
