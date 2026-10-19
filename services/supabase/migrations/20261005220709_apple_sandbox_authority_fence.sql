begin;
-- SOURCE-ONLY rollout dependency: deploy coordinated native/Edge copy and
-- explicitly provision test authority before enabling this fence. TestFlight
-- and App Review purchases are Sandbox, not retail billing authority.
-- Fixed <=7-day review caps still require grant-lifetime accounting; no
-- automatic reviewer authority or cap derived from a Sandbox product exists.
create table if not exists public.apple_sandbox_receipts(
 original_transaction_id text primary key check(length(original_transaction_id)between 1 and 200),
 org_id uuid not null,actor_id uuid not null, -- accounting tombstones survive deletion
 transaction_id text not null,product_id text not null,status text not null,
 signed_at timestamptz not null,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
alter table public.apple_sandbox_receipts enable row level security;
revoke all on public.apple_sandbox_receipts from public,anon,authenticated,service_role;
grant select on public.apple_sandbox_receipts to service_role;
create or replace function public.record_apple_sandbox_receipt(p_org uuid,p_actor uuid,p_original text,p_transaction text,p_product text,p_status text,p_signed_at timestamptz)
returns jsonb language plpgsql security definer set search_path=''as $$
declare prior public.apple_sandbox_receipts;actor uuid;org uuid;e public.plan_entitlements;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_original is null or length(p_original)not between 1 and 200 or p_transaction is null or length(p_transaction)not between 1 and 200
  or p_product is null or length(p_product)not between 1 and 200 or p_status is null or p_status not in('active','grace','expired','refunded','revoked')or p_signed_at is null or not pg_catalog.isfinite(p_signed_at)or p_signed_at>now()+interval '5 minutes'then raise exception 'RP400: Verified Sandbox receipt is required';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('apple_sandbox:'||p_original,72451));
 select * into prior from public.apple_sandbox_receipts where original_transaction_id=p_original for update;
 org:=coalesce(p_org,prior.org_id);actor:=coalesce(p_actor,prior.actor_id);
 if prior.org_id is not null and(org is distinct from prior.org_id or actor is distinct from prior.actor_id)then raise exception 'RP409: This test purchase belongs to another account or workspace';end if;
 if org is null or actor is null then raise exception 'RP403: Sandbox testing requires explicit authorized test access';end if;
 perform 1 from public.profiles where id=actor for update;
 if not found or not exists(select 1 from auth.users where id=actor and is_anonymous is false)or exists(select 1 from public.deletion_requests where user_id=actor and status in('pending','processing'))then raise exception 'RP403: Sandbox testing requires a current named test account';end if;
 perform 1 from public.orgs where id=org and deleted_at is null for update;
 if not found or not exists(select 1 from public.memberships where org_id=org and user_id=actor and role in('owner','admin'))then raise exception 'RP403: Sandbox testing requires the authorized test workspace owner';end if;
 if not(public.org_has_internal_testing_grant(org)or public.org_has_private_internal_testing(org))then raise exception 'RP403: Sandbox testing requires explicit authorized test access';end if;
 e:=public.org_entitlement(org);
 if prior.signed_at is null or p_signed_at>prior.signed_at then
  insert into public.apple_sandbox_receipts(original_transaction_id,org_id,actor_id,transaction_id,product_id,status,signed_at)
  values(p_original,org,actor,p_transaction,p_product,p_status,p_signed_at)
  on conflict(original_transaction_id)do update set transaction_id=excluded.transaction_id,product_id=excluded.product_id,status=excluded.status,signed_at=excluded.signed_at,updated_at=now();
 end if;
 -- Test receipt never touches org plan/source/expiry, Apple retail binding,
 -- cancellation or contract. Access belongs only to the service-owned grant.
 return jsonb_build_object('ok',true,'test_only',true,'environment','Sandbox','plan',e.plan,'source','manual','org_id',org,'original_transaction_id',p_original,'product_id',p_product,'expires_at',null);
end$$;
revoke all on function public.record_apple_sandbox_receipt(uuid,uuid,text,text,text,text,timestamptz)from public,anon,authenticated;
grant execute on function public.record_apple_sandbox_receipt(uuid,uuid,text,text,text,text,timestamptz)to service_role;

-- Preserve the exact reviewed chronology/cutover body and security metadata.
do $patch$declare old text;definition text;sig regprocedure:='public.apply_apple_entitlement_v2(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text,timestamptz,timestamptz,timestamptz,timestamptz)'::regprocedure;
begin
 select prosrc into old from pg_catalog.pg_proc where oid=sig;
 if md5(old)='54b6b1d581e2756c939c66e14fcd3b84'then return;end if;
 if md5(old)<>'d2524ed2e36f8b5a6d56cdaaf7ff806b'then raise exception 'Unknown apply_apple_entitlement_v2 body; Sandbox fence refused';end if;
 definition:=pg_catalog.pg_get_functiondef(sig);
 definition:=replace(definition,$needle$  signed_at:=greatest(p_transaction_signed_at,p_event_signed_at);$needle$,$replacement$  if p_environment='Sandbox'then return public.record_apple_sandbox_receipt(p_org,p_user,p_original_transaction_id,p_transaction_id,p_product_id,p_status,greatest(p_transaction_signed_at,p_event_signed_at));end if;
  if p_environment is distinct from 'Production'then raise exception 'RP400: Verified Apple environment is required';end if;
  signed_at:=greatest(p_transaction_signed_at,p_event_signed_at);$replacement$);
 execute definition;
end$patch$;

-- Preserve the exact reviewed chronology/cutover body and security metadata.
do $patch$declare old text;definition text;sig regprocedure:='public.apply_apple_entitlement(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text)'::regprocedure;
begin
 select prosrc into old from pg_catalog.pg_proc where oid=sig;
 if md5(old)='dc19c04bce703d8d63062538fbd42f0d'then return;end if;
 if md5(old)<>'03edd959aa47da2b4d4502b4fe8c204e'then raise exception 'Unknown apply_apple_entitlement body; Sandbox fence refused';end if;
 definition:=pg_catalog.pg_get_functiondef(sig);
 definition:=replace(definition,$needle$  if p_original_transaction_id is null$needle$,$replacement$  if p_environment='Sandbox'then raise exception 'RP403: Sandbox testing requires authorized verified test synchronization';end if;
  if p_environment is distinct from 'Production'then raise exception 'RP400: Verified Apple environment is required';end if;
  if p_original_transaction_id is null$replacement$);
 execute definition;
end$patch$;
commit;
