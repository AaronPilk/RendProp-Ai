-- Fill the existing two-shot recipe window before polling long-running
-- supplier receipts. No new capacity, funding, retry or provider authority.
begin;
create or replace function public.property_video_job_claim(p_job uuid,p_worker text)returns jsonb language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;token uuid;active integer;begin
 if current_setting('role',true)is distinct from'service_role'or p_worker not in('slot-0','slot-1')then raise insufficient_privilege;end if;
 perform pg_advisory_xact_lock(hashtextextended('property-video-global-slots',79));j:=public.property_video_job_scope(p_job,null,true);
 perform 1 from public.property_video_jobs where id=p_job for update;
 -- Recheck afterlocking: cancellation cancommitwhilewaiting for this row.
 j:=public.property_video_job_scope(p_job,null,true);
 if(j.manifest->>'narration_asset_id'is not null or j.manifest->>'narration_result_id'is not null)and j.audio_preflight is null then
  if j.audio_until>now()then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
  if j.audio_attempts>=3 then update public.property_video_jobs set state='failed',message='The saved narration could not be decoded. Record or upload a valid audio take before creating a new video.'where id=p_job;return jsonb_build_object('action','done','job',to_jsonb(j));end if;
  token:=gen_random_uuid();update public.property_video_jobs set state='queued',audio_lease=token,audio_until=now()+interval'5 minutes',audio_attempts=audio_attempts+1 where id=p_job returning * into j;return jsonb_build_object('action','inspect_audio','job',to_jsonb(j));end if;
 select * into s from public.property_video_job_sources where job_id=p_job and state='processing'and clip is not null and(cpu_attempts<3)and(lease_until is null or lease_until<=now())order by position for update skip locked limit 1;
 if s.job_id is not null then token:=gen_random_uuid();update public.property_video_job_sources set state='quality_review',lease_token=token,lease_until=now()+interval'5 minutes',cpu_attempts=cpu_attempts+1 where job_id=p_job and position=s.position returning * into s;
  return jsonb_build_object('action','extract_frames','job',to_jsonb(j),'source',to_jsonb(s));end if;
 if not exists(select 1 from public.property_video_job_sources where job_id=p_job and state not in('ready','original_photo'))then
  if j.compose_until>now()then return jsonb_build_object('action','wait','job',to_jsonb(j));end if;
  if j.compose_attempts>=3 then update public.property_video_jobs set state='failed',message='The video could not be assembled. Your saved photos are safe.'where id=p_job;return jsonb_build_object('action','done','job',to_jsonb(j));end if;
  token:=gen_random_uuid();update public.property_video_jobs set state='composing',compose_lease=token,compose_until=now()+interval'10 minutes',compose_attempts=compose_attempts+1,output_asset_id=gen_random_uuid(),poster_asset_id=gen_random_uuid(),updated_at=now()where id=p_job returning * into j;
  return jsonb_build_object('action','compose','job',to_jsonb(j),'sources',(select jsonb_agg(to_jsonb(x)order by position)from public.property_video_job_sources x where job_id=p_job));end if;
 select count(*)into active from public.property_video_job_sources src join public.property_video_jobs vj on vj.id=src.job_id where src.state in('dispatching','processing','quality_review','ambiguous')and src.provider_terminal_at is null and vj.deadline>now()and(vj.state<>'cancelled'or src.receipt is not null or exists(select 1 from public.app_video_cost_reservations r where r.actor_id=vj.actor_id and r.org_id=vj.org_id and r.idempotency_key=src.request_key and r.released_at is null));
 if active>=4 or(select count(*)from public.property_video_job_sources where job_id=p_job and state in('dispatching','processing','quality_review','ambiguous'))>=2 then
  null; -- Full supplier capacity must not prevent polling accepted receipts.
 elsif
 coalesce((select count from public.rate_limits where key='aivideo:'||public.library_actor_billing_org(j.actor_id,j.org_id)and window_start+window_seconds*interval'1 second'>now()),0)>=20 then
  null; -- Polling is free; the paid helper still charges the same burst gate.
 else
 select * into s from public.property_video_job_sources where job_id=p_job and state='pending'order by position for update skip locked limit 1;
 if s.job_id is not null then
 token:=gen_random_uuid();update public.property_video_job_sources set state='dispatching',attempt_id=gen_random_uuid(),lease_token=token,lease_until=now()+interval'5 minutes'where job_id=p_job and position=s.position returning * into s;
 update public.property_video_job_sources set request_key='bgvideo:'||attempt_id where job_id=p_job and position=s.position returning * into s;
 update public.property_video_jobs set state='generating',updated_at=now()where id=p_job;
 return jsonb_build_object('action','dispatch','job',to_jsonb(j),'source',to_jsonb(s));
 end if;
 end if;
 -- Give every accepted nonterminal receipt a turn. Record the claim time,
 -- including unsuccessful status attempts, so a slow first source cannot
 -- indefinitely starve a second accepted source. The current lease still
 -- prevents overlapping status calls for one attempt.
 select * into s from public.property_video_job_sources where job_id=p_job and state='processing'and clip is null and(lease_until is null or lease_until<=now())order by provider_status_checked_at nulls first,position for update skip locked limit 1;
 if s.job_id is not null then token:=gen_random_uuid();update public.property_video_job_sources set lease_token=token,lease_until=now()+interval'5 minutes',provider_status_checked_at=clock_timestamp()where job_id=p_job and position=s.position returning * into s;return jsonb_build_object('action','poll','job',to_jsonb(j),'source',to_jsonb(s));end if;
 return jsonb_build_object('action','wait','job',to_jsonb(j));end$$;

revoke all on function public.property_video_job_claim(uuid,text) from public,anon,authenticated;
grant execute on function public.property_video_job_claim(uuid,text) to service_role;
commit;
