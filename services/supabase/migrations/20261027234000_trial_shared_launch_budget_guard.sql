-- The owner allocated $1,000 of existing cash: at most $500 in immutable
-- seven-day sponsor holds and at most $500 for media, legacy trial-kind
-- runtime authority, and QA. Keep this dormant; no pool or grant is changed.
begin;

-- Count the whole future legacy ceiling conservatively. A settled historical
-- cost is sunk, whereas an overlapping open runtime cap is future authority.
-- This check is made again under the purchase admission lock before StoreKit.
do $patch$ declare d text;a text;b text;
begin
 d:=pg_get_functiondef('public.subscription_trial_media_template_ready(uuid)'::regprocedure);
 a:='tariff jsonb; r jsonb;delivery numeric;compute numeric;storage numeric;';
 b:='tariff jsonb; r jsonb;delivery numeric;compute numeric;storage numeric;runtime jsonb;legacy_future numeric:=0;';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then
  raise exception 'Review changed trial media shared-budget declaration';end if;
 d:=replace(d,a,b);
 a:=' tariff:=a.tariff;r:=s.trial_reserve_components;';
 b:=$body$
 -- A malformed runtime envelope cannot certify a cash allocation.
 runtime:=public.trial_sponsor_pool();
 if runtime is null or coalesce(runtime->>'cap_cents','')!~'^[0-9]{1,10}$'
  or runtime->>'starts_at' is null or runtime->>'ends_at' is null then
  return false;end if;
 if (runtime->>'ends_at')::timestamptz>now()
  and (runtime->>'starts_at')::timestamptz<p.ends_at then
  legacy_future:=(runtime->>'cap_cents')::numeric;end if;
 if a.cash_paid_cents+legacy_future>50000 then return false;end if;
 tariff:=a.tariff;r:=s.trial_reserve_components;$body$;
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then
  raise exception 'Review changed trial media shared-budget gate';end if;
 execute replace(d,a,b);
end $patch$;

-- An active unlimited internal QA grant, private sponsorship, or unresolved
-- unlimited provider hold has no finite future cash bound. Preserve all
-- existing QA access, but make public activation readiness fail closed until
-- the operator deliberately retires or funds that authority.
create function public.subscription_trial_private_authority_clear()
returns boolean language sql stable security definer set search_path='' as $$
 select not exists(select 1 from public.org_internal_testing_grants g
   where g.unmetered_business_allowances and g.revoked_at is null
    and g.starts_at<=now() and (g.expires_at is null or g.expires_at>now()))
  and not exists(select 1 from public.private_internal_testing_sponsorships s
   where s.revoked_at is null and s.starts_at<=now()
    and (s.expires_at is null or s.expires_at>now()))
  and not exists(select 1 from public.serving_cost_reservations r
   where r.sponsored_unlimited and r.state in('reserved','uncertain'));
$$;
revoke all on function public.subscription_trial_private_authority_clear() from public,anon,authenticated;
grant execute on function public.subscription_trial_private_authority_clear() to service_role;

do $patch$ declare d text;a text;b text;
begin
 d:=pg_get_functiondef('public.subscription_trial_activation_readiness()'::regprocedure);
 a:='''local_prerequisites_met'',bounded and cardinality(missing)=0';
 b:='''private_launch_authority_clear'',public.subscription_trial_private_authority_clear(),'||chr(10)||
  '    ''local_prerequisites_met'',bounded and cardinality(missing)=0 and public.subscription_trial_private_authority_clear()';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then
  raise exception 'Review changed trial shared-budget readiness predecessor';end if;
 execute replace(d,a,b);
end $patch$;

commit;
