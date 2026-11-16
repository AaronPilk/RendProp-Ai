-- One explicit retry for an exactly proven, unaccepted FAL403 submission.
-- No accepted receipt is replaced. Old refusal journals and all sibling clips
-- remain immutable; a new attempt is subject to normal funding/slot admission.
begin;
create or replace function public.property_video_submit_refusal(p_job uuid,p_attempt uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;r public.app_video_cost_reservations;v public.serving_cost_reservations;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 j:=public.property_video_job_scope(p_job,null,false);
 select *into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt;
 if j.state<>'failed'or j.cancelled_at is not null or j.deadline<=now()or s.job_id is null or s.state<>'failed'or s.last_error<>'provider_submit_refused'
  or s.receipt is not null or s.clip is not null or s.generation_provenance_id is not null or s.lease_until>now()
  or s.request_key is distinct from'bgvideo:'||s.attempt_id::text or s.admission_retries>=3
  or exists(select 1 from jsonb_array_elements(s.non_dispatch_history)entry where entry->>'reason'='provider_submit_refused')then return null;end if;
 select *into r from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key and feature='reel'and provider='fal'
  and model='fal-ai/kling-video/v3/4k/image-to-video'and released_at is not null and rejection_status=403 and rejection_error_class='upstream'
  and provider_request_id is null and cost_ledger_id is null and settled_at is null and units=5 and unit_cost_cents=42 and total_cents=210 and hold_cents>=210 and input_sha256~'^[a-f0-9]{64}$';
 if r.id is null or r.meta->>'task'is distinct from'video.reel_clip'or r.meta->>'aspect'is distinct from j.manifest->>'aspect'or r.meta->>'motion'is distinct from s.motion
  or r.meta->>'seconds'is distinct from'5'or r.meta->>'unit'is distinct from'second' then return null;end if;
 select *into v from public.serving_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and request_key=s.request_key and stage='reel'
  and provider=r.provider and model=r.model and input_sha256=r.input_sha256 and state='rejected'and ledger_id is null and settled_at is not null and hold_cents>=r.total_cents;
 if v.id is null or not exists(select 1 from public.app_video_allowance_receipts where reservation_id=r.id and listing_id=j.listing_id)or exists(select 1 from public.cost_ledger where org_id=j.org_id and feature='reel'and(meta->>'app_video_reservation_id'=r.id::text or meta->>'request_key'=s.request_key))
  or exists(select 1 from public.serving_operation_results where org_id=j.org_id and actor_id=j.actor_id and request_key=s.request_key)then return null;end if;
 begin
  if public.property_photo_reference(j.actor_id,j.listing_id,s.asset_id,s.photo_provenance_id)is distinct from s.source then return null;end if;
 exception when sqlstate'P0001'then if sqlerrm like'RP403:%'or sqlerrm like'RP404:%'or sqlerrm like'RP409:%'then return null;end if;raise;end;
 return jsonb_build_object('app_reservation_id',r.id,'serving_reservation_id',v.id,'rejection_status',403,'provider',r.provider,'model',r.model,'request_key',s.request_key,'attempt_id',s.attempt_id,'source_asset_id',s.asset_id,'source_sha256',s.source->>'sha256','input_sha256',r.input_sha256,'released_at',r.released_at,'no_accepted_receipt',true);end$$;
create or replace function public.property_video_submit_resume_available(p_job uuid)returns boolean
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 j:=public.property_video_job_scope(p_job,null,false);
 return j.state='failed'and j.cancelled_at is null and j.deadline>now()
  and exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and s.state='failed'and public.property_video_submit_refusal(p_job,s.attempt_id)is not null)
  and not exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and(s.state='ambiguous'or(s.state='failed'and public.property_video_submit_refusal(p_job,s.attempt_id)is null)));end$$;
create or replace function public.property_video_submit_history_guard()returns trigger
language plpgsql security definer set search_path=''as $$declare i integer;e jsonb;begin
 if not exists(select 1 from jsonb_array_elements(old.non_dispatch_history)entry where entry->>'reason'='provider_submit_refused')and not exists(select 1 from jsonb_array_elements(new.non_dispatch_history)entry where entry->>'reason'='provider_submit_refused')then return new;end if;
 if jsonb_array_length(new.non_dispatch_history)<jsonb_array_length(old.non_dispatch_history)then raise exception'RP409: Prior supplier refusal history is immutable';end if;
 for i in 0..jsonb_array_length(old.non_dispatch_history)-1 loop if new.non_dispatch_history->i is distinct from old.non_dispatch_history->i then raise exception'RP409: Prior supplier refusal history is immutable';end if;end loop;
 if jsonb_array_length(new.non_dispatch_history)>jsonb_array_length(old.non_dispatch_history)and(new.non_dispatch_history->-1)->>'reason'='provider_submit_refused'then
  e:=public.property_video_submit_refusal(old.job_id,old.attempt_id);
  if e is null or jsonb_array_length(new.non_dispatch_history)<>jsonb_array_length(old.non_dispatch_history)+1 or(new.non_dispatch_history->-1)->'refusal'is distinct from e
   or(new.non_dispatch_history->-1)->'prior_source'is distinct from(to_jsonb(old)-'non_dispatch_history')or new.admission_retries<>old.admission_retries+1
   then raise exception'RP409: A confirmed unaccepted supplier refusal is required';end if;
 end if;return new;end$$;
drop trigger if exists property_video_submit_history_guard on public.property_video_job_sources;
create trigger property_video_submit_history_guard before update of non_dispatch_history on public.property_video_job_sources for each row execute function public.property_video_submit_history_guard();
do $$begin
 if to_regprocedure('public.property_video_job_resume_before_submit_20261015(uuid,uuid,numeric)')is null then
  if(select md5(prosrc)from pg_proc where oid='public.property_video_job_resume(uuid,uuid,numeric)'::regprocedure)is distinct from'd933e5b56dc167af66cc64c3e01459d4'then raise exception'Review changed saved-video resume authority';end if;
  alter function public.property_video_job_resume(uuid,uuid,numeric)rename to property_video_job_resume_before_submit_20261015;
 elsif(select md5(prosrc)from pg_proc where oid='public.property_video_job_resume_before_submit_20261015(uuid,uuid,numeric)'::regprocedure)is distinct from'd933e5b56dc167af66cc64c3e01459d4'then raise exception'Review changed previous saved-video resume authority';end if;
end$$;
do $$begin
 if to_regprocedure('public.property_video_job_resume(uuid,uuid,numeric)')is not null and(select md5(prosrc)from pg_proc where oid=to_regprocedure('public.property_video_job_resume(uuid,uuid,numeric)'))not in('d933e5b56dc167af66cc64c3e01459d4','31f27152c2bb8a228133b7f0dcd1c334')then raise exception'Review changed unaccepted-submit resume authority';end if;
end$$;
create or replace function public.property_video_job_resume(p_actor uuid,p_job uuid,p_quote numeric)returns public.property_video_jobs
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;e jsonb;n integer;begin
 j:=public.property_video_job_scope(p_job,p_actor,false);select *into j from public.property_video_jobs where id=p_job for update;
 if public.property_video_submit_resume_available(p_job)then
  if p_quote is null or p_quote<=0 or p_quote::text in('NaN','Infinity','-Infinity')then raise exception'RP409: Price the remaining planned shots before retrying an unaccepted submission';end if;
  select count(*)into n from public.property_video_job_sources where job_id=p_job and state in('pending','failed');perform public.property_video_recipe_capacity(p_actor,j.listing_id,n,p_quote);
  for s in select *from public.property_video_job_sources where job_id=p_job and state='failed'order by position for update loop
   perform 1 from public.capture_assets where id=s.asset_id and listing_id=j.listing_id for share;
   perform 1 from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key for share;
   perform 1 from public.serving_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and request_key=s.request_key and stage='reel'for share;
   e:=public.property_video_submit_refusal(p_job,s.attempt_id);if e is null then raise exception'RP409: The confirmed supplier refusal changed';end if;
   update public.property_video_job_sources set state='pending',admission_retries=admission_retries+1,
    non_dispatch_history=non_dispatch_history||jsonb_build_array(jsonb_build_object('reason','provider_submit_refused','prior_source',to_jsonb(s)-'non_dispatch_history','refusal',e,'recovered_at',now())),
    attempt_id=null,request_key=null,lease_token=null,lease_until=null,last_error=null where job_id=p_job and position=s.position;
  end loop;
  update public.property_video_jobs set state='generating',message='Retrying the affected shot after a confirmed unaccepted submission. Saved clips and photo order are unchanged; remaining shots use normal processing.',updated_at=now()where id=p_job;
  return public.property_video_job_scope(p_job,p_actor,false);
 end if;
 return public.property_video_job_resume_before_submit_20261015(p_actor,p_job,p_quote);end$$;
revoke all on function public.property_video_submit_refusal(uuid,uuid),public.property_video_submit_resume_available(uuid),public.property_video_submit_history_guard(),public.property_video_job_resume(uuid,uuid,numeric),public.property_video_job_resume_before_submit_20261015(uuid,uuid,numeric)from public,anon,authenticated;
grant execute on function public.property_video_submit_refusal(uuid,uuid),public.property_video_submit_resume_available(uuid),public.property_video_submit_history_guard(),public.property_video_job_resume(uuid,uuid,numeric),public.property_video_job_resume_before_submit_20261015(uuid,uuid,numeric)to service_role;
commit;
