-- Honor the server-derived failed-axis retry even if the model summary says
-- pass. This cannot approve output, rerun QC, or bypass the normal paid retry.
begin;
do $$begin
 if(select md5(prosrc)from pg_proc where oid='public.property_video_quality_retry_evidence(uuid,uuid)'::regprocedure)not in('47f95b2153f43b1621579642e2dbbaca','a33ac73339ee6cdf20854da94b7bf924')then
  raise exception'Review changed paid quality retry authority';
 end if;
end$$;
create or replace function public.property_video_quality_retry_evidence(p_job uuid,p_attempt uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;p public.media_provenance;b public.property_video_sources;r public.app_video_cost_reservations;paid public.cost_ledger;c public.app_video_drift_checks;ledgers jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select *into j from public.property_video_jobs where id=p_job;select *into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt;
 if j.id is null or s.job_id is null or s.clip is null or s.receipt is null or s.generation_provenance_id is null then return null;end if;
 select *into p from public.media_provenance where id=s.generation_provenance_id and org_id=j.org_id and listing_id=j.listing_id;
 select *into b from public.property_video_sources where request_id=s.receipt->>'request_id'and actor_id=j.actor_id and org_id=j.org_id and listing_id=j.listing_id and source_asset_id=s.asset_id and source_provenance_id is not distinct from s.photo_provenance_id and generation_provenance_id=p.id and input_sha256=s.source->>'sha256';
 if b.request_id is null or p.qc->>'task'is distinct from'judge.qc_drift'or p.qc->>'request_id'is distinct from b.request_id or p.qc->>'source_sha256'is distinct from b.qc_source_hash
  or p.qc->>'action'is distinct from'retry'or p.qc->'publishable'is distinct from'false'::jsonb or coalesce(p.qc->>'verdict','')not in('pass','fail','regen')or p.qc->'attempt'is distinct from'0'::jsonb or jsonb_typeof(p.qc->'failed')is distinct from'array'or jsonb_array_length(p.qc->'failed')=0 then return null;end if;
 select *into r from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and feature='reel'and idempotency_key=s.request_key and provider_request_id=b.request_id and model=s.receipt->>'model_id'and settled_at is not null and released_at is null;
 select *into paid from public.cost_ledger where id=r.cost_ledger_id and org_id=j.org_id and feature='reel'and provider=r.provider and model=r.model and total_cents>0
  and meta->>'app_video_reservation_id'=r.id::text and meta->>'request_id'=b.request_id and meta->>'request_key'=r.idempotency_key and meta->>'stage'='reel';
 if r.id is null or paid.id is null then return null;end if;
 select *into c from public.app_video_drift_checks where reservation_id=r.id and actor_id=j.actor_id and org_id=j.org_id and listing_id=j.listing_id and source_sha256=b.qc_source_hash and state='retry'
  and result#>>'{drift,action}'='retry'and result#>'{drift,publishable}'='false'::jsonb and result#>'{drift,attempt}'='0'::jsonb and result#>'{drift,failed}'=p.qc->'failed'
  -- A summary pass can still fail the server's independent axis gates. Only
  -- the matching terminal failed decision, not that raw word, grants retry.
  and(p.qc->>'verdict'<>'pass'or(result#>>'{drift,status}'='fail'and result#>>'{drift,verdict}'='pass'
   and result#>'{drift,scores}'=p.qc->'scores'and result#>'{drift,thresholds}'=p.qc->'thresholds'));
 if c.reservation_id is null then return null;end if;
 select jsonb_agg(id order by created_at,id)into ledgers from public.cost_ledger where org_id=j.org_id and feature='qc'and total_cents>0 and meta->>'kind'='video_drift'
  and meta->>'request_id'=b.request_id and meta->>'provenance_id'=p.id::text and meta->>'source_asset_id'=s.asset_id::text and meta->>'source_sha256'=b.qc_source_hash
  and meta->>'action'='retry'and meta->'publishable'='false'::jsonb and meta->'attempt'='0'::jsonb and meta->>'verdict'=p.qc->>'verdict'and meta->'failed'=p.qc->'failed'
  and(p.qc->>'verdict'<>'pass'or meta->'scores'=p.qc->'scores');
 if ledgers is null then return null;end if;
 return jsonb_build_object('paid_reservation_id',r.id,'paid_ledger_id',paid.id,'qc_check_id',c.check_id,'qc_ledger_ids',ledgers,'provenance_id',p.id,'source_asset_id',s.asset_id,'source_sha256',b.qc_source_hash,'request_id',b.request_id,'verdict',p.qc,'action','retry');end$$;

do $$begin
 if to_regprocedure('public.property_video_job_quality_resume_available(uuid)')is not null
  and(select md5(prosrc)from pg_proc where oid=to_regprocedure('public.property_video_job_quality_resume_available(uuid)'))is distinct from'c3c6136977acb084e645217806b526bb'then
  raise exception'Review changed quality resume projection';
 end if;
end$$;
create or replace function public.property_video_job_quality_resume_available(p_job uuid)returns boolean
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;candidate public.property_video_job_sources;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 j:=public.property_video_job_scope(p_job,null,false);
 if j.state='failed'and j.cancelled_at is null and j.deadline>now()
  and exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and s.quality_retries=0
   and((s.state='failed'and s.last_error='quality_check_refused')or(s.state='quality_review'and s.cpu_attempts>=3 and s.lease_until<=now()))
   and public.property_video_quality_retry_evidence(p_job,s.attempt_id)is not null)
  and not exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and(s.state='ambiguous'
   or(s.state='failed'and(s.last_error<>'quality_check_refused'or s.quality_retries>=1 or public.property_video_quality_retry_evidence(p_job,s.attempt_id)is null))
   or(s.state='quality_review'and(s.lease_until is null or s.lease_until>now()or s.cpu_attempts<3 or s.quality_retries>=1 or public.property_video_quality_retry_evidence(p_job,s.attempt_id)is null))))then
  for candidate in select *from public.property_video_job_sources where job_id=p_job and((state='failed'and last_error='quality_check_refused')or(state='quality_review'and cpu_attempts>=3 and lease_until<=now()))loop
   if public.property_photo_reference(j.actor_id,j.listing_id,candidate.asset_id,candidate.photo_provenance_id)is distinct from candidate.source then return false;end if;
  end loop;
  return true;
 end if;return false;end$$;

do $$begin
 if(select md5(prosrc)from pg_proc where oid='public.property_video_job_resume(uuid,uuid,numeric)'::regprocedure)not in('2d9d03d1f198e86ba47afebd88022f2c','b732f83b09e2e37462616f548d229bb5')then
  raise exception'Review changed retained paid retry recovery authority';
 end if;
end$$;
create or replace function public.property_video_job_resume(p_actor uuid,p_job uuid,p_quote numeric)returns public.property_video_jobs language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;n integer;recoverable integer;retry_source public.property_video_job_sources;grant_evidence jsonb;begin
 j:=public.property_video_job_scope(p_job,p_actor,false);select * into j from public.property_video_jobs where id=p_job for update;
 -- Explicit owner recovery may consume an already-terminal paid retry after
 -- the old callback exhausted extraction leases. It does not repeat QC or
 -- dispatch anything; the next claim still uses normal paid admission.
 if public.property_video_job_quality_resume_available(p_job)then
  for retry_source in select *from public.property_video_job_sources where job_id=p_job and((state='failed'and last_error='quality_check_refused')or(state='quality_review'and cpu_attempts>=3 and lease_until<=now()))order by position for update loop
   if public.property_photo_reference(j.actor_id,j.listing_id,retry_source.asset_id,retry_source.photo_provenance_id)is distinct from retry_source.source then raise exception'RP409: The selected source changed or was withdrawn';end if;
   grant_evidence:=public.property_video_quality_retry_evidence(p_job,retry_source.attempt_id);
   if grant_evidence is null then raise exception'RP409: A terminal paid same-source retry grant is required';end if;
   -- Same append-only transition as property_video_job_quality_retry. Keep
   -- the job failed until every eligible row is validated and archived so a
   -- second expired row cannot lose the original stopped-job authority.
 update public.property_video_job_sources set quality_retry_history=quality_retry_history||jsonb_build_array(jsonb_build_object('prior_source',to_jsonb(retry_source)-'quality_retry_history','quality_grant',grant_evidence,'retried_at',now())),quality_retries=quality_retries+1,
  state='pending',motion='push_in',attempt_id=null,request_key=null,receipt=null,clip=null,generation_provenance_id=null,lease_token=null,lease_until=null,cpu_attempts=0,cpu_recoveries=0,provider_terminal_at=null,provider_status_checked_at=null,admission_retries=0,last_error=null,fallback_evidence=null
  where job_id=p_job and position=retry_source.position;
  end loop;
  update public.property_video_jobs set state='generating',message='The saved quality check requested one safer camera move. The next clip still requires normal processing capacity.',updated_at=now()where id=p_job;
  return public.property_video_job_scope(p_job,p_actor,false);
 end if;
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


revoke all on function public.property_video_quality_retry_evidence(uuid,uuid),public.property_video_job_resume(uuid,uuid,numeric),public.property_video_job_quality_resume_available(uuid)from public,anon,authenticated;
grant execute on function public.property_video_quality_retry_evidence(uuid,uuid),public.property_video_job_resume(uuid,uuid,numeric),public.property_video_job_quality_resume_available(uuid)to service_role;
commit;
