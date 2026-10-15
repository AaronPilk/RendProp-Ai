-- One explicit replacement for a paid FAL receipt whose exact status AND result
-- endpoints both return404. The prior charge is retained, never refunded.
begin;
alter table public.property_video_job_sources add column if not exists paid_replacements integer not null default 0 check(paid_replacements between 0 and 1);
alter table public.property_video_job_sources add column if not exists paid_replacement_history jsonb not null default'[]'::jsonb check(jsonb_typeof(paid_replacement_history)='array');
alter table public.property_video_job_sources add column if not exists missing_result_evidence jsonb;
create or replace function public.property_video_missing_result_receipt(p_job uuid,p_attempt uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;e jsonb;r public.app_video_cost_reservations;paid public.cost_ledger;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 j:=public.property_video_job_scope(p_job,null,false);select *into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt;
 if j.cancelled_at is not null or j.deadline<=now()or s.job_id is null or s.state not in('processing','failed')or s.clip is not null then return null;end if;
 e:=public.property_video_delivery_receipt(p_job,p_attempt);
 if e is null or exists(select 1 from public.media_provenance where id=s.generation_provenance_id and qc is not null and qc<>'null'::jsonb and qc<>'{}'::jsonb)then return null;end if;
 select *into r from public.app_video_cost_reservations where id=(e->>'paid_reservation_id')::uuid;select *into paid from public.cost_ledger where id=(e->>'paid_ledger_id')::uuid;
 return e||jsonb_build_object('paid_total_cents',r.total_cents,'ledger_total_cents',paid.total_cents,'paid_settled_at',r.settled_at,'paid_input_sha256',r.input_sha256,'manifest_sha256',j.manifest_sha256,'quality_profile',j.quality_profile);end$$;
create or replace function public.property_video_job_result_missing(p_job uuid,p_lease uuid,p_attempt uuid)returns boolean
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;e jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 j:=public.property_video_job_scope(p_job,null,false);select *into j from public.property_video_jobs where id=p_job for update;
 select *into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt for update;
 e:=public.property_video_missing_result_receipt(p_job,p_attempt);
 if e is null then raise exception'RP409: An exact current paid FAL receipt without a reviewed clip is required';end if;
 if s.missing_result_evidence->>'lease'=p_lease::text and s.missing_result_evidence->'paid_receipt'=e then return true;end if;
 perform public.property_video_job_worker_scope(p_job,p_lease,p_attempt);
 if s.state<>'processing'or s.missing_result_evidence is not null then raise exception'RP409: This saved receipt is not awaiting its first missing-result decision';end if;
 update public.property_video_job_sources set missing_result_evidence=jsonb_build_object('phase','status_and_result_read','provider','fal','status',404,'result_status',404,'lease',p_lease,'paid_receipt',e,'observed_at',now()),
  state='failed',last_error='provider_result_missing',lease_until=null,provider_terminal_at=coalesce(provider_terminal_at,now())where job_id=p_job and attempt_id=p_attempt;
 update public.property_video_jobs set state='failed',message=case when s.paid_replacements>=1 then'The replacement clip is also unavailable. Its paid receipts and finished clips are retained; contact support for help.'else'The service cannot retrieve one paid clip. Resume creates one replacement for that affected shot using your normal allowance; its earlier charge remains recorded. Saved clips and photo order are unchanged.'end,updated_at=now()where id=p_job;
 return true;end$$;
create or replace function public.property_video_missing_result_resume_available(p_job uuid)returns boolean
language plpgsql stable security definer set search_path=''as $$declare j public.property_video_jobs;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 j:=public.property_video_job_scope(p_job,null,false);
 return j.state='failed'and j.cancelled_at is null and j.deadline>now()
  and exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and s.state='failed'and s.last_error='provider_result_missing'and s.paid_replacements=0 and(s.lease_until is null or s.lease_until<=now())
   and s.missing_result_evidence->>'phase'='status_and_result_read'and s.missing_result_evidence->>'provider'='fal'and s.missing_result_evidence->>'status'='404'and s.missing_result_evidence->>'result_status'='404'
   and s.missing_result_evidence->'paid_receipt'=public.property_video_missing_result_receipt(p_job,s.attempt_id))
  and not exists(select 1 from public.property_video_job_sources s where s.job_id=p_job and(s.state='ambiguous'or(s.state='failed'and(s.last_error<>'provider_result_missing'or s.paid_replacements<>0 or s.lease_until>now()
   or s.missing_result_evidence->>'phase'is distinct from'status_and_result_read'or s.missing_result_evidence->>'provider'is distinct from'fal'or s.missing_result_evidence->>'status'is distinct from'404'or s.missing_result_evidence->>'result_status'is distinct from'404'
   or public.property_video_missing_result_receipt(p_job,s.attempt_id)is null or s.missing_result_evidence->'paid_receipt'is distinct from public.property_video_missing_result_receipt(p_job,s.attempt_id)))));end$$;
create or replace function public.property_video_paid_replacement_history_guard()returns trigger
language plpgsql security definer set search_path=''as $$declare e jsonb;begin
 if new.paid_replacements<old.paid_replacements then raise exception'RP409: A paid replacement cannot be reset';end if;
 if new.paid_replacement_history is distinct from old.paid_replacement_history or new.paid_replacements<>old.paid_replacements then
  if old.paid_replacements<>0 or new.paid_replacements<>1 or jsonb_array_length(new.paid_replacement_history)<>1 then raise exception'RP409: Paid replacement history is append-only and bounded once';end if;
  e:=public.property_video_missing_result_receipt(old.job_id,old.attempt_id);
  if not public.property_video_missing_result_resume_available(old.job_id)or e is null or old.paid_replacements<>0 or new.paid_replacements<>1
   or new.paid_replacement_history is distinct from jsonb_build_array(jsonb_build_object('prior_source',to_jsonb(old)-'paid_replacement_history','paid_receipt',e,'missing_evidence',old.missing_result_evidence,'recovered_at',(new.paid_replacement_history->0)->'recovered_at'))
   or(new.paid_replacement_history->0)->>'recovered_at'is null
   or(to_jsonb(new)-array['state','attempt_id','request_key','receipt','generation_provenance_id','lease_token','lease_until','last_error','provider_terminal_at','paid_replacements','paid_replacement_history','missing_result_evidence'])is distinct from(to_jsonb(old)-array['state','attempt_id','request_key','receipt','generation_provenance_id','lease_token','lease_until','last_error','provider_terminal_at','paid_replacements','paid_replacement_history','missing_result_evidence'])
   then raise exception'RP409: Replacement must retain its exact paid missing receipt and all other source history';end if;
 end if;
 if old.missing_result_evidence is not null and new.missing_result_evidence is distinct from old.missing_result_evidence and not(old.paid_replacements=0 and new.paid_replacements=1 and new.missing_result_evidence is null and(new.paid_replacement_history->0)->'missing_evidence'=old.missing_result_evidence)then raise exception'RP409: Missing-result evidence is immutable';end if;
 return new;end$$;
drop trigger if exists property_video_paid_replacement_history_guard on public.property_video_job_sources;
create trigger property_video_paid_replacement_history_guard before update of paid_replacements,paid_replacement_history,missing_result_evidence on public.property_video_job_sources for each row execute function public.property_video_paid_replacement_history_guard();
do $$begin
 if to_regprocedure('public.property_video_job_resume_before_paid_replacement_20261015(uuid,uuid,numeric)')is null then
  if(select md5(prosrc)from pg_proc where oid='public.property_video_job_resume(uuid,uuid,numeric)'::regprocedure)is distinct from'31f27152c2bb8a228133b7f0dcd1c334'then raise exception'Review changed saved-video resume authority';end if;
  alter function public.property_video_job_resume(uuid,uuid,numeric)rename to property_video_job_resume_before_paid_replacement_20261015;
 elsif(select md5(prosrc)from pg_proc where oid='public.property_video_job_resume_before_paid_replacement_20261015(uuid,uuid,numeric)'::regprocedure)is distinct from'31f27152c2bb8a228133b7f0dcd1c334'then raise exception'Review changed previous saved-video resume authority';end if;
end$$;
do $$begin if to_regprocedure('public.property_video_job_resume(uuid,uuid,numeric)')is not null and(select md5(prosrc)from pg_proc where oid=to_regprocedure('public.property_video_job_resume(uuid,uuid,numeric)'))not in('31f27152c2bb8a228133b7f0dcd1c334','a17b39620d21ce8837b9486c2a969071')then raise exception'Review changed paid-result replacement authority';end if;end$$;
create or replace function public.property_video_job_resume(p_actor uuid,p_job uuid,p_quote numeric)returns public.property_video_jobs
language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;e jsonb;n integer;begin
 j:=public.property_video_job_scope(p_job,p_actor,false);select *into j from public.property_video_jobs where id=p_job for update;
 if public.property_video_missing_result_resume_available(p_job)then
  if p_quote is null or p_quote<=0 or p_quote::text in('NaN','Infinity','-Infinity')then raise exception'RP409: Price this replacement and remaining shots before resuming';end if;
  select count(*)into n from public.property_video_job_sources where job_id=p_job and state in('pending','failed');perform public.property_video_recipe_capacity(p_actor,j.listing_id,n,p_quote);
  for s in select *from public.property_video_job_sources where job_id=p_job and state='failed'order by position for update loop
   perform 1 from public.capture_assets where id=s.asset_id and listing_id=j.listing_id for share;
   perform 1 from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key for share;
   perform 1 from public.cost_ledger where id=(public.property_video_delivery_receipt(p_job,s.attempt_id)->>'paid_ledger_id')::uuid for share;
   e:=public.property_video_missing_result_receipt(p_job,s.attempt_id);if e is null or s.missing_result_evidence->'paid_receipt'is distinct from e then raise exception'RP409: The paid missing-result receipt changed';end if;
   update public.property_video_job_sources set paid_replacements=paid_replacements+1,
    paid_replacement_history=jsonb_build_array(jsonb_build_object('prior_source',to_jsonb(s)-'paid_replacement_history','paid_receipt',e,'missing_evidence',s.missing_result_evidence,'recovered_at',now())),
    state='pending',missing_result_evidence=null,attempt_id=null,request_key=null,receipt=null,generation_provenance_id=null,lease_token=null,lease_until=null,last_error=null,provider_terminal_at=null where job_id=p_job and position=s.position;
  end loop;
  update public.property_video_jobs set state='generating',message='Creating one replacement for the unavailable clip using your normal allowance. Its earlier charge remains recorded; finished clips, photo order and remaining planned shots are preserved.',updated_at=now()where id=p_job;
  return public.property_video_job_scope(p_job,p_actor,false);
 end if;
 return public.property_video_job_resume_before_paid_replacement_20261015(p_actor,p_job,p_quote);end$$;
revoke all on function public.property_video_missing_result_receipt(uuid,uuid),public.property_video_job_result_missing(uuid,uuid,uuid),public.property_video_missing_result_resume_available(uuid),public.property_video_paid_replacement_history_guard(),public.property_video_job_resume(uuid,uuid,numeric),public.property_video_job_resume_before_paid_replacement_20261015(uuid,uuid,numeric)from public,anon,authenticated;
grant execute on function public.property_video_missing_result_receipt(uuid,uuid),public.property_video_job_result_missing(uuid,uuid,uuid),public.property_video_missing_result_resume_available(uuid),public.property_video_paid_replacement_history_guard(),public.property_video_job_resume(uuid,uuid,numeric),public.property_video_job_resume_before_paid_replacement_20261015(uuid,uuid,numeric)to service_role;
commit;
