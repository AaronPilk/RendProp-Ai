begin;
-- Quotes and negotiated floors are internal sales inputs, not public APIs.
-- Revoke PUBLIC too: revoking only anon/authenticated leaves inherited access.
-- Keep the exact function bodies, owners, modes, prices and contract writers.
revoke execute on function public.brokerage_price_cents(integer),
 public.brokerage_price_floor_cents(),
 public.brokerage_quote(integer,integer,integer,integer,integer)
 from public,anon,authenticated;
grant execute on function public.brokerage_price_cents(integer),
 public.brokerage_price_floor_cents(),
 public.brokerage_quote(integer,integer,integer,integer,integer)
 to service_role;
commit;
