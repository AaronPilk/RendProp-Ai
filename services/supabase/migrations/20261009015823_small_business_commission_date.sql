-- Apple Small Business Program: the reduced commission applies from a known
-- instant, not from whenever someone remembers to edit config.
--
-- Enrollment approved 2026-09-25 (owner). That date falls in Apple fiscal
-- September 2026 (Aug 30 – Sep 26); reduced proceeds begin 15 days after the
-- end of that fiscal month = 2026-10-11. Midnight Pacific is used so no sale
-- before Apple's switch is budgeted at the lower rate.
--
-- serving_envelope_int('apple_commission_bps', d) returns reduced_commission_bps
-- once now() >= reduced_commission_from; before that, or if either key is
-- missing/malformed, it returns apple_commission_bps (30%) — the smaller
-- envelope. Replay-safe: create-or-replace plus an idempotent config merge.
begin;

create or replace function public.serving_envelope_int(p_key text,p_default integer)returns integer
language sql stable security definer set search_path='' as $$
 select coalesce((
  select case
   when p_key='apple_commission_bps'
    and jsonb_typeof(value->'reduced_commission_bps')='number'
    and (value->>'reduced_commission_bps')::numeric between 0 and 10000
    and jsonb_typeof(value->'reduced_commission_from')='string'
    and (value->>'reduced_commission_from')~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$'
    and now()>=(value->>'reduced_commission_from')::timestamptz
   then (value->>'reduced_commission_bps')::integer
   when jsonb_typeof(value->p_key)='number' and (value->>p_key)::numeric between 0 and 100000000
   then (value->>p_key)::integer end
  from public.app_config where key='serving_envelope'),p_default);
$$;
revoke all on function public.serving_envelope_int(text,integer)from public,anon,authenticated;
grant execute on function public.serving_envelope_int(text,integer)to service_role,postgres;

update public.app_config set value=value||jsonb_build_object(
 'apple_commission_bps',3000,
 'reduced_commission_bps',1500,
 'reduced_commission_from','2026-10-11T07:00:00Z',
 'note','Monthly AI envelope = net-of-Apple receipts x (1 - net_margin) - hosting reserve, per paid service window. Apple Small Business Program approved 2026-09-25 (fiscal September ends 2026-09-26); reduced 15% commission applies from 2026-10-11 (reduced_commission_from, midnight Pacific). Before that, or if the reduced keys are malformed, apple_commission_bps (30%) is used. Plans are monthly only. Trial money comes from app_config.trial_sponsor_pool.'),
 updated_at=now() where key='serving_envelope';

commit;
