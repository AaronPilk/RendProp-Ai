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
 perform public.property_video_job_receipt(j.id,src.attempt_id,jsonb_build_object('request_id',request,'model_id','fixture-model'));
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
set local role service_role;
-- BEGIN CASE
create temporary table retry_case as select pg_temp.cpu_job(700)c;grant select on retry_case to service_role;select pg_temp.retry_grant((select c from retry_case));
-- END CASE
reset role;
create function pg_temp.evidence()returns jsonb language plpgsql security definer as $$begin return public.property_video_quality_retry_evidence((select(c#>>'{job,id}')::uuid from retry_case),(select(c#>>'{source,attempt_id}')::uuid from retry_case));end$$;
create function pg_temp.no_grant_change(command text,label text,expect_null boolean default true)returns void language plpgsql as $$declare denied boolean;begin
 begin execute'set local session_replication_role=replica';execute command;execute'set local session_replication_role=origin';execute'set local role service_role';denied:=pg_temp.evidence()is null;execute'reset role';raise exception using errcode='PZ001',message='rollback closed fixture mutation';exception when sqlstate'PZ001'then null;end;
 perform pg_temp.ok(denied is not distinct from expect_null,label);end$$;
set local role service_role;
select pg_temp.ok(pg_temp.evidence()is not null,'strict failed axes authorize raw-pass terminal retry');
reset role;
select pg_temp.no_grant_change($q$update media_provenance set qc=jsonb_set(qc,'{verdict}','"fail"')where id=(select(c#>>'{source,generation_provenance_id}')::uuid from retry_case);update app_video_drift_checks set result=jsonb_set(result,'{drift,verdict}','"fail"')where listing_id=(select listing from bf);update cost_ledger set meta=jsonb_set(meta,'{verdict}','"fail"')where feature='qc'and meta->>'request_id'=(select c#>>'{source,receipt,request_id}'from retry_case)$q$,'existing fail summary retry remains supported',false);
select pg_temp.no_grant_change($q$update media_provenance set qc=jsonb_set(qc,'{verdict}','"regen"')where id=(select(c#>>'{source,generation_provenance_id}')::uuid from retry_case);update app_video_drift_checks set result=jsonb_set(result,'{drift,verdict}','"regen"')where listing_id=(select listing from bf);update cost_ledger set meta=jsonb_set(meta,'{verdict}','"regen"')where feature='qc'and meta->>'request_id'=(select c#>>'{source,receipt,request_id}'from retry_case)$q$,'existing regen summary retry remains supported',false);

-- Every mutation is rolled back locally before the next independent oracle.
select pg_temp.no_grant_change($q$update media_provenance set qc=jsonb_set(qc,'{verdict}','"unknown"')where id=(select(c#>>'{source,generation_provenance_id}')::uuid from retry_case)$q$,'unknown summary cannot authorize retry');
select pg_temp.no_grant_change($q$update media_provenance set qc=qc-'verdict'where id=(select(c#>>'{source,generation_provenance_id}')::uuid from retry_case)$q$,'incomplete summary cannot authorize retry');
select pg_temp.no_grant_change($q$update media_provenance set qc=jsonb_set(qc,'{action}','"hold"')where id=(select(c#>>'{source,generation_provenance_id}')::uuid from retry_case)$q$,'manual hold cannot authorize retry');
select pg_temp.no_grant_change($q$update media_provenance set qc=jsonb_set(qc,'{publishable}','true')where id=(select(c#>>'{source,generation_provenance_id}')::uuid from retry_case)$q$,'publishable pass cannot authorize retry');
select pg_temp.no_grant_change($q$update media_provenance set qc=jsonb_set(qc,'{failed}','[]')where id=(select(c#>>'{source,generation_provenance_id}')::uuid from retry_case)$q$,'empty failed axes cannot authorize retry');
select pg_temp.no_grant_change($q$update media_provenance set qc=jsonb_set(qc,'{failed}','["architecture"]')where id=(select(c#>>'{source,generation_provenance_id}')::uuid from retry_case)$q$,'forged failed axes cannot replace canonical decision');
select pg_temp.no_grant_change($q$update media_provenance set qc=jsonb_set(qc,'{source_sha256}',to_jsonb(repeat('f',32)))where id=(select(c#>>'{source,generation_provenance_id}')::uuid from retry_case)$q$,'wrong source cannot authorize retry');
select pg_temp.no_grant_change($q$update media_provenance set qc=jsonb_set(qc,'{attempt}','1')where id=(select(c#>>'{source,generation_provenance_id}')::uuid from retry_case)$q$,'later attempt cannot authorize retry');
select pg_temp.no_grant_change($q$update media_provenance set qc=qc-'scores'where id=(select(c#>>'{source,generation_provenance_id}')::uuid from retry_case)$q$,'raw-pass missing scores cannot authorize retry');
select pg_temp.no_grant_change($q$update media_provenance set qc=jsonb_set(qc,'{scores,additions}','100')where id=(select(c#>>'{source,generation_provenance_id}')::uuid from retry_case)$q$,'raw-pass mismatched scores cannot authorize retry');
select pg_temp.no_grant_change($q$update app_video_drift_checks set state='hold'where listing_id=(select listing from bf)$q$,'nonterminal journal cannot authorize retry');
select pg_temp.no_grant_change($q$update app_video_drift_checks set result=jsonb_set(result,'{drift,status}','"pass"')where listing_id=(select listing from bf)$q$,'journal status pass cannot authorize retry');
select pg_temp.no_grant_change($q$update app_video_drift_checks set result=jsonb_set(result,'{drift,verdict}','"fail"')where listing_id=(select listing from bf)$q$,'journal summary mismatch cannot authorize retry');
select pg_temp.no_grant_change($q$delete from app_video_drift_checks where listing_id=(select listing from bf)$q$,'missing terminal journal cannot authorize retry');
select pg_temp.no_grant_change($q$update app_video_cost_reservations set model='wrong-model'where idempotency_key=(select c#>>'{source,request_key}'from retry_case)$q$,'wrong paid model cannot authorize retry');
select pg_temp.no_grant_change($q$update app_video_cost_reservations set settled_at=null,cost_ledger_id=null,provider_request_id=null where idempotency_key=(select c#>>'{source,request_key}'from retry_case)$q$,'unsettled generation cannot authorize retry');
select pg_temp.no_grant_change($q$update cost_ledger set total_cents=0 where feature='reel'and meta->>'request_key'=(select c#>>'{source,request_key}'from retry_case)$q$,'missing paid generation charge cannot authorize retry');
select pg_temp.no_grant_change($q$delete from cost_ledger where feature='qc'and meta->>'request_id'=(select c#>>'{source,receipt,request_id}'from retry_case)$q$,'missing paid QC charge cannot authorize retry');
select pg_temp.no_grant_change($q$update cost_ledger set meta=jsonb_set(meta,'{scores,artifacts}','99')where feature='qc'and meta->>'request_id'=(select c#>>'{source,receipt,request_id}'from retry_case)$q$,'paid QC score mismatch cannot authorize retry');
set local role service_role;
select pg_temp.refuse($q$select property_video_job_quality_retry((select(c#>>'{job,id}')::uuid from retry_case),gen_random_uuid(),(select(c#>>'{source,attempt_id}')::uuid from retry_case))$q$,'RP409:','wrong lease cannot consume retry');
select pg_temp.refuse($q$select property_video_job_scope((select(c#>>'{job,id}')::uuid from retry_case),(select other from bf),false)$q$,'RP404:','foreign actor cannot access paid retry job');
create temporary table retained as select to_jsonb(s)prior,(select deadline from property_video_jobs where id=s.job_id)deadline from property_video_job_sources s where job_id=(select(c#>>'{job,id}')::uuid from retry_case)and position=0;grant select on retained to service_role;
select pg_temp.ok((property_video_job_quality_retry((select(c#>>'{job,id}')::uuid from retry_case),(select(c#>>'{source,lease_token}')::uuid from retry_case),(select(c#>>'{source,attempt_id}')::uuid from retry_case))->>'retry_scheduled')='true','raw-pass strict failure schedules one normal paid retry');
select pg_temp.ok((select quality_retries=1 and jsonb_array_length(quality_retry_history)=1 and quality_retry_history#>'{0,prior_source,clip}'=(select prior->'clip'from retained)and quality_retry_history#>'{0,prior_source,receipt}'=(select prior->'receipt'from retained)and quality_retry_history#>>'{0,quality_grant,verdict,verdict}'='pass'and state='pending'and motion='push_in'from property_video_job_sources where job_id=(select(c#>>'{job,id}')::uuid from retry_case)and position=0),'retry archives exact paid source and raw verdict without approving it');
select pg_temp.ok((property_video_job_quality_retry((select(c#>>'{job,id}')::uuid from retry_case),(select(c#>>'{source,lease_token}')::uuid from retry_case),(select(c#>>'{source,attempt_id}')::uuid from retry_case))->>'replay')='true','lost acknowledgment replays same single transition');
select pg_temp.ok((select count(*)=1 from app_video_cost_reservations where idempotency_key=(select c#>>'{source,request_key}'from retry_case))and(select count(*)=0 from property_video_job_outputs where job_id=(select(c#>>'{job,id}')::uuid from retry_case)),'retry scheduling creates no provider charge or output');
select pg_temp.refuse($q$update property_video_job_sources set quality_retries=0 where job_id=(select(c#>>'{job,id}')::uuid from retry_case)and position=0$q$,'RP409:','retry cannot reset history or create third attempt');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_quality_retry_evidence(uuid,uuid)','execute')and not has_function_privilege('anon','public.property_video_job_quality_retry(uuid,uuid,uuid)','execute'),'retry evidence remains service-only');

-- Reproduce the exact stopped callback shape with unrelated ready, accepted
-- processing and pending work, using genuine fixture paid/source/QC RPCs.
reset role;
create function pg_temp.paid_receipt(c jsonb)returns jsonb language plpgsql as $$declare j public.property_video_jobs;src public.property_video_job_sources;rid uuid:=gen_random_uuid();lid uuid:=gen_random_uuid();request text;prov public.media_provenance;claim jsonb;begin
 select * into j from public.property_video_jobs where id=(c#>>'{job,id}')::uuid;select * into src from public.property_video_job_sources where job_id=j.id and attempt_id=(c#>>'{source,attempt_id}')::uuid;
 request:='fixture-provider:'||src.attempt_id;
 insert into public.app_video_cost_reservations(id,actor_id,org_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents,meta)values(rid,j.actor_id,j.org_id,src.request_key,'reel','fal','fixture-model',src.source->>'sha256',1,.0001,.0001,.0001,'{"task":"video.reel_clip"}');
 insert into public.cost_ledger(id,org_id,feature,provider,model,total_cents,meta)values(lid,j.org_id,'reel','fal','fixture-model',.0001,jsonb_build_object('app_video_reservation_id',rid,'request_id',request,'request_key',src.request_key,'stage','reel'));
 update public.app_video_cost_reservations set provider_request_id=request,cost_ledger_id=lid,settled_at=now()where id=rid;
 insert into public.app_video_allowance_receipts(reservation_id,listing_id,monthly_key,monthly_window_start,burst_key,burst_window_start)values(rid,j.listing_id,'fixture-month',now(),'fixture-burst',now());
 perform public.property_video_job_receipt(j.id,src.attempt_id,jsonb_build_object('request_id',request,'model_id','fixture-model'));
 return jsonb_build_object('job',to_jsonb(j),'source',(select to_jsonb(x)from public.property_video_job_sources x where job_id=j.id and attempt_id=src.attempt_id));end$$;

create function pg_temp.accept_clip(c jsonb)returns void language plpgsql as $$declare s public.property_video_job_sources;j public.property_video_jobs;v jsonb;begin
 select *into s from property_video_job_sources where job_id=(c#>>'{job,id}')::uuid and attempt_id=(c#>>'{source,attempt_id}')::uuid;select *into j from property_video_jobs where id=s.job_id;
 v:=jsonb_build_object('task','judge.qc_drift','request_id',s.receipt->>'request_id','source_sha256',repeat('d',32),'verdict','pass','action','accept','publishable',true,'failed','[]'::jsonb,'attempt',0);
 update media_provenance set qc=v where id=s.generation_provenance_id;insert into cost_ledger(org_id,feature,provider,model,total_cents,meta)values(j.org_id,'qc','anthropic','fixture-judge',.0001,v);
 perform public.property_video_job_qc(j.id,s.lease_token,s.attempt_id);end$$;
set local role service_role;
create temporary table stopped_job as select(property_video_job_enqueue((select actor from bf),jsonb_set(jsonb_set((select m from bm),'{operation_id}','"f3700000-0000-4000-8000-000000000701"'),'{sources}',(select jsonb_agg(value)from jsonb_array_elements((select m->'sources'from bm))with ordinality x(value,n)where n<=4)))).*;grant select on stopped_job to service_role;
create temporary table stopped_ready as select pg_temp.paid_clip(property_video_job_claim((select id from stopped_job),'slot-0'))c;select pg_temp.accept_clip((select c from stopped_ready));
truncate retry_case;insert into retry_case select pg_temp.paid_clip(property_video_job_claim((select id from stopped_job),'slot-0'));select pg_temp.retry_grant((select c from retry_case));
create temporary table stopped_processing as select pg_temp.paid_receipt(property_video_job_claim((select id from stopped_job),'slot-0'))c;
reset role;update property_video_job_sources set cpu_attempts=3,lease_until=now()-interval'1 second'where job_id=(select id from stopped_job)and position=1;update property_video_jobs set state='failed'where id=(select id from stopped_job);
create temporary table untouched as select jsonb_agg(to_jsonb(s)order by position)rows from property_video_job_sources s where job_id=(select id from stopped_job)and position<>1;grant select on untouched to service_role;
create temporary table stopped_identity as select manifest_sha256,manifest,operation_id,deadline,(select count(*)from app_video_cost_reservations)reservations,(select count(*)from cost_ledger)ledgers from property_video_jobs where id=(select id from stopped_job);grant select on stopped_identity to service_role;
create function pg_temp.refused_resume_change(command text,label text)returns void language plpgsql as $$declare denied boolean:=false;begin
 begin
  execute'set local session_replication_role=replica';execute command;execute'set local session_replication_role=origin';execute'set local role service_role';
  begin if public.property_video_job_quality_resume_available((select id from stopped_job))then raise exception'Closed projection incorrectly allowed recovery';end if;perform public.property_video_job_resume((select actor from bf),(select id from stopped_job),0);exception when others then if sqlerrm like'RP409:%'then denied:=true;else raise;end if;end;
  execute'reset role';raise exception using errcode='PZ002',message='rollback closed recovery fixture';
 exception when sqlstate'PZ002'then null;end;perform pg_temp.ok(denied,label);end$$;
select pg_temp.refused_resume_change($q$update property_video_job_sources set lease_until=now()+interval'5 minutes'where job_id=(select id from stopped_job)and position=1$q$,'active quality lease cannot be recovered');
select pg_temp.refused_resume_change($q$update media_provenance set qc=jsonb_set(qc,'{verdict}','"unknown"')where id=(select(c#>>'{source,generation_provenance_id}')::uuid from retry_case)$q$,'unknown stopped QC cannot be recovered');
select pg_temp.refused_resume_change($q$update media_provenance set qc=jsonb_set(qc,'{action}','"hold"')where id=(select(c#>>'{source,generation_provenance_id}')::uuid from retry_case)$q$,'held stopped QC cannot be recovered');
select pg_temp.refused_resume_change($q$update app_video_cost_reservations set settled_at=null,cost_ledger_id=null,provider_request_id=null where idempotency_key=(select c#>>'{source,request_key}'from retry_case)$q$,'unpaid stopped clip cannot be recovered');
select pg_temp.refused_resume_change($q$update property_video_job_sources set source=jsonb_set(source,'{sha256}',to_jsonb(repeat('f',64)))where job_id=(select id from stopped_job)and position=1$q$,'changed source identity cannot be recovered');
set local role service_role;
select pg_temp.ok(public.property_video_job_quality_resume_available((select id from stopped_job)),'terminal stopped quality projection permits existing button');
select pg_temp.ok((property_video_job_resume((select actor from bf),(select id from stopped_job),0)).state='generating','explicit owner resume consumes expired terminal retry without rejudge');
select pg_temp.ok((select state='pending'and quality_retries=1 and jsonb_array_length(quality_retry_history)=1 and quality_retry_history#>>'{0,prior_source,attempt_id}'=(select c#>>'{source,attempt_id}'from retry_case)and quality_retry_history#>>'{0,prior_source,cpu_attempts}'='3'and quality_retry_history#>>'{0,quality_grant,verdict,verdict}'='pass'from property_video_job_sources where job_id=(select id from stopped_job)and position=1),'expired review retains paid verdict and exhausted callback history');
select pg_temp.ok((select jsonb_agg(to_jsonb(s)order by position)=(select rows from untouched)from property_video_job_sources s where job_id=(select id from stopped_job)and position<>1),'resume preserves ready processing and pending sources exactly');
select pg_temp.ok((select j.manifest_sha256=i.manifest_sha256 and j.manifest=i.manifest and j.operation_id=i.operation_id and j.deadline=i.deadline from property_video_jobs j,stopped_identity i where j.id=(select id from stopped_job)),'resume preserves operation manifest and deadline');
select pg_temp.ok((select count(*)=(select reservations from stopped_identity)from app_video_cost_reservations)and(select count(*)=(select ledgers from stopped_identity)from cost_ledger),'resume makes no provider reservation or QC charge');
select pg_temp.ok((property_video_job_resume((select actor from bf),(select id from stopped_job),0)).state='generating'and(select quality_retries=1 from property_video_job_sources where job_id=(select id from stopped_job)and position=1),'lost owner resume reply is idempotent');
select pg_temp.ok((property_video_job_quality_retry((select id from stopped_job),(select(c#>>'{source,lease_token}')::uuid from retry_case),(select(c#>>'{source,attempt_id}')::uuid from retry_case))->>'replay')='true','old callback acknowledgment replays after explicit resume');
select pg_temp.ok(not public.property_video_job_quality_resume_available((select id from stopped_job)),'resumed work has no second quality-resume grant');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_job_quality_resume_available(uuid)','execute')and not has_function_privilege('anon','public.property_video_job_quality_resume_available(uuid)','execute'),'quality resume projection remains service-only');


-- Both slots can independently have a retained terminal retry when an old
-- worker stops. Recover the set atomically, not just its first position.
create temporary table multi0 as select pg_temp.cpu_job(702)c;select pg_temp.retry_grant((select c from multi0));
create temporary table multi1 as select pg_temp.paid_clip(property_video_job_claim((select(c#>>'{job,id}')::uuid from multi0),'slot-0'))c;select pg_temp.retry_grant((select c from multi1));
reset role;update property_video_job_sources set cpu_attempts=3,lease_until=now()-interval'1 second'where job_id=(select(c#>>'{job,id}')::uuid from multi0);update property_video_jobs set state='failed'where id=(select(c#>>'{job,id}')::uuid from multi0);
create temporary table multi_identity as select(select count(*)from app_video_cost_reservations)reservations,(select count(*)from cost_ledger)ledgers;grant select on multi_identity,multi0,multi1 to service_role;
-- MULTI RECOVERY READY
set local role service_role;
select pg_temp.ok(public.property_video_job_quality_resume_available((select(c#>>'{job,id}')::uuid from multi0)),'two terminal reviews expose one existing Resume action');
select pg_temp.ok((property_video_job_resume((select actor from bf),(select(c#>>'{job,id}')::uuid from multi0),0)).state='generating','two expired terminal reviews recover atomically');
select pg_temp.ok((select count(*)=2 and bool_and(state='pending'and quality_retries=1 and jsonb_array_length(quality_retry_history)=1 and quality_retry_history#>>'{0,prior_source,cpu_attempts}'='3'and quality_retry_history#>>'{0,quality_grant,verdict,verdict}'='pass')from property_video_job_sources where job_id=(select(c#>>'{job,id}')::uuid from multi0)),'both paid grants retained exactly once');
select pg_temp.ok((select count(*)=(select reservations from multi_identity)from app_video_cost_reservations)and(select count(*)=(select ledgers from multi_identity)from cost_ledger),'multi-source recovery creates no paid dispatch or judge charge');
select pg_temp.ok((property_video_job_resume((select actor from bf),(select(c#>>'{job,id}')::uuid from multi0),0)).state='generating'and(select bool_and(quality_retries=1 and jsonb_array_length(quality_retry_history)=1)from property_video_job_sources where job_id=(select(c#>>'{job,id}')::uuid from multi0)),'multi-source lost resume reply preserves single retries');

reset role;select jsonb_build_object('passed',true,'assertions',n)from checks;
rollback;
