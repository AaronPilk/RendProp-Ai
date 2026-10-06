# apple-subscriptions — App Store Server Notifications V2

**6 October delivery:** the coordinated 25-function backend deployment includes
this webhook and `me`, from reviewed `5eeb783`, with signature authentication
and `me` JWT verification preserved. See
[the actual rollout](../../../../docs/handoff/CAS-AND-STUDIO-ROLLOUT-20261006.md).
The older source-only labels below belong to the earlier review checkpoint.
No retail, trial or App Review funds were seeded. The newer atomic limited-trial
reservation/converter candidate is separate, disabled and not deployed. Neither
deployment nor local tests establish an actual Apple purchase/restore/renewal.

Apple tells this endpoint when a subscription starts, renews, lapses, is
refunded or is revoked. It verifies Apple's signature itself, then applies the
result through the service-only `apply_apple_entitlement_v2()` chronology writer.
The original `apply_apple_entitlement()` compatibility writer remains subject to
the same retail environment fence.

This README was reconciled with the committed handler on 24 September 2026.
It documents deployment and owner-run purchase checks; it is not a fresh
notification-delivery or App Store Connect receipt. The
[24 September Studio release](../../../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md)
did not redeploy this function or perform a phone purchase.

The [6 October launch candidate](../../../../docs/handoff/LAUNCH-READINESS-20261006.md)
records the current **source-only** Sandbox and finite App Review funding authority.
The [5 October full-system audit](../../../../docs/handoff/FULL-SYSTEM-AUDIT-20261005.md)
is its predecessor. Synthetic local verification is not evidence that these
migrations or the coordinated handlers/native copy are deployed. No retail,
trial or review funding allocation is seeded by the migrations. The 24 September
record remains historical.

| Route | Auth | Answers |
|---|---|---|
| `POST /apple-subscriptions/notify` | **none** — Apple's JWS *is* the auth | `200 {ok, duplicate?, applied?, ignored?, pending?}` · `401` bad signature · `400` malformed · `413` body too large · `429` flood · `503` database unavailable |
| `GET /apple-subscriptions/health` | none | `{ok, configured, schema_ready, bundle_id_from_env, bundle_id, products[], checked_at}` |

The sibling route on the device side is `POST /me/entitlement` (owner JWT), in
`functions/me/index.ts`. Between them: the app links a purchase to a workspace,
Apple keeps that link up to date.

---

## 1. Deploy — `--no-verify-jwt` is not optional

Apple has no Supabase JWT. With the gateway's JWT check on, every notification
is rejected before this code runs, so notification-driven entitlement sync cannot
work. This is an external webhook: signature validation happens in the handler,
consistent with [Supabase's webhook authentication guidance](https://supabase.com/docs/guides/functions/auth#external-webhooks).

The source uses a nonstandard repository layout. Follow the
[targeted release staging guidance](../README.md#production-release): prepare a
reviewed scratch workdir containing standard `supabase/functions` and
`supabase/config.toml`, including the affected handlers and shared imports from
the same revision. Run these commands against that staging directory, not
against `services/supabase` directly:

```bash
supabase functions deploy --help
supabase functions deploy apple-subscriptions --workdir <release-stage> --project-ref <project-ref> --no-verify-jwt
supabase functions deploy me --workdir <release-stage> --project-ref <project-ref>  # preserve verify_jwt = true
```

The staged `supabase/config.toml` must preserve `me` with `verify_jwt = true`
and the webhook setting:

```toml
[functions.apple-subscriptions]
verify_jwt = false
```

Ensure the complete schema prerequisites, including `0019_subscriptions.sql`
and `0021_launch_hardening.sql`, are applied before deploying. The latter
enforces workspace/environment binding inside the shared RPC, handles product
crossgrades and adds the account-token field used by `me`. Reconcile the
existing migration ledger before applying files; do not replay historical
migrations blindly. `/health` only checks that `apple_subscriptions` is
readable, not that every RPC, grant or later migration is correct.

The current source additionally requires the reviewed subscription chronology
and cutover migrations. Do not activate
`20261005220709_apple_sandbox_authority_fence.sql` without coordinated `me`,
webhook and native handling, explicit testing access and the finite App Review
gate below. The fence refuses an unknown existing writer body rather than
overwriting it. Preserve `me` JWT verification and the webhook's signature auth.

## 2. Secrets

One name, and it is not a secret in the security sense — the bundle id ships in
the app binary and is listed publicly on the App Store. It is an env var so a
rename never needs a code change.

| Name | Default | Used for |
|---|---|---|
| `APPLE_BUNDLE_ID` | `com.rendprop.app` | every transaction and notification must carry this `bundleId`, or it is a 400 |

```bash
supabase secrets set --project-ref <project-ref> APPLE_BUNDLE_ID=com.rendprop.app
```

**No App Store Server API key is needed.** The JWS Apple signs — on the device
and in the notification — carries the transaction, the renewal info and the
certificate chain that proves them. `APPLE_ASC_ISSUER_ID`, `APPLE_ASC_KEY_ID`
and `APPLE_ASC_PRIVATE_KEY_P8` would only be needed to *poll* Apple's
`/inApps/v1/subscriptions/{id}` endpoints — a future upgrade if we ever want to
reconcile state Apple never pushed. Nothing here reads them.

(The four `APPLE_TEAM_ID` / `APPLE_CLIENT_ID` / `APPLE_KEY_ID` /
`APPLE_PRIVATE_KEY_P8` secrets are *Sign in with Apple*, used by
`POST /me/apple-code` and account deletion. Unrelated to subscriptions.)

## 3. Point App Store Connect at it

App Store Connect → your app → **General → App Information → App Store Server
Notifications**. Set **Version 2** and paste:

```
https://<project-ref>.supabase.co/functions/v1/apple-subscriptions/notify
```

There are two fields — **Production Server URL** and **Sandbox Server URL**.
Paste the same URL into both. The source verifies both signed environments;
Production uses the retail subscription ledger, while the 5 October fence routes
Sandbox to a separate test-only receipt ledger. The historical deployment does
not establish that this new separation is live.

Before pasting, confirm the endpoint is live and the schema landed:

```bash
curl -s https://<project-ref>.supabase.co/functions/v1/apple-subscriptions/health
# {"ok":true,"configured":true,"schema_ready":true,"bundle_id":"com.rendprop.app",...}
```

`configured: false` means either `APPLE_BUNDLE_ID` is unset or migration 0019
has not been applied — `schema_ready` says which.

## 4. Replay a notification from App Store Connect

Same screen, **Send Test Notification** (the "Request a Test Notification"
button). Apple posts a signed `TEST` notification to the Production URL
immediately and shows you the delivery result, including the HTTP status we
returned.

What to expect:

* `200 {"ok":true}` with `"applied":false, "ignored":"no_entitlement_change"` —
  a `TEST` notification carries no transaction, so nothing is entitled. That is
  success.
* Re-delivery of the **same signed notification UUID** answers
  `{"ok":true,"duplicate":true}`. A separately requested test notification may
  have a new UUID; pressing the request button twice is not a deduplication test.
* Every delivery is stored. To see it:

```sql
select notification_type, subtype, environment, pending, received_at
  from apple_notifications
 order by received_at desc limit 20;
```

Apple also keeps the last test result under **Get Test Notification Status**,
and the History screen lets you re-request past notification types for a date
range — use it after fixing an outage to backfill.

## 5. Test with a Sandbox tester

1. App Store Connect → **Users and Access → Sandbox → Test Accounts** → create
   one. Use an email that is *not* an existing Apple ID.
2. On the device: Settings → App Store → **Sandbox Account** → sign in as the
   tester. (Do not sign the main Apple ID out.)
3. Use a dedicated sandbox tester with the owner's test build. Renewal timing
   is configurable per account; do not assume a fixed half-hour lifecycle.
   Apple currently documents a default one-month period of five minutes and
   up to 12 automatic renewals; see
   [sandbox account settings](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/manage-sandbox-apple-account-settings/).
   TestFlight has its own [purchase-testing guidance](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight/).
4. The app calls `POST /me/entitlement` with the JWS StoreKit handed it; Apple
   may also post `SUBSCRIBED`. Under the source-only fence, this purchase confirms
   an existing explicit test grant; it cannot activate a retail plan. Production
   notification ordering is described under *pending notifications* below.

After the coordinated fence rollout, inspect authorized test receipts separately:

```sql
select original_transaction_id, product_id, status, signed_at, updated_at
  from apple_sandbox_receipts order by updated_at desc limit 10;
```

Verify that the workspace's retail subscription and plan did not change:

```sql
select original_transaction_id, plan, status, environment, expires_at, auto_renew
  from apple_subscriptions order by updated_at desc limit 10;

select id, plan, plan_source, plan_expires_at, apple_product_id
  from orgs where id = '<org uuid>';
```

Cancel auto-renewal through the sandbox account's subscription controls, then
observe renewal-status change and eventual expiry. Cancelling renewal does not
immediately end the already-paid period; verify the signed dates and resulting
notification types instead of expecting an instant lapse.

### Sandbox authority fence — source only

`record_apple_sandbox_receipt` verifies current named-account and workspace
owner/admin authority, and requires an existing service-owned internal/private
testing grant or the candidate's finite App Review funding authority. It stores
the original transaction's immutable actor/workspace
binding in `apple_sandbox_receipts`; signed chronology prevents an older receipt
from overwriting a newer one. Sandbox never changes the retail plan, source,
expiry, cancellation, contract or `apple_subscriptions` binding. The selected
Sandbox product never chooses the grant's allowance. Production retains its
verified chronology and sticky retail environment binding.

Without explicit test access, `POST /me/entitlement` returns 403 with
`sandbox_testing_required`. The coordinated native source keeps that transaction
pending and offers Restore after access is authorized. Do not finish a transaction
whose server synchronization has not been confirmed. A Sandbox webhook cannot
create test access or a retail subscription.

Both TestFlight and App Review purchases use Sandbox. The 6 October candidate
adds a dedicated finite App Review funding grant, restricted feature/seat access
and serving reservations bounded over the grant lifetime. A selected Sandbox
product does not supply money or choose those limits. Provisioning remains
service-only; the migrations create no review account or funding allocation.
**Rollout is gated:** authorize actual review funding, verify the coordinated
schema/handlers and complete purchase/restore acceptance before claiming reviewer
readiness. Existing internal grants are separate from this finite review authority;
rolling allowance windows alone are not a lifetime serving limit.

### Pending notifications

For Production, if Apple's notification arrives before the app has ever called
`POST /me/entitlement`, there is no workspace to credit yet. The row is stored
with `pending = true` and the computed entitlement attached; the next
`POST /me/entitlement` for that `originalTransactionId` replays it in receipt
order and reports how many in `replayed_notifications`. Nothing is dropped.

```sql
select notification_uuid, notification_type, original_transaction_id, received_at
  from apple_notifications where pending order by received_at;
```

A row that stays `pending` for a long time means a purchase Apple knows about
that no signed-in device has ever claimed.

## 6. What each notification type does

The retail effects below describe verified Production subscriptions. Under the
source-only fence, Sandbox events update only an already bound authorized test
receipt and do not change the separate grant.

| Type | Effect |
|---|---|
| `SUBSCRIBED`, `DID_RENEW`, `DID_CHANGE_RENEWAL_PREF`, `DID_CHANGE_RENEWAL_STATUS`, `PRICE_INCREASE`, `OFFER_REDEEMED`, `RENEWAL_EXTENDED`, `REFUND_DECLINED`, `REFUND_REVERSED`, `METADATA_UPDATE` | believe the signed transaction: `active` while unexpired, `grace` inside a billing-grace window, `expired` otherwise |
| `DID_FAIL_TO_RENEW` | `grace` when the subtype is `GRACE_PERIOD` and the paid period has ended — the plan is kept until `gracePeriodExpiresDate`. Before expiry it stays `active`; without grace, `EXPIRED` follows and does the work |
| `EXPIRED`, `GRACE_PERIOD_EXPIRED` | `expired` → `orgs.plan = 'free'` |
| `REFUND` | `refunded` → `free` |
| `REVOKE` | `revoked` → `free` |
| `TEST`, `CONSUMPTION_REQUEST`, `RENEWAL_EXTENSION`, `EXTERNAL_PURCHASE_TOKEN`, `ONE_TIME_CHARGE`, `MIGRATION` | stored, no entitlement change |
| anything else | stored, logged **by name**, `200`. Apple shipping a new type is not an outage |

Two things a lapse will **not** do:

* downgrade an org whose `plan_source = 'manual'` (an owner-granted plan is
  Apple-proof in both directions), and
* downgrade an org that still has another `active`/`grace` subscription.

## 7. Troubleshooting

| Symptom | Cause |
|---|---|
| Apple's test notification shows `401` | deployed without `--no-verify-jwt` — the gateway rejected it before this code ran |
| `401 {"code":"unauthorized"}` in our logs | the signature did not verify. The message names the check (`chain does not end at the pinned Apple root`, `leaf certificate has expired`, `payload signature`, …) |
| `400 This notification is for a different app` | `APPLE_BUNDLE_ID` does not match the app that sent it |
| `configured:false` on `/health` | `APPLE_BUNDLE_ID` unset, or migration 0019 not applied (`schema_ready` distinguishes them) |
| plan does not change but the row is stored | inspect `payload->>'verdict'`, subscription dates, `orgs.plan_source`, and other active subscriptions. The handler exposes `environment_mismatch`, `unmapped_product`, `no_entitlement_change`, `no_transaction` or `refused`; it does not forward every RPC reason to the HTTP response. |
| everything answers `duplicate: true` | the UUID is already stored; inspect its recorded verdict and the recovery limits below before assuming entitlement application succeeded |
| `POST /me/entitlement` returns `sandbox_testing_required` after the source fence rollout | the current account/workspace lacks explicit authorized testing access; retain the transaction and restore after authorization rather than granting retail access from its Sandbox product |

## 8. Limits, refusal and recovery

The handler limits request bodies to **128 KiB** before JSON buffering and
`signedPayload` to **64 KiB** of characters. Its durable limiter permits 240
requests per 60 seconds for a source `cf-connecting-ip`; without that header,
requests share the `unknown` bucket. Apple JWS verification covers the outer
notification and any nested transaction/renewal blobs, with the pinned Apple
root and bundle checks.

A deterministic `RPnnn:` refusal from the RPC is recorded and returns 200 with
`ignored: "refused"`; repeating the same UUID is then a no-op. Database failure
returns 503 and attempts to remove the ledger row so a retry can apply it.
That cleanup is best-effort: if deletion also fails, a later delivery may be
classified duplicate without applying the entitlement. Investigate stored rows
and RPC failures instead of treating every duplicate as proof of successful
plan application.

Logs include notification type, subtype, UUID, environment, verdict, unmapped
product identifiers and deterministic RPC refusal messages. Raw signed blobs,
account tokens and credentials must not be logged.

## 9. Local checks

From the repository root:

```bash
deno test --allow-env --allow-read \
  services/supabase/functions/apple-subscriptions/notify.test.ts \
  services/supabase/functions/_shared/applejws.test.ts
```

This command passed **53 tests** during the 24 September documentation refresh.
The first run may fetch pinned test imports. `notify.test.ts` checks pure
notification decisions; `applejws.test.ts` checks signature/parsing behavior.
Neither proves the deployed database, gateway setting, Apple delivery or a
real StoreKit purchase. Schema binding and concurrency need the disposable
Postgres checks described in the broader Supabase test setup.

Current source-only authority, chronology and confirmed-trial proofs run against
disposable synthetic databases:

```bash
python3 tools/audit/run_backend_billing_authority.py
python3 tools/audit/run_subscription_chronology.py
python3 tools/audit/run_subscription_trial_regression.py
```

These checks do not create live testing grants, change App Store Connect, or
establish a real-device purchase or App Review acceptance.
