-- 0047: lifecycle messaging — the outbox, the triggers and the schedule
--       (2026-09-12, commercial audit "nothing in this product ever speaks to
--       the customer").
--
-- NUMBERING: 0048 is reserved for a parallel branch. Nothing in this file
-- references it; the two are independent and may land in either order.
--
-- ── WHAT WAS TRUE BEFORE THIS FILE ──────────────────────────────────────────
--
-- No push, no e-mail, no scheduled outbound message existed anywhere in the
-- system. `apps/ios/Rendprop/Config.swift` reads
-- `static let enablePush = false // TODO: APNs render-ready / lead-received`,
-- and functions/leads/index.ts says it in as many words at the end of the
-- public capture path:
--
--     "Agent notification (email/push) is a later step — the app's Leads
--      screen (GET /leads) is the delivery channel for now (decision A13)."
--
-- So when a buyer fills in the end-card on a hosted tour at 21:40, the agent
-- finds out whenever they next happen to open the app. For a customer who
-- lists ~9 houses a year that silence IS the churn mechanism: the sentence
-- that renews a subscription is "Rendprop got me a lead", and nobody can say
-- it about a lead they never saw.
--
-- ── WHAT THIS FILE IS, AND WHAT IT DELIBERATELY IS NOT ───────────────────────
--
-- It is an OUTBOX, not a pile of send calls. Every producer — a trigger inside
-- the lead insert, the two publish paths, the 15-minute tick — writes a ROW.
-- Delivery is a separate, restartable drain (functions/notify) that claims
-- rows, sends them and marks them. That separation buys four things nothing
-- else can:
--
--   1. A producer can never be slowed down, or failed, by a provider. The lead
--      insert commits whether or not APNs is reachable.
--   2. `dedupe_key` is UNIQUE, so "the same event queued twice" is a database
--      constraint rather than a convention. Every producer here keys on the
--      fact that caused it (a lead id, a render id, a trial end instant, a
--      meter window), so a replayed trigger or a re-run tick writes nothing.
--   3. The drain is safe to run concurrently: notification_claim_batch() locks
--      FOR UPDATE SKIP LOCKED, so two instances cannot hand the same row to
--      two providers.
--   4. It ships INERT. With no APNs or e-mail secret set, the drain marks rows
--      `skipped` with a reason and keeps running. The owner turns it on by
--      adding keys, not by deploying code.
--
-- It is NOT a message-content store. The outbox carries the FACTS (which lead,
-- which listing, how many hours of trial are left); the WORDING lives in one
-- file, services/supabase/functions/notify/copy.ts, so the copy can be fixed
-- without a migration and without rewriting rows that are already queued. The
-- `payload` column still accepts explicit `title`/`body` — an operator-composed
-- message wins over the template — it just is not where the six product
-- messages live.
--
-- ── AFTER TRIGGER vs IN-FUNCTION CALL (the decision, and why) ────────────────
--
--   leads       → AFTER INSERT ROW TRIGGER (§8). The insert is a plain INSERT
--                 from functions/leads/index.ts with no locking of its own, so
--                 a trigger adds no lock-order risk; and a trigger catches
--                 EVERY writer, including a future one and a hand-written
--                 support insert. AFTER, not BEFORE, because the dedupe key is
--                 the lead's own id and BEFORE INSERT does not have it yet.
--
--   renders     → IN-FUNCTION CALL inside publish_render() (§9) and
--                 publish_worker_render() (§10), NOT a trigger on `renders`.
--                 Three reasons, all of them about those functions' locking
--                 and their replay arms:
--                   • publish_worker_render() holds `for update` locks on the
--                     listing and the job and re-checks its lease AFTER the
--                     last write, rolling the whole publication back if it
--                     expired. The enqueue has to sit INSIDE that fence, after
--                     the final re-check, or a notification can outlive a
--                     publication that was rolled back. A row trigger fires at
--                     the write, which is before the fence closes.
--                   • `renders` is UPDATEd by paths that are not publications:
--                     unpublish_deleted_listing_renders() (0011 §12) nulls
--                     published_at on a soft delete, and 0035's recovery arm
--                     rewrites an existing row. A trigger would have to
--                     re-derive "is this a publication?" from OLD/NEW; the two
--                     publish functions simply KNOW.
--                   • publish_render() allocates its slug in a retry loop whose
--                     failed attempts are rolled back by an exception block. A
--                     row trigger would run inside each attempt.
--
--   scheduled   → notification_tick() (§11), called every 15 minutes by
--                 pg_cron (§12, the same guarded pattern as 0022).
--
-- Both in-function enqueues, and the lead trigger, wrap the call in their OWN
-- exception block. This is a deliberate ordering of harms: a bug in lifecycle
-- messaging must never cost a customer a captured lead or a finished tour. The
-- block degrades to a RAISE WARNING; the outbox row is simply not written, and
-- the outbox is not the system of record for anything.
--
-- ── IDEMPOTENCY ─────────────────────────────────────────────────────────────
--
-- `create table if not exists`, `create index if not exists`, guarded
-- constraints, `create or replace function`, `drop trigger if exists` before
-- `create trigger`, and a cron block that unschedules before scheduling. CI
-- applies this file TWICE (tools/audit/run_database_regression.py); a replay
-- changes nothing and destroys no rows.

-- ── 1. notification_devices — where a push can actually land ────────────────
--
-- One row per APNs device token. THE TOKEN IS THE IDENTITY: it is unique, and
-- re-registering one that is already on file MOVES it to the current user
-- (a phone handed to another agent must not keep waking the old one) and
-- re-enables it (a person who reinstalls gets their notifications back).
--
-- `environment` decides the HOST the drain talks to — api.sandbox.push.apple.com
-- for a development build, api.push.apple.com for TestFlight/App Store. Sending
-- a production token to the sandbox host (or the reverse) is the classic
-- silent-failure: Apple answers 400 BadDeviceToken and nothing is delivered.
--
-- `disabled_at` + `disabled_reason` are written when APNs says the token is
-- dead (410 Unregistered, 400 BadDeviceToken). A dead token is retired, never
-- retried forever — see notification_disable_device() in §7.
--
-- POSTURE: RLS on with NO policies and every tenant grant revoked. A client
-- cannot SELECT, INSERT or UPDATE this table at all; the only write path is
-- notification_register_device() (SECURITY DEFINER, service_role), reached
-- through POST /me/devices with the caller's own JWT resolved server-side. A
-- direct table grant would let one signed-in tenant enumerate or re-point
-- another tenant's push tokens.

create table if not exists public.notification_devices (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid        not null references public.profiles(id) on delete cascade,
  device_token    text        not null,
  bundle_id       text        not null default 'com.rendprop.app',
  environment     text        not null default 'production'
                    check (environment in ('sandbox','production')),
  locale          text,
  app_version     text,
  created_at      timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),
  disabled_at     timestamptz,
  disabled_reason text
);

create unique index if not exists uq_notification_devices_token
  on public.notification_devices (device_token);
create index if not exists idx_notification_devices_user
  on public.notification_devices (user_id) where disabled_at is null;

comment on table public.notification_devices is
  'APNs device tokens, one row per token (unique). Service-role only: RLS on, '
  'no policies, no tenant grants — the only write path is '
  'notification_register_device() behind POST /me/devices. A token APNs rejects '
  'as 410 Unregistered / 400 BadDeviceToken is disabled here rather than retried.';

comment on column public.notification_devices.environment is
  'Which APNs host this token belongs to: sandbox (development builds) or '
  'production (TestFlight + App Store). Sending a token to the wrong host is a '
  'silent non-delivery, so the drain picks the host from THIS column.';

comment on column public.notification_devices.disabled_at is
  'Set when Apple says the token is dead. A disabled row is never selected for '
  'delivery and never deleted — it is the evidence that this install is gone.';

-- ── 2. notification_preferences — the off switch, per category ──────────────
--
-- A MISSING ROW MEANS EVERY CATEGORY IS ON. That is the whole reason the
-- defaults are on the columns AND notification_preferences_for() (§7) exists:
-- the app, the enqueuer and a human reading the table all get the same answer
-- for a person who has never touched the settings screen.
--
-- Transactional (lead_received, render_ready, upload_stuck) and lifecycle
-- (free_week_ending, allowance_low, first_tour_nudge) default ON — a person
-- who just published a tour wants to know a buyer wrote in — and EVERY ONE of
-- the six can be turned off independently. `muted_until` is the global pause:
-- while it is in the future, nothing at all is enqueued for this person.
--
-- There is deliberately no "marketing" category and no way to add one from a
-- client: the six below are the entire vocabulary the CHECK on
-- notification_outbox.category enforces.

create table if not exists public.notification_preferences (
  user_id          uuid primary key references public.profiles(id) on delete cascade,
  lead_received    boolean     not null default true,
  render_ready     boolean     not null default true,
  upload_stuck     boolean     not null default true,
  free_week_ending boolean     not null default true,
  allowance_low    boolean     not null default true,
  first_tour_nudge boolean     not null default true,
  muted_until      timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

comment on table public.notification_preferences is
  'Per-person notification switches. NO ROW = every category ON — read through '
  'notification_preferences_for() so the app and the enqueuer never disagree. '
  'Service-role only (RLS on, no policies); written by '
  'notification_set_preferences() behind PATCH /me/notifications.';

comment on column public.notification_preferences.muted_until is
  'Global pause. While this is in the future notification_enqueue() returns '
  'skipped for EVERY category, transactional ones included.';

-- ── 3. notification_outbox — the queue ──────────────────────────────────────
--
-- COLUMN NOTES THAT CARRY REAL MEANING:
--
--   dedupe_key   UNIQUE, and NOT NULL. This is the anti-double-send invariant,
--                enforced by the database rather than by whoever writes the
--                next producer. Every producer keys on the FACT: the lead id,
--                the render id, the trial-end instant, the meter window. A
--                re-run tick, a replayed trigger and a retried edge call all
--                collide on the same key and write nothing.
--   channel      ONE row means ONE delivery. notification_enqueue() picks push
--                when the person has a live device and e-mail otherwise (§7) —
--                so "a lead enqueues one row per owner/admin" stays literally
--                true and nobody is double-messaged about one event.
--   payload      FACTS, not prose. {deep_link, data:{…}} plus optional
--                title/body for an operator-composed message. The six product
--                messages are rendered from `data` by functions/notify/copy.ts.
--   scheduled_for  when it may first be sent. `now()` for everything this file
--                produces; the column exists so a future producer can say
--                "tomorrow at 9am local" without a second table.
--   claimed_at   when notification_claim_batch() flipped it to `sending`. It is
--                what makes notification_sweep() able to tell a send that is in
--                flight from one whose isolate died — there is no other clock
--                on that transition.
--   state        queued → sending → sent | failed | skipped | expired.
--                `skipped` is a NORMAL outcome, not an error: no provider key,
--                no device, a preference off. `expired` is a row that sat past
--                its usefulness (§7, notification_sweep).
--
-- The outbox is PRUNABLE. Nothing here purges it today, but it is designed to
-- be: the permanent record of what was actually delivered is notification_log
-- (§4), which is a different table for exactly that reason.

create table if not exists public.notification_outbox (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid        references public.orgs(id) on delete cascade,
  user_id       uuid        not null references public.profiles(id) on delete cascade,
  category      text        not null,
  channel       text        not null check (channel in ('push','email')),
  dedupe_key    text        not null,
  payload       jsonb       not null default '{}'::jsonb,
  scheduled_for timestamptz not null default now(),
  state         text        not null default 'queued'
                  check (state in ('queued','sending','sent','failed','skipped','expired')),
  attempts      integer     not null default 0,
  last_error    text,
  claimed_at    timestamptz,
  created_at    timestamptz not null default now(),
  sent_at       timestamptz
);

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.notification_outbox'::regclass
       and conname  = 'notification_outbox_category_check'
  ) then
    alter table public.notification_outbox
      add constraint notification_outbox_category_check
      check (category in ('lead_received','render_ready','upload_stuck',
                          'free_week_ending','allowance_low','first_tour_nudge'));
  end if;

  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.notification_outbox'::regclass
       and conname  = 'notification_outbox_payload_object'
  ) then
    alter table public.notification_outbox
      add constraint notification_outbox_payload_object
      check (jsonb_typeof(payload) = 'object' and pg_column_size(payload) <= 8192);
  end if;
end $$;

create unique index if not exists uq_notification_outbox_dedupe
  on public.notification_outbox (dedupe_key);
-- The drain's only query: the next queued rows that are due.
create index if not exists idx_notification_outbox_ready
  on public.notification_outbox (state, scheduled_for);

comment on table public.notification_outbox is
  'The delivery queue. One row = one message on one channel to one person. '
  'dedupe_key is UNIQUE so an event can never be queued twice. Claimed by '
  'notification_claim_batch() (FOR UPDATE SKIP LOCKED, so concurrent drains are '
  'safe) and closed by notification_mark(). Prunable: what was actually '
  'delivered lives in notification_log.';

comment on column public.notification_outbox.dedupe_key is
  'The identity of the EVENT, not of the row: lead_received:<lead>:<user>, '
  'render_ready:<render>:<user>, free_week_ending:<org>:<trial end>:<user>, '
  'allowance_low:<org>:<feature>:<window>:<user>, first_tour_nudge:<org>:<user>, '
  'upload_stuck:<asset>:<user>. UNIQUE — a replay collides and writes nothing.';

comment on column public.notification_outbox.claimed_at is
  'When claim_batch flipped this row to sending. notification_sweep() reclaims '
  'a sending row older than 10 minutes; without this column a drain that died '
  'mid-send would strand its batch forever.';

-- ── 4. notification_log — what was actually delivered, permanently ──────────
--
-- Deliberately SEPARATE from the outbox and deliberately TINY: category,
-- channel, org, user, when, and the provider's own message id. No title, no
-- body, no address, no token. That is what makes it safe to keep forever, and
-- keeping it forever is the point — the outbox can be pruned the day it gets
-- big, and "did we ever tell this customer their tour was ready?" still has an
-- answer.
--
-- NOT PURGED BY ANY CRON. 0022's nightly job touches app_events and nothing
-- else; this table is not in it and must not be added to it.
--
-- The two FKs are `on delete set null`, not cascade: deleting an account
-- de-identifies the record and keeps the count. A deleted customer is forgotten
-- without falsifying how much mail this system has sent.

create table if not exists public.notification_log (
  id                  bigserial primary key,
  category            text        not null,
  channel             text        not null,
  org_id              uuid        references public.orgs(id) on delete set null,
  user_id             uuid        references public.profiles(id) on delete set null,
  sent_at             timestamptz not null default now(),
  provider_message_id text
);

create index if not exists idx_notification_log_sent
  on public.notification_log (sent_at);
create index if not exists idx_notification_log_org
  on public.notification_log (org_id, sent_at);

comment on table public.notification_log is
  'PERMANENT, compact record of messages that were actually delivered. No '
  'content, no address, no token — category/channel/org/user/time/provider id '
  'only, which is why it can be kept indefinitely. Written by '
  'notification_mark(p_state => ''sent''). NOT purged by any cron job: 0022 '
  'schedules purge_app_events() and nothing else. Do not add this table to it.';

-- ── 5. Posture: every one of the four tables is service-role only ───────────
--
-- Same shape as rate_limits (0004/0007), admin_allowlist (0017) and app_events
-- (0020): RLS enabled with NO policies, and the API roles revoked explicitly so
-- Supabase's default grants on a freshly created table cannot leave a hole.

alter table public.notification_devices     enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.notification_outbox      enable row level security;
alter table public.notification_log         enable row level security;

revoke all on public.notification_devices     from public, anon, authenticated;
revoke all on public.notification_preferences from public, anon, authenticated;
revoke all on public.notification_outbox      from public, anon, authenticated;
revoke all on public.notification_log         from public, anon, authenticated;

-- AND FROM service_role TOO, before granting back only SELECT. Supabase's
-- default privileges hand the API roles ALL on a freshly created table, so
-- without this revoke the service role would keep INSERT/UPDATE/DELETE and
-- "every write goes through an RPC" would be a comment rather than a rule.
-- With it: the drain can READ the queue and the device list (which is all it
-- needs), and cannot forge a message, re-point a push token, or rewrite the
-- permanent log. Every write path is a SECURITY DEFINER function below, owned
-- by the migrating role, which is unaffected by this revoke.
revoke all on public.notification_devices     from service_role;
revoke all on public.notification_preferences from service_role;
revoke all on public.notification_outbox      from service_role;
revoke all on public.notification_log         from service_role;

grant select on public.notification_devices     to service_role;
grant select on public.notification_preferences to service_role;
grant select on public.notification_outbox      to service_role;
grant select on public.notification_log         to service_role;

-- ── 6. notification_register_device / notification_set_preferences ──────────
--
-- The two tenant-facing writes, both reached through functions/me with the
-- caller's own JWT resolved to p_user server-side. SECURITY DEFINER and
-- service_role only, the same grant posture as apply_apple_entitlement()
-- (0019) and set_provenance_media(): a signed-in client never calls these
-- directly, so it can never pass somebody else's user id.

create or replace function public.notification_register_device(
  p_user        uuid,
  p_token       text,
  p_bundle_id   text default null,
  p_environment text default null,
  p_locale      text default null,
  p_app_version text default null
) returns public.notification_devices
language plpgsql
security definer
set search_path = public
as $notification_register_device$
declare
  v_token text := btrim(coalesce(p_token, ''));
  v_env   text := lower(btrim(coalesce(p_environment, 'production')));
  v_row   public.notification_devices;
begin
  if p_user is null then
    raise exception 'RP400: a device registration needs a user';
  end if;
  -- APNs tokens are hex; length has changed before and will again, so the
  -- bound is generous and the SHAPE is what is checked.
  if v_token = '' or length(v_token) > 400 or v_token !~ '^[0-9a-fA-F]+$' then
    raise exception 'RP400: device_token must be a hexadecimal APNs token';
  end if;
  if v_env not in ('sandbox','production') then
    raise exception 'RP400: environment must be sandbox or production';
  end if;

  insert into notification_devices as d
    (user_id, device_token, bundle_id, environment, locale, app_version, last_seen_at)
  values
    (p_user, v_token, coalesce(nullif(btrim(p_bundle_id), ''), 'com.rendprop.app'),
     v_env, left(nullif(btrim(p_locale), ''), 32), left(nullif(btrim(p_app_version), ''), 40), now())
  on conflict (device_token) do update set
    -- The token is the identity: a phone handed to another agent must stop
    -- waking the previous one, and a reinstall must un-retire the row.
    user_id         = excluded.user_id,
    bundle_id       = excluded.bundle_id,
    environment     = excluded.environment,
    locale          = coalesce(excluded.locale, d.locale),
    app_version     = coalesce(excluded.app_version, d.app_version),
    last_seen_at    = now(),
    disabled_at     = null,
    disabled_reason = null
  returning * into v_row;

  return v_row;
end;
$notification_register_device$;

revoke execute on function public.notification_register_device(uuid, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.notification_register_device(uuid, text, text, text, text, text)
  to service_role;

comment on function public.notification_register_device(uuid, text, text, text, text, text) is
  'Upsert an APNs token for a user. The TOKEN is the identity: re-registering '
  'one already on file re-points it to the current user and clears any '
  'disabled_at, so a handed-on phone stops waking its previous owner and a '
  'reinstall is not permanently muted. service_role only (POST /me/devices).';

create or replace function public.notification_set_preferences(
  p_user  uuid,
  p_prefs jsonb
) returns public.notification_preferences
language plpgsql
security definer
set search_path = public
as $notification_set_preferences$
declare
  v_row  public.notification_preferences;
  v_mute timestamptz;
  v_key  text;
begin
  if p_user is null then
    raise exception 'RP400: a preference update needs a user';
  end if;
  if p_prefs is null or jsonb_typeof(p_prefs) <> 'object' then
    raise exception 'RP400: preferences must be a JSON object';
  end if;
  -- An unknown key is a client that thinks a category exists which does not.
  -- Refusing is kinder than silently dropping it: the person believes they
  -- turned something off.
  for v_key in select k from jsonb_object_keys(p_prefs) k loop
    if v_key not in ('lead_received','render_ready','upload_stuck',
                     'free_week_ending','allowance_low','first_tour_nudge','muted_until') then
      raise exception 'RP400: unknown notification preference "%"', v_key;
    end if;
  end loop;
  for v_key in select k from jsonb_object_keys(p_prefs) k where k <> 'muted_until' loop
    if jsonb_typeof(p_prefs -> v_key) <> 'boolean' then
      raise exception 'RP400: notification preference "%" must be true or false', v_key;
    end if;
  end loop;
  if p_prefs ? 'muted_until' then
    if jsonb_typeof(p_prefs -> 'muted_until') = 'null' then
      v_mute := null;
    else
      begin
        v_mute := (p_prefs ->> 'muted_until')::timestamptz;
      exception when others then
        raise exception 'RP400: muted_until must be an ISO-8601 timestamp or null';
      end;
    end if;
  end if;

  insert into notification_preferences as p (user_id) values (p_user)
  on conflict (user_id) do nothing;

  update notification_preferences set
    lead_received    = coalesce((p_prefs ->> 'lead_received')::boolean,    lead_received),
    render_ready     = coalesce((p_prefs ->> 'render_ready')::boolean,     render_ready),
    upload_stuck     = coalesce((p_prefs ->> 'upload_stuck')::boolean,     upload_stuck),
    free_week_ending = coalesce((p_prefs ->> 'free_week_ending')::boolean, free_week_ending),
    allowance_low    = coalesce((p_prefs ->> 'allowance_low')::boolean,    allowance_low),
    first_tour_nudge = coalesce((p_prefs ->> 'first_tour_nudge')::boolean, first_tour_nudge),
    -- Only touched when the key is PRESENT, so a call that flips one category
    -- does not silently un-mute a person who asked for quiet.
    muted_until      = case when p_prefs ? 'muted_until' then v_mute else muted_until end,
    updated_at       = now()
  where user_id = p_user
  returning * into v_row;

  return v_row;
end;
$notification_set_preferences$;

revoke execute on function public.notification_set_preferences(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.notification_set_preferences(uuid, jsonb) to service_role;

comment on function public.notification_set_preferences(uuid, jsonb) is
  'Merge a partial preference patch for one user, creating the row if needed. '
  'Any of the six categories can be turned off independently; muted_until is '
  'the global pause and is only touched when the key is present. An unknown key '
  'or a non-boolean value is RP400 rather than a silent drop. service_role only '
  '(PATCH /me/notifications).';

-- ── 7. The queue RPCs ───────────────────────────────────────────────────────

-- notification_preferences_for(): the EFFECTIVE preferences for a person,
-- creating nothing. A missing row answers all-on, which is the same answer the
-- column defaults give — one function so the app's settings screen and the
-- enqueuer can never disagree about what a person who never opened settings
-- has switched on.
create or replace function public.notification_preferences_for(p_user uuid)
returns public.notification_preferences
language plpgsql
stable
security definer
set search_path = public
as $notification_preferences_for$
declare
  v_row public.notification_preferences;
begin
  select * into v_row from notification_preferences where user_id = p_user;
  if found then return v_row; end if;
  v_row.user_id          := p_user;
  v_row.lead_received    := true;
  v_row.render_ready     := true;
  v_row.upload_stuck     := true;
  v_row.free_week_ending := true;
  v_row.allowance_low    := true;
  v_row.first_tour_nudge := true;
  v_row.muted_until      := null;
  v_row.created_at       := null;
  v_row.updated_at       := null;
  return v_row;
end;
$notification_preferences_for$;

revoke execute on function public.notification_preferences_for(uuid) from public, anon, authenticated;
grant execute on function public.notification_preferences_for(uuid) to service_role;

comment on function public.notification_preferences_for(uuid) is
  'The EFFECTIVE preferences for a user, without creating a row: no row means '
  'every category on. Read by GET /me and by notification_enqueue() so the '
  'settings screen and the queue always agree. service_role only.';

-- notification_enqueue(): the ONE way a row gets into the outbox.
--
-- It NEVER raises for an ordinary "we are not going to send this" — a category
-- the person turned off, a global mute, a person with no device and no e-mail
-- address, a key that is already queued. All of those answer `skipped` or
-- `duplicate`, because every caller is inside somebody's business transaction
-- (a lead capture, a publish) and an exception there would cost them the thing
-- they actually came for. The only RP400s are programming errors: an unknown
-- category, a null user.
--
-- CHANNEL CHOICE, and why ONE row: push when the person has at least one live
-- device, e-mail otherwise. One event therefore produces exactly one message
-- per person — a phone that buzzes AND an inbox that fills for the same lead is
-- how a useful alert becomes noise.
create or replace function public.notification_enqueue(
  p_org           uuid,
  p_user          uuid,
  p_category      text,
  p_payload       jsonb       default '{}'::jsonb,
  p_dedupe_key    text        default null,
  p_scheduled_for timestamptz default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $notification_enqueue$
declare
  v_cat     text := lower(btrim(coalesce(p_category, '')));
  v_key     text;
  v_pref    public.notification_preferences;
  v_on      boolean;
  v_channel text;
  v_row     public.notification_outbox;
  v_existing uuid;
begin
  if v_cat not in ('lead_received','render_ready','upload_stuck',
                   'free_week_ending','allowance_low','first_tour_nudge') then
    raise exception 'RP400: unknown notification category "%"', p_category;
  end if;
  if p_user is null then
    raise exception 'RP400: a notification needs a recipient';
  end if;

  -- A producer that forgets its key still cannot double-send its own retry,
  -- but it gets no cross-call protection either — so every producer in this
  -- file passes one explicitly, and this fallback exists only so the column's
  -- NOT NULL can never be the reason a lead insert fails.
  v_key := coalesce(nullif(btrim(p_dedupe_key), ''),
                    v_cat || ':' || coalesce(p_org::text, '-') || ':' || p_user::text
                          || ':' || gen_random_uuid()::text);

  v_pref := notification_preferences_for(p_user);
  v_on := case v_cat
            when 'lead_received'    then v_pref.lead_received
            when 'render_ready'     then v_pref.render_ready
            when 'upload_stuck'     then v_pref.upload_stuck
            when 'free_week_ending' then v_pref.free_week_ending
            when 'allowance_low'    then v_pref.allowance_low
            when 'first_tour_nudge' then v_pref.first_tour_nudge
          end;
  if v_on is not true then
    return jsonb_build_object('state', 'skipped', 'reason', 'category_off',
                              'category', v_cat, 'dedupe_key', v_key, 'id', null);
  end if;
  if v_pref.muted_until is not null and v_pref.muted_until > now() then
    return jsonb_build_object('state', 'skipped', 'reason', 'muted',
                              'category', v_cat, 'dedupe_key', v_key, 'id', null);
  end if;

  if exists (select 1 from notification_devices d
              where d.user_id = p_user and d.disabled_at is null) then
    v_channel := 'push';
  elsif exists (select 1 from profiles pr
                 where pr.id = p_user and coalesce(btrim(pr.email), '') <> '') then
    v_channel := 'email';
  else
    -- No phone registered and no address on file. Not an error — a workspace
    -- whose owner signed in anonymously is exactly this — and not a row either.
    return jsonb_build_object('state', 'skipped', 'reason', 'no_channel',
                              'category', v_cat, 'dedupe_key', v_key, 'id', null);
  end if;

  insert into notification_outbox
    (org_id, user_id, category, channel, dedupe_key, payload, scheduled_for)
  values
    (p_org, p_user, v_cat, v_channel, v_key,
     coalesce(p_payload, '{}'::jsonb), coalesce(p_scheduled_for, now()))
  on conflict (dedupe_key) do nothing
  returning * into v_row;

  if not found then
    select id into v_existing from notification_outbox where dedupe_key = v_key;
    return jsonb_build_object('state', 'duplicate', 'reason', 'dedupe_key',
                              'category', v_cat, 'dedupe_key', v_key, 'id', v_existing);
  end if;

  return jsonb_build_object('state', 'queued', 'reason', null, 'category', v_cat,
                            'channel', v_channel, 'dedupe_key', v_key, 'id', v_row.id);
end;
$notification_enqueue$;

revoke execute on function public.notification_enqueue(uuid, uuid, text, jsonb, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.notification_enqueue(uuid, uuid, text, jsonb, text, timestamptz)
  to service_role;

comment on function public.notification_enqueue(uuid, uuid, text, jsonb, text, timestamptz) is
  'The only writer of notification_outbox. Answers {state: queued|skipped|'
  'duplicate, reason, id, channel, dedupe_key} and NEVER raises for an ordinary '
  'refusal — a category the person switched off, an active muted_until, nobody '
  'to reach, or a dedupe_key already queued — because every caller is inside a '
  'lead capture or a publish and must not lose it. Picks ONE channel: push when '
  'the person has a live device, e-mail otherwise. service_role only.';

-- notification_claim_batch(): what makes concurrent drains safe.
--
-- The inner SELECT takes FOR UPDATE SKIP LOCKED on the due rows, so a second
-- drain running at the same moment simply does not see them and takes the next
-- ones instead. The UPDATE then flips them to `sending` and stamps claimed_at,
-- which is what notification_sweep() later uses to tell a send in flight from a
-- drain that died. `as materialized` is not decoration: an inlined CTE would
-- lose the locking clause's guarantee about which rows the UPDATE touches.
create or replace function public.notification_claim_batch(p_limit integer default 25)
returns setof public.notification_outbox
language plpgsql
security definer
set search_path = public
as $notification_claim_batch$
declare
  v_limit integer := greatest(1, least(200, coalesce(p_limit, 25)));
begin
  return query
  with claimed as materialized (
    select o.id
      from notification_outbox o
     where o.state = 'queued'
       and o.scheduled_for <= now()
     order by o.scheduled_for, o.created_at
     for update skip locked
     limit v_limit
  )
  update notification_outbox o
     set state      = 'sending',
         attempts   = o.attempts + 1,
         claimed_at = now(),
         last_error = null
    from claimed c
   where o.id = c.id
  returning o.*;
end;
$notification_claim_batch$;

revoke execute on function public.notification_claim_batch(integer) from public, anon, authenticated;
grant execute on function public.notification_claim_batch(integer) to service_role;

comment on function public.notification_claim_batch(integer) is
  'Claim up to p_limit (1…200) due rows: locks them FOR UPDATE SKIP LOCKED, '
  'flips them to sending, bumps attempts, stamps claimed_at and returns them. '
  'Two concurrent drains therefore hand every row to exactly one of them. '
  'service_role only.';

-- notification_mark(): close a claimed row.
--
-- ONE DELIBERATE ASYMMETRY, stated because a caller can be surprised by it:
-- p_state is honoured exactly as given for sent / skipped / expired / queued,
-- but `failed` is a RETRY while attempts are left. A provider 500 or a dropped
-- connection is not a permanent failure, and the drain has no business
-- implementing a backoff policy of its own — so `failed` becomes `queued` with
-- a widening delay until NOTIFICATION_MAX_ATTEMPTS, and only then sticks. The
-- returned row always says what actually happened.
create or replace function public.notification_mark(
  p_id          uuid,
  p_state       text,
  p_error       text default null,
  p_provider_id text default null
) returns public.notification_outbox
language plpgsql
security definer
set search_path = public
as $notification_mark$
declare
  v_max   constant integer := 5;
  v_state text := lower(btrim(coalesce(p_state, '')));
  v_row   public.notification_outbox;
  v_err   text := left(nullif(btrim(coalesce(p_error, '')), ''), 500);
begin
  if v_state not in ('queued','sent','failed','skipped','expired') then
    raise exception 'RP400: state must be queued, sent, failed, skipped or expired';
  end if;
  select * into v_row from notification_outbox where id = p_id for update;
  if not found then
    raise exception 'RP404: outbox row not found';
  end if;

  if v_state = 'sent' then
    update notification_outbox
       set state = 'sent', sent_at = now(), last_error = null, claimed_at = null
     where id = p_id returning * into v_row;
    -- The permanent, content-free record. Written here and nowhere else, so
    -- "delivered" always means "a provider accepted it".
    insert into notification_log (category, channel, org_id, user_id, sent_at, provider_message_id)
    values (v_row.category, v_row.channel, v_row.org_id, v_row.user_id, v_row.sent_at,
            left(nullif(btrim(coalesce(p_provider_id, '')), ''), 200));

  elsif v_state = 'failed' and v_row.attempts < v_max then
    update notification_outbox
       set state         = 'queued',
           -- 1, 4, 9, 16 minutes: long enough for a provider blip to clear,
           -- short enough that a lead is still news when it lands.
           scheduled_for = now() + make_interval(mins => greatest(1, v_row.attempts * v_row.attempts)),
           last_error    = v_err,
           claimed_at    = null
     where id = p_id returning * into v_row;

  else
    update notification_outbox
       set state      = v_state,
           last_error = v_err,
           claimed_at = case when v_state = 'queued' then null else claimed_at end
     where id = p_id returning * into v_row;
  end if;

  return v_row;
end;
$notification_mark$;

revoke execute on function public.notification_mark(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.notification_mark(uuid, text, text, text) to service_role;

comment on function public.notification_mark(uuid, text, text, text) is
  'Close a claimed outbox row. sent → stamps sent_at and writes the permanent '
  'notification_log entry. failed → RETRIES (back to queued with a 1/4/9/16-minute '
  'backoff) while attempts < 5, and only then sticks as failed. skipped/expired/'
  'queued are stored verbatim. Returns the row as it now stands. service_role only.';

-- notification_sweep(): the janitor the drain cannot be.
--
--   • A `sending` row older than 10 minutes is a drain that died holding it —
--     an isolate that was recycled, a deploy mid-batch. Nothing else will ever
--     move it, so it goes back to `queued` (its attempts count is kept, so a
--     row that keeps killing its drain still stops eventually via mark()).
--   • A `queued` row whose scheduled_for is more than 72 hours in the past is
--     no longer worth sending. "A buyer enquired about your listing" three days
--     late is not a service, it is confusion, and an expired row is honest
--     about that instead of silently sitting in the queue forever.
create or replace function public.notification_sweep()
returns jsonb
language plpgsql
security definer
set search_path = public
as $notification_sweep$
declare
  v_stale_after  constant interval := interval '10 minutes';
  v_expire_after constant interval := interval '72 hours';
  v_reclaimed integer := 0;
  v_expired   integer := 0;
begin
  with reclaimed as (
    update notification_outbox
       set state      = 'queued',
           claimed_at = null,
           last_error = 'reclaimed by notification_sweep after a stalled send'
     where state = 'sending'
       and claimed_at is not null
       and claimed_at < now() - v_stale_after
    returning 1
  ) select count(*) into v_reclaimed from reclaimed;

  with expired as (
    update notification_outbox
       set state      = 'expired',
           claimed_at = null,
           last_error = 'expired by notification_sweep: past its usefulness'
     where state = 'queued'
       and scheduled_for < now() - v_expire_after
    returning 1
  ) select count(*) into v_expired from expired;

  return jsonb_build_object(
    'reclaimed', v_reclaimed,
    'expired',   v_expired,
    'swept_at',  to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
end;
$notification_sweep$;

revoke execute on function public.notification_sweep() from public, anon, authenticated;
grant execute on function public.notification_sweep() to service_role;

comment on function public.notification_sweep() is
  'Returns sending rows stuck over 10 minutes to queued (a drain died holding '
  'them; nothing else would ever move them) and expires queued rows more than '
  '72 hours past their scheduled_for. Answers {reclaimed, expired, swept_at}. '
  'Called by notification_tick(); service_role only.';

-- notification_disable_device(): the APNs 410 path.
--
-- Apple answering 410 Unregistered or 400 BadDeviceToken means the app is gone
-- from that device. Retrying is not just useless, it is how a queue fills with
-- rows that can never succeed. The row is retired, not deleted: the evidence
-- that this install existed is worth more than the byte.
create or replace function public.notification_disable_device(
  p_token  text,
  p_reason text default null
) returns integer
language plpgsql
security definer
set search_path = public
as $notification_disable_device$
declare
  v_n integer := 0;
begin
  update notification_devices
     set disabled_at     = now(),
         disabled_reason = left(coalesce(nullif(btrim(p_reason), ''), 'rejected by APNs'), 200)
   where device_token = btrim(coalesce(p_token, ''))
     and disabled_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end;
$notification_disable_device$;

revoke execute on function public.notification_disable_device(text, text) from public, anon, authenticated;
grant execute on function public.notification_disable_device(text, text) to service_role;

comment on function public.notification_disable_device(text, text) is
  'Retire a device token APNs rejected as gone (410 Unregistered / 400 '
  'BadDeviceToken). Returns how many rows were disabled. Rows are never '
  'deleted. service_role only.';

-- ── 8. The lead trigger — the message that saves the subscription ───────────
--
-- AFTER INSERT ROW on `leads`, so it catches every writer (the public capture
-- route today, anything else tomorrow) and so the lead's own id is available as
-- the dedupe key. Recipients are the org's owners and admins: an `agent` seat
-- works a listing but the inbox belongs to the person whose business it is, and
-- `marketing` is read-only by design (0006 §2) and gets nothing.
--
-- The enqueue is wrapped per recipient in its own exception block. A lead is
-- the product; a notification is a courtesy. If the courtesy throws — a missing
-- profile row, a constraint nobody anticipated — the lead still commits and the
-- server logs a warning.

create or replace function public.notification_on_lead_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $notification_on_lead_insert$
declare
  v_address text;
  v_slug    text;
  v_member  record;
begin
  if new.org_id is null then
    -- The demo tour (slug estate-demo) captures leads with no org. Nobody to tell.
    return new;
  end if;

  select l.address into v_address from listings l where l.id = new.listing_id;
  select r.slug    into v_slug    from renders  r where r.id = new.render_id;

  for v_member in
    select m.user_id
      from memberships m
     where m.org_id = new.org_id
       and m.role in ('owner','admin')
  loop
    begin
      perform notification_enqueue(
        new.org_id,
        v_member.user_id,
        'lead_received',
        jsonb_build_object(
          -- A PATH, not a URL: the drain owns the public base (TOUR_PUBLIC_BASE_URL)
          -- so a domain change does not have to rewrite queued rows.
          'deep_link', case when v_slug is not null then '/f/' || v_slug else null end,
          'data', jsonb_build_object(
            'lead_id',         new.id,
            'lead_name',       nullif(btrim(coalesce(new.name, '')), ''),
            'has_phone',       (new.phone is not null),
            'has_email',       (new.email is not null),
            'listing_id',      new.listing_id,
            'listing_address', v_address,
            'slug',            v_slug)),
        'lead_received:' || new.id::text || ':' || v_member.user_id::text,
        null);
    exception when others then
      raise warning '0047: lead_received enqueue failed for lead % / user % (% — %)',
        new.id, v_member.user_id, sqlstate, sqlerrm;
    end;
  end loop;

  return new;
end;
$notification_on_lead_insert$;

comment on function public.notification_on_lead_insert() is
  'AFTER INSERT trigger on leads: queues a lead_received message for every '
  'owner/admin of the org (never for a marketing seat), keyed on the lead id so '
  'a replay cannot double-send. Each enqueue is wrapped in its own exception '
  'block — a notification failure must never roll back a captured lead.';

drop trigger if exists trg_leads_notify on public.leads;
create trigger trg_leads_notify
  after insert on public.leads
  for each row execute function public.notification_on_lead_insert();

-- ── 9. publish_render(): queue render_ready ────────────────────────────────
--
-- Reproduced VERBATIM from 0046 §3 (the LATEST definition of this function).
-- Signature, security definer, search_path, the role check, the anti-spoof
-- poster rule, the advisory lock, the idempotent replay path, the duration
-- bound, the staged-outcome derivation, chapters, slug allocation, 0046's
-- activation stamp and the grants are all UNCHANGED. The only edits are marked
-- `0047:` — one added declaration and the enqueue block at the end.
--
-- It sits at the very end, on the NON-replay path only: the idempotent replay
-- above returns before reaching it, so a retry of the same publish cannot
-- re-queue anything either. (The dedupe key would refuse it a second time
-- regardless — belt and braces, the same way 0046's stamp is written.)

create or replace function public.publish_render(
  p_job uuid,
  p_duration numeric default null,
  p_speed numeric default 2.0,
  p_chapters jsonb default '[]'::jsonb,
  p_poster_asset uuid default null
) returns public.renders
language plpgsql
security definer
set search_path = public
as $publish_render$
declare
  v_job render_jobs;
  v_org uuid;
  v_role text;
  v_asset capture_assets;
  v_poster capture_assets;
  v_poster_key text := null;
  v_render renders;
  v_slug text;
  v_dur numeric;
  v_staged boolean;
  v_style text;
  attempt integer;
  -- 0047: recipients of the render_ready message. Never returned; the function's
  -- return type is byte-identical to 0046's.
  v_member record;
begin
  select rj.* into v_job from render_jobs rj where rj.id = p_job;
  if not found then raise exception 'RP404: render job not found'; end if;
  select l.org_id into v_org from listings l where l.id = v_job.listing_id and l.deleted_at is null;
  if v_org is null then raise exception 'RP404: listing not found'; end if;

  v_role := org_role(v_org);
  if v_role is null then raise exception 'RP403: not a member of this workspace'; end if;
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit publishing renders';
  end if;

  -- Poster: SERVER-DERIVED key from an asset the caller could only have created
  -- through /uploads {role:"render", kind:"photo"} for this same listing. A free
  -- string here would let a caller point og:image at anything in the bucket.
  if p_poster_asset is not null then
    select a.* into v_poster from capture_assets a where a.id = p_poster_asset;
    if not found
       or v_poster.listing_id <> v_job.listing_id
       or coalesce(v_poster.bucket, 'uploads') <> 'renders'
       or v_poster.uploaded is not true
       or v_poster.kind <> 'photo' then
      raise exception 'RP400: poster_asset_id must be an uploaded photo in the renders bucket for this listing';
    end if;
    v_poster_key := v_poster.storage_key;
  end if;

  -- Serialize per job, then re-check: concurrent publishes previously raced the
  -- unique(job_id) index and surfaced RP500 instead of the existing render.
  perform pg_advisory_xact_lock(hashtextextended('publish_render:' || p_job::text, 42));
  select r.* into v_render from renders r where r.job_id = p_job;
  if found then
    -- Idempotent replay. A retry that now carries a poster completes the earlier
    -- poster-less publish instead of being ignored.
    if v_poster_key is not null and v_render.poster_key is null then
      update renders set poster_key = v_poster_key where id = v_render.id returning * into v_render;
    end if;
    return v_render;
  end if;

  if v_job.capture_asset_id is null then raise exception 'RP400: job has no capture asset'; end if;
  select a.* into v_asset from capture_assets a where a.id = v_job.capture_asset_id;
  if not found then raise exception 'RP404: capture asset not found'; end if;
  if coalesce(v_asset.bucket, 'uploads') <> 'renders' then
    raise exception 'RP400: the job asset is not a role=render upload';
  end if;
  if v_asset.uploaded is not true then
    raise exception 'RP409: the render upload is not complete';
  end if;

  v_dur := coalesce(p_duration, v_asset.duration_s);
  if v_dur is null or v_dur <= 0 or v_dur > 7200 then
    raise exception 'RP400: duration_s is required (0 < s <= 7200)';
  end if;

  -- ── VIRTUAL-STAGING DISCLOSURE — SERVER-DERIVED, the caller gets no say ────
  -- `renders.staged` is a LEGAL DISCLOSURE, not a feature flag: it drives the
  -- "✦ Virtually staged" chip and the disclosure sheet on the public tour
  -- (services/edge/tour-host/src/player.ts). Under MLS virtual-media rules and
  -- California AB 723, getting it wrong is a compliance failure in BOTH
  -- directions — stamping a tour whose pixels were never altered is false
  -- advertising of an add-on that did not run; failing to stamp one that WAS
  -- altered is a disclosure violation. So the flag follows the OUTCOME the
  -- pipeline reports, and where no outcome exists it follows whichever answer
  -- cannot under-disclose:
  --
  --   1. enhancement_result carries `staged` → the worker MEASURED what it
  --      shipped (a segment passed QC and an edit landed). Trust it in both
  --      directions. This is the F-G-01 #2 / F-G-09 fix: before 0016 a tour was
  --      stamped because the user ticked a box, even when the pipeline skipped,
  --      QC denied the edit, the spend ceiling stopped it, or no worker was
  --      reachable at all.
  --   2. source='app' with no outcome → FALSE. An app publish is the phone's
  --      own on-device render, uploaded through /uploads role=render; no AI
  --      pipeline exists on that path (iOS decision A5 — Enhancements always
  --      ships `declutter:false, style:.asIs`), so nothing was altered and
  --      stamping it is exactly the false-advertising failure above. Photo-level
  --      edits made through /ai-enhance are disclosed separately and per-asset
  --      through media_provenance (0012); they are not this tour-level flag.
  --   3. source='worker' with no outcome → the pre-0016 intent-derived rule,
  --      byte-for-byte unchanged. A worker that died before writing its result,
  --      or one too old to write the column at all, must not silently turn a
  --      REAL virtual staging into an undisclosed one. Falling back to the
  --      requested toggles can only over-disclose, which is the survivable
  --      direction — and it is what this function does today, so the worker
  --      path does not regress.
  v_style := lower(trim(coalesce(v_job.enhancements->>'style', '')));
  if v_job.enhancement_result is not null and v_job.enhancement_result ? 'staged' then
    v_staged := coalesce((v_job.enhancement_result->>'staged')::boolean, false);
  elsif coalesce(v_job.source, 'worker') = 'app' then
    v_staged := false;
  else
    v_staged := coalesce((v_job.enhancements->>'declutter')::boolean, false)
                or (v_style <> '' and v_style not in ('as_is','as-is','asis','none'));
  end if;

  perform replace_asset_chapters(v_asset.id, p_chapters);

  for attempt in 1..6 loop
    v_slug := (
      select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', (random()*30)::integer + 1, 1), '')
      from generate_series(1, 10)
    );
    begin
      insert into renders (job_id, listing_id, slug, duration_s, speed_factor,
                           video_key, stream_uid, poster_key, staged, published_at)
      values (v_job.id, v_job.listing_id, v_slug, v_dur,
              greatest(0.25, least(8.0, coalesce(p_speed, 2.0))),
              v_asset.storage_key, null, v_poster_key, v_staged, now())
      returning * into v_render;
      exit;
    exception when unique_violation then
      if attempt = 6 then raise exception 'RP500: could not allocate a unique slug'; end if;
    end;
  end loop;

  -- 0046: the ACTIVATION fact, written exactly once. `coalesce` in the SET and
  -- `is null` in the WHERE both say the same thing on purpose — a later publish
  -- must never move the first one, and neither form alone survives a careless
  -- edit of the other.
  update orgs
     set first_tour_published_at = coalesce(first_tour_published_at, v_render.published_at)
   where id = v_org
     and first_tour_published_at is null;

  update render_jobs
     set status = 'ready', progress = 1, finished_at = now(), error = null
   where id = v_job.id;
  update listings set status = 'ready' where id = v_job.listing_id;

  -- 0047: "your tour is ready". LAST, after the job and listing are actually
  -- marked ready, so a message can never describe a state that has not been
  -- written yet. Its own exception block: a publish is the customer's work and
  -- must never be lost to a messaging fault.
  begin
    for v_member in
      select m.user_id from memberships m
       where m.org_id = v_org and m.role in ('owner','admin')
    loop
      perform notification_enqueue(
        v_org, v_member.user_id, 'render_ready',
        jsonb_build_object(
          'deep_link', '/f/' || v_render.slug,
          'data', jsonb_build_object(
            'render_id',       v_render.id,
            'slug',            v_render.slug,
            'listing_id',      v_render.listing_id,
            'listing_address', (select l.address from listings l where l.id = v_render.listing_id),
            'source',          coalesce(v_job.source, 'worker'))),
        'render_ready:' || v_render.id::text || ':' || v_member.user_id::text,
        null);
    end loop;
  exception when others then
    raise warning '0047: render_ready enqueue failed for render % (% — %)',
      v_render.id, sqlstate, sqlerrm;
  end;

  return v_render;
end;
$publish_render$;

revoke execute on function public.publish_render(uuid, numeric, numeric, jsonb, uuid) from public, anon;
grant  execute on function public.publish_render(uuid, numeric, numeric, jsonb, uuid) to authenticated, service_role;

-- ── 10. publish_worker_render(): the other publish path, same message ───────
--
-- Reproduced VERBATIM from 0046 §4 (itself 0035's body plus 0046's stamp).
-- Signature, security invoker, the empty search_path, the service_role guard,
-- the envelope bounds, the listing→job→render lock order, the exact-replay
-- receipt comparison, the lease fences, the scalar canonicalisation, the photo
-- validation and the grants are all UNCHANGED. The only edits are marked
-- `0047:` — one added declaration and the enqueue block.
--
-- WHERE THE ENQUEUE SITS, and why it is not a trigger: AFTER the FINAL lease
-- re-check. Both earlier fences can still roll this entire transaction back, so
-- anything queued before them could describe a publication that never happened.
-- A row trigger on `renders` fires at the write — inside the fence, before it
-- closes — and would also fire on 0035's recovery UPDATE and on
-- unpublish_deleted_listing_renders()'s un-publish. The call site knows exactly
-- what happened; a trigger would have to guess.
--
-- NOTE FOR WHOEVER RUNS THE AUDIT HARNESS: run_database_regression.py mutates
-- 0035 in a disposable database and "restores" it by re-applying that FILE, so
-- inside that one run the function reverts to the 0035 body (without 0046's
-- stamp and without this enqueue) after the publication fixture. Nothing
-- downstream in that run depends on either, and production keeps this body
-- because migrations apply in order. Do not "fix" it by moving them back out.

create or replace function public.publish_worker_render(
  p_job uuid,
  p_worker text,
  p_attempt integer,
  p_render jsonb,
  p_enhancement_result jsonb,
  p_photos jsonb default '[]'::jsonb
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $publish_worker_render$
declare
  v_listing_id uuid;
  v_listing public.listings;
  v_job public.render_jobs;
  v_render public.renders;
  v_id uuid;
  v_slug text;
  v_prefix text;
  v_request jsonb;
  v_receipt jsonb;
  v_photo jsonb;
  v_duration numeric;
  v_speed numeric;
  v_staged boolean;
  v_constraint text;
  v_try integer;
  -- 0047: recipients of the render_ready message. Never returned; the jsonb
  -- envelope this function answers with is byte-identical to 0046's.
  v_member record;
begin
  -- Grants are the boundary; this explicit guard also prevents accidental future
  -- EXECUTE grants from making an ordinary member's chosen worker_id authoritative.
  if current_user <> 'service_role' then
    raise exception using errcode = '42501', message = 'worker publication requires service_role';
  end if;
  if p_worker is null or length(p_worker) not between 1 and 200
     or p_attempt is null or p_attempt < 1
     or jsonb_typeof(p_render) is distinct from 'object'
     or jsonb_typeof(p_enhancement_result) is distinct from 'object'
     or jsonb_typeof(p_photos) is distinct from 'array' then
    raise exception using errcode = 'WP003', message = 'invalid worker publication envelope';
  end if;
  if jsonb_array_length(p_photos) > 100
     or octet_length(p_render::text) + octet_length(p_enhancement_result::text)
        + octet_length(p_photos::text) > 262144 then
    raise exception using errcode = 'WP003', message = 'worker publication envelope exceeds bounds';
  end if;

  -- Listing first, then job, then render/photos: a soft-delete already locks
  -- the listing before unpublishing renders. Sharing that order prevents an
  -- inverse-lock deadlock and prevents publication from undoing a tombstone.
  select listing_id into v_listing_id from public.render_jobs where id = p_job;
  select * into v_listing from public.listings where id = v_listing_id for update;
  if not found or v_listing.deleted_at is not null then
    raise exception using errcode = 'WP001', message = 'worker publication listing is unavailable';
  end if;
  select * into v_job from public.render_jobs where id = p_job for update;
  if not found or v_job.listing_id is distinct from v_listing_id
     or v_job.source is distinct from 'worker'
     or v_job.worker_id is distinct from p_worker
     or v_job.attempts is distinct from p_attempt then
    raise exception using errcode = 'WP001', message = 'worker publication claim is no longer owned';
  end if;
  v_request := jsonb_build_object('render', p_render,
    'enhancement_result', p_enhancement_result, 'photos', p_photos);

  if v_job.status = 'ready' then
    v_receipt := v_job.worker_publish_receipt;
    select * into v_render from public.renders where job_id = p_job;
    -- A successful exact replay is read-only, even after its former lease
    -- expires. A different output from the same process/attempt is NOT a retry.
    if not found or v_receipt is null
       or v_receipt->'request' is distinct from v_request
       or v_receipt->>'worker_id' is distinct from p_worker
       or v_receipt->'attempt' is distinct from to_jsonb(p_attempt)
       or v_receipt->'render' is distinct from to_jsonb(v_render) then
      raise exception using errcode = 'WP002', message = 'worker publication conflicts with the committed output';
    end if;
    return jsonb_build_object('job_id', p_job, 'status', 'ready', 'render', to_jsonb(v_render), 'receipt', v_receipt);
  end if;
  -- clock_timestamp(), not now(): a call may have waited for either row lock.
  -- The time when its transaction BEGAN is not proof its lease is still alive.
  if v_job.status is distinct from 'processing'
     or v_job.lease_expires_at is null or v_job.lease_expires_at <= clock_timestamp() then
    raise exception using errcode = 'WP001', message = 'worker publication lease is expired or job is not processing';
  end if;
  if not exists (select 1 from public.capture_assets a
    where a.id = v_job.capture_asset_id and a.listing_id = v_listing_id
      and a.kind = 'video' and a.uploaded is true and coalesce(a.bucket, 'uploads') = 'uploads') then
    raise exception using errcode = 'WP003', message = 'worker publication requires an uploaded raw video capture';
  end if;

  begin
    v_id := (p_render->>'id')::uuid;
    v_duration := (p_render->>'duration_s')::numeric;
    v_speed := (p_render->>'speed_factor')::numeric;
    v_staged := (p_enhancement_result->>'staged')::boolean;
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = 'WP003', message = 'invalid worker publication scalar';
  end;
  v_slug := p_render->>'slug';
  v_prefix := 'renders/' || v_listing_id::text || '/' || v_id::text;
  -- The persisted numeric columns have two decimal places. Reject coercion
  -- rather than commit 30.001 as 30.00 and disagree with the exact receipt.
  -- Existing chk_renders_duration already rejects 0.004 rounding to zero.
  if v_id is null or v_slug is null or v_slug !~ '^[a-zA-Z0-9_-]{6,80}$'
     or jsonb_typeof(p_render->'duration_s') is distinct from 'number'
     or jsonb_typeof(p_render->'speed_factor') is distinct from 'number'
     or v_duration is null or not (v_duration > 0 and v_duration <= 7200)
     or v_speed is null or not (v_speed >= 0.25 and v_speed <= 8)
     or round(v_duration, 2) is distinct from v_duration
     or round(v_speed, 2) is distinct from v_speed
     or jsonb_typeof(p_enhancement_result->'staged') is distinct from 'boolean'
     or jsonb_typeof(p_enhancement_result->'ran') is distinct from 'boolean'
     or p_render->>'video_key' is distinct from v_prefix || '.mp4'
     or p_render->>'poster_key' is distinct from v_prefix || '-poster.jpg'
     or (p_render->>'hero_key' is not null and p_render->>'hero_key' <> v_prefix || '-hero.mp4')
     or length(coalesce(p_render->>'stream_uid', '')) > 200 then
    raise exception using errcode = 'WP003', message = 'invalid worker publication media or outcome';
  end if;

  select * into v_render from public.renders where job_id = p_job for update;
  if found then
    -- Recovery of a pre-0035 partial publish keeps the customer's existing URL.
    -- Only the current fenced attempt can replace it; ready jobs were handled above.
    update public.renders set duration_s = v_duration, speed_factor = v_speed,
      video_key = p_render->>'video_key', poster_key = p_render->>'poster_key',
      stream_uid = p_render->>'stream_uid', hero_key = p_render->>'hero_key',
      staged = v_staged, published_at = clock_timestamp()
    where id = v_render.id returning * into v_render;
  else
    for v_try in 1..5 loop
      begin
        insert into public.renders (id, job_id, listing_id, slug, duration_s, speed_factor,
          video_key, stream_uid, poster_key, hero_key, staged, published_at)
        values (v_id, p_job, v_listing_id, v_slug, v_duration, v_speed,
          p_render->>'video_key', p_render->>'stream_uid', p_render->>'poster_key',
          p_render->>'hero_key', v_staged, clock_timestamp()) returning * into v_render;
        exit;
      exception when unique_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint <> 'renders_slug_key' or v_try = 5 then raise; end if;
        v_slug := left(replace(gen_random_uuid()::text, '-', ''), 12);
      end;
    end loop;
  end if;

  -- 0046: the same ACTIVATION fact as publish_render(), written exactly once.
  -- A pre-0035 partial publish being recovered above is still this workspace's
  -- first tour if nothing else ever published, so the stamp covers both arms.
  update public.orgs
     set first_tour_published_at = coalesce(first_tour_published_at, v_render.published_at)
   where id = v_listing.org_id
     and first_tour_published_at is null;

  for v_photo in select value from jsonb_array_elements(p_photos) loop
    if jsonb_typeof(v_photo) is distinct from 'object'
       or v_photo->>'listing_id' is distinct from v_listing_id::text
       or v_photo->'is_staged' is distinct from 'true'::jsonb
       or v_photo->>'enhanced_key' is null
       or v_photo->>'enhanced_key' !~ ('^' || v_prefix || '-staged-[0-9]+[.]jpg$')
       or (v_photo->>'original_key' is not null and
         v_photo->>'original_key' !~ ('^' || v_prefix || '-staged-[0-9]+-orig[.]jpg$')) then
      raise exception using errcode = 'WP003', message = 'invalid worker publication photo';
    end if;
    insert into public.photos (listing_id, original_key, enhanced_key, is_staged, caption, sort)
    values (v_listing_id, v_photo->>'original_key', v_photo->>'enhanced_key', true,
      v_photo->>'caption', (v_photo->>'sort')::smallint);
  end loop;

  -- An unrelated constraint/trigger may have delayed a write. Recheck at the
  -- final state transition so expiry during that wait rolls every row back.
  if v_job.lease_expires_at <= clock_timestamp() then
    raise exception using errcode = 'WP001', message = 'worker publication lease expired during transaction';
  end if;

  v_receipt := jsonb_build_object('version', 1, 'job_id', p_job, 'worker_id', p_worker,
    'attempt', p_attempt, 'request', v_request, 'render', to_jsonb(v_render));
  update public.render_jobs set enhancement_result = p_enhancement_result,
    worker_publish_receipt = v_receipt, status = 'ready', current_step = 'ready',
    progress = 1, finished_at = clock_timestamp(), error = null
  where id = p_job;
  update public.listings set status = 'ready' where id = v_listing_id;
  -- Final-row triggers can wait too. The pre-transition check alone cannot
  -- prove these last writes completed before expiry; roll them all back if not.
  if v_job.lease_expires_at <= clock_timestamp() then
    raise exception using errcode = 'WP001', message = 'worker publication lease expired during final state writes';
  end if;

  -- 0047: "your tour is ready", AFTER the final lease fence — see the header.
  -- Schema-qualified because this function runs with an EMPTY search_path.
  begin
    for v_member in
      select m.user_id from public.memberships m
       where m.org_id = v_listing.org_id and m.role in ('owner','admin')
    loop
      perform public.notification_enqueue(
        v_listing.org_id, v_member.user_id, 'render_ready',
        jsonb_build_object(
          'deep_link', '/f/' || v_render.slug,
          'data', jsonb_build_object(
            'render_id',       v_render.id,
            'slug',            v_render.slug,
            'listing_id',      v_render.listing_id,
            'listing_address', v_listing.address,
            'source',          'worker')),
        'render_ready:' || v_render.id::text || ':' || v_member.user_id::text,
        null);
    end loop;
  exception when others then
    raise warning '0047: render_ready enqueue failed for worker render % (% — %)',
      v_render.id, sqlstate, sqlerrm;
  end;

  return jsonb_build_object('job_id', p_job, 'status', 'ready', 'render', to_jsonb(v_render), 'receipt', v_receipt);
end;
$publish_worker_render$;

revoke execute on function public.publish_worker_render(uuid, text, integer, jsonb, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.publish_worker_render(uuid, text, integer, jsonb, jsonb, jsonb)
  to service_role;

-- ── 11. notification_tick() — the four scheduled messages ───────────────────
--
-- ONE function, called every 15 minutes (§12). Everything it produces is
-- dedupe-keyed on the FACT that justifies it, so a re-run — a cron catch-up, a
-- hand invocation, two schedulers briefly overlapping — writes nothing new.
-- Each category is bounded (500 recipients per run) so one pathological query
-- cannot turn a tick into an outage; the next tick picks up the rest because
-- the predicates are all "still true right now", not "new since last time".
--
--   free_week_ending  orgs on `trial` whose trial_ends_at is inside the next
--                     48 hours. Keyed on the trial-end INSTANT, so extending a
--                     trial legitimately produces a second message and a
--                     re-run of the same window does not.
--   allowance_low     an org past 80% of any metered cap in the CURRENT period.
--                     The four AI meters come from rate_limits (their window is
--                     the period); worker renders are calendar-month scoped,
--                     the same window create_render_job() enforces. Keyed on
--                     (feature, period), so it can fire again next period.
--   first_tour_nudge  a REAL org (org_is_real — 0046 §6, the non-orphan
--                     predicate, because handle_new_user() mints an org on
--                     every anonymous signup) created 48–72 hours ago that has
--                     never published. Keyed on the org alone: once, ever.
--   upload_stuck      an open upload reservation past its deadline. Sent to the
--                     person who started it, and only if they are still a
--                     member of the org. Keyed on the asset: once, ever.
--
-- Finally it calls notification_sweep(), so a dead drain's batch is recovered
-- on the same 15-minute heartbeat instead of needing a second schedule.

create or replace function public.notification_tick()
returns jsonb
language plpgsql
security definer
set search_path = public
as $notification_tick$
declare
  v_cap     constant integer := 500;
  v_rec     record;
  v_res     jsonb;
  n_trial   integer := 0;
  n_allow   integer := 0;
  n_nudge   integer := 0;
  n_stuck   integer := 0;
  v_sweep   jsonb;
begin
  -- ── free_week_ending ──────────────────────────────────────────────────────
  for v_rec in
    select o.id as org_id, o.trial_ends_at, m.user_id
      from orgs o
      join memberships m on m.org_id = o.id and m.role in ('owner','admin')
     where o.deleted_at is null
       and o.plan = 'trial'
       and o.trial_ends_at is not null
       and o.trial_ends_at > now()
       and o.trial_ends_at <= now() + interval '48 hours'
       and org_is_real(o.id)
     order by o.trial_ends_at
     limit v_cap
  loop
    v_res := notification_enqueue(
      v_rec.org_id, v_rec.user_id, 'free_week_ending',
      jsonb_build_object(
        'deep_link', null,
        'data', jsonb_build_object(
          'trial_ends_at', to_char(v_rec.trial_ends_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
          'hours_left', greatest(0, floor(extract(epoch from (v_rec.trial_ends_at - now())) / 3600))::integer)),
      'free_week_ending:' || v_rec.org_id::text || ':'
        || to_char(v_rec.trial_ends_at at time zone 'UTC', 'YYYYMMDD"T"HH24MI') || ':'
        || v_rec.user_id::text,
      null);
    if v_res->>'state' = 'queued' then n_trial := n_trial + 1; end if;
  end loop;

  -- ── allowance_low ─────────────────────────────────────────────────────────
  -- One usage shape from two different clocks. The AI meters are 30-day rolling
  -- windows kept in rate_limits (key '<meter>:<org>'); renders are counted per
  -- calendar month off render_jobs, because that is what create_render_job()
  -- enforces. `period` is whatever makes "this period" identifiable, and it is
  -- in the dedupe key — so the message can fire again next period and not twice
  -- in this one.
  for v_rec in
    with usage as (
      select (split_part(rl.key, ':', 2))::uuid as org_id,
             case split_part(rl.key, ':', 1)
               when 'aiphotomo' then 'photo_edits'
               when 'reelmo'    then 'reels'
               when 'aerialmo'  then 'aerials'
               when 'dronemo'   then 'drone'
             end as feature,
             greatest(0, rl.count) as used,
             to_char(rl.window_start at time zone 'UTC', 'YYYYMMDD"T"HH24MISS') as period
        from rate_limits rl
       where split_part(rl.key, ':', 1) in ('aiphotomo','reelmo','aerialmo','dronemo')
         and split_part(rl.key, ':', 2) ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
         and rl.window_start + make_interval(secs => coalesce(rl.window_seconds, 2592000)) > now()
      union all
      select l.org_id,
             'renders' as feature,
             count(*)::integer as used,
             to_char(date_trunc('month', now() at time zone 'UTC'), 'YYYYMM') as period
        from render_jobs rj
        join listings l on l.id = rj.listing_id
       where rj.source = 'worker'
         and rj.created_at >= date_trunc('month', now())
       group by l.org_id
    ), scored as (
      select u.*, e.* from usage u
      join orgs o on o.id = u.org_id and o.deleted_at is null
      cross join lateral (
        select case u.feature
                 when 'photo_edits' then t.photo_edits_per_month
                 when 'reels'       then t.reels_per_month
                 when 'aerials'     then t.aerials_per_month
                 when 'drone'       then t.topaz_per_month
                 when 'renders'     then t.renders_per_month
               end as cap
          from org_entitlement(u.org_id) t
      ) e
    )
    select s.org_id, s.feature, s.used, s.cap, s.period, m.user_id
      from scored s
      join memberships m on m.org_id = s.org_id and m.role in ('owner','admin')
     where s.cap is not null and s.cap > 0
       and s.used::numeric >= s.cap::numeric * 0.8
     order by s.org_id, s.feature
     limit v_cap
  loop
    v_res := notification_enqueue(
      v_rec.org_id, v_rec.user_id, 'allowance_low',
      jsonb_build_object(
        'deep_link', null,
        'data', jsonb_build_object(
          'feature', v_rec.feature,
          -- Clamped, the same way GET /me clamps it: bump_rate() keeps counting
          -- past the cap, and "72 of 60 used" is a bug report, not a message.
          'used',    least(v_rec.used, v_rec.cap),
          'cap',     v_rec.cap,
          'left',    greatest(0, v_rec.cap - v_rec.used))),
      'allowance_low:' || v_rec.org_id::text || ':' || v_rec.feature || ':'
        || v_rec.period || ':' || v_rec.user_id::text,
      null);
    if v_res->>'state' = 'queued' then n_allow := n_allow + 1; end if;
  end loop;

  -- ── first_tour_nudge ──────────────────────────────────────────────────────
  for v_rec in
    select o.id as org_id, o.created_at, m.user_id
      from orgs o
      join memberships m on m.org_id = o.id and m.role in ('owner','admin')
     where o.deleted_at is null
       and o.first_tour_published_at is null
       and o.created_at <= now() - interval '48 hours'
       and o.created_at >  now() - interval '72 hours'
       and org_is_real(o.id)
     order by o.created_at
     limit v_cap
  loop
    v_res := notification_enqueue(
      v_rec.org_id, v_rec.user_id, 'first_tour_nudge',
      jsonb_build_object(
        'deep_link', null,
        'data', jsonb_build_object(
          'signed_up_at', to_char(v_rec.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))),
      'first_tour_nudge:' || v_rec.org_id::text || ':' || v_rec.user_id::text,
      null);
    if v_res->>'state' = 'queued' then n_nudge := n_nudge + 1; end if;
  end loop;

  -- ── upload_stuck ──────────────────────────────────────────────────────────
  -- The membership join is not decoration: upload_reservations deliberately
  -- carries no cascading FK (0037 — "deleting a listing must not erase the only
  -- known R2 keys"), so actor_id can name somebody who is no longer in the org,
  -- or a row whose org is gone entirely.
  for v_rec in
    select r.asset_id, r.org_id, r.actor_id, r.expires_at, l.address
      from upload_reservations r
      join memberships m on m.org_id = r.org_id and m.user_id = r.actor_id
      left join listings l on l.id = r.listing_id
     where r.state = 'open'
       and r.expires_at < now()
     order by r.expires_at
     limit v_cap
  loop
    v_res := notification_enqueue(
      v_rec.org_id, v_rec.actor_id, 'upload_stuck',
      jsonb_build_object(
        'deep_link', null,
        'data', jsonb_build_object(
          'asset_id',        v_rec.asset_id,
          'listing_address', v_rec.address,
          'deadline',        to_char(v_rec.expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))),
      'upload_stuck:' || v_rec.asset_id::text || ':' || v_rec.actor_id::text,
      null);
    if v_res->>'state' = 'queued' then n_stuck := n_stuck + 1; end if;
  end loop;

  v_sweep := notification_sweep();

  return jsonb_build_object(
    'ran_at',           to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'free_week_ending', n_trial,
    'allowance_low',    n_allow,
    'first_tour_nudge', n_nudge,
    'upload_stuck',     n_stuck,
    'sweep',            v_sweep);
end;
$notification_tick$;

revoke execute on function public.notification_tick() from public, anon, authenticated;
grant execute on function public.notification_tick() to service_role;

comment on function public.notification_tick() is
  'The scheduled producer, called every 15 minutes by pg_cron. Queues '
  'free_week_ending (trial ending inside 48h), allowance_low (past 80% of a '
  'metered cap this period), first_tour_nudge (a REAL org 48–72h old that has '
  'never published) and upload_stuck (an open reservation past its deadline), '
  'every one of them dedupe-keyed so a re-run cannot double-send, then runs '
  'notification_sweep(). Answers the per-category counts it actually queued. '
  'service_role only.';

-- ── 12. The schedule (pg_cron is a MANUAL GATE — the same one as 0022) ──────
--
-- notification_tick() is created UNCONDITIONALLY above: it always exists and
-- can be called by hand or from an external scheduler (a Cloudflare Worker cron
-- trigger, the same alternative DEPLOYMENT.md §9 gives for the deletion
-- sweeper). This block only tries to put pg_cron in charge of calling it every
-- 15 minutes.
--
-- pg_cron is a shared_preload_libraries extension — it must be compiled in and
-- loaded at server start, so a plain/off-the-shelf Postgres (a bare
-- `postgres:16` image, most local dev installs) simply does not have it, with
-- no control file to install from. `create extension pg_cron` on such a host
-- does not no-op, it ERRORS ("extension \"pg_cron\" is not available"), which is
-- what turned the CI `db-migrations` job red when 0022 first tried it: CI
-- replays every migration against plain `postgres:16`. So the block below is a
-- GUARD, not a courtesy: it checks pg_available_extensions before attempting
-- the extension, then pg_extension before attempting to schedule, and RAISES
-- NOTICE (loudly, in the migration run's own log) on either miss instead of
-- silently skipping.
--
-- ** THIS IS A MANUAL GATE IN PRODUCTION, NOT JUST IN CI. ** A fresh Supabase
-- project does not have pg_cron enabled by default either. If this migration's
-- log shows the "pg_cron is not available" (or "did not finish") notice, NOTHING
-- IS EVER SENT on the four scheduled categories — the trial-ending, allowance,
-- first-tour and stuck-upload messages simply do not exist — and stuck `sending`
-- rows are never reclaimed, because notification_sweep() runs from the tick.
-- The two TRIGGERED categories (lead_received, render_ready) are unaffected:
-- they are queued inside their own transactions and drained by functions/notify
-- on whatever schedule invokes it. See services/supabase/DEPLOYMENT.md,
-- "Scheduling lifecycle notifications (pg_cron is a manual gate)".
--
-- Belt AND braces: the whole block also has an `exception when others`
-- fallback, because "available" has more failure modes than "no control file" —
-- pg_cron pins its SQL objects to exactly ONE database cluster-wide
-- (`cron.database_name`), so on a shared cluster where another process has it
-- loaded against a different database, `create extension pg_cron` is a hard
-- ERROR ("can only create extension in database X"), not a graceful no-op. Any
-- such surprise degrades to the same loud notice instead of aborting this
-- migration (and every migration after it).
do $$
declare
  v_id bigint;
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    execute 'create extension if not exists pg_cron';
  end if;

  -- Re-check via pg_extension (not the availability check above) so a
  -- create-extension that silently no-op'd for any other reason also
  -- degrades to the same loud skip, rather than proceeding to schedule
  -- against a `cron` schema that was never actually installed.
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute 'grant usage on schema cron to postgres';

    select jobid into v_id from cron.job where jobname = 'notification-tick';
    if v_id is not null then perform cron.unschedule(v_id); end if;
    perform cron.schedule('notification-tick', '*/15 * * * *',
      $job$ select public.notification_tick(); $job$);

    raise notice '0047: pg_cron is available — notification-tick scheduled every 15 minutes (calls public.notification_tick(), which also runs public.notification_sweep()).';
  else
    raise notice '0047: pg_cron is NOT available on this Postgres — the 15-minute lifecycle tick was NOT scheduled, so free_week_ending, allowance_low, first_tour_nudge and upload_stuck will NEVER be produced and stalled ''sending'' rows will never be reclaimed. public.notification_tick() (created unconditionally above) still exists and can be invoked manually or from an external scheduler (e.g. a Cloudflare Worker cron trigger). lead_received and render_ready are unaffected — they are queued by triggers inside their own transactions. THIS IS A MANUAL GATE: once pg_cron is enabled, re-run this migration to schedule it. See services/supabase/DEPLOYMENT.md.';
  end if;
exception
  when others then
    -- Never let a pg_cron surprise (wrong cron.database_name, a permission
    -- quirk, anything not anticipated above) fail this migration outright.
    -- notification_tick() is unaffected either way.
    raise notice '0047: pg_cron setup did not finish (% — %) — the 15-minute lifecycle tick was NOT scheduled. public.notification_tick() still exists and can be invoked manually or from an external scheduler. THIS IS A MANUAL GATE: resolve whatever this reports on THIS server, then re-run this migration. See services/supabase/DEPLOYMENT.md.', SQLSTATE, SQLERRM;
end $$;
