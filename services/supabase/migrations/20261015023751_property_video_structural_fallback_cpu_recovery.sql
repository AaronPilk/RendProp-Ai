-- A local CPU/provider transport failure is not a visual property change.
-- Retain paid attempts and require terminal, paid, exact-source QC authority.
alter table public.property_video_job_sources add column if not exists cpu_recoveries integer not null default 0 check(cpu_recoveries between 0 and 2);
alter table public.property_video_job_sources add column if not exists cpu_recovery_history jsonb not null default '[]'::jsonb check(jsonb_typeof(cpu_recovery_history)='array');
alter table public.property_video_job_sources add column if not exists fallback_evidence jsonb;

create or replace function public.property_video_structural_rejection(p_job uuid,p_attempt uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;p public.media_provenance;b public.property_video_sources;q public.cost_ledger;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into j from public.property_video_jobs where id=p_job;
 select * into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt;
 if j.id is null or s.job_id is null or s.clip is null or s.receipt is null or not coalesce((j.manifest->>'allow_original_photo_fallback')::boolean,false)then return null;end if;
 select * into p from public.media_provenance where id=s.generation_provenance_id and org_id=j.org_id and listing_id=j.listing_id;
 select * into b from public.property_video_sources where request_id=s.receipt->>'request_id'and actor_id=j.actor_id and org_id=j.org_id and listing_id=j.listing_id
  and source_asset_id=s.asset_id and source_provenance_id is not distinct from s.photo_provenance_id and generation_provenance_id=p.id and input_sha256=s.source->>'sha256';
 if b.request_id is null or p.qc->>'request_id'is distinct from b.request_id or p.qc->>'source_sha256'is distinct from b.qc_source_hash
  or p.qc->>'task'is distinct from'judge.qc_drift'or p.qc->>'action'is distinct from'refuse'or p.qc->'publishable'is distinct from'false'::jsonb
  or coalesce(p.qc->>'verdict','')not in('fail','regen')or jsonb_typeof(p.qc->'failed')is distinct from'array'then return null;end if;
 if not exists(select 1 from jsonb_array_elements_text(p.qc->'failed')f(category)where category in('architecture','contents','additions','same_room'))then return null;end if;
 select * into q from public.cost_ledger where org_id=j.org_id and feature='qc'and total_cents>0
  and meta->>'kind'='video_drift'and meta->>'request_id'=b.request_id and meta->>'provenance_id'=p.id::text
  and meta->>'source_asset_id'=s.asset_id::text and meta->>'source_sha256'=b.qc_source_hash
  and meta->>'action'='refuse'and meta->'publishable'='false'::jsonb and meta->>'verdict'=p.qc->>'verdict'and meta->'failed'=p.qc->'failed'
  order by created_at desc,id desc limit 1;
 if q.id is null then return null;end if;
 return jsonb_build_object('request_id',b.request_id,'generation_provenance_id',p.id,'source_asset_id',s.asset_id,'source_sha256',b.qc_source_hash,'qc_ledger_id',q.id,'failed',p.qc->'failed','verdict',p.qc->'verdict','action','refuse');end$$;

create or replace function public.property_video_fallback_source_guard()returns trigger language plpgsql security definer set search_path=''as $$declare evidence jsonb;begin
 if new.state='original_photo'then evidence:=public.property_video_structural_rejection(new.job_id,new.attempt_id);
  if evidence is null then raise exception'RP409: Original-photo fallback requires a confirmed paid structural quality rejection';end if;
  new.fallback_evidence:=evidence;end if;return new;end$$;
drop trigger if exists property_video_fallback_source_guard on public.property_video_job_sources;
create trigger property_video_fallback_source_guard before insert or update of state on public.property_video_job_sources for each row execute function public.property_video_fallback_source_guard();
-- Historical unsafe fallback rows must not enter composition or be registered
-- as a ready output. No old row is silently reclassified by this migration.
create or replace function public.property_video_fallback_output_guard()returns trigger language plpgsql security definer set search_path=''as $$begin
 if new.state in('composing','ready')and exists(select 1 from public.property_video_job_sources s where s.job_id=new.id and s.state='original_photo'and public.property_video_structural_rejection(s.job_id,s.attempt_id)is null)then
  raise exception'RP409: A saved photo fallback has no confirmed structural rejection; resume its retained clip quality check';end if;return new;end$$;
drop trigger if exists property_video_fallback_output_guard on public.property_video_jobs;
create trigger property_video_fallback_output_guard before update of state on public.property_video_jobs for each row execute function public.property_video_fallback_output_guard();

create or replace function public.property_video_job_failure(p_job uuid,p_lease uuid,p_attempt uuid,p_code text,p_ambiguous boolean default false)returns boolean
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into j from public.property_video_jobs where id=p_job for update;if j.id is null then return false;end if;
 if j.cancelled_at is not null or j.deadline<=now()or j.state in('ready','cancelled')then raise exception'RP409: Stopped work cannot accept a failure callback';end if;
 if p_attempt is null and j.audio_lease=p_lease and j.audio_preflight is null then update public.property_video_jobs set state=case when audio_attempts>=3 then'failed'else'queued'end,audio_until=now(),message='The saved narration could not be decoded. Re-record or upload a valid audio take.'where id=p_job;return true;end if;
 if p_attempt is null then if j.compose_lease is distinct from p_lease or j.state<>'composing'then raise exception'RP409: A current composition lease is required';end if;
  update public.property_video_jobs set state=case when compose_attempts>=3 then'failed'else'generating'end,compose_until=now(),message='Video assembly was interrupted. Saved work will resume.'where id=p_job;return true;end if;
 select * into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt and lease_token=p_lease for update;
 if s.job_id is null then raise exception'RP409: A current shot lease is required';end if;
 if p_code='capacity_before_dispatch'and not p_ambiguous then
  if s.receipt is not null or exists(select 1 from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key and released_at is null)then raise exception'RP409: Accepted or uncertain supplier work cannot be reset';end if;
  update public.property_video_job_sources set state='failed',last_error=p_code,lease_until=null where job_id=p_job and attempt_id=p_attempt;
  update public.property_video_jobs set state='failed',message='Video paused before the next unpaid clip. Completed clips are retained; resume after processing capacity is available.'where id=p_job;return true;end if;
 if p_code='cpu_extract_failed'and s.state='quality_review'and s.cpu_attempts<3 then update public.property_video_job_sources set state='processing',lease_until=null,last_error=p_code where job_id=p_job and attempt_id=p_attempt;return true;end if;
 -- Only the persisted terminal QC verdict can authorize this substitution.
 if not p_ambiguous and p_code='quality_check_refused'and public.property_video_structural_rejection(p_job,p_attempt)is not null then
  update public.property_video_job_sources set state='original_photo',last_error=p_code,lease_until=null where job_id=p_job and attempt_id=p_attempt;return true;end if;
 -- A known paid clip with an unknown QC result is a quality pause, not an
 -- ambiguous new provider POST. Never erase its immutable receipt or clip.
 update public.property_video_job_sources set state=case when p_ambiguous and s.clip is null then'ambiguous'else'failed'end,last_error=left(p_code,80),lease_until=null where job_id=p_job and attempt_id=p_attempt;
 update public.property_video_jobs set state=case when p_ambiguous and s.clip is null then'needs_reconciliation'else'failed'end,
  message=case when p_ambiguous and s.clip is null then'The provider receipt could not be confirmed. No duplicate generation will be started.'when s.clip is not null then'Video quality review paused. Your paid clip is saved; resume the check after processing is available.'else'A selected photo could not be generated or approved. Your photos and payment receipts are retained.'end,updated_at=now()where id=p_job;return true;end$$;

create or replace function public.property_video_job_resume(p_actor uuid,p_job uuid,p_quote numeric)returns public.property_video_jobs language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;n integer;recoverable integer;begin
 j:=public.property_video_job_scope(p_job,p_actor,false);select * into j from public.property_video_jobs where id=p_job for update;
 -- Explicit local-quality recovery reuses the accepted supplier output.
 -- At most two user-requested CPU recovery cycles fit within the same deadline.
 select count(*)into recoverable from public.property_video_job_sources s where s.job_id=p_job and s.state in('failed','original_photo','quality_review')
  and s.last_error in('cpu_extract_failed','quality_check_refused','quality_check_unconfirmed')and s.clip is not null and s.receipt is not null and s.generation_provenance_id is not null
  and s.cpu_recoveries<2 and(s.state<>'quality_review'or s.lease_until is null or s.lease_until<=now())
  and public.property_video_structural_rejection(s.job_id,s.attempt_id)is null;
 if recoverable>0 then
  if j.state not in('queued','generating','quality_review','composing','failed')or j.cancelled_at is not null or j.deadline<=now()
   or exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and(s.state='ambiguous'or(s.state='failed'and(s.last_error not in('cpu_extract_failed','quality_check_refused','quality_check_unconfirmed')or s.clip is null or s.receipt is null or s.generation_provenance_id is null or s.cpu_recoveries>=2))))then raise exception'RP409: This saved video is not a safely recoverable quality pause';end if;
  if exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and public.property_photo_reference(j.actor_id,j.listing_id,s.asset_id,s.photo_provenance_id)is distinct from s.source)then raise exception'RP409: A selected photo changed or was withdrawn';end if;
  if exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and s.state in('failed','original_photo','quality_review')and s.last_error in('cpu_extract_failed','quality_check_refused','quality_check_unconfirmed')and not exists(
   select 1 from public.app_video_cost_reservations r join public.property_video_sources b on b.request_id=r.provider_request_id where r.actor_id=j.actor_id and r.org_id=j.org_id and r.idempotency_key=s.request_key and r.settled_at is not null and r.released_at is null and r.provider_request_id=s.receipt->>'request_id'and r.model=s.receipt->>'model_id'
    and b.actor_id=j.actor_id and b.org_id=j.org_id and b.listing_id=j.listing_id and b.source_asset_id=s.asset_id and b.generation_provenance_id=s.generation_provenance_id and b.input_sha256=s.source->>'sha256'))then raise exception'RP409: The retained paid clip has no matching source authority';end if;
  update public.property_video_job_sources set state='processing',cpu_recoveries=cpu_recoveries+1,
   cpu_recovery_history=cpu_recovery_history||jsonb_build_array(jsonb_build_object('attempt_id',attempt_id,'request_key',request_key,'clip_sha256',clip->>'sha256','previous_state',state,'cpu_attempts',cpu_attempts,'reason',last_error,'recovered_at',now(),'compose_lease',j.compose_lease,'compose_attempts',j.compose_attempts)),
   cpu_attempts=0,lease_token=null,lease_until=null,last_error=null,fallback_evidence=null
   where job_id=p_job and state in('failed','original_photo','quality_review')and last_error in('cpu_extract_failed','quality_check_refused','quality_check_unconfirmed')and clip is not null and receipt is not null and generation_provenance_id is not null and cpu_recoveries<2
    and(state<>'quality_review'or lease_until is null or lease_until<=now())and public.property_video_structural_rejection(job_id,attempt_id)is null;
  update public.property_video_jobs set state='generating',message=null,compose_lease=null,compose_until=null,compose_attempts=0,updated_at=now()where id=p_job returning * into j;return j;
 end if;
 if j.state in('queued','generating','quality_review','composing','ready')then return j;end if;
 if j.state<>'failed'or j.cancelled_at is not null or j.deadline<=now()or not exists(select 1 from public.property_video_job_sources where job_id=p_job and state='failed'and last_error='capacity_before_dispatch')or exists(select 1 from public.property_video_job_sources where job_id=p_job and(state='ambiguous'or(state='failed'and(last_error<>'capacity_before_dispatch'or receipt is not null or admission_retries>=3))))then raise exception'RP409: This saved video is not a safely resumable capacity pause';end if;
 if exists(select 1 from public.property_video_job_sources s join public.app_video_cost_reservations r on r.actor_id=j.actor_id and r.org_id=j.org_id and r.idempotency_key=s.request_key where s.job_id=p_job and s.state='failed'and r.released_at is null)then raise exception'RP409: An unsettled supplier attempt cannot be restarted';end if;
 select count(*)into n from public.property_video_job_sources where job_id=p_job and state in('pending','failed');perform public.property_video_recipe_capacity(p_actor,j.listing_id,n,p_quote);
 update public.property_video_job_sources set state='pending',admission_retries=admission_retries+1,non_dispatch_history=non_dispatch_history||jsonb_build_array(jsonb_build_object('attempt_id',attempt_id,'request_key',request_key,'reason',last_error)),attempt_id=null,lease_token=null,lease_until=null,request_key=null,last_error=null where job_id=p_job and state='failed'and last_error='capacity_before_dispatch';
 update public.property_video_jobs set state='generating',message=null,updated_at=now()where id=p_job returning * into j;return j;end$$;

revoke all on function public.property_video_structural_rejection(uuid,uuid),public.property_video_fallback_source_guard(),public.property_video_fallback_output_guard(),public.property_video_job_resume(uuid,uuid,numeric),public.property_video_job_failure(uuid,uuid,uuid,text,boolean)from public,anon,authenticated;
grant execute on function public.property_video_structural_rejection(uuid,uuid),public.property_video_fallback_source_guard(),public.property_video_fallback_output_guard(),public.property_video_job_resume(uuid,uuid,numeric),public.property_video_job_failure(uuid,uuid,uuid,text,boolean)to service_role;
