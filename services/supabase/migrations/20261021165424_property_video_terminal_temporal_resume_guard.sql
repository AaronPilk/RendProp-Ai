-- A first, immutable terminal motion verdict is not a transient CPU failure.
-- Preserve the existing paid-retry authority and all old resume bodies; stop
-- only re-entry of the same retained failed clip into processing.
begin;
do $baseline$begin
 if (select md5(prosrc) from pg_proc where oid='public.property_video_job_resume(uuid,uuid,numeric)'::regprocedure) is distinct from '121a22da639a891d762964ae72efb00b'
  or (select md5(prosrc) from pg_proc where oid='public.property_video_job_resume_before_delivery_20261015(uuid,uuid,numeric)'::regprocedure) is distinct from 'b732f83b09e2e37462616f548d229bb5'
  or (select md5(prosrc) from pg_proc where oid='public.property_video_job_quality_resume_available(uuid)'::regprocedure) is distinct from 'c3c6136977acb084e645217806b526bb' then
  raise exception 'Review changed saved-video resume authority';
 end if;
 if to_regprocedure('public.property_video_terminal_temporal_refusal(uuid,uuid,text)') is not null
  or to_regprocedure('public.property_video_job_terminal_temporal_resume_block(uuid)') is not null
  or to_regprocedure('public.property_video_terminal_temporal_cpu_guard()') is not null
  or exists(select 1 from pg_trigger where tgrelid='public.property_video_job_sources'::regclass and tgname='property_video_terminal_temporal_cpu_guard' and not tgisinternal) then
  raise exception 'Review existing terminal-temporal resume guard objects';
 end if;
end$baseline$;

-- Match the current shot/paid attempt/retained clip and the unchanged worker
-- limit identity. Foreign/historical clips or unknown reports grant nothing.
create function public.property_video_terminal_temporal_refusal(p_job uuid,p_attempt uuid,p_clip_sha256 text) returns boolean
language plpgsql stable security definer set search_path='' as $$begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 return exists(select 1 from public.property_video_job_sources s
  join public.property_video_job_temporal_verdicts v on v.job_id=s.job_id and v.position=s.position and v.attempt_id=s.attempt_id
  where s.job_id=p_job and s.attempt_id=p_attempt and s.clip->>'sha256'=p_clip_sha256
   and v.limits_sha256='244436b765886f537bd6d3b835dc42ca06cc758dc1a3b796028aae448b21d555'
   and v.record->>'clip_sha256'=p_clip_sha256 and v.record->>'attempt_id'=p_attempt::text
   and v.record->>'profile'='temporal-motion-v2' and v.record#>>'{verdict,profile}'='temporal-motion-v2'
   and v.record#>>'{limits,sha256}'=v.limits_sha256 and v.record#>>'{limits,profile}'='temporal-motion-v2'
   and v.record#>'{verdict,pass}'='false'::jsonb
   and v.record#>'{verdict,reasons}' ?| array['walk_through_travel','horizon_roll','duplicate_frames','unmeasurable']);
end$$;

-- One read-only projection for both status and HTTP Resume preflight. A
-- separately proven existing paid quality-retry grant keeps its old route;
-- this does not create a grant, authorize a purchase or change any verdict.
create function public.property_video_job_terminal_temporal_resume_block(p_job uuid) returns boolean
language plpgsql stable security definer set search_path='' as $$declare j public.property_video_jobs;begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 j:=public.property_video_job_scope(p_job,null,false);
 if j.state<>'failed' or j.cancelled_at is not null then return false;end if;
 if public.property_video_job_quality_resume_available(p_job) then return false;end if;
 return exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and s.state in('failed','original_photo','quality_review')
  and public.property_video_terminal_temporal_refusal(s.job_id,s.attempt_id,s.clip->>'sha256'));
end$$;

-- The actual service RPC's old CPU branch updates this row while holding the
-- job/source locks. A stale client or direct RPC cannot bypass the projection.
-- Any refusal rolls back the whole old resume transaction, including siblings.
create function public.property_video_terminal_temporal_cpu_guard() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if new.state='processing' and old.state in('failed','original_photo','quality_review')
  and public.property_video_terminal_temporal_refusal(old.job_id,old.attempt_id,old.clip->>'sha256') then
  raise exception 'RP409: This generated clip failed the motion-quality check. Its saved result cannot be resumed as a processing retry.';
 end if;
 return new;
end$$;
create trigger property_video_terminal_temporal_cpu_guard before update of state,cpu_recoveries on public.property_video_job_sources
 for each row execute function public.property_video_terminal_temporal_cpu_guard();
revoke all on function public.property_video_terminal_temporal_refusal(uuid,uuid,text),public.property_video_job_terminal_temporal_resume_block(uuid),public.property_video_terminal_temporal_cpu_guard() from public,anon,authenticated;
grant execute on function public.property_video_terminal_temporal_refusal(uuid,uuid,text),public.property_video_job_terminal_temporal_resume_block(uuid),public.property_video_terminal_temporal_cpu_guard() to service_role;
commit;
