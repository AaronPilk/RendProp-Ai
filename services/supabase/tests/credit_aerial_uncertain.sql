-- Unknown KIE acceptance must retain the 20-credit hold across Stop. A later
-- exact accepted receipt settles that same hold without a second POST.
begin;
create temporary table uncertain_checks(n integer not null default 0);
insert into uncertain_checks default values;
grant all on uncertain_checks to service_role;
create function pg_temp.uncertain_ok(v boolean,label text) returns void language plpgsql as $$
begin
 if v is distinct from true then raise exception 'AERIAL UNCERTAIN FAIL: %',label;end if;
 update uncertain_checks set n=n+1;
end$$;
create function pg_temp.claim_uncertain_aerial(p_job uuid,p_lease uuid)
returns void language sql security definer set search_path='' as $$
 update public.property_video_aerial_openings set generation_lease=p_lease,
  generation_claimed_at=now(),state='dispatching' where id=p_job
$$;
grant execute on function pg_temp.claim_uncertain_aerial(uuid,uuid) to service_role;
create temporary table uncertain_job(id uuid,actor uuid,org uuid,lease uuid);
insert into uncertain_job
select id,actor_id,billing_org_id,'a0bbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid
from public.property_video_aerial_openings
where operation_id='a0777777-7777-4777-8777-777777777777';
grant select on uncertain_job to service_role;
set local role service_role;
do $$
declare j uncertain_job%rowtype;r jsonb;
begin
 select * into j from uncertain_job;
 perform pg_temp.uncertain_ok(j.id is not null,'concurrent request has one saved job');
 perform pg_temp.claim_uncertain_aerial(j.id,j.lease);
 perform public.property_video_aerial_ambiguous(j.id,j.lease);
 perform public.property_video_aerial_cancel(j.actor,j.id);
 perform public.property_video_aerial_release_future(j.id);
 perform pg_temp.uncertain_ok(
  (select state='reserved' from public.credit_holds
    where request_key='aerial-opening:a0777777-7777-4777-8777-777777777777')
  and (select state='uncertain' from public.serving_cost_reservations
    where request_key='aerial-opening:a0777777-7777-4777-8777-777777777777'
      and stage='aerial')
  and (select released_at is null and cost_ledger_id is null
    from public.app_video_cost_reservations
    where idempotency_key='aerial-opening:a0777777-7777-4777-8777-777777777777')
  and (select future_reconciled_at is null and message like 'Confirming the supplier outcome%'
    from public.property_video_aerial_worker_read(j.id))
  and (public.credit_wallet_state(j.org,'Production')->>'total_available')::integer=60,
  'Stop cannot refund or hide an uncertain KIE submission from recovery');
 r:=jsonb_build_object('provider','kie','model','kling-3.0/video',
   'id','aerial-late-accepted','submitted_at',now(),
   'poll_url','https://api.kie.ai/api/v1/jobs/recordInfo?taskId=aerial-late-accepted');
 perform public.property_video_aerial_receipt(j.id,j.lease,r);
 perform public.property_video_aerial_release_future(j.id);
 perform pg_temp.uncertain_ok(
  (select state='settled' from public.credit_holds
    where request_key='aerial-opening:a0777777-7777-4777-8777-777777777777')
  and (select cost_ledger_id is not null and provider_request_id='aerial-late-accepted'
    from public.app_video_cost_reservations
    where idempotency_key='aerial-opening:a0777777-7777-4777-8777-777777777777')
  and (select future_reconciled_at is not null
    from public.property_video_aerial_worker_read(j.id))
  and (public.credit_wallet_state(j.org,'Production')->>'total_available')::integer=60,
  'late exact KIE receipt settles same hold after Stop without new credits');
end$$;
reset role;
select jsonb_build_object('passed',true,'assertions',(select n from uncertain_checks));
rollback;
