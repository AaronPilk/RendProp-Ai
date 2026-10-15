-- Source-only candidate. No live policy activation or renderer deployment.
-- One distinct, explicit operator repair after the reviewed static-photo fix.
begin;
do $$begin
 if (select md5(prosrc)from pg_proc where oid='public.property_video_compose_snapshot(uuid)'::regprocedure)is distinct from'2dd963d6784041fdd2a26e5cde8ce913'
 or(select md5(prosrc)from pg_proc where oid='public.property_video_compose_resume_available(uuid)'::regprocedure)is distinct from'63189c8fb1f4cded2a7846f59d85d03f'
 then raise exception'Review changed retained assembly snapshot authority';end if;
end$$;
insert into public.app_config(key,value)values('property_video_static_fallback_repair',jsonb_build_object('enabled',false,'policy','static-original-fallback-v1','renderer_runtime_sha256','6fa6fd7846e2b8134b34ff3d766612eea5aecfd2e4b1093914e49eb59723afed','renderer_image_sha256',null))on conflict(key)do nothing;
-- The image value is an explicit release-operator attestation, not an automatic
-- Cloudflare proof. It stays null/OFF until that exact fixed image is verified.
create or replace function public.property_video_static_repair_release()returns jsonb
language plpgsql stable security definer set search_path=''as $$declare c jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select value into c from public.app_config where key='property_video_static_fallback_repair';
 if c->'enabled'is distinct from'true'::jsonb or c->>'policy'is distinct from'static-original-fallback-v1'
  or c->>'renderer_runtime_sha256'is distinct from'6fa6fd7846e2b8134b34ff3d766612eea5aecfd2e4b1093914e49eb59723afed'
  or coalesce(c->>'renderer_image_sha256','')!~'^[0-9a-f]{64}$'then return null;end if;
 return jsonb_build_object('policy',c->'policy','renderer_runtime_sha256',c->'renderer_runtime_sha256','renderer_image_sha256',c->'renderer_image_sha256');end$$;
create or replace function public.property_video_static_repair_available(p_job uuid)returns boolean
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;v jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 j:=public.property_video_job_scope(p_job,null,false);
 if j.state<>'failed'or j.compose_recoveries<>1 or jsonb_array_length(j.compose_recovery_history)<>1 or j.compose_attempts<>3
  or j.compose_lease is null or j.compose_until is null or j.compose_until>now()or public.property_video_static_repair_release()is null
  or not exists(select 1 from public.property_video_job_sources where job_id=p_job and state='original_photo')then return false;end if;
 v:=public.property_video_compose_snapshot(p_job);
 return v is not null and v=(j.compose_recovery_history->0)-array['prior_compose_lease','prior_compose_attempts','recovered_at'];end$$;
-- Keep the old 0->1 ordinary Resume branch byte-for-byte. Add only the new
-- policy-verified, prefix-preserving 1->2 transition.
do $patch$declare body text;h text;begin
 select md5(prosrc)into h from pg_proc where oid='public.property_video_compose_history_guard()'::regprocedure;
 if h='f3b58f811f6205343f87461a6fbafb13'then
  body:=pg_get_functiondef('public.property_video_compose_history_guard()'::regprocedure);
  body:=replace(body,$old$if new.compose_recoveries is distinct from old.compose_recoveries or new.compose_recovery_history is distinct from old.compose_recovery_history then$old$,$new$if new.compose_recoveries is distinct from old.compose_recoveries or new.compose_recovery_history is distinct from old.compose_recovery_history then
  if old.compose_recoveries=1 and new.compose_recoveries=2 then
   v:=public.property_video_compose_snapshot(old.id);
   if not public.property_video_static_repair_available(old.id)or v is null
    or coalesce(new.compose_recovery_history#>>'{1,repair_operation}','')!~'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or new.compose_recovery_history is distinct from old.compose_recovery_history||jsonb_build_array(v||public.property_video_static_repair_release()||jsonb_build_object('repair_operation',new.compose_recovery_history#>'{1,repair_operation}','prior_compose_lease',old.compose_lease,'prior_compose_attempts',old.compose_attempts,'recovered_at',new.compose_recovery_history#>'{1,recovered_at}'))
    or jsonb_typeof(new.compose_recovery_history#>'{1,recovered_at}')is distinct from'string'
    or new.state<>'generating'or new.compose_attempts<>0
    or(to_jsonb(new)-array['state','compose_attempts','compose_recoveries','compose_recovery_history','message','updated_at'])is distinct from(to_jsonb(old)-array['state','compose_attempts','compose_recoveries','compose_recovery_history','message','updated_at'])then
    raise exception'RP409: Static-photo repair must retain its exact release, recipe and prior history';end if;
   return new;
  end if;$new$);
  execute body;
 elsif h is distinct from'3d550f6735548f20aef5b751943ff3f9' then raise exception'Review changed assembly history authority';end if;
end$patch$;
alter table public.property_video_jobs drop constraint property_video_jobs_compose_recoveries_check;
alter table public.property_video_jobs add constraint property_video_jobs_compose_recoveries_check check(compose_recoveries between 0 and 2);
create unique index if not exists property_video_static_repair_operation on public.property_video_jobs((compose_recovery_history#>>'{1,repair_operation}'))where compose_recoveries=2;
create or replace function public.property_video_job_repair_static_compose(p_actor uuid,p_job uuid,p_operation uuid)returns public.property_video_jobs
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;v jsonb;r jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_actor is null or p_job is null or p_operation is null then raise exception'RP400: Explicit repair identity is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('property-video-static-repair:'||p_operation::text,79));
 j:=public.property_video_job_scope(p_job,p_actor,false);select *into j from public.property_video_jobs where id=p_job for update;
 -- A lost response is an acknowledgment, even if that same cycle later failed.
 if j.compose_recoveries=2 and j.compose_recovery_history#>>'{1,repair_operation}'=p_operation::text then return public.property_video_job_scope(p_job,p_actor,false);end if;
 if exists(select 1 from public.property_video_jobs where compose_recovery_history#>>'{1,repair_operation}'=p_operation::text)then raise exception'RP409: This repair operation is already bound';end if;
 perform 1 from public.app_config where key='property_video_static_fallback_repair'for share;
 if not public.property_video_static_repair_available(p_job)then raise exception'RP409: This saved assembly is not eligible for the fixed-renderer repair';end if;
 perform 1 from public.property_video_job_sources where job_id=p_job order by position for update;
 perform 1 from public.capture_assets where id in(select asset_id from public.property_video_job_sources where job_id=p_job)order by id for share;
 -- Recheck current authority after waiting for all retained source locks.
 v:=public.property_video_compose_snapshot(p_job);r:=public.property_video_static_repair_release();
 if not public.property_video_static_repair_available(p_job)or v is null or r is null then raise exception'RP409: Saved assembly inputs or renderer release changed';end if;
 update public.property_video_jobs set compose_recoveries=2,compose_recovery_history=compose_recovery_history||jsonb_build_array(v||r||jsonb_build_object('repair_operation',p_operation,'prior_compose_lease',j.compose_lease,'prior_compose_attempts',j.compose_attempts,'recovered_at',now())),compose_attempts=0,state='generating',message='Reassembling your saved clips with the corrected photo fallback. No clips or quality checks are being regenerated.',updated_at=now()where id=p_job;
 return public.property_video_job_scope(p_job,p_actor,false);end$$;
-- Old body{} Resume is never a second repair request. Preserve its replay and
-- exhaustion behavior after either explicit recovery count.
do $patch$declare body text;h text;begin
 select md5(prosrc)into h from pg_proc where oid='public.property_video_job_resume(uuid,uuid,numeric)'::regprocedure;
 if h='de2e8daf35f09d8b1d696b2399c49710'then
  body:=pg_get_functiondef('public.property_video_job_resume(uuid,uuid,numeric)'::regprocedure);
  body:=replace(body,'if j.compose_recoveries=1 and','if j.compose_recoveries>=1 and');execute body;
 elsif h is distinct from'121a22da639a891d762964ae72efb00b' then raise exception'Review changed ordinary assembly Resume';end if;
end$patch$;
do $patch$declare body text;h text;begin
 select md5(prosrc)into h from pg_proc where oid='public.property_video_job_claim(uuid,text)'::regprocedure;
 if h='7302f3b16e2e4a1279b404559a6c3381'then
  body:=pg_get_functiondef('public.property_video_job_claim(uuid,text)'::regprocedure);
  body:=replace(body,'j.compose_recoveries=1','j.compose_recoveries>=1');
  body:=replace(body,$old$(j.compose_recovery_history->0)-array['prior_compose_lease','prior_compose_attempts','recovered_at']$old$,$new$(j.compose_recovery_history->(j.compose_recoveries-1))-array['prior_compose_lease','prior_compose_attempts','recovered_at','repair_operation','policy','renderer_runtime_sha256','renderer_image_sha256']$new$);
  body:=replace(body,$old$-- Recovered assembly cannot cross an uncertain output or changed source snapshot.$old$,$new$-- Recovered assembly cannot cross an uncertain output or changed source snapshot.
  if j.compose_recoveries=2 and public.property_video_static_repair_release()is distinct from(j.compose_recovery_history->1)-array['operation_id','manifest_sha256','quality_profile','deadline','output_asset_id','poster_asset_id','sources_sha256','prior_compose_lease','prior_compose_attempts','recovered_at','repair_operation']then
   update public.property_video_jobs set state='needs_reconciliation',message='The fixed renderer release needs review. Your finished clips are retained.'where id=p_job returning *into j;return jsonb_build_object('action','done','job',to_jsonb(j));end if;$new$);
  execute body;
 elsif h is distinct from'59756aa060288e811be3dcddb1625349' then raise exception'Review changed recovered assembly claim';end if;
end$patch$;
revoke all on function public.property_video_static_repair_release(),public.property_video_static_repair_available(uuid),public.property_video_job_repair_static_compose(uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.property_video_static_repair_release(),public.property_video_static_repair_available(uuid),public.property_video_job_repair_static_compose(uuid,uuid,uuid)to service_role;
commit;
