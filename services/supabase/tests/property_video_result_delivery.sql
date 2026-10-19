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
-- BEGIN DELIVERY FIXTURE
set local role service_role;
create temporary table delivery_job as select property_video_job_enqueue((select actor from bf),jsonb_set(jsonb_set((select m from bm),'{operation_id}','"f3700000-0000-4000-8000-000000008000"'),'{sources}',(select jsonb_agg(x)from jsonb_array_elements((select m->'sources'from bm))with ordinality e(x,n)where n<=4)))j;
create temporary table ready_case as select pg_temp.paid_clip(property_video_job_claim((select(j).id from delivery_job),'slot-0'))c;select pg_temp.accept_qc((select c from ready_case));
create temporary table retry_case as select pg_temp.paid_clip(property_video_job_claim((select(j).id from delivery_job),'slot-0'))c;select pg_temp.retry_grant((select c from retry_case));select property_video_job_quality_retry((select(j).id from delivery_job),(select(c#>>'{source,lease_token}')::uuid from retry_case),(select(c#>>'{source,attempt_id}')::uuid from retry_case));
create temporary table processing_case as select pg_temp.accepted_only(property_video_job_claim((select(j).id from delivery_job),'slot-0'))c;
create temporary table failed_case as select pg_temp.accepted_only(property_video_job_claim((select(j).id from delivery_job),'slot-0'))c;select property_video_job_failure((select(j).id from delivery_job),(select(c#>>'{source,lease_token}')::uuid from failed_case),(select(c#>>'{source,attempt_id}')::uuid from failed_case),'provider_generation_failed',false);
-- END DELIVERY FIXTURE
reset role;
create temporary table snapshot as select (select to_jsonb(j)from property_video_jobs j where id=(select(j).id from delivery_job))j,(select jsonb_agg(to_jsonb(s)order by position)from property_video_job_sources s where job_id=(select(j).id from delivery_job)and position<>2)siblings,(select count(*)from cost_ledger)ledgers,(select count(*)from app_video_cost_reservations)reservations;
grant select on delivery_job,ready_case,retry_case,processing_case,failed_case,snapshot to service_role,authenticated;
create function pg_temp.available()returns boolean language plpgsql security definer as $$begin return public.property_video_delivery_resume_available((select(j).id from delivery_job));end$$;
create function pg_temp.deny_change(command text,label text)returns void language plpgsql as $$declare denied boolean;begin
 begin execute'set local session_replication_role=replica';execute command;execute'set local session_replication_role=origin';execute'set local role service_role';denied:=not pg_temp.available();execute'reset role';raise exception using errcode='PZ001',message='rollback synthetic mutation';exception when sqlstate'PZ001'then null;end;perform pg_temp.ok(denied,label);end$$;
set local role service_role;
select pg_temp.ok(pg_temp.available(),'exact historical completed-result failure has bounded same-receipt recovery');
select pg_temp.ok((select quality_retries=1 and jsonb_array_length(quality_retry_history)=1 from property_video_job_sources where job_id=(select(j).id from delivery_job)and position=1),'sibling quality retry stays established');
reset role;
select pg_temp.deny_change($q$update property_video_job_sources set receipt=jsonb_set(receipt,'{request_id}','"foreign"')where job_id=(select(j).id from delivery_job)and position=2$q$,'wrong provider request cannot recover');
select pg_temp.deny_change($q$update property_video_job_sources set receipt=null where job_id=(select(j).id from delivery_job)and position=2$q$,'unknown acceptance cannot recover');
select pg_temp.deny_change($q$update property_video_job_sources set receipt=jsonb_set(receipt,'{model_id}','"foreign"')where job_id=(select(j).id from delivery_job)and position=2$q$,'wrong model cannot recover');
select pg_temp.deny_change($q$update app_video_cost_reservations set released_at=now(),cost_ledger_id=null,provider_request_id=null,settled_at=null,rejection_status=403,rejection_error_class='upstream'where idempotency_key=(select c#>>'{source,request_key}'from failed_case)$q$,'released known-zero-cost cannot authorize a paid delivery recovery');
select pg_temp.deny_change($q$update app_video_cost_reservations set cost_ledger_id=null,provider_request_id=null,settled_at=null where idempotency_key=(select c#>>'{source,request_key}'from failed_case)$q$,'unsettled receipt cannot recover');
select pg_temp.deny_change($q$update cost_ledger set meta=meta-'request_id'where id=(select cost_ledger_id from app_video_cost_reservations where idempotency_key=(select c#>>'{source,request_key}'from failed_case))$q$,'wrong financial lineage cannot recover');
select pg_temp.deny_change($q$update media_provenance set model_id='foreign'where id=(select(c#>>'{source,generation_provenance_id}')::uuid from failed_case)$q$,'wrong provenance cannot recover');
select pg_temp.deny_change($q$update capture_assets set uploaded=false where id=(select(c#>>'{source,asset_id}')::uuid from failed_case)$q$,'deleted source cannot recover');
select pg_temp.deny_change($q$update property_video_job_sources set state='ambiguous'where job_id=(select(j).id from delivery_job)and position=2$q$,'ambiguous acceptance cannot recover');
select pg_temp.deny_change($q$update property_video_job_sources set last_error='provider_safety_refused'where job_id=(select(j).id from delivery_job)and position=2$q$,'content safety refusal cannot recover');
select pg_temp.deny_change($q$update property_video_job_sources set last_error='provider_terminal_failed'where job_id=(select(j).id from delivery_job)and position=2$q$,'explicit supplier generation failure cannot recover');
select pg_temp.deny_change($q$update property_video_job_sources set lease_until=now()+interval'5 minutes'where job_id=(select(j).id from delivery_job)and position=2$q$,'active lease cannot be recovered');
set local role service_role;
select pg_temp.refuse(format('select property_video_job_resume(%L,%L,0)',(select other from bf),(select(j).id from delivery_job)),'RP404','foreign actor cannot resume saved result');
select pg_temp.ok((property_video_job_resume((select actor from bf),(select(j).id from delivery_job),0)).state='generating','explicit owner resume re-polls same paid receipt');
select pg_temp.ok(not pg_temp.available(),'successful recovery projection closes until another bounded pause');
select pg_temp.ok((select delivery_recoveries=1 and jsonb_array_length(delivery_recovery_history)=1 and state='processing'and attempt_id=(select(c#>>'{source,attempt_id}')::uuid from failed_case)and request_key=(select c#>>'{source,request_key}'from failed_case)and receipt=(select c#>'{source,receipt}'from failed_case)and clip is null from property_video_job_sources where job_id=(select(j).id from delivery_job)and position=2),'recovery preserves exact attempt request receipt and does not fabricate a clip');
select pg_temp.ok((select jsonb_agg(to_jsonb(s)order by position)from property_video_job_sources s where job_id=(select(j).id from delivery_job)and position<>2)=(select siblings from snapshot),'ready processing and pending siblings byte unchanged');
select pg_temp.ok((select manifest_sha256=(select j->>'manifest_sha256'from snapshot)and operation_id=(select(j->>'operation_id')::uuid from snapshot)and deadline=(select(j->>'deadline')::timestamptz from snapshot)from property_video_jobs where id=(select(j).id from delivery_job)),'original operation manifest deadline unchanged');
select pg_temp.ok((property_video_job_resume((select actor from bf),(select(j).id from delivery_job),0)).state='generating','lost response replay acknowledges existing job');
select pg_temp.ok((select delivery_recoveries=1 from property_video_job_sources where job_id=(select(j).id from delivery_job)and position=2),'lost response never increments recovery twice');
-- Each current lease can be counted only once, even when the callback reply is lost.
create temporary table read_case as select pg_temp.target_poll((select(j).id from delivery_job),2)c;grant select on read_case to service_role;
select pg_temp.ok(property_video_job_result_read_failure((select(j).id from delivery_job),(select(c#>>'{source,lease_token}')::uuid from read_case),(select(c#>>'{source,attempt_id}')::uuid from read_case),'unknown'),'first exact result read failure saved');
select pg_temp.ok(property_video_job_result_read_failure((select(j).id from delivery_job),(select(c#>>'{source,lease_token}')::uuid from read_case),(select(c#>>'{source,attempt_id}')::uuid from read_case),'unknown'),'same callback replay acknowledged');
select pg_temp.ok((select result_read_failures=1 and provider_terminal_at is not null from property_video_job_sources where job_id=(select(j).id from delivery_job)and position=2),'one read counter and terminal vendor work recorded');
select pg_temp.refuse(format('select property_video_job_result_read_failure(%L,%L,%L,%L)',(select(j).id from delivery_job),(select(c#>>'{source,lease_token}')::uuid from read_case),(select(c#>>'{source,attempt_id}')::uuid from read_case),'permission'),'RP409','conflicting callback cannot rewrite cause');
select pg_temp.refuse(format('select property_video_job_result_read_failure(%L,%L,%L,%L)',(select(j).id from delivery_job),gen_random_uuid(),(select(c#>>'{source,attempt_id}')::uuid from read_case),'unknown'),'RP409','stale lease cannot consume another read');
select pg_temp.refuse(format('select property_video_job_result_read_failure(%L,%L,%L,%L)',(select(j).id from delivery_job),gen_random_uuid(),(select(c#>>'{source,attempt_id}')::uuid from read_case),'content_policy'),'RP400','safety reason cannot enter delivery recovery');
do $$declare c jsonb;begin for cycle in 1..3 loop
 for n in case when cycle=1 then 2 else 1 end..3 loop c:=pg_temp.target_poll((select(j).id from delivery_job),2);perform property_video_job_result_read_failure((select(j).id from delivery_job),(c#>>'{source,lease_token}')::uuid,(c#>>'{source,attempt_id}')::uuid,'balance_exhausted');end loop;
 perform pg_temp.ok((select state='failed'from property_video_jobs where id=(select(j).id from delivery_job)),'third read pauses without new paid request');
 if cycle<3 then perform pg_temp.ok(pg_temp.available(),'bounded explicit delivery recovery remains available');perform property_video_job_resume((select actor from bf),(select(j).id from delivery_job),0);else perform pg_temp.ok(not pg_temp.available(),'three explicit recovery cycles are finite');end if;end loop;end$$;
select pg_temp.ok((select delivery_recoveries=3 and result_read_failures=3 and jsonb_array_length(delivery_recovery_history)=3 and receipt=(select c#>'{source,receipt}'from failed_case)from property_video_job_sources where job_id=(select(j).id from delivery_job)and position=2),'bounded audited history retains exact accepted receipt');
select pg_temp.ok((select count(*)from cost_ledger)=(select ledgers from snapshot)and(select count(*)from app_video_cost_reservations)=(select reservations from snapshot),'all delivery reads and resumes create no charge reservation or refund');
select pg_temp.refuse(format('update property_video_job_sources set delivery_recoveries=0 where job_id=%L and position=2',(select(j).id from delivery_job)),'RP409','delivery recovery budget cannot be reset');
select pg_temp.refuse(format('update property_video_job_sources set delivery_recovery_history=%L where job_id=%L and position=2','[]',(select(j).id from delivery_job)),'RP409','audited delivery history cannot be deleted');
reset role;
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_job_result_read_failure(uuid,uuid,uuid,text)','execute')and not has_function_privilege('authenticated','public.property_video_delivery_resume_available(uuid)','execute'),'new delivery authority service only');
select jsonb_build_object('passed',true,'assertions',(select n from checks),'supplierPOSTs',0,'paidQCcalls',0,'noNewPaidGeneration',true);rollback;
