-- Rollback-only negative controls for the dormant aerial credit tariff.
-- All KIE and media receipts below are synthetic; no provider is contacted.
begin;
create temporary table fair_checks(n integer not null default 0);
insert into fair_checks default values;
grant all on fair_checks to service_role;
create function pg_temp.fair_ok(v boolean,label text) returns void language plpgsql as $$
begin
 if v is distinct from true then raise exception 'AERIAL FAIR FAIL: %',label;end if;
 update fair_checks set n=n+1;
end$$;
create function pg_temp.fair_refuses(statement text,needle text,label text)
returns void language plpgsql as $$
begin
 begin execute statement;exception when others then
  if position(needle in sqlerrm)>0 then perform pg_temp.fair_ok(true,label);return;end if;
  raise;
 end;
 raise exception 'AERIAL FAIR FAIL admitted: %',label;
end$$;
create function pg_temp.fair_claim(p_job uuid,p_lease uuid)
returns void language sql security definer set search_path='' as $$
 update public.property_video_aerial_openings set generation_lease=p_lease,
   generation_claimed_at=now(),state='dispatching' where id=p_job
$$;
grant execute on function pg_temp.fair_claim(uuid,uuid) to service_role;
create function pg_temp.fair_ready(p_job uuid)
returns void language sql security definer set search_path='' as $$
 update public.property_video_aerial_openings set
  qualified_output=jsonb_build_object('etag','"retained-fixture"','sha256',repeat('e',64)),
  quality=jsonb_build_object('action','accept','verdict','pass',
    'publishable',true,'output_sha256',repeat('e',64)),
  state='ready_for_acceptance' where id=p_job
$$;
grant execute on function pg_temp.fair_ready(uuid) to service_role;
create function pg_temp.fair_claim_old(p_job uuid,p_lease uuid)
returns void language sql security definer set search_path='' as $$
 update public.property_video_aerial_openings
  set generation_lease=p_lease,generation_claimed_at=now()-interval '49 hours',
    state='dispatching' where id=p_job
$$;
grant execute on function pg_temp.fair_claim_old(uuid,uuid) to service_role;
create temporary table fair_source(manifest jsonb,quote jsonb,consent jsonb);
insert into fair_source select manifest,quote,consent
 from public.property_video_aerial_openings
 where operation_id='a0444444-4444-4444-8444-444444444444';
grant select on fair_source to service_role;

-- Four $1 worst-case reservations plus real saved loss/open holds exhaust the
-- per-workspace $5 rolling failure cap. The failed admission must reserve no
-- extra wallet credit and create no additional aerial job.
create temporary table fair_cap_ids(hold_id uuid);
with seeded as(
 insert into public.credit_aerial_failure_budget(hold_id,job_id,billing_org_id,
  environment,maximum_cents)
 select gen_random_uuid(),gen_random_uuid(),
  'a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Production',100
  from generate_series(1,4) returning hold_id)
insert into fair_cap_ids select hold_id from seeded;
set local role service_role;
do $$
declare m jsonb;q jsonb;c jsonb;op uuid:='a0cccccc-cccc-4ccc-8ccc-cccccccccccc';
begin
 select manifest,quote,consent into m,q,c from fair_source;
 m:=jsonb_set(m,'{operation_id}',to_jsonb(op));
 q:=jsonb_set(q,'{manifest_sha256}',to_jsonb(encode(sha256(convert_to(m::text,'UTF8')),'hex')));
 perform pg_temp.fair_refuses(format(
  'select public.property_video_aerial_admit_credit(%L,%L::jsonb,%L::jsonb,%L::jsonb,%L,%L)',
  'a0111111-1111-4111-8111-111111111111',m,q,c,'Production','aerial-opening-v1'),
  'RP402: The bounded aerial supplier-failure budget is full',
  'parallel failure exposure cannot exceed the workspace cap');
 perform pg_temp.fair_ok(not exists(select 1 from public.credit_holds
   where request_key='aerial-opening:'||op),
  'failure-budget denial spends no customer credits');
end$$;
reset role;
delete from public.credit_aerial_failure_budget where hold_id in(select hold_id from fair_cap_ids);

create temporary table fair_global_ids(hold_id uuid);
with seeded as(
 insert into public.credit_aerial_failure_budget(hold_id,job_id,billing_org_id,
  environment,maximum_cents)
 select gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),'Production',100
  from generate_series(1,50) returning hold_id)
insert into fair_global_ids select hold_id from seeded;
set local role service_role;
do $$
declare m jsonb;q jsonb;c jsonb;op uuid:='a0cccccc-cccc-4ccc-8ccc-cccccccccccc';
begin
 select manifest,quote,consent into m,q,c from fair_source;
 m:=jsonb_set(m,'{operation_id}',to_jsonb(op));
 q:=jsonb_set(q,'{manifest_sha256}',to_jsonb(encode(sha256(convert_to(m::text,'UTF8')),'hex')));
 perform pg_temp.fair_refuses(format(
  'select public.property_video_aerial_admit_credit(%L,%L::jsonb,%L::jsonb,%L::jsonb,%L,%L)',
  'a0111111-1111-4111-8111-111111111111',m,q,c,'Production','aerial-opening-v1'),
  'RP402: The bounded aerial supplier-failure budget is full',
  'parallel workspaces cannot exceed the global supplier-loss cap');
end$$;
reset role;
delete from public.credit_aerial_failure_budget where hold_id in(select hold_id from fair_global_ids);

set local role service_role;
do $$
declare actor uuid:='a0111111-1111-4111-8111-111111111111';
 org uuid:='a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 m jsonb;q jsonb;c jsonb; j public.property_video_aerial_openings;
 lease uuid:='a0bbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';r jsonb;
 before_ integer; after_ integer;
begin
 select manifest,quote,consent into m,q,c from fair_source;
 m:=jsonb_set(m,'{operation_id}',to_jsonb('a0dddddd-dddd-4ddd-8ddd-dddddddddddd'::uuid));
 q:=jsonb_set(q,'{manifest_sha256}',to_jsonb(encode(sha256(convert_to(m::text,'UTF8')),'hex')));
 before_:=(public.credit_wallet_state(org,'Production')->>'total_available')::integer;
 j:=public.property_video_aerial_admit_credit(actor,m,q,c,'Production','aerial-opening-v1');
 perform pg_temp.fair_claim(j.id,lease);
 r:=jsonb_build_object('provider','kie','model','kling-3.0/video',
   'id','aerial-fair-ready','submitted_at',now(),
   'poll_url','https://api.kie.ai/api/v1/jobs/recordInfo?taskId=aerial-fair-ready');
 perform public.property_video_aerial_receipt(j.id,lease,r);
 perform pg_temp.fair_ok((select state='reserved' from public.credit_holds
   where request_key='aerial-opening:'||j.operation_id)
   and (public.credit_wallet_state(org,'Production')->>'total_available')::integer=before_-20,
   'billable KIE acceptance alone does not settle customer');
 perform pg_temp.fair_ready(j.id);
 perform public.credit_aerial_customer_finish(j.id);
 perform pg_temp.fair_ok((select state='settled' from public.credit_holds
   where request_key='aerial-opening:'||j.operation_id)
   and (select state='released' and spent_cents=0 from public.credit_aerial_failure_budget
     where job_id=j.id)
   and (select count(*)=5 from public.serving_cost_reservations
     where request_key='aerial-opening:'||j.operation_id and budget_source='credits'),
   'verified ready opening alone settles customer and releases failure risk');
 perform public.credit_aerial_customer_finish(j.id);
 perform pg_temp.fair_ok((public.credit_wallet_state(org,'Production')->>'total_available')::integer=before_-20,
   'ready replay never charges twice');

 m:=jsonb_set(m,'{operation_id}',to_jsonb('a0eeeeee-eeee-4eee-8eee-eeeeeeeeeeee'::uuid));
 q:=jsonb_set(q,'{manifest_sha256}',to_jsonb(encode(sha256(convert_to(m::text,'UTF8')),'hex')));
 before_:=(public.credit_wallet_state(org,'Production')->>'total_available')::integer;
 j:=public.property_video_aerial_admit_credit(actor,m,q,c,'Production','aerial-opening-v1');
 perform pg_temp.fair_claim_old(j.id,lease);
 perform pg_temp.fair_ok((select state='reserved' from public.credit_holds
   where request_key='aerial-opening:'||j.operation_id)
   and (public.credit_wallet_state(org,'Production')->>'total_available')::integer=before_-20,
   'crashed dispatch without a KIE receipt keeps credits reserved for reconciliation');
 perform public.credit_aerial_hold_reconcile(100);
 perform pg_temp.fair_ok((select state='released' from public.credit_holds
   where request_key='aerial-opening:'||j.operation_id)
   and (select state='spent' and spent_cents>=45 from public.credit_aerial_failure_budget
     where job_id=j.id)
   and (public.credit_wallet_state(org,'Production')->>'total_available')::integer=before_,
   'aged unknown supplier liability refunds customer and retains full risk');
 perform public.property_video_aerial_ambiguous(j.id,lease);
 perform public.property_video_aerial_reject_before_dispatch(j.id,lease,0,'validation');
 perform pg_temp.fair_ok((select state='cancelled' from public.property_video_aerial_worker_read(j.id))
   and (select released_at is null from public.app_video_cost_reservations
     where idempotency_key='aerial-opening:'||j.operation_id),
   'late ambiguous or rejection callback cannot resurrect or erase supplier liability');
 r:=jsonb_build_object('provider','kie','model','kling-3.0/video',
   'id','aerial-fair-late','submitted_at',now(),
   'poll_url','https://api.kie.ai/api/v1/jobs/recordInfo?taskId=aerial-fair-late');
 perform public.property_video_aerial_receipt(j.id,lease,r);
 after_:=(public.credit_wallet_state(org,'Production')->>'total_available')::integer;
 perform pg_temp.fair_ok(after_=before_
   and (select state='released' from public.credit_holds where request_key='aerial-opening:'||j.operation_id)
   and (select provider_request_id='aerial-fair-late' and cost_ledger_id is not null
     from public.app_video_cost_reservations where idempotency_key='aerial-opening:'||j.operation_id)
   and (select state='cancelled' from public.property_video_aerial_worker_read(j.id)),
   'late KIE receipt stays billable without recharging refunded customer');
end$$;
reset role;
select pg_temp.fair_ok(not has_function_privilege('service_role',
 'public.property_video_aerial_quality(uuid,uuid,jsonb)','EXECUTE'),
 'direct quality RPC cannot bypass customer charge boundary');
select jsonb_build_object('passed',true,'assertions',(select n from fair_checks));
rollback;
