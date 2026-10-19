begin;
-- Acquisition is dormant by default. An admitted cash commitment never expires
-- or recycles on a client cancellation, timeout, deleted account or late receipt.
alter table public.serving_sponsor_pools add column if not exists admissions_enabled boolean not null default false;
create table if not exists public.subscription_trial_purchase_reservations (
 id uuid primary key default gen_random_uuid(),actor_id uuid not null unique,identity_sha256 text not null unique check(identity_sha256 ~ '^[a-f0-9]{64}$'),org_id uuid not null unique,
 product_id text not null, pool_id uuid not null references public.serving_sponsor_pools(id), schedule_id uuid not null references public.apple_serving_schedules(id),
 sponsored_cents bigint not null check(sponsored_cents between 1 and 500),reserve_components jsonb not null,
 schedule_evidence_sha256 text not null check(schedule_evidence_sha256 ~ '^[a-f0-9]{64}$'),pool_evidence_sha256 text not null check(pool_evidence_sha256 ~ '^[a-f0-9]{64}$'),
 walkthrough_cap integer not null check(walkthrough_cap=1),photo_cap integer not null check(photo_cap=5),listing_cap integer not null check(listing_cap=1),max_days integer not null check(max_days between 1 and 7),
 max_video_seconds integer not null check(max_video_seconds between 1 and 90),upload_budget_bytes bigint not null check(upload_budget_bytes between 1 and 1073741824),
 held_at timestamptz not null default now(),funding_id uuid unique references public.serving_funding(id),original_transaction_id text unique,converted_at timestamptz,
 check(public.serving_reserve_total(reserve_components)is not null and public.serving_reserve_total(reserve_components)<sponsored_cents),
 check((funding_id is null and original_transaction_id is null and converted_at is null)or(funding_id is not null and original_transaction_id is not null and converted_at is not null))
);
alter table public.subscription_trial_purchase_reservations enable row level security;
revoke all on public.subscription_trial_purchase_reservations from public,anon,authenticated,service_role;
grant select on public.subscription_trial_purchase_reservations to service_role;

create or replace function public.subscription_trial_held_offer(p_actor uuid,p_org uuid)returns jsonb
language plpgsql stable security definer set search_path='' as $$declare h public.subscription_trial_purchase_reservations;begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if not exists(select 1 from public.memberships m join public.orgs o on o.id=m.org_id and o.deleted_at is null where m.user_id=p_actor and m.org_id=p_org)then raise exception 'RP403: Current trial workspace access is required';end if;
 if not exists(select 1 from auth.users where id=p_actor and is_anonymous is false and email_confirmed_at is not null)
  or not exists(select 1 from public.memberships where user_id=p_actor and org_id=p_org and role='owner')
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then return null;end if;
 select * into h from public.subscription_trial_purchase_reservations where actor_id=p_actor and org_id=p_org and funding_id is null;
 if h.id is null then return null;end if;
 return jsonb_build_object('reservation_id',h.id,'actor_id',h.actor_id,'app_account_token',h.actor_id,'org_id',h.org_id,'product_id',h.product_id,'held_at',h.held_at,
  'trial_offer',jsonb_build_object('enabled',true,'walkthroughs',h.walkthrough_cap,'photo_edits',h.photo_cap,'published_listings',h.listing_cap,'max_days',h.max_days,'max_video_seconds',h.max_video_seconds,'upload_budget_bytes',h.upload_budget_bytes));
end$$;

create or replace function public.prepare_subscription_trial_purchase(p_actor uuid,p_org uuid,p_product text)returns jsonb
language plpgsql security definer set search_path='' as $$
declare h public.subscription_trial_purchase_reservations;c public.subscription_trial_config;s public.apple_serving_schedules;p public.serving_sponsor_pools;identity_hash text;committed bigint;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 -- A small, deterministic trial-admission lock precedes ALL chain/pool/org/
 -- identity locks in prepare/conversion/legacy zero-price funding. No HTTP or
 -- provider work occurs while it is held.
 perform pg_advisory_xact_lock(hashtextextended('subscription-trial-admission',72456));
 if p_actor is null or p_org is null or p_product is null or p_product not in('com.rendprop.app.starter.monthly','com.rendprop.app.starter.annual','com.rendprop.app.pro.monthly','com.rendprop.app.pro.annual','com.rendprop.app.team.monthly')then raise exception 'RP400: A supported trial subscription product is required';end if;
 if not exists(select 1 from public.memberships m join public.orgs o on o.id=m.org_id and o.deleted_at is null where m.user_id=p_actor and m.org_id=p_org and m.role='owner')
  or not exists(select 1 from auth.users where id=p_actor and is_anonymous is false and email_confirmed_at is not null)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception 'RP403: A current confirmed buying owner is required';end if;
 select encode(sha256(convert_to(lower(btrim(email)),'UTF8')),'hex')into identity_hash from auth.users where id=p_actor and email_confirmed_at is not null and length(btrim(email))>0;
 if identity_hash is null then raise exception 'RP403: A confirmed buying account is required';end if;
 select * into h from public.subscription_trial_purchase_reservations where actor_id=p_actor or identity_sha256=identity_hash or org_id=p_org;
 if h.id is not null then
  if row(h.actor_id,h.org_id,h.product_id)is distinct from row(p_actor,p_org,p_product)or h.funding_id is not null then raise exception 'RP409: This lifetime trial is already committed to its original account, workspace and product';end if;
  return public.subscription_trial_held_offer(p_actor,p_org);
 end if;
 if exists(select 1 from public.subscription_trial_grants where actor_id=p_actor or identity_sha256=identity_hash or org_id=p_org)
  or exists(select 1 from public.serving_funding where source='trial'and(actor_id=p_actor or org_id=p_org))
  or exists(select 1 from public.apple_subscriptions where org_id=p_org and environment='Production'and status in('active','grace'))
  or public.subscription_trial_paid_or_override(p_org)then raise exception 'RP409: This account or workspace already has subscription service';end if;
 select * into c from public.subscription_trial_config where singleton;
 if not c.enabled then raise exception 'RP402: The funded subscription trial is not activated';end if;
 select * into s from public.apple_serving_schedules where product_id=p_product and storefront='USA'and currency='USD'and starts_at<=now()and ends_at>now()
  and trial_sponsored_cents>0 and trial_days=7 and c.max_days=7 order by starts_at desc limit 1;
 if s.id is null or public.serving_reserve_total(s.trial_reserve_components)>=s.trial_sponsored_cents then raise exception 'RP402: An inclusive funded trial schedule is required';end if;
 select * into p from public.serving_sponsor_pools where id=s.trial_pool_id for update;
 if p.id is null or not p.admissions_enabled or p.starts_at>now()or p.ends_at<=now()then raise exception 'RP402: Trial sponsor admission is unavailable';end if;
 select coalesce(sum(sponsored_cents),0)into committed from public.serving_funding where sponsor_pool_id=p.id;
 committed:=committed+(select coalesce(sum(sponsored_cents),0)from public.subscription_trial_purchase_reservations where pool_id=p.id and funding_id is null);
 if committed+s.trial_sponsored_cents>p.funded_cents then raise exception 'RP402: The trial sponsor commitment is exhausted';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 -- Lock/recheck current buying authority after acquiring the org lock. A GET
 -- returning null is not authority to consume cash.
 perform 1 from auth.users where id=p_actor for share;
 perform 1 from public.memberships where user_id=p_actor and org_id=p_org for share;
 if not exists(select 1 from public.orgs where id=p_org and deleted_at is null)
  or not exists(select 1 from public.memberships where user_id=p_actor and org_id=p_org and role='owner')
  or not exists(select 1 from auth.users where id=p_actor and is_anonymous is false and email_confirmed_at is not null and encode(sha256(convert_to(lower(btrim(email)),'UTF8')),'hex')=identity_hash)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception 'RP403: The confirmed buying owner changed before cash commitment';end if;
 insert into public.subscription_trial_purchase_reservations(actor_id,identity_sha256,org_id,product_id,pool_id,schedule_id,sponsored_cents,reserve_components,schedule_evidence_sha256,pool_evidence_sha256,walkthrough_cap,photo_cap,listing_cap,max_days,max_video_seconds,upload_budget_bytes)
 values(p_actor,identity_hash,p_org,p_product,p.id,s.id,s.trial_sponsored_cents,s.trial_reserve_components,s.evidence_sha256,p.evidence_sha256,c.walkthroughs,c.photo_edits,c.published_listings,s.trial_days,c.max_video_seconds,c.upload_budget_bytes);
 return public.subscription_trial_held_offer(p_actor,p_org);
end$$;

-- Signed notifications can resolve an exact already-admitted actor/SKU before
-- a device sends its first receipt. This returns no loose workspace membership.
create or replace function public.subscription_trial_reserved_workspace(p_actor uuid,p_product text)returns uuid
language plpgsql stable security definer set search_path='' as $$declare o uuid;begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 select h.org_id into o from public.subscription_trial_purchase_reservations h where h.actor_id=p_actor and h.product_id=p_product
  and exists(select 1 from public.orgs where id=h.org_id and deleted_at is null)
  and exists(select 1 from auth.users where id=p_actor and is_anonymous is false)
  and exists(select 1 from public.memberships where org_id=h.org_id and user_id=p_actor and role='owner')
  and not exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'));
 return o;
end$$;

create or replace function public.fund_reserved_subscription_trial(p_actor uuid,p_org uuid,p_original text,p_transaction text,p_product text,p_price_milliunits bigint,p_currency text,p_storefront text,p_offer_type integer,p_offer_discount_type text,p_purchased_at timestamptz,p_expires_at timestamptz,p_signed_at timestamptz,p_evidence_sha256 text)
returns jsonb language plpgsql security definer set search_path='' set timezone='UTC' as $$
declare h public.subscription_trial_purchase_reservations;s public.apple_subscriptions;f public.serving_funding;r jsonb;g uuid;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 perform pg_advisory_xact_lock(hashtextextended('subscription-trial-admission',72456));
 if p_original is null or p_transaction is null or p_signed_at is null or p_purchased_at is null or p_expires_at is null or p_evidence_sha256 is null or p_evidence_sha256 !~ '^[a-f0-9]{64}$'then raise exception 'RP400: Verified trial receipt facts are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_original,72451));
 select * into s from public.apple_subscriptions where original_transaction_id=p_original for update;
 if s.org_id is distinct from p_org or s.environment is distinct from 'Production'or s.last_transaction_id is distinct from p_transaction
  or s.product_id is distinct from p_product or s.transaction_purchased_at is distinct from p_purchased_at or s.transaction_signed_at>p_signed_at or s.expires_at is distinct from p_expires_at then return jsonb_build_object('funded',false,'reason','stale_or_unbound');end if;
 select * into f from public.serving_funding where collection_ref='apple-trial:'||p_original and org_id=p_org;
 -- Accepted signed chain/org revocations must revoke historical funding even
 -- when Apple omits the appAccountToken. They never acquire a new grant.
 if s.status in('refunded','revoked')then
  return public.fund_verified_apple_transaction(p_org,p_original,p_transaction,p_product,p_price_milliunits,p_currency,p_storefront,p_offer_type,p_offer_discount_type,p_purchased_at,p_expires_at,p_signed_at,p_evidence_sha256);
 end if;
 if f.id is not null then
  if f.id is not null and f.actor_id is distinct from p_actor and(p_actor is not null or exists(select 1 from public.subscription_trial_purchase_reservations where funding_id=f.id))then return jsonb_build_object('funded',false,'reason','trial_actor_mismatch');end if;
  return public.fund_verified_apple_transaction(p_org,p_original,p_transaction,p_product,p_price_milliunits,p_currency,p_storefront,p_offer_type,p_offer_discount_type,p_purchased_at,p_expires_at,p_signed_at,p_evidence_sha256);
 end if;
 if p_actor is null or p_price_milliunits is distinct from 0 or p_offer_type is distinct from 1 or p_offer_discount_type is distinct from 'FREE_TRIAL'or p_currency is distinct from 'USD'or p_storefront is distinct from 'USA'
  or s.status not in('active','expired')then return jsonb_build_object('funded',false,'reason','unreserved_trial_classification');end if;
 select * into h from public.subscription_trial_purchase_reservations where actor_id=p_actor and org_id=p_org and product_id=p_product for update;
 if h.id is null then return jsonb_build_object('funded',false,'reason','trial_purchase_not_reserved');end if;
 if h.funding_id is not null then return jsonb_build_object('funded',false,'reason','trial_chain_mismatch');end if;
 if p_purchased_at<h.held_at or p_expires_at<=p_purchased_at or p_expires_at>p_purchased_at+make_interval(days=>h.max_days)then return jsonb_build_object('funded',false,'reason','trial_receipt_period_mismatch');end if;
 -- NO latest config, schedule or pool expiry check: this cash was committed
 -- before StoreKit. There is intentionally no purchase-window upper cutoff.
 perform 1 from public.serving_sponsor_pools where id=h.pool_id for update;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
 update public.serving_funding set revoked_at=now(),revocation_kind='apple_replaced',revocation_evidence_sha256=p_evidence_sha256 where org_id=p_org and apple_original_transaction_id=p_original and revoked_at is null and ends_at>p_purchased_at;
 r:=public.provision_serving_funding(p_org,'trial','apple-trial:'||p_original,p_actor,0,h.sponsored_cents,p_purchased_at,p_expires_at,1,h.reserve_components,h.schedule_evidence_sha256);
 update public.serving_funding set apple_original_transaction_id=p_original,sponsor_pool_id=h.pool_id where id=(r->>'funding_id')::uuid;
 insert into public.subscription_trial_grants(actor_id,identity_sha256,org_id,original_transaction_id,funding_id,starts_at,ends_at,walkthrough_cap,photo_cap,listing_cap,upload_budget_bytes,max_video_seconds,evidence_sha256)
 values(h.actor_id,h.identity_sha256,h.org_id,p_original,(r->>'funding_id')::uuid,p_purchased_at,p_expires_at,h.walkthrough_cap,h.photo_cap,h.listing_cap,h.upload_budget_bytes,h.max_video_seconds,p_evidence_sha256)returning id into g;
 update public.subscription_trial_purchase_reservations set funding_id=(r->>'funding_id')::uuid,original_transaction_id=p_original,converted_at=now()where id=h.id;
 return r||jsonb_build_object('funded',true,'reservation_id',h.id,'trial_grant_id',g,'schedule_id',h.schedule_id);
end$$;

-- Legacy calls can restore/refund previously accepted funding, but may not
-- bypass pre-purchase cash commitment or pick another owner for a new trial.
do $patch$declare d text;b text;a text;begin
 select pg_get_functiondef(oid),prosrc into d,b from pg_proc where oid='public.fund_verified_apple_transaction(uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text)'::regprocedure;
 if position('trial_purchase_reservation_required'in b)=0 then
  a:=' -- Entitlement chronology already accepted this exact verified receipt.';
  if(length(b)-length(replace(b,a,'')))/length(a)<>1 then raise exception 'Unknown funding lock body';end if;
  d:=replace(d,a,E' if p_price_milliunits=0 then perform pg_advisory_xact_lock(hashtextextended(''subscription-trial-admission'',72456));end if;\n'||a);
  a:=' if p_price_milliunits=0 and not(select enabled from public.subscription_trial_config where singleton)';
  if(length(b)-length(replace(b,a,'')))/length(a)<>1 then raise exception 'Unknown bounded funding admission body';end if;
  execute replace(d,a,E' if p_price_milliunits=0 then return jsonb_build_object(''funded'',false,''reason'',''trial_purchase_reservation_required'');end if;\n'||a);
 end if;
end$patch$;
revoke all on function public.subscription_trial_held_offer(uuid,uuid),public.prepare_subscription_trial_purchase(uuid,uuid,text),public.subscription_trial_reserved_workspace(uuid,text),public.fund_reserved_subscription_trial(uuid,uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text)from public,anon,authenticated;
grant execute on function public.subscription_trial_held_offer(uuid,uuid),public.prepare_subscription_trial_purchase(uuid,uuid,text),public.subscription_trial_reserved_workspace(uuid,text),public.fund_reserved_subscription_trial(uuid,uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text)to service_role;
commit;
