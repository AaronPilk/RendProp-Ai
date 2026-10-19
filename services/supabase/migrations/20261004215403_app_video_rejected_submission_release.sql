-- Only a definitive submit refusal without a provider receipt can release a
-- priced hold. Timeouts, HTTP5xx and missing acceptance remain unresolved.
-- Tombstones stay: release never permits a second POST for the same key.
alter table public.app_video_cost_reservations
  add column if not exists released_at timestamptz,
  add column if not exists rejection_status integer,
  add column if not exists rejection_error_class text;
alter table public.app_video_cost_reservations
  drop constraint if exists app_video_release_consistent;
alter table public.app_video_cost_reservations add constraint app_video_release_consistent check (
  (released_at is null and rejection_status is null and rejection_error_class is null)
  or (released_at is not null and cost_ledger_id is null and provider_request_id is null and settled_at is null
    and rejection_status is not null and rejection_error_class is not null
    and rejection_status in (0,400,401,402,403,404,405,413,415,422,429)
    and rejection_error_class in ('validation','nsfw','rate_limit','upstream','other'))
);
create or replace function public.app_video_cost_pin_receipt()
returns trigger language plpgsql set search_path='' as $$
begin
  if (new.id,new.org_id,new.actor_id,new.idempotency_key,new.feature,new.provider,new.model,
      new.input_sha256,new.units,new.unit_cost_cents,new.total_cents,new.hold_cents,new.meta,new.created_at)
     is distinct from
     (old.id,old.org_id,old.actor_id,old.idempotency_key,old.feature,old.provider,old.model,
      old.input_sha256,old.units,old.unit_cost_cents,old.total_cents,old.hold_cents,old.meta,old.created_at)
    or (old.cost_ledger_id is not null and
      (new.cost_ledger_id,new.provider_request_id,new.settled_at,new.released_at,new.rejection_status,new.rejection_error_class) is distinct from
      (old.cost_ledger_id,old.provider_request_id,old.settled_at,old.released_at,old.rejection_status,old.rejection_error_class))
    or (old.released_at is not null and
      (new.cost_ledger_id,new.provider_request_id,new.settled_at,new.released_at,new.rejection_status,new.rejection_error_class) is distinct from
      (old.cost_ledger_id,old.provider_request_id,old.settled_at,old.released_at,old.rejection_status,old.rejection_error_class)) then
    raise exception 'RP409: Video reservation identity, price and terminal receipt are immutable';
  end if;
  return new;
end $$;

-- Unknown earlier-month allocation can still represent a real bill. Retain it
-- until reconciliation; exclude ONLY a recorded non-allocation rejection.
create or replace function public.app_video_held_cents(p_org uuid)
returns numeric language plpgsql stable security definer set search_path='' as $$
begin
  if not (coalesce(auth.role()='service_role',false)
    or current_setting('role',true)='service_role'
    or (session_user=current_user and current_setting('role',true)='none')
    or exists(select 1 from public.memberships where org_id=p_org and user_id=auth.uid())) then return 0; end if;
  return (select coalesce(sum(hold_cents),0) from public.app_video_cost_reservations
    where org_id=p_org and cost_ledger_id is null and released_at is null);
end $$;

create or replace function public.app_video_cost_release_rejected(
  p_actor uuid,p_org uuid,p_key text,p_provider_status integer,p_error_class text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.app_video_cost_reservations;
begin
  -- Status0 is a server-derived preparation failure before any provider HTTP
  -- request, never an upstream status supplied by a client.
  if p_provider_status is null or p_provider_status not in (0,400,401,402,403,404,405,413,415,422,429)
    or p_error_class is null or p_error_class not in ('validation','nsfw','rate_limit','upstream','other') then
    raise exception 'RP400: A definitive provider submission rejection is required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||p_org::text,42));
  perform 1 from public.orgs where id=p_org for update;
  select * into r from public.app_video_cost_reservations
    where org_id=p_org and actor_id=p_actor and idempotency_key=p_key for update;
  if not found then raise exception 'RP409: Video reservation does not match this actor, workspace and key'; end if;
  if r.cost_ledger_id is not null then raise exception 'RP409: An accepted video cannot release its budget'; end if;
  if r.released_at is not null then
    if (r.rejection_status,r.rejection_error_class) is distinct from (p_provider_status,p_error_class) then
      raise exception 'RP409: Provider rejection receipt is immutable';
    end if;
    return jsonb_build_object('released',true);
  end if;
  update public.app_video_cost_reservations set released_at=now(),
    rejection_status=p_provider_status,rejection_error_class=p_error_class where id=r.id;
  return jsonb_build_object('released',true);
end $$;
revoke all on function public.app_video_cost_release_rejected(uuid,uuid,text,integer,text) from public,anon,authenticated;
grant execute on function public.app_video_cost_release_rejected(uuid,uuid,text,integer,text) to service_role;
revoke all on function public.app_video_held_cents(uuid) from public,anon,authenticated;
grant execute on function public.app_video_held_cents(uuid) to authenticated,service_role;
create or replace function public.app_video_cost_settle(p_actor uuid,p_org uuid,p_key text,p_provider_request_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.app_video_cost_reservations; ledger uuid; live_org uuid;
begin
  if p_provider_request_id is null or length(p_provider_request_id) not between 1 and 256
    or p_provider_request_id !~ '^[!-~]+$' then
    raise exception 'RP400: A bounded provider request receipt is required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||p_org::text,42));
  select id into live_org from public.orgs where id=p_org for update;
  select * into r from public.app_video_cost_reservations
    where org_id=p_org and idempotency_key=p_key and actor_id=p_actor for update;
  if not found then raise exception 'RP409: Video reservation does not match this actor, workspace and key'; end if;
  if r.released_at is not null then raise exception 'RP409: A definitively rejected submission cannot be settled'; end if;
  if r.cost_ledger_id is not null then
    if r.provider_request_id<>p_provider_request_id then raise exception 'RP409: Provider receipt is immutable'; end if;
    return jsonb_build_object('settled',true,'ledger_id',r.cost_ledger_id,'total_cents',r.total_cents);
  end if;
  -- An accepted paid receipt remains accountable after role revocation or
  -- deletion. Settlement grants neither a new dispatch nor media access.
  -- If the org was physically erased, retain its accounting identity in meta
  -- while honoring cost_ledger's existing nullable org FK.
  insert into public.cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta,idempotency_key)
  values(live_org,r.feature,r.provider,r.model,r.units,r.unit_cost_cents,r.total_cents,
    r.meta||jsonb_build_object('app_video_reservation_id',r.id,'billing_org_id',r.org_id,
      'request_id',p_provider_request_id,'input_sha256',r.input_sha256,'held_cents',r.hold_cents,
      'price_estimated',true,'billing_reconciled',false), 'app-video:'||r.id::text)
  returning id into ledger;
  update public.app_video_cost_reservations set provider_request_id=p_provider_request_id,
    cost_ledger_id=ledger,settled_at=now() where id=r.id;
  return jsonb_build_object('settled',true,'ledger_id',ledger,'total_cents',r.total_cents);
end $$;

revoke all on function public.app_video_cost_settle(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.app_video_cost_settle(uuid,uuid,text,text) to service_role;
comment on table public.app_video_cost_reservations is
  'Private immutable one-POST admission: definitive non-allocation can release its hold, never its key. Unresolved holds persist across months until reconciliation. Accepted receipt atomically settles once. No customer input/media stored.';
