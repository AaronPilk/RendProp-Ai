-- The driver supplies the existing owned-photo/account fixture in one transaction.
create temporary table checks(n integer);insert into checks values(0);grant all on checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'FAILED-SLOT FAIL: %',label;end if;update checks set n=n+1;end$$;
create function pg_temp.refuse(command text,needle text,label text)returns void language plpgsql as $$begin begin execute command;exception when others then if position(needle in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception'FAILED-SLOT FAIL: allowed %',label;end$$;
create function pg_temp.enqueue_case(i integer)returns uuid language plpgsql as $$declare j public.property_video_jobs;m jsonb;begin
 select jsonb_set(jsonb_set(jsonb_set(bm.m,'{operation_id}',to_jsonb(('f3700000-0000-4000-8000-'||lpad(i::text,12,'0'))::text)),'{sources}',jsonb_build_array(bm.m#>'{sources,0}',bm.m#>'{sources,1}')),'{presentation,shot_labels}','[null,null]')into m from bm;
 j:=public.property_video_job_enqueue((select actor from bf),m);return j.id;end$$;
-- Closed provider acceptance fixture, using the actual claim and receipt RPCs.
-- The reservation is an unsettled liability, not a generated clip or paid-call proof.
create function pg_temp.failed_case(i integer)returns jsonb language plpgsql as $$declare jid uuid;c jsonb;r uuid:=gen_random_uuid();begin
 jid:=pg_temp.enqueue_case(i);c:=public.property_video_job_claim(jid,'slot-0');
 if c->>'action'<>'dispatch'then raise exception'FAILED-SLOT FAIL: initial admission unavailable';end if;
 insert into public.app_video_cost_reservations(id,actor_id,org_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents,meta)
 values(r,(select actor from bf),(select org from bf),c#>>'{source,request_key}','reel','fal','fixture-model',repeat('a',64),5,4.86,24.3,24.3,'{"task":"video.reel_clip"}');
 perform public.property_video_job_receipt(jid,(c#>>'{source,attempt_id}')::uuid,jsonb_build_object('request_id','fixture-accepted:'||i,'model_id','fixture-model','status_url','https://private.invalid/status?job=opaque'));
 update public.property_video_jobs set state='failed',message='The other source failed its native pixel gate.'where id=jid;
 update public.property_video_job_sources set state='failed',last_error='source_quality_below_1080'where job_id=jid and position=1;
 return c||jsonb_build_object('reservation_id',r,'request_id','fixture-accepted:'||i);end$$;
reset role;update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';set local role service_role;
create temporary table failed_cases as select i,pg_temp.failed_case(i)c from generate_series(1,4)i;grant select on failed_cases to service_role;
create temporary table waiting_job as select pg_temp.enqueue_case(5)id;grant select on waiting_job to service_role;
select pg_temp.ok((select count(*)=4 from property_video_job_sources where state='processing'and provider_terminal_at is null),'four failed recipes retain four accepted pending slots');
select pg_temp.ok(property_video_job_claim((select id from waiting_job),'slot-0')->>'action'='wait','failed pending receipts block fifth dispatch before provider terminal');
create temporary table before_liability as select to_jsonb(r)r from app_video_cost_reservations r;grant select on before_liability to service_role;
create temporary table before_sources as select job_id,position,receipt,request_key,attempt_id,quality_retry_history from property_video_job_sources where job_id in(select(c#>>'{job,id}')::uuid from failed_cases);grant select on before_sources to service_role;
select pg_temp.ok(jsonb_array_length(property_video_cancelled_attempts())=4,'failed known paid receipts enter metadata reconciliation');
select pg_temp.ok(jsonb_array_length(property_video_cancelled_attempts())=0,'failed receipt reconciliation retains thirty second throttle');
select pg_temp.ok((select count(*)=4 from property_video_job_sources where state='processing'and provider_terminal_at is null),'merely checking failed receipts does not release capacity');
select pg_temp.refuse($q$select property_video_cancelled_terminal((select(c#>>'{job,id}')::uuid from failed_cases where i=1),(select(c#>>'{source,attempt_id}')::uuid from failed_cases where i=1),'foreign-request','fal','fixture-model')$q$,'RP409:','foreign request cannot free failed slot');
select pg_temp.refuse($q$select property_video_cancelled_terminal((select(c#>>'{job,id}')::uuid from failed_cases where i=1),(select(c#>>'{source,attempt_id}')::uuid from failed_cases where i=2),'fixture-accepted:1','fal','fixture-model')$q$,'RP409:','foreign attempt cannot free failed slot');
select pg_temp.refuse($q$select property_video_cancelled_terminal((select(c#>>'{job,id}')::uuid from failed_cases where i=1),(select(c#>>'{source,attempt_id}')::uuid from failed_cases where i=1),'fixture-accepted:1','kie','fixture-model')$q$,'RP409:','foreign provider cannot free failed slot');
select pg_temp.refuse($q$select property_video_cancelled_terminal((select(c#>>'{job,id}')::uuid from failed_cases where i=1),(select(c#>>'{source,attempt_id}')::uuid from failed_cases where i=1),'fixture-accepted:1','fal','foreign-model')$q$,'RP409:','foreign model cannot free failed slot');
-- A missing reservation or mismatched actor/library cannot attest paid acceptance.
reset role;set local session_replication_role=replica;update app_video_cost_reservations set idempotency_key='missing-matching-fixture'where id=(select(c->>'reservation_id')::uuid from failed_cases where i=1);set local session_replication_role=origin;set local role service_role;
select pg_temp.refuse($q$select property_video_cancelled_terminal((select(c#>>'{job,id}')::uuid from failed_cases where i=1),(select(c#>>'{source,attempt_id}')::uuid from failed_cases where i=1),'fixture-accepted:1','fal','fixture-model')$q$,'RP409:','missing active paid reservation cannot free failed slot');
reset role;set local session_replication_role=replica;update app_video_cost_reservations set idempotency_key=(select c#>>'{source,request_key}'from failed_cases where i=1),actor_id=(select other from bf)where id=(select(c->>'reservation_id')::uuid from failed_cases where i=1);set local session_replication_role=origin;set local role service_role;
select pg_temp.refuse($q$select property_video_cancelled_terminal((select(c#>>'{job,id}')::uuid from failed_cases where i=1),(select(c#>>'{source,attempt_id}')::uuid from failed_cases where i=1),'fixture-accepted:1','fal','fixture-model')$q$,'RP409:','foreign actor paid reservation cannot free failed slot');
reset role;set local session_replication_role=replica;update app_video_cost_reservations set actor_id=(select actor from bf),org_id=(select other_org from bf)where id=(select(c->>'reservation_id')::uuid from failed_cases where i=1);set local session_replication_role=origin;set local role service_role;
select pg_temp.refuse($q$select property_video_cancelled_terminal((select(c#>>'{job,id}')::uuid from failed_cases where i=1),(select(c#>>'{source,attempt_id}')::uuid from failed_cases where i=1),'fixture-accepted:1','fal','fixture-model')$q$,'RP409:','foreign library paid reservation cannot free failed slot');
reset role;set local session_replication_role=replica;update app_video_cost_reservations set org_id=(select org from bf)where id=(select(c->>'reservation_id')::uuid from failed_cases where i=1);set local session_replication_role=origin;set local role service_role;
select pg_temp.ok(property_video_cancelled_terminal((select(c#>>'{job,id}')::uuid from failed_cases where i=1),(select(c#>>'{source,attempt_id}')::uuid from failed_cases where i=1),'fixture-accepted:1','fal','fixture-model'),'known paid provider terminal releases failed slot');
select pg_temp.ok((select count(*)=1 from property_video_job_sources where provider_terminal_at is not null),'provider terminal releases exactly one slot');
select pg_temp.ok(property_video_cancelled_terminal((select(c#>>'{job,id}')::uuid from failed_cases where i=1),(select(c#>>'{source,attempt_id}')::uuid from failed_cases where i=1),'fixture-accepted:1','fal','fixture-model'),'lost terminal acknowledgement is idempotent');
select pg_temp.ok((select count(*)=1 from property_video_job_sources where provider_terminal_at is not null),'terminal replay does not release another slot');
create temporary table resumed_capacity as select property_video_job_claim((select id from waiting_job),'slot-0')c;
select pg_temp.ok((select c->>'action'='dispatch'from resumed_capacity),'one confirmed terminal receipt admits exactly one new source');
select pg_temp.ok(property_video_job_claim((select id from waiting_job),'slot-1')->>'action'='wait','existing global four limit still blocks another dispatch');
-- Unknown acceptance remains conservatively counted even after a recipe fails.
reset role;update property_video_jobs set state='failed'where id=(select id from waiting_job);update property_video_job_sources set state='ambiguous',lease_until=null where job_id=(select id from waiting_job)and position=0;set local role service_role;
select pg_temp.refuse($q$select property_video_cancelled_terminal((select id from waiting_job),(select(c#>>'{source,attempt_id}')::uuid from resumed_capacity),'guessed-unknown-receipt','fal','fixture-model')$q$,'RP409:','missing supplier receipt cannot free ambiguous failed slot');
create temporary table another_waiting as select pg_temp.enqueue_case(6)id;
select pg_temp.ok(property_video_job_claim((select id from another_waiting),'slot-0')->>'action'='wait','unknown failed acceptance continues to consume global slot');
select pg_temp.ok((select jsonb_agg(r order by r->>'id')from before_liability)=(select jsonb_agg(to_jsonb(r)order by id::text)from app_video_cost_reservations r),'terminal reconciliation preserves all reservation holds and settlement fields');
select pg_temp.ok(not exists(select 1 from cost_ledger),'metadata reconciliation creates no ledger settlement or refund');
select pg_temp.ok(not exists(select 1 from before_sources b join property_video_job_sources s using(job_id,position)where row(b.receipt,b.request_key,b.attempt_id,b.quality_retry_history)is distinct from row(s.receipt,s.request_key,s.attempt_id,s.quality_retry_history)),'failed reconciliation preserves exact attempts receipts and retry history');
select pg_temp.ok(not exists(select 1 from property_video_job_outputs),'failed reconciliation never produces or publishes an output');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_cancelled_terminal(uuid,uuid,text,text,text)','execute')and not has_function_privilege('anon','public.property_video_cancelled_attempts()','execute'),'only service can reconcile paid terminal metadata');
reset role;set local role authenticated;
select pg_temp.refuse('select property_video_cancelled_attempts()','permission denied','client cannot claim failed paid receipt reconciliation');
select pg_temp.refuse($q$select property_video_cancelled_terminal(gen_random_uuid(),gen_random_uuid(),'request','fal','fixture-model')$q$,'permission denied','client cannot assert failed provider terminal');
reset role;select jsonb_build_object('passed',true,'assertions',(select n from checks));
rollback;
