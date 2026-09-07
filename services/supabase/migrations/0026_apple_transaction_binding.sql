-- 0026: apple_transaction_binding — the concurrent first-bind race 0021 missed
-- (2026-09-07, external release audit P0/P1: "unbound StoreKit transactions can
-- be claimed by the wrong account").
--
-- ── WHAT WAS ASKED, AND WHAT WAS ALREADY THERE ──────────────────────────────
--
-- The paywall is reachable signed out, so a purchase can carry no
-- appAccountToken (functions/me/index.ts's handleEntitlement soft-accepts an
-- absent one — the shipped build, in App Review, never sets one). The ask: once
-- such an unbound transaction binds to WHOEVER submits it, that binding must be
-- permanent — keyed on originalTransactionId — and any LATER attempt by a
-- different account to claim the same transaction must be refused with a clear
-- 409, never a silent re-bind.
--
-- Reading 0019/0021 first (as directed) before writing anything: that binding
-- already exists and is NOT being duplicated here.
--   • apple_subscriptions.original_transaction_id is the primary key (0019).
--   • apply_apple_entitlement() already refuses a p_org that disagrees with an
--     EXISTING row's org_id, raising RP409 inside the row lock (0021 FINDING 1).
--   • functions/me/index.ts has the same friendly pre-check (a plain SELECT)
--     before it ever calls the RPC, so the common case never even reaches SQL.
-- For the SEQUENTIAL case — org A links it, then org B tries — this was already
-- correct before this migration, and is unchanged: see invariants.sql's
-- "a subscription bound to one org cannot be claimed by another (RP409)".
--
-- ── THE GAP: 0021's GUARD READS A ROW THAT ISN'T THERE YET ──────────────────
--
-- 0021's guard is `if found and v_existing.org_id is not null and p_org <>
-- v_existing.org_id then raise RP409`. `found` comes from `select … for update`
-- run BEFORE the insert. `for update` locks rows that EXIST; it cannot lock — or
-- even see — a row that has not been inserted yet. So for a transaction NOBODY
-- has bound before (exactly the unbound-JWS scenario this fix is about), two
-- overlapping calls both observe `found = false`, both skip the guard entirely,
-- and both fall through to the same `insert … on conflict (original_
-- transaction_id) do update`. Whichever call's INSERT commits durably second
-- resolves as a CONFLICT against the first's now-committed row — and 0021's
-- SET clause was `org_id = coalesce(excluded.org_id, s.org_id)`, which prefers
-- the INCOMING value. So the second call's own org_id silently overwrites the
-- first's, with no exception raised: a successful-looking re-bind, the exact
-- thing FINDING 1 was written to prevent, just moved one layer down.
--
-- REPRODUCED on a scratch Postgres 16 (0001…0023 replayed), two genuinely
-- concurrent sessions (a temporary copy of the 0021 function with a pg_sleep
-- injected right after its `select … for update`, so both sessions are proven
-- to observe found=false before either inserts), same brand-new
-- original_transaction_id, different org:
--
--   session A (org A) -> commits first  -> {"ok":true,"org_updated":true,"bound_org":"A"}
--   session B (org B) -> commits second -> {"ok":true,"org_updated":true,"bound_org":"B"}
--   apple_subscriptions.org_id afterwards: B
--   orgs.plan afterwards: BOTH A and B read 'pro' -- ONE purchase, TWO paid
--   workspaces, and NEITHER caller was ever told anything was wrong.
--
-- This is not hypothetical timing-sensitive luck: `for update` on an absent row
-- is a documented Postgres phantom-read gap (SELECT FOR UPDATE locks existing
-- tuples; it has no equivalent of a gap/predicate lock on a key that has no row
-- yet), and READ COMMITTED is what Postgres and PostgREST both run with here —
-- nothing in this repo raises the isolation level (ci-bootstrap.sql grep says
-- so), so the gap is live in production exactly as reproduced above.
--
-- ── THE FIX: STICKY ORG_ID, PLUS A POST-WRITE RE-CHECK ──────────────────────
--
-- Same pattern this very function already uses for `environment` (0021 FINDING
-- 3, `environment = coalesce(s.environment, excluded.environment)` — prefer
-- what is ALREADY stored): the ON CONFLICT SET clause for org_id is reordered
-- to `coalesce(s.org_id, excluded.org_id)`. On a genuine first link (existing
-- org_id is null) this changes nothing — the incoming value still wins. On the
-- race, it means whichever call's row actually persisted keeps ITS org_id, and
-- the loser's conflicting write no longer moves it.
--
-- That alone would silently protect the DATA while leaving the LOSING caller
-- believing it succeeded (org_updated:true, wrong org echoed back) — not the
-- "clear 409-style error, never silently re-bind" the fix calls for. So the
-- write is followed by a re-check of the value the upsert ACTUALLY produced
-- (`v_existing`, freshly read via `returning * into v_existing`): if it now
-- disagrees with p_org, this call raises the SAME RP409 the pre-existing guard
-- raises for the sequential case — which also rolls back whatever this
-- statement itself just wrote, so a losing call never leaves so much as a
-- last_transaction_id behind.
--
-- Scoped to org_id only, deliberately: p_environment/p_product_id/p_status/…
-- all come from the DECODED, VERIFIED JWS itself, so two calls racing on the
-- SAME original_transaction_id carry IDENTICAL values for all of them — only
-- p_org (and p_user) differ, because those two alone are supplied by the
-- calling edge function from ITS caller's own session, never from the JWS. That
-- is also why user_id is left as `coalesce(excluded.user_id, s.user_id)`,
-- unchanged: it is informational (the FK's ON DELETE SET NULL target, per
-- 0019), decides no entitlement, and re-checking it would only add churn to a
-- migration that is otherwise a pure function replacement.
--
-- RE-REPRODUCED against the fixed function with the identical two-session
-- harness (both directions — A-first and B-first — to rule out an ordering
-- artifact rather than a real "first commit wins"): the second-to-commit call
-- now raises RP409, its transaction rolls back in full, and
-- apple_subscriptions.org_id / orgs.plan reflect ONLY the winner, whichever
-- session that was.
--
-- Same signature as 0019/0021 (byte-identical argument list — PostgREST
-- resolves this RPC by name, and invariants.sql asserts one overload per
-- function), same grants, same everything else. Idempotent: `create or
-- replace function`; a replay changes nothing.

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

  -- 0021 FINDING 1, sequential case: an EXISTING binding beats a disagreeing
  -- p_org. Unreachable for a brand-new original_transaction_id — `found` is
  -- false until some call has actually inserted a row — which is exactly the
  -- gap 0024 closes below.
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
    -- 0024: STICKY, not "prefer incoming". Two calls that both saw found=false
    -- for a brand-new key (the concurrent-first-bind race — see header) both
    -- reach this upsert; whichever commits durably SECOND now keeps the FIRST
    -- committed org_id instead of overwriting it. On every non-racing path this
    -- is a no-op: a genuine first link has s.org_id = null, so the incoming
    -- value still wins via coalesce's fallback.
    org_id                 = coalesce(s.org_id, excluded.org_id),
    -- user_id is informational only (0019: the ON DELETE SET NULL target) and
    -- decides no entitlement, so it is left exactly as 0019/0021 had it.
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

  -- 0024: the re-check the sequential guard above cannot do for a first bind —
  -- it runs on `found`, captured BEFORE this statement wrote anything. This
  -- runs on what the upsert actually persisted. Raising here rolls back this
  -- entire call (including whatever this statement itself just wrote), so a
  -- call that loses the race leaves no trace — not a wrong org_id, not a stray
  -- last_transaction_id — and its caller gets the same RP409 copy as the
  -- sequential case, never a 200 with somebody else's binding.
  if v_existing.org_id is not null and p_org is not null and v_existing.org_id <> p_org then
    raise exception 'RP409: This subscription is already used by another account';
  end if;

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

-- CREATE OR REPLACE keeps the 0019/0021 privileges; re-asserted so this file
-- alone lands in the same state on a database that has only seen 0019.
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
  '— except on a manual (owner-granted) plan, which it never changes. Refuses '
  '(RP409) a p_org that disagrees with the subscription''s binding both when an '
  'existing row is read (0021) and when the write itself would move a binding '
  'another concurrent call already made (0024 — the sticky org_id upsert plus a '
  'post-write re-check), refuses to let one environment overwrite the other, and '
  'treats an earlier expiry as stale only when the product is unchanged. '
  'service_role only.';
