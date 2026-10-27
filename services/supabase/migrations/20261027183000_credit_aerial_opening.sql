-- Dormant 1080p aerial-opening credit path. Never activates an Apple catalog,
-- monthly grant, or live quote. A production operation needs a separate
-- explicit tariff activation after the full receipt/settlement audit.
begin;
insert into public.credit_tariffs(operation,version,credits,active)
values('aerial.opening','aerial-opening-v1',20,false)
on conflict(operation,version) do nothing;

alter table public.app_video_cost_reservations
  -- This accounting tombstone intentionally survives hard account deletion.
  -- Keep the immutable funding UUID without an FK, as with cost_ledger_id.
  add column credit_hold_id uuid,
  add column credit_environment text;
alter table public.app_video_cost_reservations
  add constraint app_video_credit_binding_check check(
    (credit_hold_id is null and credit_environment is null) or
    (credit_hold_id is not null and credit_environment in('Production','Sandbox')));
create unique index app_video_credit_hold_once
  on public.app_video_cost_reservations(credit_hold_id) where credit_hold_id is not null;

create table public.credit_aerial_openings(
  job_id uuid primary key references public.property_video_aerial_openings(id) on delete cascade,
  hold_id uuid not null unique references public.credit_holds(id),
  environment text not null check(environment in('Production','Sandbox')),
  tariff_version text not null check(tariff_version='aerial-opening-v1'),
  created_at timestamptz not null default now());
alter table public.credit_aerial_openings enable row level security;
revoke all on public.credit_aerial_openings from public,anon,authenticated,service_role;
grant select on public.credit_aerial_openings to service_role;

-- A service role may settle a receipt, never retarget its funding identity.
do $patch$ declare definition text; anchor text; replacement text; begin
  definition:=pg_get_functiondef('public.app_video_cost_pin_receipt()'::regprocedure);
  anchor:='new.hold_cents,new.meta,new.created_at)';
  replacement:='new.hold_cents,new.meta,new.created_at,new.credit_hold_id,new.credit_environment)';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed immutable video reservation before credit binding';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='old.hold_cents,old.meta,old.created_at)';
  replacement:='old.hold_cents,old.meta,old.created_at,old.credit_hold_id,old.credit_environment)';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed immutable video reservation before credit binding';end if;
  execute replace(definition,anchor,replacement);
end $patch$;

-- Freeze the exact source, quote, consent, customer hold and all supplier
-- liabilities in ONE admission transaction. This RPC is never called by
-- an old binary and is unreachable while the tariff stays inactive.
do $patch$ declare definition text; anchor text; replacement text; begin
  definition:=pg_get_functiondef('public.property_video_aerial_admit(uuid,jsonb,jsonb,jsonb)'::regprocedure);
  anchor:='property_video_aerial_admit(p_actor uuid, p_manifest jsonb, p_quote jsonb, p_consent jsonb)';
  replacement:='property_video_aerial_admit_credit(p_actor uuid, p_manifest jsonb, p_quote jsonb, p_consent jsonb, p_environment text, p_tariff_version text)';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial admission signature';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='mr jsonb;br jsonb;begin';
  replacement:='mr jsonb;br jsonb;credit jsonb;fund public.credit_holds;wallet jsonb;daily numeric;model_name text;begin';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial admission declaration';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='if j.id is not null then if j.manifest is distinct from p_manifest or j.consent is distinct from p_consent then raise exception''RP409: This aerial operation has different saved inputs or permission'';end if;return public.property_video_aerial_scope(j.id,p_actor);end if;';
  replacement:=E'if j.id is not null then\n  if j.manifest is distinct from p_manifest or j.quote is distinct from p_quote or j.consent is distinct from p_consent then raise exception ''RP409: This aerial credit operation has different saved inputs, quote or permission'';end if;\n  select to_jsonb(ca) into credit from public.credit_aerial_openings ca where ca.job_id=j.id;\n  if credit is null or credit->>''environment'' is distinct from p_environment or credit->>''tariff_version'' is distinct from p_tariff_version then raise exception ''RP409: This aerial operation has a different funding source'';end if;\n  return public.property_video_aerial_scope(j.id,p_actor);end if;';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial replay authority';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='perform pg_advisory_xact_lock(hashtextextended(''serving:''||billing,72452));perform pg_advisory_xact_lock(hashtextextended(''serving:''||org,72452));perform pg_advisory_xact_lock(hashtextextended(''org_month_spend:''||billing,42));';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial admission lock order';end if;
  definition:=replace(definition,anchor,'');
  -- Never hold an org row lock while waiting on the shared credit wallet.
  anchor:='perform 1 from public.orgs where id=billing and deleted_at is null for update;';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial billing workspace lock';end if;
  definition:=replace(definition,anchor,'perform 1 from public.orgs where id=billing and deleted_at is null;');
  anchor:='perform 1 from public.orgs where id=org and deleted_at is null for update;';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial content workspace lock';end if;
  definition:=replace(definition,anchor,'perform 1 from public.orgs where id=org and deleted_at is null;');
  anchor:='ent:=public.org_entitlement(billing);';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial legacy quota block';end if;
  definition:=split_part(definition,anchor,1)||$body$
  if p_environment not in('Production','Sandbox') or p_tariff_version is distinct from'aerial-opening-v1'
   or p_manifest->>'profile' not in('kie-kling3-omni-reference-aerial-opening-v1','kie-kling3-pro-aerial-opening-v1')
   or (p_quote->>'maximum_total_cents')::numeric>100 or
      (p_quote->>'generation_cents')::numeric<>45 then
    raise exception 'RP402: This 20-credit quote funds only one bounded 1080p aerial opening';end if;
  if not public.credit_primary_subscription(billing,p_environment) then
    wallet:=public.credit_wallet_state(billing,p_environment);
    if public.effective_plan(billing)<>'free' or (wallet->>'monthly_available')::integer<>0 or
      (wallet->>'topup_available')::integer<20 then
      raise exception 'RP402: This workspace needs an eligible credit balance';end if;
  end if;
  wallet:=public.credit_wallet_reserve(p_actor,billing,p_environment,
    'aerial-opening:'||(p_manifest->>'operation_id'),'aerial.opening','aerial-opening-v1');
  if wallet->>'state'<>'reserved' or (wallet->>'credits')::integer<>20 then
    raise exception 'RP409: This aerial customer-credit hold is unavailable';end if;
  select*into fund from public.credit_holds where id=(wallet->>'hold_id')::uuid for update;
  perform pg_advisory_xact_lock(hashtextextended('serving:'||billing,72452));
  perform pg_advisory_xact_lock(hashtextextended('serving:'||org,72452));
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||billing,42));
  perform 1 from public.orgs where id=billing and deleted_at is null for update;
  if not found then raise exception 'RP404: Aerial billing library unavailable';end if;
  perform 1 from public.orgs where id=org and deleted_at is null for update;
  if not found then raise exception 'RP404: Aerial library unavailable';end if;
  -- Sandbox is not customer revenue. Only internal QA may spend it, at most
  -- $3 of credit-funded supplier face per billing workspace in a rolling day.
  if p_environment='Sandbox' then
    if not(public.org_has_internal_testing_grant(billing) or
       public.org_has_private_internal_testing(billing)) then
      raise exception 'RP403: Sandbox aerial credits are limited to internal QA';end if;
    select coalesce(sum(r.hold_cents),0) into daily from public.serving_cost_reservations r
      where r.billing_org_id=billing and r.budget_source='credits'
        and r.credit_environment='Sandbox' and r.state<>'rejected'
        and r.created_at>=now()-interval'1 day';
    if daily+(p_quote->>'maximum_total_cents')::numeric>300 then
      raise exception 'RP402: The Sandbox supplier test budget is used up';end if;
  end if;
  model_name:=case when p_manifest->>'profile'='kie-kling3-omni-reference-aerial-opening-v1'
    then'kling-3.0-omni/reference-to-video'else'kling-3.0/video'end;
  insert into public.serving_cost_reservations(org_id,billing_org_id,actor_id,
    request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,
    sponsored_unlimited,budget_source,credit_hold_id,credit_environment,trial_kind)
  select org,billing,p_actor,'aerial-opening:'||(p_manifest->>'operation_id'),
    v.stage,v.provider,v.model,h,p_quote->>'tariff_version',v.cents,
    false,'credits',fund.id,p_environment,false
  from(values
    ('aerial_input','cloudflare','container-standard-3',(p_quote->>'processing_cents')::numeric/2),
    ('aerial_qualification','cloudflare','container-standard-3',(p_quote->>'processing_cents')::numeric/2),
    ('aerial_assessment',p_quote#>>'{assessment,provider}',p_quote#>>'{assessment,model}',(p_quote#>>'{assessment,cents}')::numeric),
    ('aerial_quality',p_quote#>>'{quality,provider}',p_quote#>>'{quality,model}',(p_quote#>>'{quality,cents}')::numeric),
    ('aerial','kie',model_name,(p_quote->>'generation_cents')::numeric))
    as v(stage,provider,model,cents);
  insert into public.app_video_cost_reservations(org_id,billing_org_id,actor_id,idempotency_key,
    feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,
    hold_cents,meta,credit_hold_id,credit_environment)
  values(org,billing,p_actor,'aerial-opening:'||(p_manifest->>'operation_id'),
    'aerial','kie',model_name,h,5,(c#>>'{route,unit_cents}')::numeric,
    (p_quote->>'generation_cents')::numeric,(p_quote->>'generation_cents')::numeric,
    jsonb_build_object('task',c#>>'{route,task}','route_id',c->>'route_id',
      'unit','second','grounded',true,'seconds',5,'aspect',p_manifest->>'aspect',
      'price_estimated',true),fund.id,p_environment);
  $body$||' insert into public.property_video_aerial_openings('||
    split_part(definition,' insert into public.property_video_aerial_openings(',2);
  -- The prefix above intentionally resumes at the original job INSERT.
  anchor:=E'\n values((p_manifest->>''operation_id'')::uuid,p_actor,org,billing,c,public.listing_owner_library((p_manifest->>''listing_id'')::uuid),(p_manifest->>''listing_id'')::uuid,p_manifest,h,ctx,p_quote,p_consent)returning*into j;return j;';
  replacement:=E'\n values((p_manifest->>''operation_id'')::uuid,p_actor,org,billing,c,public.listing_owner_library((p_manifest->>''listing_id'')::uuid),(p_manifest->>''listing_id'')::uuid,p_manifest,h,ctx,p_quote,p_consent)returning*into j;\n insert into public.credit_aerial_openings(job_id,hold_id,environment,tariff_version)values(j.id,fund.id,p_environment,p_tariff_version);\n return j;';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial job persistence';end if;
  definition:=replace(definition,anchor,replacement);
  execute definition;
end $patch$;
revoke all on function public.property_video_aerial_admit_credit(uuid,jsonb,jsonb,jsonb,text,text)
  from public,anon,authenticated;
grant execute on function public.property_video_aerial_admit_credit(uuid,jsonb,jsonb,jsonb,text,text)
  to service_role;

-- Receipt acceptance is the charge boundary. The validated KIE receipt,
-- customer settlement, provider-stage outcome and cost-ledger row commit or
-- roll back together. A cancelled job with an accepted receipt still settles.
do $patch$ declare definition text; anchor text; replacement text; begin
  definition:=pg_get_functiondef('public.property_video_aerial_receipt(uuid,uuid,jsonb)'::regprocedure);
  anchor:='declare j public.property_video_aerial_openings;begin';
  replacement:='declare j public.property_video_aerial_openings;ca public.credit_aerial_openings;v public.app_video_cost_reservations;h public.credit_holds;begin';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial receipt declaration';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='perform pg_advisory_xact_lock(hashtextextended(''serving:''||j.billing_org_id,72452));';
  replacement:=E'select*into ca from public.credit_aerial_openings where job_id=p_id;\n if ca.job_id is not null then\n  perform pg_advisory_xact_lock(hashtextextended(''credit-wallet:''||j.billing_org_id||'':''||ca.environment,71003));\n end if;\n perform pg_advisory_xact_lock(hashtextextended(''serving:''||j.billing_org_id,72452));';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial receipt lock order';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='if j.provider_receipt is not null then if j.provider_receipt is distinct from p_receipt then raise exception''RP409: Aerial acceptance is immutable'';end if;return true;end if;';
  replacement:=E'if j.provider_receipt is not null then\n  if j.provider_receipt is distinct from p_receipt then raise exception ''RP409: Aerial acceptance is immutable'';end if;\n  if ca.job_id is not null and not exists(select 1 from public.credit_holds where id=ca.hold_id and state=''settled'') then raise exception ''RP503: Accepted aerial receipt lacks customer settlement'';end if;\n  return true;end if;';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial receipt replay';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='perform public.app_video_cost_settle(j.actor_id,j.org_id,''aerial-opening:''||j.operation_id,p_receipt->>''id'');';
  replacement:=E'if ca.job_id is not null then\n  select*into v from public.app_video_cost_reservations where org_id=j.org_id and actor_id=j.actor_id and idempotency_key=''aerial-opening:''||j.operation_id;\n  select*into h from public.credit_holds where id=ca.hold_id;\n  if v.credit_hold_id is distinct from ca.hold_id or v.credit_environment is distinct from ca.environment or h.org_id is distinct from j.billing_org_id or h.actor_id is distinct from j.actor_id or h.request_key is distinct from v.idempotency_key or h.operation is distinct from ''aerial.opening'' or h.tariff_version is distinct from ''aerial-opening-v1'' or h.credits<>20 or h.state<>''reserved'' then raise exception ''RP409: Accepted aerial receipt changed funding'';end if;\n  perform public.credit_wallet_finish(j.actor_id,j.billing_org_id,ca.environment,''aerial-opening:''||j.operation_id,''settled'');\n  if exists(select 1 from public.serving_cost_reservations where credit_hold_id=ca.hold_id and stage=''aerial'' and state=''reserved'') then\n   perform public.serving_cost_finish(j.actor_id,j.org_id,''aerial-opening:''||j.operation_id,''aerial'',''succeeded'',null);\n  elsif not exists(select 1 from public.serving_cost_reservations where credit_hold_id=ca.hold_id and stage=''aerial'' and state in(''uncertain'',''succeeded'')) then\n   raise exception ''RP409: Accepted aerial supplier liability was already rejected'';end if;\n end if;\n perform public.app_video_cost_settle(j.actor_id,j.org_id,''aerial-opening:''||j.operation_id,p_receipt->>''id'');';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial receipt settlement';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='perform public.serving_cost_finish(j.actor_id,j.org_id,''aerial-opening:''||j.operation_id,''aerial'',''succeeded'',null);return true;';
  replacement:=E'if ca.job_id is null then perform public.serving_cost_finish(j.actor_id,j.org_id,''aerial-opening:''||j.operation_id,''aerial'',''succeeded'',null);end if;return true;';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial serving completion';end if;
  execute replace(definition,anchor,replacement);
end $patch$;

-- Reconcile only a definitive terminal outcome. If supplier acceptance is
-- unknown, leave credits reserved. If the provider definitely did not accept
-- and every stage was rejected before work, return them. Otherwise settled
-- supplier liability consumes this one 20-credit attempt, including failure.
do $patch$ declare definition text; anchor text; replacement text; begin
  definition:=pg_get_functiondef('public.property_video_aerial_release_future(uuid)'::regprocedure);
  anchor:='a public.app_video_allowance_receipts;begin';
  replacement:='a public.app_video_allowance_receipts;ca public.credit_aerial_openings;liability boolean;begin';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial terminal declaration';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='perform pg_advisory_xact_lock(hashtextextended(''serving:''||j.billing_org_id,72452));';
  replacement:=E'select*into ca from public.credit_aerial_openings where job_id=p_id;\n if ca.job_id is not null then\n  perform pg_advisory_xact_lock(hashtextextended(''credit-wallet:''||j.billing_org_id||'':''||ca.environment,71003));\n end if;\n perform pg_advisory_xact_lock(hashtextextended(''serving:''||j.billing_org_id,72452));';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial terminal lock order';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='update public.property_video_aerial_openings set future_reconciled_at=coalesce(future_reconciled_at,now())where id=p_id;return true;';
  replacement:=E'if ca.job_id is not null then\n  if r.credit_hold_id is distinct from ca.hold_id or r.credit_environment is distinct from ca.environment then raise exception ''RP409: Aerial liability lost its credit funding'';end if;\n  if j.provider_receipt is not null then\n   perform public.credit_wallet_finish(j.actor_id,j.billing_org_id,ca.environment,''aerial-opening:''||j.operation_id,''settled'');\n  elsif r.released_at is not null and r.provider_request_id is null then\n   select exists(select 1 from public.serving_cost_reservations sr where sr.credit_hold_id=ca.hold_id and sr.budget_source=''credits'' and sr.state<>''rejected'') into liability;\n   perform public.credit_wallet_finish(j.actor_id,j.billing_org_id,ca.environment,''aerial-opening:''||j.operation_id,case when liability then ''settled'' else ''released'' end);\n  end if;\n end if;\n update public.property_video_aerial_openings set future_reconciled_at=coalesce(future_reconciled_at,now())where id=p_id;return true;';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed aerial terminal reconciliation';end if;
  execute replace(definition,anchor,replacement);
end $patch$;

-- A linked video hold is already customer-funded, including an ambiguous
-- dispatch. Keep its real ledger row in global spend; only the paid-plan
-- noncredit slice receives a proven credit-linked addback.
do $patch$ declare definition text; anchor text; replacement text; begin
  definition:=pg_get_functiondef('public.serving_ceiling_spent_cents(uuid,timestamptz,timestamptz)'::regprocedure);
  anchor:='v.cost_ledger_id is null and v.released_at is null';
  replacement:='v.cost_ledger_id is null and v.released_at is null and v.credit_hold_id is null';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed video hold accounting before credit binding';end if;
  execute replace(definition,anchor,replacement);
end $patch$;

do $patch$ declare definition text; anchor text; replacement text; begin
  definition:=pg_get_functiondef('public.credit_combined_budget_state(uuid)'::regprocedure);
  anchor:='where c.id in(select r.ledger_id from public.serving_cost_reservations r';
  replacement:=E'where c.id in(\n      select r.ledger_id from public.serving_cost_reservations r';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed combined credit ledger query';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='and r.ledger_id is not null)';
  replacement:=E'and r.ledger_id is not null\n      union select v.cost_ledger_id from public.app_video_cost_reservations v\n        join public.credit_holds h on h.id=v.credit_hold_id\n        where v.billing_org_id=b and v.credit_environment=''Production''\n          and h.org_id=b and h.environment=''Production'' and h.state=''settled''\n          and h.operation=''aerial.opening'' and h.tariff_version=''aerial-opening-v1''\n          and h.actor_id=v.actor_id and h.request_key=v.idempotency_key\n          and v.cost_ledger_id is not null)';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed combined credit ledger linkage';end if;
  execute replace(definition,anchor,replacement);
end $patch$;

-- Primary credit subscribers cannot silently fall back to a legacy monthly
-- aerial allowance if their current wallet lacks the quoted 20 credits.
do $patch$ declare definition text; anchor text; replacement text; begin
  definition:=pg_get_functiondef('public.property_video_aerial_admit(uuid,jsonb,jsonb,jsonb)'::regprocedure);
  anchor:='ent:=public.org_entitlement(billing);';
  replacement:=E'if public.credit_primary_subscription(billing,''Production'') then\n  raise exception ''RP402: Review the current aerial credit quote before admission'';end if;\n ent:=public.org_entitlement(billing);';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed legacy aerial allowance admission';end if;
  execute replace(definition,anchor,replacement);
end $patch$;
commit;
