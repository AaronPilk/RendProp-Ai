-- Dormant aerial tariff repair. A supplier acceptance is a bill, not a usable
-- customer deliverable. A customer hold settles only after the qualified clip
-- reaches ready_for_acceptance; terminal failures release it. Supplier loss is
-- retained in a separate, finite risk journal, including an unknown KIE POST.
begin;

create table public.credit_aerial_failure_budget(
  -- Keep these UUIDs after hard deletion, as with the video cost tombstone.
  hold_id uuid primary key,
  job_id uuid not null unique,
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
create index credit_aerial_failure_daily on public.credit_aerial_failure_budget(state,finished_at);
create index credit_aerial_failure_daily_org on public.credit_aerial_failure_budget(billing_org_id,state,finished_at);
alter table public.credit_aerial_failure_budget enable row level security;
revoke all on public.credit_aerial_failure_budget from public,anon,authenticated,service_role;
grant select on public.credit_aerial_failure_budget to service_role;

-- The customer-credit journal and the supplier-loss journal are exclusive.
-- Preserve the immutable hold UUID for audit after a refund, but remove these
-- rows from the credit addback in credit_combined_budget_state.
alter table public.serving_cost_reservations
  drop constraint serving_cost_reservations_budget_source_check;
alter table public.serving_cost_reservations
  add constraint serving_cost_reservations_budget_source_check
  check(budget_source in('funding','ceiling','credits','aerial_failure'));
alter table public.serving_cost_reservations
  drop constraint serving_cost_reservations_check;
alter table public.serving_cost_reservations
  add constraint serving_cost_reservations_check check(
    (sponsored_unlimited and budget_source='funding' and funding_id is null and slice_index is null and credit_hold_id is null)
    or(not sponsored_unlimited and budget_source='ceiling' and funding_id is null and slice_index is null and credit_hold_id is null)
    or(not sponsored_unlimited and budget_source='funding' and funding_id is not null and slice_index is not null and credit_hold_id is null)
    or(not sponsored_unlimited and budget_source in('credits','aerial_failure')
      and funding_id is null and slice_index is null and credit_hold_id is not null));
alter table public.serving_cost_reservations
  drop constraint serving_cost_reservations_credit_environment_check;
alter table public.serving_cost_reservations
  add constraint serving_cost_reservations_credit_environment_check check(
    (budget_source in('credits','aerial_failure') and credit_environment in('Production','Sandbox'))
    or(budget_source not in('credits','aerial_failure') and credit_environment is null));

-- Reserve the full possible supplier loss before admission. Parallel accounts
-- cannot each observe an unused global budget and all start together. The
-- risk is released on a good clip; a failed attempt retains its actual or
-- conservative liability for 24 hours. This is separate from plan credits.
do $patch$ declare definition text;anchor text;replacement text;begin
  definition:=pg_get_functiondef('public.property_video_aerial_admit_credit(uuid,jsonb,jsonb,jsonb,text,text)'::regprocedure);
  anchor:='wallet:=public.credit_wallet_reserve(p_actor,billing,p_environment,';
  replacement:=E'perform pg_advisory_xact_lock(hashtextextended(''credit-aerial-failure-budget'',71005));\n  if (select coalesce(sum(case when state=''reserved'' then maximum_cents else spent_cents end),0)\n      from public.credit_aerial_failure_budget\n      where (state=''reserved'' or(state=''spent'' and finished_at>=now()-interval ''1 day'')))\n      +(p_quote->>''maximum_total_cents'')::numeric>5000\n    or (select coalesce(sum(case when state=''reserved'' then maximum_cents else spent_cents end),0)\n      from public.credit_aerial_failure_budget\n      where billing_org_id=billing and (state=''reserved'' or(state=''spent'' and finished_at>=now()-interval ''1 day'')))\n      +(p_quote->>''maximum_total_cents'')::numeric>500 then\n   raise exception ''RP402: The bounded aerial supplier-failure budget is full'';end if;\n  wallet:=public.credit_wallet_reserve(p_actor,billing,p_environment,';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial wallet admission before supplier-loss budget';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='insert into public.credit_aerial_openings(job_id,hold_id,environment,tariff_version)values(j.id,fund.id,p_environment,p_tariff_version);';
  replacement:=anchor||E'\n insert into public.credit_aerial_failure_budget(hold_id,job_id,billing_org_id,environment,maximum_cents)\n values(fund.id,j.id,billing,p_environment,(p_quote->>''maximum_total_cents'')::numeric);';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial job/failure-budget binding';end if;
  execute replace(definition,anchor,replacement);
end $patch$;

-- During a running paid-period opening, the frozen customer credits already
-- cover the accepted KIE receipt. On a failed refund, the cost falls back to
-- noncredit budget automatically because the hold becomes released.
do $patch$ declare definition text;anchor text;replacement text;begin
 definition:=pg_get_functiondef('public.credit_combined_budget_state(uuid)'::regprocedure);
 anchor:='h.org_id=b and h.environment=''Production'' and h.state=''settled''';
 replacement:='h.org_id=b and h.environment=''Production'' and h.state in(''reserved'',''settled'')';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
   raise exception 'Review changed aerial credit-video budget linkage';end if;
 execute replace(definition,anchor,replacement);
end $patch$;

-- This function is the only credit-to-failure reclassification. It requires
-- exact actor, workspace, saved quote, all five supplier stages and the
-- immutable video reservation. A terminal unknown KIE submission waits 48h;
-- then it refunds the customer while reserving the full possible supplier
-- bill. A late exact KIE receipt can still be journaled, never recharged.
create function public.credit_aerial_customer_finish(p_id uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare j public.property_video_aerial_openings; ca public.credit_aerial_openings;
  h public.credit_holds; v public.app_video_cost_reservations;
  risk public.credit_aerial_failure_budget; n integer; expense numeric;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 select * into j from public.property_video_aerial_openings where id=p_id;
 select * into ca from public.credit_aerial_openings where job_id=p_id;
 if ca.job_id is null then return false;end if;
 if j.id is null then raise exception 'RP409: Credit aerial job disappeared';end if;
 perform pg_advisory_xact_lock(hashtextextended('credit-wallet:'||j.billing_org_id||':'||ca.environment,71003));
 perform pg_advisory_xact_lock(hashtextextended('serving:'||j.billing_org_id,72452));
 perform pg_advisory_xact_lock(hashtextextended('serving:'||j.org_id,72452));
 select * into j from public.property_video_aerial_openings where id=p_id for update;
 select * into h from public.credit_holds where id=ca.hold_id for update;
 select * into v from public.app_video_cost_reservations where org_id=j.org_id
  and actor_id=j.actor_id and idempotency_key='aerial-opening:'||j.operation_id for update;
 select * into risk from public.credit_aerial_failure_budget where hold_id=ca.hold_id for update;
 if h.id is null or v.id is null or risk.hold_id is null
  or ca.environment is distinct from h.environment or h.org_id is distinct from j.billing_org_id
  or h.actor_id is distinct from j.actor_id or h.request_key is distinct from 'aerial-opening:'||j.operation_id
  or h.operation is distinct from 'aerial.opening' or h.tariff_version is distinct from ca.tariff_version
  or h.credits<>20 or v.credit_hold_id is distinct from h.id or v.credit_environment is distinct from ca.environment
  or v.billing_org_id is distinct from j.billing_org_id or risk.job_id is distinct from j.id
  or risk.billing_org_id is distinct from j.billing_org_id or risk.environment is distinct from ca.environment
  or risk.maximum_cents is distinct from (j.quote->>'maximum_total_cents')::numeric
  then raise exception 'RP409: Aerial customer and supplier funding changed';end if;
 if h.state='settled' and risk.state='released' then return true;end if;
 if h.state='released' and risk.state in('spent','released') then return true;end if;
 if h.state<>'reserved' or risk.state<>'reserved' then
  raise exception 'RP409: Aerial financial outcome is inconsistent';end if;
 if j.state in('ready_for_acceptance','accepted') then
  if j.cancel_requested_at is not null or j.provider_receipt is null
    or j.qualified_output->>'etag' is null
    or j.quality->>'action' is distinct from 'accept'
    or j.quality->>'verdict' is distinct from 'pass'
    or j.quality->'publishable' is distinct from 'true'::jsonb
    or j.quality->>'output_sha256' is distinct from j.qualified_output->>'sha256'
    or v.provider_request_id is distinct from j.provider_receipt->>'id'
    or v.cost_ledger_id is null or v.released_at is not null
    or not exists(select 1 from public.serving_cost_reservations s where s.credit_hold_id=h.id
      and s.stage='aerial' and s.state='succeeded' and s.budget_source='credits')
    then raise exception 'RP409: A usable opening and exact supplier receipt are required';end if;
  perform public.credit_wallet_finish(j.actor_id,j.billing_org_id,ca.environment,
    'aerial-opening:'||j.operation_id,'settled');
  update public.credit_aerial_failure_budget set state='released',finished_at=now()
    where hold_id=h.id;
  return true;
 end if;
 if j.state='ambiguous' and j.provider_receipt is null
   and j.generation_claimed_at<=now()-interval '48 hours' then
   update public.property_video_aerial_openings set state='failed',
     cancel_requested_at=coalesce(cancel_requested_at,now()),
     message='The supplier response could not be confirmed. Your credits are being returned; this opening is stopped.',
     updated_at=now() where id=p_id returning * into j;
 end if;
 if j.state not in('failed','cancelled','ineligible') then return false;end if;
 if j.provider_receipt is not null and (v.provider_request_id is distinct from j.provider_receipt->>'id'
   or v.cost_ledger_id is null or v.released_at is not null) then
   raise exception 'RP409: Accepted supplier cost must remain accounted';end if;
 if j.provider_receipt is null and v.released_at is null then
  if j.generation_claimed_at is null then
   raise exception 'RP409: Unclaimed aerial submission needs a definitive release';end if;
  if j.generation_claimed_at>now()-interval '48 hours' then return false;end if;
  -- No supplier id exists to poll. The full possible bill remains our risk,
  -- and the operation stays stopped even if its exact receipt arrives later.
  update public.property_video_aerial_openings set
    cancel_requested_at=coalesce(cancel_requested_at,now()),
    state='cancelled',message='The supplier response could not be confirmed. Your credits were returned; this opening remains stopped.',updated_at=now()
    where id=p_id;
 end if;
 select count(*),coalesce(sum(case when s.state='rejected' then 0
   when s.stage='aerial' then coalesce(vc.total_cents,s.hold_cents)
   else coalesce(c.total_cents,s.hold_cents) end),0)
  into n,expense
  from public.serving_cost_reservations s
  left join public.cost_ledger c on c.id=s.ledger_id
  left join public.cost_ledger vc on vc.id=v.cost_ledger_id and s.stage='aerial'
  where s.credit_hold_id=h.id and s.actor_id=j.actor_id and s.org_id=j.org_id
   and s.billing_org_id=j.billing_org_id and s.request_key='aerial-opening:'||j.operation_id
   and s.credit_environment=ca.environment and s.budget_source='credits';
 if n<>5 or expense>risk.maximum_cents then
   raise exception 'RP409: Aerial supplier-loss bound or five-stage receipt changed';end if;
 update public.serving_cost_reservations set budget_source='aerial_failure'
   where credit_hold_id=h.id and budget_source='credits' and state<>'rejected';
 update public.credit_aerial_failure_budget set
   state=case when expense>0 then 'spent' else 'released' end,
   spent_cents=expense,finished_at=now() where hold_id=h.id;
 perform public.credit_wallet_finish(j.actor_id,j.billing_org_id,ca.environment,
   'aerial-opening:'||j.operation_id,'released');
 return true;
end$$;
revoke all on function public.credit_aerial_customer_finish(uuid) from public,anon,authenticated;
grant execute on function public.credit_aerial_customer_finish(uuid) to service_role;

-- Receipt acceptance records a supplier bill, but no customer charge.
do $patch$ declare definition text;anchor text;replacement text;begin
 definition:=pg_get_functiondef('public.property_video_aerial_receipt(uuid,uuid,jsonb)'::regprocedure);
 anchor:='or h.credits<>20 or h.state<>''reserved'' then';
 replacement:=E'or h.credits<>20 or h.state not in(''reserved'',''released'')\n   or (h.state=''released'' and not exists(select 1 from public.credit_aerial_failure_budget f\n     where f.hold_id=h.id and f.job_id=j.id and f.state=''spent'' and v.released_at is null)) then';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
   raise exception 'Review changed accepted aerial customer hold check';end if;
 definition:=replace(definition,anchor,replacement);
 anchor:='perform public.credit_wallet_finish(j.actor_id,j.billing_org_id,ca.environment,''aerial-opening:''||j.operation_id,''settled'');';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
   raise exception 'Review changed premature aerial credit charge';end if;
 definition:=replace(definition,anchor,'-- Supplier receipt alone never charges a customer.');
 anchor:='if ca.job_id is not null and not exists(select 1 from public.credit_holds where id=ca.hold_id and state=''settled'') then raise exception ''RP503: Accepted aerial receipt lacks customer settlement'';end if;';
 replacement:='if ca.job_id is not null and not exists(select 1 from public.credit_holds where id=ca.hold_id and state in(''reserved'',''settled'',''released'')) then raise exception ''RP503: Accepted aerial receipt lost its customer hold'';end if;';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
   raise exception 'Review changed replayed aerial receipt credit check';end if;
 definition:=replace(definition,anchor,replacement);
 anchor:='perform public.app_video_cost_settle(j.actor_id,j.org_id,''aerial-opening:''||j.operation_id,p_receipt->>''id'');';
 replacement:=E'if ca.job_id is not null and exists(select 1 from public.credit_holds where id=ca.hold_id and state=''released'') then\n  update public.property_video_aerial_openings set cancel_requested_at=coalesce(cancel_requested_at,now()),state=''cancelled'',updated_at=now() where id=p_id;\n end if;\n perform public.app_video_cost_settle(j.actor_id,j.org_id,''aerial-opening:''||j.operation_id,p_receipt->>''id'');';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
   raise exception 'Review changed aerial supplier ledger settlement';end if;
 execute replace(definition,anchor,replacement);
end $patch$;

-- A delayed transport callback after the 48-hour customer refund must not
-- resurrect an already stopped operation. The supplier bill remains in the
-- failure journal; an exact later acceptance still records its cost.
do $patch$ declare definition text;anchor text;replacement text;begin
 definition:=pg_get_functiondef('public.property_video_aerial_ambiguous(uuid,uuid)'::regprocedure);
 anchor:='if j.provider_receipt is null then update public.property_video_aerial_openings set state=''ambiguous''';
 replacement:=E'if exists(select 1 from public.credit_aerial_openings ca\n   join public.credit_holds h on h.id=ca.hold_id\n   where ca.job_id=j.id and h.state=''released'') then return true;end if;\n if j.provider_receipt is null then update public.property_video_aerial_openings set state=''ambiguous''';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
   raise exception 'Review changed ambiguous aerial callback';end if;
 execute replace(definition,anchor,replacement);
 definition:=pg_get_functiondef('public.property_video_aerial_reject_before_dispatch(uuid,uuid,integer,text)'::regprocedure);
 anchor:='perform public.app_video_cost_release_rejected(j.actor_id,j.org_id,''aerial-opening:''||j.operation_id,p_status,p_error_class);';
 replacement:=E'if exists(select 1 from public.credit_aerial_openings ca\n   join public.credit_holds h on h.id=ca.hold_id\n   where ca.job_id=j.id and h.state=''released'') then return true;end if;\n perform public.app_video_cost_release_rejected(j.actor_id,j.org_id,''aerial-opening:''||j.operation_id,p_status,p_error_class);';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
   raise exception 'Review changed rejected aerial callback';end if;
 execute replace(definition,anchor,replacement);
end $patch$;

-- The existing release_future function handles untouched legacy allowance
-- refunds and definitive rejection. Replace only its credit branch.
do $patch$ declare definition text;anchor text;replacement text;begin
 definition:=pg_get_functiondef('public.property_video_aerial_release_future(uuid)'::regprocedure);
 anchor:=E'if j.provider_receipt is not null then\n   perform public.credit_wallet_finish(j.actor_id,j.billing_org_id,ca.environment,''aerial-opening:''||j.operation_id,''settled'');\n  elsif r.released_at is not null and r.provider_request_id is null then\n   select exists(select 1 from public.serving_cost_reservations sr where sr.credit_hold_id=ca.hold_id and sr.budget_source=''credits'' and sr.state<>''rejected'') into liability;\n   perform public.credit_wallet_finish(j.actor_id,j.billing_org_id,ca.environment,''aerial-opening:''||j.operation_id,case when liability then ''settled'' else ''released'' end);\n  end if;';
 replacement:='perform public.credit_aerial_customer_finish(p_id);';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
   raise exception 'Review changed aerial terminal customer settlement';end if;
 execute replace(definition,anchor,replacement);
end $patch$;

-- Acquire the wallet lock before the original vision result obtains serving
-- locks. Both a good quality result and a failed/ineligible result reconcile
-- atomically with the exact cost receipt. The raw quality mutator is private
-- to its owner-definer caller so it cannot bypass this boundary.
alter function public.property_video_aerial_vision_result(uuid,text,uuid,jsonb)
  rename to property_video_aerial_vision_result_before_credit;
revoke all on function public.property_video_aerial_vision_result_before_credit(uuid,text,uuid,jsonb)
 from public,anon,authenticated,service_role;
create function public.property_video_aerial_vision_result(p_id uuid,p_phase text,p_lease uuid,p_result jsonb)
returns boolean language plpgsql security definer set search_path='' as $$
declare j public.property_video_aerial_openings; ca public.credit_aerial_openings; ok boolean;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 select * into j from public.property_video_aerial_openings where id=p_id;
 select * into ca from public.credit_aerial_openings where job_id=p_id;
 if ca.job_id is not null then
  if j.id is null or ca.environment not in('Production','Sandbox') then
    raise exception 'RP409: Aerial credit funding is unavailable';end if;
  perform pg_advisory_xact_lock(hashtextextended('credit-wallet:'||j.billing_org_id||':'||ca.environment,71003));
 end if;
 ok:=public.property_video_aerial_vision_result_before_credit(p_id,p_phase,p_lease,p_result);
 if ca.job_id is not null then
  select * into j from public.property_video_aerial_openings where id=p_id;
  if j.state='ready_for_acceptance' then
    perform public.credit_aerial_customer_finish(p_id);
  elsif j.state in('failed','cancelled','ineligible') then
    perform public.property_video_aerial_release_future(p_id);
  end if;
 end if;
 return ok;
end$$;
revoke all on function public.property_video_aerial_vision_result(uuid,text,uuid,jsonb)
 from public,anon,authenticated;
grant execute on function public.property_video_aerial_vision_result(uuid,text,uuid,jsonb) to service_role;
revoke all on function public.property_video_aerial_quality(uuid,uuid,jsonb)
 from public,anon,authenticated,service_role;

-- A timed-out POST has no supplier id to poll. Keep an immutable full-face
-- supplier-loss reservation, return customer credits after 48h, and prohibit
-- new media even if an exact receipt arrives later. A healthy active attempt
-- never expires merely because a worker was slow.
create function public.credit_aerial_hold_reconcile(p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path='' as $$
declare candidate record; job public.property_video_aerial_openings;
  credit public.credit_aerial_openings;
  scanned integer:=0; refunded integer:=0; waiting integer:=0; held public.credit_holds;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 if p_limit is null or p_limit not between 1 and 500 then
  raise exception 'RP400: Bounded aerial reconciliation batch required';end if;
 if not pg_try_advisory_xact_lock(hashtextextended('credit-aerial-recovery',71006)) then
  return jsonb_build_object('busy',true,'scanned',0,'refunded',0,'waiting',0);end if;
 for candidate in
  select ca.job_id from public.credit_aerial_openings ca
   join public.credit_holds h on h.id=ca.hold_id and h.state='reserved'
   join public.property_video_aerial_openings j on j.id=ca.job_id
   where j.state in('failed','cancelled','ineligible','ready_for_acceptance','accepted')
      or(j.state in('ambiguous','dispatching')
         and j.generation_claimed_at<=now()-interval '48 hours')
      or(j.state not in('failed','cancelled','ineligible','ready_for_acceptance','accepted')
         and j.deadline<=now())
   order by j.created_at,j.id limit p_limit
 loop
  scanned:=scanned+1;
  select * into job from public.property_video_aerial_openings where id=candidate.job_id;
  if job.state in('ready_for_acceptance','accepted') then
   perform public.credit_aerial_customer_finish(job.id);
  else
   if job.state not in('failed','cancelled','ineligible') then
    select * into credit from public.credit_aerial_openings where job_id=job.id;
    perform pg_advisory_xact_lock(hashtextextended('credit-wallet:'||job.billing_org_id||':'||credit.environment,71003));
    perform pg_advisory_xact_lock(hashtextextended('serving:'||job.billing_org_id,72452));
    perform pg_advisory_xact_lock(hashtextextended('serving:'||job.org_id,72452));
    select * into job from public.property_video_aerial_openings where id=job.id for update;
    if job.state not in('failed','cancelled','ineligible','ready_for_acceptance','accepted')
      and (job.deadline<=now()
        or(job.state in('ambiguous','dispatching') and
           job.generation_claimed_at<=now()-interval '48 hours')) then
     update public.property_video_aerial_openings set state='failed',
       cancel_requested_at=coalesce(cancel_requested_at,now()),
       message='This opening timed out. Your original files are kept while the supplier outcome and credits are reconciled.',
       updated_at=now() where id=job.id;
    end if;
   end if;
   perform public.property_video_aerial_release_future(job.id);
  end if;
  select * into held from public.credit_holds where id=(select hold_id from public.credit_aerial_openings where job_id=job.id);
  if held.state='released' then refunded:=refunded+1;
  elsif held.state='reserved' then waiting:=waiting+1;end if;
 end loop;
 return jsonb_build_object('busy',false,'scanned',scanned,'refunded',refunded,'waiting',waiting);
end$$;
revoke all on function public.credit_aerial_hold_reconcile(integer)
 from public,anon,authenticated;
grant execute on function public.credit_aerial_hold_reconcile(integer) to service_role;

-- Activation remains forbidden until cron is installed and its first run is
-- observed. The migration only requests the same 15-minute recovery cadence
-- used by other credit holds when pg_cron is available.
do $schedule$ begin
 if exists(select 1 from pg_extension where extname='pg_cron') then
  perform cron.schedule('credit-aerial-hold-reconcile','*/15 * * * *',
   'set role service_role;select public.credit_aerial_hold_reconcile(100)');
 else raise notice 'credit_aerial_hold_reconcile requires an external 15-minute scheduler';end if;
exception when others then
 raise notice 'credit_aerial_hold_reconcile scheduling failed (% — %); activation stays blocked',SQLSTATE,SQLERRM;
end $schedule$;
commit;
