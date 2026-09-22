-- 0033 — seats, adoption and membership become transactions.
--
-- Written on GPT-6 Astra's audit of f71b3c9, which reproduced three defects by
-- executing the real handlers offline. All three were then confirmed by reading
-- the source. Astra's proposed-team-core.sql is the basis for the two invite
-- functions here; the differences are noted where they occur.
--
-- ── WHAT WAS BROKEN ─────────────────────────────────────────────────────────
--
-- F02  team/index.ts read the invite, counted seats, inserted the membership,
--      and only THEN tried to mark the invite consumed — ignoring how many rows
--      that update touched. Two people submitting one code both passed the
--      count and both got a membership; only one won the invite row. The code
--      comment claiming the ordering prevented this was wrong: the MEMBERSHIP
--      grants access, not the invite.
--
-- F01  adopt/index.ts selected `org_id, role` and then discarded the role, so
--      ANY member of an empty org — a marketing user, not just its owner —
--      could hard-delete it by calling /adopt with an anonymous token. Empty
--      does not mean disposable: 0019 detaches subscriptions with ON DELETE SET
--      NULL, so a paid, empty brokerage could be destroyed and its subscription
--      orphaned. The identical bug was caught and fixed in team/accept and
--      never back-ported to adopt, which the pattern was copied from.
--
-- F11  handle_new_user is an AFTER INSERT trigger on auth.users, so it fires
--      once, at signup. A member removed from a team kept their Auth user, had
--      no membership, and every route answered 403 "User has no org
--      membership" forever. The comment in team/index.ts promising them a fresh
--      workspace on next launch was false.
--
-- ── THE SHAPE OF THE FIX ────────────────────────────────────────────────────
--
-- One idea removes all three: JOINING A TEAM NO LONGER DESTROYS ANYTHING.
--
-- Before, joining deleted your personal workspace, which is why removal
-- orphaned you and why adopt felt entitled to delete an org it had merely
-- counted. Now you keep your personal workspace and gain a second membership,
-- and a new `user_workspace_state` row records which one you are working in.
-- Removal simply falls back to the personal workspace that was never deleted,
-- so F11 needs no repair path at all. Adoption transfers a membership and
-- deletes nothing, so F01 cannot happen.
--
-- That makes an active-workspace resolver necessary rather than optional:
-- orgForUser() previously picked by role rank, and an agent who joined a team
-- would resolve to their own owner-role personal org instead of the team.
-- _shared/supabase.ts consults this table first.
--
-- Every membership and seat mutation takes the SAME org row lock, before
-- reading any count.

-- ── Which workspace a person is working in ──────────────────────────────────
create table if not exists public.user_workspace_state (
  user_id      uuid primary key references public.profiles(id) on delete cascade,
  active_org_id uuid not null references public.orgs(id) on delete cascade,
  updated_at   timestamptz not null default now()
);
alter table public.user_workspace_state enable row level security;
revoke all on public.user_workspace_state from public, anon, authenticated;
grant select, insert, update, delete on public.user_workspace_state to service_role;

/** The org a user is acting in: their explicit choice when it is still a
 *  membership, else their highest-privilege one. Never raises. */
create or replace function public.active_org_for_user(p_user uuid)
returns uuid
language sql stable
set search_path = ''
as $$
  select coalesce(
    (select s.active_org_id
       from public.user_workspace_state s
       join public.memberships m
         on m.user_id = s.user_id and m.org_id = s.active_org_id
       join public.orgs o on o.id = s.active_org_id and o.deleted_at is null
      where s.user_id = p_user),
    (select m.org_id
       from public.memberships m
       join public.orgs o on o.id = m.org_id and o.deleted_at is null
      where m.user_id = p_user
      order by case m.role when 'owner' then 0 when 'admin' then 1
                           when 'agent' then 2 else 3 end
      limit 1));
$$;

-- ── Accept an invite, atomically ────────────────────────────────────────────
--
-- Differs from Astra's draft in one way: it does NOT refuse when the joiner's
-- own workspace has work in it. Nothing is discarded any more, so there is
-- nothing to refuse — they keep it and switch to the team.
create or replace function public.accept_org_invite(p_user uuid, p_token_hash text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_org uuid;
  v_invite public.org_invites%rowtype;
  v_existing_role text;
  v_allowed integer;
  v_used integer;
  v_name text;
begin
  -- Serialise this user's own joins/adoptions against each other.
  perform 1 from public.profiles where id = p_user for update;
  if not found then raise exception 'RP401: session no longer exists'; end if;
  if exists (select 1 from public.deletion_requests
             where user_id = p_user and status in ('processing','pending')) then
    raise exception 'RP409: this account is being deleted';
  end if;

  select org_id into v_org from public.org_invites where token_hash = p_token_hash;
  if not found then raise exception 'RP404: that invite code is not valid, or it has expired'; end if;

  -- THE lock. Every seat mutation takes it before reading any count.
  select name into v_name from public.orgs
    where id = v_org and deleted_at is null for update;
  if not found then raise exception 'RP404: that invite code is not valid, or it has expired'; end if;

  select * into v_invite from public.org_invites
    where token_hash = p_token_hash and org_id = v_org for update;
  if not found then raise exception 'RP404: that invite code is not valid, or it has expired'; end if;

  select role into v_existing_role from public.memberships
    where user_id = p_user and org_id = v_org;

  if v_invite.accepted_at is not null then
    -- Idempotent for the person who accepted it — but a REMOVED member cannot
    -- walk back in by replaying their own old code.
    if v_invite.accepted_by is distinct from p_user or v_existing_role is null then
      raise exception 'RP404: that invite code is not valid, or it has expired';
    end if;
  else
    if v_invite.revoked_at is not null then
      raise exception 'RP404: that invite code is not valid, or it has expired';
    end if;
    if v_invite.expires_at <= now() then
      raise exception 'RP404: that invite code is not valid, or it has expired';
    end if;
    if v_existing_role is null then
      v_used    := public.org_seats_used(v_org);
      v_allowed := public.org_seats_allowed(v_org);
      if v_allowed is null or v_allowed < 1 then
        raise exception 'RP503: this team''s plan is unavailable right now';
      end if;
      -- This pending invite is itself counted in `used`, so the test is
      -- strictly greater than.
      if v_used > v_allowed then
        raise exception 'RP402: this team is full — every seat on its plan is taken';
      end if;
      insert into public.memberships(user_id, org_id, role)
        values (p_user, v_org, v_invite.role);
      v_existing_role := v_invite.role;
    end if;
    update public.org_invites set accepted_at = now(), accepted_by = p_user
      where id = v_invite.id;
  end if;

  insert into public.user_workspace_state(user_id, active_org_id)
    values (p_user, v_org)
    on conflict (user_id) do update
      set active_org_id = excluded.active_org_id, updated_at = now();

  return jsonb_build_object('ok', true, 'org_id', v_org,
                            'org_name', v_name, 'role', v_existing_role);
end;
$$;

-- ── Create an invite, atomically ────────────────────────────────────────────
--
-- Returns jsonb, not the row type: `org_invites` carries `token_hash`, which is
-- a credential and must never leave the database.
create or replace function public.create_org_invite(
  p_user uuid, p_org uuid, p_email text, p_role text, p_token_hash text
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_role text;
  v_allowed integer;
  v_row public.org_invites%rowtype;
begin
  perform 1 from public.profiles where id = p_user for update;
  if not found then raise exception 'RP401: session no longer exists'; end if;
  if exists (select 1 from public.deletion_requests
             where user_id = p_user and status in ('processing','pending')) then
    raise exception 'RP409: this account is being deleted';
  end if;

  perform 1 from public.orgs where id = p_org and deleted_at is null for update;
  if not found then raise exception 'RP404: workspace not found'; end if;

  select role into v_role from public.memberships where org_id = p_org and user_id = p_user;
  if v_role is null or v_role not in ('owner', 'admin') then
    raise exception 'RP403: only the owner or an admin can change who is on the team';
  end if;
  if p_role is null or p_role not in ('admin', 'agent', 'marketing') then
    raise exception 'RP400: role must be admin, agent or marketing';
  end if;
  if p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'RP400: invalid invite';
  end if;

  v_allowed := public.org_seats_allowed(p_org);
  if v_allowed is null or v_allowed < 1 then
    raise exception 'RP503: this plan is unavailable right now';
  end if;
  if public.org_seats_used(p_org) >= v_allowed then
    raise exception 'RP402: every seat on your plan is taken';
  end if;

  -- Retire invites that have already expired, so the one-live-invite-per-email
  -- index does not block re-inviting somebody whose code ran out. No live
  -- invite is touched.
  update public.org_invites set revoked_at = now()
    where org_id = p_org and accepted_at is null and revoked_at is null and expires_at <= now();

  insert into public.org_invites(org_id, email, role, token_hash, invited_by)
    values (p_org, nullif(lower(btrim(p_email)), ''), p_role, p_token_hash, p_user)
    returning * into v_row;

  return jsonb_build_object('id', v_row.id, 'email', v_row.email, 'role', v_row.role,
                            'created_at', v_row.created_at, 'expires_at', v_row.expires_at);
end;
$$;

-- ── Adopt an anonymous workspace, destroying nothing ────────────────────────
--
-- The old route deleted the caller's own org when it counted zero listings and
-- zero leads. It never checked that the caller OWNED it, that nobody else was
-- in it, or that it had no subscription. This deletes nothing at all: the
-- anonymous membership moves, and the adopted workspace simply becomes active.
create or replace function public.adopt_anonymous_org(
  p_user uuid, p_anon_user uuid, p_anon_org uuid
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_existing_role text;
begin
  if p_user = p_anon_user then raise exception 'RP400: nothing to adopt'; end if;

  perform 1 from public.profiles where id = p_user for update;
  if not found then raise exception 'RP401: session no longer exists'; end if;
  if exists (select 1 from public.deletion_requests
             where user_id = p_user and status in ('processing','pending')) then
    raise exception 'RP409: this account is being deleted';
  end if;

  perform 1 from public.orgs where id = p_anon_org and deleted_at is null for update;
  if not found then raise exception 'RP404: that workspace no longer exists'; end if;

  select role into v_existing_role from public.memberships
    where user_id = p_user and org_id = p_anon_org;
  if v_existing_role is not null then
    -- Already adopted. Retries are normal on a flaky sign-in.
    insert into public.user_workspace_state(user_id, active_org_id)
      values (p_user, p_anon_org)
      on conflict (user_id) do update
        set active_org_id = excluded.active_org_id, updated_at = now();
    return jsonb_build_object('ok', true, 'adopted', true, 'org_id', p_anon_org);
  end if;

  perform 1 from public.memberships
    where user_id = p_anon_user and org_id = p_anon_org for update;
  if not found then raise exception 'RP404: that workspace no longer exists'; end if;

  update public.memberships set user_id = p_user
    where user_id = p_anon_user and org_id = p_anon_org;

  -- Public attribution followed the anonymous profile, which is about to be
  -- deleted; a non-null FK would either block that or orphan the credit.
  update public.listings set agent_id = p_user
    where org_id = p_anon_org and agent_id = p_anon_user;

  insert into public.user_workspace_state(user_id, active_org_id)
    values (p_user, p_anon_org)
    on conflict (user_id) do update
      set active_org_id = excluded.active_org_id, updated_at = now();

  return jsonb_build_object('ok', true, 'adopted', true, 'org_id', p_anon_org);
end;
$$;

-- ── Grants ──────────────────────────────────────────────────────────────────
--
-- 0032 revoked these from `anon` only, which does NOT remove the implicit
-- PUBLIC EXECUTE that every function is created with — so `authenticated`
-- could still call them. Astra caught it.
revoke execute on function public.org_seats_used(uuid)      from public, anon, authenticated;
revoke execute on function public.org_seats_allowed(uuid)   from public, anon, authenticated;
revoke execute on function public.active_org_for_user(uuid) from public, anon, authenticated;
revoke execute on function public.accept_org_invite(uuid, text) from public, anon, authenticated;
revoke execute on function public.create_org_invite(uuid, uuid, text, text, text) from public, anon, authenticated;
revoke execute on function public.adopt_anonymous_org(uuid, uuid, uuid) from public, anon, authenticated;

grant execute on function public.org_seats_used(uuid)      to service_role;
grant execute on function public.org_seats_allowed(uuid)   to service_role;
grant execute on function public.active_org_for_user(uuid) to service_role;
grant execute on function public.accept_org_invite(uuid, text) to service_role;
grant execute on function public.create_org_invite(uuid, uuid, text, text, text) to service_role;
grant execute on function public.adopt_anonymous_org(uuid, uuid, uuid) to service_role;
