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
-- A paid, retained clip under its live quality-review lease (actual claim/receipt/clip RPCs).
create function pg_temp.review_job(i integer)returns jsonb language plpgsql as $$declare j public.property_video_jobs;c jsonb;begin
 j:=property_video_job_enqueue((select actor from bf),pg_temp.recipe(i));c:=property_video_job_claim(j.id,'slot-0');return pg_temp.paid_clip(c);end$$;
select pg_temp.ok((select data_type='jsonb'and is_nullable='YES'from information_schema.columns where table_name='property_video_job_sources'and column_name='temporal'),'temporal column is a nullable jsonb record');
select pg_temp.ok((select column_default like'%[]%'from information_schema.columns where table_name='property_video_job_sources'and column_name='temporal_history'),'temporal history defaults empty');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)','execute')and not has_function_privilege('anon','public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)','execute')and has_function_privilege('service_role','public.property_video_job_temporal(uuid,uuid,uuid,text,jsonb)','execute'),'temporal record is service-only');
reset role;update listings set status='draft'where id=(select listing from bf);update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';set local role service_role;
select pg_temp.refuse($q$select property_video_job_temporal(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),repeat('e',64),pg_temp.report('{}'))$q$,'RP404:','unknown job refused');
create temporary table rv as select pg_temp.review_job(1)c;grant select on rv to service_role;
create temporary table rv_ids as select(c#>>'{job,id}')::uuid job,(c#>>'{source,lease_token}')::uuid lease,(c#>>'{source,attempt_id}')::uuid attempt from rv;grant select on rv_ids to service_role;
select pg_temp.ok((select s.state='quality_review'and s.clip->>'sha256'=repeat('e',64)and s.temporal is null from property_video_job_sources s,rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt),'fixture shot is under quality review with a retained clip and no verdict');
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
select pg_temp.ok((select temporal is null and temporal_history='[]'from property_video_job_sources s,rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt),'no refusal recorded anything');
-- First record, exact replay, first-measurement-wins, immutability.
create temporary table reservations_before as select count(*)n from app_video_cost_reservations;grant select on reservations_before to service_role;
create temporary table first_record as select property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{vertical_bob,walking_cadence}'))r from rv_ids;grant select on first_record to service_role;
select pg_temp.ok((select r->>'attempt_id'=attempt::text and r->>'clip_sha256'=repeat('e',64)and(r->>'recorded_at')::timestamptz<=now()and r#>>'{verdict,pass}'='false'and r#>'{verdict,reasons}'='["vertical_bob","walking_cadence"]'::jsonb and r#>>'{limits,sha256}'=repeat('1',64)from first_record,rv_ids),'first verdict recorded with attempt, clip and limit version');
select pg_temp.ok((select s.temporal=(select r from first_record)and s.temporal_history='[]'and s.state='quality_review'and s.last_error is null from property_video_job_sources s,rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt),'record stored on the shot without changing its state');
select pg_temp.ok((select property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{vertical_bob,walking_cadence}'))=(select r from first_record)from rv_ids),'exact replay returns the same record');
select pg_temp.ok((select property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{}'))=(select r from first_record)from rv_ids),'a re-measurement under the same limits cannot overwrite: the first recorded verdict wins');
select pg_temp.ok((select s.temporal=(select r from first_record)and s.temporal_history='[]'from property_video_job_sources s,rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt),'stored verdict unchanged by the repeat');
reset role;
select pg_temp.refuse($q$update property_video_job_sources s set temporal=jsonb_set(temporal,'{verdict,pass}','true')from rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt$q$,'RP409: A recorded temporal verdict is immutable','direct edit of a recorded verdict refused');
select pg_temp.refuse($q$update property_video_job_sources s set temporal=null from rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt$q$,'RP409: A recorded temporal verdict is immutable','erasing a recorded verdict refused');
select pg_temp.refuse($q$update property_video_job_sources s set temporal_history='[{"forged":true}]'from rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt$q$,'RP409: A recorded temporal verdict is immutable','forged history without archiving refused');
set local role service_role;
-- A new limit version for the same attempt archives the prior verdict unchanged.
create temporary table second_record as select property_video_job_temporal(job,lease,attempt,repeat('e',64),pg_temp.report('{}',repeat('2',64)))r from rv_ids;grant select on second_record to service_role;
select pg_temp.ok((select r#>>'{verdict,pass}'='true'and r#>>'{limits,sha256}'=repeat('2',64)from second_record),'new limit version records a new verdict');
select pg_temp.ok((select s.temporal=(select r from second_record)and s.temporal_history=jsonb_build_array((select r from first_record))from property_video_job_sources s,rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt),'prior verdict archived exactly once, unchanged');
reset role;
select pg_temp.refuse($q$update property_video_job_sources s set temporal_history=jsonb_set(temporal_history,'{0,verdict,pass}','true')from rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt$q$,'RP409:','archived verdict cannot be edited');
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
  if(select state<>'processing'or temporal is null or last_error<>'cpu_extract_failed'from property_video_job_sources where job_id=j and attempt_id=a)then raise exception'TEMPORAL FAIL: hold % did not keep the verdict in a review pause',i;end if;
  c:=property_video_job_claim(j,'slot-0');if c->>'action'<>'extract_frames'or(c#>>'{source,attempt_id}')::uuid<>a then raise exception'TEMPORAL FAIL: hold % did not re-extract the same attempt',i;end if;
  l:=(c#>>'{source,lease_token}')::uuid;insert into hold_claims values(i,c);
  if property_video_job_temporal(j,l,a,repeat('e',64),pg_temp.report('{}',repeat('2',64)))<>(select r from second_record)then raise exception'TEMPORAL FAIL: re-extract % overwrote the recorded verdict',i;end if;
 end loop;
 perform property_video_job_failure(j,l,a,'cpu_extract_failed',false);end$$;
select pg_temp.ok((select s.state='failed'and s.last_error='cpu_extract_failed'and s.cpu_attempts=3 and s.clip is not null and s.receipt is not null and s.generation_provenance_id is not null and s.cpu_recoveries=0 and s.temporal=(select r from second_record)and jsonb_array_length(s.temporal_history)=1 from property_video_job_sources s,rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt),'third hold is a resumable quality pause with paid clip and recorded verdict retained');
select pg_temp.ok((select state='failed'and message like'Video quality review paused.%'from property_video_jobs,rv_ids where id=rv_ids.job),'held job pauses explicitly, never ready');
select pg_temp.ok((select count(*)from app_video_cost_reservations)=(select n from reservations_before),'holds bought nothing');
create temporary table resumed as select(property_video_job_resume((select actor from bf),job,0)).*from rv_ids;grant select on resumed to service_role;
select pg_temp.ok((select state='generating'from resumed),'owner resume reopens the held review without a new quote');
select pg_temp.ok((select s.state='processing'and s.cpu_recoveries=1 and s.cpu_attempts=0 and s.temporal=(select r from second_record)from property_video_job_sources s,rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt),'resume keeps the recorded verdict for the next review pass');
create temporary table resumed_claim as select property_video_job_claim(job,'slot-0')c from rv_ids;grant select on resumed_claim to service_role;
select pg_temp.ok((select c->>'action'='extract_frames'and(c#>>'{source,attempt_id}')::uuid=attempt from resumed_claim,rv_ids),'resumed review re-extracts the same paid attempt');
select pg_temp.ok((select property_video_job_temporal(rv_ids.job,(c#>>'{source,lease_token}')::uuid,rv_ids.attempt,repeat('e',64),pg_temp.report('{vertical_bob}',repeat('2',64)))=(select r from second_record)from resumed_claim,rv_ids),'after resume the first recorded verdict still wins');
-- A lapsed lease refuses a write until the next claim.
reset role;create temporary table live_lease as select(c#>>'{source,lease_token}')::uuid lease from resumed_claim;grant select on live_lease to service_role;set local role service_role;
reset role;update property_video_job_sources s set lease_until=now()-interval'1 second'from rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt;set local role service_role;
select pg_temp.refuse($q$select property_video_job_temporal(job,(select lease from live_lease),attempt,repeat('e',64),pg_temp.report('{}',repeat('3',64)))from rv_ids$q$,'RP409:','lapsed review lease cannot record');
select pg_temp.ok((select s.temporal=(select r from second_record)from property_video_job_sources s,rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt),'lapsed-lease refusal recorded nothing');
-- The retry path keeps the superseded attempt's verdict in its archived prior_source; a fresh attempt records anew.
select pg_temp.ok((select(to_jsonb(s)-'quality_retry_history')?'temporal'from property_video_job_sources s,rv_ids where s.job_id=rv_ids.job and s.attempt_id=rv_ids.attempt),'prior_source snapshots carry the recorded verdict');
reset role;select jsonb_build_object('passed',true,'assertions',(select n from checks),'supplierPOSTs',0);
rollback;
