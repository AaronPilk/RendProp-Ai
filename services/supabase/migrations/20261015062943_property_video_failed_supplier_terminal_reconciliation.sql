-- A recipe failure does not make its other accepted supplier requests terminal.
-- Reconcile their existing paid receipts through the same metadata-only cron
-- path as cancelled jobs; unknown acceptance keeps its slot and money hold.
-- Only the two job-state guards change. No generation, funding or retry authority.
begin;
create or replace function public.property_video_cancelled_attempts()returns jsonb language plpgsql security definer set search_path=''as $$declare rows jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 with candidates as(select s.job_id,s.position from public.property_video_job_sources s join public.property_video_jobs j on j.id=s.job_id where j.state in('cancelled','needs_reconciliation','failed')and s.receipt is not null and s.provider_terminal_at is null and(s.provider_status_checked_at is null or s.provider_status_checked_at<now()-interval'30 seconds')order by j.created_at,s.position for update of s skip locked limit 4),touched as(update public.property_video_job_sources s set provider_status_checked_at=now()from candidates c where s.job_id=c.job_id and s.position=c.position returning s.*)
 select coalesce(jsonb_agg(jsonb_build_object('job_id',j.id,'actor_id',j.actor_id,'org_id',j.org_id,'listing_id',j.listing_id,'attempt_id',s.attempt_id,'request_key',s.request_key,'receipt',s.receipt,'provider',r.provider,'model',r.model)),'[]'::jsonb)into rows from touched s join public.property_video_jobs j on j.id=s.job_id join public.app_video_cost_reservations r on r.actor_id=j.actor_id and r.org_id=j.org_id and r.idempotency_key=s.request_key and r.feature='reel'and r.model=s.receipt->>'model_id'and(r.provider_request_id is null or r.provider_request_id=s.receipt->>'request_id')and r.released_at is null;return rows;end$$;
create or replace function public.property_video_cancelled_terminal(p_job uuid,p_attempt uuid,p_request text,p_provider text,p_model text)returns boolean language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;s public.property_video_job_sources;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into j from public.property_video_jobs where id=p_job for update;select * into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt for update;
 if j.id is null or s.job_id is null or j.state not in('cancelled','needs_reconciliation','failed')or s.receipt->>'request_id'is distinct from p_request or s.receipt->>'model_id'is distinct from p_model or not exists(select 1 from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key and feature='reel'and provider=p_provider and model=p_model and released_at is null and(provider_request_id is null or provider_request_id=p_request))then raise exception'RP409: Knowncancelled providerreceipt isunavailable';end if;
 update public.property_video_job_sources set provider_terminal_at=coalesce(provider_terminal_at,now())where job_id=p_job and attempt_id=p_attempt;return true;end$$;
revoke all on function public.property_video_cancelled_attempts(),public.property_video_cancelled_terminal(uuid,uuid,text,text,text)from public,anon,authenticated;
grant execute on function public.property_video_cancelled_attempts(),public.property_video_cancelled_terminal(uuid,uuid,text,text,text)to service_role;

commit;
