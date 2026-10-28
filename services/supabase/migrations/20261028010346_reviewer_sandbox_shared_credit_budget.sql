-- A dedicated App Review account may exercise a signed paid Sandbox period,
-- but the Sandbox sale is not cash. Every supplier attempt shares the same
-- nonrenewable app_review sponsor envelope as legacy Pro-style work. No grant,
-- catalog, tariff, media budget, or owner cash is activated by this migration.
begin;

-- Refuse an unexpected live definition rather than wrap a different money
-- authority. This migration is source-only until its complete deployment
-- order and operator cash evidence are independently checked.
do $preflight$ declare d text;begin
 d:=pg_get_functiondef('public.credit_primary_subscription(uuid,text)'::regprocedure);
 if position('p_environment<>''Production''' in d)=0 or
    position('credit_combined_budget_state' in d)=0 then
   raise exception 'Review changed paid primary credit authority';end if;
 d:=pg_get_functiondef('public.plan_serving_ceiling(uuid)'::regprocedure);
 if position('credit_combined_budget_state' in d)=0 then
   raise exception 'Review changed paid plan supplier ceiling';end if;
 d:=pg_get_functiondef('public.serving_ceiling_spent_cents(uuid,timestamptz,timestamptz)'::regprocedure);
 if position('public.cost_ledger' in d)=0 or
    position('public.serving_cost_reservations' in d)=0 then
   raise exception 'Review changed shared supplier spend ledger';end if;
 d:=pg_get_functiondef('public.org_month_spend_cents(uuid)'::regprocedure);
 if position('public.plan_serving_ceiling' in d)=0 then
   raise exception 'Review changed monthly supplier spend authority';end if;
end $preflight$;

create function public.reviewer_sandbox_signed_credit(p_org uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select current_setting('role',true)='service_role' and exists(
   select 1 from public.serving_funding f
   join public.serving_funding_slices sl on sl.funding_id=f.id and sl.slice_index=0
   join public.apple_sandbox_receipts s on s.org_id=f.org_id and s.actor_id=f.actor_id
   join public.credit_monthly_events e on e.environment='Sandbox'
     and e.org_id=f.org_id and e.original_transaction_id=s.original_transaction_id
     and e.transaction_id=s.transaction_id and e.product_id=s.product_id
   join public.credit_monthly_catalog c on c.product_id=e.product_id and c.active
   join public.credit_grants g on g.org_id=f.org_id and g.environment='Sandbox'
     and g.source='monthly' and g.reference='apple:'||e.transaction_id
     and g.product_id=e.product_id and g.revoked_at is null
     and g.starts_at=e.period_start and g.expires_at>=e.period_end
   join public.media_delivery_budgets m on m.org_id=f.org_id and m.funding_id=f.id
     and m.starts_at=f.starts_at and m.ends_at=f.retention_ends_at
     and m.starts_at<=now() and m.ends_at>now()
   join public.media_account_reserves a on a.receipt_ref=m.account_reserve_ref
     and a.cash_source='business_paid_cash' and a.starts_at<=f.starts_at
     and a.ends_at>=f.retention_ends_at
   where f.org_id=p_org and f.source='app_review' and f.revoked_at is null
     and f.starts_at<=now() and f.ends_at>now() and f.actor_id is not null
     and sl.starts_at=f.starts_at and sl.ends_at=f.ends_at
     and s.status='active' and e.state in('paid','reversed')
     and e.price_milliunits>0 and e.period_start<=now() and e.period_end>now()
     and g.starts_at<=now() and g.expires_at>now()
     and public.org_has_app_review_funding(f.org_id)
     and not public.org_has_internal_testing_grant(f.org_id)
     and not public.org_has_private_internal_testing(f.org_id)
     and not exists(select 1 from public.apple_subscriptions p
       where p.org_id=f.org_id and p.environment='Production'
         and p.status in('active','grace'))
 );
$$;
revoke all on function public.reviewer_sandbox_signed_credit(uuid)
 from public,anon,authenticated;
grant execute on function public.reviewer_sandbox_signed_credit(uuid)
 to service_role;

-- Keep the existing Production paid-credit authority byte-for-byte. Only the
-- exact dedicated reviewer may use a current signed Sandbox monthly wallet.
alter function public.credit_primary_subscription(uuid,text)
 rename to credit_primary_subscription_before_reviewer_20261028;
create function public.credit_primary_subscription(p_org uuid,p_environment text)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if p_environment='Sandbox' and public.reviewer_sandbox_signed_credit(p_org)
 then return true;end if;
 return public.credit_primary_subscription_before_reviewer_20261028(p_org,p_environment);
end$$;
revoke all on function public.credit_primary_subscription(uuid,text),
 public.credit_primary_subscription_before_reviewer_20261028(uuid,text)
 from public,anon,authenticated;
grant execute on function public.credit_primary_subscription(uuid,text),
 public.credit_primary_subscription_before_reviewer_20261028(uuid,text)
 to service_role;

-- The older reviewer ceiling was a calendar-month $5 that could refill when
-- a seven-day grant crossed a month boundary. Use the immutable funding slice
-- and deduct the media/retention reserve from the *same* $5 commitment.
alter function public.plan_serving_ceiling(uuid)
 rename to plan_serving_ceiling_before_reviewer_20261028;
create function public.plan_serving_ceiling(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare f public.serving_funding;sl public.serving_funding_slices;b uuid;
begin
 b:=public.library_billing_org(p_org);
 if public.org_has_app_review_funding(b) then
   select * into f from public.serving_funding where org_id=b and source='app_review'
     and revoked_at is null and starts_at<=now() and ends_at>now();
   select * into sl from public.serving_funding_slices
     where funding_id=f.id and starts_at<=now() and ends_at>now();
   if sl.funding_id is null or sl.total_budget_cents>500
      or sl.recurring_reserve_cents>sl.total_budget_cents
   then raise exception 'RP503: Reviewer sponsor slice is unavailable';end if;
   return jsonb_build_object('ceiling_cents',
     sl.total_budget_cents-sl.recurring_reserve_cents,
     'basis','period','kind','app_review','plan','pro','sku',null,
     'period_start',sl.starts_at,'period_end',sl.ends_at,
     'window','review_grant','funding_id',f.id);
 end if;
 return public.plan_serving_ceiling_before_reviewer_20261028(p_org);
end$$;
revoke all on function public.plan_serving_ceiling(uuid),
 public.plan_serving_ceiling_before_reviewer_20261028(uuid)
 from public,anon,authenticated;
grant execute on function public.plan_serving_ceiling(uuid),
 public.plan_serving_ceiling_before_reviewer_20261028(uuid)
 to service_role,postgres;

-- The older Pro entitlement also advertised a fresh $5 processing allowance.
-- It now reports the exact provider remainder of the one review commitment.
alter function public.org_entitlement(uuid)
 rename to org_entitlement_before_reviewer_20261028;
create function public.org_entitlement(p_org uuid)
returns public.plan_entitlements language plpgsql stable security definer
 set search_path='' as $$
declare e public.plan_entitlements;ceiling jsonb;b uuid;
begin
 e:=public.org_entitlement_before_reviewer_20261028(p_org);
 b:=public.library_billing_org(p_org);
 if public.org_has_app_review_funding(b) then
   ceiling:=public.plan_serving_ceiling(b);
   e.cogs_ceiling_cents:=(ceiling->>'ceiling_cents')::integer;
 end if;
 return e;
end$$;
revoke all on function public.org_entitlement(uuid),
 public.org_entitlement_before_reviewer_20261028(uuid)
 from public,anon,authenticated;
grant execute on function public.org_entitlement(uuid),
 public.org_entitlement_before_reviewer_20261028(uuid)
 to authenticated,service_role,postgres;

-- The common ceiling ledger already counts actual cost receipts, unresolved
-- ceiling holds, and video holds. Include unresolved funded and Sandbox credit
-- holds for this reviewer so every route sees one shared supplier balance.
alter function public.serving_ceiling_spent_cents(uuid,timestamptz,timestamptz)
 rename to serving_ceiling_spent_cents_before_reviewer_20261028;
create function public.serving_ceiling_spent_cents(
 p_org uuid,p_start timestamptz,p_end timestamptz)
returns numeric language plpgsql stable security definer set search_path='' as $$
declare base numeric;extra numeric;f public.serving_funding;b uuid;
begin
 base:=public.serving_ceiling_spent_cents_before_reviewer_20261028(
   p_org,p_start,p_end);
 b:=public.library_billing_org(p_org);
 if not public.org_has_app_review_funding(b) then return base;end if;
 select * into f from public.serving_funding where org_id=b and source='app_review'
   and revoked_at is null and starts_at<=now() and ends_at>now();
 if f.id is null or p_start is distinct from f.starts_at
    or p_end is distinct from f.ends_at
 then raise exception 'RP503: Reviewer supplier period changed';end if;
 select coalesce(sum(r.hold_cents),0) into extra
 from public.serving_cost_reservations r
 where r.billing_org_id=b and r.ledger_id is null
   and r.state in('reserved','uncertain','succeeded')
   and ((r.budget_source='funding' and r.funding_id=f.id)
      or (r.budget_source='credits' and r.credit_environment='Sandbox'));
 return base+extra;
end$$;
revoke all on function public.serving_ceiling_spent_cents(uuid,timestamptz,timestamptz),
 public.serving_ceiling_spent_cents_before_reviewer_20261028(uuid,timestamptz,timestamptz)
 from public,anon,authenticated;
grant execute on function public.serving_ceiling_spent_cents(uuid,timestamptz,timestamptz),
 public.serving_ceiling_spent_cents_before_reviewer_20261028(uuid,timestamptz,timestamptz)
 to service_role,postgres;

alter function public.org_month_spend_cents(uuid)
 rename to org_month_spend_cents_before_reviewer_20261028;
create function public.org_month_spend_cents(p_org uuid)
returns numeric language plpgsql stable security definer set search_path='' as $$
declare ceiling jsonb;b uuid;
begin
 b:=public.library_billing_org(p_org);
 if public.org_has_app_review_funding(b) then
   ceiling:=public.plan_serving_ceiling(b);
   return public.serving_ceiling_spent_cents(b,
     (ceiling->>'period_start')::timestamptz,
     (ceiling->>'period_end')::timestamptz);
 end if;
 return public.org_month_spend_cents_before_reviewer_20261028(p_org);
end$$;
revoke all on function public.org_month_spend_cents(uuid),
 public.org_month_spend_cents_before_reviewer_20261028(uuid)
 from public,anon,authenticated;
grant execute on function public.org_month_spend_cents(uuid),
 public.org_month_spend_cents_before_reviewer_20261028(uuid)
 to authenticated,service_role,postgres;

-- The final immutable journal fence. Both legacy and credit writers reach it
-- before provider dispatch; the two existing lock identities serialize against
-- ceiling-mode video admission and funded-mode legacy attempts respectively.
create function public.review_shared_supplier_reserve_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare b uuid;f public.serving_funding;sl public.serving_funding_slices;
 spent numeric;
begin
 b:=public.library_actor_billing_org(new.actor_id,new.org_id);
 select * into f from public.serving_funding where org_id=b and source='app_review'
   and revoked_at is null and starts_at<=now() and ends_at>now();
 if f.id is null then return new;end if;
 if new.budget_source='credits' and new.credit_environment='Production'
 then return new;end if;
 if current_setting('role',true) is distinct from 'service_role'
    or new.actor_id is distinct from f.actor_id or
    new.billing_org_id is distinct from b or
    not public.org_has_app_review_funding(b)
 then raise exception 'RP403: Reviewer supplier attempt belongs to another account';end if;
 if new.budget_source='credits' and
    (new.credit_environment is distinct from 'Sandbox' or
      not public.reviewer_sandbox_signed_credit(b) or
      not exists(select 1 from public.credit_holds h where h.id=new.credit_hold_id
        and h.org_id=b and h.actor_id=f.actor_id and h.environment='Sandbox'
        and h.state in('reserved','settled')))
 then raise exception 'RP403: Signed reviewer Sandbox credit authority is unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||b,72452));
 perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||b::text,42));
 select * into sl from public.serving_funding_slices where funding_id=f.id
   and starts_at<=now() and ends_at>now() for update;
 if sl.funding_id is null then raise exception 'RP402: Reviewer sponsor expired';end if;
 spent:=public.serving_ceiling_spent_cents(b,sl.starts_at,sl.ends_at);
 if spent+new.hold_cents>sl.total_budget_cents-sl.recurring_reserve_cents
 then raise exception 'RP402: Shared reviewer supplier budget is used up';end if;
 return new;
end$$;
revoke all on function public.review_shared_supplier_reserve_guard()
 from public,anon,authenticated;
create trigger zzz_review_shared_supplier_reserve_guard
 before insert on public.serving_cost_reservations
 for each row execute function public.review_shared_supplier_reserve_guard();

-- Credit aerial opening also writes a second app_video accounting hold for
-- the same KIE stage. It may not introduce an unjournaled Sandbox charge.
create function public.review_shared_video_reserve_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare b uuid;f public.serving_funding;sl public.serving_funding_slices;
 spent numeric;
begin
 b:=public.library_actor_billing_org(new.actor_id,new.org_id);
 select * into f from public.serving_funding where org_id=b and source='app_review'
   and revoked_at is null and starts_at<=now() and ends_at>now();
 if f.id is null or new.credit_environment='Production' then return new;end if;
 if current_setting('role',true) is distinct from 'service_role' or
    new.actor_id is distinct from f.actor_id or
    new.billing_org_id is distinct from b
 then raise exception 'RP403: Reviewer video attempt belongs to another account';end if;
 if new.credit_hold_id is not null then
   if not public.reviewer_sandbox_signed_credit(b) or
      new.credit_environment is distinct from 'Sandbox' or
      not exists(select 1 from public.serving_cost_reservations r
        where r.credit_hold_id=new.credit_hold_id and r.budget_source='credits'
          and r.credit_environment='Sandbox' and r.billing_org_id=b
          and r.actor_id=f.actor_id and r.request_key=new.idempotency_key
          and r.stage='aerial' and r.state<>'rejected'
          and r.hold_cents>=new.hold_cents)
   then raise exception 'RP403: Reviewer aerial video lacks its shared credit hold';end if;
   return new;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||b::text,42));
 select * into sl from public.serving_funding_slices where funding_id=f.id
   and starts_at<=now() and ends_at>now() for update;
 if sl.funding_id is null then raise exception 'RP402: Reviewer sponsor expired';end if;
 spent:=public.serving_ceiling_spent_cents(b,sl.starts_at,sl.ends_at);
 if spent+new.hold_cents>sl.total_budget_cents-sl.recurring_reserve_cents
 then raise exception 'RP402: Shared reviewer supplier budget is used up';end if;
 return new;
end$$;
revoke all on function public.review_shared_video_reserve_guard()
 from public,anon,authenticated;
create trigger zzz_review_shared_video_reserve_guard
 before insert on public.app_video_cost_reservations
 for each row execute function public.review_shared_video_reserve_guard();

-- Existing Sandbox guards remain for all QA and retail accounts. The single
-- dedicated reviewer is additionally allowed, then the journal trigger above
-- checks the one shared sponsor cap atomically. Daily QA cap still applies to
-- QA accounts; it does not create a second reviewer allowance.
do $patch$ declare d text;a text;b text;begin
 d:=pg_get_functiondef('public.credit_serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text,uuid,text,text)'::regprocedure);
 a:='public.org_has_private_internal_testing(bill)) then';
 b:='public.org_has_private_internal_testing(bill) or public.reviewer_sandbox_signed_credit(bill)) then';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then
   raise exception 'Review changed Sandbox photo supplier guard';end if;
 d:=replace(d,a,b);
 a:='if total+p_hold_cents>300 then';
 b:='if not public.reviewer_sandbox_signed_credit(bill) and total+p_hold_cents>300 then';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then
   raise exception 'Review changed Sandbox photo daily cap';end if;
 execute replace(d,a,b);
end $patch$;

do $patch$ declare d text;a text;b text;begin
 d:=pg_get_functiondef('public.credit_photo_motion_fund(uuid,uuid,uuid,text,jsonb,text)'::regprocedure);
 a:='public.org_has_private_internal_testing(p_billing)) then';
 b:='public.org_has_private_internal_testing(p_billing) or public.reviewer_sandbox_signed_credit(p_billing)) then';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then
   raise exception 'Review changed Sandbox Photo Motion guard';end if;
 d:=replace(d,a,b);
 a:='if legacy+quote_cents>300 then';
 b:='if not public.reviewer_sandbox_signed_credit(p_billing) and legacy+quote_cents>300 then';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then
   raise exception 'Review changed Sandbox Photo Motion daily cap';end if;
 execute replace(d,a,b);
end $patch$;

do $patch$ declare d text;a text;b text;begin
 d:=pg_get_functiondef('public.property_video_aerial_admit_credit(uuid,jsonb,jsonb,jsonb,text,text)'::regprocedure);
 a:='public.org_has_private_internal_testing(billing)) then';
 b:='public.org_has_private_internal_testing(billing) or public.reviewer_sandbox_signed_credit(billing)) then';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then
   raise exception 'Review changed Sandbox aerial guard';end if;
 d:=replace(d,a,b);
 a:=$anchor$if daily+(p_quote->>'maximum_total_cents')::numeric>300 then$anchor$;
 b:=$anchor$if not public.reviewer_sandbox_signed_credit(billing) and daily+(p_quote->>'maximum_total_cents')::numeric>300 then$anchor$;
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then
   raise exception 'Review changed Sandbox aerial daily cap';end if;
 execute replace(d,a,b);
end $patch$;

commit;
