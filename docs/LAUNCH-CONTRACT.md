# Launch wave contract — subscriptions, events, key probe, UI walk (2026-09-05)

Branch `launch` (off `ai-router`). Five agents in parallel. File ownership is strict;
cross-file needs go in `HANDOFF-<agent>.md`. Shared Swift API surfaces are added as
NEW files using the `protocol X` + `extension LiveAPIClient: X` + `extension
MockAPIClient: X` + `model.api as? X` pattern (see `AdminRoutingAPI` in
`SettingsView.swift`) — nobody edits `Networking/APIClient.swift`.

## Plans and product IDs (one source of truth: `plan_entitlements`)

| plan | price_cents | App Store product id (monthly) | (annual, 2 months free) |
|---|---|---|---|
| starter | 4900 | `com.rendprop.app.starter.monthly` | `com.rendprop.app.starter.annual` = 49000 |
| pro | 9900 | `com.rendprop.app.pro.monthly` | `com.rendprop.app.pro.annual` = 99000 |
| team | 24900 | `com.rendprop.app.team.monthly` | `com.rendprop.app.team.annual` = 249000 — **NOT SOLD AT LAUNCH — needs Apple's higher price points** |

**Team Yearly is pulled from the launch lineup (2026-09-05).** App Store Connect's yearly
price points stop at USD 1,000 unless Apple grants extended ones, so `$2,490.00` cannot be
sold yet: **Starter and Pro sell monthly or yearly, Team sells monthly.** The id above is
still defined and still maps to `team` for entitlements — it is listed in
`RendpropProducts.notSoldAtLaunch` (`Products.swift`), which keeps it out of the ids the
app requests from StoreKit. Emptying that set re-enables it in one line once Apple grants
the price points. Details: `docs/handoff/launch-P1.md` §5.3.

`trial` (7 days, card on file) is Apple's **introductory offer** on each product — not a
separate product. `free` is the lapsed floor: no product, it's what an expired
subscription becomes. `solo` is a legacy alias of `starter` — never sell it.
Subscription group id (ASC): `rendprop_plans`. All three products in ONE group so
upgrades/downgrades are Apple-managed.

## Entitlement sync (P1 ↔ P2)

```
POST /me/entitlement            (owner JWT)
{ "signed_transaction": "<JWS from StoreKit 2 Transaction.jwsRepresentation>",
  "signed_renewal_info": "<JWS, optional>" }
→ 200 { "plan": "pro", "source": "apple", "expires_at": "...", "product_id": "...",
        "original_transaction_id": "...", "environment": "Sandbox|Production" }
```
Server verifies the JWS chain against Apple's root CA (x5c), checks `bundleId ==
com.rendprop.app`, maps `productId` → plan, upserts `apple_subscriptions`, and sets
`orgs.plan` via a SECURITY DEFINER RPC `apply_apple_entitlement(...)` that only the
service role may call. A downgrade or expiry sets `orgs.plan = 'free'`.

```
POST /apple-subscriptions/notify   (NO JWT — Apple calls it; verify_jwt false)
{ "signedPayload": "<App Store Server Notifications v2 JWS>" }
```
Verify the JWS the same way; handle `SUBSCRIBED`, `DID_RENEW`, `DID_CHANGE_RENEWAL_STATUS`,
`EXPIRED`, `GRACE_PERIOD_EXPIRED`, `REFUND`, `REVOKE`, `DID_FAIL_TO_RENEW`. Idempotent on
`notificationUUID`. Unknown types are logged and 200'd (never 5xx Apple).

`GET /me` gains (additive, all optional): `plan_source: "apple"|"manual"|"trial"|null`,
`plan_expires_at`, `apple_product_id`.

Secrets (NAMES): `APPLE_BUNDLE_ID` (= com.rendprop.app), and for the optional App
Store Server API lookups `APPLE_ASC_ISSUER_ID`, `APPLE_ASC_KEY_ID`, `APPLE_ASC_PRIVATE_KEY_P8`
(these may already exist as `APPLE_*` for sign-in; reuse names if identical).

## Events (P3)

```
POST /events        (owner JWT when signed in; anon key + device id when not)
{ "device_id": "uuid (app-generated, not IDFA)", "session_id": "uuid",
  "app_version": "1.0 (1)", "os": "iOS 26.4", "events": [
    { "name": "app_open", "t": "iso", "props": {} },
    { "name": "home_created", "t": "...", "props": { "space_type": "real_estate" } } ] }
→ 202 { "accepted": N }
```
Event vocabulary (exact strings): `app_open`, `signup`, `signin`, `home_created`,
`capture_started`, `capture_finished`, `render_finished`, `tour_published`,
`ai_photo_edit`, `reel_made`, `voiceover_added`, `aerial_made`, `paywall_viewed`,
`purchase_started`, `purchase_completed`, `purchase_failed`, `restore`, `crash`
(MetricKit diagnostic summary, no PII), `error` (non-fatal, category only).
No PII in props, ever. No email, no address, no photo.

SKAdNetwork conversion values (iOS 16.1+ `SKAdNetwork.updatePostbackConversionValue`):
0 = install, 1 = signup, 2 = home_created, 3 = tour_published, 4 = paywall_viewed,
5 = purchase_completed. Coarse: low/medium/high mapped 0–1 / 2–3 / 4–5.

`GET /admin/funnel?window=7d|30d` → per-step counts + conversion %, plus crash count.

## Key probe (P4)

```
GET /admin/providers/probe     (admin only; rate 6/hour/admin)
→ { "checked_at": "...", "results": [
     { "key": "fal", "configured": true, "ok": true, "latency_ms": 212, "how": "GET https://fal.run/health (authed)" },
     { "key": "elevenlabs", "configured": true, "ok": false, "latency_ms": 380, "error_class": "auth", "how": "GET /v2/voices?page_size=1" } ] }
```
Rule: the cheapest AUTHENTICATED call that proves the key works and costs $0 —
a list/models/voices/whoami endpoint. NEVER a generation. NEVER any key material in
the response or logs. `error_class` ∈ auth | network | rate_limit | other.

## UI walk (P5)

XCUITest target `RendpropUITests` (project.yml addition). One test `testWalk` that
launches with `-uiTesting` (Mock API, signed-in mock, admin mock), then screenshots
each screen as an `XCTAttachment` named `01-home`, `02-add-home`, `03-photo-studio`,
`04-reel-studio-voice`, `05-settings`, `06-owner-console`, `07-routing`. Every
screenshot attachment is `lifetime = .keepAlways`. The bridge runs it on the booted
simulator and extracts PNGs from the `.xcresult` with `xcrun xcresulttool`.
