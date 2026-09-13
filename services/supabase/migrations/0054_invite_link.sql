-- 0054: the invite mail carries a LINK, not a chore (2026-09-13).
--
-- Owner feedback from a real TestFlight session, in his words: "A user would
-- find it difficult to go to settings and put in the code. People are idiots
-- this ux and process needs to be easier for a user to do."
--
-- He is right, and the app's own copy admitted it — "You'll get a code to send
-- them. They enter it in Rendprop under Settings -> Team -> Join a team." That
-- is five steps and a typing test, four hundred times over for a brokerage.
--
-- 0053 made the mail arrive. This makes the mail USEFUL: the payload now
-- carries `deep_link = /join/<code>`, which notify/copy.ts absoluteLink()
-- already knows how to turn into https://rendprop.com/join/<code>, and the
-- tour-host Worker serves a page there with the code large, one tap to copy,
-- an App Store button and a `rendprop://join/<code>` hand-off.
--
-- ── THE REDACTION HAS TO FOLLOW THE CODE ───────────────────────────────────
-- 0053's trigger strips `payload -> data -> code` once a row reaches a terminal
-- state. The code now ALSO appears inside the deep link, at the top level of
-- the payload, where that trigger does not look — so a `sent` row would still
-- hold a working invite in its URL. The trigger is widened here. This is the
-- kind of thing that only shows up if you go back and re-read the thing you
-- wrote an hour ago against the thing you are adding now.
--
-- Idempotent: create or replace only.

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
    select coalesce(nullif(btrim(full_name), ''), null) into v_inviter
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

-- ── the redaction now follows the code into the link ────────────────────────

create or replace function public.notification_redact_code()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.state not in ('sent','failed','skipped','expired') then
    return new;
  end if;
  -- the code where it is stored as a field
  if new.payload #> '{data,code}' is not null
     and new.payload #>> '{data,code}' <> '[redacted]' then
    new.payload := jsonb_set(new.payload, '{data,code}', '"[redacted]"'::jsonb);
  end if;
  -- and the same code where it is embedded in the join URL. Missing this is
  -- how a "redacted" row goes on holding a perfectly usable invite.
  if new.payload ->> 'deep_link' like '/join/%' then
    new.payload := jsonb_set(new.payload, '{deep_link}', '"/join/[redacted]"'::jsonb);
  end if;
  return new;
end;
$$;

comment on function public.notification_redact_code() is
  'Strips the plaintext invite code from an outbox payload the moment the row '
  'reaches a terminal state — from data.code AND from the /join/<code> deep '
  'link, because the code lives in both. Before the send it has to be readable; '
  'after, a stored copy is pure liability. A failed row with retries left is put '
  'back to `queued` by notification_mark and never passes through here, so a '
  'retry keeps a usable code.';
