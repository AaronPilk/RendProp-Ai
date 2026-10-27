-- Prospective Photo Motion customer-credit funding. The prior migration's
-- activation guard remains in force: installing this file cannot redirect any
-- current job. Terminal accounting and partial receipts still need a separate
-- review before activation is possible.
begin;

create table public.credit_photo_motion_quotes(
  hold_id uuid primary key references public.credit_holds(id) on delete cascade,
  reservation_id uuid not null unique references public.serving_cost_reservations(id),
  job_id uuid unique references public.property_video_jobs(id) on delete set null,
  operation_id uuid not null,
  actor_id uuid not null,
  content_org_id uuid not null,
  billing_org_id uuid not null,
  environment text not null check(environment in('Production','Sandbox')),
  manifest_sha256 text not null check(manifest_sha256~'^[a-f0-9]{64}$'),
  quote_sha256 text not null check(quote_sha256~'^[a-f0-9]{64}$'),
  maximum_supplier_cents numeric not null check(maximum_supplier_cents>0 and maximum_supplier_cents<=100),
  credits integer not null check(credits between 1 and 20),
  created_at timestamptz not null default now(),
  unique(actor_id,operation_id),
  check(credits=ceil(maximum_supplier_cents/5)::integer));
create index credit_photo_motion_quotes_billing_time
  on public.credit_photo_motion_quotes(billing_org_id,created_at desc);
alter table public.credit_photo_motion_quotes enable row level security;
revoke all on public.credit_photo_motion_quotes from public,anon,authenticated,service_role;
grant select on public.credit_photo_motion_quotes to service_role;

create function public.credit_photo_motion_applicable(
  p_actor uuid,p_content_org uuid,p_environment text
) returns boolean language plpgsql stable security definer set search_path='' as $$
declare policy jsonb;billing uuid;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege;end if;
  if p_environment not in('Production','Sandbox') then return false;end if;
  select value into policy from public.app_config where key='credit_photo_motion';
  if policy->'enabled' is distinct from 'true'::jsonb or
     policy->'activation_ready' is distinct from 'true'::jsonb then return false;end if;
  if policy->>'revision' is distinct from 'photo-motion-quoted-v1' or
     policy->>'cents_per_credit' is distinct from '5' or
     policy->>'max_quote_cents' is distinct from '100' then
    raise exception 'RP503: Photo Motion credit policy changed without review';end if;
  billing:=public.library_actor_billing_org(p_actor,p_content_org);
  if p_environment='Sandbox' and
     (public.org_has_internal_testing_grant(billing) or
      public.org_has_private_internal_testing(billing)) then
    -- Keep a recognized internal TestFlight workspace in Sandbox even when
    -- its grant is empty. Falling through would silently spend Production.
    return true;
  end if;
  if public.credit_primary_subscription(billing,p_environment) then return true;end if;
  -- A purchased pack remains the route after its last credit is used, so
  -- Review can show the exact price and invite a top-up instead of falling
  -- through to an old plan or pretending the video is free.
  return exists(select 1 from public.credit_grants g where g.org_id=billing
    and g.environment=p_environment and g.source='topup'
    and g.revoked_at is null and g.starts_at<=now()
    and(g.expires_at is null or g.expires_at>now()));
end$$;

create function public.credit_photo_motion_environment(
  p_actor uuid,p_content_org uuid,p_manifest jsonb,p_supplier_cents numeric
 ) returns text language plpgsql security definer set search_path='' as $$
declare billing uuid;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege;end if;
  -- A signed Apple Sandbox wallet can only fund internal QA. Prefer it on a
  -- QA account so TestFlight never silently spends a Production top-up.
  if public.credit_photo_motion_applicable(p_actor,p_content_org,'Sandbox') then
    return 'Sandbox';end if;
  if not public.credit_photo_motion_applicable(p_actor,p_content_org,'Production') then
    return null;end if;
  billing:=public.library_actor_billing_org(p_actor,p_content_org);
  if public.credit_primary_subscription(billing,'Production') then
    return 'Production';end if;
  -- Existing manual/legacy plans spend their included clips first. A verified
  -- purchased pack extends them only when the complete plan recipe would
  -- refuse on clip, budget, or funded-serving capacity.
  begin
    perform public.property_video_recipe_capacity(p_actor,
      (p_manifest->>'listing_id')::uuid,
      jsonb_array_length(p_manifest->'sources'),p_supplier_cents);
    return null;
  exception when others then
    if sqlerrm like 'RP402:%' then return 'Production';end if;
    raise;
  end;
  return null;
end$$;

-- Read-only Review quote. It validates the same exact full manifest and
-- applies the same plan-first route as admission. Supplier COGS never leaves
-- this server function; customers see only the credit charge and balance.
create function public.credit_photo_motion_review_quote(
  p_actor uuid,p_manifest jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare checked jsonb; supplier jsonb; route text; quote jsonb;
  billing uuid; wallet jsonb; available integer; credits integer;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege;end if;
  checked:=public.property_video_photo_motion_manifest(p_actor,p_manifest);
  supplier:=public.property_video_photo_motion_quote(p_actor,p_manifest);
  route:=public.credit_photo_motion_environment(p_actor,
    (checked->>'org_id')::uuid,p_manifest,(supplier->>'estimated_cents')::numeric);
  if route is null then
    return jsonb_build_object('mode','plan','active',false);end if;
  quote:=public.credit_photo_motion_quote(p_actor,p_manifest,route);
  if quote->'active' is distinct from 'true'::jsonb then
    raise exception 'RP503: Photo Motion credit route changed during review';end if;
  billing:=public.library_actor_billing_org(p_actor,(checked->>'org_id')::uuid);
  wallet:=public.credit_wallet_state(billing,route);
  available:=(wallet->>'total_available')::integer;
  credits:=(quote->>'credits')::integer;
  return jsonb_build_object('mode','credits','active',true,
    'credits',credits,'available_credits',available,
    'affordable',available>=credits,'environment',route,
    'manifest_sha256',quote->>'manifest_sha256',
    'quote_sha256',quote->>'quote_sha256');
end$$;

-- Only the exact admission function may call this private allocator. Its
-- request key, manifest, upper cost, environment and grant sources are frozen
-- together before the background job is inserted.
create function public.credit_photo_motion_fund(
  p_actor uuid,p_org uuid,p_billing uuid,p_environment text,
  p_manifest jsonb,p_manifest_sha256 text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare quoted jsonb;price integer;available bigint;wanted integer;
  prior public.credit_holds;grant_row public.credit_grants;hold_id uuid;
  reservation_id uuid;credit_key text;quote_cents numeric;legacy numeric;
begin
  if current_setting('role',true) is distinct from 'service_role' or
     current_setting('rendprop.photo_motion_credit_admission',true)
       is distinct from p_manifest_sha256 then raise insufficient_privilege;end if;
  if not public.credit_photo_motion_applicable(p_actor,p_org,p_environment) or
     public.library_actor_billing_org(p_actor,p_org) is distinct from p_billing or
     p_manifest_sha256 is distinct from
       encode(sha256(convert_to(p_manifest::text,'UTF8')),'hex') then
    raise exception 'RP402: This workspace has no active Photo Motion credit route';end if;
  quoted:=public.credit_photo_motion_quote(p_actor,p_manifest,p_environment);
  if quoted->'active' is distinct from 'true'::jsonb or
     quoted->>'manifest_sha256' is distinct from p_manifest_sha256 then
    raise exception 'RP409: Photo Motion credit quote changed before funding';end if;
  price:=(quoted->>'credits')::integer;
  quote_cents:=(quoted->>'maximum_supplier_cents')::numeric;
  credit_key:='photomotion:'||(p_manifest->>'operation_id');
  perform pg_advisory_xact_lock(hashtextextended(
    'credit-wallet:'||p_billing||':'||p_environment,71003));
  select * into prior from public.credit_holds where org_id=p_billing and
    environment=p_environment and actor_id=p_actor and request_key=credit_key for update;
  if prior.id is not null then
    raise exception 'RP409: Existing Photo Motion funding must replay its saved job';end if;
  available:=(public.credit_wallet_state(p_billing,p_environment)->>'total_available')::bigint;
  if available<price then raise exception 'RP402: Add credits before starting Photo Motion';end if;
  if p_environment='Sandbox' then
    if not(public.org_has_internal_testing_grant(p_billing) or
      public.org_has_private_internal_testing(p_billing)) then
      raise exception 'RP403: Sandbox Photo Motion is limited to internal QA';end if;
    select coalesce(sum(r.hold_cents),0) into legacy
      from public.serving_cost_reservations r where r.billing_org_id=p_billing
        and r.budget_source='credits' and r.credit_environment='Sandbox'
        and r.state<>'rejected' and r.created_at>=now()-interval'1 day';
    if legacy+quote_cents>300 then
      raise exception 'RP402: The Sandbox supplier test budget is used up';end if;
  end if;
  insert into public.credit_holds(org_id,actor_id,environment,request_key,
    operation,tariff_version,credits) values(p_billing,p_actor,p_environment,
    credit_key,'video.photo_motion','photo-motion-quoted-v1',price)
    returning id into hold_id;
  wanted:=price;
  for grant_row in select * from public.credit_grants where org_id=p_billing
    and environment=p_environment and revoked_at is null and remaining_credits>0
    and starts_at<=now() and (expires_at is null or expires_at>now())
    order by case when source='monthly' then 0 else 1 end,
      expires_at nulls last,created_at,id for update
  loop
    exit when wanted=0;
    insert into public.credit_hold_allocations(hold_id,grant_id,credits)
      values(hold_id,grant_row.id,least(wanted,grant_row.remaining_credits));
    update public.credit_grants set remaining_credits=
      remaining_credits-least(wanted,grant_row.remaining_credits)
      where id=grant_row.id;
    wanted:=wanted-least(wanted,grant_row.remaining_credits);
  end loop;
  if wanted<>0 then raise exception 'RP503: Photo Motion credit allocation changed';end if;
  insert into public.serving_cost_reservations(org_id,billing_org_id,actor_id,
    request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,
    sponsored_unlimited,budget_source,credit_hold_id,credit_environment,trial_kind)
    values(p_org,p_billing,p_actor,credit_key,'photo_motion','cloudflare',
      'container-standard-3',p_manifest_sha256,'container-standard3-20261021',
      quote_cents,false,'credits',hold_id,p_environment,false)
    returning id into reservation_id;
  insert into public.credit_photo_motion_quotes(hold_id,reservation_id,operation_id,
    actor_id,content_org_id,billing_org_id,environment,manifest_sha256,
    quote_sha256,maximum_supplier_cents,credits)
    values(hold_id,reservation_id,(p_manifest->>'operation_id')::uuid,p_actor,
      p_org,p_billing,p_environment,p_manifest_sha256,
      quoted->>'quote_sha256',quote_cents,price);
  return jsonb_build_object('hold_id',hold_id,'reservation_id',reservation_id,
    'credits',price,'quote_sha256',quoted->>'quote_sha256');
end$$;

-- A credit-funded job must link the exact quote and reservation during its
-- original insert. A later update or old-job replay cannot opt in.
create function public.credit_photo_motion_job_bind()
returns trigger language plpgsql security definer set search_path='' as $$
declare q public.credit_photo_motion_quotes;r public.serving_cost_reservations;
  h public.credit_holds;
begin
  if new.manifest->>'source_mode' is distinct from 'photo_motion_v1' then return new;end if;
  select * into r from public.serving_cost_reservations where actor_id=new.actor_id
    and org_id=new.org_id and request_key='photomotion:'||new.operation_id
    and stage='photo_motion' for update;
  if r.budget_source<>'credits' then return new;end if;
  select * into q from public.credit_photo_motion_quotes
    where reservation_id=r.id for update;
  select * into h from public.credit_holds where id=r.credit_hold_id for update;
  if current_setting('role',true) is distinct from 'service_role' or
     current_setting('rendprop.photo_motion_credit_admission',true)
       is distinct from new.manifest_sha256 or
     q.reservation_id is null or q.job_id is not null or
     row(q.hold_id,q.operation_id,q.actor_id,q.content_org_id,
       q.billing_org_id,q.manifest_sha256,q.maximum_supplier_cents,q.credits)
     is distinct from row(r.credit_hold_id,new.operation_id,new.actor_id,
       new.org_id,r.billing_org_id,new.manifest_sha256,r.hold_cents,h.credits) or
     h.org_id is distinct from q.billing_org_id or h.actor_id is distinct from
       new.actor_id or h.environment is distinct from q.environment or
     h.request_key is distinct from r.request_key or
     h.operation is distinct from 'video.photo_motion' or
     h.tariff_version is distinct from 'photo-motion-quoted-v1' or
     h.state is distinct from 'reserved' then
    raise exception 'RP409: Photo Motion job lost its exact customer-credit quote';end if;
  update public.credit_photo_motion_quotes set job_id=new.id
    where hold_id=q.hold_id and job_id is null;
  return new;
end$$;
create trigger z_credit_photo_motion_job_bind after insert on public.property_video_jobs
  for each row execute function public.credit_photo_motion_job_bind();

-- Preserve old admission while routing only explicitly activated, verified
-- monthly-credit workspaces or free top-up workspaces through the quote.
do $patch$ declare definition text;anchor text;replacement text;begin
  definition:=pg_get_functiondef(
    'public.property_video_job_admit_photo_motion(uuid,jsonb)'::regprocedure);
  anchor:='declare j public.property_video_jobs;q jsonb;checked jsonb;h text;org uuid;billing uuid;prior text;meter jsonb;ent public.plan_entitlements;refused public.property_video_refused_operations;reason text;begin';
  replacement:='declare j public.property_video_jobs;q jsonb;checked jsonb;h text;org uuid;billing uuid;prior text;credit_prior text;credit_env text;meter jsonb;ent public.plan_entitlements;refused public.property_video_refused_operations;reason text;begin';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed Photo Motion admission variables';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='checked:=public.property_video_photo_motion_manifest(p_actor,p_manifest);q:=public.property_video_photo_motion_quote(p_actor,p_manifest);org:=(checked->>''org_id'')::uuid;';
  replacement:=anchor||E'\n credit_env:=public.credit_photo_motion_environment(p_actor,org,p_manifest,(q->>''estimated_cents'')::numeric);';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed Photo Motion quote and credit-route order';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:=E' -- Normal exact existing plan/ceiling or funded authority. No new funding gate.\n perform public.property_video_recipe_capacity(p_actor,(p_manifest->>''listing_id'')::uuid,jsonb_array_length(p_manifest->''sources''),(q->>''estimated_cents'')::numeric);\n perform public.serving_cost_reserve(p_actor,org,''photomotion:''||(p_manifest->>''operation_id''),''photo_motion'',''cloudflare'',''container-standard-3'',h,(q->>''estimated_cents'')::numeric,''container-standard3-20261021'');\n select*into ent from public.org_entitlement(public.library_actor_billing_org(p_actor,org));meter:=public.bump_rate_receipt(''reelmo:''||public.library_actor_billing_org(p_actor,org),2592000,ent.reels_per_month,jsonb_array_length(p_manifest->''sources''));if meter->''accepted''is distinct from''true''::jsonb then raise exception''RP402: This video exceeds the current plan photo-clip allowance'';end if;';
  replacement:=E' if credit_env is not null then\n  credit_prior:=current_setting(''rendprop.photo_motion_credit_admission'',true);\n  perform set_config(''rendprop.photo_motion_credit_admission'',h,true);\n  perform public.credit_photo_motion_fund(p_actor,org,billing,credit_env,p_manifest,h);\n else\n  -- Original plan allowance and serving reservation remain byte-for-byte.\n  perform public.property_video_recipe_capacity(p_actor,(p_manifest->>''listing_id'')::uuid,jsonb_array_length(p_manifest->''sources''),(q->>''estimated_cents'')::numeric);\n  perform public.serving_cost_reserve(p_actor,org,''photomotion:''||(p_manifest->>''operation_id''),''photo_motion'',''cloudflare'',''container-standard-3'',h,(q->>''estimated_cents'')::numeric,''container-standard3-20261021'');\n  select*into ent from public.org_entitlement(public.library_actor_billing_org(p_actor,org));meter:=public.bump_rate_receipt(''reelmo:''||public.library_actor_billing_org(p_actor,org),2592000,ent.reels_per_month,jsonb_array_length(p_manifest->''sources''));if meter->''accepted''is distinct from''true''::jsonb then raise exception''RP402: This video exceeds the current plan photo-clip allowance'';end if;\n end if;';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed Photo Motion serving/allowance admission';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='j:=public.property_video_job_enqueue(p_actor,p_manifest);perform set_config(''rendprop.photo_motion_admission'',coalesce(prior,''''),true);';
  replacement:='j:=public.property_video_job_enqueue(p_actor,p_manifest);perform set_config(''rendprop.photo_motion_admission'',coalesce(prior,''''),true);if credit_env is not null then perform set_config(''rendprop.photo_motion_credit_admission'',coalesce(credit_prior,''''),true);end if;';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed Photo Motion enqueue cleanup';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='if sqlerrm not like''RP402:%''then raise;end if;reason:=left(sqlerrm,500);';
  replacement:=anchor||E'\n  if credit_env is not null then\n   -- A wallet race or supplier cap has not created a job. Keep the frozen\n   -- operation open so it can be re-quoted after a top-up or risk reset.\n   return jsonb_build_object(''accepted'',false,''operation_closed'',false,\n     ''operation_id'',p_manifest->>''operation_id'',''message'',reason);\n  end if;';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed Photo Motion refusal identity';end if;
  execute replace(definition,anchor,replacement);
end $patch$;

revoke all on function public.credit_photo_motion_applicable(uuid,uuid,text),
  public.credit_photo_motion_environment(uuid,uuid,jsonb,numeric),
  public.credit_photo_motion_review_quote(uuid,jsonb),
  public.credit_photo_motion_fund(uuid,uuid,uuid,text,jsonb,text),
  public.credit_photo_motion_job_bind() from public,anon,authenticated;
grant execute on function public.credit_photo_motion_applicable(uuid,uuid,text),
  public.credit_photo_motion_environment(uuid,uuid,jsonb,numeric),
  public.credit_photo_motion_review_quote(uuid,jsonb),
  public.credit_photo_motion_job_bind() to service_role;
-- The allocator is private even to service_role. It runs only inside the
-- SECURITY DEFINER admission function's authenticated transaction.
revoke all on function public.credit_photo_motion_fund(uuid,uuid,uuid,text,jsonb,text)
  from service_role;
commit;
