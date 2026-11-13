-- CONTRACT PHASE: apply only after me and apple-subscriptions use v2 and
-- serving old-handler requests have drained. The earlier expand migration keeps
-- their eleven-argument writer unchanged so refunds are not acknowledged as
-- deterministic RP409 refusals during the handler deployment window.
-- Final boundary: old internal calls cannot roll back any existing snapshot;
-- old native HTTP bodies remain supported by the updated verified handlers.

create or replace function public.apply_apple_entitlement(
  p_org uuid,p_user uuid,p_original_transaction_id text,p_transaction_id text,
  p_product_id text,p_plan text,p_environment text,p_status text,
  p_expires_at timestamptz,p_auto_renew boolean,p_notification_type text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.apple_subscriptions;
begin
  if p_original_transaction_id is null or btrim(p_original_transaction_id)='' then
    raise exception 'RP400: original_transaction_id is required';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_original_transaction_id,72451));
  select * into s from public.apple_subscriptions where original_transaction_id=p_original_transaction_id for update;
  if found then
    if p_org is not null and s.org_id is not null and p_org<>s.org_id then
      raise exception 'RP409: This subscription is already used by another account';
    end if;
    -- Every existing snapshot needs signed chronology. Updated handlers obtain
    -- it from Apple's verified JWS even when an older native client restores.
    raise exception 'RP409: Subscription synchronization requires verified signed chronology';
  end if;
  return public._apply_apple_entitlement_snapshot(p_org,p_user,p_original_transaction_id,p_transaction_id,
    p_product_id,p_plan,p_environment,p_status,p_expires_at,p_auto_renew,p_notification_type);
end $$;

revoke execute on function public.apply_apple_entitlement(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text) from public,anon,authenticated;
grant execute on function public.apply_apple_entitlement(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text) to service_role;
