-- Property video: no dead end after a failed motion-quality (temporal) verdict.
--
-- Today a paid AI clip that fails the temporal motion check (walking bob, sway,
-- cadence, zoom pumping, travel, roll, repeated frames) stops the whole video
-- as "Video quality review paused" with no automatic way forward: both
-- kie-kling3-4k-steady-v1 jobs in production ended there (21 Oct 2026).
--
-- This migration adds an OWNER-CONTROLLED switch, shipped OFF:
--   app_config key 'property_video_graceful_fallback' = {"enabled": false, ...}
-- While it is off, every function below behaves exactly as before.
-- When the owner turns it on, a shot whose immutable recorded temporal verdict
-- failed is finished with the user's own selected photo (existing
-- 'original_photo' shot, only when the job has allow_original_photo_fallback)
-- and the remaining shots and the final video continue normally.
--
-- Unchanged guarantees: no new or repeated paid generation; the paid receipt,
-- clip, cost ledger, reservation and provenance rows are not touched; the
-- fallback is still refused without persisted evidence; ambiguous supplier
-- outcomes still go to needs_reconciliation; Photo Motion jobs are untouched.
--
-- Safe to apply once: it refuses to run unless the three replaced functions
-- are byte-identical to the reviewed production predecessors.
-- Rollback: see reports/video-reliability.md ("Risk notes"). In short: set the
-- switch to {"enabled": false} (instant), or re-create the three functions from
-- 20261021222704 (property_video_job_failure) and 20261015023751 (both guards)
-- and drop property_video_graceful_fallback_evidence(uuid,uuid).
begin;
lock table public.property_video_jobs,public.property_video_job_sources in share row exclusive mode;
do $baseline$begin
 if(select md5(prosrc)from pg_proc where oid='public.property_video_job_failure(uuid,uuid,uuid,text,boolean)'::regprocedure)is distinct from'53a2d40ae0768110a7e1498a0a0e6d0e'then raise exception'Graceful fallback predecessor changed: property_video_job_failure';end if;
 if(select md5(prosrc)from pg_proc where oid='public.property_video_fallback_source_guard()'::regprocedure)is distinct from'9d7673f2d3416ecbde87d75d1c59b7df'then raise exception'Graceful fallback predecessor changed: property_video_fallback_source_guard';end if;
 if(select md5(prosrc)from pg_proc where oid='public.property_video_fallback_output_guard()'::regprocedure)is distinct from'970c541a22b34ba07a839c3170283d12'then raise exception'Graceful fallback predecessor changed: property_video_fallback_output_guard';end if;
 if to_regprocedure('public.property_video_structural_rejection(uuid,uuid)')is null or to_regclass('public.property_video_job_temporal_verdicts')is null then raise exception'Graceful fallback prerequisites are missing';end if;
 if to_regprocedure('public.property_video_graceful_fallback_evidence(uuid,uuid)')is not null then raise exception'Graceful fallback is already installed';end if;
end$baseline$;

-- Shipped OFF. Only the owner turns it on (one UPDATE of this row).
insert into public.app_config(key,value)values('property_video_graceful_fallback',jsonb_build_object('enabled',false,'policy','temporal-refusal-original-photo-v1'))on conflict(key)do nothing;

-- Evidence that one shot may finish with the user's selected photo because its
-- paid clip has a recorded failing temporal verdict. Null means "not allowed".
create function public.property_video_graceful_fallback_evidence(p_job uuid,p_attempt uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;v public.property_video_job_temporal_verdicts;enabled boolean;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_job is null or p_attempt is null then return null;end if;
 select *into j from public.property_video_jobs where id=p_job;
 select *into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt;
 if j.id is null or s.job_id is null or s.clip is null or s.receipt is null or coalesce(s.clip->>'sha256','')!~'^[a-f0-9]{64}$'
  or j.manifest->>'source_mode'is not distinct from'photo_motion_v1'
  or not coalesce((j.manifest->>'allow_original_photo_fallback')::boolean,false)then return null;end if;
 select coalesce(value->'enabled'='true'::jsonb,false)into enabled from public.app_config where key='property_video_graceful_fallback';
 -- Turning the switch off stops new substitutions; a shot already finished this
 -- way keeps its recorded evidence so its video can still be assembled.
 if not coalesce(enabled,false)and not(s.state='original_photo'and s.fallback_evidence->>'kind'='temporal_motion_refusal'and s.fallback_evidence->>'attempt_id'=p_attempt::text)then return null;end if;
 select *into v from public.property_video_job_temporal_verdicts t where t.job_id=p_job and t.position=s.position and t.attempt_id=p_attempt
  and t.record->>'clip_sha256'=s.clip->>'sha256'and t.record->>'attempt_id'=p_attempt::text
  and t.record->>'profile'='temporal-motion-v2'and t.record#>>'{verdict,profile}'='temporal-motion-v2'
  and t.record#>>'{limits,profile}'='temporal-motion-v2'and t.record#>>'{limits,sha256}'=t.limits_sha256
  and t.record#>'{verdict,pass}'='false'::jsonb and jsonb_typeof(t.record#>'{verdict,reasons}')='array'and t.record#>'{verdict,reasons}'<>'[]'::jsonb
  order by t.recorded_at,t.limits_sha256 limit 1;
 if v.job_id is null then return null;end if;
 return jsonb_build_object('kind','temporal_motion_refusal','policy','temporal-refusal-original-photo-v1','attempt_id',p_attempt,'request_id',s.receipt->>'request_id',
  'clip_sha256',s.clip->>'sha256','limits_sha256',v.limits_sha256,'reasons',v.record#>'{verdict,reasons}','verdict_recorded_at',v.recorded_at);end$$;

create or replace function public.property_video_fallback_source_guard()returns trigger language plpgsql security definer set search_path=''as $$declare evidence jsonb;begin
 if new.state='original_photo'then evidence:=public.property_video_structural_rejection(new.job_id,new.attempt_id);
  if evidence is null then evidence:=public.property_video_graceful_fallback_evidence(new.job_id,new.attempt_id);end if;
  if evidence is null then raise exception'RP409: Original-photo fallback requires a confirmed paid structural quality rejection';end if;
  new.fallback_evidence:=evidence;end if;return new;end$$;

create or replace function public.property_video_fallback_output_guard()returns trigger language plpgsql security definer set search_path=''as $$begin
 if new.state in('composing','ready')and exists(select 1 from public.property_video_job_sources s where s.job_id=new.id and s.state='original_photo'and public.property_video_structural_rejection(s.job_id,s.attempt_id)is null
  and public.property_video_graceful_fallback_evidence(s.job_id,s.attempt_id)is null)then
  raise exception'RP409: A saved photo fallback has no confirmed structural rejection; resume its retained clip quality check';end if;return new;end$$;

create or replace function public.property_video_job_failure(p_job uuid,p_lease uuid,p_attempt uuid,p_code text,p_ambiguous boolean default false)returns boolean
language plpgsql security definer set search_path=''as $function$declare j public.property_video_jobs;s public.property_video_job_sources;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into j from public.property_video_jobs where id=p_job for update;if j.id is null then return false;end if;
 if j.cancelled_at is not null or j.deadline<=now()or j.state in('ready','cancelled')then raise exception'RP409: Stopped work cannot accept a failure callback';end if;
 if j.manifest->>'source_mode'='photo_motion_v1'then
  if p_attempt is not null or p_ambiguous is distinct from false or p_code not in('cpu_audio_failed','cpu_compose_failed')or p_code is null
   or not exists(select 1 from public.property_video_photo_motion_observations where job_id=p_job and lease_token=p_lease and phase=case when p_code='cpu_audio_failed'then'inspect_audio'else'compose'end and outcome='failed')
  then raise exception'RP409: Photo Motion requires its closed current CPU failure observation';end if;
  if p_code='cpu_audio_failed'then
   if j.audio_lease is distinct from p_lease or j.audio_preflight is not null or j.audio_attempts not between 1 and 3 then raise exception'RP409: Current Photo Motion audio lease is required';end if;
   update public.property_video_jobs set state=case when audio_attempts>=3 then'failed'else'queued'end,audio_until=now(),message='The saved narration could not be decoded. Your photos and any saved files are kept.'where id=p_job;
  else
   if j.compose_lease is distinct from p_lease or j.compose_attempts not between 1 and 3 or j.state not in('composing','generating','failed')then raise exception'RP409: Current Photo Motion composition lease is required';end if;
   update public.property_video_jobs set state=case when compose_attempts>=3 then'failed'else'generating'end,compose_until=now(),message='Photo Motion could not finish. Your photos and any saved files are kept.'where id=p_job;
  end if;return true;
 end if;

 if p_attempt is null and j.audio_lease=p_lease and j.audio_preflight is null then update public.property_video_jobs set state=case when audio_attempts>=3 then'failed'else'queued'end,audio_until=now(),message='The saved narration could not be decoded. Re-record or upload a valid audio take.'where id=p_job;return true;end if;
 if p_attempt is null then if j.compose_lease is distinct from p_lease or j.state<>'composing'then raise exception'RP409: A current composition lease is required';end if;
  update public.property_video_jobs set state=case when compose_attempts>=3 then'failed'else'generating'end,compose_until=now(),message='Video assembly could not finish. Your finished clips are saved.'where id=p_job;return true;end if;
 select * into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt and lease_token=p_lease for update;
 if s.job_id is null then raise exception'RP409: A current shot lease is required';end if;
 if p_code='capacity_before_dispatch'and not p_ambiguous then
  if s.receipt is not null or exists(select 1 from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key and released_at is null)then raise exception'RP409: Accepted or uncertain supplier work cannot be reset';end if;
  update public.property_video_job_sources set state='failed',last_error=p_code,lease_until=null where job_id=p_job and attempt_id=p_attempt;
  update public.property_video_jobs set state='failed',message='Video paused before the next unpaid clip. Completed clips are retained; resume after processing capacity is available.'where id=p_job;return true;end if;
 -- Owner-enabled graceful finish (app_config property_video_graceful_fallback):
 -- a paid clip whose recorded temporal motion verdict failed is replaced by the
 -- user's own selected photo (the user allowed that fallback) and the video is
 -- still delivered. No new generation, no re-extract, no erased receipt/clip.
 if not p_ambiguous and p_code in('quality_check_refused','cpu_extract_failed')and s.state='quality_review'
  and public.property_video_graceful_fallback_evidence(p_job,p_attempt)is not null then
  update public.property_video_job_sources set state='original_photo',last_error='temporal_motion_refused',lease_until=null where job_id=p_job and attempt_id=p_attempt;return true;end if;
 if p_code='cpu_extract_failed'and s.state='quality_review'and s.cpu_attempts<3 then update public.property_video_job_sources set state='processing',lease_until=null,last_error=p_code where job_id=p_job and attempt_id=p_attempt;return true;end if;
 -- Only the persisted terminal QC verdict can authorize this substitution.
 if not p_ambiguous and p_code='quality_check_refused'and public.property_video_structural_rejection(p_job,p_attempt)is not null then
  update public.property_video_job_sources set state='original_photo',last_error=p_code,lease_until=null where job_id=p_job and attempt_id=p_attempt;return true;end if;
 -- A known paid clip with an unknown QC result is a quality pause, not an
 -- ambiguous new provider POST. Never erase its immutable receipt or clip.
 update public.property_video_job_sources set state=case when p_ambiguous and s.clip is null then'ambiguous'else'failed'end,last_error=left(p_code,80),lease_until=null where job_id=p_job and attempt_id=p_attempt;
 update public.property_video_jobs set state=case when p_ambiguous and s.clip is null then'needs_reconciliation'else'failed'end,
  message=case when p_ambiguous and s.clip is null then'The provider receipt could not be confirmed. No duplicate generation will be started.'when s.clip is not null then'Video quality review paused. Your paid clip is saved; resume the check after processing is available.'else'A selected photo could not be generated or approved. Your photos and payment receipts are retained.'end,updated_at=now()where id=p_job;return true;end$function$;

revoke all on function public.property_video_graceful_fallback_evidence(uuid,uuid),public.property_video_fallback_source_guard(),public.property_video_fallback_output_guard(),public.property_video_job_failure(uuid,uuid,uuid,text,boolean)from public,anon,authenticated;
grant execute on function public.property_video_graceful_fallback_evidence(uuid,uuid),public.property_video_fallback_source_guard(),public.property_video_fallback_output_guard(),public.property_video_job_failure(uuid,uuid,uuid,text,boolean)to service_role;
commit;
