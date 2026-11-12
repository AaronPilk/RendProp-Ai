-- Property video: the paid drift judge is ADVISORY (owner decisions, 12 Nov 2026).
--
-- "No quality-check outcome may block or delay delivery of an AI photo or
-- video; verdicts are recorded as advisory. If a result is poor the user
-- retries and spends credits. Only hard technical invalidity blocks."
--
-- Before: a generated clip became ready only through property_video_job_qc,
-- which demands a PASSING paid judge receipt. A failed verdict bought one
-- automatic retry, or replaced the shot with the still photo, or paused the
-- job; an unavailable or malformed verdict paused it.
--
-- After (with property-video-worker of the same date): the judge still runs
-- and is still paid for and recorded exactly as it answered (cost_ledger 'qc'
-- row, media_provenance.qc with enforcement:'advisory', drift-check journal).
-- The worker then calls property_video_job_qc_advisory, which marks the shot
-- ready whatever the verdict and labels it from those records:
--   last_error null                      -> judge passed (same test as before)
--   last_error 'quality_advisory_failed' -> judge failed it; used anyway
--   last_error 'quality_advisory_unknown'-> no usable verdict; used anyway
--   last_error 'quality_judge_off'       -> judge switched off by the owner
-- A clip is never recorded as passed unless it passed.
--
-- Unchanged: the lease/attempt fence, live-job and unchanged-source checks,
-- the clip's AI-disclosure record and its binding to the source photo (both
-- still mandatory), every receipt, reservation, cost and ledger row, tenant
-- and ownership checks, the video's own disclosure labelling. No allowance is
-- refunded for a clip that is used (ai-video, same release).
-- property_video_job_qc is left in place for the previous worker.
--
-- Owner switch, shipped as 'advisory': app_config 'property_video_quality_judge'
--   {"mode":"advisory"}  run the paid judge, record it, enforce nothing (default)
--   {"mode":"off"}       skip the paid judge; shots are labelled 'quality_judge_off'
--
-- property_video_compose_snapshot (assembly recovery) no longer requires a
-- passing judge receipt for a ready clip, so a video containing an
-- advisory-failed clip can still use "Resume assembly".
--
-- Guarded and repeatable: compose_snapshot must be the reviewed production
-- predecessor or already this exact body; the two new functions are created
-- only when absent or already this exact body. Anything else stops.
-- Rollback (operator; FIRST redeploy the previous property-video-worker and
-- ai-video, otherwise finished shots have nowhere to go):
--   drop function public.property_video_job_qc_advisory(uuid,uuid,uuid,text);
--   drop function public.property_video_quality_judge_mode();
--   delete from public.app_config where key='property_video_quality_judge';
--   re-run the CREATE OR REPLACE FUNCTION public.property_video_compose_snapshot
--   statement from 20261015184528_property_video_preoutput_compose_recovery.sql.
-- Shots already finished under the advisory rule stay ready.
begin;
do $baseline$declare current text;begin
 select md5(prosrc)into current from pg_proc where oid=to_regprocedure('public.property_video_compose_snapshot(uuid)');
 if current is null or current not in('2dd963d6784041fdd2a26e5cde8ce913','ce6dfb696e4a70ef81c30e79f3d811ce')then raise exception'Advisory drift judge: property_video_compose_snapshot changed since review';end if;
 if to_regprocedure('public.property_video_job_qc(uuid,uuid,uuid)')is null or to_regprocedure('public.property_video_job_worker_scope(uuid,uuid,uuid)')is null
  or to_regprocedure('public.property_video_job_scope(uuid,uuid,boolean)')is null then raise exception'Advisory drift judge: reviewed predecessor objects are missing';end if;
 select md5(prosrc)into current from pg_proc where oid=to_regprocedure('public.property_video_job_qc_advisory(uuid,uuid,uuid,text)');
 if current is not null and current<>'c392cfade60f2c808958c610ae7aee5e'then raise exception'Advisory drift judge: an unreviewed property_video_job_qc_advisory exists';end if;
 select md5(prosrc)into current from pg_proc where oid=to_regprocedure('public.property_video_quality_judge_mode()');
 if current is not null and current<>'6c282c34a55aeebe931d849a412808ae'then raise exception'Advisory drift judge: an unreviewed property_video_quality_judge_mode exists';end if;
end$baseline$;

insert into public.app_config(key,value)values('property_video_quality_judge',jsonb_build_object('mode','advisory'))on conflict(key)do nothing;

create or replace function public.property_video_quality_judge_mode()returns text
language plpgsql stable security definer set search_path=''as $$begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 return case when(select value->>'mode'from public.app_config where key='property_video_quality_judge')='off'then'off'else'advisory'end;
end$$;

create or replace function public.property_video_job_qc_advisory(p_job uuid,p_lease uuid,p_attempt uuid,p_review text)returns jsonb
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;p public.media_provenance;bound public.property_video_sources;review text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_job is null or p_lease is null or p_attempt is null or p_review is null or p_review not in('judged','unknown','skipped')then raise exception'RP400: Use a closed advisory quality outcome';end if;
 select *into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt and lease_token=p_lease;
 if s.job_id is null then raise exception'RP409: A current shot lease is required';end if;
 if s.state='ready'then
  -- A repeated callback for the shot this same lease already finished: only
  -- its label is refreshed from the records. Stopped jobs still refuse.
  j:=public.property_video_job_scope(p_job,null,false);
  if j.cancelled_at is not null or j.state in('cancelled','needs_reconciliation')then raise exception'RP409: Stopped video work cannot accept a quality callback';end if;
 else
  -- Same fence as property_video_job_qc: live job, unchanged selected photos,
  -- this exact attempt under its current unexpired lease.
  perform public.property_video_job_worker_scope(p_job,p_lease,p_attempt);
 end if;
 select *into j from public.property_video_jobs where id=p_job;
 select *into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt and lease_token=p_lease for update;
 if s.job_id is null or s.state not in('quality_review','ready')or s.clip is null or s.receipt is null or s.generation_provenance_id is null then raise exception'RP409: This clip has no retained paid result under review';end if;
 -- The AI-disclosure record of this exact generation and its binding to the
 -- selected source photo stay mandatory, whatever the judge said.
 select *into p from public.media_provenance where id=s.generation_provenance_id and listing_id=j.listing_id and org_id=j.org_id;
 select *into bound from public.property_video_sources where request_id=s.receipt->>'request_id'and actor_id=j.actor_id and listing_id=j.listing_id and source_asset_id=s.asset_id and generation_provenance_id=p.id;
 if p.id is null or bound.request_id is null then raise exception'RP409: This clip has no disclosure record bound to its source photo';end if;
 -- The label comes from the saved judge records, never from the caller.
 -- 'passed' needs exactly what property_video_job_qc needs.
 review:=case
  when p.qc->>'request_id'=bound.request_id and p.qc->>'source_sha256'=bound.qc_source_hash and p.qc->>'publishable'='true'
   and exists(select 1 from public.cost_ledger where org_id=j.org_id and feature='qc'and meta->>'request_id'=bound.request_id and meta->>'publishable'='true'and total_cents>0)then'passed'
  when p.qc->>'request_id'=bound.request_id and p.qc->>'source_sha256'=bound.qc_source_hash and p.qc->>'publishable'='false'and p.qc->>'action'in('retry','refuse')then'failed'
  when p_review='skipped'then'skipped'
  else'unknown'end;
 update public.property_video_job_sources set state='ready',lease_until=null,
  last_error=case review when'passed'then null when'failed'then'quality_advisory_failed'when'skipped'then'quality_judge_off'else'quality_advisory_unknown'end
  where job_id=p_job and attempt_id=p_attempt;
 return jsonb_build_object('ready',true,'review',review,'enforcement','advisory');end$$;

-- CREATE OR REPLACE keeps the OID, owner, ACL and dependants.
create or replace function public.property_video_compose_snapshot(p_job uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;r public.app_video_cost_reservations;l public.cost_ledger;p public.media_provenance;b public.property_video_sources;v jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 j:=public.property_video_job_scope(p_job,null,false);
 if j.cancelled_at is not null or j.deadline<=now()or j.result is not null or j.output_asset_id is null or j.poster_asset_id is null or j.output_asset_id=j.poster_asset_id
  or exists(select 1 from public.property_video_job_outputs where job_id=p_job)
  or exists(select 1 from public.capture_assets where id in(j.output_asset_id,j.poster_asset_id))
  or(select count(*)from public.property_video_job_sources where job_id=p_job)<>j.source_count then return null;end if;
 for s in select *from public.property_video_job_sources where job_id=p_job order by position loop
  if s.state not in('ready','original_photo')or s.clip is null or s.receipt is null or s.attempt_id is null or s.generation_provenance_id is null
   or s.lease_until>now()or public.property_photo_reference(j.actor_id,j.listing_id,s.asset_id,s.photo_provenance_id)is distinct from s.source then return null;end if;
  select *into r from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key and feature='reel';
  if r.id is null or r.settled_at is null or r.released_at is not null or r.provider_request_id is distinct from s.receipt->>'request_id'or r.model is distinct from s.receipt->>'model_id'then return null;end if;
  select *into l from public.cost_ledger where id=r.cost_ledger_id and org_id=j.org_id and feature='reel'and provider=r.provider and model=r.model and total_cents>0
   and meta->>'app_video_reservation_id'=r.id::text and meta->>'request_id'=r.provider_request_id and meta->>'request_key'=r.idempotency_key and meta->>'stage'='reel';
  if l.id is null then return null;end if;
  select *into p from public.media_provenance where id=s.generation_provenance_id and org_id=j.org_id and listing_id=j.listing_id;
  select *into b from public.property_video_sources where request_id=r.provider_request_id and actor_id=j.actor_id and org_id=j.org_id and listing_id=j.listing_id
   and source_asset_id=s.asset_id and source_provenance_id is not distinct from s.photo_provenance_id and generation_provenance_id=p.id and input_sha256=s.source->>'sha256';
  if b.request_id is null then return null;end if;
  if s.state='original_photo'then
   v:=public.property_video_structural_rejection(p_job,s.attempt_id);
   if v is null or s.fallback_evidence is distinct from v then return null;end if;
  -- Advisory drift judge (12 Nov 2026): a ready clip no longer needs a passing
  -- judge receipt to be reassembled. Its paid generation, disclosure record and
  -- source binding above are still required; an original-photo shot still
  -- needs its confirmed structural rejection.
  end if;
 end loop;
 return jsonb_build_object('operation_id',j.operation_id,'manifest_sha256',j.manifest_sha256,'quality_profile',j.quality_profile,'deadline',j.deadline,'output_asset_id',j.output_asset_id,'poster_asset_id',j.poster_asset_id,
  'sources_sha256',(select encode(sha256(convert_to(jsonb_agg(to_jsonb(x)order by position)::text,'UTF8')),'hex')from public.property_video_job_sources x where job_id=p_job));end$$;

revoke all on function public.property_video_quality_judge_mode(),public.property_video_job_qc_advisory(uuid,uuid,uuid,text)from public,anon,authenticated;
grant execute on function public.property_video_quality_judge_mode(),public.property_video_job_qc_advisory(uuid,uuid,uuid,text)to service_role;
commit;
