begin;
-- An anonymous Auth user is not a trial/reviewer/private sponsor. Only their
-- exact signed Production retail chain and its current funded slice can admit
-- them. This helper reads service-owned rows, never JWT/user metadata claims.
create or replace function public.org_has_verified_retail_guest(p_actor uuid,p_org uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select current_setting('role',true)='service_role' and exists(
  select 1 from auth.users u join public.memberships m on m.user_id=u.id
   join public.orgs o on o.id=m.org_id
   join public.apple_subscriptions a on a.org_id=o.id and a.user_id=u.id
   join public.serving_funding f on f.org_id=o.id and f.apple_original_transaction_id=a.original_transaction_id
   join public.serving_funding_slices s on s.funding_id=f.id and s.org_id=o.id
  where u.id=p_actor and u.is_anonymous is true and m.org_id=p_org and m.role in('owner','admin','agent')
   and o.deleted_at is null and o.plan_source='apple' and a.environment='Production' and a.status='active'
   and a.app_account_token=p_actor and a.plan in('starter','pro','team') and public.effective_plan(p_org)=a.plan
   and o.apple_product_id=a.product_id and o.plan_expires_at=a.expires_at
   and a.transaction_purchased_at is not null and a.transaction_signed_at is not null
   and a.transaction_purchased_at<=now() and a.transaction_signed_at>=a.transaction_purchased_at
   and a.expires_at>now() and a.expires_at>a.transaction_purchased_at
   and f.source='retail' and f.revoked_at is null and f.collection_ref='apple:'||a.last_transaction_id
   and f.net_receipts_cents>0 and f.sponsored_cents=0 and f.sponsor_pool_id is null
   and f.starts_at=a.transaction_purchased_at and f.ends_at=a.expires_at
   and f.starts_at<=now() and f.ends_at>now() and s.starts_at<=now() and s.ends_at>now()
   and not exists(select 1 from public.deletion_requests d where d.user_id=p_actor and d.status in('pending','processing'))
 );
$$;
revoke all on function public.org_has_verified_retail_guest(uuid,uuid) from public,anon,authenticated;
grant execute on function public.org_has_verified_retail_guest(uuid,uuid) to service_role;

-- Persist a present, verified buyer token in the same chain-locked transaction
-- as its retail funding. Missing legacy tokens retain their old named-account
-- path, but cannot satisfy the guest reader. Refunds with missing tokens still
-- flow through the existing revoke path; this wrapper does not mint sponsorship.
create or replace function public.fund_verified_retail_apple_transaction(
 p_actor uuid,p_org uuid,p_original text,p_transaction text,p_product text,p_price_milliunits bigint,p_currency text,p_storefront text,
 p_offer_type integer,p_offer_discount_type text,p_purchased_at timestamptz,p_expires_at timestamptz,p_signed_at timestamptz,p_evidence_sha256 text
)returns jsonb language plpgsql security definer set search_path='' set timezone='UTC' as $$
declare a public.apple_subscriptions; buyer uuid; adoption public.anonymous_adoption_receipts; recovered jsonb;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_actor is null or p_price_milliunits is null or p_price_milliunits<=0
  or p_offer_discount_type='FREE_TRIAL' or p_signed_at is null or p_purchased_at is null
  or p_expires_at is null or p_evidence_sha256 is null or p_evidence_sha256 !~ '^[a-f0-9]{64}$'
 then raise exception 'RP400: Verified paid buyer facts are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_original,72451));
 select * into a from public.apple_subscriptions where original_transaction_id=p_original for update;
 if a.org_id is distinct from p_org or a.environment is distinct from 'Production'
  or a.last_transaction_id is distinct from p_transaction or a.product_id is distinct from p_product
  or a.transaction_purchased_at is distinct from p_purchased_at or a.transaction_signed_at is null
  or a.transaction_signed_at>p_signed_at or a.expires_at is distinct from p_expires_at
  or(a.app_account_token is not null and a.app_account_token<>p_actor)
 then return jsonb_build_object('funded',false,'reason','stale_or_unbound_buyer');end if;
 -- A verified refund must still revoke an admitted chain even after its buyer
 -- account was deleted. It can never mint a new grant through this path.
 if a.status in('revoked','refunded')then
  return public.fund_verified_apple_transaction(p_org,p_original,p_transaction,p_product,p_price_milliunits,p_currency,p_storefront,p_offer_type,p_offer_discount_type,p_purchased_at,p_expires_at,p_signed_at,p_evidence_sha256);
 end if;
 buyer:=a.user_id;
 if buyer is distinct from p_actor then
  -- Preserve the existing exact guest-to-named-account adoption contract. A
  -- shared membership alone, or an anonymous destination, is insufficient.
  if not exists(select 1 from auth.users where id=buyer and is_anonymous is false)then
   return jsonb_build_object('funded',false,'reason','stale_or_unbound_buyer');end if;
  select * into adoption from public.anonymous_adoption_receipts
   where source_user_id=p_actor and destination_user_id=buyer and org_id=p_org;
  if adoption.operation_id is null then return jsonb_build_object('funded',false,'reason','stale_or_unbound_buyer');end if;
  recovered:=public.adoption_receipt(buyer,p_actor,adoption.operation_id);
  if recovered->>'ok' is distinct from 'true' or recovered->>'adopted' is distinct from 'true'
   or recovered->>'source_user_id' is distinct from p_actor::text or recovered->>'destination_user_id' is distinct from buyer::text
   or recovered->>'org_id' is distinct from p_org::text or recovered->>'operation_id' is distinct from adoption.operation_id::text
  then return jsonb_build_object('funded',false,'reason','stale_or_unbound_buyer');end if;
 end if;
 if not exists(select 1 from public.orgs where id=p_org and deleted_at is null)
  or not exists(select 1 from auth.users where id=buyer)
  or not exists(select 1 from public.memberships where user_id=buyer and org_id=p_org and role in('owner','admin'))
  or exists(select 1 from public.deletion_requests where user_id=buyer and status in('pending','processing'))
 then return jsonb_build_object('funded',false,'reason','buyer_authority_unavailable');end if;
 update public.apple_subscriptions set app_account_token=p_actor where original_transaction_id=p_original;
 return public.fund_verified_apple_transaction(p_org,p_original,p_transaction,p_product,p_price_milliunits,p_currency,p_storefront,p_offer_type,p_offer_discount_type,p_purchased_at,p_expires_at,p_signed_at,p_evidence_sha256);
end$$;
revoke all on function public.fund_verified_retail_apple_transaction(uuid,uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text) from public,anon,authenticated;
grant execute on function public.fund_verified_retail_apple_transaction(uuid,uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text) to service_role;

-- Preserve every existing cash, replay, quota, trial and deletion guard. Only
-- the identity predicate gains the independently bounded retail exception.
do $patch$
declare signature text;definition text;body text;anchor text:=E'not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)';
 replacement text:=E'(not exists(select 1 from auth.users where id=p_actor and is_anonymous is false) and not public.org_has_verified_retail_guest(p_actor,p_org))';
begin
 foreach signature in array array[
  'public.serving_operation_begin(uuid,uuid,text,text,text)',
  'public.serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text)',
  'public.serving_operation_complete(uuid,uuid,text,jsonb)'
 ]loop
  select pg_get_functiondef(signature::regprocedure),prosrc into definition,body from pg_proc where oid=signature::regprocedure;
  if position(replacement in body)=0 then
   if (length(body)-length(replace(body,anchor,'')))/length(anchor)<>1 then raise exception 'Guest identity anchor changed for %',signature;end if;
   execute replace(definition,anchor,replacement);
  end if;
 end loop;
end$patch$;

-- Anonymous service presentation uses the same exact retail admission as
-- provider operations. A named account keeps every existing override rule.
do $activation$
declare definition text;body text;anchor text:=E' if public.org_has_internal_testing_grant(p_org)';addition text:=$guest$ if exists(select 1 from auth.users where id=p_actor and is_anonymous is true)then
  if public.org_has_verified_retail_guest(p_actor,p_org)then return jsonb_build_object('org_id',p_org,'available',true,'funded',true,'authority','verified_retail');end if;
  return jsonb_build_object('org_id',p_org,'available',false,'funded',false,'authority','subscription_activation_unavailable');
 end if;
$guest$;
begin
 select pg_get_functiondef(oid),prosrc into definition,body from pg_proc where oid='public.subscription_serving_activation(uuid,uuid)'::regprocedure;
 if position(addition in body)=0 then
  if(length(body)-length(replace(body,anchor,'')))/length(anchor)<>1 then raise exception 'Activation authority anchor changed';end if;
  execute replace(definition,anchor,addition||anchor);
 end if;
end$activation$;

-- A durable receipt is acknowledged only once application/funding completed.
-- An outage retains an unprocessed exact receipt, so duplicate delivery resumes
-- the idempotent chronology instead of treating a failed deletion as success.
alter table public.apple_notifications add column if not exists verified_payload_sha256 text;
alter table public.apple_notifications add column if not exists processed_at timestamptz;
alter table public.apple_notifications add column if not exists processing_outcome text;
do $$begin
 if not exists(select 1 from pg_constraint where conname='apple_notification_verified_payload_sha256' and conrelid='public.apple_notifications'::regclass)then
  alter table public.apple_notifications add constraint apple_notification_verified_payload_sha256 check(verified_payload_sha256 is null or verified_payload_sha256 ~ '^[a-f0-9]{64}$');
 end if;
 if not exists(select 1 from pg_constraint where conname='apple_notification_processing_outcome' and conrelid='public.apple_notifications'::regclass)then
  alter table public.apple_notifications add constraint apple_notification_processing_outcome check(processing_outcome is null or processing_outcome in('applied','refused','pending','ignored'));
 end if;
end$$;
commit;
