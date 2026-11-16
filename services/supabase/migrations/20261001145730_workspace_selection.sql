-- Explicit workspace selection, with existing memberships as the only authority.
-- Selection is a default for new sessions; clients bind in-flight work to X-Org-Id.
-- No memberships, listings, roles or subscription bindings are changed here.
create or replace function public.workspace_directory(p_user uuid, p_preferred_org uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_org uuid; v_workspaces jsonb;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege using message='service role required';
  end if;
  if not exists(select 1 from public.profiles where id=p_user) then
    raise exception 'RP401: session no longer exists';
  end if;
  if exists(select 1 from public.deletion_requests where user_id=p_user and status in ('pending','processing')) then
    raise exception 'RP409: this account is being deleted';
  end if;
  v_org:=coalesce(p_preferred_org,public.active_org_for_user(p_user));
  if v_org is null or not exists(select 1 from public.memberships m join public.orgs o on o.id=m.org_id
      where m.user_id=p_user and m.org_id=v_org and o.deleted_at is null) then
    raise exception 'RP403: this workspace is no longer available to this account';
  end if;
  select jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,'role',m.role) order by lower(o.name),o.id)
    into v_workspaces from public.memberships m join public.orgs o on o.id=m.org_id
    where m.user_id=p_user and o.deleted_at is null;
  return jsonb_build_object('active_org_id',v_org,'workspaces',coalesce(v_workspaces,'[]'::jsonb));
end;
$$;

create or replace function public.select_workspace(p_user uuid,p_org uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_role text; v_name text;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege using message='service role required';
  end if;
  if p_user is null or p_org is null then raise exception 'RP400: choose a workspace';end if;
  -- Same profile -> org ordering used by team acceptance/removal and deletion.
  perform 1 from public.profiles where id=p_user for update;
  if not found then raise exception 'RP401: session no longer exists';end if;
  if exists(select 1 from public.deletion_requests where user_id=p_user and status in ('pending','processing')) then
    raise exception 'RP409: this account is being deleted';
  end if;
  select name into v_name from public.orgs where id=p_org and deleted_at is null for update;
  if not found then raise exception 'RP403: this workspace is no longer available to this account';end if;
  select role into v_role from public.memberships where user_id=p_user and org_id=p_org;
  if v_role is null then raise exception 'RP403: this workspace is no longer available to this account';end if;
  insert into public.user_workspace_state(user_id,active_org_id) values(p_user,p_org)
    on conflict(user_id)do update set active_org_id=excluded.active_org_id,updated_at=now();
  return jsonb_build_object('ok',true,'org_id',p_org,'org_name',v_name,'role',v_role);
end;
$$;

revoke execute on function public.workspace_directory(uuid,uuid) from public,anon,authenticated;
revoke execute on function public.select_workspace(uuid,uuid) from public,anon,authenticated;
grant execute on function public.workspace_directory(uuid,uuid) to service_role;
grant execute on function public.select_workspace(uuid,uuid) to service_role;
