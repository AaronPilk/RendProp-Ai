-- Customer-credit Photo Motion is dormant until a reviewed policy activates it.
-- This migration completes its separate supplier-loss journal and terminal
-- accounting. Old jobs and plan-funded Photo Motion remain on their old path.
begin;

create table public.credit_photo_motion_failure_budget(
  hold_id uuid primary key,
  reservation_id uuid not null unique,
  job_id uuid unique,
  operation_id uuid not null,
  billing_org_id uuid not null,
  environment text not null check(environment in('Production','Sandbox')),
  maximum_cents numeric not null check(maximum_cents>0 and maximum_cents<=100),
  spent_cents numeric not null default 0 check(spent_cents>=0 and spent_cents<=maximum_cents),
  state text not null default 'reserved' check(state in('reserved','spent','released')),
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  check((state='reserved' and finished_at is null and spent_cents=0)
    or(state='released' and finished_at is not null and spent_cents=0)
    or(state='spent' and finished_at is not null and spent_cents>0)));
create index credit_pm_failure_daily on public.credit_photo_motion_failure_budget(state,finished_at);
create index credit_pm_failure_daily_org on public.credit_photo_motion_failure_budget(billing_org_id,state,finished_at);
alter table public.credit_photo_motion_failure_budget enable row level security;
revoke all on public.credit_photo_motion_failure_budget from public,anon,authenticated,service_role;
grant select on public.credit_photo_motion_failure_budget to service_role;

alter table public.serving_cost_reservations
  drop constraint serving_cost_reservations_budget_source_check;
alter table public.serving_cost_reservations
  add constraint serving_cost_reservations_budget_source_check
  check(budget_source in('funding','ceiling','credits','aerial_failure','video_failure'));
alter table public.serving_cost_reservations
  drop constraint serving_cost_reservations_check;
alter table public.serving_cost_reservations
  add constraint serving_cost_reservations_check check(
    (sponsored_unlimited and budget_source='funding' and funding_id is null and slice_index is null and credit_hold_id is null)
    or(not sponsored_unlimited and budget_source='ceiling' and funding_id is null and slice_index is null and credit_hold_id is null)
    or(not sponsored_unlimited and budget_source='funding' and funding_id is not null and slice_index is not null and credit_hold_id is null)
    or(not sponsored_unlimited and budget_source in('credits','aerial_failure','video_failure')
      and funding_id is null and slice_index is null and credit_hold_id is not null));
alter table public.serving_cost_reservations
  drop constraint serving_cost_reservations_credit_environment_check;
alter table public.serving_cost_reservations
  add constraint serving_cost_reservations_credit_environment_check check(
    (budget_source in('credits','aerial_failure','video_failure') and credit_environment in('Production','Sandbox'))
    or(budget_source not in('credits','aerial_failure','video_failure') and credit_environment is null));

-- Reserve the whole possible failure loss before new work starts. The global
-- advisory lock serializes admissions, while terminal releases only reduce
-- the outstanding risk and cannot create an undercount.
do $patch$ declare definition text;anchor text;replacement text;begin
  definition:=pg_get_functiondef('public.credit_photo_motion_fund(uuid,uuid,uuid,text,jsonb,text)'::regprocedure);
  anchor:='perform pg_advisory_xact_lock(hashtextextended(
    ''credit-wallet:''||p_billing||'':''||p_environment,71003));';
  replacement:=E'perform pg_advisory_xact_lock(hashtextextended(''credit-photo-motion-failure-budget'',71006));\n  if (select coalesce(sum(case when state=''reserved'' then maximum_cents else spent_cents end),0)\n    from public.credit_photo_motion_failure_budget\n    where state=''reserved'' or(state=''spent'' and finished_at>=now()-interval ''1 day''))\n    +quote_cents>5000\n    or (select coalesce(sum(case when state=''reserved'' then maximum_cents else spent_cents end),0)\n    from public.credit_photo_motion_failure_budget\n    where billing_org_id=p_billing and\n      (state=''reserved'' or(state=''spent'' and finished_at>=now()-interval ''1 day'')))\n    +quote_cents>500 then\n    raise exception ''RP402: The bounded Photo Motion supplier-failure budget is full'';end if;\n  '||anchor;
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed Photo Motion funding lock order';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='quoted->>''quote_sha256'',quote_cents,price);';
  replacement:=anchor||E'\n  insert into public.credit_photo_motion_failure_budget(hold_id,reservation_id,operation_id,\n    billing_org_id,environment,maximum_cents)\n    values(hold_id,reservation_id,(p_manifest->>''operation_id'')::uuid,\n      p_billing,p_environment,quote_cents);';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed Photo Motion quote persistence';end if;
  execute replace(definition,anchor,replacement);
  definition:=pg_get_functiondef('public.credit_photo_motion_job_bind()'::regprocedure);
  anchor:='where hold_id=q.hold_id and job_id is null;';
  replacement:=anchor||E'\n  update public.credit_photo_motion_failure_budget set job_id=new.id\n    where hold_id=q.hold_id and reservation_id=r.id and job_id is null;\n  if not found then raise exception ''RP409: Photo Motion failure budget lost its job binding'';end if;';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed Photo Motion job binding';end if;
  execute replace(definition,anchor,replacement);
end $patch$;

-- Photo Motion writes one cost-ledger row per measured CPU phase rather than
-- setting the whole reservation's ledger_id. Add back only exactly bound
-- partial rows while the customer credit hold is still reserved or settled.
-- A refunded failed video changes budget_source to video_failure, so its
-- supplier bill stays in the noncredit spend ledger.
do $patch$ declare definition text;anchor text;replacement text;begin
  definition:=pg_get_functiondef('public.credit_combined_budget_state(uuid)'::regprocedure);
  anchor:='and v.cost_ledger_id is not null)';
  replacement:=E'and v.cost_ledger_id is not null\n      union select c.ledger_id from public.property_video_pm_server_costs c\n        join public.credit_photo_motion_quotes q on q.job_id=c.job_id and q.reservation_id=c.reservation_id\n        join public.serving_cost_reservations r on r.id=q.reservation_id\n        join public.credit_holds h on h.id=q.hold_id\n        join public.property_video_pm_cost_eligibility e on e.job_id=q.job_id and e.reservation_id=r.id\n        where q.billing_org_id=b and q.environment=''Production''\n          and r.billing_org_id=b and r.budget_source=''credits''\n          and r.credit_hold_id=q.hold_id and r.credit_environment=''Production''\n          and h.org_id=b and h.environment=''Production'' and h.state in(''reserved'',''settled'')\n          and h.actor_id=q.actor_id and h.request_key=r.request_key\n          and h.operation=''video.photo_motion'' and h.tariff_version=''photo-motion-quoted-v1''\n          and c.accounting_state=''recorded'' and c.ledger_id is not null\n          and e.manifest_sha256=q.manifest_sha256 and e.billing_org_id=b)';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed combined credit partial-CPU linkage';end if;
  execute replace(definition,anchor,replacement);
end $patch$;

create function public.credit_photo_motion_reconcile(p_job uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare q public.credit_photo_motion_quotes;j public.property_video_jobs;
  r public.serving_cost_reservations;h public.credit_holds;
  risk public.credit_photo_motion_failure_budget;
  observed integer;recorded integer;missing integer;grace timestamptz;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege;end if;
  select * into q from public.credit_photo_motion_quotes where job_id=p_job;
  if q.job_id is null then return jsonb_build_object('applicable',false);end if;
  perform pg_advisory_xact_lock(hashtextextended('serving:'||q.billing_org_id,72452));
  perform pg_advisory_xact_lock(hashtextextended('serving:'||q.content_org_id,72452));
  perform pg_advisory_xact_lock(hashtextextended('credit-wallet:'||q.billing_org_id||':'||q.environment,71003));
  select * into q from public.credit_photo_motion_quotes where job_id=p_job for update;
  select * into j from public.property_video_jobs where id=p_job for update;
  select * into r from public.serving_cost_reservations where id=q.reservation_id for update;
  select * into h from public.credit_holds where id=q.hold_id for update;
  select * into risk from public.credit_photo_motion_failure_budget where hold_id=q.hold_id for update;
  if j.id is null or r.id is null or h.id is null or risk.hold_id is null or
     row(j.operation_id,j.actor_id,j.org_id,j.manifest_sha256) is distinct from
       row(q.operation_id,q.actor_id,q.content_org_id,q.manifest_sha256) or
     row(r.id,r.org_id,r.billing_org_id,r.actor_id,r.request_key,r.stage,
       r.provider,r.model,r.input_sha256,r.hold_cents,r.credit_hold_id,
       r.credit_environment) is distinct from
       row(q.reservation_id,q.content_org_id,q.billing_org_id,q.actor_id,
       'photomotion:'||q.operation_id,'photo_motion','cloudflare',
       'container-standard-3',q.manifest_sha256,q.maximum_supplier_cents,
       q.hold_id,q.environment) or
     row(h.org_id,h.actor_id,h.environment,h.request_key,h.operation,
       h.tariff_version,h.credits) is distinct from
       row(q.billing_org_id,q.actor_id,q.environment,
       'photomotion:'||q.operation_id,'video.photo_motion',
       'photo-motion-quoted-v1',q.credits) or
     row(risk.reservation_id,risk.job_id,risk.operation_id,
       risk.billing_org_id,risk.environment,risk.maximum_cents) is distinct from
       row(q.reservation_id,p_job,q.operation_id,q.billing_org_id,
       q.environment,q.maximum_supplier_cents) then
    raise exception 'RP409: Photo Motion customer, job and supplier funding changed';end if;
  if h.state='settled' and risk.state='released' then
    return jsonb_build_object('applicable',true,'state','settled','replay',true);end if;
  if h.state='released' and risk.state in('spent','released') then
    if j.state='ready' then raise exception 'RP409: Refunded Photo Motion became ready';end if;
    return jsonb_build_object('applicable',true,'state','released','replay',true);end if;
  if h.state<>'reserved' or risk.state<>'reserved' or r.budget_source<>'credits' then
    raise exception 'RP409: Photo Motion financial outcome is inconsistent';end if;
  if j.state='ready' then
    -- An earlier failed CPU attempt can set the supplier reservation to
    -- uncertain before a later, valid compose attempt finishes. The final
    -- verified outputs and completed observation still earn one settlement.
    if r.state not in('succeeded','uncertain') or j.result is null or
       (select count(*) from public.property_video_job_outputs o
         where o.job_id=p_job and o.state='ready' and o.etag is not null)<>2 or
       not exists(select 1 from public.property_video_photo_motion_observations o
         where o.job_id=p_job and o.phase='compose' and o.outcome='completed') then
      return jsonb_build_object('applicable',true,'state','waiting_for_ready_receipts');end if;
    perform public.credit_wallet_finish(j.actor_id,q.billing_org_id,q.environment,
      'photomotion:'||j.operation_id,'settled');
    update public.credit_photo_motion_failure_budget set state='released',finished_at=now()
      where hold_id=q.hold_id;
    return jsonb_build_object('applicable',true,'state','settled','credits',q.credits);
  end if;
  if j.state not in('failed','cancelled') then
    return jsonb_build_object('applicable',true,'state','in_progress');end if;
  select count(*),count(*) filter(where c.accounting_state='recorded')
    into observed,recorded from public.property_video_photo_motion_observations o
    left join public.property_video_pm_server_costs c on c.job_id=o.job_id
      and c.phase=o.phase and c.lease_token=o.lease_token
    where o.job_id=p_job;
  missing:=greatest(0,coalesce(j.compose_attempts,0)+coalesce(j.audio_attempts,0)-observed);
  grace:=coalesce(j.cancelled_at,j.updated_at,j.deadline);
  if missing>0 and grace>now()-interval '48 hours' then
    return jsonb_build_object('applicable',true,'state','awaiting_cpu_outcome',
      'missing_observations',missing);end if;
  if observed=0 and missing=0 then
    if r.state='reserved' then
      perform public.serving_cost_finish(j.actor_id,j.org_id,
        'photomotion:'||j.operation_id,'photo_motion','rejected',0);
    elsif r.state<>'rejected' then
      raise exception 'RP409: Unworked Photo Motion has a supplier liability';end if;
    perform public.credit_wallet_finish(j.actor_id,q.billing_org_id,q.environment,
      'photomotion:'||j.operation_id,'released');
    update public.credit_photo_motion_failure_budget set state='released',finished_at=now()
      where hold_id=q.hold_id;
    return jsonb_build_object('applicable',true,'state','released','supplier_cents',0);
  end if;
  -- Any CPU attempt or uncertain callback may incur a bill. Retain the full
  -- conservative supplier quote in the failure ledger for 24 hours, refund
  -- the customer, and never recycle this job into a second charge.
  if r.state='rejected' then
    raise exception 'RP409: Observed Photo Motion liability was rejected';end if;
  update public.serving_cost_reservations set budget_source='video_failure'
    where id=r.id and budget_source='credits';
  update public.credit_photo_motion_failure_budget set
    state='spent',spent_cents=maximum_cents,finished_at=now()
    where hold_id=q.hold_id;
  perform public.credit_wallet_finish(j.actor_id,q.billing_org_id,q.environment,
    'photomotion:'||j.operation_id,'released');
  return jsonb_build_object('applicable',true,'state','released',
    'supplier_risk_cents',q.maximum_supplier_cents,
    'missing_observations',missing,'recorded_observations',recorded);
end$$;
revoke all on function public.credit_photo_motion_reconcile(uuid)
  from public,anon,authenticated;
grant execute on function public.credit_photo_motion_reconcile(uuid)
  to service_role;

create function public.credit_photo_motion_reconcile_all(p_limit integer default 50)
returns integer language plpgsql security definer set search_path='' as $$
declare candidate record;completed integer:=0;
begin
  if current_setting('role',true) is distinct from 'service_role' or
     p_limit not between 1 and 100 then raise insufficient_privilege;end if;
  for candidate in select q.job_id from public.credit_photo_motion_quotes q
    join public.credit_holds h on h.id=q.hold_id
    join public.property_video_jobs j on j.id=q.job_id
    where h.state='reserved' and j.state in('ready','failed','cancelled')
    order by j.updated_at limit p_limit loop
    begin
      perform public.credit_photo_motion_reconcile(candidate.job_id);
      completed:=completed+1;
    exception when others then
      -- An individual uncertain customer outcome remains reserved for
      -- investigation; one broken receipt cannot starve other jobs.
      null;
    end;
  end loop;
  return completed;
end$$;
revoke all on function public.credit_photo_motion_reconcile_all(integer)
  from public,anon,authenticated;
grant execute on function public.credit_photo_motion_reconcile_all(integer)
  to service_role;

do $schedule$ begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    perform cron.schedule('credit-photo-motion-reconcile','*/5 * * * *',
      'set role service_role;select public.credit_photo_motion_reconcile_all(50);');
  else
    raise notice 'credit_photo_motion: pg_cron unavailable; schedule the bounded reconciler externally.';
  end if;
end $schedule$;

-- Terminal code is installed but still cannot turn on retail by migration.
-- Activation needs an explicit later reviewed configuration and the matching
-- native quoted-charge flow. This replacement only allows that future step.
create or replace function public.credit_photo_motion_activation_guard()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.key='credit_photo_motion' and new.value->'enabled'='true'::jsonb and
    (new.value->'activation_ready' is distinct from 'true'::jsonb or
     new.value->>'revision' is distinct from 'photo-motion-quoted-v1' or
     new.value->>'cents_per_credit' is distinct from '5' or
     new.value->>'max_quote_cents' is distinct from '100') then
    raise exception 'RP409: Photo Motion credit release is not approved';end if;
  return new;
end$$;
commit;
