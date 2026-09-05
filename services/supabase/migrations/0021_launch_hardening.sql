-- 0021: launch hardening — the four things 0019/0020 left reachable
-- (2026-09-05, adversarial review S1).
--
-- 0019 and 0020 are already live. Nothing here drops a column, changes a
-- function signature or narrows a grant a deployed edge function relies on:
-- every change is a REPLACEMENT of a function body with the same argument list,
-- one new nullable column, and one new index. Safe to apply before or after the
-- functions are redeployed, and safe to re-apply.
--
-- ── FINDING 1 (P1). ONE SUBSCRIPTION COULD ENTITLE TWO WORKSPACES ───────────
--
-- `apply_apple_entitlement()` upserted `org_id = coalesce(excluded.org_id,
-- s.org_id)`, so a call carrying a DIFFERENT p_org silently re-pointed the
-- subscription and set the new org's plan — while the old org kept the plan it
-- had already been given. The only thing standing between an attacker and that
-- was a read-then-write check in functions/me (`select org_id … ; if bound and
-- bound <> org then 409`), which two concurrent requests both pass.
--
-- Reproduced on a scratch Postgres 16 (0001…0020 replayed):
--
--   select apply_apple_entitlement('<victim org>', null, 'OT-1', …, 'active', …);
--   -- victim.plan = 'pro'
--   select apply_apple_entitlement('<attacker org>', null, 'OT-1', …, 'active', …);
--   -- -> {"org_updated": true}, apple_subscriptions.org_id = attacker
--   -- -> BOTH orgs now read plan='pro' from ONE subscription.
--
-- The binding is now enforced where the write happens: a p_org that disagrees
-- with the stored one raises RP409, which functions/me already maps to the same
-- 409 "This subscription is already used by another account" its pre-check
-- returns. The notification path can never raise it — it passes the org it just
-- read off the row — and if it ever did, the 503 makes Apple retry, which then
-- reads the new binding.
--
-- ── FINDING 2 (P1). A CROSSGRADE FROZE THE PLAN, THEN THE LAPSE ─────────────
--
-- The out-of-order guard fired on `p_expires_at < stored expires_at` alone. An
-- upgrade inside the subscription group is applied by Apple IMMEDIATELY with a
-- prorated refund, so `pro.annual` → `team.monthly` arrives with an expiry ~11
-- months EARLIER than the one on file. The guard called that stale:
--
--   annual pro            -> plan=pro,  plan_expires_at=2027-09-05
--   upgrade to team.month -> reason "stale_notification", org_updated=false
--                            (customer pays for team, gets pro)
--   later EXPIRED         -> reason "stale_notification" AGAIN, because the
--                            frozen 2027 expiry is still later than every
--                            subsequent one — so the plan NEVER lapsed and
--                            effective_plan()'s 16-day backstop never fired
--                            either, because it reads the same frozen date.
--
-- Verified end-to-end on the same scratch database. The guard now only fires
-- when the product is demonstrably UNCHANGED — a duplicate or a genuinely
-- out-of-order signal for the subscription we already hold. A visible product
-- change is a crossgrade and is always the newer truth.
--
-- ── FINDING 3 (P3). SANDBOX COULD OVERWRITE PRODUCTION ──────────────────────
--
-- functions/apple-subscriptions refuses a notification whose environment
-- disagrees with the stored row, but POST /me/entitlement had no such check and
-- the upsert did `environment = coalesce(excluded.environment, s.environment)`
-- — so a Sandbox transaction rewrote a Production row's environment, after
-- which every real Production notification for it was discarded as an
-- environment mismatch and the subscription could neither renew nor lapse.
-- The rule now lives in the function both callers go through.
--
-- ── FINDING 4 (P2). THE FUNNEL'S PURCHASE COUNT WAS UNAUTHENTICATED ─────────
--
-- `app_events` is written by POST /events, which accepts the project ANON key
-- (it must: half the funnel happens before anyone signs in). `device_id` is a
-- client-generated UUID, so anybody holding the anon key — it ships inside the
-- app — can mint `purchase_completed` rows for invented devices and inflate the
-- one number the owner is about to spend ad money against.
--
-- The reported step is LEFT ALONE (a shipped screen reads it, and quietly
-- redefining a headline number is its own kind of lie). Two unspoofable numbers
-- are added beside it: `purchases_verified`, counted from `apple_subscriptions`
-- — rows only apply_apple_entitlement() can write, only from a JWS this server
-- verified against the pinned Apple root — and `purchase_completed_attributed`,
-- the events that carried a real user JWT. A gap between the three is the
-- signal; see admin/funnel.ts, which returns all three with a note.
--
-- ── ALSO HERE ───────────────────────────────────────────────────────────────
--
-- `apple_subscriptions.app_account_token`: the UUID StoreKit lets the app stamp
-- on a purchase (`Product.PurchaseOption.appAccountToken`). POST /me/entitlement
-- now refuses a transaction whose token names a DIFFERENT user, and records it
-- when present. Nullable and unchecked when absent, because the shipped build
-- does not set one yet — see docs/handoff §iOS in the review report.
--
-- Idempotent: `add column if not exists` / `create index if not exists` /
-- `create or replace function`. A replay changes nothing.

-- ── 1. apple_subscriptions.app_account_token ────────────────────────────────

alter table public.apple_subscriptions
  add column if not exists app_account_token uuid;

create index if not exists idx_apple_subscriptions_account_token
  on public.apple_subscriptions (app_account_token)
  where app_account_token is not null;

comment on column public.apple_subscriptions.app_account_token is
  'The appAccountToken StoreKit stamped on the purchase, when the client set '
  'one. Written by POST /me/entitlement from the VERIFIED transaction, never '
  'from a request body. NULL for builds that do not set it; when it is present '
  'it must equal the caller''s own user id or the sync is refused, which is '
  'what stops a leaked signed transaction from being redeemed by someone else.';

-- ── 2. apply_apple_entitlement() — same signature, three new guards ─────────
--
-- Reproduced verbatim from 0019 except where marked `0021:`. Argument list is
-- byte-identical on purpose: PostgREST resolves this RPC by named arguments and
-- tests/invariants.sql asserts exactly one overload of every function, so
-- adding a parameter would break every deployed caller at once.

create or replace function public.apply_apple_entitlement(
  p_org                     uuid,
  p_user                    uuid,
  p_original_transaction_id text,
  p_transaction_id          text,
  p_product_id              text,
  p_plan                    text,
  p_environment             text,
  p_status                  text,
  p_expires_at              timestamptz,
  p_auto_renew              boolean,
  p_notification_type       text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing   public.apple_subscriptions%rowtype;
  v_stale      boolean := false;
  v_status     text;
  v_expires    timestamptz;
  v_plan       text;
  v_source     text;
  v_org_source text;
  v_updated    boolean := false;
  v_reason     text := null;
  v_others     integer := 0;
begin
  if p_original_transaction_id is null or btrim(p_original_transaction_id) = '' then
    raise exception 'RP400: original_transaction_id is required';
  end if;
  if p_status is null or p_status not in ('active','grace','expired','revoked','refunded') then
    raise exception 'RP400: status must be active, grace, expired, revoked or refunded';
  end if;

  select * into v_existing
    from apple_subscriptions
   where original_transaction_id = p_original_transaction_id
   for update;

  -- 0021 FINDING 1: one subscription, one workspace — enforced HERE, inside the
  -- row lock, not by a read-then-write check in an edge function that two
  -- concurrent requests both pass. The caller (POST /me/entitlement) already
  -- returns the same 409 for the non-racing case; this is what makes the racing
  -- case answer the same way instead of re-pointing the subscription and
  -- leaving two orgs entitled by one purchase.
  if found
     and v_existing.org_id is not null
     and p_org is not null
     and p_org <> v_existing.org_id
  then
    raise exception 'RP409: This subscription is already used by another account';
  end if;

  -- 0021 FINDING 3: environment is sticky. Sandbox must never move Production
  -- and Production must never be reset by a Sandbox replay, on EITHER path —
  -- functions/apple-subscriptions checked this, POST /me/entitlement did not.
  -- The arrival is recorded; nothing else changes.
  if found
     and v_existing.environment is not null
     and p_environment is not null
     and p_environment <> v_existing.environment
  then
    update apple_subscriptions
       set last_notification_type = coalesce(p_notification_type, last_notification_type),
           updated_at             = now()
     where original_transaction_id = p_original_transaction_id;

    return jsonb_build_object(
      'ok', true,
      'plan', (select o.plan from orgs o where o.id = v_existing.org_id),
      'source', 'apple',
      'expires_at', v_existing.expires_at,
      'status', v_existing.status,
      'org_updated', false,
      'reason', 'environment_mismatch');
  end if;

  -- Out-of-order delivery: an older expiry for a non-terminal status is news
  -- we already have. Record that the notification arrived; change nothing else.
  --
  -- 0021 FINDING 2: …but ONLY when the product has not changed. A crossgrade
  -- inside the subscription group is applied by Apple immediately with a
  -- prorated refund, so an UPGRADE from an annual product to a monthly one
  -- legitimately carries an earlier expiry. Treating that as stale froze the
  -- org on the old plan AND the old (much later) expiry, which then made every
  -- subsequent signal — including the final EXPIRED — stale as well, so the
  -- subscription never lapsed. A visible product change is always the newer
  -- truth; the guard is kept for the case it was written for, a duplicate or
  -- out-of-order signal about the SAME product.
  if found
     and p_status in ('active','grace','expired')
     and v_existing.expires_at is not null
     and p_expires_at is not null
     and p_expires_at < v_existing.expires_at
     and (p_product_id is null
          or v_existing.product_id is null
          or p_product_id = v_existing.product_id)
  then
    v_stale := true;
  end if;

  v_status  := case when v_stale then v_existing.status     else p_status     end;
  v_expires := case when v_stale then v_existing.expires_at else p_expires_at end;
  v_plan    := case when v_stale then v_existing.plan       else p_plan       end;

  insert into apple_subscriptions as s (
    original_transaction_id, org_id, user_id, product_id, plan, environment,
    status, expires_at, auto_renew, last_transaction_id, last_notification_type,
    created_at, updated_at
  ) values (
    p_original_transaction_id, p_org, p_user, p_product_id, v_plan, p_environment,
    v_status, v_expires, p_auto_renew, p_transaction_id, p_notification_type,
    now(), now()
  )
  on conflict (original_transaction_id) do update set
    -- Never blank an existing link: a notification arrives with p_org null.
    -- (org_id can only ever be the stored one or a first link — a disagreeing
    -- p_org raised RP409 above.)
    org_id                 = coalesce(excluded.org_id, s.org_id),
    user_id                = coalesce(excluded.user_id, s.user_id),
    -- 0021: on a stale signal the product must not move either, or the row
    -- ends up claiming a product whose plan it is not carrying.
    product_id             = case when v_stale then s.product_id
                                  else coalesce(excluded.product_id, s.product_id) end,
    plan                   = coalesce(excluded.plan, s.plan),
    environment            = coalesce(s.environment, excluded.environment),
    status                 = excluded.status,
    expires_at             = excluded.expires_at,
    auto_renew             = coalesce(excluded.auto_renew, s.auto_renew),
    last_transaction_id    = coalesce(excluded.last_transaction_id, s.last_transaction_id),
    last_notification_type = coalesce(excluded.last_notification_type, s.last_notification_type),
    updated_at             = now()
  returning * into v_existing;

  -- No org yet (a notification that beat the device here): the row is stored
  -- and POST /me/entitlement will replay it once the app links the workspace.
  if v_existing.org_id is null then
    return jsonb_build_object(
      'ok', true, 'plan', null, 'source', null, 'expires_at', v_expires,
      'status', v_status, 'org_updated', false, 'reason', 'no_org_linked');
  end if;

  select o.plan_source into v_org_source from orgs o where o.id = v_existing.org_id for update;
  if not found then
    return jsonb_build_object(
      'ok', true, 'plan', null, 'source', null, 'expires_at', v_expires,
      'status', v_status, 'org_updated', false, 'reason', 'org_missing');
  end if;

  -- RULE 2 (0019): an owner-granted plan is Apple-proof, in both directions.
  if v_org_source = 'manual' then
    return jsonb_build_object(
      'ok', true, 'plan', (select plan from orgs where id = v_existing.org_id),
      'source', 'manual', 'expires_at', v_expires, 'status', v_status,
      'org_updated', false, 'reason', 'manual_plan');
  end if;

  if v_stale then
    return jsonb_build_object(
      'ok', true, 'plan', (select plan from orgs where id = v_existing.org_id),
      'source', 'apple', 'expires_at', v_expires, 'status', v_status,
      'org_updated', false, 'reason', 'stale_notification');
  end if;

  if v_status in ('active','grace') then
    update orgs
       set plan             = coalesce(v_plan, plan),
           plan_source      = 'apple',
           plan_expires_at  = v_expires,
           apple_product_id = coalesce(v_existing.product_id, apple_product_id)
     where id = v_existing.org_id;
    v_updated := true;
    v_source  := 'apple';
  else
    -- A lapse only downgrades when nothing else is still paying for this org.
    -- 0021: `and x.expires_at > now()` as well, so a row that is still marked
    -- active only because its own EXPIRED was never delivered cannot hold an
    -- org on a paid plan forever. Rows with no expiry at all still count, the
    -- same way they did before.
    select count(*) into v_others
      from apple_subscriptions x
     where x.org_id = v_existing.org_id
       and x.original_transaction_id <> v_existing.original_transaction_id
       and x.status in ('active','grace')
       and (x.expires_at is null or x.expires_at > now() - interval '16 days');

    if v_others > 0 then
      v_reason := 'another_subscription_active';
    else
      update orgs
         set plan             = 'free',
             plan_source      = 'apple',
             plan_expires_at  = v_expires,
             apple_product_id = coalesce(v_existing.product_id, apple_product_id)
       where id = v_existing.org_id;
      v_updated := true;
    end if;
    v_source := 'apple';
  end if;

  return jsonb_build_object(
    'ok', true,
    'plan', (select plan from orgs where id = v_existing.org_id),
    'source', coalesce(v_source, 'apple'),
    'expires_at', v_expires,
    'status', v_status,
    'org_updated', v_updated,
    'reason', v_reason
  );
end;
$$;

-- CREATE OR REPLACE keeps the 0019 privileges; re-asserted so this file alone
-- lands in the same state on a database that has only ever seen 0019.
revoke execute on function public.apply_apple_entitlement(
  uuid, uuid, text, text, text, text, text, text, timestamptz, boolean, text
) from public, anon, authenticated;
grant execute on function public.apply_apple_entitlement(
  uuid, uuid, text, text, text, text, text, text, timestamptz, boolean, text
) to service_role;

comment on function public.apply_apple_entitlement(
  uuid, uuid, text, text, text, text, text, text, timestamptz, boolean, text
) is
  'The ONLY path from a verified Apple JWS to orgs.plan. Upserts '
  'apple_subscriptions and sets plan/plan_source/plan_expires_at/apple_product_id '
  '— except on a manual (owner-granted) plan, which it never changes. '
  'Refuses (RP409) a p_org that disagrees with the subscription''s existing '
  'binding, refuses to let one environment overwrite the other, and treats an '
  'earlier expiry as stale only when the product is unchanged. service_role only.';

-- ── 3. admin_funnel() — a purchase number nobody can fabricate ─────────────
--
-- Reproduced from 0020 except for the two additions marked `0021:`. The eight
-- steps, their counts and both percentages are untouched: a shipped iOS screen
-- decodes them and the honest fix is a number BESIDE the reported one, not a
-- silent redefinition of it.

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
  v_attrib    bigint := 0;
  v_verified  bigint := 0;
  v_sandbox   bigint := 0;
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
  -- 0021: purchase_completed events that carried a real USER JWT. POST /events
  -- resolves user_id from the token and never from the body, so this cannot be
  -- reached with the anon key alone — unlike the step count above, which any
  -- holder of the shipped anon key can inflate with invented device ids.
  select coalesce(count(*) filter (where e.name = 'crash'), 0),
         coalesce(count(*) filter (where e.name = 'error'), 0),
         coalesce(count(distinct e.device_id), 0),
         coalesce(count(distinct e.session_id), 0),
         coalesce(count(*), 0),
         coalesce(count(distinct e.device_id)
                    filter (where e.name = 'purchase_completed'
                              and e.user_id is not null), 0)
    into v_crashes, v_errors, v_devices, v_sessions, v_total, v_attrib
    from app_events e
   where e.t >= v_from and e.t <= v_now;

  -- 0021: GROUND TRUTH. apple_subscriptions is written only by
  -- apply_apple_entitlement(), only from a JWS verified against the pinned
  -- Apple root, so this number cannot be fabricated by any client at all. It
  -- counts subscriptions that STARTED in the window (created_at), which is the
  -- same event `purchase_completed` claims to report. Sandbox is counted apart
  -- rather than folded in: a TestFlight tester is not revenue.
  select coalesce(count(*) filter (where coalesce(s.environment, 'Production') <> 'Sandbox'), 0),
         coalesce(count(*) filter (where s.environment = 'Sandbox'), 0)
    into v_verified, v_sandbox
    from apple_subscriptions s
   where s.created_at >= v_from and s.created_at <= v_now;

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
    -- 0021, additive. See the header: the step above is client-reported and
    -- reachable with the anon key; these two are not.
    'purchase_completed_attributed', v_attrib,
    'purchases_verified',            v_verified,
    'purchases_verified_sandbox',    v_sandbox,
    'by_day',         v_by_day
  );
end;
$$;

revoke execute on function public.admin_funnel(interval) from public, anon, authenticated;
grant  execute on function public.admin_funnel(interval) to service_role;

comment on function public.admin_funnel(interval) is
  'The whole GET /admin/funnel payload in one call: eight ordered steps counted '
  'as DISTINCT DEVICES with pct_of_previous / pct_of_first, plus crashes, errors, '
  'active_devices, sessions, a by_day series, and three purchase numbers — the '
  'client-reported step, the subset that carried a user JWT, and the count of '
  'apple_subscriptions actually created in the window, which no client can '
  'fabricate. Window is clamped to 1 hour … 365 days. service_role only.';
