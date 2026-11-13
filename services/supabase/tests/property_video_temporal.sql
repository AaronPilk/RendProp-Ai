-- Actual current SQL authority for recorded temporal motion verdicts with
-- synthetic transport facts; no encoded media, model or network. The driver
-- (property_video_temporal_pg.py) prepends the owned-property seed and the
-- paid_clip helpers of property_video_jobs.sql.
create temporary table checks(n integer);insert into checks values(0);grant all on checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'TEMPORAL FAIL: %',label;end if;update checks set n=n+1;end$$;
create function pg_temp.refuse(command text,needle text,label text)returns void language plpgsql as $$begin begin execute command;exception when others then if position(needle in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception'TEMPORAL FAIL: allowed %',label;end$$;
create function pg_temp.recipe(i integer,n integer default 2)returns jsonb language sql as $$
 select jsonb_set(jsonb_set(jsonb_set(m,'{operation_id}',to_jsonb(('f8700000-0000-4000-8000-'||lpad(i::text,12,'0'))::text)),'{sources}',(select jsonb_agg(value order by ord)from jsonb_array_elements(m->'sources')with ordinality e(value,ord)where ord<=n)),'{presentation,shot_labels}',(select jsonb_agg(null::text)from generate_series(1,n)))from bm
$$;
create function pg_temp.report(reasons text[],limits text default repeat('1',64))returns jsonb language sql as $$
 select jsonb_build_object('profile','temporal-motion-v2','limits',jsonb_build_object('profile','temporal-motion-v2','sha256',limits),
  'metrics',jsonb_build_object('profile','temporal-motion-v2','fps',24,'steps',120,'frame',jsonb_build_array(1920,1080),'bob_pp_px',case when'vertical_bob'=any(reasons)then 6.4 else .3 end,'cadence_acf',0,'cadence_hz',null),
  'verdict',jsonb_build_object('profile','temporal-motion-v2','pass',cardinality(reasons)=0,'reasons',to_jsonb(reasons)))
$$;
-- The stored record for one shot attempt under one limit version, and a job's record count.
create function pg_temp.verdict(j uuid,a uuid,l text default repeat('1',64))returns jsonb language sql as $$select v.record from public.property_video_job_temporal_verdicts v where v.job_id=j and v.attempt_id=a and v.limits_sha256=l$$;
create function pg_temp.verdicts(j uuid)returns bigint language sql as $$select count(*)from public.property_video_job_temporal_verdicts where job_id=j$$;
-- A paid, retained clip under its live quality-review lease (actual claim/receipt/clip RPCs).
create function pg_temp.review_job(i integer,n integer default 2)returns jsonb language plpgsql as $$declare j public.property_video_jobs;c jsonb;begin
 j:=property_video_job_enqueue((select actor from bf),pg_temp.recipe(i,n));c:=property_video_job_claim(j.id,'slot-0');return pg_temp.paid_clip(c);end$$;
-- Stored paid drift 'retry' evidence for one attempt, exactly as
-- property_video_derived_retry.sql (pg_temp.retry_grant) seeds it: synthetic
-- receipt rows only, no generated pixels, model or provider call.
create function pg_temp.retry_grant(c jsonb)returns void language plpgsql security definer as $$declare j public.property_video_jobs;s public.property_video_job_sources;r public.app_video_cost_reservations;v jsonb;begin
 select *into j from property_video_jobs where id=(c#>>'{job,id}')::uuid;select *into s from property_video_job_sources where job_id=j.id and attempt_id=(c#>>'{source,attempt_id}')::uuid;
 select *into r from app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key;
 v:=jsonb_build_object('task','judge.qc_drift','request_id',s.receipt->>'request_id','source_sha256',repeat('d',32),'verdict','pass','action','retry','publishable',false,'failed',jsonb_build_array('additions','artifacts'),'attempt',0,'scores',jsonb_build_object('architecture',95,'contents',97,'additions',0,'artifacts',8,'same_room',98),'thresholds',jsonb_build_object('architecture',85,'contents',80,'additions',90,'artifacts',75,'same_room',90));
 update media_provenance set qc=v where id=s.generation_provenance_id;
 insert into cost_ledger(org_id,feature,provider,model,total_cents,meta)values(j.org_id,'qc','anthropic','fixture-judge',.0001,v||jsonb_build_object('kind','video_drift','provenance_id',s.generation_provenance_id,'source_asset_id',s.asset_id));
 insert into app_video_drift_checks(reservation_id,actor_id,org_id,listing_id,source_sha256,state,result)values(r.id,j.actor_id,j.org_id,j.listing_id,repeat('d',32),'retry',jsonb_build_object('drift',v||jsonb_build_object('status','fail')));end$$;
-- Verdicts live in their own service-read-only table; the shot row keeps its shape.
select pg_temp.ok((select relrowsecurity and not relforcerowsecurity from pg_class where oid='public.property_video_job_temporal_verdicts'::regclass)and not exists(select 1 from pg_policy where polrelid='public.property_video_job_temporal_verdicts'::regclass),'verdict table has RLS and no client policy');
select pg_temp.ok(has_table_privilege('service_role','public.property_video_job_temporal_verdicts','select')and not has_table_privilege('service_role','public.property_video_job_temporal_verdicts','insert')and not has_table_privilege('service_role','public.property_video_job_temporal_verdicts','update')and not has_table_privilege('service_role','public.property_video_job_temporal_verdicts','delete')
 and not has_table_privilege('authenticated','public.property_video_job_temporal_verdicts','select')and not has_table_privilege('anon','public.property_video_job_temporal_verdicts','select'),'verdicts are service-read-only; writes only through the RPC');
select pg_temp.ok(not exists(select 1 from information_schema.columns where table_schema='public'and table_name='property_video_job_sources'and column_name like'temporal%'),'the shot row shape is untouched');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)','execute')and not has_function_privilege('anon','public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)','execute')and has_function_privilege('service_role','public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)','execute'),'temporal record is service-only');
reset role;update listings set status='draft'where id=(select listing from bf);update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';set local role service_role;
select pg_temp.refuse($q$select property_video_job_temporal(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),repeat('e',64),pg_temp.report('{}'))$q$,'RP404:','unknown job refused');
create temporary table rv as select pg_temp.review_job(1)c;grant select on rv to service_role;
create temporary table rv_ids as select(c#>>'{job,id}')::uuid job,(c#>>'{source,lease_token}')::uuid lease,(c#>>'{source,attempt_id}')::uuid attempt from rv;grant select on rv_ids to service_role;
select pg_temp.ok((select s.state='quality_review'and s.clip->>'sha256'=repeat('e',64)and pg_temp.verdicts(rv_ids.job)=0 from property_video_job_sources s,rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt),'fixture shot is under quality review with a retained clip and no verdict');
-- Closed report shape and clip identity.
select pg_temp.refuse($q$select property_video_job_temporal(job,lease,attempt,repeat('f',64),pg_temp.report('{}'))from rv_ids$q$,'RP409: The temporal report names a different clip','wrong clip sha refused');
select pg_temp.refuse($q$select property_video_job_temporal(job,lease,attempt,'not-a-sha',pg_temp.report('{}'))from rv_ids$q$,'RP409: The temporal report names a different clip','malformed clip sha refused');
select pg_temp.refuse($q$select property_video_job_temporal(job,gen_random_uuid(),attempt,repeat('e',64),pg_temp.report('{}'))from rv_ids$q$,'RP409:','foreign lease refused');
select pg_temp.refuse($q$select property_video_job_temporal(job,lease,gen_random_uuid(),repeat('e',64),pg_temp.report('{}'))from rv_ids$q$,'RP409:','foreign attempt refused');
select pg_temp.refuse($q$select property_video_job_temporal(job,lease,attempt,repeat('e',64),'"pass"'::jsonb)from rv_ids$q$,'RP400: Use a closed temporal motion report','non-object report refused');
select pg_temp.refuse($q$select property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{}')||'{"series":{}}')from rv_ids$q$,'RP400:','extra report keys refused');
select pg_temp.refuse($q$select property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{}')-'limits')from rv_ids$q$,'RP400:','missing limits refused');
select pg_temp.refuse($q$select property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{}','v2'))from rv_ids$q$,'RP400:','unhashed limit version refused');
select pg_temp.refuse($q$select property_video_job_temporal(job,lease,attempt,repeat('e',64),jsonb_set(pg_temp.report('{vertical_bob}'),'{verdict,pass}','true'))from rv_ids$q$,'RP400:','pass with reasons refused');
select pg_temp.refuse($q$select property_video_job_temporal(job,lease,attempt,repeat('e',64),jsonb_set(pg_temp.report('{}'),'{verdict,pass}','false'))from rv_ids$q$,'RP400:','fail without reasons refused');
select pg_temp.refuse($q$select property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{looks_fine}'))from rv_ids$q$,'RP400:','unknown reason refused');
select pg_temp.refuse($q$select property_video_job_temporal(job,lease,attempt,repeat('e',64),jsonb_set(pg_temp.report('{}'),'{verdict,profile}','"temporal-motion-v1"'))from rv_ids$q$,'RP400:','foreign verdict profile refused');
select pg_temp.ok((select pg_temp.verdicts(job)=0 from rv_ids),'no refusal recorded anything');
-- First record, exact replay, first-measurement-wins, immutability.
create temporary table reservations_before as select count(*)n from app_video_cost_reservations;grant select on reservations_before to service_role;
create temporary table shot_before as select to_jsonb(s)snap from property_video_job_sources s,rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt;grant select on shot_before to service_role;
create temporary table first_record as select property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{vertical_bob,walking_cadence}'))r from rv_ids;grant select on first_record to service_role;
select pg_temp.ok((select r->>'attempt_id'=attempt::text and r->>'clip_sha256'=repeat('e',64)and(r->>'recorded_at')::timestamptz<=now()and r#>>'{verdict,pass}'='false'and r#>'{verdict,reasons}'='["vertical_bob","walking_cadence"]'::jsonb and r#>>'{limits,sha256}'=repeat('1',64)from first_record,rv_ids),'first verdict recorded with attempt, clip and limit version');
select pg_temp.ok((select pg_temp.verdict(rv_ids.job,rv_ids.attempt)=(select r from first_record)and pg_temp.verdicts(rv_ids.job)=1 and to_jsonb(s)=(select snap from shot_before)from property_video_job_sources s,rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt),'record stored once; the shot row is byte-identical');
select pg_temp.ok((select property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{vertical_bob,walking_cadence}'))=(select r from first_record)from rv_ids),'exact replay returns the same record');
select pg_temp.ok((select property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{}'))=(select r from first_record)from rv_ids),'a re-measurement under the same limits cannot overwrite: the first recorded verdict wins');
select pg_temp.ok((select pg_temp.verdict(job,attempt)=(select r from first_record)and pg_temp.verdicts(job)=1 from rv_ids),'stored verdict unchanged by the repeat');
-- The worker's own role can read verdicts but never write them directly.
select pg_temp.refuse($q$insert into property_video_job_temporal_verdicts(job_id,position,attempt_id,limits_sha256,record)select job,0,attempt,repeat('9',64),jsonb_build_object('attempt_id',attempt,'limits',jsonb_build_object('sha256',repeat('9',64)))from rv_ids$q$,'permission denied for table property_video_job_temporal_verdicts','the service role cannot insert a verdict directly');
select pg_temp.refuse($q$update property_video_job_temporal_verdicts set record=record where job_id=(select job from rv_ids)$q$,'permission denied for table property_video_job_temporal_verdicts','the service role cannot edit a verdict');
select pg_temp.refuse($q$delete from property_video_job_temporal_verdicts where job_id=(select job from rv_ids)$q$,'permission denied for table property_video_job_temporal_verdicts','the service role cannot erase a verdict');
reset role;
-- Even the owner cannot edit a recorded verdict; the key and checks refuse a
-- second record for the same attempt and limit version or a forged identity.
select pg_temp.refuse($q$update property_video_job_temporal_verdicts v set record=jsonb_set(record,'{verdict,pass}','true')from rv_ids where v.job_id=rv_ids.job and v.attempt_id=rv_ids.attempt$q$,'RP409: A recorded temporal verdict is immutable','direct edit of a recorded verdict refused');
select pg_temp.refuse($q$insert into property_video_job_temporal_verdicts(job_id,position,attempt_id,limits_sha256,record)select job,0,attempt,repeat('1',64),(select r from first_record)from rv_ids$q$,'duplicate key value violates unique constraint "property_video_job_temporal_verdicts_pkey"','a second record for the same attempt and limit version refused');
select pg_temp.refuse($q$insert into property_video_job_temporal_verdicts(job_id,position,attempt_id,limits_sha256,record)select job,0,attempt,repeat('4',64),(select r from first_record)from rv_ids$q$,'property_video_job_temporal_verdicts_record_check','a record must name its own attempt and limit version');
select pg_temp.refuse($q$insert into property_video_job_temporal_verdicts(job_id,position,attempt_id,limits_sha256,record)select job,7,attempt,repeat('1',64),(select r from first_record)from rv_ids$q$,'property_video_job_temporal_verdicts_source_fkey','a verdict must belong to an existing shot');
set local role service_role;
-- A new limit version for the same attempt adds a record; the first stays unchanged.
create temporary table second_record as select property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{}',repeat('2',64)))r from rv_ids;grant select on second_record to service_role;
select pg_temp.ok((select r#>>'{verdict,pass}'='true'and r#>>'{limits,sha256}'=repeat('2',64)from second_record),'new limit version records a new verdict');
select pg_temp.ok((select pg_temp.verdict(job,attempt)=(select r from first_record)and pg_temp.verdict(job,attempt,repeat('2',64))=(select r from second_record)and pg_temp.verdicts(job)=2 from rv_ids),'the earlier limit version''s verdict is kept unchanged');
reset role;
select pg_temp.refuse($q$update property_video_job_temporal_verdicts v set record=jsonb_set(record,'{verdict,pass}','true')from rv_ids where v.job_id=rv_ids.job and v.limits_sha256=repeat('1',64)$q$,'RP409:','an earlier verdict cannot be edited');
set local role service_role;
-- The record never advances, approves or buys: the shot still needs the paid drift receipt.
select pg_temp.refuse($q$select property_video_job_qc(job,lease,attempt)from rv_ids$q$,'RP409: This clip has no passing paid source quality receipt','a recorded temporal pass is not a publication receipt');
select pg_temp.refuse($q$select property_video_job_quality_retry(job,lease,attempt)from rv_ids$q$,'RP409: A terminal paid same-source retry grant is required','a temporal-only failure has no paid retry grant (follow-up: see temporal.ts)');
select pg_temp.ok((select count(*)from app_video_cost_reservations)=(select n from reservations_before),'no reservation or purchase followed any temporal write');
-- The worker's HOLD is the existing CPU review pause: the recorded verdict survives the
-- re-extract (new lease, same attempt, first measurement still wins) and the third pause
-- is a resumable quality pause with the paid clip retained, never a publication.
create temporary table hold_claims(n integer,c jsonb);grant all on hold_claims to service_role;
do $$declare i integer;c jsonb;j uuid;l uuid;a uuid;begin select job,lease,attempt into j,l,a from rv_ids;
 for i in 1..2 loop
  perform property_video_job_failure(j,l,a,'cpu_extract_failed',false);
  if(select state<>'processing'or pg_temp.verdicts(j)<>2 or last_error<>'cpu_extract_failed'from property_video_job_sources where job_id=j and attempt_id=a)then raise exception'TEMPORAL FAIL: hold % did not keep the verdict in a review pause',i;end if;
  c:=property_video_job_claim(j,'slot-0');if c->>'action'<>'extract_frames'or(c#>>'{source,attempt_id}')::uuid<>a then raise exception'TEMPORAL FAIL: hold % did not re-extract the same attempt',i;end if;
  l:=(c#>>'{source,lease_token}')::uuid;insert into hold_claims values(i,c);
  if property_video_job_temporal(j,l,a,repeat('e',64),pg_temp.report('{}',repeat('2',64)))<>(select r from second_record)then raise exception'TEMPORAL FAIL: re-extract % overwrote the recorded verdict',i;end if;
 end loop;
 perform property_video_job_failure(j,l,a,'cpu_extract_failed',false);end$$;
select pg_temp.ok((select s.state='failed'and s.last_error='cpu_extract_failed'and s.cpu_attempts=3 and s.clip is not null and s.receipt is not null and s.generation_provenance_id is not null and s.cpu_recoveries=0 and pg_temp.verdict(rv_ids.job,rv_ids.attempt,repeat('2',64))=(select r from second_record)and pg_temp.verdicts(rv_ids.job)=2 from property_video_job_sources s,rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt),'third hold is a resumable quality pause with paid clip and recorded verdict retained');
select pg_temp.ok((select state='failed'and message like'Video quality review paused.%'from property_video_jobs,rv_ids where id=rv_ids.job),'held job pauses explicitly, never ready');
select pg_temp.ok((select count(*)from app_video_cost_reservations)=(select n from reservations_before),'holds bought nothing');
create temporary table resumed as select(property_video_job_resume((select actor from bf),job,0)).*from rv_ids;grant select on resumed to service_role;
select pg_temp.ok((select state='generating'from resumed),'owner resume reopens the held review without a new quote');
select pg_temp.ok((select s.state='processing'and s.cpu_recoveries=1 and s.cpu_attempts=0 and pg_temp.verdicts(rv_ids.job)=2 from property_video_job_sources s,rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt),'resume keeps the recorded verdicts for the next review pass');
create temporary table resumed_claim as select property_video_job_claim(job,'slot-0')c from rv_ids;grant select on resumed_claim to service_role;
select pg_temp.ok((select c->>'action'='extract_frames'and(c#>>'{source,attempt_id}')::uuid=attempt from resumed_claim,rv_ids),'resumed review re-extracts the same paid attempt');
select pg_temp.ok((select property_video_job_temporal(rv_ids.job,(c#>>'{source,lease_token}')::uuid,rv_ids.attempt,repeat('e',64),pg_temp.report('{vertical_bob}',repeat('2',64)))=(select r from second_record)from resumed_claim,rv_ids),'after resume the first recorded verdict still wins');
-- A lapsed lease refuses a write until the next claim.
reset role;create temporary table live_lease as select(c#>>'{source,lease_token}')::uuid lease from resumed_claim;grant select on live_lease to service_role;set local role service_role;
reset role;update property_video_job_sources s set lease_until=now()-interval'1 second'from rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt;set local role service_role;
select pg_temp.refuse($q$select property_video_job_temporal(job,(select lease from live_lease),attempt,repeat('e',64),pg_temp.report('{}',repeat('3',64)))from rv_ids$q$,'RP409:','lapsed review lease cannot record');
select pg_temp.ok((select pg_temp.verdicts(job)=2 and pg_temp.verdict(job,attempt,repeat('3',64))is null from rv_ids),'lapsed-lease refusal recorded nothing');
-- A temporal refusal (walk-through travel, horizon roll, repeated frames,
-- unmeasurable) is what the worker reports as quality_check_refused. Without a
-- paid structural drift rejection that is NOT an original-photo substitution:
-- property_video_job_failure pauses the job with the paid clip, receipt and
-- provenance retained, and the fallback guard refuses a forged substitution. A
-- CPU measurement never invents provenance, a QC receipt or a still fallback.
create temporary table rf as select pg_temp.review_job(2,1)c;grant select on rf to service_role;
create temporary table rf_ids as select(c#>>'{job,id}')::uuid job,(c#>>'{source,lease_token}')::uuid lease,(c#>>'{source,attempt_id}')::uuid attempt from rf;grant select on rf_ids to service_role;
create temporary table rf_before as select(select count(*)from media_provenance)provenance,(select count(*)from app_video_cost_reservations)reservations,(select count(*)from cost_ledger)ledger;grant select on rf_before to service_role;
create temporary table rf_record as select property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{walk_through_travel}'))r from rf_ids;grant select on rf_record to service_role;
select pg_temp.ok((select property_video_job_failure(job,lease,attempt,'quality_check_refused',false)from rf_ids),'the worker''s temporal refusal is accepted as a quality refusal');
select pg_temp.ok((select s.state='failed'and s.last_error='quality_check_refused'and s.clip is not null and s.receipt is not null and s.generation_provenance_id is not null and pg_temp.verdict(rf_ids.job,rf_ids.attempt)=(select r from rf_record)from property_video_job_sources s,rf_ids where s.job_id=rf_ids.job and s.attempt_id=rf_ids.attempt),'a temporal refusal pauses the shot with the paid clip, receipt, provenance and recorded verdict retained');
select pg_temp.ok((select state='failed'and message like'Video quality review paused.%'from property_video_jobs,rf_ids where id=rf_ids.job),'a temporal refusal pauses the job, never ready and never a still substitution');
select pg_temp.ok((select count(*)=0 from property_video_job_sources s,rf_ids where s.job_id=rf_ids.job and s.state='original_photo'),'no original-photo fallback without a paid structural rejection');
select pg_temp.ok((select(select count(*)from media_provenance)=provenance and(select count(*)from app_video_cost_reservations)=reservations and(select count(*)from cost_ledger)=ledger from rf_before),'the temporal refusal created no provenance, QC receipt, reservation or cost row');
-- Even a direct service write (the role the worker holds) cannot forge the substitution.
select pg_temp.refuse($q$update property_video_job_sources s set state='original_photo'from rf_ids where s.job_id=rf_ids.job and s.attempt_id=rf_ids.attempt$q$,'RP409: Original-photo fallback requires a confirmed paid structural quality rejection','a recorded temporal refusal cannot be turned into a still fallback');
create temporary table rf_resumed as select(property_video_job_resume((select actor from bf),job,0)).*from rf_ids;grant select on rf_resumed to service_role;
create temporary table rf_claim as select property_video_job_claim(job,'slot-0')c from rf_ids;grant select on rf_claim to service_role;
select pg_temp.ok((select r.state='generating'and c->>'action'='extract_frames'and(c#>>'{source,attempt_id}')::uuid=rf_ids.attempt from rf_resumed r,rf_claim,rf_ids),'owner resume re-reviews the same paid attempt without a new quote');
select pg_temp.ok((select property_video_job_temporal(rf_ids.job,(c#>>'{source,lease_token}')::uuid,rf_ids.attempt,repeat('e',64),pg_temp.report('{}'))=(select r from rf_record)from rf_claim,rf_ids),'after resume the recorded refusal still stands: a re-measurement cannot pass the same attempt');
select pg_temp.ok((select(select count(*)from app_video_cost_reservations)=reservations and(select count(*)from cost_ledger)=ledger from rf_before),'the refusal pause and its resume bought nothing');
-- The actual single paid retry (a persisted drift 'retry' grant) supersedes the
-- attempt; its recorded verdict stays keyed to that attempt, and the next paid
-- attempt of the same shot records its own verdict beside it.
create temporary table rt as select pg_temp.review_job(3,1)c;grant select on rt to service_role;
create temporary table rt_ids as select(c#>>'{job,id}')::uuid job,(c#>>'{source,lease_token}')::uuid lease,(c#>>'{source,attempt_id}')::uuid attempt from rt;grant select on rt_ids to service_role;
create temporary table rt_first as select property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{vertical_bob}'))r from rt_ids;grant select on rt_first to service_role;
reset role;select pg_temp.retry_grant((select c from rt));set local role service_role;
select pg_temp.ok((select(property_video_job_quality_retry(job,lease,attempt)->>'retry_scheduled')='true'from rt_ids),'a persisted paid drift grant schedules the one paid retry');
select pg_temp.ok((select quality_retries=1 and state='pending'and quality_retry_history#>>'{0,prior_source,attempt_id}'=rt_ids.attempt::text and pg_temp.verdict(rt_ids.job,rt_ids.attempt)=(select r from rt_first)from property_video_job_sources s,rt_ids where s.job_id=rt_ids.job and s.position=0),'the paid retry supersedes the attempt; its recorded verdict stays keyed to it');
create temporary table rt_next as select pg_temp.paid_clip(property_video_job_claim(job,'slot-0'))c from rt_ids;grant select on rt_next to service_role;
select pg_temp.ok((select(c#>>'{source,attempt_id}')::uuid is distinct from rt_ids.attempt and(c#>>'{job,id}')::uuid=rt_ids.job from rt_next,rt_ids),'the next paid attempt of the same shot is under review');
select pg_temp.ok((select property_video_job_temporal(rt_ids.job,(c#>>'{source,lease_token}')::uuid,(c#>>'{source,attempt_id}')::uuid,repeat('e',64),pg_temp.report('{}'))#>>'{verdict,pass}'='true'from rt_next,rt_ids),'the new attempt records its own verdict');
select pg_temp.ok((select pg_temp.verdict(rt_ids.job,rt_ids.attempt)=(select r from rt_first)and pg_temp.verdict(rt_ids.job,(c#>>'{source,attempt_id}')::uuid)#>>'{verdict,pass}'='true'and pg_temp.verdicts(rt_ids.job)=2 from rt_next,rt_ids),'the superseded attempt''s verdict is unchanged beside the new one');
-- Account erasure deletes shot rows directly (20261016001450); their verdicts go with them.
reset role;
create temporary table erase_before as select pg_temp.verdicts((select job from rt_ids))n;
delete from property_video_job_sources where job_id=(select job from rt_ids);
select pg_temp.ok((select n=2 from erase_before)and pg_temp.verdicts((select job from rt_ids))=0,'erasing a shot removes its verdicts with it; nothing blocks erasure');
select jsonb_build_object('passed',true,'assertions',(select n from checks),'supplierPOSTs',0);
rollback;
