begin;
-- Quotes, negotiated floors and contract pricing inputs are not public APIs.
-- Revoke PUBLIC too: revoking only anon/authenticated leaves inherited access.
-- Keep the exact function bodies, owners, modes, prices and contract writers.
-- org_entitlement calls the invoker contract/COGS helpers from existing
-- service or definer callers. Do not turn the helpers into SECURITY DEFINER.
revoke execute on function public.brokerage_price_cents(integer),
 public.brokerage_price_floor_cents(),
 public.brokerage_cogs_ceiling_cents(public.brokerage_contracts),
 public.brokerage_contract(uuid),
 public.brokerage_quote(integer,integer,integer,integer,integer)
 from public,anon,authenticated;
grant execute on function public.brokerage_price_cents(integer),
 public.brokerage_price_floor_cents(),
 public.brokerage_cogs_ceiling_cents(public.brokerage_contracts),
 public.brokerage_contract(uuid),
 public.brokerage_quote(integer,integer,integer,integer,integer)
 to service_role;
commit;
