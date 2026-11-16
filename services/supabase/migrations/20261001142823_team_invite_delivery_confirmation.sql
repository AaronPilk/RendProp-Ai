-- Invite creation succeeded while every addressed invite silently failed to queue.
-- profiles has `name`, not `full_name`; the RPC catches the undefined-column
-- exception by design so a valid code survives email outages. Keep that contract,
-- queue the existing code/link correctly, and preserve the service-role-only grant.
-- No existing invites are mailed or recreated by this migration.

create or replace function public.notification_enqueue_invite(
  p_org       uuid,
  p_invite    uuid,
  p_email     text,
  p_code      text,
  p_role      text default 'agent',
  p_inviter   uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_org_name text;
  v_inviter  text;
  v_addr     text := lower(btrim(coalesce(p_email, '')));
  v_code     text := upper(btrim(coalesce(p_code, '')));
  v_id       uuid;
begin
  if v_addr = '' or position('@' in v_addr) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_address');
  end if;
  if v_code = '' then
    return jsonb_build_object('ok', false, 'reason', 'no_code');
  end if;

  select name into v_org_name from orgs where id = p_org;
  if p_inviter is not null then
    select coalesce(nullif(btrim(name), ''), null) into v_inviter
      from profiles where id = p_inviter;
  end if;

  insert into public.notification_outbox
      (org_id, user_id, to_email, category, channel, dedupe_key, payload, scheduled_for)
  values
      (p_org, null, v_addr, 'team_invite', 'email', 'invite:' || p_invite::text,
       jsonb_build_object(
          -- absoluteLink() prefixes a leading-slash path with TOUR_PUBLIC_BASE_URL
          -- and refuses anything that is not one, so this cannot become an
          -- off-site link by way of a malformed code.
          'deep_link', '/join/' || v_code,
          'data', jsonb_build_object(
            'code', v_code,
            'org_name', coalesce(v_org_name, 'a team'),
            'inviter', v_inviter,
            'role', coalesce(p_role, 'agent'))),
       now())
  on conflict (dedupe_key) do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', true, 'queued', false, 'reason', 'already_queued');
  end if;
  return jsonb_build_object('ok', true, 'queued', true, 'id', v_id);
exception when others then
  return jsonb_build_object('ok', false, 'reason', SQLSTATE || ': ' || SQLERRM);
end;
$$;

revoke execute on function public.notification_enqueue_invite(uuid,uuid,text,text,text,uuid)
  from public, anon, authenticated;
grant  execute on function public.notification_enqueue_invite(uuid,uuid,text,text,text,uuid)
  to service_role;

