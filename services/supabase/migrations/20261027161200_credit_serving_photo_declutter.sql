-- One provisional, bounded credit-funded operation. Customer credits and
-- supplier liabilities remain separate journals, joined by the credit hold.
begin;

insert into public.credit_tariffs(operation,version,credits,active)
values('photo.declutter','photo-declutter-v1',10,true)
on conflict(operation,version) do nothing;

-- Only a current verified paid Apple SKU with an activated monthly-credit
-- catalog moves to primary wallet admission. Legacy/manual plans stay intact.
create or replace function public.credit_primary_subscription(p_org uuid,p_environment text)
returns boolean language sql stable security definer set search_path='' as $$
 select current_setting('role',true)='service_role' and exists(
   select 1 from public.apple_subscriptions s
   join public.credit_monthly_catalog c on c.product_id=s.product_id and c.active
   where s.org_id=p_org and s.environment=p_environment and s.status='active'
     and s.expires_at>now()
     and exists(select 1 from public.credit_grants g where g.org_id=p_org
       and g.environment=p_environment and g.source='monthly'
       and g.product_id=s.product_id and g.revoked_at is null
       and g.starts_at<=now() and g.expires_at>now())
 );
$$;

alter table public.serving_cost_reservations
  add column if not exists credit_hold_id uuid references public.credit_holds(id);
alter table public.serving_cost_reservations
  add column if not exists credit_environment text;
alter table public.serving_cost_reservations
  drop constraint if exists serving_cost_reservations_budget_source_check;
alter table public.serving_cost_reservations
  add constraint serving_cost_reservations_budget_source_check
  check(budget_source in('funding','ceiling','credits'));
alter table public.serving_cost_reservations
  drop constraint if exists serving_cost_reservations_check;
alter table public.serving_cost_reservations
  add constraint serving_cost_reservations_check check(
    (sponsored_unlimited and budget_source='funding' and funding_id is null and slice_index is null and credit_hold_id is null)
    or(not sponsored_unlimited and budget_source='ceiling' and funding_id is null and slice_index is null and credit_hold_id is null)
    or(not sponsored_unlimited and budget_source='funding' and funding_id is not null and slice_index is not null and credit_hold_id is null)
    or(not sponsored_unlimited and budget_source='credits' and funding_id is null and slice_index is null and credit_hold_id is not null));
alter table public.serving_cost_reservations
  add constraint serving_cost_reservations_credit_environment_check
  check((budget_source='credits' and credit_environment in('Production','Sandbox'))
    or (budget_source<>'credits' and credit_environment is null));
create index if not exists serving_credit_hold_costs
  on public.serving_cost_reservations(credit_hold_id,state) where budget_source='credits';

create or replace function public.credit_serving_cost_reserve(
 p_actor uuid,p_org uuid,p_key text,p_stage text,p_provider text,p_model text,
 p_input_sha256 text,p_hold_cents numeric,p_tariff_version text,
 p_credit_org uuid,p_credit_key text,p_environment text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare h public.credit_holds; reservation uuid; total numeric; bill uuid;
  qc_id uuid; evidence public.photo_edit_evidence;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
 if p_actor is null or p_org is null or p_credit_org is null or
    p_key is null or p_key !~ '^[A-Za-z0-9:_-]{8,128}$' or
    p_credit_key is null or p_credit_key !~ '^[A-Za-z0-9:_-]{8,128}$' or
    p_stage is null or p_stage !~ '^[a-z0-9:._-]{1,80}$' or
    p_provider is null or length(p_provider) not between 1 and 40 or
    p_model is null or length(p_model) not between 1 and 240 or
    p_input_sha256 is null or p_input_sha256 !~ '^[a-f0-9]{64}$' or
    p_hold_cents is null or p_hold_cents::text in('NaN','Infinity','-Infinity') or
    p_hold_cents<=0 or p_hold_cents>100000000 or p_hold_cents<>round(p_hold_cents,4) or
    p_tariff_version is null or length(p_tariff_version) not between 1 and 120 or
    p_environment not in('Production','Sandbox') then
   raise exception 'RP400: A bounded verified credit attempt is required'; end if;
 bill:=public.library_actor_billing_org(p_actor,p_org);
 if bill is distinct from p_credit_org or
    not public.library_financial_actor(p_actor,p_org) or
    (not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)
     and not public.org_has_verified_retail_guest(p_actor,p_org)) or
    exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing')) then
   raise exception 'RP403: Current editor and billing workspace required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||bill,72452));
 perform pg_advisory_xact_lock(hashtextextended('credit-wallet:'||bill||':'||p_environment,71003));
 select * into h from public.credit_holds where org_id=bill and actor_id=p_actor
   and environment=p_environment and request_key=p_credit_key for update;
 if h.id is null or h.operation<>'photo.declutter' or
    h.tariff_version<>'photo-declutter-v1' or h.state not in('reserved','settled') then
   raise exception 'RP402: This declutter credit hold is unavailable'; end if;
 if p_key=p_credit_key then
   if p_stage !~ '^photo[.]declutter:[0-9]+$' or
     not exists(select 1 from public.serving_operations o where o.org_id=p_org
       and o.actor_id=p_actor and o.request_key=p_key) then
     raise exception 'RP403: Original photo operation required'; end if;
 else
   if p_key !~ '^photo-qc:[a-f0-9-]{36}$' or p_stage<>'photo.qc:0' then
     raise exception 'RP403: Only the saved photo judge may share this hold'; end if;
   qc_id:=substring(p_key from 10)::uuid;
   select e.* into evidence from public.photo_quality_checks q
     join public.photo_edit_evidence e on e.id=q.evidence_id
     where q.id=qc_id and e.actor_id=p_actor and e.org_id=p_org
       and e.request_key=p_credit_key and e.edit='declutter';
   if evidence.id is null then raise exception 'RP403: Saved declutter check required'; end if;
   if not exists(select 1 from public.serving_operations o where o.org_id=p_org
      and o.actor_id=p_actor and o.request_key=p_key) then
     raise exception 'RP403: Saved judge operation required'; end if;
 end if;
 if exists(select 1 from public.serving_cost_reservations r where r.org_id=p_org
    and r.actor_id=p_actor and r.request_key=p_key and r.stage=p_stage) then
   raise exception 'RP409: This provider attempt is already journaled'; end if;
 -- Supplier quote may never exceed the retail credit risk ceiling. An
 -- uncertain submission retains its bound; only definitive rejection frees it.
 select coalesce(sum(r.hold_cents),0) into total
   from public.serving_cost_reservations r where r.credit_hold_id=h.id
     and r.budget_source='credits' and r.state<>'rejected';
 if total+p_hold_cents>h.credits*5 then
   raise exception 'RP402: This credit quote cannot fund another provider attempt'; end if;
 -- Free Sandbox purchases are not real revenue. Bound the real supplier bill
 -- to internal QA accounts and $3 per billing workspace per rolling day.
 if p_environment='Sandbox' then
   if not(public.org_has_internal_testing_grant(bill) or
      public.org_has_private_internal_testing(bill)) then
     raise exception 'RP403: Sandbox credits are restricted to internal testing'; end if;
   select coalesce(sum(r.hold_cents),0) into total
     from public.serving_cost_reservations r where r.billing_org_id=bill
       and r.budget_source='credits' and r.credit_environment='Sandbox'
       and r.state<>'rejected' and r.created_at>=now()-interval '1 day';
   if total+p_hold_cents>300 then
     raise exception 'RP402: The daily Sandbox test budget is used up'; end if;
 end if;
 insert into public.serving_cost_reservations(org_id,billing_org_id,actor_id,request_key,
   stage,provider,model,input_sha256,tariff_version,hold_cents,sponsored_unlimited,
   budget_source,credit_hold_id,credit_environment,trial_kind)
 values(p_org,bill,p_actor,p_key,p_stage,p_provider,p_model,p_input_sha256,
   p_tariff_version,p_hold_cents,false,'credits',h.id,p_environment,false)
 returning id into reservation;
 return jsonb_build_object('reserved',true,'id',reservation,'hold_cents',p_hold_cents,
   'budget','credits','credit_hold_id',h.id);
end$$;

-- The existing exact-match ledger trigger handles ceiling receipts. This
-- separate branch binds only credit receipts; it never widens ceiling matching.
create or replace function public.cost_ledger_settle_credit_hold() returns trigger
language plpgsql security definer set search_path='' as $$
declare matches uuid[];
begin
 if new.org_id is null or new.provider is null or new.model is null or
    nullif(new.meta->>'request_key','') is null or
    nullif(new.meta->>'stage','') is null then return new; end if;
 select array_agg(x.id) into matches from (
   select r.id from public.serving_cost_reservations r
   where r.org_id=new.org_id and r.request_key=new.meta->>'request_key'
     and r.stage=new.meta->>'stage' and r.provider=new.provider
     and r.model=new.model and r.budget_source='credits' and r.state='succeeded'
     and (new.meta->>'actor_id' is null or r.actor_id::text=new.meta->>'actor_id')
   for update
 ) x;
 if cardinality(matches)=1 then
   update public.serving_cost_reservations set ledger_id=new.id
   where id=matches[1] and ledger_id is null;
 end if;
 return new;
end$$;
drop trigger if exists cost_ledger_settle_credit_hold on public.cost_ledger;
create trigger cost_ledger_settle_credit_hold after insert on public.cost_ledger
 for each row execute function public.cost_ledger_settle_credit_hold();

-- A definitely unsubmitted operation can return the customer's reservation.
-- Once supplier dispatch may have happened, retain it for outcome recovery.
create or replace function public.credit_wallet_finish(
  p_actor uuid,p_org uuid,p_environment text,p_key text,p_state text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare held public.credit_holds; alloc record; source_grant public.credit_grants;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_state not in('settled','released') then raise exception 'RP400: A terminal credit outcome is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('credit-wallet:'||p_org||':'||p_environment,71003));
  select * into held from public.credit_holds where org_id=p_org and environment=p_environment
    and actor_id=p_actor and request_key=p_key for update;
  if not found then raise exception 'RP404: Credit hold not found'; end if;
  if held.state<>'reserved' then
    if held.state<>p_state then raise exception 'RP409: Credit outcome cannot be rewritten'; end if;
    return jsonb_build_object('state',held.state,'credits',held.credits,'replay',true);
  end if;
  if p_state='released' then
    if exists(select 1 from public.serving_cost_reservations r where
      r.credit_hold_id=held.id and r.budget_source='credits' and r.state<>'rejected') then
      raise exception 'RP409: Provider liability may exist; retain this credit hold'; end if;
    for alloc in select * from public.credit_hold_allocations where hold_id=held.id loop
      select * into source_grant from public.credit_grants where id=alloc.grant_id for update;
      if source_grant.revoked_at is null then
        update public.credit_grants set remaining_credits=remaining_credits+alloc.credits
          where id=alloc.grant_id;
      elsif source_grant.source='topup' then
        update public.credit_refund_debts set debt_credits=greatest(0,debt_credits-alloc.credits)
          where environment=source_grant.environment and transaction_id=source_grant.reference;
      end if;
    end loop;
  end if;
  update public.credit_holds set state=p_state,finished_at=now() where id=held.id;
  return jsonb_build_object('state',p_state,'credits',held.credits,'replay',false);
end$$;

revoke all on function public.credit_primary_subscription(uuid,text),
 public.credit_serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text,uuid,text,text),
 public.cost_ledger_settle_credit_hold() from public,anon,authenticated;
grant execute on function public.credit_primary_subscription(uuid,text),
 public.credit_serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text,uuid,text,text),
 public.cost_ledger_settle_credit_hold() to service_role;
commit;
