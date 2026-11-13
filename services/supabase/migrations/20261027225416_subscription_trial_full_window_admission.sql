-- The purchase hold promises seven days, so all three independent admission
-- windows must cover that entire term. Keep the check inside the existing
-- serialized trial-admission transaction, before the immutable cash hold.
-- The runtime sponsor lock also serializes this headroom read with AI cost
-- holds; it is deliberately taken after the workspace lock, matching the
-- serving writer's lock order.
begin;

do $patch$
declare definition text; anchor text; replacement text;
begin
  definition:=pg_get_functiondef('public.prepare_subscription_trial_purchase(uuid,uuid,text)'::regprocedure);

  anchor:='and starts_at<=now()and ends_at>now()';
  replacement:='and starts_at<=now()and ends_at>=now()+interval ''168 hours''';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed seven-day trial admission predecessor';
  end if;
  definition:=replace(definition,anchor,replacement);

  anchor:='p.ends_at<=now()then raise exception ''RP402: Trial sponsor admission is unavailable''';
  replacement:='p.ends_at<now()+interval ''168 hours'' then raise exception ''RP402: Trial sponsor admission is unavailable''';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed seven-day trial admission predecessor';
  end if;
  definition:=replace(definition,anchor,replacement);

  anchor:=' perform 1 from public.orgs where id=p_org and deleted_at is null for update;';
  replacement:=$body$
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if public.serving_mode()='ceiling' then
  perform pg_advisory_xact_lock(hashtextextended('serving:trial-sponsor',72452));
  -- Production intro usage draws this operational cap as well as the
  -- immutable purchase sponsor commitment. A few remaining cents cannot
  -- support the advertised seven-day package.
  if not exists(
    select 1 from (select public.trial_sponsor_pool() as pool) runtime
    where now()>=(runtime.pool->>'starts_at')::timestamptz
      and (runtime.pool->>'ends_at')::timestamptz>=now()+interval '168 hours'
      and (runtime.pool->>'cap_cents')::numeric-public.trial_sponsor_spent_cents()>=s.trial_sponsored_cents
  ) then raise exception 'RP402: Seven-day trial serving capacity is unavailable';end if;
 end if;$body$;
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed seven-day trial admission predecessor';
  end if;
  execute replace(definition,anchor,replacement);
end $patch$;

commit;
