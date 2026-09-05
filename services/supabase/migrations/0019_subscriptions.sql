-- 0019: Apple subscriptions — the paid plan becomes a fact in the database
-- (2026-09-05).
--
-- Until now `orgs.plan` was set by hand and `trial` was the only thing that
-- could ever change it. This migration makes the App Store the source of a
-- paid plan, with three rules that decide every design choice below.
--
-- ── RULE 1: APPLE'S WORD ONLY REACHES `orgs` THROUGH ONE DEFINER FUNCTION ───
--
-- `apply_apple_entitlement()` is the ONLY way an Apple signal writes a plan. It
-- is SECURITY DEFINER with `set search_path = public`, execute is revoked from
-- public/anon/authenticated and granted to service_role alone — so the plan a
-- client sees is the plan a verified JWS produced, never one it asked for.
-- Both new tables are service-role only for the same reason (RLS on, NO
-- policies, every tenant grant revoked). A tenant reading its own subscription
-- gets it from `GET /me`, which the server assembles.
--
-- Belt and braces on the `orgs` side: the tenant UPDATE grant has been
-- column-scoped since 0005 (`name, handle, space_type, brand_kit`), so the
-- three new columns are unwritable by a client the moment they exist. §3
-- re-asserts that grant so this file also repairs a database where someone ran
-- a bare `grant update on orgs`.
--
-- ── RULE 2: AN OWNER-GRANTED PLAN IS NEVER TOUCHED BY APPLE ─────────────────
--
-- `orgs.plan_source = 'manual'` means a human decided this org's plan — a
-- comped account, a partner, the owner's own workspace. Apple must not raise it
-- and must not lower it, so apply_apple_entitlement() records the subscription
-- and returns `org_updated: false, reason: 'manual_plan'` without writing
-- `orgs` at all. This is the one case where the subscription table and the plan
-- column are allowed to disagree, and it is deliberate.
--
-- NOTE FOR THE OWNER: this migration defaults EVERY existing org to
-- plan_source = 'trial', because guessing which historical org was a comp and
-- which was a real payer is how a paying org silently stops downgrading. Mark
-- the comped ones explicitly, once:
--     update public.orgs set plan_source = 'manual' where id in ('…','…');
--
-- ── RULE 3: A LAPSE IS A LAPSE, EVEN IF APPLE GOES QUIET ────────────────────
--
-- Notifications can be missed, delayed or delivered out of order — Apple says
-- so, and a webhook is not a ledger. So `effective_plan()` gains a SECOND
-- expiry arm alongside the trial one: an org on `plan_source = 'apple'` whose
-- `plan_expires_at` is more than 16 days past reads `free`, whatever
-- `orgs.plan` still says. 16 days is Apple's maximum billing-retry grace, so
-- the arm can only fire for a subscription that is genuinely gone. The trial
-- arm is reproduced BYTE-IDENTICALLY from 0010 and stays first.
--
-- Out-of-order delivery is handled in the function itself: a status/expiry
-- older than the one already stored is recorded but not applied (§4), so a
-- late EXPIRED cannot undo a DID_RENEW that already landed. Revocations and
-- refunds always apply — money coming back is never stale news.
--
-- Idempotent: `create table if not exists` / `add column if not exists` /
-- guarded constraints / `create index if not exists` / `create or replace
-- function` / `drop policy if exists`. Safe to re-apply.

-- ── 1. apple_subscriptions — one row per original_transaction_id ────────────
--
-- Apple's `originalTransactionId` is the stable identity of a subscription
-- across every renewal, upgrade, downgrade and re-subscribe, so it is the
-- primary key. `org_id` is nullable on purpose: a notification can arrive
-- before the app has ever called POST /me/entitlement, and losing that
-- notification is worse than storing it unlinked.
--
-- org_id is ON DELETE SET NULL rather than CASCADE: DELETE /me destroys the
-- org, and the App Store subscription outlives it (Apple keeps billing until
-- the user cancels). Keeping the orphaned row means a later notification for
-- that transaction still has somewhere to land instead of raising an FK error
-- at Apple. user_id is SET NULL for the same reason, which is also what keeps a
-- deleted person's id from surviving here — so after a deletion the row holds
-- nothing but Apple's own identifiers, a product id and a status.

create table if not exists public.apple_subscriptions (
  original_transaction_id text primary key,
  org_id                  uuid references public.orgs(id) on delete set null,
  -- SET NULL, not CASCADE: DELETE /me destroys the profile, and this makes the
  -- deleted person's id disappear from here automatically instead of relying on
  -- the deletion handler remembering a table it does not know about. The
  -- subscription row itself survives, because the App Store subscription does.
  user_id                 uuid references public.profiles(id) on delete set null,
  product_id              text,
  plan                    text,
  environment             text,
  status                  text,
  expires_at              timestamptz,
  auto_renew              boolean,
  last_transaction_id     text,
  last_notification_type  text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.apple_subscriptions'::regclass
       and conname  = 'apple_subscriptions_status_check'
  ) then
    alter table public.apple_subscriptions
      add constraint apple_subscriptions_status_check
      check (status is null or status in ('active','grace','expired','revoked','refunded'));
  end if;
end $$;

create index if not exists idx_apple_subscriptions_org
  on public.apple_subscriptions (org_id);
create index if not exists idx_apple_subscriptions_status
  on public.apple_subscriptions (status);

comment on table public.apple_subscriptions is
  'One row per App Store subscription, keyed by Apple''s stable '
  'originalTransactionId. Written ONLY by apply_apple_entitlement() from a '
  'verified JWS (device sync or App Store Server Notification V2). '
  'Service-role only: RLS on, no policies, no tenant grants.';

comment on column public.apple_subscriptions.org_id is
  'The workspace this subscription unlocks. NULL while a notification is '
  'waiting for the app''s first POST /me/entitlement to link it, and after the '
  'org is deleted (the App Store subscription outlives the workspace).';

-- ── 2. apple_notifications — the idempotency ledger ────────────────────────
--
-- Apple retries a notification until it gets a 2xx, and a retry carries the
-- SAME notificationUUID. That uuid is therefore the primary key: the handler
-- inserts first and treats a unique violation as "already handled", which is
-- what makes double delivery a no-op rather than a double plan write.
--
-- `pending` marks a notification that arrived before any org was linked to its
-- original_transaction_id. POST /me/entitlement replays those, in receipt
-- order, the moment the app links the subscription — so a SUBSCRIBED that beat
-- the device to the server is applied instead of lost.
--
-- `payload` holds the DECODED notification plus the decoded transaction and
-- renewal info. Not the raw JWS: the decoded form is what a replay needs, it is
-- already verified, and it keeps a signed blob out of the database.

create table if not exists public.apple_notifications (
  notification_uuid       text primary key,
  original_transaction_id text,
  org_id                  uuid references public.orgs(id) on delete set null,
  notification_type       text,
  subtype                 text,
  environment             text,
  pending                 boolean not null default false,
  payload                 jsonb   not null default '{}'::jsonb,
  received_at             timestamptz not null default now()
);

create index if not exists idx_apple_notifications_pending
  on public.apple_notifications (original_transaction_id, received_at)
  where pending;
create index if not exists idx_apple_notifications_org
  on public.apple_notifications (org_id, received_at desc);

comment on table public.apple_notifications is
  'Every App Store Server Notification V2 this server has accepted, keyed by '
  'Apple''s notificationUUID so a retry is idempotent. pending = arrived before '
  'the subscription was linked to an org; POST /me/entitlement replays those. '
  'Service-role only: RLS on, no policies, no tenant grants.';

-- ── 3. orgs: where the plan came from, and when it runs out ────────────────
--
-- plan_source  'trial'  (default — a signup with no purchase and no comp)
--              'apple'  set by apply_apple_entitlement()
--              'manual' an owner-granted plan; Apple never touches it (RULE 2)
-- plan_expires_at   when the CURRENT paid period ends (or the grace window,
--                   while Apple is retrying). NULL on a trial or a manual grant.
-- apple_product_id  the last App Store product this org bought. Kept after an
--                   expiry as history, so the console can still say what lapsed.

alter table public.orgs add column if not exists plan_source      text;
alter table public.orgs add column if not exists plan_expires_at  timestamptz;
alter table public.orgs add column if not exists apple_product_id text;

-- Backfill before the default so the intent is explicit rather than a side
-- effect of ADD COLUMN, and so a replay updates zero rows.
update public.orgs set plan_source = 'trial' where plan_source is null;

alter table public.orgs alter column plan_source set default 'trial';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.orgs'::regclass
       and conname  = 'orgs_plan_source_check'
  ) then
    alter table public.orgs
      add constraint orgs_plan_source_check
      check (plan_source is null or plan_source in ('manual','trial','apple'));
  end if;
end $$;

comment on column public.orgs.plan_source is
  'Who decided this plan: trial (signup default) | apple (a verified App Store '
  'subscription) | manual (an owner grant — apply_apple_entitlement() never '
  'overwrites it, up or down). Server-controlled: not in the tenant UPDATE grant.';
comment on column public.orgs.plan_expires_at is
  'End of the current paid period, or of the billing grace window. Read by '
  'effective_plan(): more than 16 days past on an apple plan reads `free`.';
comment on column public.orgs.apple_product_id is
  'Last App Store product id this org held. Kept after expiry as history.';

-- Re-assert the column-scoped UPDATE grant from 0005. Nothing new is granted:
-- this is here so the three columns above are unwritable by a client even on a
-- database where a bare `grant update on public.orgs` was run at some point.
revoke update on public.orgs from authenticated, anon;
grant  update (name, handle, space_type, brand_kit) on public.orgs to authenticated;

-- ── 4. apply_apple_entitlement() — the single write path ───────────────────
--
-- Upserts the subscription row and, unless the org is manual (RULE 2), sets the
-- plan columns:
--
--   active | grace                     -> plan = p_plan,  source 'apple'
--   expired | revoked | refunded       -> plan = 'free',  source 'apple'
--
-- Two guards that only matter when reality is messier than the happy path:
--
--   STALE SIGNAL. If the stored expiry is already LATER than the incoming one
--   and the incoming status is not a revocation, the row's status/expiry/plan
--   are left alone (only last_notification_type is recorded). That is Apple's
--   documented out-of-order delivery, handled instead of assumed away.
--
--   A SECOND SUBSCRIPTION. A lapse only downgrades the org when no OTHER
--   apple_subscriptions row for that org is still active or in grace — so an
--   org that re-subscribed under a new originalTransactionId is not dropped to
--   `free` by the old one finally expiring.
--
-- Returns jsonb: { ok, plan, source, expires_at, status, org_updated, reason }.

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

  -- Out-of-order delivery: an older expiry for a non-terminal status is news
  -- we already have. Record that the notification arrived; change nothing else.
  if found
     and p_status in ('active','grace','expired')
     and v_existing.expires_at is not null
     and p_expires_at is not null
     and p_expires_at < v_existing.expires_at
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
    org_id                 = coalesce(excluded.org_id, s.org_id),
    user_id                = coalesce(excluded.user_id, s.user_id),
    product_id             = coalesce(excluded.product_id, s.product_id),
    plan                   = coalesce(excluded.plan, s.plan),
    environment            = coalesce(excluded.environment, s.environment),
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

  -- RULE 2: an owner-granted plan is Apple-proof, in both directions.
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
    select count(*) into v_others
      from apple_subscriptions x
     where x.org_id = v_existing.org_id
       and x.original_transaction_id <> v_existing.original_transaction_id
       and x.status in ('active','grace');

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
  'service_role only.';

-- ── 5. effective_plan(): the apple expiry arm ──────────────────────────────
--
-- The trial arm is reproduced verbatim from 0010 and stays FIRST, so every
-- existing trial behaviour is byte-identical. The new arm is the backstop for a
-- notification that never arrived: 16 days is Apple's maximum billing-retry
-- grace period, so a paid plan whose expiry is further past than that is gone
-- regardless of what any webhook did or did not say.

create or replace function public.effective_plan(p_org uuid)
returns text
language sql stable
set search_path = public
as $$
  select case
           when o.plan = 'trial' and o.trial_ends_at is not null and o.trial_ends_at < now()
             then 'free'
           when o.plan_source = 'apple'
                and o.plan_expires_at is not null
                and o.plan_expires_at < now() - interval '16 days'
             then 'free'
           else coalesce(o.plan, 'trial')
         end
    from orgs o where o.id = p_org;
$$;

-- CREATE OR REPLACE keeps the existing privileges; re-asserted so a fresh
-- replay of this file alone lands in the same state as 0010 + 0019.
revoke execute on function public.effective_plan(uuid) from public, anon;
grant  execute on function public.effective_plan(uuid) to authenticated, service_role;

-- ── 6. RLS: both new tables are service-role only ──────────────────────────
--
-- RLS on with NO policies + every tenant grant revoked = a tenant SELECT is a
-- hard permission error and a tenant write is impossible. Same posture as
-- admin_allowlist (0017 §3). The app reads its own subscription state through
-- GET /me, which the server assembles with the service-role client.

alter table public.apple_subscriptions enable row level security;
alter table public.apple_notifications enable row level security;

revoke all on public.apple_subscriptions from authenticated, anon;
revoke all on public.apple_notifications from authenticated, anon;
