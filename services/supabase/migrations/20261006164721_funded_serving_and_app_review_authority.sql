begin;
-- Inclusive money authority. A quota or a Sandbox purchase is never funding.
-- No retail/trial/reviewer allocations are seeded by a source migration.
create table if not exists public.serving_funding (
 id uuid primary key default gen_random_uuid(), org_id uuid not null,
 source text not null check(source in ('retail','trial','app_review')),
 collection_ref text not null unique check(length(collection_ref) between 8 and 200),
 actor_id uuid, net_receipts_cents bigint not null check(net_receipts_cents between 0 and 1000000000),
 sponsored_cents bigint not null default 0 check(sponsored_cents between 0 and 100000000),
 starts_at timestamptz not null, ends_at timestamptz not null,retention_ends_at timestamptz not null,
 service_months integer not null check(service_months in (1,12)),
 recurring_reserve_cents bigint not null check(recurring_reserve_cents>=0),
 reserve_components jsonb not null, evidence_sha256 text not null check(evidence_sha256 ~ '^[a-f0-9]{64}$'),
 apple_original_transaction_id text, revoked_at timestamptz, revocation_kind text check(revocation_kind in('operator','apple_refund','apple_replaced')),
 revocation_evidence_sha256 text check(revocation_evidence_sha256 is null or revocation_evidence_sha256 ~ '^[a-f0-9]{64}$'),
 reactivation_evidence_sha256 text check(reactivation_evidence_sha256 is null or reactivation_evidence_sha256 ~ '^[a-f0-9]{64}$'),created_at timestamptz not null default now(),
 check(ends_at>starts_at and retention_ends_at>=ends_at),
 check((source='retail' and sponsored_cents=0 and actor_id is null)
    or(source<>'retail' and net_receipts_cents=0 and actor_id is not null and service_months=1)),
 check(source<>'app_review' or(ends_at<=starts_at+interval '7 days' and sponsored_cents<=500)),
 check(recurring_reserve_cents<=case when source='retail' then net_receipts_cents/4 else sponsored_cents end)
);
create table if not exists public.serving_funding_slices (
 funding_id uuid not null references public.serving_funding(id), slice_index integer not null,
 org_id uuid not null, starts_at timestamptz not null, ends_at timestamptz not null,
 total_budget_cents bigint not null check(total_budget_cents>=0),
 recurring_reserve_cents bigint not null check(recurring_reserve_cents between 0 and total_budget_cents),
 primary key(funding_id,slice_index),check(ends_at>starts_at)
);
create table if not exists public.serving_cost_reservations (
 id uuid primary key default gen_random_uuid(),org_id uuid not null,actor_id uuid not null,
 request_key text not null check(request_key ~ '^[A-Za-z0-9:_-]{8,128}$'),
 stage text not null check(stage ~ '^[a-z0-9:._-]{1,80}$'),
 funding_id uuid, slice_index integer,
 provider text not null check(length(provider) between 1 and 40),model text not null check(length(model) between 1 and 240),
 input_sha256 text not null check(input_sha256 ~ '^[a-f0-9]{64}$'),
 tariff_version text not null check(length(tariff_version) between 1 and 120),
 hold_cents numeric(20,4) not null check(hold_cents>0 and hold_cents<=100000000),
 state text not null default 'reserved' check(state in ('reserved','succeeded','uncertain','rejected')),
 sponsored_unlimited boolean not null default false,
 created_at timestamptz not null default now(),settled_at timestamptz,
 unique(org_id,actor_id,request_key,stage),
 foreign key(funding_id,slice_index) references public.serving_funding_slices(funding_id,slice_index),
 check((sponsored_unlimited and funding_id is null and slice_index is null)
   or(not sponsored_unlimited and funding_id is not null and slice_index is not null))
);
create index if not exists serving_cost_slice on public.serving_cost_reservations(funding_id,slice_index) where state<>'rejected';
create index if not exists serving_funding_current on public.serving_funding(org_id,starts_at,ends_at) where revoked_at is null;
alter table public.serving_funding enable row level security;
alter table public.serving_funding_slices enable row level security;
alter table public.serving_cost_reservations enable row level security;
revoke all on public.serving_funding,public.serving_funding_slices,public.serving_cost_reservations from public,anon,authenticated,service_role;
grant select on public.serving_funding,public.serving_funding_slices,public.serving_cost_reservations to service_role;

-- A recorded liability survives deletion. Neither an expired window nor a
-- goodwill quota refund deletes, releases or renews this journal.
create or replace function public.provision_serving_funding(
 p_org uuid,p_source text,p_collection_ref text,p_actor uuid,p_net_receipts_cents bigint,p_sponsored_cents bigint,
 p_starts_at timestamptz,p_ends_at timestamptz,p_service_months integer,p_reserve_components jsonb,p_evidence_sha256 text
)returns jsonb language plpgsql security definer set search_path='' set timezone='UTC' as $$
declare prior public.serving_funding;funding uuid;budget bigint;reserve bigint;component text;amount numeric;
 s timestamptz;e timestamptz;i integer;part bigint;rpart bigint;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_org is null or p_source is null or p_source not in('retail','trial','app_review')or p_collection_ref is null
  or length(p_collection_ref)not between 8 and 200 or p_evidence_sha256 is null or p_evidence_sha256 !~ '^[a-f0-9]{64}$'
  or p_net_receipts_cents is null or p_net_receipts_cents not between 0 and 1000000000
  or p_sponsored_cents is null or p_sponsored_cents not between 0 and 100000000
  or p_service_months is null or p_service_months not in(1,12)
  or p_starts_at is null or p_ends_at is null or not isfinite(p_starts_at)or not isfinite(p_ends_at)
  or p_ends_at<=p_starts_at or p_starts_at>now()+interval '5 minutes'
  or jsonb_typeof(p_reserve_components)is distinct from 'object' then raise exception 'RP400: Verified collected funding and bounded serving reserve are required';end if;
 reserve:=0;
 foreach component in array array['storage','delivery','compute','email','support','retention','uncertainty']loop
  if not(p_reserve_components ? component)or jsonb_typeof(p_reserve_components->component)<>'number'then raise exception 'RP400: Every serving liability requires a reserve';end if;
  amount:=(p_reserve_components->>component)::numeric;
  if amount<0 or amount<>trunc(amount)or amount>1000000000 then raise exception 'RP400: Serving reserves must be nonnegative integer cents';end if;
  reserve:=reserve+amount::bigint;
 end loop;
 if(select count(*)from jsonb_object_keys(p_reserve_components))<>7 then raise exception 'RP400: Unknown serving reserve category';end if;
 budget:=case when p_source='retail'then p_net_receipts_cents/4 else p_sponsored_cents end;
 if reserve>budget or(p_source='retail'and(p_actor is not null or p_sponsored_cents<>0 or p_net_receipts_cents<=0))
  or(p_source<>'retail'and(p_actor is null or p_net_receipts_cents<>0 or p_service_months<>1 or p_sponsored_cents<=0))
  or(p_source='app_review'and(p_ends_at>p_starts_at+interval '7 days'or p_sponsored_cents>500))then
  raise exception 'RP400: Funding does not cover the inclusive serving envelope';end if;
 if p_source='retail'and(p_ends_at>p_starts_at+make_interval(months=>p_service_months)+interval '2 days'
  or p_ends_at<p_starts_at+make_interval(months=>p_service_months)-interval '2 days')then raise exception 'RP400: Funding must match the purchased service period';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP403: A current workspace is required';end if;
 select * into prior from public.serving_funding where collection_ref=p_collection_ref;
 if prior.id is not null then
  if row(prior.org_id,prior.source,prior.actor_id,prior.net_receipts_cents,prior.sponsored_cents,prior.starts_at,prior.ends_at,prior.service_months,prior.reserve_components,prior.evidence_sha256)
   is distinct from row(p_org,p_source,p_actor,p_net_receipts_cents,p_sponsored_cents,p_starts_at,p_ends_at,p_service_months,p_reserve_components,p_evidence_sha256)then raise exception 'RP409: Funding receipt is immutable';end if;
  return jsonb_build_object('ok',true,'funding_id',prior.id,'replay',true);end if;
 if exists(select 1 from public.serving_funding where org_id=p_org and revoked_at is null and starts_at<p_ends_at and ends_at>p_starts_at)then raise exception 'RP409: Funding periods cannot overlap or stack';end if;
 if p_source<>'retail'then
  if not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)
   or not exists(select 1 from public.memberships where org_id=p_org and user_id=p_actor and role='owner')
   or not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception 'RP403: Sponsored access requires a current named owner';end if;
 end if;
 if p_source='app_review'then
  if public.org_has_internal_testing_grant(p_org)or public.org_has_private_internal_testing(p_org)
   or(select count(*)from public.memberships where org_id=p_org)<>1
   or exists(select 1 from public.apple_subscriptions where org_id=p_org and environment='Production'and status in('active','grace'))
   or exists(select 1 from public.serving_funding where actor_id=p_actor and source='app_review')then raise exception 'RP403: App Review needs a dedicated finite workspace and one lifetime grant';end if;
 end if;
 insert into public.serving_funding(org_id,source,collection_ref,actor_id,net_receipts_cents,sponsored_cents,starts_at,ends_at,retention_ends_at,service_months,recurring_reserve_cents,reserve_components,evidence_sha256)
 values(p_org,p_source,p_collection_ref,p_actor,p_net_receipts_cents,p_sponsored_cents,p_starts_at,p_ends_at,case when p_source='app_review'then p_ends_at else p_ends_at+interval '90 days'end,p_service_months,reserve,p_reserve_components,p_evidence_sha256)returning id into funding;
 for i in 0..p_service_months-1 loop
  s:=p_starts_at+make_interval(months=>i);e:=case when i=p_service_months-1 then p_ends_at else least(p_ends_at,p_starts_at+make_interval(months=>i+1))end;
  part:=budget/p_service_months+case when i<budget%p_service_months then 1 else 0 end;
  rpart:=reserve/p_service_months+case when i<reserve%p_service_months then 1 else 0 end;
  insert into public.serving_funding_slices values(funding,i,p_org,s,e,part,rpart);
 end loop;
 return jsonb_build_object('ok',true,'funding_id',funding,'total_budget_cents',budget,'recurring_reserve_cents',reserve,'provider_budget_cents',budget-reserve,'service_months',p_service_months);
end$$;

create or replace function public.org_has_app_review_funding(p_org uuid)returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.serving_funding f join public.orgs o on o.id=f.org_id and o.deleted_at is null
  join auth.users u on u.id=f.actor_id and u.is_anonymous is false
  join public.memberships m on m.org_id=f.org_id and m.user_id=f.actor_id and m.role='owner'
  where f.org_id=p_org and f.source='app_review'and f.revoked_at is null and f.starts_at<=now()and f.ends_at>now()
   and not exists(select 1 from public.deletion_requests d where d.user_id=f.actor_id and d.status in('pending','processing'))
   and(select count(*)from public.memberships where org_id=f.org_id)=1
   and(current_setting('role',true)='service_role'or auth.uid()=f.actor_id));
$$;
revoke all on function public.org_has_app_review_funding(uuid)from public,anon,authenticated;
grant execute on function public.org_has_app_review_funding(uuid)to authenticated,service_role;

create or replace function public.serving_cost_reserve(p_actor uuid,p_org uuid,p_key text,p_stage text,p_provider text,p_model text,p_input_sha256 text,p_hold_cents numeric,p_tariff_version text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare prior public.serving_cost_reservations;f public.serving_funding;s public.serving_funding_slices;
 unlimited boolean;spent numeric;reservation uuid;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_key is null or p_key !~ '^[A-Za-z0-9:_-]{8,128}$'or p_stage is null or p_stage !~ '^[a-z0-9:._-]{1,80}$'
  or p_input_sha256 is null or p_input_sha256 !~ '^[a-f0-9]{64}$'or p_hold_cents is null
  or p_hold_cents::text in('NaN','Infinity','-Infinity')or p_hold_cents<=0 or p_hold_cents>100000000
  or p_hold_cents<>round(p_hold_cents,4)or p_provider is null or length(p_provider)not between 1 and 40
  or p_model is null or length(p_model)not between 1 and 240 or p_tariff_version is null or length(p_tariff_version)not between 1 and 120 then raise exception 'RP400: A bounded verified attempt quote is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or not exists(select 1 from public.memberships where org_id=p_org and user_id=p_actor and role in('owner','admin','agent'))
  or not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception 'RP403: Current editor access is required';end if;
 select * into prior from public.serving_cost_reservations where org_id=p_org and actor_id=p_actor and request_key=p_key and stage=p_stage;
 if prior.id is not null then raise exception 'RP409: This provider attempt is already journaled; restore its existing result';end if;
 unlimited:=public.org_has_internal_testing_grant(p_org)or public.org_has_private_internal_testing(p_org);
 if not unlimited then
  if p_tariff_version='unpriced-private-sponsorship' then raise exception 'RP403: An unpriced route is restricted to unlimited private sponsorship';end if;
  select funding.* into f from public.serving_funding funding where org_id=p_org and revoked_at is null and starts_at<=now()and ends_at>now();
  if f.id is null then raise exception 'RP402: This workspace has no funded serving allowance';end if;
  if f.source<>'retail'and f.actor_id is distinct from p_actor then raise exception 'RP403: Sponsored funds belong to the named test account';end if;
  if f.source='app_review'and not public.org_has_app_review_funding(p_org)then raise exception 'RP403: App Review authority is unavailable';end if;
  select * into s from public.serving_funding_slices where funding_id=f.id and starts_at<=now()and ends_at>now();
  if s.funding_id is null then raise exception 'RP402: This paid service interval is not funded';end if;
  select coalesce(sum(hold_cents),0)into spent from public.serving_cost_reservations where funding_id=s.funding_id and slice_index=s.slice_index and state<>'rejected';
  if spent+p_hold_cents>s.total_budget_cents-s.recurring_reserve_cents then raise exception 'RP402: This attempt exceeds the shared funded serving allowance';end if;
 end if;
 insert into public.serving_cost_reservations(org_id,actor_id,request_key,stage,funding_id,slice_index,provider,model,input_sha256,tariff_version,hold_cents,sponsored_unlimited)
 values(p_org,p_actor,p_key,p_stage,s.funding_id,s.slice_index,p_provider,p_model,p_input_sha256,p_tariff_version,p_hold_cents,unlimited)returning id into reservation;
 return jsonb_build_object('reserved',true,'id',reservation,'hold_cents',p_hold_cents,'sponsored_unlimited',unlimited);
end$$;

create or replace function public.serving_cost_finish(p_actor uuid,p_org uuid,p_key text,p_stage text,p_state text,p_rejection_status integer default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.serving_cost_reservations;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_state is null or p_state not in('succeeded','uncertain','rejected')or(p_state='rejected'and(p_rejection_status is null or p_rejection_status not in(0,400,401,402,403,404,405,413,415,422,429)))then raise exception 'RP400: A definitive dispatch outcome is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
 select * into r from public.serving_cost_reservations where org_id=p_org and actor_id=p_actor and request_key=p_key and stage=p_stage for update;
 if r.id is null then raise exception 'RP404: Provider attempt not found';end if;
 if r.state<>'reserved'then
  if r.state<>p_state then raise exception 'RP409: Provider liability cannot be rewritten';end if;
  return jsonb_build_object('finished',true,'state',r.state,'replay',true);end if;
 update public.serving_cost_reservations set state=p_state,settled_at=now()where id=r.id;
 return jsonb_build_object('finished',true,'state',p_state,'hold_cents',case when p_state='rejected'then 0 else r.hold_cents end);
end$$;

create or replace function public.revoke_serving_funding(p_org uuid,p_collection_ref text,p_evidence_sha256 text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_evidence_sha256 is null or p_evidence_sha256 !~ '^[a-f0-9]{64}$'then raise exception 'RP400: Refund/revocation evidence is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
 update public.serving_funding set revoked_at=coalesce(revoked_at,now()),revocation_kind=case when revoked_at is null then 'operator'else coalesce(revocation_kind,'operator')end,revocation_evidence_sha256=coalesce(revocation_evidence_sha256,p_evidence_sha256)where org_id=p_org and collection_ref=p_collection_ref;
 if not found then raise exception 'RP404: Funding receipt not found';end if;
 -- Incurred/ambiguous costs and the retention reserve remain accounting debt.
 return jsonb_build_object('ok',true,'revoked',true);
end$$;

-- Reviewer access comes from the finite service-owned grant. A Sandbox product
-- does not change any retail plan, subscription, contract or owner QA grant.
do $patch$declare definition text;body text;anchor text;replacement text;
begin
 select pg_get_functiondef(oid),prosrc into definition,body from pg_proc where oid='public.record_apple_sandbox_receipt(uuid,uuid,text,text,text,text,timestamptz)'::regprocedure;
 anchor:='if not(public.org_has_internal_testing_grant(org)or public.org_has_private_internal_testing(org))then';
 replacement:='if not(public.org_has_internal_testing_grant(org)or public.org_has_private_internal_testing(org)or public.org_has_app_review_funding(org))then';
 if position(replacement in body)=0 then
  if(length(body)-length(replace(body,anchor,'')))/length(anchor)<>1 then raise exception 'Sandbox authority changed; review funded grant insertion';end if;
  execute replace(definition,anchor,replacement);end if;
 select pg_get_functiondef(oid),prosrc into definition,body from pg_proc where oid='public.effective_plan(uuid)'::regprocedure;
 anchor:=E'  select case\n';replacement:=E'  select case\n           when public.org_has_app_review_funding(p_org) then ''pro''\n';
 if position('when public.org_has_app_review_funding(p_org)' in body)=0 then
  if(length(body)-length(replace(body,anchor,'')))/length(anchor)<>1 then raise exception 'Effective plan changed; review finite grant insertion';end if;
  execute replace(definition,anchor,replacement);end if;
 select pg_get_functiondef(oid),prosrc into definition,body from pg_proc where oid='public.org_entitlement(uuid)'::regprocedure;
 anchor:=E'  return v_base;\nend;';
 replacement:=E'  if public.org_has_app_review_funding(p_org) then\n    v_base := public.plan_entitlement(''pro'');\n    v_base.seats := 1;\n    v_base.topaz_per_month := 1;\n    v_base.cogs_ceiling_cents := 500;\n    return v_base;\n  end if;\n  return v_base;\nend;';
 if position(replacement in body)=0 then
  if(length(body)-length(replace(body,anchor,'')))/length(anchor)<>1 then raise exception 'Entitlement body changed; review finite App Review insertion';end if;
  execute replace(definition,anchor,replacement);end if;
end$patch$;
revoke all on function public.provision_serving_funding(uuid,text,text,uuid,bigint,bigint,timestamptz,timestamptz,integer,jsonb,text),
 public.serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text),
 public.serving_cost_finish(uuid,uuid,text,text,text,integer),public.revoke_serving_funding(uuid,text,text)from public,anon,authenticated;
grant execute on function public.provision_serving_funding(uuid,text,text,uuid,bigint,bigint,timestamptz,timestamptz,integer,jsonb,text),
 public.serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text),
 public.serving_cost_finish(uuid,uuid,text,text,text,integer),public.revoke_serving_funding(uuid,text,text)to service_role;


-- One permanent operation identity before a client helper/chain starts. Stage
-- tombstones alone must not let a repeated request advance to a new provider.
create table if not exists public.serving_operations (
 org_id uuid not null,actor_id uuid not null,request_key text not null check(request_key ~ '^[A-Za-z0-9:_-]{8,128}$'),
 operation text not null check(length(operation)between 1 and 200),input_sha256 text not null check(input_sha256 ~ '^[a-f0-9]{64}$'),
 state text not null default 'started'check(state in('started','not_dispatched','completed')),
 created_at timestamptz not null default now(),primary key(org_id,actor_id,request_key)
);
alter table public.serving_operations enable row level security;
revoke all on public.serving_operations from public,anon,authenticated,service_role;
grant select on public.serving_operations to service_role;
create table if not exists public.serving_operation_results (
 org_id uuid not null references public.orgs(id)on delete cascade,
 actor_id uuid not null references auth.users(id)on delete cascade,request_key text not null,
 result jsonb not null check(jsonb_typeof(result)='object'and octet_length(result::text)<=262144),
 created_at timestamptz not null default now(),primary key(org_id,actor_id,request_key),
 foreign key(org_id,actor_id,request_key)references public.serving_operations(org_id,actor_id,request_key)
);
alter table public.serving_operation_results enable row level security;
revoke all on public.serving_operation_results from public,anon,authenticated,service_role;
grant select on public.serving_operation_results to service_role;
create or replace function public.serving_operation_begin(p_actor uuid,p_org uuid,p_key text,p_operation text,p_input_sha256 text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare prior public.serving_operations;saved jsonb;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_key is null or p_key !~ '^[A-Za-z0-9:_-]{8,128}$'or p_operation is null or length(p_operation)not between 1 and 200
  or p_input_sha256 is null or p_input_sha256 !~ '^[a-f0-9]{64}$'then raise exception 'RP400: A permanent operation identifier is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or not exists(select 1 from public.memberships where user_id=p_actor and org_id=p_org and role in('owner','admin','agent'))
  or not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception 'RP403: Current editor access is required';end if;
 select * into prior from public.serving_operations where org_id=p_org and actor_id=p_actor and request_key=p_key for update;
 if prior.org_id is not null then
  if prior.operation<>p_operation or prior.input_sha256<>p_input_sha256 then raise exception 'RP409: A request identifier cannot change its operation or inputs';end if;
  if prior.state='completed'then
   select result into saved from public.serving_operation_results where org_id=p_org and actor_id=p_actor and request_key=p_key;
   if saved is not null then return jsonb_build_object('begun',false,'replay',true,'result',saved);end if;
  end if;
  if prior.state='not_dispatched'and not exists(select 1 from public.serving_cost_reservations where org_id=p_org and actor_id=p_actor and request_key=p_key)then
   update public.serving_operations set state='started'where org_id=p_org and actor_id=p_actor and request_key=p_key;
   return jsonb_build_object('begun',true,'retry_after_no_dispatch',true);
  end if;
  raise exception 'RP409: This operation already started. Check its saved result or status before starting another';end if;
 insert into public.serving_operations(org_id,actor_id,request_key,operation,input_sha256)values(p_org,p_actor,p_key,p_operation,p_input_sha256);
 return jsonb_build_object('begun',true);
end$$;
revoke all on function public.serving_operation_begin(uuid,uuid,text,text,text)from public,anon,authenticated;
grant execute on function public.serving_operation_begin(uuid,uuid,text,text,text)to service_role;
create or replace function public.serving_operation_no_dispatch(p_actor uuid,p_org uuid,p_key text)
returns jsonb language plpgsql security definer set search_path='' as $$begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
 if exists(select 1 from public.serving_cost_reservations where org_id=p_org and actor_id=p_actor and request_key=p_key)then return jsonb_build_object('retryable',false);end if;
 update public.serving_operations set state='not_dispatched'where org_id=p_org and actor_id=p_actor and request_key=p_key and state='started';
 return jsonb_build_object('retryable',found);
end$$;
create or replace function public.serving_operation_complete(p_actor uuid,p_org uuid,p_key text,p_result jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare prior public.serving_operations;saved jsonb;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if jsonb_typeof(p_result)is distinct from 'object'or octet_length(p_result::text)>262144 then raise exception 'RP400: A bounded generated result is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or not exists(select 1 from public.memberships where org_id=p_org and user_id=p_actor and role in('owner','admin','agent'))
  or not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception 'RP403: Current editor access is required';end if;
 select * into prior from public.serving_operations where org_id=p_org and actor_id=p_actor and request_key=p_key for update;
 if prior.org_id is null or prior.state='not_dispatched'then raise exception 'RP409: Generated result has no started operation';end if;
 if not exists(select 1 from public.serving_cost_reservations where org_id=p_org and actor_id=p_actor and request_key=p_key and state<>'rejected')then raise exception 'RP409: Generated result has no admitted provider attempt';end if;
 select result into saved from public.serving_operation_results where org_id=p_org and actor_id=p_actor and request_key=p_key;
 if saved is not null then
  if saved<>p_result then raise exception 'RP409: Generated result is immutable';end if;
  return jsonb_build_object('saved',true,'replay',true);
 end if;
 insert into public.serving_operation_results(org_id,actor_id,request_key,result)values(p_org,p_actor,p_key,p_result);
 update public.serving_operations set state='completed'where org_id=p_org and actor_id=p_actor and request_key=p_key;
 return jsonb_build_object('saved',true);
end$$;
revoke all on function public.serving_operation_no_dispatch(uuid,uuid,text),public.serving_operation_complete(uuid,uuid,text,jsonb)from public,anon,authenticated;
grant execute on function public.serving_operation_no_dispatch(uuid,uuid,text),public.serving_operation_complete(uuid,uuid,text,jsonb)to service_role;

-- Price points are evidence for a conservative proceeds schedule, never cash
-- settlement. Operations must attest tax/FX/commission floors and serving
-- bounds before publishing a schedule. No catalog guesses are seeded here.
create or replace function public.serving_reserve_total(p_components jsonb)returns bigint
language plpgsql immutable strict set search_path='' as $$
declare component text;amount numeric;total bigint:=0;
begin
 if jsonb_typeof(p_components)<>'object'or(select count(*)from jsonb_object_keys(p_components))<>7 then return null;end if;
 foreach component in array array['storage','delivery','compute','email','support','retention','uncertainty']loop
  if not(p_components ? component)or jsonb_typeof(p_components->component)<>'number'then return null;end if;
  amount:=(p_components->>component)::numeric;
  if amount<0 or amount<>trunc(amount)or amount>1000000000 then return null;end if;
  total:=total+amount::bigint;
 end loop;
 return total;
end$$;
revoke all on function public.serving_reserve_total(jsonb)from public,anon,authenticated;
grant execute on function public.serving_reserve_total(jsonb)to service_role;

-- Sponsors commit cash separately from retail proceeds. Exhaustion includes all
-- past commitments, even revoked trials: an already-spent launch pool cannot be
-- replenished by restoring or refunding an Apple chain.
create table if not exists public.serving_sponsor_pools (
 id uuid primary key default gen_random_uuid(),collection_ref text not null unique check(length(collection_ref)between 8 and 200),
 source text not null check(source='trial'),funded_cents bigint not null check(funded_cents between 1 and 100000000),
 starts_at timestamptz not null,ends_at timestamptz not null,evidence_sha256 text not null check(evidence_sha256 ~ '^[a-f0-9]{64}$'),
 check(ends_at>starts_at and ends_at<=starts_at+interval '31 days')
);
alter table public.serving_sponsor_pools enable row level security;
revoke all on public.serving_sponsor_pools from public,anon,authenticated,service_role;
grant select,insert on public.serving_sponsor_pools to service_role;
alter table public.serving_funding add column if not exists sponsor_pool_id uuid references public.serving_sponsor_pools(id);
create index if not exists serving_funding_sponsor_pool on public.serving_funding(sponsor_pool_id)where sponsor_pool_id is not null;
create index if not exists serving_funding_apple_chain on public.serving_funding(org_id,apple_original_transaction_id)where apple_original_transaction_id is not null;

create table if not exists public.apple_serving_schedules (
 id uuid primary key default gen_random_uuid(), product_id text not null,
 storefront text not null check(storefront='USA'),currency text not null check(currency='USD'),
 price_milliunits bigint not null check(price_milliunits>0),net_proceeds_floor_cents bigint not null check(net_proceeds_floor_cents>0 and net_proceeds_floor_cents<=price_milliunits/10),
 service_months integer not null check(service_months in(1,12)),starts_at timestamptz not null,ends_at timestamptz not null,
 reserve_components jsonb not null,trial_sponsored_cents bigint not null default 0 check(trial_sponsored_cents between 0 and 500),
 trial_reserve_components jsonb not null,trial_days integer not null default 0 check(trial_days between 0 and 14),
 trial_pool_id uuid references public.serving_sponsor_pools(id),
 evidence_sha256 text not null check(evidence_sha256 ~ '^[a-f0-9]{64}$'),created_at timestamptz not null default now(),
 check(ends_at>starts_at and ends_at<=starts_at+interval '31 days'),
 check(public.serving_reserve_total(reserve_components)is not null and public.serving_reserve_total(reserve_components)<=net_proceeds_floor_cents/4),
 check(public.serving_reserve_total(trial_reserve_components)is not null and public.serving_reserve_total(trial_reserve_components)<=trial_sponsored_cents),
 check((trial_sponsored_cents=0 and trial_days=0 and trial_pool_id is null)or(trial_sponsored_cents>0 and trial_days>0 and trial_pool_id is not null)),
 unique(product_id,price_milliunits,starts_at)
);
alter table public.apple_serving_schedules enable row level security;
revoke all on public.apple_serving_schedules from public,anon,authenticated,service_role;
grant select,insert on public.apple_serving_schedules to service_role;
create or replace function public.fund_verified_apple_transaction(p_org uuid,p_original text,p_transaction text,p_product text,p_price_milliunits bigint,p_currency text,p_storefront text,p_offer_type integer,p_offer_discount_type text,p_purchased_at timestamptz,p_expires_at timestamptz,p_signed_at timestamptz,p_evidence_sha256 text)
returns jsonb language plpgsql security definer set search_path='' set timezone='UTC' as $$
declare subscription public.apple_subscriptions;schedule public.apple_serving_schedules;result jsonb;reference text;actor uuid;existing public.serving_funding;
 pool public.serving_sponsor_pools;committed bigint;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_org is null or p_original is null or p_transaction is null or p_product is null
  or p_signed_at is null or p_purchased_at is null or p_expires_at is null
  or p_evidence_sha256 is null or p_evidence_sha256 !~ '^[a-f0-9]{64}$'then raise exception 'RP400: Verified transaction funding facts are required';end if;
 -- Entitlement chronology already accepted this exact verified receipt. A stale
 -- notification cannot replenish, undo a refund, move a grant or fund grace.
 perform pg_advisory_xact_lock(hashtextextended(p_original,72451));
 select * into subscription from public.apple_subscriptions where original_transaction_id=p_original for update;
 if subscription.org_id is distinct from p_org or subscription.environment is distinct from 'Production'
  or subscription.last_transaction_id is distinct from p_transaction or subscription.product_id is distinct from p_product
  or subscription.transaction_purchased_at is distinct from p_purchased_at or subscription.transaction_signed_at>p_signed_at then
  return jsonb_build_object('funded',false,'reason','stale_or_unbound');end if;
 reference:=case when p_price_milliunits=0 then 'apple-trial:'||p_original else 'apple:'||p_transaction end;
 if subscription.status in('refunded','revoked')then
  perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
  update public.serving_funding set revoked_at=coalesce(revoked_at,now()),revocation_kind=case when revoked_at is null then 'apple_refund'else coalesce(revocation_kind,'apple_refund')end,revocation_evidence_sha256=coalesce(revocation_evidence_sha256,p_evidence_sha256)
   where org_id=p_org and(apple_original_transaction_id=p_original or collection_ref='apple:'||p_transaction or collection_ref='apple-trial:'||p_original);
  return jsonb_build_object('funded',false,'reason','revoked');end if;
 if subscription.status<>'active'or subscription.expires_at<>p_expires_at or p_expires_at<=now()then return jsonb_build_object('funded',false,'reason','unpaid_or_expired');end if;
 select * into existing from public.serving_funding where org_id=p_org and collection_ref=reference;
 if existing.id is not null then
  if existing.source='retail'and existing.revoked_at is not null and existing.revocation_kind='apple_refund'
   and subscription.last_notification_type='REFUND_REVERSED'then
   perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
   if not exists(select 1 from public.serving_funding where org_id=p_org and id<>existing.id and revoked_at is null and starts_at<existing.ends_at and ends_at>existing.starts_at)then
    update public.serving_funding set revoked_at=null,reactivation_evidence_sha256=p_evidence_sha256 where id=existing.id;
    existing.revoked_at:=null;
   end if;
  end if;
  return jsonb_build_object('funded',existing.revoked_at is null,'funding_id',existing.id,'replay',true);end if;
 if p_price_milliunits is null or p_price_milliunits<0 or p_currency is distinct from 'USD'or p_storefront is distinct from 'USA'then return jsonb_build_object('funded',false,'reason','unsupported_payment_facts');end if;
 select * into schedule from public.apple_serving_schedules where product_id=p_product and storefront=p_storefront and currency=p_currency
  and(p_price_milliunits=0 or price_milliunits=p_price_milliunits)and starts_at<=p_purchased_at and ends_at>p_purchased_at and ends_at>now()order by starts_at desc limit 1;
 if schedule.id is null then return jsonb_build_object('funded',false,'reason','unattested_proceeds_and_serving');end if;
 if p_price_milliunits=0 then
  if p_offer_type is distinct from 1 or p_offer_discount_type is distinct from 'FREE_TRIAL'or schedule.trial_sponsored_cents<=0 or schedule.trial_days<=0
   or p_expires_at>p_purchased_at+make_interval(days=>schedule.trial_days)then return jsonb_build_object('funded',false,'reason','unsponsored_trial');end if;
  select user_id into actor from public.memberships m join auth.users u on u.id=m.user_id and u.is_anonymous is false where m.org_id=p_org and m.role='owner'order by m.user_id limit 1;
  if actor is null then return jsonb_build_object('funded',false,'reason','named_trial_owner_required');end if;
  select * into pool from public.serving_sponsor_pools where id=schedule.trial_pool_id for update;
  if pool.id is null or pool.starts_at>now()or pool.ends_at<=now()then return jsonb_build_object('funded',false,'reason','trial_pool_unavailable');end if;
  select coalesce(sum(sponsored_cents),0)into committed from public.serving_funding where sponsor_pool_id=pool.id;
  if committed+schedule.trial_sponsored_cents>pool.funded_cents then return jsonb_build_object('funded',false,'reason','trial_pool_exhausted');end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
 update public.serving_funding set revoked_at=now(),revocation_kind='apple_replaced',revocation_evidence_sha256=p_evidence_sha256 where org_id=p_org and apple_original_transaction_id=p_original and revoked_at is null and ends_at>p_purchased_at and collection_ref<>reference;
 if p_price_milliunits=0 then
  result:=public.provision_serving_funding(p_org,'trial',reference,actor,0,schedule.trial_sponsored_cents,p_purchased_at,p_expires_at,1,schedule.trial_reserve_components,schedule.evidence_sha256);
 else
  result:=public.provision_serving_funding(p_org,'retail',reference,null,schedule.net_proceeds_floor_cents,0,p_purchased_at,p_expires_at,schedule.service_months,schedule.reserve_components,schedule.evidence_sha256);
 end if;
 update public.serving_funding set apple_original_transaction_id=p_original,sponsor_pool_id=case when p_price_milliunits=0 then pool.id else null end where id=(result->>'funding_id')::uuid;
 return result||jsonb_build_object('funded',true,'schedule_id',schedule.id);
end$$;
revoke all on function public.fund_verified_apple_transaction(uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text)from public,anon,authenticated;
grant execute on function public.fund_verified_apple_transaction(uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text)to service_role;
commit;
