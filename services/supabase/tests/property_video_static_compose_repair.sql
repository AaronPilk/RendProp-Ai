\set ON_ERROR_STOP on
begin;
create temporary table checks(n integer);insert into checks values(0);grant all on checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'BGVIDEO FAIL: %',label;end if;update checks set n=n+1;end$$;
create function pg_temp.refuse(command text,needle text,label text)returns void language plpgsql as $$begin begin execute command;exception when others then if position(needle in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception'BGVIDEO FAIL: allowed %',label;end$$;

-- Closed synthetic provider transport, actual paid binding/QC/fallback RPCs.
-- These rows attest receipt authority only, never real generated pixels.
create function pg_temp.paid_clip(c jsonb)returns jsonb language plpgsql as $$declare j public.property_video_jobs;src public.property_video_job_sources;rid uuid:=gen_random_uuid();lid uuid:=gen_random_uuid();request text;prov public.media_provenance;claim jsonb;begin
 select * into j from public.property_video_jobs where id=(c#>>'{job,id}')::uuid;select * into src from public.property_video_job_sources where job_id=j.id and attempt_id=(c#>>'{source,attempt_id}')::uuid;
 request:='fixture-provider:'||src.attempt_id;
 insert into public.app_video_cost_reservations(id,actor_id,org_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents,meta)values(rid,j.actor_id,j.org_id,src.request_key,'reel','fal','fixture-model',src.source->>'sha256',1,.0001,.0001,.0001,'{"task":"video.reel_clip"}');
 insert into public.cost_ledger(id,org_id,feature,provider,model,total_cents,meta)values(lid,j.org_id,'reel','fal','fixture-model',.0001,jsonb_build_object('app_video_reservation_id',rid,'request_id',request,'request_key',src.request_key,'stage','reel'));
 update public.app_video_cost_reservations set provider_request_id=request,cost_ledger_id=lid,settled_at=now()where id=rid;
 insert into public.app_video_allowance_receipts(reservation_id,listing_id,monthly_key,monthly_window_start,burst_key,burst_window_start)values(rid,j.listing_id,'fixture-month',now(),'fixture-burst',now());
 perform public.property_video_job_receipt(j.id,src.attempt_id,jsonb_build_object('request_id',request,'model_id','fixture-model','status_url','https://receipt.fixture.invalid/?job=closed'));
 prov:=public.property_video_job_provenance(j.id,src.attempt_id,request,'fixture-model');
 perform public.bind_property_video_source(j.actor_id,j.listing_id,src.asset_id,src.photo_provenance_id,request,prov.id,src.source->>'sha256',repeat('d',32));
 perform public.property_video_job_clip(j.id,src.attempt_id,jsonb_build_object('storage_key','private-fixture/'||src.attempt_id||'.mp4','sha256',repeat('e',64),'width',1088,'height',1920,'duration_s',5.042));
 claim:=public.property_video_job_claim(j.id,'slot-0');if claim->>'action'<>'extract_frames'then raise exception'BGVIDEO FAIL: paid fixture did not claim quality extraction';end if;return claim;end$$;
insert into auth.users(id,email,is_anonymous)values('f1100000-0000-4000-8000-000000000001','background-owner@fixture.invalid',false),('f1100000-0000-4000-8000-000000000002','background-other@fixture.invalid',false);
create temporary table bf as select 'f1100000-0000-4000-8000-000000000001'::uuid actor,'f1100000-0000-4000-8000-000000000002'::uuid other,(select org_id from memberships where user_id='f1100000-0000-4000-8000-000000000001'and role='owner'limit 1)org,(select org_id from memberships where user_id='f1100000-0000-4000-8000-000000000002'and role='owner'limit 1)other_org,'f1300000-0000-4000-8000-000000000001'::uuid listing;
grant select on bf to service_role,authenticated;
-- Seed the synthetic home under the paid authority used by this video proof.
update public.orgs set plan='team',plan_source='manual',plan_expires_at=null where id=(select org from bf);
insert into listings(id,org_id,agent_id,address)values((select listing from bf),(select org from bf),(select actor from bf),'Synthetic background property');
set local session_replication_role=replica;
insert into capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type)select md5('bg-photo:'||i)::uuid,(select listing from bf),'photo','renders','renders/'||(select org from bf)||'/'||(select listing from bf)||'/gallery-'||i||'.jpg',100,repeat('a',64),true,2,'image/jpeg'from generate_series(1,100)i;
insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,spent_bytes,state,settled_at)select id,(select org from bf),listing_id,(select actor from bf),current_date,'{}',0,bytes,'completed',now()from capture_assets where listing_id=(select listing from bf);
insert into upload_operations(asset_id,kind,bucket,object_key,bytes,expected_bytes,content_type,content_type_declared,asset_kind,state,etag)select id,'copy',bucket,storage_key,bytes,bytes,content_type,true,kind,'retained','"source-etag"'from capture_assets where listing_id=(select listing from bf);
set local session_replication_role=origin;
create temporary table bm as select jsonb_build_object('operation_id','f1700000-0000-4000-8000-000000000001','listing_id',listing,'expected_org_id',org,'purpose','listing','aspect','16:9','allow_original_photo_fallback',true,'presentation',jsonb_build_object('transition','cut','shot_caption_style','off','spoken_captions',false,'title_card',null,'shot_labels',(select jsonb_agg(null::text)from generate_series(1,100))),'music',null,'narration_asset_id',null,'narration_result_id',null,'narration_words','[]'::jsonb,'sources',(select jsonb_agg(jsonb_build_object('photo_id','selected:'||i,'photo_asset_id',md5('bg-photo:'||i)::uuid,'photo_version_id','staged-selected-'||i,'photo_provenance_id',null,'motion','push_in')order by i)from generate_series(1,100)i))m from bf;
grant select on bm to service_role,authenticated;
reset role;update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';
create function pg_temp.cpu_job(i integer)returns jsonb language plpgsql as $$declare j public.property_video_jobs;c jsonb;begin
 j:=property_video_job_enqueue((select actor from bf),jsonb_set(jsonb_set((select m from bm),'{operation_id}',to_jsonb(('f3700000-0000-4000-8000-'||lpad(i::text,12,'0'))::text)),'{sources}',jsonb_build_array((select m#>'{sources,0}'from bm),(select m#>'{sources,1}'from bm))));
 c:=property_video_job_claim(j.id,'slot-0');return pg_temp.paid_clip(c);end$$;

-- Summary pass is not the server quality decision. These exact closed
-- fixtures exercise stored evidence only; no generated pixels or provider calls.
create function pg_temp.retry_grant(c jsonb,summary text default'pass')returns void language plpgsql security definer as $$declare j public.property_video_jobs;s public.property_video_job_sources;r public.app_video_cost_reservations;v jsonb;begin
 select *into j from property_video_jobs where id=(c#>>'{job,id}')::uuid;select *into s from property_video_job_sources where job_id=j.id and attempt_id=(c#>>'{source,attempt_id}')::uuid;
 select *into r from app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key;
 v:=jsonb_build_object('task','judge.qc_drift','request_id',s.receipt->>'request_id','source_sha256',repeat('d',32),'verdict',summary,'action','retry','publishable',false,'failed',jsonb_build_array('additions','artifacts'),'attempt',0,'scores',jsonb_build_object('architecture',95,'contents',97,'additions',0,'artifacts',8,'same_room',98),'thresholds',jsonb_build_object('architecture',85,'contents',80,'additions',90,'artifacts',75,'same_room',90));
 update media_provenance set qc=v where id=s.generation_provenance_id;
 insert into cost_ledger(org_id,feature,provider,model,total_cents,meta)values(j.org_id,'qc','anthropic','fixture-judge',.0001,v||jsonb_build_object('kind','video_drift','provenance_id',s.generation_provenance_id,'source_asset_id',s.asset_id));
 insert into app_video_drift_checks(reservation_id,actor_id,org_id,listing_id,source_sha256,state,result)values(r.id,j.actor_id,j.org_id,j.listing_id,repeat('d',32),'retry',jsonb_build_object('drift',v||jsonb_build_object('status','fail')));end$$;
create function pg_temp.accepted_only(c jsonb)returns jsonb language plpgsql as $$declare j public.property_video_jobs;src public.property_video_job_sources;rid uuid:=gen_random_uuid();lid uuid:=gen_random_uuid();request text;prov public.media_provenance;claim jsonb;begin
 select * into j from public.property_video_jobs where id=(c#>>'{job,id}')::uuid;select * into src from public.property_video_job_sources where job_id=j.id and attempt_id=(c#>>'{source,attempt_id}')::uuid;
 request:='fixture-provider:'||src.attempt_id;
 insert into public.app_video_cost_reservations(id,actor_id,org_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents,meta)values(rid,j.actor_id,j.org_id,src.request_key,'reel','fal','fixture-model',src.source->>'sha256',1,.0001,.0001,.0001,'{"task":"video.reel_clip"}');
 insert into public.cost_ledger(id,org_id,feature,provider,model,total_cents,meta)values(lid,j.org_id,'reel','fal','fixture-model',.0001,jsonb_build_object('app_video_reservation_id',rid,'request_id',request,'request_key',src.request_key,'stage','reel'));
 update public.app_video_cost_reservations set provider_request_id=request,cost_ledger_id=lid,settled_at=now()where id=rid;
 insert into public.app_video_allowance_receipts(reservation_id,listing_id,monthly_key,monthly_window_start,burst_key,burst_window_start)values(rid,j.listing_id,'fixture-month',now(),'fixture-burst',now());
 perform public.property_video_job_receipt(j.id,src.attempt_id,jsonb_build_object('request_id',request,'model_id','fixture-model','status_url','https://receipt.fixture.invalid/?job=closed'));
 prov:=public.property_video_job_provenance(j.id,src.attempt_id,request,'fixture-model');
 select *into src from public.property_video_job_sources where job_id=j.id and attempt_id=src.attempt_id;return jsonb_build_object('job',to_jsonb(j),'source',to_jsonb(src));end$$;

create function pg_temp.accept_qc(c jsonb)returns void language plpgsql as $$declare src public.property_video_job_sources;j public.property_video_jobs;begin
 select *into src from property_video_job_sources where job_id=(c#>>'{job,id}')::uuid and attempt_id=(c#>>'{source,attempt_id}')::uuid;select *into j from property_video_jobs where id=src.job_id;
 update media_provenance set qc=jsonb_build_object('publishable',true,'request_id',src.receipt->>'request_id','source_sha256',repeat('d',32))where id=src.generation_provenance_id;
 insert into cost_ledger(org_id,feature,provider,model,total_cents,meta)values(j.org_id,'qc','anthropic','fixture-judge',.0001,jsonb_build_object('request_id',src.receipt->>'request_id','publishable',true));
 perform property_video_job_qc(j.id,src.lease_token,src.attempt_id);end$$;
create function pg_temp.target_poll(j uuid,pos integer)returns jsonb language plpgsql as $$declare c jsonb;begin
 for i in 1..6 loop c:=property_video_job_claim(j,'slot-0');if c->>'action'='poll'and(c#>>'{source,position}')::integer=pos then return c;end if;
 if c->>'action'='poll'then perform property_video_job_poll_release(j,(c#>>'{source,lease_token}')::uuid,(c#>>'{source,attempt_id}')::uuid);else raise exception'Expected same accepted receipt poll, got %',c->>'action';end if;end loop;raise exception'No saved receipt poll';end$$;

reset role;
create function pg_temp.ready_recipe(i integer,use_fallback boolean default true)returns uuid language plpgsql as $$declare j public.property_video_jobs;c jsonb;src public.property_video_job_sources;v jsonb;begin
 j:=property_video_job_enqueue((select actor from bf),jsonb_set(jsonb_set((select m from bm),'{operation_id}',to_jsonb(('f3800000-0000-4000-8000-'||lpad(i::text,12,'0'))::text)),'{sources}',(select jsonb_agg(x)from jsonb_array_elements((select m->'sources'from bm))with ordinality e(x,n)where n<=3)));
 for n in 0..2 loop
  c:=pg_temp.paid_clip(property_video_job_claim(j.id,'slot-0'));
  if n=2 and use_fallback then
   select *into src from property_video_job_sources where job_id=j.id and attempt_id=(c#>>'{source,attempt_id}')::uuid;
   v:=jsonb_build_object('task','judge.qc_drift','request_id',src.receipt->>'request_id','source_sha256',repeat('d',32),'verdict','fail','action','refuse','publishable',false,'failed',jsonb_build_array('architecture'));
   update media_provenance set qc=v where id=src.generation_provenance_id;
   insert into cost_ledger(org_id,feature,provider,model,total_cents,meta)values(j.org_id,'qc','anthropic','fixture-judge',.0001,v||jsonb_build_object('kind','video_drift','provenance_id',src.generation_provenance_id,'source_asset_id',src.asset_id));
   perform property_video_job_failure(j.id,src.lease_token,src.attempt_id,'quality_check_refused',false);
  else perform pg_temp.accept_qc(c);end if;
 end loop;return j.id;end$$;
create function pg_temp.fail_assembly(j uuid)returns void language plpgsql as $$declare c jsonb;begin
 for i in 1..3 loop c:=property_video_job_claim(j,'slot-0');if c->>'action'<>'compose'then raise exception'Expected assembly only';end if;perform property_video_job_failure(j,(c#>>'{job,compose_lease}')::uuid,null,'cpu_attempt_failed',false);end loop;end$$;
set local role service_role;
create temporary table cj as select pg_temp.ready_recipe(9001)id;select pg_temp.fail_assembly((select id from cj));grant select on cj to service_role,authenticated;

select property_video_job_resume((select actor from bf),(select id from cj),0);select pg_temp.fail_assembly((select id from cj));
reset role;
create temporary table snapshot as select(select to_jsonb(j)from property_video_jobs j where id=(select id from cj))j,(select jsonb_agg(to_jsonb(s)order by position)from property_video_job_sources s where job_id=(select id from cj))sources,(select jsonb_agg(to_jsonb(l)order by id)from cost_ledger l)ledgers,(select jsonb_agg(to_jsonb(r)order by id)from app_video_cost_reservations r)reservations,(select jsonb_agg(to_jsonb(r)order by id)from serving_cost_reservations r)serving;
grant select on snapshot to service_role,authenticated;
create function pg_temp.available()returns boolean language plpgsql security definer as $$begin return property_video_static_repair_available((select id from cj));end$$;
create function pg_temp.deny_change(command text,label text)returns void language plpgsql as $$declare denied boolean;begin
 begin execute'set local session_replication_role=replica';execute command;execute'set local session_replication_role=origin';execute'set local role service_role';begin denied:=not pg_temp.available();exception when sqlstate'P0001'then if sqlerrm not like'RP404:%'and sqlerrm not like'RP409:%'then raise;end if;denied:=true;end;execute'reset role';raise exception using errcode='PZ001',message='rollback synthetic mutation';exception when sqlstate'PZ001'then null;end;perform pg_temp.ok(denied,label);end$$;
set local role service_role;
select pg_temp.ok(not pg_temp.available(),'repair defaults OFF before verified image');
select pg_temp.refuse(format('select property_video_job_repair_static_compose(%L,%L,%L)',(select actor from bf),(select id from cj),'fe000000-0000-4000-8000-000000000001'),'RP409','no repair before fixed renderer policy activation');
reset role;
update app_config set value=value||jsonb_build_object('enabled',true,'renderer_image_sha256',repeat('9',64))where key='property_video_static_fallback_repair';
set local role service_role;
select pg_temp.ok(pg_temp.available(),'verified fixed renderer permits exact second explicit cycle');
select pg_temp.ok((select compose_recoveries=1 and compose_attempts=3 and state='failed'from property_video_jobs where id=(select id from cj)),'availability is read only');
reset role;
select pg_temp.ok(not has_function_privilege('authenticated','property_video_job_repair_static_compose(uuid,uuid,uuid)','execute')and not has_function_privilege('anon','property_video_static_repair_available(uuid)','execute'),'repair is service only');
select pg_temp.deny_change($q$update app_config set value=value-'policy'where key='property_video_static_fallback_repair'$q$,'missing policy refuses repair');
select pg_temp.deny_change($q$update app_config set value=jsonb_set(value,'{policy}','"wrong"')where key='property_video_static_fallback_repair'$q$,'wrong policy refuses repair');
select pg_temp.deny_change($q$update app_config set value=jsonb_set(value,'{renderer_runtime_sha256}',to_jsonb(repeat('0',64)))where key='property_video_static_fallback_repair'$q$,'wrong renderer runtime refuses repair');
select pg_temp.deny_change($q$update app_config set value=value-'renderer_image_sha256'where key='property_video_static_fallback_repair'$q$,'missing exact image refuses repair');
select pg_temp.deny_change($q$update property_video_jobs set compose_until=now()+interval'1 minute'where id=(select id from cj)$q$,'active assembly lease cannot repair');
select pg_temp.deny_change($q$update property_video_jobs set deadline=now()-interval'1 minute'where id=(select id from cj)$q$,'expired saved recipe cannot repair');
select pg_temp.deny_change($q$update property_video_jobs set cancelled_at=now()where id=(select id from cj)$q$,'cancelled recipe cannot repair');
select pg_temp.deny_change($q$update property_video_jobs set result='{}'where id=(select id from cj)$q$,'any output result prevents repair');
select pg_temp.deny_change($q$update property_video_job_sources set state='processing'where job_id=(select id from cj)and position=0$q$,'unfinished source cannot repair');
select pg_temp.deny_change($q$update property_video_job_sources set receipt=jsonb_set(receipt,'{model_id}','"foreign"')where job_id=(select id from cj)and position=0$q$,'foreign paid model cannot repair');
select pg_temp.deny_change($q$update property_video_job_sources set source=jsonb_set(source,'{sha256}',to_jsonb(repeat('f',64)))where job_id=(select id from cj)and position=0$q$,'current source identity cannot be changed');
select pg_temp.deny_change($q$update capture_assets set uploaded=false where id=(select asset_id from property_video_job_sources where job_id=(select id from cj)and position=0)$q$,'withdrawn source cannot repair');
select pg_temp.deny_change($q$update app_video_cost_reservations set settled_at=null,cost_ledger_id=null,provider_request_id=null where idempotency_key=(select request_key from property_video_job_sources where job_id=(select id from cj)and position=0)$q$,'unsettled generation cannot repair');
select pg_temp.deny_change($q$update cost_ledger set meta=meta-'request_id'where feature='reel'$q$,'paid ledger request identity required');
select pg_temp.deny_change($q$update media_provenance set qc=jsonb_set(qc,'{publishable}','false')where id=(select generation_provenance_id from property_video_job_sources where job_id=(select id from cj)and position=0)$q$,'unknown or refused quality cannot repair as ready');
select pg_temp.deny_change($q$delete from cost_ledger where feature='qc'and meta->'publishable'='true'::jsonb$q$,'paid quality approval required');
select pg_temp.deny_change($q$update property_video_job_sources set fallback_evidence='{}'where job_id=(select id from cj)and state='original_photo'$q$,'fallback retains exact paid structural refusal');
select pg_temp.deny_change($q$update property_video_jobs set compose_recovery_history=jsonb_set(compose_recovery_history,'{0,sources_sha256}',to_jsonb(repeat('f',64)))where id=(select id from cj)$q$,'prior recovery source snapshot must match');
select pg_temp.deny_change($q$insert into capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded)select output_asset_id,listing_id,'video','renders','synthetic/uncertain.mp4',1,repeat('b',64),false from property_video_jobs where id=(select id from cj)$q$,'any reserved output asset blocks uncertain overwrite');
select pg_temp.deny_change($q$insert into property_video_job_outputs(asset_id,job_id,lease_token,kind,storage_key,bytes,sha256,content_type)select s.asset_id,j.id,j.compose_lease,'video','synthetic/prior-admission.mp4',100,repeat('b',64),'video/mp4'from property_video_jobs j join property_video_job_sources s on s.job_id=j.id and s.position=0 where j.id=(select id from cj)$q$,'any job output journal blocks uncertain overwrite');
set local role service_role;
select pg_temp.refuse(format('select property_video_job_resume(%L,%L,0)',(select actor from bf),(select id from cj)),'RP409','old body replay cannot start repair cycle');
select pg_temp.refuse(format('select property_video_job_repair_static_compose(%L,%L,%L)',(select other from bf),(select id from cj),'fe000000-0000-4000-8000-000000000001'),'RP404','foreign actor cannot repair');
select pg_temp.refuse(format('select property_video_job_repair_static_compose(%L,%L,null)',(select actor from bf),(select id from cj)),'RP400','explicit new operation required');
select pg_temp.ok((property_video_job_repair_static_compose((select actor from bf),(select id from cj),'fe000000-0000-4000-8000-000000000001')).state='generating','explicit repair reassembles without supplier work');
select pg_temp.ok((property_video_job_repair_static_compose((select actor from bf),(select id from cj),'fe000000-0000-4000-8000-000000000001')).state='generating','lost repair response acknowledges same cycle');
select pg_temp.ok(not pg_temp.available(),'repair is no longer offered after one transition');
select pg_temp.ok((select compose_recoveries=2 and compose_attempts=0 and jsonb_array_length(compose_recovery_history)=2 and compose_recovery_history->0=(select j#>'{compose_recovery_history,0}'from snapshot)and compose_recovery_history#>>'{1,repair_operation}'='fe000000-0000-4000-8000-000000000001'from property_video_jobs where id=(select id from cj)),'repair appends exact prior prefix and explicit operation');
select pg_temp.ok((select output_asset_id::text=(select j->>'output_asset_id'from snapshot)and poster_asset_id::text=(select j->>'poster_asset_id'from snapshot)and manifest_sha256=(select j->>'manifest_sha256'from snapshot)and operation_id::text=(select j->>'operation_id'from snapshot)and deadline=(select(j->>'deadline')::timestamptz from snapshot)and quality_profile=(select j->>'quality_profile'from snapshot)from property_video_jobs where id=(select id from cj)),'output IDs manifest operation profile and deadline are exact');
select pg_temp.ok((select jsonb_agg(to_jsonb(s)order by position)from property_video_job_sources s where job_id=(select id from cj))=(select sources from snapshot),'every ready clip fallback receipt and source history unchanged');
select pg_temp.ok((select jsonb_agg(to_jsonb(l)order by id)from cost_ledger l)=(select ledgers from snapshot)and(select jsonb_agg(to_jsonb(r)order by id)from app_video_cost_reservations r)=(select reservations from snapshot)and(select jsonb_agg(to_jsonb(r)order by id)from serving_cost_reservations r)is not distinct from(select serving from snapshot),'no supplier ledger refund reservation or QC call created');
select pg_temp.refuse(format('select property_video_job_repair_static_compose(%L,%L,%L)',(select actor from bf),(select id from cj),'fe000000-0000-4000-8000-000000000002'),'RP409','different operation cannot add another cycle');
select pg_temp.refuse($q$update property_video_jobs set compose_recoveries=1,compose_recovery_history=compose_recovery_history->0 where id=(select id from cj)$q$,'RP409','repair history cannot be erased');
create temporary table claim as select property_video_job_claim((select id from cj),'slot-0')c;grant select on claim to service_role;
select pg_temp.ok((select c->>'action'='compose'and c#>>'{job,output_asset_id}'=(select j->>'output_asset_id'from snapshot)and c#>>'{job,poster_asset_id}'=(select j->>'poster_asset_id'from snapshot)from claim),'repair claim preserves exact reserved output identities');
select pg_temp.ok((property_video_job_claim((select id from cj),'slot-1'))->>'action'='wait','second slot cannot duplicate current repaired assembly');
select pg_temp.refuse(format('select property_video_job_outputs_reserve(%L,%L,100,%L,100,%L)',(select id from cj),(select(j->>'compose_lease')::uuid from snapshot),repeat('b',64),repeat('c',64)),'RP409','old pre-repair lease cannot admit output');
select property_video_job_failure((select id from cj),(select(c#>>'{job,compose_lease}')::uuid from claim),null,'cpu_attempt_failed',false);
select property_video_job_failure((select id from cj),(property_video_job_claim((select id from cj),'slot-0')#>>'{job,compose_lease}')::uuid,null,'cpu_attempt_failed',false);
select property_video_job_failure((select id from cj),(property_video_job_claim((select id from cj),'slot-0')#>>'{job,compose_lease}')::uuid,null,'cpu_attempt_failed',false);
select pg_temp.ok((property_video_job_repair_static_compose((select actor from bf),(select id from cj),'fe000000-0000-4000-8000-000000000001')).state='failed','same repair operation acknowledges later terminal failure');
select pg_temp.refuse(format('select property_video_job_repair_static_compose(%L,%L,%L)',(select actor from bf),(select id from cj),'fe000000-0000-4000-8000-000000000002'),'RP409','a second repair operation cannot start third recovery');
select pg_temp.refuse(format('select property_video_job_resume(%L,%L,0)',(select actor from bf),(select id from cj)),'RP409','old ordinary Resume remains exhausted');
select pg_temp.ok((select message='Video assembly could not finish. Your finished clips are saved.'from property_video_jobs where id=(select id from cj)),'terminal message does not promise automatic resume');
create temporary table nofallback as select pg_temp.ready_recipe(9002,false)id;grant select on nofallback to service_role;
select pg_temp.fail_assembly((select id from nofallback));select property_video_job_resume((select actor from bf),(select id from nofallback),0);select pg_temp.fail_assembly((select id from nofallback));
select pg_temp.ok(not property_video_static_repair_available((select id from nofallback)),'static-photo repair does not expand unrelated all-AI failures');
select json_build_object('passed',true,'assertions',(select n from checks),'providerCalls',0,'pixelClaims',false);rollback;
