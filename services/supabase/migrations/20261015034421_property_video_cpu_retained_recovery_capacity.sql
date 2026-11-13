-- More explicit CPU-only recovery capacity after proven platform startup errors.
-- No supplier retry, funding, receipt, source, deadline or automatic work changes.
begin;
do $$begin if(select md5(prosrc)from pg_proc where oid='public.property_video_job_resume(uuid,uuid,numeric)'::regprocedure)not in('736c8d085d0ef5ab27126d3b4fcfd8b1','59bf3e874a3ca13403af4f35b981a13b')then raise exception'Review changed retained-video CPU recovery authority';end if;end$$;
alter table public.property_video_job_sources drop constraint if exists property_video_job_sources_cpu_recoveries_check;
alter table public.property_video_job_sources add constraint property_video_job_sources_cpu_recoveries_check check(cpu_recoveries between 0 and 5);

create or replace function public.property_video_job_resume(p_actor uuid,p_job uuid,p_quote numeric)returns public.property_video_jobs language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;n integer;recoverable integer;begin
 j:=public.property_video_job_scope(p_job,p_actor,false);select * into j from public.property_video_jobs where id=p_job for update;
 -- Explicit local-quality recovery reuses the accepted supplier output.
 -- At most five user-requested CPU recovery cycles fit within the same deadline.
 select count(*)into recoverable from public.property_video_job_sources s where s.job_id=p_job and s.state in('failed','original_photo','quality_review')
  and s.last_error in('cpu_extract_failed','quality_check_refused','quality_check_unconfirmed')and s.clip is not null and s.receipt is not null and s.generation_provenance_id is not null
  and s.cpu_recoveries<5 and(s.state<>'quality_review'or s.lease_until is null or s.lease_until<=now())
  and public.property_video_structural_rejection(s.job_id,s.attempt_id)is null;
 if recoverable>0 then
  if j.state not in('queued','generating','quality_review','composing','failed')or j.cancelled_at is not null or j.deadline<=now()
   or exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and(s.state='ambiguous'or(s.state='failed'and(s.last_error not in('cpu_extract_failed','quality_check_refused','quality_check_unconfirmed')or s.clip is null or s.receipt is null or s.generation_provenance_id is null or s.cpu_recoveries>=5))))then raise exception'RP409: This saved video is not a safely recoverable quality pause';end if;
  if exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and public.property_photo_reference(j.actor_id,j.listing_id,s.asset_id,s.photo_provenance_id)is distinct from s.source)then raise exception'RP409: A selected photo changed or was withdrawn';end if;
  if exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and s.state in('failed','original_photo','quality_review')and s.last_error in('cpu_extract_failed','quality_check_refused','quality_check_unconfirmed')and not exists(
   select 1 from public.app_video_cost_reservations r join public.property_video_sources b on b.request_id=r.provider_request_id where r.actor_id=j.actor_id and r.org_id=j.org_id and r.idempotency_key=s.request_key and r.settled_at is not null and r.released_at is null and r.provider_request_id=s.receipt->>'request_id'and r.model=s.receipt->>'model_id'
    and b.actor_id=j.actor_id and b.org_id=j.org_id and b.listing_id=j.listing_id and b.source_asset_id=s.asset_id and b.generation_provenance_id=s.generation_provenance_id and b.input_sha256=s.source->>'sha256'))then raise exception'RP409: The retained paid clip has no matching source authority';end if;
  update public.property_video_job_sources set state='processing',cpu_recoveries=cpu_recoveries+1,
   cpu_recovery_history=cpu_recovery_history||jsonb_build_array(jsonb_build_object('attempt_id',attempt_id,'request_key',request_key,'clip_sha256',clip->>'sha256','previous_state',state,'cpu_attempts',cpu_attempts,'reason',last_error,'recovered_at',now(),'compose_lease',j.compose_lease,'compose_attempts',j.compose_attempts)),
   cpu_attempts=0,lease_token=null,lease_until=null,last_error=null,fallback_evidence=null
   where job_id=p_job and state in('failed','original_photo','quality_review')and last_error in('cpu_extract_failed','quality_check_refused','quality_check_unconfirmed')and clip is not null and receipt is not null and generation_provenance_id is not null and cpu_recoveries<5
    and(state<>'quality_review'or lease_until is null or lease_until<=now())and public.property_video_structural_rejection(job_id,attempt_id)is null;
  update public.property_video_jobs set state='generating',message=null,compose_lease=null,compose_until=null,compose_attempts=0,updated_at=now()where id=p_job returning * into j;return j;
 end if;
 if j.state in('queued','generating','quality_review','composing','ready')then return j;end if;
 if j.state<>'failed'or j.cancelled_at is not null or j.deadline<=now()or not exists(select 1 from public.property_video_job_sources where job_id=p_job and state='failed'and last_error='capacity_before_dispatch')or exists(select 1 from public.property_video_job_sources where job_id=p_job and(state='ambiguous'or(state='failed'and(last_error<>'capacity_before_dispatch'or receipt is not null or admission_retries>=3))))then raise exception'RP409: This saved video is not a safely resumable capacity pause';end if;
 if exists(select 1 from public.property_video_job_sources s join public.app_video_cost_reservations r on r.actor_id=j.actor_id and r.org_id=j.org_id and r.idempotency_key=s.request_key where s.job_id=p_job and s.state='failed'and r.released_at is null)then raise exception'RP409: An unsettled supplier attempt cannot be restarted';end if;
 select count(*)into n from public.property_video_job_sources where job_id=p_job and state in('pending','failed');perform public.property_video_recipe_capacity(p_actor,j.listing_id,n,p_quote);
 update public.property_video_job_sources set state='pending',admission_retries=admission_retries+1,non_dispatch_history=non_dispatch_history||jsonb_build_array(jsonb_build_object('attempt_id',attempt_id,'request_key',request_key,'reason',last_error)),attempt_id=null,lease_token=null,lease_until=null,request_key=null,last_error=null where job_id=p_job and state='failed'and last_error='capacity_before_dispatch';
 update public.property_video_jobs set state='generating',message=null,updated_at=now()where id=p_job returning * into j;return j;end$$;

revoke all on function public.property_video_job_resume(uuid,uuid,numeric)from public,anon,authenticated;
grant execute on function public.property_video_job_resume(uuid,uuid,numeric)to service_role;
commit;
