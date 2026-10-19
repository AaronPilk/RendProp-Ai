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

reset role;update public.orgs set plan='team',plan_source='manual',plan_expires_at=null where id=(select org from bf);
set local role service_role;
create temporary table missing_job as select property_video_job_enqueue((select actor from bf),jsonb_set(jsonb_set((select m from bm),'{operation_id}','"f3700000-0000-4000-8000-000000009001"'),'{sources}',(select jsonb_agg(x)from jsonb_array_elements((select m->'sources'from bm))with ordinality e(x,n)where n<=4)))j;
create temporary table ready_case as select pg_temp.paid_clip(property_video_job_claim((select(j).id from missing_job),'slot-0'))c;select pg_temp.accept_qc((select c from ready_case));
create temporary table processing_case as select pg_temp.accepted_only(property_video_job_claim((select(j).id from missing_job),'slot-0'))c;
create temporary table missing_case as select pg_temp.accepted_only(property_video_job_claim((select(j).id from missing_job),'slot-0'))c;
reset role;set local session_replication_role=replica;update property_video_job_sources set quality_retries=1,quality_retry_history='[{"syntheticPriorQualityAttempt":true}]',admission_retries=2 where job_id=(select(j).id from missing_job)and position=2;set local session_replication_role=origin;set local role service_role;
create temporary table missing_poll as select pg_temp.target_poll((select(j).id from missing_job),2)c;
grant select on missing_job,ready_case,processing_case,missing_case,missing_poll to service_role,authenticated;
select pg_temp.ok(not property_video_missing_result_resume_available((select(j).id from missing_job)),'processing receipt never offers paid replacement');
select pg_temp.refuse(format('select property_video_job_result_missing(%L,%L,%L)',(select(j).id from missing_job),gen_random_uuid(),(select(c#>>'{source,attempt_id}')::uuid from missing_poll)),'RP409','wrong lease cannot record missing result');
select pg_temp.ok(property_video_job_result_missing((select(j).id from missing_job),(select(c#>>'{source,lease_token}')::uuid from missing_poll),(select(c#>>'{source,attempt_id}')::uuid from missing_poll)),'trusted dual404 callback pauses same job with exact paid receipt');
select pg_temp.ok(property_video_job_result_missing((select(j).id from missing_job),(select(c#>>'{source,lease_token}')::uuid from missing_poll),(select(c#>>'{source,attempt_id}')::uuid from missing_poll)),'lost callback reply records same missing decision once');
reset role;
create temporary table snapshot as select(select to_jsonb(j)from property_video_jobs j where id=(select(j).id from missing_job))j,(select jsonb_agg(to_jsonb(s)order by position)from property_video_job_sources s where job_id=(select(j).id from missing_job)and position<>2)siblings,(select jsonb_agg(to_jsonb(l)order by id)from cost_ledger l)ledgers,(select jsonb_agg(to_jsonb(r)order by id)from app_video_cost_reservations r)reservations,(select jsonb_agg(to_jsonb(r)order by id)from serving_cost_reservations r)serving;
grant select on snapshot to service_role,authenticated;
create function pg_temp.available()returns boolean language plpgsql security definer as $$begin return public.property_video_missing_result_resume_available((select(j).id from missing_job));end$$;
create function pg_temp.deny_change(command text,label text)returns void language plpgsql as $$declare denied boolean;begin
 begin execute'set local session_replication_role=replica';execute command;execute'set local session_replication_role=origin';execute'set local role service_role';denied:=not pg_temp.available();execute'reset role';raise exception using errcode='PZ001',message='rollback synthetic mutation';exception when sqlstate'PZ001'then null;end;perform pg_temp.ok(denied,label);end$$;
set local role service_role;
select pg_temp.ok(pg_temp.available(),'exact paid dual404 requires explicit replacement consent');
reset role;
select pg_temp.ok(not has_function_privilege('authenticated','property_video_job_result_missing(uuid,uuid,uuid)','execute')and not has_function_privilege('anon','property_video_missing_result_resume_available(uuid)','execute'),'paid replacement authority is service only');
select pg_temp.deny_change($q$update app_video_cost_reservations set settled_at=null,cost_ledger_id=null,provider_request_id=null where idempotency_key=(select c#>>'{source,request_key}'from missing_case)$q$,'unsettled receipt cannot recover');
select pg_temp.deny_change($q$update app_video_cost_reservations set released_at=now(),settled_at=null,cost_ledger_id=null,provider_request_id=null,rejection_status=403,rejection_error_class='upstream'where idempotency_key=(select c#>>'{source,request_key}'from missing_case)$q$,'released or refunded receipt cannot masquerade as paid missing result');
select pg_temp.deny_change($q$update app_video_cost_reservations set provider_request_id='foreign'where idempotency_key=(select c#>>'{source,request_key}'from missing_case)$q$,'different accepted request cannot recover');
select pg_temp.deny_change($q$update app_video_cost_reservations set actor_id=(select other from bf)where idempotency_key=(select c#>>'{source,request_key}'from missing_case)$q$,'foreign paid receipt cannot recover');
select pg_temp.deny_change($q$update cost_ledger set meta=meta-'request_id'where id=(select cost_ledger_id from app_video_cost_reservations where idempotency_key=(select c#>>'{source,request_key}'from missing_case))$q$,'missing paid ledger identity cannot recover');
select pg_temp.deny_change($q$update property_video_job_sources set receipt=jsonb_set(receipt,'{model_id}','"foreign"')where job_id=(select(j).id from missing_job)and position=2$q$,'different model cannot recover');
select pg_temp.deny_change($q$update property_video_job_sources set state='ambiguous'where job_id=(select(j).id from missing_job)and position=2$q$,'unknown supplier acceptance cannot recover');
select pg_temp.deny_change($q$update property_video_job_sources set missing_result_evidence=null where job_id=(select(j).id from missing_job)and position=2$q$,'missing both-endpoint evidence cannot recover');
select pg_temp.deny_change($q$update property_video_job_sources set missing_result_evidence=jsonb_set(missing_result_evidence,'{result_status}','503')where job_id=(select(j).id from missing_job)and position=2$q$,'temporary result failure cannot recover');
select pg_temp.deny_change($q$update property_video_job_sources set missing_result_evidence=jsonb_set(missing_result_evidence,'{status}','200')where job_id=(select(j).id from missing_job)and position=2$q$,'completed status plus absent result is not dual404');
select pg_temp.deny_change($q$update property_video_job_sources set missing_result_evidence=jsonb_set(missing_result_evidence,'{paid_receipt,request_id}','"foreign"')where job_id=(select(j).id from missing_job)and position=2$q$,'forged missing receipt evidence cannot recover');
select pg_temp.deny_change($q$update media_provenance set qc='{"verdict":"fail","action":"refuse"}'where id=(select(c#>>'{source,generation_provenance_id}')::uuid from missing_case)$q$,'quality refusal cannot be rerolled as lost output');
select pg_temp.deny_change($q$update property_video_job_sources set lease_until=now()+interval'1 hour'where job_id=(select(j).id from missing_job)and position=2$q$,'active lease cannot recover');
select pg_temp.deny_change($q$update capture_assets set uploaded=false where id=(select(c#>>'{source,asset_id}')::uuid from missing_case)$q$,'withdrawn original source cannot recover');
select pg_temp.deny_change($q$update property_video_jobs set deadline=now()-interval'1 minute'where id=(select(j).id from missing_job)$q$,'expired recipe cannot recover');
select pg_temp.deny_change($q$update property_video_job_sources set source=jsonb_set(source,'{sha256}',to_jsonb(repeat('f',64)))where job_id=(select(j).id from missing_job)and position=2$q$,'changed source bytes cannot recover');
select pg_temp.deny_change($q$update property_video_job_sources set paid_replacements=1 where job_id=(select(j).id from missing_job)and position=2$q$,'a paid source can receive at most one replacement');
set local role service_role;
select pg_temp.refuse(format('select property_video_job_resume(%L,%L,1)',(select other from bf),(select(j).id from missing_job)),'RP404','foreign owner cannot recover');
select pg_temp.refuse(format('select property_video_job_resume(%L,%L,0)',(select actor from bf),(select(j).id from missing_job)),'RP409','new paid attempt needs current recipe quote');
select pg_temp.refuse(format('select property_video_job_resume(%L,%L,10000000)',(select actor from bf),(select(j).id from missing_job)),'RP402','normal funding capacity still enforced');
select pg_temp.ok((property_video_job_resume((select actor from bf),(select(j).id from missing_job),.0001)).state='generating','explicit owner resume schedules one normally funded replacement');
select pg_temp.ok(not pg_temp.available(),'active resumed job no longer advertises stopped missing result');
select pg_temp.ok((select state='pending'and attempt_id is null and request_key is null and receipt is null and generation_provenance_id is null and paid_replacements=1 and jsonb_array_length(paid_replacement_history)=1 and paid_replacement_history#>>'{0,paid_receipt,request_id}'=(select c#>>'{source,receipt,request_id}'from missing_case)from property_video_job_sources where job_id=(select(j).id from missing_job)and position=2),'new attempt scheduled while original paid receipt and full prior source remain in history');
select pg_temp.ok((select paid_replacement_history#>>'{0,paid_receipt,paid_total_cents}'='0.0001'and paid_replacement_history#>>'{0,paid_receipt,ledger_total_cents}'='0.0001'and paid_replacement_history#>>'{0,paid_receipt,manifest_sha256}'=(select j->>'manifest_sha256'from snapshot)from property_video_job_sources where job_id=(select(j).id from missing_job)and position=2),'original settled amount and saved recipe profile are retained in the replacement journal');
select pg_temp.ok((select jsonb_agg(to_jsonb(s)order by position)from property_video_job_sources s where job_id=(select(j).id from missing_job)and position<>2)=(select siblings from snapshot),'ready accepted and pending siblings remain byte unchanged');
select pg_temp.ok((select manifest_sha256=(select j->>'manifest_sha256'from snapshot)and operation_id=(select(j->>'operation_id')::uuid from snapshot)and deadline=(select(j->>'deadline')::timestamptz from snapshot)from property_video_jobs where id=(select(j).id from missing_job)),'original operation manifest deadline unchanged');
select pg_temp.ok((select jsonb_agg(to_jsonb(l)order by id)from cost_ledger l)=(select ledgers from snapshot)and(select jsonb_agg(to_jsonb(r)order by id)from app_video_cost_reservations r)=(select reservations from snapshot)and(select jsonb_agg(to_jsonb(r)order by id)from serving_cost_reservations r)is not distinct from(select serving from snapshot),'all old charges and holds remain exact; no refund reservation or provider call on resume');
select pg_temp.ok((property_video_job_resume((select actor from bf),(select(j).id from missing_job),.0001)).state='generating','lost owner reply acknowledges the same recovery');
select pg_temp.ok((select paid_replacements=1 and jsonb_array_length(paid_replacement_history)=1 from property_video_job_sources where job_id=(select(j).id from missing_job)and position=2),'replay cannot repeat replacement transition');
reset role;
select pg_temp.refuse($q$update property_video_job_sources set paid_replacement_history='[]'where job_id=(select(j).id from missing_job)and position=2$q$,'RP409','old paid receipt history cannot be erased');
select pg_temp.refuse($q$update property_video_job_sources set paid_replacements=0 where job_id=(select(j).id from missing_job)and position=2$q$,'RP409','replacement limit cannot be reset');
select pg_temp.refuse($q$update property_video_job_sources set paid_replacement_history=jsonb_set(paid_replacement_history,'{0,missing_evidence,status}','503')where job_id=(select(j).id from missing_job)and position=2$q$,'RP409','known missing evidence remains immutable');
set local role service_role;
create temporary table replacement_claim as select property_video_job_claim((select(j).id from missing_job),'slot-0')c;
select pg_temp.ok((select c->>'action'='dispatch'and(c#>>'{source,position}')::integer=2 and c#>>'{source,attempt_id}'is distinct from(select c#>>'{source,attempt_id}'from missing_case)from replacement_claim),'normal claim creates exactly one fresh request for affected source only');
select pg_temp.ok((select quality_retries=1 and admission_retries=2 from property_video_job_sources where job_id=(select(j).id from missing_job)and position=2),'replacement does not reset quality or admission counters');
create temporary table replacement_paid as select pg_temp.accepted_only((select c from replacement_claim))c;
create temporary table replacement_poll as select pg_temp.target_poll((select(j).id from missing_job),2)c;
select pg_temp.ok(property_video_job_result_missing((select(j).id from missing_job),(select(c#>>'{source,lease_token}')::uuid from replacement_poll),(select(c#>>'{source,attempt_id}')::uuid from replacement_poll)),'missing replacement stops failed instead of polling forever');
select pg_temp.ok(not pg_temp.available(),'second paid missing clip cannot receive another replacement');
select pg_temp.refuse(format('select property_video_job_resume(%L,%L,.0001)',(select actor from bf),(select(j).id from missing_job)),'RP409','one explicit replacement cannot repeat after second paid missing clip');
select json_build_object('passed',true,'assertions',(select n from checks),'supplierPOSTs',0);rollback;
