-- Property video: the temporal motion check is ADVISORY (owner decision, 12 Nov 2026).
--
-- Policy, the same one the photo judge has had since 6 Nov 2026: perform the
-- action, record the verdict, the user reviews the result. A clip with a failed
-- motion verdict is used in the video; it must never pause, fail or strand a
-- job, never buy a generation and never be replaced by a still photo.
--
-- The worker (property-video-worker/engine.ts) no longer acts on the verdict.
-- This migration removes the one remaining SQL block: until now a job that had
-- ALREADY been paused by a failed motion verdict ("Video quality review
-- paused. Your paid clip is saved...") could not be resumed, because
-- property_video_terminal_temporal_refusal() made the Resume projection
-- (property_video_job_terminal_temporal_resume_block) answer "blocked" and
-- made the trigger property_video_terminal_temporal_cpu_guard refuse to put
-- the saved clip back into review. With the function answering false, the
-- existing owner Resume re-reviews the SAME saved, already-paid clip (CPU
-- re-extract plus the normal paid drift judge) and the job continues.
--
-- Unchanged: no generation is bought or repeated (Resume of a saved clip uses
-- quote 0 and the existing receipt checks in
-- property_video_job_resume_before_delivery_20261015); recorded verdicts stay
-- immutable; receipts, clips, reservations, cost ledger, provenance and
-- AI-disclosure rows, tenant and ownership checks, the job deadline, the paid
-- drift judge and the original-photo fallback rule (structural drift only) are
-- not touched. No table, trigger, ACL or other function changes.
--
-- Guarded and repeatable: it runs only when the function is the reviewed
-- production predecessor (first run) or already this exact body (repeat run,
-- which changes nothing). Anything else stops with an error.
-- Rollback (operator step; restores the block, so do it only together with the
-- previous property-video-worker): re-run the CREATE OR REPLACE FUNCTION
-- public.property_video_terminal_temporal_refusal statement from
-- 20261021212436_property_video_immutable_temporal_hold_resume.sql.
begin;
do $baseline$declare current text;begin
 if to_regprocedure('public.property_video_terminal_temporal_refusal(uuid,uuid,text)')is null
  or to_regprocedure('public.property_video_job_terminal_temporal_resume_block(uuid)')is null
  or to_regprocedure('public.property_video_terminal_temporal_cpu_guard()')is null then raise exception'Advisory temporal check: reviewed predecessor objects are missing';end if;
 select md5(prosrc)into current from pg_proc where oid='public.property_video_terminal_temporal_refusal(uuid,uuid,text)'::regprocedure;
 if current not in('da7d0caf1d357653374201c7a4259377','c3b2ab2f3ce8a72df3be5850b1da301b')then raise exception'Advisory temporal check: property_video_terminal_temporal_refusal changed since review';end if;
end$baseline$;

-- CREATE OR REPLACE keeps the OID, owner, ACL and both dependants.
create or replace function public.property_video_terminal_temporal_refusal(p_job uuid,p_attempt uuid,p_clip_sha256 text) returns boolean
language plpgsql stable security definer set search_path='' as $$begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 -- ADVISORY since the owner decision of 12 Nov 2026: a recorded temporal motion
 -- verdict is kept in property_video_job_temporal_verdicts and reported, and
 -- no longer refuses, pauses or blocks anything. Both callers (the Resume
 -- projection and the saved-clip re-review trigger) therefore stand aside.
 return false;
end$$;
commit;
