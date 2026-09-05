# apple-subscriptions — App Store Server Notifications V2

Apple tells this endpoint when a subscription starts, renews, lapses, is
refunded or is revoked. It verifies Apple's signature itself, then applies the
result through `apply_apple_entitlement()` (migration `0019_subscriptions.sql`).

| Route | Auth | Answers |
|---|---|---|
| `POST /apple-subscriptions/notify` | **none** — Apple's JWS *is* the auth | `200 {ok, duplicate?, applied?, ignored?, pending?}` · `401` bad signature · `400` malformed · `429` flood |
| `GET /apple-subscriptions/health` | none | `{ok, configured, schema_ready, bundle_id, products[], checked_at}` |

The sibling route on the device side is `POST /me/entitlement` (owner JWT), in
`functions/me/index.ts`. Between them: the app links a purchase to a workspace,
Apple keeps that link up to date.

---

## 1. Deploy — `--no-verify-jwt` is not optional

Apple has no Supabase JWT. With the gateway's JWT check on, every notification
is rejected before this code runs, Apple retries for about a day, gives up, and
subscriptions stop syncing with no error anywhere you would look.

```bash
cd services/supabase
supabase functions deploy apple-subscriptions --no-verify-jwt
supabase functions deploy me            # normal — owner JWT
```

Or in `supabase/config.toml`:

```toml
[functions.apple-subscriptions]
verify_jwt = false
```

Apply migration `0019_subscriptions.sql` **before** deploying either function —
both call `apply_apple_entitlement()`, and `me` also selects the three new
`orgs` columns.

## 2. Secrets

One name, and it is not a secret in the security sense — the bundle id ships in
the app binary and is listed publicly on the App Store. It is an env var so a
rename never needs a code change.

| Name | Default | Used for |
|---|---|---|
| `APPLE_BUNDLE_ID` | `com.rendprop.app` | every transaction and notification must carry this `bundleId`, or it is a 400 |

```bash
supabase secrets set APPLE_BUNDLE_ID=com.rendprop.app
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
Paste the same URL into both: the handler accepts `Sandbox` and `Production`,
stores which one each subscription belongs to, and refuses to let one move the
other.

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
* Press the button twice and the second delivery answers
  `{"ok":true,"duplicate":true}`: Apple resends with the same
  `notificationUUID`, and the uuid is the primary key of `apple_notifications`.
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
3. Run the app from Xcode or TestFlight and buy a plan. Sandbox renewals are
   compressed — a 1-month subscription renews every 5 minutes and auto-renews 6
   times before it lapses, so a full lifecycle takes about half an hour.
4. The app calls `POST /me/entitlement` with the JWS StoreKit handed it; Apple
   posts `SUBSCRIBED` here at roughly the same moment. Either order works — see
   *pending notifications* below.

Watch it land:

```sql
select original_transaction_id, plan, status, environment, expires_at, auto_renew
  from apple_subscriptions order by updated_at desc limit 10;

select id, plan, plan_source, plan_expires_at, apple_product_id
  from orgs where id = '<org uuid>';
```

To force the lapse path without waiting: in the sandbox, **Settings → App Store
→ Sandbox Account → Manage → cancel** the subscription, and Apple sends
`DID_CHANGE_RENEWAL_STATUS` then `EXPIRED`.

### Sandbox cannot touch production

A subscription is stored with the environment it was first seen in. A `Sandbox`
notification for a row recorded as `Production` (or the reverse) is stored and
answered `{"ignored":"environment_mismatch"}` — never applied. A tester cannot
change what a paying customer gets.

### Pending notifications

If Apple's notification arrives before the app has ever called
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
| plan does not change but the row is stored | check `apple_notifications.payload->>'verdict'` and the response's `ignored` field: `manual_plan`, `environment_mismatch`, `unmapped_product` and `another_subscription_active` are all deliberate |
| everything answers `duplicate: true` | Apple is resending a uuid we already stored; the first delivery did the work |

Logs carry only the notification type, subtype, uuid and environment. No
payload, no account token, no credential — by design, and asserted by review
rather than by hope.
