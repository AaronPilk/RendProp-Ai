-- Honor the EXISTING paid terminal drift decision once, not a transport retry.
-- The normal generation helper still admits each new attempt against real funds.
begin;
alter table public.property_video_job_sources add column if not exists quality_retries integer not null default 0 check(quality_retries between 0 and 1);
alter table public.property_video_job_sources add column if not exists quality_retry_history jsonb not null default'[]'::jsonb check(jsonb_typeof(quality_retry_history)='array');
create or replace function public.property_video_quality_retry_evidence(p_job uuid,p_attempt uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;p public.media_provenance;b public.property_video_sources;r public.app_video_cost_reservations;paid public.cost_ledger;c public.app_video_drift_checks;ledgers jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select *into j from public.property_video_jobs where id=p_job;select *into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt;
 if j.id is null or s.job_id is null or s.clip is null or s.receipt is null or s.generation_provenance_id is null then return null;end if;
 select *into p from public.media_provenance where id=s.generation_provenance_id and org_id=j.org_id and listing_id=j.listing_id;
 select *into b from public.property_video_sources where request_id=s.receipt->>'request_id'and actor_id=j.actor_id and org_id=j.org_id and listing_id=j.listing_id and source_asset_id=s.asset_id and source_provenance_id is not distinct from s.photo_provenance_id and generation_provenance_id=p.id and input_sha256=s.source->>'sha256';
 if b.request_id is null or p.qc->>'task'is distinct from'judge.qc_drift'or p.qc->>'request_id'is distinct from b.request_id or p.qc->>'source_sha256'is distinct from b.qc_source_hash
  or p.qc->>'action'is distinct from'retry'or p.qc->'publishable'is distinct from'false'::jsonb or coalesce(p.qc->>'verdict','')not in('fail','regen')or p.qc->'attempt'is distinct from'0'::jsonb or jsonb_typeof(p.qc->'failed')is distinct from'array'or jsonb_array_length(p.qc->'failed')=0 then return null;end if;
 select *into r from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and feature='reel'and idempotency_key=s.request_key and provider_request_id=b.request_id and model=s.receipt->>'model_id'and settled_at is not null and released_at is null;
 select *into paid from public.cost_ledger where id=r.cost_ledger_id and org_id=j.org_id and feature='reel'and provider=r.provider and model=r.model and total_cents>0
  and meta->>'app_video_reservation_id'=r.id::text and meta->>'request_id'=b.request_id and meta->>'request_key'=r.idempotency_key and meta->>'stage'='reel';
 if r.id is null or paid.id is null then return null;end if;
 select *into c from public.app_video_drift_checks where reservation_id=r.id and actor_id=j.actor_id and org_id=j.org_id and listing_id=j.listing_id and source_sha256=b.qc_source_hash and state='retry'
  and result#>>'{drift,action}'='retry'and result#>'{drift,publishable}'='false'::jsonb and result#>'{drift,attempt}'='0'::jsonb and result#>'{drift,failed}'=p.qc->'failed';
 if c.reservation_id is null then return null;end if;
 select jsonb_agg(id order by created_at,id)into ledgers from public.cost_ledger where org_id=j.org_id and feature='qc'and total_cents>0 and meta->>'kind'='video_drift'
  and meta->>'request_id'=b.request_id and meta->>'provenance_id'=p.id::text and meta->>'source_asset_id'=s.asset_id::text and meta->>'source_sha256'=b.qc_source_hash
  and meta->>'action'='retry'and meta->'publishable'='false'::jsonb and meta->'attempt'='0'::jsonb and meta->>'verdict'=p.qc->>'verdict'and meta->'failed'=p.qc->'failed';
 if ledgers is null then return null;end if;
 return jsonb_build_object('paid_reservation_id',r.id,'paid_ledger_id',paid.id,'qc_check_id',c.check_id,'qc_ledger_ids',ledgers,'provenance_id',p.id,'source_asset_id',s.asset_id,'source_sha256',b.qc_source_hash,'request_id',b.request_id,'verdict',p.qc,'action','retry');end$$;

create or replace function public.property_video_quality_history_guard()returns trigger
language plpgsql security definer set search_path=''as $$declare i integer;begin
 if new.quality_retries<old.quality_retries then raise exception'RP409: A paid quality retry cannot be reset';end if;
 if new.quality_retry_history is distinct from old.quality_retry_history or new.quality_retries<>old.quality_retries then
  if new.quality_retries<>old.quality_retries+1 or jsonb_array_length(new.quality_retry_history)<>jsonb_array_length(old.quality_retry_history)+1 then raise exception'RP409: Quality retry history is append-only';end if;
  for i in 0..jsonb_array_length(old.quality_retry_history)-1 loop if new.quality_retry_history->i is distinct from old.quality_retry_history->i then raise exception'RP409: Prior paid retry evidence is immutable';end if;end loop;
  if public.property_video_quality_retry_evidence(old.job_id,old.attempt_id)is null or(new.quality_retry_history->-1)->'prior_source'is distinct from(to_jsonb(old)-'quality_retry_history')or(new.quality_retry_history->-1)->'quality_grant'is distinct from public.property_video_quality_retry_evidence(old.job_id,old.attempt_id)then raise exception'RP409: A paid retry must retain its exact current source and grant';end if;
 end if;return new;end$$;
drop trigger if exists property_video_quality_history_guard on public.property_video_job_sources;
create trigger property_video_quality_history_guard before update of quality_retries,quality_retry_history on public.property_video_job_sources for each row execute function public.property_video_quality_history_guard();

create or replace function public.property_video_job_quality_retry(p_job uuid,p_lease uuid,p_attempt uuid)returns jsonb
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;grant_evidence jsonb;begin
 j:=public.property_video_job_scope(p_job,null,false);select *into j from public.property_video_jobs where id=p_job for update;
 -- Lost replies acknowledge the exact old operation without resetting a newer
 -- accepted attempt or touching either paid receipt.
 select *into s from public.property_video_job_sources x where x.job_id=p_job and exists(select 1 from jsonb_array_elements(x.quality_retry_history)h where h#>>'{prior_source,attempt_id}'=p_attempt::text and h#>>'{prior_source,lease_token}'=p_lease::text);
 if s.job_id is not null then return jsonb_build_object('retry_scheduled',true,'replay',true,'job_id',p_job,'position',s.position);end if;
 if j.cancelled_at is not null or j.deadline<=now()or j.state not in('queued','generating','quality_review','failed')then raise exception'RP409: Stopped video work cannot retry a supplier';end if;
 select *into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt for update;
 if s.job_id is null or s.lease_token is distinct from p_lease or s.quality_retries>=1 or not((s.state='quality_review'and s.lease_until>now())or(s.state='failed'and s.last_error='quality_check_refused'and s.lease_until is null))then raise exception'RP409: This clip has no current single quality retry';end if;
 if public.property_photo_reference(j.actor_id,j.listing_id,s.asset_id,s.photo_provenance_id)is distinct from s.source then raise exception'RP409: The selected source changed or was withdrawn';end if;
 grant_evidence:=public.property_video_quality_retry_evidence(p_job,p_attempt);if grant_evidence is null then raise exception'RP409: A terminal paid same-source retry grant is required';end if;
 update public.property_video_job_sources set quality_retry_history=quality_retry_history||jsonb_build_array(jsonb_build_object('prior_source',to_jsonb(s)-'quality_retry_history','quality_grant',grant_evidence,'retried_at',now())),quality_retries=quality_retries+1,
  state='pending',motion='push_in',attempt_id=null,request_key=null,receipt=null,clip=null,generation_provenance_id=null,lease_token=null,lease_until=null,cpu_attempts=0,cpu_recoveries=0,provider_terminal_at=null,provider_status_checked_at=null,admission_retries=0,last_error=null,fallback_evidence=null
  where job_id=p_job and position=s.position;
 update public.property_video_jobs set state='generating',message='The saved quality check requested one safer camera move. The next clip still requires normal processing capacity.',updated_at=now()where id=p_job;
 return jsonb_build_object('retry_scheduled',true,'replay',false,'job_id',p_job,'position',s.position);end$$;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.property_video_job_resume(uuid,uuid,numeric)'::regprocedure)not in('59bf3e874a3ca13403af4f35b981a13b','2d9d03d1f198e86ba47afebd88022f2c')then raise exception'Review changed retained-video recovery authority';end if;end$$;
create or replace function public.property_video_job_resume(p_actor uuid,p_job uuid,p_quote numeric)returns public.property_video_jobs language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;n integer;recoverable integer;retry_source public.property_video_job_sources;begin
 j:=public.property_video_job_scope(p_job,p_actor,false);select * into j from public.property_video_jobs where id=p_job for update;
 -- Recover the old worker's terminal-retry pause through the ordinary owner
 -- action, using exactly the same paid grant and one-transition RPC as a worker.
 if j.state='failed'and j.cancelled_at is null and j.deadline>now()
  and exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and s.state='failed'and s.last_error='quality_check_refused'and s.quality_retries=0 and public.property_video_quality_retry_evidence(p_job,s.attempt_id)is not null)
  and not exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and(s.state='ambiguous'or(s.state='failed'and(s.last_error<>'quality_check_refused'or s.quality_retries>=1 or public.property_video_quality_retry_evidence(p_job,s.attempt_id)is null))))then
  for retry_source in select *from public.property_video_job_sources where job_id=p_job and state='failed'and last_error='quality_check_refused'loop perform public.property_video_job_quality_retry(p_job,retry_source.lease_token,retry_source.attempt_id);end loop;
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

revoke all on function public.property_video_quality_history_guard(),public.property_video_quality_retry_evidence(uuid,uuid),public.property_video_job_quality_retry(uuid,uuid,uuid),public.property_video_job_resume(uuid,uuid,numeric)from public,anon,authenticated;
grant execute on function public.property_video_quality_history_guard(),public.property_video_quality_retry_evidence(uuid,uuid),public.property_video_job_quality_retry(uuid,uuid,uuid),public.property_video_job_resume(uuid,uuid,numeric)to service_role;
commit;
