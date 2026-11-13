-- Re-read an accepted paid result. This path cannot create a supplier attempt,
-- replace a request key, refund a charge, or approve/publish a clip.
begin;
alter table public.property_video_job_sources add column if not exists result_read_failures integer not null default 0 check(result_read_failures between 0 and 3);
alter table public.property_video_job_sources add column if not exists result_read_last_lease uuid;
alter table public.property_video_job_sources add column if not exists result_read_last_issue jsonb;
alter table public.property_video_job_sources add column if not exists delivery_recoveries integer not null default 0 check(delivery_recoveries between 0 and 3);
alter table public.property_video_job_sources add column if not exists delivery_recovery_history jsonb not null default'[]'::jsonb check(jsonb_typeof(delivery_recovery_history)='array');
create or replace function public.property_video_delivery_receipt(p_job uuid,p_attempt uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;r public.app_video_cost_reservations;paid public.cost_ledger;p public.media_provenance;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 j:=public.property_video_job_scope(p_job,null,false);
 select *into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt;
 if j.cancelled_at is not null or j.deadline<=now()or s.job_id is null or s.receipt is null or s.clip is not null or s.generation_provenance_id is null
  or jsonb_typeof(s.receipt->'status_url')is distinct from'string'or length(s.receipt->>'status_url')=0 then return null;end if;
 select *into r from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key and feature='reel'and provider='fal'and provider_request_id=s.receipt->>'request_id'and model=s.receipt->>'model_id'and settled_at is not null and released_at is null;
 select *into paid from public.cost_ledger where id=r.cost_ledger_id and org_id=j.org_id and feature='reel'and provider=r.provider and model=r.model and total_cents>0
  and meta->>'app_video_reservation_id'=r.id::text and meta->>'request_id'=r.provider_request_id and meta->>'request_key'=r.idempotency_key and meta->>'stage'='reel';
 select *into p from public.media_provenance where id=s.generation_provenance_id and org_id=j.org_id and listing_id=j.listing_id and kind='reel'and model_id=r.model;
 if r.id is null or paid.id is null or p.id is null then return null;end if;
 begin
  if public.property_photo_reference(j.actor_id,j.listing_id,s.asset_id,s.photo_provenance_id)is distinct from s.source then return null;end if;
 exception when sqlstate'P0001'then if sqlerrm like'RP403:%'or sqlerrm like'RP404:%'or sqlerrm like'RP409:%'then return null;end if;raise;end;
 return jsonb_build_object('paid_reservation_id',r.id,'paid_ledger_id',paid.id,'provider',r.provider,'model',r.model,'request_id',r.provider_request_id,'request_key',r.idempotency_key,'attempt_id',s.attempt_id,'source_asset_id',s.asset_id,'source_sha256',s.source->>'sha256','photo_provenance_id',s.photo_provenance_id,'generation_provenance_id',p.id,'receipt',s.receipt);end$$;
create or replace function public.property_video_delivery_resume_available(p_job uuid)returns boolean
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 j:=public.property_video_job_scope(p_job,null,false);
 return j.state='failed'and j.cancelled_at is null and j.deadline>now()
  and exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and s.state='failed'and s.last_error in('provider_generation_failed','provider_result_unavailable')and s.delivery_recoveries<3 and(s.lease_until is null or s.lease_until<=now())and public.property_video_delivery_receipt(p_job,s.attempt_id)is not null)
  and not exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and(s.state='ambiguous'or(s.state='failed'and(s.last_error not in('provider_generation_failed','provider_result_unavailable')or s.delivery_recoveries>=3 or s.lease_until>now()or public.property_video_delivery_receipt(p_job,s.attempt_id)is null))));end$$;
create or replace function public.property_video_delivery_history_guard()returns trigger
language plpgsql security definer set search_path=''as $$declare i integer;begin
 if new.delivery_recoveries<old.delivery_recoveries then raise exception'RP409: A saved delivery recovery cannot be reset';end if;
 if new.delivery_recoveries<>old.delivery_recoveries or new.delivery_recovery_history is distinct from old.delivery_recovery_history then
  if new.delivery_recoveries<>old.delivery_recoveries+1 or jsonb_array_length(new.delivery_recovery_history)<>jsonb_array_length(old.delivery_recovery_history)+1 then raise exception'RP409: Delivery recovery history is append-only';end if;
  for i in 0..jsonb_array_length(old.delivery_recovery_history)-1 loop if new.delivery_recovery_history->i is distinct from old.delivery_recovery_history->i then raise exception'RP409: Prior delivery recovery is immutable';end if;end loop;
  if not public.property_video_delivery_resume_available(old.job_id)or public.property_video_delivery_receipt(old.job_id,old.attempt_id)is null
   or(new.delivery_recovery_history->-1)->'prior_source'is distinct from(to_jsonb(old)-'delivery_recovery_history')
   or(new.delivery_recovery_history->-1)->'paid_receipt'is distinct from public.property_video_delivery_receipt(old.job_id,old.attempt_id)
   or(to_jsonb(new)-array['state','lease_token','lease_until','last_error','result_read_failures','delivery_recoveries','delivery_recovery_history'])is distinct from(to_jsonb(old)-array['state','lease_token','lease_until','last_error','result_read_failures','delivery_recoveries','delivery_recovery_history'])
   then raise exception'RP409: Delivery recovery must retain its exact paid attempt and source';end if;
 end if;return new;end$$;
drop trigger if exists property_video_delivery_history_guard on public.property_video_job_sources;
create trigger property_video_delivery_history_guard before update of delivery_recoveries,delivery_recovery_history on public.property_video_job_sources for each row execute function public.property_video_delivery_history_guard();
create or replace function public.property_video_job_result_read_failure(p_job uuid,p_lease uuid,p_attempt uuid,p_reason text)returns boolean
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;issue jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_reason is null or p_reason not in('balance_exhausted','account_locked','auth','permission','unknown')then raise exception'RP400: Use a closed supplier result-read classification';end if;
 j:=public.property_video_job_scope(p_job,null,false);select *into j from public.property_video_jobs where id=p_job for update;
 select *into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt for update;
 issue:=jsonb_build_object('provider','fal','provider_state','completed','provider_status',403,'phase','result_read','reason',p_reason);
 if s.job_id is null or public.property_video_delivery_receipt(p_job,p_attempt)is null then raise exception'RP409: An exact retained paid result receipt is required';end if;
 if s.result_read_last_lease=p_lease and s.result_read_last_issue=issue then return true;end if;
 perform public.property_video_job_worker_scope(p_job,p_lease,p_attempt);
 if s.state<>'processing'or s.result_read_failures>=3 then raise exception'RP409: This saved result is not awaiting a bounded read';end if;
 update public.property_video_job_sources set result_read_failures=result_read_failures+1,result_read_last_lease=p_lease,result_read_last_issue=issue,
  provider_terminal_at=coalesce(provider_terminal_at,now()),state=case when result_read_failures+1>=3 then'failed'else'processing'end,last_error='provider_result_unavailable',lease_until=null where job_id=p_job and attempt_id=p_attempt;
 if s.result_read_failures+1>=3 then update public.property_video_jobs set state='failed',message=case when s.delivery_recoveries>=3 then'The video service still cannot deliver its saved result. Existing clips and paid receipts are retained; contact support for help.'else'The video service completed a clip but could not deliver its file. Resume rechecks this affected clip using its same paid receipt; remaining planned shots keep normal processing.'end,updated_at=now()where id=p_job;end if;return true;end$$;
do $$begin
 if to_regprocedure('public.property_video_job_resume_before_delivery_20261015(uuid,uuid,numeric)')is null then
  if(select md5(prosrc)from pg_proc where oid='public.property_video_job_resume(uuid,uuid,numeric)'::regprocedure)is distinct from'b732f83b09e2e37462616f548d229bb5'then raise exception'Review changed saved-video resume authority';end if;
  alter function public.property_video_job_resume(uuid,uuid,numeric)rename to property_video_job_resume_before_delivery_20261015;
 elsif(select md5(prosrc)from pg_proc where oid='public.property_video_job_resume_before_delivery_20261015(uuid,uuid,numeric)'::regprocedure)is distinct from'b732f83b09e2e37462616f548d229bb5'then raise exception'Review changed prior saved-video resume authority';end if;
end$$;
do $$begin
 if to_regprocedure('public.property_video_job_resume(uuid,uuid,numeric)')is not null and(select md5(prosrc)from pg_proc where oid=to_regprocedure('public.property_video_job_resume(uuid,uuid,numeric)'))not in('d933e5b56dc167af66cc64c3e01459d4','b732f83b09e2e37462616f548d229bb5')then raise exception'Review changed delivery-aware resume authority';end if;
end$$;
create or replace function public.property_video_job_resume(p_actor uuid,p_job uuid,p_quote numeric)returns public.property_video_jobs
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;evidence jsonb;begin
 j:=public.property_video_job_scope(p_job,p_actor,false);select *into j from public.property_video_jobs where id=p_job for update;
 if public.property_video_delivery_resume_available(p_job)then
  for s in select *from public.property_video_job_sources where job_id=p_job and state='failed'order by position for update loop
   evidence:=public.property_video_delivery_receipt(p_job,s.attempt_id);if evidence is null then raise exception'RP409: The retained paid result changed';end if;
   update public.property_video_job_sources set delivery_recovery_history=delivery_recovery_history||jsonb_build_array(jsonb_build_object('prior_source',to_jsonb(s)-'delivery_recovery_history','paid_receipt',evidence,'recovered_at',now())),delivery_recoveries=delivery_recoveries+1,
    state='processing',lease_token=null,lease_until=null,last_error=null,result_read_failures=0 where job_id=p_job and position=s.position;
  end loop;
  update public.property_video_jobs set state='generating',message='Rechecking this affected clip using its same paid receipt. Saved clips and photo order are unchanged; remaining planned shots keep normal processing.',updated_at=now()where id=p_job;
  return public.property_video_job_scope(p_job,p_actor,false);
 end if;
 return public.property_video_job_resume_before_delivery_20261015(p_actor,p_job,p_quote);end$$;
revoke all on function public.property_video_delivery_receipt(uuid,uuid),public.property_video_delivery_resume_available(uuid),public.property_video_delivery_history_guard(),public.property_video_job_result_read_failure(uuid,uuid,uuid,text),public.property_video_job_resume(uuid,uuid,numeric),public.property_video_job_resume_before_delivery_20261015(uuid,uuid,numeric)from public,anon,authenticated;
grant execute on function public.property_video_delivery_receipt(uuid,uuid),public.property_video_delivery_resume_available(uuid),public.property_video_delivery_history_guard(),public.property_video_job_result_read_failure(uuid,uuid,uuid,text),public.property_video_job_resume(uuid,uuid,numeric),public.property_video_job_resume_before_delivery_20261015(uuid,uuid,numeric)to service_role;
commit;
