-- 0038: transfer + exact replay receipt commit together. No Auth deletion,
-- workspace deletion, or credential bytes. CLI scaffold renamed to the repo's
-- explicitly reserved sequential migration name; 0037 belongs to the cost lane.
create table if not exists public.anonymous_adoption_receipts (
  operation_id uuid primary key,
  source_user_id uuid not null unique,
  destination_user_id uuid not null,
  org_id uuid not null,
  receipt jsonb not null,
  created_at timestamptz not null default now(),
  check (source_user_id <> destination_user_id)
);
-- No cascade from the source identity: a later cleanup must not erase proof.
alter table public.anonymous_adoption_receipts enable row level security;
revoke all on public.anonymous_adoption_receipts from public, anon, authenticated, service_role;
grant select, insert on public.anonymous_adoption_receipts to service_role;

create or replace function public.adoption_receipt(p_user uuid, p_anon_user uuid, p_operation uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v public.anonymous_adoption_receipts%rowtype;
begin
  if current_setting('role', true) is distinct from 'service_role' then
    raise insufficient_privilege using message = 'service role required';
  end if;
  if p_user is null or p_anon_user is null or p_operation is null or p_user = p_anon_user then
    raise exception 'RP400: invalid handoff binding';
  end if;
  select * into v from public.anonymous_adoption_receipts where operation_id = p_operation;
  if not found then
    if exists(select 1 from public.anonymous_adoption_receipts where source_user_id = p_anon_user) then
      raise exception 'RP409: this source already has a different handoff';
    end if;
    return null;
  end if;
  if v.source_user_id <> p_anon_user or v.destination_user_id <> p_user then
    raise exception 'RP403: handoff binding does not match';
  end if;
  -- A receipt is historical proof, not a way to re-grant a removed membership
  -- or change the user's current active workspace during a later replay.
  if not exists(select 1 from public.memberships m join public.orgs o on o.id=m.org_id
                where m.user_id=p_user and m.org_id=v.org_id and o.deleted_at is null)
     or exists(select 1 from public.deletion_requests where user_id=p_user and status in ('pending','processing')) then
    raise exception 'RP409: transferred workspace is no longer available to this account';
  end if;
  return v.receipt;
end;
$$;

create or replace function public.adopt_anonymous_org(
  p_user uuid, p_anon_user uuid, p_anon_org uuid, p_operation uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_receipt jsonb; v_count integer;
begin
  if current_setting('role', true) is distinct from 'service_role' then
    raise insufficient_privilege using message = 'service role required';
  end if;
  if p_user is null or p_anon_user is null or p_anon_org is null or p_operation is null or p_user=p_anon_user then
    raise exception 'RP400: invalid handoff binding';
  end if;
  -- Receipt-only replays do not change workspace selection or lock Auth rows.
  v_receipt := public.adoption_receipt(p_user,p_anon_user,p_operation);
  if v_receipt is not null then
    if (v_receipt->>'org_id')::uuid <> p_anon_org then raise exception 'RP403: workspace binding does not match'; end if;
    return v_receipt;
  end if;
  -- Auth -> profile -> org; sorted within each class. Auth can promote an
  -- anonymous identity while Edge waits for SQL. Its live row, not the earlier
  -- GET/JWT snapshot, must still authorize the transfer. Auth-first also agrees
  -- with auth.users deletion cascading into profiles. No HTTP inside the lock.
  perform 1 from auth.users where id in(p_user,p_anon_user) order by id for update;
  perform 1 from public.profiles where id in (p_user,p_anon_user) order by id for update;
  v_receipt := public.adoption_receipt(p_user,p_anon_user,p_operation);
  if v_receipt is not null then
    if (v_receipt->>'org_id')::uuid <> p_anon_org then raise exception 'RP403: workspace binding does not match'; end if;
    return v_receipt;
  end if;
  select count(*) into v_count from public.profiles where id in (p_user,p_anon_user);
  if v_count <> 2 then raise exception 'RP401: session no longer exists'; end if;
  if (select is_anonymous from auth.users where id=p_anon_user) is distinct from true
     or (select is_anonymous from auth.users where id=p_user) is distinct from false then
    raise exception 'RP403: current source and destination identity types do not permit transfer';
  end if;
  if exists(select 1 from public.deletion_requests where user_id in (p_user,p_anon_user)
            and status in ('pending','processing')) then raise exception 'RP409: an account is being deleted'; end if;
  perform 1 from public.orgs where id=p_anon_org and deleted_at is null for update;
  if not found then raise exception 'RP404: that workspace no longer exists'; end if;
  -- Recheck the boundary inside the transaction, not only at Edge preflight.
  if (select count(*) from public.memberships where user_id=p_anon_user) <> 1
     or not exists(select 1 from public.memberships where user_id=p_anon_user and org_id=p_anon_org and role='owner')
     or exists(select 1 from public.memberships where org_id=p_anon_org and user_id<>p_anon_user) then
    raise exception 'RP409: original workspace ownership changed';
  end if;
  update public.memberships set user_id=p_user where user_id=p_anon_user and org_id=p_anon_org;
  update public.listings set agent_id=p_user where org_id=p_anon_org and agent_id=p_anon_user;
  insert into public.user_workspace_state(user_id,active_org_id) values(p_user,p_anon_org)
    on conflict(user_id) do update set active_org_id=excluded.active_org_id, updated_at=now();
  v_receipt := jsonb_build_object('ok',true,'adopted',true,'operation_id',p_operation,
    'source_user_id',p_anon_user,'destination_user_id',p_user,'org_id',p_anon_org,
    'source_cleanup_pending',true);
  insert into public.anonymous_adoption_receipts(operation_id,source_user_id,destination_user_id,org_id,receipt)
    values(p_operation,p_anon_user,p_user,p_anon_org,v_receipt);
  return v_receipt;
end;
$$;

-- An old Edge instance may still call three arguments during rollout. It uses
-- the same receipt-writing transaction, not the former receipt-less mutation.
-- The source is globally single-use. Existing proof may be replayed only for
-- that same source/destination/org tuple; never choose an arbitrary receipt.
create or replace function public.adopt_anonymous_org(p_user uuid,p_anon_user uuid,p_anon_org uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v public.anonymous_adoption_receipts%rowtype; bytes bytea; operation uuid;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege using message = 'service role required';
  end if;
  if p_user is null or p_anon_user is null or p_anon_org is null or p_user=p_anon_user then
    raise exception 'RP400: invalid handoff binding';
  end if;
  select * into v from public.anonymous_adoption_receipts where source_user_id=p_anon_user;
  if found then
    if v.destination_user_id <> p_user or v.org_id <> p_anon_org then
      raise exception 'RP403: legacy handoff binding does not match';
    end if;
    return public.adoption_receipt(p_user,p_anon_user,v.operation_id);
  end if;
  -- Built-in SHA256, not pgcrypto. Byte-for-byte same namespace and UUID bits
  -- as the updated Edge route's legacyOperation; no extension dependency.
  bytes := sha256(convert_to('rendprop-adoption-v1:'||p_anon_user::text||':'||p_user::text,'UTF8'));
  bytes := set_byte(bytes,6,(get_byte(bytes,6)&15)|64);
  bytes := set_byte(bytes,8,(get_byte(bytes,8)&63)|128);
  operation := encode(substring(bytes from 1 for 16),'hex')::uuid;
  return public.adopt_anonymous_org(p_user,p_anon_user,p_anon_org,operation);
end;
$$;
revoke execute on function public.adopt_anonymous_org(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.adopt_anonymous_org(uuid,uuid,uuid) to service_role;
revoke execute on function public.adopt_anonymous_org(uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke execute on function public.adoption_receipt(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.adopt_anonymous_org(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.adoption_receipt(uuid,uuid,uuid) to service_role;
