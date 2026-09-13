-- 0053: an invite that actually reaches the person it was issued to
-- (2026-09-13).
--
-- THE GAP, found by audit today and the single thing that would have killed a
-- brokerage pilot on day one:
--
--   `org_invites` has no trigger. `notification_outbox.category` is a closed
--   CHECK of six values, none of which is an invite. `team/index.ts` says it
--   out loud at line 99 — "this product sends no mail (org_invites.email is
--   'delivery + display only')". So the plaintext invite code existed in
--   exactly one place: the body of the HTTP response that created it. Nothing
--   but a human hand moved it to the agent.
--
--   At two people that is a text message. At four hundred it is four hundred
--   text messages, and then four hundred agents each hand-typing twelve
--   characters. A working Resend pipeline had been sitting right there since
--   0047 with no way for an invite to enter it.
--
-- ── WHY THE ENQUEUE IS NOT A TRIGGER ───────────────────────────────────────
-- `org_invites.token_hash` is `sha256(plaintext)` (0032:29). The plaintext
-- leaves the database exactly once, in the RPC's return value (0048:493-496),
-- and is never at rest anywhere. A trigger on the table can only see the hash,
-- so a trigger PHYSICALLY CANNOT send a usable invite. That is a security
-- property worth keeping, not a bug to route around.
--
-- So the enqueue is a separate RPC called by the edge function, which is the
-- one place that legitimately holds the plaintext, in the same request that
-- minted it.
--
-- ── THE CODE IS REDACTED THE MOMENT IT IS SENT ─────────────────────────────
-- Any asynchronous delivery means the code sits in `notification_outbox.payload`
-- until the drain picks it up — typically under a minute. That window is real
-- and this migration closes it deliberately: `notification_mark` now strips
-- `payload->'data'->>'code'` on any terminal state. The outbox is service-role
-- only with RLS and no policies, so the exposure was already narrow; after the
-- send it is gone entirely, and a `sent` row cannot be replayed into a working
-- invite by anyone who later reads the table.
--
-- ── user_id BECOMES NULLABLE, AND THAT IS THE WHOLE POINT ──────────────────
-- Every other notification goes to someone who already has an account. An
-- invitee, by definition, does not — that is what is being invited. So the
-- outbox grows `to_email`, `user_id` becomes nullable, and a CHECK makes sure
-- a row always has at least one way to reach somebody. Delivery prefers
-- `to_email` when it is set; everything existing keeps working untouched
-- because their `to_email` is null.
--
-- Idempotent throughout.

-- ── 1. the outbox can address a stranger ────────────────────────────────────

alter table public.notification_outbox
  add column if not exists to_email text;

alter table public.notification_outbox
  alter column user_id drop not null;

alter table public.notification_outbox
  drop constraint if exists notification_outbox_has_recipient;
alter table public.notification_outbox
  add constraint notification_outbox_has_recipient
  check (user_id is not null or to_email is not null);

comment on column public.notification_outbox.to_email is
  'An explicit destination for someone who has no account yet — a team invitee. '
  'When set, delivery uses it instead of looking the address up from profiles. '
  'NULL for every ordinary notification, which is addressed by user_id.';

-- A row with no user has no preferences to consult and can only go by mail.
alter table public.notification_outbox
  drop constraint if exists notification_outbox_userless_is_email;
alter table public.notification_outbox
  add constraint notification_outbox_userless_is_email
  check (user_id is not null or channel = 'email');

-- ── 2. the seventh category ─────────────────────────────────────────────────

alter table public.notification_outbox
  drop constraint if exists notification_outbox_category_check;
alter table public.notification_outbox
  add constraint notification_outbox_category_check
  check (category = any (array[
    'lead_received','render_ready','upload_stuck',
    'free_week_ending','allowance_low','first_tour_nudge',
    'team_invite'
  ]));

-- `notification_preferences` is one boolean column per category and an invitee
-- has no row in it at all, so `team_invite` deliberately does NOT get a column.
-- An invite is transactional: someone asked for this person specifically, by
-- address, and there is no account on which to express a preference. It is the
-- one category that is never suppressed.

-- ── 3. enqueue an invite ────────────────────────────────────────────────────
-- Called by functions/team in the same request that minted the code. Never by
-- a trigger — see the header.

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
  v_org_name  text;
  v_inviter   text;
  v_addr      text := lower(btrim(coalesce(p_email, '')));
  v_id        uuid;
begin
  if v_addr = '' or position('@' in v_addr) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_address');
  end if;
  if coalesce(btrim(p_code), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'no_code');
  end if;

  select name into v_org_name from orgs where id = p_org;
  if p_inviter is not null then
    select coalesce(nullif(btrim(full_name), ''), null) into v_inviter
      from profiles where id = p_inviter;
  end if;

  -- dedupe_key is the invite id, so re-sending the same invite is a no-op
  -- rather than a second mail. Re-inviting mints a NEW invite row and so gets
  -- a new key, which is the behaviour you want.
  insert into public.notification_outbox
      (org_id, user_id, to_email, category, channel, dedupe_key, payload, scheduled_for)
  values
      (p_org, null, v_addr, 'team_invite', 'email', 'invite:' || p_invite::text,
       jsonb_build_object('data', jsonb_build_object(
          'code', p_code,
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
  -- An invite that cannot be MAILED must never fail the invite that was
  -- successfully CREATED. The caller gets the code back either way.
  return jsonb_build_object('ok', false, 'reason', SQLSTATE || ': ' || SQLERRM);
end;
$$;

comment on function public.notification_enqueue_invite is
  'Queue the e-mail that carries an invite code. Called by functions/team right '
  'after create_org_invite / create_org_invites_bulk, because that is the only '
  'place the plaintext code exists — org_invites stores sha256 of it, so a '
  'trigger could never send a usable invite. Never raises: a mail failure must '
  'not roll back a seat that was issued.';

revoke execute on function public.notification_enqueue_invite(uuid,uuid,text,text,text,uuid)
  from public, anon, authenticated;
grant  execute on function public.notification_enqueue_invite(uuid,uuid,text,text,text,uuid)
  to service_role;

-- dedupe_key has to be unique for the ON CONFLICT above to mean anything.
create unique index if not exists notification_outbox_dedupe_uidx
  on public.notification_outbox (dedupe_key);

-- ── 4. strip the code once it has been delivered ────────────────────────────
-- A TRIGGER, NOT A REWRITE OF notification_mark.
--
-- The first draft of this migration restated notification_mark with the
-- redaction folded in. That was wrong and the source caught it: the real
-- function is not a simple UPDATE — it carries the retry ladder (failed +
-- attempts < 5 goes back to `queued` with a 1/4/9/16-minute backoff), a
-- FOR UPDATE lock, state validation, error truncation at 500 chars, a
-- different parameter name (p_provider_id), and it RETURNS the row rather
-- than void. Restating it from memory would have silently deleted the
-- retries — every transient Resend blip would have become a permanent
-- failure, and nothing would have looked broken.
--
-- So the redaction attaches to the table instead. It cannot interfere with
-- the retry ladder because it only fires when the state actually lands on a
-- terminal value, and `failed`-with-retries-left never reaches one: that path
-- sets the row back to `queued`.

create or replace function public.notification_redact_code()
returns trigger language plpgsql set search_path = public as $$
begin
  -- Terminal only. A `failed` row that notification_mark is about to requeue
  -- passes through `queued`, not through here, so its code survives for the
  -- retry — which is the entire reason a retry exists.
  if new.state in ('sent','failed','skipped','expired')
     and new.payload #> '{data,code}' is not null
     and new.payload #>> '{data,code}' <> '[redacted]'
  then
    new.payload := jsonb_set(new.payload, '{data,code}', '"[redacted]"'::jsonb);
  end if;
  return new;
end;
$$;

drop trigger if exists notification_redact_code_trg on public.notification_outbox;
create trigger notification_redact_code_trg
  before update on public.notification_outbox
  for each row
  when (new.state in ('sent','failed','skipped','expired'))
  execute function public.notification_redact_code();

comment on function public.notification_redact_code() is
  'Strips the plaintext invite code from an outbox payload the moment the row '
  'reaches a terminal state. Before that the code has to be readable, because '
  'the drain has not sent it yet; after, a stored copy is pure liability — '
  'anyone who could read the table later could accept a seat meant for someone '
  'else. A failed row that still has retries left is put back to `queued` by '
  'notification_mark and never passes through this trigger, so retries keep '
  'a usable code.';
