-- Classify an exhausted immutable motion-quality hold truthfully; do not
-- mistake it for missing/transient CPU work. No historical DML, threshold,
-- prompt, cap, retry route, trigger/projection body, owner or ACL change.
begin;
do $baseline$begin
 if(select md5(prosrc)from pg_proc where oid='public.property_video_terminal_temporal_refusal(uuid,uuid,text)'::regprocedure)is distinct from'546381bea5212de15af964fc79a1dbb5'
  or(select md5(prosrc)from pg_proc where oid='public.property_video_job_terminal_temporal_resume_block(uuid)'::regprocedure)is distinct from'ca314d1cabdcb77178c02b3ca803983d'
  or(select md5(prosrc)from pg_proc where oid='public.property_video_terminal_temporal_cpu_guard()'::regprocedure)is distinct from'39476f3f3096026326bd9cf348657057'
  or(select md5(prosrc)from pg_proc where oid='public.property_video_job_resume(uuid,uuid,numeric)'::regprocedure)is distinct from'121a22da639a891d762964ae72efb00b' then
  raise exception'Review changed immutable temporal hold authority';
 end if;
end$baseline$;

-- CREATE OR REPLACE keeps the existing OID, owner, ACL and trigger references.
-- The BEFORE trigger reads the OLD source row/count during actual Resume;
-- do not require a failed parent here: old Resume already set it generating.
create or replace function public.property_video_terminal_temporal_refusal(p_job uuid,p_attempt uuid,p_clip_sha256 text) returns boolean
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
   and (
    v.record#>'{verdict,reasons}' ?| array['walk_through_travel','horizon_roll','duplicate_frames','unmeasurable']
    or(s.cpu_attempts>=3
      and jsonb_typeof(v.record->'metrics')='object'and v.record#>>'{metrics,profile}'='temporal-motion-v2'
      and jsonb_typeof(v.record#>'{verdict,reasons}')='array'and v.record#>'{verdict,reasons}'<>'[]'::jsonb
      and not exists(select 1 from jsonb_array_elements(case when jsonb_typeof(v.record#>'{verdict,reasons}')='array'then v.record#>'{verdict,reasons}'else'[]'::jsonb end)r
       where jsonb_typeof(r)<>'string'or r#>>'{}'not in('vertical_bob','lateral_sway','walking_cadence','roll_wobble','zoom_pumping')))
   ));
end$$;
commit;
