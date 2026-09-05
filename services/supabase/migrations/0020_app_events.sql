-- 0020: first-party product analytics — app_events + the funnel read (2026-09-05).
--
-- The owner is about to spend money on Meta ads pointing at the iOS app, and
-- the app currently reports NOTHING: no funnel, no crash count, no idea which
-- step loses people. This migration is the storage half of the fix. The other
-- halves are `functions/events` (the anon-reachable writer) and
-- `functions/admin/funnel.ts` (the admin-only reader).
--
-- NO THIRD-PARTY SDK is involved. Nothing here is Firebase, Mixpanel or an ad
-- network: it is one append-only table the app POSTs to, and one function that
-- counts it. That is deliberate — a first-party pipeline keeps the privacy
-- manifest honest and keeps App Review simple (docs/LAUNCH-CONTRACT.md §Events).
--
-- ── FOUR THINGS THIS FILE IS CAREFUL ABOUT ───────────────────────────────────
--
-- 1. NO PII EVER LANDS HERE. `props` is a small jsonb bag whose keys are
--    WHITELISTED per event name by the edge function, whose string values are
--    scrubbed for anything that looks like an e-mail/phone/address/URL, and
--    which is capped at 1 KB per event. The table cannot enforce a whitelist,
--    so it enforces the shape: props must be a jsonb OBJECT and it must be
--    small. A writer that forgets the whitelist still cannot store a photo, a
--    street address or a 40 KB blob.
--
-- 2. A CLIENT CAN NEVER READ IT. RLS is on with NO policies and every tenant
--    grant is revoked, so `app_events` is service-role only — the same posture
--    as `admin_allowlist` (0017) and `rate_limits` (0004/0007). The funnel is
--    read through admin_funnel(), which is SECURITY DEFINER and granted to
--    service_role alone; the admin edge function calls it after requireAdmin().
--    There is deliberately NO admin SELECT policy: an admin needs the AGGREGATE,
--    not the row stream, and the aggregate is the only thing exposed.
--
-- 3. THE DEVICE ID IS NOT AN ADVERTISING ID. `device_id` is a UUID the app
--    generates on first launch and keeps in its own Keychain item. It is not
--    the IDFA, not the IDFV, not derivable from either, dies with an app
--    delete + Keychain purge, and never leaves this system. The app never asks
--    for App Tracking Transparency because it never tracks across apps.
--
-- 4. THE DATA EXPIRES. purge_app_events() drops rows older than a retention
--    window (default 180 days). Analytics that nobody deletes becomes a
--    liability the day someone asks what you still hold — see §4 for the cron.
--
-- Idempotent: `create table if not exists` / `create index if not exists` /
-- guarded constraints / `create or replace function`. A replay changes nothing
-- and destroys no rows.

-- ── 1. app_events — one row per event, append-only ──────────────────────────
--
-- Column notes that carry real meaning:
--   • t            when the event happened ON THE DEVICE (the app sends ISO
--                  timestamps and may be offline for days before it flushes).
--                  This is what every funnel window filters on.
--   • received_at  when the server accepted it. Kept so a clock-skewed or
--                  malicious `t` can be spotted without losing the row, and so
--                  the purge has a server-truth column to fall back on.
--   • device_id    app-generated install id (see §3 above). NOT NULL: a row
--                  with no device cannot participate in a per-device funnel,
--                  so it would be counted-but-invisible, which is worse than
--                  rejected.
--   • user_id      NULL until the person signs in. Resolved server-side from
--                  the JWT — the edge function never reads an id out of the
--                  request body, so a client cannot attribute its events to
--                  somebody else's account.
--   • org_id       same, via orgForUser(). No FK on either: an event is a fact
--                  about something that happened, and deleting an account must
--                  not fail on, or silently rewrite, historical counts. (The
--                  purge and DELETE /me are what remove the rows.)
--   • props        bounded jsonb object, whitelisted per event by the writer.

create table if not exists public.app_events (
  id          bigserial primary key,
  received_at timestamptz not null default now(),
  t           timestamptz not null default now(),
  name        text        not null,
  device_id   uuid        not null,
  session_id  uuid,
  user_id     uuid,
  org_id      uuid,
  app_version text,
  os          text,
  props       jsonb       not null default '{}'::jsonb
);

comment on table public.app_events is
  'First-party product analytics. One row per app event (docs/LAUNCH-CONTRACT.md '
  '§Events vocabulary). Service-role only: RLS on, no policies, no tenant grants. '
  'Read through admin_funnel(); expired by purge_app_events(). NO PII in props.';

comment on column public.app_events.device_id is
  'App-generated install UUID kept in the app''s own Keychain item. NOT the IDFA '
  'or IDFV and not derivable from either — the app requests no ATT permission.';

comment on column public.app_events.t is
  'Device-side event time (the app buffers events offline and flushes later). '
  'Every funnel window filters on this; received_at is the server''s own clock.';

comment on column public.app_events.props is
  'Bounded jsonb object. Keys are whitelisted PER EVENT NAME by functions/events '
  'and unknown keys are dropped; string values are scrubbed for anything shaped '
  'like an e-mail, phone number, street address or URL.';

-- Shape guards. The writer enforces the vocabulary and the whitelist; these
-- make the *storage* invariants true even for a future writer that forgets.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.app_events'::regclass
       and conname  = 'app_events_props_object'
  ) then
    alter table public.app_events
      add constraint app_events_props_object
      check (jsonb_typeof(props) = 'object' and pg_column_size(props) <= 2048);
  end if;

  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.app_events'::regclass
       and conname  = 'app_events_name_bounded'
  ) then
    alter table public.app_events
      add constraint app_events_name_bounded
      check (name = btrim(name) and length(name) between 1 and 40);
  end if;
end $$;

-- The three reads this table has, and nothing speculative:
--   (name, t)      every funnel step is "this event, in this window".
--   (device_id, t) per-device timelines + the writer's own dedupe/debug reads.
--   (org_id, t)    per-tenant slices, and DELETE /me finding an org's rows.
create index if not exists idx_app_events_name_t   on public.app_events (name, t desc);
create index if not exists idx_app_events_device_t on public.app_events (device_id, t desc);
create index if not exists idx_app_events_org_t    on public.app_events (org_id, t desc) where org_id is not null;
-- The purge scans by server clock, not device clock.
create index if not exists idx_app_events_received on public.app_events (received_at);

-- ── 2. RLS + grants: service role only ──────────────────────────────────────
--
-- ci-bootstrap.sql mirrors Supabase's default privileges (ALL on every new
-- table and sequence to anon/authenticated/service_role), so every REVOKE
-- below is load-bearing, not decoration. RLS is enabled with NO policies, which
-- means even a role that somehow held the grant would see zero rows.

alter table public.app_events enable row level security;  -- no policies: service-role only
revoke all on public.app_events from anon, authenticated;
revoke all on sequence public.app_events_id_seq from anon, authenticated;
grant  all on public.app_events to service_role;
grant  usage, select on sequence public.app_events_id_seq to service_role;

-- ── 3. admin_funnel() — the whole console read, in one call ─────────────────
--
-- SECURITY DEFINER with `set search_path = public`, the convention every
-- definer in this repo follows (is_admin 0017, report_provider_outcome 0018,
-- org_role 0006, log_job_cost 0010). service_role EXECUTE only — the caller is
-- GET /admin/funnel, which has already run requireAdmin().
--
-- WHY ONE FUNCTION AND NOT EIGHT QUERIES: the eight steps, the crash/error
-- counts and the daily series must all describe the SAME window and the same
-- instant. Eight round-trips from an edge function cannot promise that, and a
-- funnel whose steps disagree about `now()` is a funnel that occasionally shows
-- 103% conversion.
--
-- WHAT A STEP COUNTS: DISTINCT DEVICES, not events. A person who opens the app
-- forty times is one device at `app_open`, so `pct_of_previous` reads as "of
-- the people who got here, how many went on" rather than being inflated by
-- whoever is most enthusiastic. It is NOT a cohort funnel: the device counted
-- at `purchase_completed` is not required to have appeared at `app_open` inside
-- the same window, so a long window plus a short one can disagree slightly at
-- the tail. That is the honest cheap version; a cohort funnel needs a join per
-- step and is not worth it at this scale.
--
-- pct_of_previous / pct_of_first are NULL (never 0) when the divisor is 0 —
-- "no data" and "nobody converted" are different facts and the screen says so.

create or replace function public.admin_funnel(p_window interval default interval '30 days')
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_window interval;
  v_from   timestamptz;
  v_now    timestamptz := now();
  v_steps  constant text[] := array[
    'app_open', 'signup', 'home_created', 'capture_finished',
    'render_finished', 'tour_published', 'paywall_viewed', 'purchase_completed'
  ];
  v_step_json jsonb;
  v_by_day    jsonb;
  v_crashes   bigint := 0;
  v_errors    bigint := 0;
  v_devices   bigint := 0;
  v_sessions  bigint := 0;
  v_total     bigint := 0;
begin
  -- Bound the window rather than trusting the caller: an unbounded interval is
  -- a full-table scan, and a negative one silently returns an empty funnel that
  -- looks like "nobody used the app".
  v_window := coalesce(p_window, interval '30 days');
  if v_window < interval '1 hour'   then v_window := interval '1 hour';   end if;
  if v_window > interval '365 days' then v_window := interval '365 days'; end if;
  v_from := v_now - v_window;

  -- The eight steps, in order, with both conversion ratios.
  select jsonb_agg(
           jsonb_build_object(
             'name',            x.name,
             'count',           x.c,
             'pct_of_previous', case when x.prev_c > 0
                                     then round((100.0 * x.c) / x.prev_c, 1) end,
             'pct_of_first',    case when x.first_c > 0
                                     then round((100.0 * x.c) / x.first_c, 1) end
           )
           order by x.ord
         )
    into v_step_json
    from (
      select c.name,
             c.ord,
             c.c,
             lag(c.c)         over (order by c.ord) as prev_c,
             first_value(c.c) over (order by c.ord) as first_c
        from (
          select s.name,
                 s.ord,
                 coalesce(count(distinct e.device_id), 0)::bigint as c
            from unnest(v_steps) with ordinality as s(name, ord)
            left join app_events e
              on e.name = s.name
             and e.t >= v_from
             and e.t <= v_now
           group by s.name, s.ord
        ) c
    ) x;

  -- Everything else about the window, in one pass over the same rows.
  select coalesce(count(*) filter (where e.name = 'crash'), 0),
         coalesce(count(*) filter (where e.name = 'error'), 0),
         coalesce(count(distinct e.device_id), 0),
         coalesce(count(distinct e.session_id), 0),
         coalesce(count(*), 0)
    into v_crashes, v_errors, v_devices, v_sessions, v_total
    from app_events e
   where e.t >= v_from and e.t <= v_now;

  -- The sparkline. Days with no events are absent rather than zero-filled —
  -- the client draws what it is given and a gap is a real gap. opens/signups/
  -- purchases are DISTINCT DEVICES for that day (so the line is "people"),
  -- crashes is a raw count (one device can crash repeatedly, and that matters).
  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'day',       to_char(d.day, 'YYYY-MM-DD'),
               'opens',     d.opens,
               'signups',   d.signups,
               'purchases', d.purchases,
               'crashes',   d.crashes
             )
             order by d.day
           ),
           '[]'::jsonb
         )
    into v_by_day
    from (
      select date_trunc('day', e.t) as day,
             count(distinct e.device_id) filter (where e.name = 'app_open')          as opens,
             count(distinct e.device_id) filter (where e.name = 'signup')            as signups,
             count(distinct e.device_id) filter (where e.name = 'purchase_completed') as purchases,
             count(*)                    filter (where e.name = 'crash')             as crashes
        from app_events e
       where e.t >= v_from and e.t <= v_now
       group by 1
    ) d;

  return jsonb_build_object(
    'generated_at',   to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'from',           to_char(v_from at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'to',             to_char(v_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'window_seconds', floor(extract(epoch from v_window))::bigint,
    'steps',          coalesce(v_step_json, '[]'::jsonb),
    'crashes',        v_crashes,
    'errors',         v_errors,
    'active_devices', v_devices,
    'sessions',       v_sessions,
    'events',         v_total,
    'by_day',         v_by_day
  );
end;
$$;

revoke execute on function public.admin_funnel(interval) from public, anon, authenticated;
grant  execute on function public.admin_funnel(interval) to service_role;

comment on function public.admin_funnel(interval) is
  'The whole GET /admin/funnel payload in one call: eight ordered steps counted '
  'as DISTINCT DEVICES with pct_of_previous / pct_of_first, plus crashes, errors, '
  'active_devices, sessions and a by_day series. Window is clamped to 1 hour … '
  '365 days. Not a cohort funnel — see the file header. service_role only.';

-- ── 4. purge_app_events() — retention is not optional ───────────────────────
--
-- Default 180 days. Returns the number of rows removed so a scheduled run can
-- be observed rather than assumed.
--
-- CRON (run it as the owner, once, in the Supabase SQL editor — pg_cron ships
-- enabled on Supabase; `select cron.schedule(...)` is idempotent by job name):
--
--   select cron.schedule(
--     'purge-app-events',
--     '17 4 * * *',                                   -- 04:17 UTC daily, off-peak
--     $cron$ select public.purge_app_events(interval '180 days'); $cron$
--   );
--
-- Until that is scheduled the table grows without bound — see HANDOFF-P3.md
-- ("what the owner must do"). Deleting in one statement is fine at this scale;
-- if the table ever gets big enough for the delete to matter, batch it.

create or replace function public.purge_app_events(p_older_than interval default interval '180 days')
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_keep interval := coalesce(p_older_than, interval '180 days');
  v_n    bigint;
begin
  -- A retention window shorter than a day would let a mis-typed call wipe the
  -- current funnel; the floor makes that impossible.
  if v_keep < interval '1 day' then v_keep := interval '1 day'; end if;

  -- received_at, not t: the device clock is attacker-suppliable, and a row
  -- stamped with the year 2099 must still expire on schedule.
  delete from app_events where received_at < now() - v_keep;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke execute on function public.purge_app_events(interval) from public, anon, authenticated;
grant  execute on function public.purge_app_events(interval) to service_role;

comment on function public.purge_app_events(interval) is
  'Deletes app_events older than p_older_than (default 180 days, floored at 1 day), '
  'measured on received_at — the server clock, never the device''s. Returns the row '
  'count. Schedule with pg_cron; see the migration header. service_role only.';
