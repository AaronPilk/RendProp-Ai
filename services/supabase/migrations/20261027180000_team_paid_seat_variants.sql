-- Exact Apple Team subscription variants. The existing three-seat SKU and
-- renewals are unchanged. New SKUs are inert until App Store Connect pricing,
-- a matching signed-price serving schedule, and monthly credit activation are
-- reviewed together. Brokerage starts at ten seats, so Team stops at nine.
begin;

create table public.team_paid_seat_variants (
  product_id text primary key,
  seats integer not null unique check (seats between 4 and 9),
  monthly_credits integer not null check (monthly_credits between 1100 and 1600),
  target_us_price_cents integer not null check (target_us_price_cents > 24900),
  active boolean not null default false,
  check (monthly_credits = 1000 + 100 * (seats - 3))
);
insert into public.team_paid_seat_variants
  (product_id,seats,monthly_credits,target_us_price_cents,active) values
  ('com.rendprop.app.team4.monthly',4,1100,29999,false),
  ('com.rendprop.app.team5.monthly',5,1200,34999,false),
  ('com.rendprop.app.team6.monthly',6,1300,39999,false),
  ('com.rendprop.app.team7.monthly',7,1400,44999,false),
  ('com.rendprop.app.team8.monthly',8,1500,49999,false),
  ('com.rendprop.app.team9.monthly',9,1600,54999,false);

insert into public.credit_monthly_catalog(product_id,credits,active)
select product_id,monthly_credits,false from public.team_paid_seat_variants;
alter table public.team_paid_seat_variants enable row level security;
revoke all on public.team_paid_seat_variants from public,anon,authenticated,service_role;
grant select on public.team_paid_seat_variants to service_role;

-- Seat count and gross price come from the CURRENT signed, paid Apple term.
-- The retail funding row proves a matching JWS price was accepted against a
-- reviewed US/USD schedule. Neither a future auto-renew SKU nor a client-side
-- product name can alter capacity. Sandbox receipts cannot fund production.
create function public.team_current_paid_variant(p_org uuid)
returns table(product_id text,seats integer,monthly_credits integer,price_cents integer)
language sql stable security definer set search_path='' as $$
  select v.product_id,v.seats,v.monthly_credits,
         (sc.price_milliunits / 10)::integer as price_cents
    from public.orgs o
    join public.apple_subscriptions s on s.org_id=o.id
      and s.product_id=o.apple_product_id
      and s.expires_at=o.plan_expires_at
    join public.team_paid_seat_variants v on v.product_id=s.product_id
      and v.active
    join public.credit_monthly_catalog c on c.product_id=v.product_id
      and c.active and c.credits=v.monthly_credits
    join public.serving_funding f on f.org_id=o.id
      and f.apple_original_transaction_id=s.original_transaction_id
      and f.collection_ref='apple:'||s.last_transaction_id
      and f.source='retail' and f.revoked_at is null
      and f.starts_at<=now() and f.ends_at>now()
    join public.apple_serving_schedules sc on sc.product_id=v.product_id
      and sc.evidence_sha256=f.evidence_sha256
      and sc.net_proceeds_floor_cents=f.net_receipts_cents
      and sc.price_milliunits=v.target_us_price_cents::bigint*10
      and sc.starts_at<=s.transaction_purchased_at
      and sc.ends_at>s.transaction_purchased_at
    where o.id=p_org and o.deleted_at is null
      and o.plan_source='apple' and o.plan='team'
      and s.environment='Production' and s.status='active'
      and s.last_transaction_id is not null
      and s.transaction_purchased_at is not null
      and s.transaction_signed_at is not null
      and s.expires_at>now()
    order by s.transaction_purchased_at desc limit 1;
$$;
revoke all on function public.team_current_paid_variant(uuid)
  from public,anon,authenticated;
grant execute on function public.team_current_paid_variant(uuid)
  to service_role,postgres;

-- Preserve all existing trial/private/brokerage branches. Change only their
-- fallthrough Team capacity and its exact paid price, guarded by known anchors.
do $patch$
declare definition text;body text;old text;replacement text;hits integer;
begin
  select pg_get_functiondef(oid),prosrc into definition,body from pg_proc
    where oid='public.org_entitlement(uuid)'::regprocedure;
  old:='  budget:=public.paid_quality_processing_budget(b);';
  replacement:=E'  if b=p_org and exists(select 1 from public.team_current_paid_variant(p_org)) then\n'
    ||E'    select v.seats,v.price_cents into e.seats,e.price_cents\n'
    ||E'      from public.team_current_paid_variant(p_org) v;\n'
    ||E'  end if;\n'||old;
  hits:=(length(body)-length(replace(body,old,'')))/length(old);
  if hits<>1 then raise exception 'Review changed org_entitlement before Team seat variants';end if;
  execute replace(definition,old,replacement);

  select pg_get_functiondef(oid),prosrc into definition,body from pg_proc
    where oid='public.org_seats_allowed(uuid)'::regprocedure;
  old:='    (select coalesce(e.seats, 1) from plan_entitlements e';
  replacement:=E'    (select v.seats from public.team_current_paid_variant(p_org) v),\n'||old;
  hits:=(length(body)-length(replace(body,old,'')))/length(old);
  if hits<>1 then raise exception 'Review changed org_seats_allowed before Team seat variants';end if;
  execute replace(definition,old,replacement);
end$patch$;

-- An immediate Apple upgrade starts a new, full paid period and refunds the
-- unused portion of the old tier. Mint the new period once, then close any
-- older overlapping monthly allowance from the SAME signed Apple chain.
-- Already-spent credits stay spent; credits held by an admitted job may still
-- settle. Top-ups and unrelated subscriptions are never touched.
alter function public.credit_verified_monthly_apply(
  uuid,text,text,text,text,timestamptz,timestamptz,bigint,timestamptz,timestamptz,text)
  rename to credit_verified_monthly_apply_before_seat_variants;
create function public.credit_verified_monthly_apply(
  p_org uuid,p_product text,p_environment text,p_original text,p_transaction text,
  p_start timestamptz,p_end timestamptz,p_price_milliunits bigint,
  p_transaction_signed_at timestamptz,p_event_signed_at timestamptz,p_event text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;is_current boolean;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege;
  end if;
  -- Match the chronology writer's chain lock before testing the effective
  -- transaction, then let the original wallet RPC take its wallet lock.
  -- This prevents a concurrent upgrade from making a reversal stale between
  -- our check and the original RPC's restore branch.
  if p_original is not null and length(p_original) between 1 and 200 then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(p_original,72451));
  end if;
  -- A late refund reversal for an older, superseded transaction must not
  -- restore credits after the buyer has changed plans.
  if p_event='reversed' then
    if p_environment='Production' then
      select exists(select 1 from public.apple_subscriptions s
        where s.original_transaction_id=p_original and s.org_id=p_org
          and s.environment=p_environment
          and s.last_transaction_id=p_transaction and s.product_id=p_product)
        into is_current;
    elsif p_environment='Sandbox' then
      select exists(select 1 from public.apple_sandbox_receipts s
        where s.original_transaction_id=p_original and s.org_id=p_org
          and s.transaction_id=p_transaction and s.product_id=p_product)
        into is_current;
    end if;
    if is_current is false then
      return jsonb_build_object('granted',false,'reason','not_current_paid_period');
    end if;
  end if;
  if p_environment='Production' and p_event in('paid','reversed')
     and exists(select 1 from public.team_paid_seat_variants v
       where v.product_id=p_product)
     and not exists(select 1 from public.team_current_paid_variant(p_org) v
       where v.product_id=p_product) then
    return jsonb_build_object('granted',false,'reason','variant_not_funded');
  end if;

  result:=public.credit_verified_monthly_apply_before_seat_variants(
    p_org,p_product,p_environment,p_original,p_transaction,p_start,p_end,
    p_price_milliunits,p_transaction_signed_at,p_event_signed_at,p_event);
  if p_event not in('paid','reversed') or result->>'granted' is distinct from 'true'
     or p_start is null then return result;end if;
  if p_environment='Production' then
    select exists(select 1 from public.apple_subscriptions s
      where s.original_transaction_id=p_original and s.org_id=p_org
        and s.environment=p_environment and s.status in('active','grace')
        and s.last_transaction_id=p_transaction and s.product_id=p_product)
      into is_current;
  else
    select exists(select 1 from public.apple_sandbox_receipts s
      where s.original_transaction_id=p_original and s.org_id=p_org
        and s.status in('active','grace')
        and s.transaction_id=p_transaction and s.product_id=p_product)
      into is_current;
  end if;
  if is_current then
    update public.credit_grants g set revoked_at=coalesce(g.revoked_at,p_event_signed_at)
      from public.credit_monthly_events m
      where g.org_id=p_org and g.environment=p_environment
        and g.source='monthly' and g.reference='apple:'||m.transaction_id
        and m.environment=p_environment and m.org_id=p_org
        and m.original_transaction_id=p_original
        and m.transaction_id<>p_transaction
        and g.starts_at<p_start and g.expires_at>p_start;
  end if;
  return result;
end$$;
revoke all on function public.credit_verified_monthly_apply_before_seat_variants(
  uuid,text,text,text,text,timestamptz,timestamptz,bigint,timestamptz,timestamptz,text)
  from public,anon,authenticated,service_role;
revoke all on function public.credit_verified_monthly_apply(
  uuid,text,text,text,text,timestamptz,timestamptz,bigint,timestamptz,timestamptz,text)
  from public,anon,authenticated;
grant execute on function public.credit_verified_monthly_apply(
  uuid,text,text,text,text,timestamptz,timestamptz,bigint,timestamptz,timestamptz,text)
  to service_role;

commit;
