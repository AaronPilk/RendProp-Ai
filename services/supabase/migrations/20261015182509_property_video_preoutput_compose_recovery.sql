-- One explicit assembly-only recovery for a fully reviewed recipe that failed
-- before any output admission. Paid generation/QC, source rows and deadlines
-- are retained; no supplier or money operation is performed by this migration.
begin;
alter table public.property_video_jobs add column if not exists compose_recoveries integer not null default 0 check(compose_recoveries between 0 and 1);
alter table public.property_video_jobs add column if not exists compose_recovery_history jsonb not null default'[]'::jsonb check(jsonb_typeof(compose_recovery_history)='array');
-- This private read-only snapshot validates current source and paid/QC lineage.
-- It deliberately refuses even unconfirmed output reservations or partial uploads.
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
  if b.request_id is null or p.qc->>'request_id'is distinct from b.request_id or p.qc->>'source_sha256'is distinct from b.qc_source_hash then return null;end if;
  if s.state='original_photo'then
   v:=public.property_video_structural_rejection(p_job,s.attempt_id);
   if v is null or s.fallback_evidence is distinct from v then return null;end if;
  elsif p.qc->'publishable'is distinct from'true'::jsonb or not exists(select 1 from public.cost_ledger where org_id=j.org_id and feature='qc'and total_cents>0 and meta->>'request_id'=b.request_id and meta->'publishable'='true'::jsonb)then return null;end if;
 end loop;
 return jsonb_build_object('operation_id',j.operation_id,'manifest_sha256',j.manifest_sha256,'quality_profile',j.quality_profile,'deadline',j.deadline,'output_asset_id',j.output_asset_id,'poster_asset_id',j.poster_asset_id,
  'sources_sha256',(select encode(sha256(convert_to(jsonb_agg(to_jsonb(x)order by position)::text,'UTF8')),'hex')from public.property_video_job_sources x where job_id=p_job));end$$;
create or replace function public.property_video_compose_resume_available(p_job uuid)returns boolean
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 j:=public.property_video_job_scope(p_job,null,false);
 return j.state='failed'and j.compose_recoveries=0 and j.compose_attempts=3 and j.compose_lease is not null and j.compose_until is not null and j.compose_until<=now()
  and public.property_video_compose_snapshot(p_job)is not null;end$$;
create or replace function public.property_video_compose_history_guard()returns trigger
language plpgsql security definer set search_path=''as $$declare v jsonb;begin
 if new.compose_recoveries is distinct from old.compose_recoveries or new.compose_recovery_history is distinct from old.compose_recovery_history then
  v:=public.property_video_compose_snapshot(old.id);
  if not public.property_video_compose_resume_available(old.id)or v is null or old.compose_recoveries<>0 or new.compose_recoveries<>1
   or new.compose_recovery_history is distinct from jsonb_build_array(v||jsonb_build_object('prior_compose_lease',old.compose_lease,'prior_compose_attempts',old.compose_attempts,'recovered_at',new.compose_recovery_history#>'{0,recovered_at}'))
   or jsonb_typeof(new.compose_recovery_history#>'{0,recovered_at}')is distinct from'string'
   or new.state<>'generating'or new.compose_attempts<>0
   or(to_jsonb(new)-array['state','compose_attempts','compose_recoveries','compose_recovery_history','message','updated_at'])is distinct from(to_jsonb(old)-array['state','compose_attempts','compose_recoveries','compose_recovery_history','message','updated_at'])then
   raise exception'RP409: Assembly recovery must retain its exact reviewed recipe and pre-output identities';end if;
 end if;return new;end$$;
drop trigger if exists property_video_compose_history_guard on public.property_video_jobs;
create trigger property_video_compose_history_guard before update of compose_recoveries,compose_recovery_history on public.property_video_jobs for each row execute function public.property_video_compose_history_guard();
do $$begin
 if to_regprocedure('public.property_video_job_resume_before_compose_20261015(uuid,uuid,numeric)')is null then
  if(select md5(prosrc)from pg_proc where oid='public.property_video_job_resume(uuid,uuid,numeric)'::regprocedure)is distinct from'a17b39620d21ce8837b9486c2a969071'then raise exception'Review changed saved-video resume authority';end if;
  alter function public.property_video_job_resume(uuid,uuid,numeric)rename to property_video_job_resume_before_compose_20261015;
 elsif(select md5(prosrc)from pg_proc where oid='public.property_video_job_resume_before_compose_20261015(uuid,uuid,numeric)'::regprocedure)is distinct from'a17b39620d21ce8837b9486c2a969071'then raise exception'Review changed previous saved-video resume authority';end if;
end$$;
do $$begin if to_regprocedure('public.property_video_job_resume(uuid,uuid,numeric)')is not null and(select md5(prosrc)from pg_proc where oid=to_regprocedure('public.property_video_job_resume(uuid,uuid,numeric)'))not in('a17b39620d21ce8837b9486c2a969071','de2e8daf35f09d8b1d696b2399c49710')then raise exception'Review changed assembly recovery authority';end if;end$$;
create or replace function public.property_video_job_resume(p_actor uuid,p_job uuid,p_quote numeric)returns public.property_video_jobs
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;v jsonb;begin
 j:=public.property_video_job_scope(p_job,p_actor,false);select *into j from public.property_video_jobs where id=p_job for update;
 if public.property_video_compose_resume_available(p_job)then
  if p_quote is distinct from 0::numeric then raise exception'RP409: Assembly recovery does not require a new supplier quote';end if;
  perform 1 from public.property_video_job_sources where job_id=p_job order by position for update;
  -- Lock current source assets before the final authority snapshot.
  perform 1 from public.capture_assets where id in(select asset_id from public.property_video_job_sources where job_id=p_job)order by id for share;
  v:=public.property_video_compose_snapshot(p_job);if v is null then raise exception'RP409: Saved assembly inputs or output admission changed';end if;
  update public.property_video_jobs set compose_recoveries=1,compose_recovery_history=jsonb_build_array(v||jsonb_build_object('prior_compose_lease',j.compose_lease,'prior_compose_attempts',j.compose_attempts,'recovered_at',now())),compose_attempts=0,state='generating',message='Resuming video assembly using your finished clips. No clips or quality checks are being regenerated.',updated_at=now()where id=p_job;
  return public.property_video_job_scope(p_job,p_actor,false);
 end if;
 if j.compose_recoveries=1 and j.state in('generating','composing','ready')then
  if j.state<>'ready'then perform public.property_video_job_scope(p_job,p_actor,true);end if;return j;end if;
 if j.compose_recoveries=1 and j.state='failed'and not exists(select 1 from public.property_video_job_sources where job_id=p_job and state not in('ready','original_photo'))then
  raise exception'RP409: The explicit assembly recovery is exhausted. Finished clips and receipts are retained for support.';end if;
 return public.property_video_job_resume_before_compose_20261015(p_actor,p_job,p_quote);end$$;

-- Exact reviewed baseline patch; no unrelated function body is replaced.
do $patch$declare body text;h text;begin
 select md5(prosrc)into h from pg_proc where oid='public.property_video_job_claim(uuid,text)'::regprocedure;
 if h='300ff6fbf3f166a2fea0ef2ede87b3e8'then
  body:=pg_get_functiondef('public.property_video_job_claim(uuid,text)'::regprocedure);
  body:=replace(body,$old$  token:=gen_random_uuid();update public.property_video_jobs set state='composing'$old$,$new$  -- Recovered assembly cannot cross an uncertain output or changed source snapshot.
  if j.compose_recoveries=1 and (public.property_video_compose_snapshot(p_job)is null or public.property_video_compose_snapshot(p_job)is distinct from(j.compose_recovery_history->0)-array['prior_compose_lease','prior_compose_attempts','recovered_at'])then
   update public.property_video_jobs set state='needs_reconciliation',message='Saved assembly inputs or an output reservation need review. Your finished clips are retained.'where id=p_job returning *into j;return jsonb_build_object('action','done','job',to_jsonb(j));end if;
  token:=gen_random_uuid();update public.property_video_jobs set state='composing'$new$);
  body:=replace(body,$old$output_asset_id=gen_random_uuid(),poster_asset_id=gen_random_uuid()$old$,$new$output_asset_id=case when j.compose_recoveries=1 then j.output_asset_id else gen_random_uuid()end,poster_asset_id=case when j.compose_recoveries=1 then j.poster_asset_id else gen_random_uuid()end$new$);
  execute body;
 elsif h is distinct from'7302f3b16e2e4a1279b404559a6c3381'then raise exception'Review changed property_video_job_claim authority';end if;end$patch$;

-- Exact reviewed baseline patch; no unrelated function body is replaced.
do $patch$declare body text;h text;begin
 select md5(prosrc)into h from pg_proc where oid='public.property_video_job_outputs_reserve(uuid,uuid,bigint,text,bigint,text)'::regprocedure;
 if h='2af81a5236c45dedc6f9de58ac618d5e'then
  body:=pg_get_functiondef('public.property_video_job_outputs_reserve(uuid,uuid,bigint,text,bigint,text)'::regprocedure);
  body:=replace(body,$old$perform public.property_video_job_worker_scope(p_job,p_lease,null);select * into j from public.property_video_jobs where id=p_job for update;$old$,$new$perform public.property_video_job_worker_scope(p_job,p_lease,null);select * into j from public.property_video_jobs where id=p_job for update;
 -- Revalidate after waiting: an old lease must not admit bytes across Resume.
 perform public.property_video_job_worker_scope(p_job,p_lease,null);$new$);
  execute body;
 elsif h is distinct from'64583c2361b3cf0cd85ba64d81b2075c'then raise exception'Review changed property_video_job_outputs_reserve authority';end if;end$patch$;

-- Exact reviewed baseline patch; no unrelated function body is replaced.
do $patch$declare body text;h text;begin
 select md5(prosrc)into h from pg_proc where oid='public.property_video_job_failure(uuid,uuid,uuid,text,boolean)'::regprocedure;
 if h='8c4b21e16ec277ad4af6bd0c78439782'then
  body:=pg_get_functiondef('public.property_video_job_failure(uuid,uuid,uuid,text,boolean)'::regprocedure);
  body:=replace(body,$old$message='Video assembly was interrupted. Saved work will resume.'$old$,$new$message='Video assembly could not finish. Your finished clips are saved.'$new$);
  execute body;
 elsif h is distinct from'418314743fbe80c6ec6a5ef29b95c0e6'then raise exception'Review changed property_video_job_failure authority';end if;end$patch$;
revoke all on function public.property_video_compose_snapshot(uuid),public.property_video_compose_resume_available(uuid),public.property_video_compose_history_guard(),public.property_video_job_resume(uuid,uuid,numeric),public.property_video_job_resume_before_compose_20261015(uuid,uuid,numeric)from public,anon,authenticated;
grant execute on function public.property_video_compose_snapshot(uuid),public.property_video_compose_resume_available(uuid),public.property_video_compose_history_guard(),public.property_video_job_resume(uuid,uuid,numeric),public.property_video_job_resume_before_compose_20261015(uuid,uuid,numeric)to service_role;
commit;
