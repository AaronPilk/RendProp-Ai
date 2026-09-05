# HANDOFF-P2 — Apple subscription verification + entitlement sync

Branch `launch-p2`, five commits, all checks green. Nothing deployed, nothing
run against production.

```
b0e6b7f  Add Apple JWS verifier: pinned root, real chain check, 20 tests
51e3bdc  Add migration 0019: apple_subscriptions, notifications, entitlement RPC
ea0d59b  Add /apple-subscriptions/notify and POST /me/entitlement
38ee0af  Handoff P2, and null a deleted person's id out of apple_subscriptions
HEAD     Map a database failure in POST /me/entitlement to 503, not 400
```

---

## 1. What this is

The App Store becomes the source of truth for a paid plan, and the only thing
the server trusts is **a signature Apple made** — never the device's word, never
a request body.

```
 device buys ──► POST /me/entitlement { signed_transaction, signed_renewal_info? }
                   verify JWS → bundle/product/ownership checks → link org
                        │
 Apple  ──────► POST /apple-subscriptions/notify { signedPayload }
                   verify outer + both nested JWS → idempotent on notificationUUID
                        │
                        ▼
                 apply_apple_entitlement()   ← SECURITY DEFINER, service_role only
                        │
                        ▼
     apple_subscriptions        orgs.plan / plan_source / plan_expires_at / apple_product_id
                                        │
                                        ▼
                                 effective_plan(org)   ← what every charge path already reads
```

### Files

| File | |
|---|---|
| `services/supabase/functions/_shared/applejws.ts` | **NEW** — JWS verification, DER/X.509 parser, decoders, `productToPlan`, `deriveEntitlement` |
| `services/supabase/functions/_shared/applejws.test.ts` | **NEW** — 26 tests, mints a real 3-cert chain at test time |
| `services/supabase/functions/apple-subscriptions/index.ts` | **NEW** — `POST /notify`, `GET /health` |
| `services/supabase/functions/apple-subscriptions/README.md` | **NEW** — deploy flags, ASC setup, sandbox testing, troubleshooting |
| `services/supabase/migrations/0019_subscriptions.sql` | **NEW** — 2 tables, 3 `orgs` columns, `apply_apple_entitlement()`, `effective_plan()` |
| `services/supabase/functions/me/index.ts` | **EDITED** — `POST /me/entitlement`; `GET /me` gains 3 additive fields. Every other route byte-identical (diff below is the whole change) |

The `me` diff is 5 hunks: header comment, imports + `APPLE_BUNDLE_ID`, one
dispatcher branch, the `orgs` select + 3 response fields, and the new handler
appended before `// ── DELETE /me`.

### Security posture, in one paragraph

`verifyAppleJWS()` pins **Apple Root CA - G3 by byte equality** (583 bytes,
SHA-256 `63343abf…653e9179`, fetched 2026-09-05 from
`https://www.apple.com/certificateauthority/AppleRootCA-G3.cer`; the test suite
hashes the embedded copy and fails on a bad paste). It then verifies
intermediate←root and leaf←intermediate with WebCrypto ECDSA (hash from each
cert's own `signatureAlgorithm` OID — Apple uses `ecdsa-with-SHA384`; SHA-256
and SHA-512 are accepted so a rotation is not an outage), checks issuer/subject
DER linkage, `basicConstraints cA=TRUE` on the intermediate, all three validity
windows against `now` with Apple's own 60 s skew, and the two marker OIDs. Then
the leaf's P-256 key must sign the JWS. Every failure is
`HttpError(401, …, "unauthorized")`.

**The OID question, answered rather than guessed.** Leaf
`1.2.840.113635.100.6.11.1` and intermediate `1.2.840.113635.100.6.2.1` are the
exact two OIDs `apple/app-store-server-library-node` checks in
`verifyCertificateChainWithoutCaching` (`jws_verification.ts` lines 290–291,
source read 2026-09-05). The intermediate OID was confirmed independently by
parsing the real `AppleWWDRCAG6.cer`, which carries it. Without these, *any*
certificate Apple's WWDR CA has ever issued — every developer's distribution
cert — would be accepted as a receipt signer.

**Known gap, deliberate:** no OCSP revocation check. Apple's own library only
does it with `enableOnlineChecks` on; it puts `ocsp.apple.com` in the critical
path of every purchase, and a revoked Apple signing leaf is a scenario where
Apple re-signs and re-sends. Written into the file header, not left silent.

---

## 2. Deploy — in this order

**Step 1. Apply the migration first.** Both functions call
`apply_apple_entitlement()`, and `me` selects three columns that do not exist
yet. Deploying first gives you a broken `GET /me` for every user.

```bash
# services/supabase/migrations/0019_subscriptions.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -1 -f services/supabase/migrations/0019_subscriptions.sql
# or Supabase Dashboard → SQL Editor → paste → Run
```

Idempotent and re-runnable. Verified against a fresh Postgres 16 + the repo's
`tests/ci-bootstrap.sql`: all 19 migrations replay clean, all **160 existing
invariants pass**, `0009+` re-applies with no change, invariants pass again.

**Step 2. Set the one secret.**

```bash
supabase secrets set APPLE_BUNDLE_ID=com.rendprop.app --project-ref ymgqpbnjpztwjsyvceld
```

**Step 3. Deploy.** `apple-subscriptions` **must** go out with
`--no-verify-jwt`; `me` is a normal (JWT-verified) deploy.

```bash
cd services/supabase
supabase functions deploy me                   --project-ref ymgqpbnjpztwjsyvceld
supabase functions deploy apple-subscriptions  --project-ref ymgqpbnjpztwjsyvceld --no-verify-jwt
```

### Exact change needed in `services/supabase/deploy-functions.sh` (I do not own it)

Line 40's public loop and the final echo. Replace:

```bash
# Public routes (no JWT — the tour host + browsers call these).
for f in tours leads beacon portfolio; do
```

with:

```bash
# Public routes (no JWT — the tour host + browsers call these, and Apple's
# App Store Server Notifications, which have no Supabase JWT and never will:
# with verify_jwt on, every notification is rejected at the gateway, Apple
# retries for a day and then gives up, and subscriptions silently stop syncing).
for f in tours leads beacon portfolio apple-subscriptions; do
```

and bump the closing line from `All 13 functions` to `All 14 functions`.

> Observed while reading that script, **not mine to fix**: `ai-chapters` exists
> in `functions/` but is in neither loop, so `./deploy-functions.sh` has never
> deployed it. Worth a look from whoever owns it.

### If you use `config.toml` instead

```toml
[functions.apple-subscriptions]
verify_jwt = false
```

---

## 3. What the OWNER (Aaron) has to do himself

These cannot be done from the repo.

1. **App Store Connect → your app → General → App Information → App Store
   Server Notifications.** Choose **Version 2** and paste this into **both** the
   Production Server URL and the Sandbox Server URL fields:

   ```
   https://ymgqpbnjpztwjsyvceld.supabase.co/functions/v1/apple-subscriptions/notify
   ```

   Same URL in both: the handler accepts `Sandbox` and `Production`, stores
   which one each subscription belongs to, and refuses to let one move the
   other.

2. **Before pasting, confirm it is live:**

   ```bash
   curl -s https://ymgqpbnjpztwjsyvceld.supabase.co/functions/v1/apple-subscriptions/health
   ```

   Expect `"configured": true`. `false` means either `APPLE_BUNDLE_ID` is unset
   or migration 0019 has not been applied — `schema_ready` tells you which.

3. **Press "Send Test Notification"** on that same screen. Expect
   `200 {"ok":true,"applied":false,"ignored":"no_entitlement_change"}` — a TEST
   notification carries no transaction, so nothing is entitled. Press it twice
   and the second answers `{"ok":true,"duplicate":true}`.

4. **Create the six products** in one subscription group `rendprop_plans`
   (`com.rendprop.app.{starter,pro,team}.{monthly,annual}` — the server accepts
   exactly these and 400s anything else) with the 7-day free trial as an
   **introductory offer** on each. Leave **Family Sharing OFF** — the server
   403s `FAMILY_SHARED` transactions either way, but turning it off keeps the
   App Store page honest.

5. **Mark any comped workspace `manual`, once.** Migration 0019 defaults every
   existing org to `plan_source = 'trial'`, deliberately: guessing which
   historical org is a comp and which is a real payer is how a paying org
   silently stops downgrading. For each account you have granted a plan to by
   hand:

   ```sql
   update public.orgs set plan_source = 'manual' where id in ('<uuid>', '…');
   ```

   From then on Apple can never raise **or** lower that org's plan.

6. **Not needed:** App Store Server API keys. The JWS Apple signs — on the
   device and in each notification — carries the transaction, the renewal info
   and the certificate chain that proves them, so nothing here polls Apple.
   `APPLE_ASC_ISSUER_ID`, `APPLE_ASC_KEY_ID` and `APPLE_ASC_PRIVATE_KEY_P8`
   would only be required to *reconcile* against `/inApps/v1/subscriptions/{id}`
   — a future upgrade, listed as names only, read by nothing today. (The four
   existing `APPLE_TEAM_ID` / `APPLE_CLIENT_ID` / `APPLE_KEY_ID` /
   `APPLE_PRIVATE_KEY_P8` secrets are *Sign in with Apple* and are unrelated.)

---

## 4. The wire contract (for P1 / iOS)

```
POST /me/entitlement            Authorization: Bearer <owner JWT>
{ "signed_transaction":  "<Transaction.jwsRepresentation>",
  "signed_renewal_info": "<RenewalInfo.jwsRepresentation>"   // optional
}
→ 200 {
    "plan": "pro",                      // EFFECTIVE plan, read back after the write
    "source": "apple",                  // 'apple' | 'manual'
    "expires_at": "2026-10-05T…Z",      // end of the paid period, or of the grace window
    "product_id": "com.rendprop.app.pro.monthly",
    "original_transaction_id": "2000000700000000",
    "environment": "Sandbox",
    "status": "active",                 // additive: active|grace|expired|revoked|refunded
    "auto_renew": true,                 // additive: null when no renewal info was sent
    "replayed_notifications": 0         // additive: early notifications applied on link
  }
```

Failure modes the app should branch on (`code` field, per the repo's envelope):

| Status / code | When | Suggested copy |
|---|---|---|
| `401 unauthorized` | the JWS did not verify | "We couldn't confirm that purchase with Apple. Try Restore Purchases." |
| `400 validation` | wrong bundle id, a product we don't sell, or a purchase with no expiry | show the message verbatim |
| `403 forbidden` | `inAppOwnershipType` is `FAMILY_SHARED`, **or** the caller is not owner/admin of the workspace | message is written for the user |
| `409 conflict` | this `originalTransactionId` is already bound to a **different** org | "This subscription is already used by another account" (verbatim — it tells them to sign in with the other account) |
| `429 rate_limited` | more than 30 calls/min for one user | back off |

`GET /me` gains three additive, always-present fields — an older build ignores
them:

```json
"plan_source": "apple",                     // 'apple' | 'manual' | 'trial' | null
"plan_expires_at": "2026-10-05T…Z",         // null on trial/manual
"apple_product_id": "com.rendprop.app.pro.monthly"
```

Note for P1: call `POST /me/entitlement` after **every** verified transaction
*and* on `Transaction.updates` — it is idempotent, and it is what links the
subscription so Apple's notifications have somewhere to land.

---

## 5. Paste-ready `handleSubscriptions()` for the admin console (P4 / integrator)

I do not own `admin/index.ts`. This compiles against it as it stands today —
I appended it to a scratch copy of the real file and ran `deno check` clean. It
uses the file's existing `pageAll`, `adminClient`, `json` and `HttpError`, and
adds no imports.

**(a)** In the `switch (route)` block, after `case "usage":`:

```ts
      case "subscriptions":
        return await handleSubscriptions();
```

**(b)** In the header comment's route list, after the `/admin/usage` line:

```
//   GET /admin/subscriptions
//        -> { generated_at, active_total, grace_total, mrr_cents, mrr_note,
//             by_plan[], by_status[], environments[], not_renewing,
//             expiring_within_7d, unlinked_subscriptions, pending_notifications,
//             last_notification_at, last_notification_type, truncated }
```

**(c)** Append the handler (anywhere after `pageAll` is defined):

```ts
// ── GET /admin/subscriptions ─────────────────────────────────────────────────
//
// What the App Store is actually paying us — read from OUR tables. No Apple API
// call, no key, no network: `apple_subscriptions` is written only by
// apply_apple_entitlement() from a JWS this server verified (migration 0019),
// so this is a straight read of state that is already trusted.
//
// MRR is an ESTIMATE and the response says so. plan_entitlements.price_cents is
// the MONTHLY list price; an annual subscriber pays ten months' worth once a
// year, which is 10/12 of that per month. Treating an annual sub as a monthly
// one would overstate it by 20%, so the product id decides the divisor. Apple's
// 15-30% commission is NOT deducted — this is gross subscription revenue.
//
// Only `active` counts toward MRR. `grace` means Apple's charge FAILED and is
// being retried; the customer still has the plan, so it is reported next to the
// number rather than folded into it.
//
// Privacy: org-level aggregates only, exactly like every other route here. No
// org name, no member, no transaction id, no product-level customer detail.

/** An annual subscription is ten months' list price, spread over twelve. */
const ANNUAL_MRR_FACTOR = 10 / 12;
const EXPIRING_SOON_DAYS = 7;

interface SubscriptionRow {
  org_id: string | null;
  plan: string | null;
  product_id: string | null;
  status: string | null;
  environment: string | null;
  expires_at: string | null;
  auto_renew: boolean | null;
}

async function handleSubscriptions(): Promise<Response> {
  const db = adminClient();
  const now = new Date();

  const [subs, entRes, lastNoteRes, pendingRes] = await Promise.all([
    pageAll<SubscriptionRow>(
      (from, to) =>
        db.from("apple_subscriptions")
          .select("org_id, plan, product_id, status, environment, expires_at, auto_renew")
          .order("original_transaction_id", { ascending: true }).range(from, to),
      "Subscriptions",
    ),
    db.from("plan_entitlements").select("plan, price_cents"),
    db.from("apple_notifications")
      .select("notification_type, subtype, received_at")
      .order("received_at", { ascending: false }).limit(1),
    db.from("apple_notifications")
      .select("notification_uuid", { count: "exact", head: true }).eq("pending", true),
  ]);

  if (entRes.error) throw new HttpError(500, `Entitlement lookup failed: ${entRes.error.message}`);
  const priceOf = new Map<string, number>(
    ((entRes.data ?? []) as Array<{ plan: string; price_cents: number }>)
      .map((e) => [e.plan, Number(e.price_cents ?? 0)]),
  );

  const byPlan = new Map<string, { active: number; grace: number; mrr_cents: number }>();
  const byStatus = new Map<string, number>();
  const byEnvironment = new Map<string, number>();

  let activeTotal = 0;
  let graceTotal = 0;
  let mrrCents = 0;
  let notRenewing = 0;
  let expiringSoon = 0;
  let unlinked = 0;

  const soonMs = now.getTime() + EXPIRING_SOON_DAYS * 86_400_000;

  for (const s of subs.rows) {
    const status = s.status ?? "unknown";
    byStatus.set(status, (byStatus.get(status) ?? 0) + 1);
    if (!s.org_id) unlinked++;
    if (status !== "active" && status !== "grace") continue;

    const plan = s.plan ?? "unknown";
    const bucket = byPlan.get(plan) ?? { active: 0, grace: 0, mrr_cents: 0 };

    if (status === "active") {
      activeTotal++;
      bucket.active++;
      const env = s.environment ?? "unknown";
      byEnvironment.set(env, (byEnvironment.get(env) ?? 0) + 1);
      const monthly = priceOf.get(plan) ?? 0;
      const factor = (s.product_id ?? "").endsWith(".annual") ? ANNUAL_MRR_FACTOR : 1;
      const line = monthly * factor;
      bucket.mrr_cents += line;
      mrrCents += line;
    } else {
      graceTotal++;
      bucket.grace++;
    }
    byPlan.set(plan, bucket);

    if (s.auto_renew === false) notRenewing++;
    const expMs = s.expires_at ? Date.parse(s.expires_at) : NaN;
    if (Number.isFinite(expMs) && expMs <= soonMs) expiringSoon++;
  }

  const last = ((lastNoteRes.data ?? []) as Array<
    { notification_type: string | null; subtype: string | null; received_at: string }
  >)[0] ?? null;

  return json({
    generated_at: now.toISOString(),
    active_total: activeTotal,
    grace_total: graceTotal,
    mrr_cents: Math.round(mrrCents),
    mrr_note:
      "Gross estimate from plan_entitlements.price_cents. Annual plans count as " +
      "10/12 of the monthly list price. Active subscriptions only; Apple's " +
      "commission is not deducted.",
    by_plan: [...byPlan.entries()]
      .map(([plan, b]) => ({
        plan,
        active: b.active,
        grace: b.grace,
        price_cents: priceOf.get(plan) ?? 0,
        mrr_cents: Math.round(b.mrr_cents),
      }))
      .sort((a, b) => b.mrr_cents - a.mrr_cents || a.plan.localeCompare(b.plan)),
    by_status: [...byStatus.entries()]
      .map(([status, count]) => ({ status, count }))
      .sort((a, b) => b.count - a.count || a.status.localeCompare(b.status)),
    environments: [...byEnvironment.entries()]
      .map(([environment, active]) => ({ environment, active }))
      .sort((a, b) => b.active - a.active || a.environment.localeCompare(b.environment)),
    not_renewing: notRenewing,
    expiring_within_7d: expiringSoon,
    // A subscription Apple told us about that no signed-in device has claimed.
    unlinked_subscriptions: unlinked,
    // Notifications waiting for POST /me/entitlement to link a workspace.
    pending_notifications: pendingRes.count ?? 0,
    last_notification_at: last?.received_at ?? null,
    last_notification_type: last
      ? (last.subtype ? `${last.notification_type}/${last.subtype}` : last.notification_type)
      : null,
    truncated: subs.truncated,
  });
}
```

**(d)** For the iOS Owner Console row (P4/P5): a "Subscriptions" card showing
`active_total` big, `mrr_cents / 100` as the money line with `mrr_note` as the
small print, `by_plan` as three rows, and — the numbers that actually catch
problems — `pending_notifications` and `unlinked_subscriptions`, which should
both be 0 in a healthy system. `last_notification_at` going quiet for a day is
the sign that App Store Connect's URL is wrong or the function lost
`--no-verify-jwt`.

Also worth adding to `docs/ADMIN-CONSOLE-CONTRACT.md` when P4 lands, since that
doc freezes the shapes the Codable structs decode.

---

## 6. Suggested additions to `tests/invariants.sql` (I do not own it)

I proved all of these on a scratch Postgres (§8), but they belong in CI. Same
`assert(...)` style as the existing 160:

1. RLS is enabled on `apple_subscriptions` and `apple_notifications` **and**
   neither has any policy (service-role only).
2. `authenticated` and `anon` hold no privilege on either table.
3. `apply_apple_entitlement` is SECURITY DEFINER with `search_path = public`,
   and `has_function_privilege('authenticated', …, 'execute')` is false.
4. The `orgs` UPDATE grant still lists exactly `name, handle, space_type,
   brand_kit` — i.e. `plan_source` is not writable by a tenant.
5. `effective_plan()` still returns `free` for an expired trial (the 0010
   behaviour must not have regressed) **and** returns `free` for
   `plan_source='apple'` with `plan_expires_at` 17 days past, but the stored
   plan at 15 days past.
6. A `manual` org is unchanged by `apply_apple_entitlement` in both directions.
7. An out-of-order (older-expiry) `expired` does not downgrade an active org.

---

## 7. Curl transcript

Run locally: `deno run --allow-env --allow-net apple-subscriptions/index.ts`
with `SUPABASE_URL` pointed at an unreachable host (so `schema_ready` is false
and no write can happen), `APPLE_BUNDLE_ID=com.rendprop.app`.

```
$ curl -s $BASE/apple-subscriptions/health
{"ok":true,"configured":false,"schema_ready":false,"bundle_id_from_env":true,
 "bundle_id":"com.rendprop.app",
 "products":["com.rendprop.app.starter.monthly","com.rendprop.app.starter.annual",
             "com.rendprop.app.pro.monthly","com.rendprop.app.pro.annual",
             "com.rendprop.app.team.monthly","com.rendprop.app.team.annual"],
 "checked_at":"2026-09-05T01:33:49.222Z"}
<- HTTP 200                      # configured:false is correct here — no database

$ curl -sX POST $BASE/apple-subscriptions/notify -H 'Content-Type: application/json' -d '{}'
{"error":"signedPayload is required","code":"validation"}
<- HTTP 400

$ curl -sX POST $BASE/apple-subscriptions/notify -H 'Content-Type: application/json' -d 'not json'
{"error":"Request body must be valid JSON","code":"validation"}
<- HTTP 400

# A well-formed JWS envelope whose x5c entries are not certificates.
$ H=$(printf '{"alg":"ES256","x5c":["AAAA","AAAA","AAAA"]}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
$ P=$(printf '{"notificationType":"TEST"}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
$ curl -sX POST $BASE/apple-subscriptions/notify -d "{\"signedPayload\":\"$H.$P.AAAA\"}"
{"error":"Apple signature could not be verified (certificate is not a SEQUENCE)","code":"unauthorized"}
<- HTTP 401

$ curl -sX POST $BASE/apple-subscriptions/notify -d '{"signedPayload":"hello"}'
{"error":"Apple signature could not be verified (envelope is not a compact JWS)","code":"unauthorized"}
<- HTTP 401

# THE ROOT PIN, proved with Apple's own certificates.
# x5c = [WWDR G6, WWDR G6, Apple Root CA - G3]  → root pins, linkage fails:
{"error":"Apple signature could not be verified (leaf issuer)","code":"unauthorized"}
<- HTTP 401

# x5c = [WWDR G6, WWDR G6, WWDR G6]  → a genuine Apple CA in the root slot:
{"error":"Apple signature could not be verified (chain does not end at the pinned Apple root)","code":"unauthorized"}
<- HTTP 401

$ curl -s $BASE/apple-subscriptions/notify                       # GET on a POST route
{"error":"POST /apple-subscriptions/notify","code":"validation"}
<- HTTP 405

$ curl -s $BASE/apple-subscriptions/whatever
{"error":"Unknown route — POST /apple-subscriptions/notify or GET /apple-subscriptions/health","code":"not_found"}
<- HTTP 404
```

`POST /me/entitlement`, same setup:

```
$ curl -sX POST $BASE/me/entitlement -d '{"signed_transaction":"x"}'
{"error":"Missing Authorization bearer token","code":"unauthorized"}
<- HTTP 401

$ curl -sX POST $BASE/me/entitlement -H 'Authorization: Bearer not-a-real-jwt' -d '{"signed_transaction":"x"}'
{"error":"Invalid or expired token","code":"unauthorized"}
<- HTTP 401
```

The routes past the auth gate (400 wrong bundle / 400 unsold product / 403
family-shared / 409 conflict) need a real Supabase JWT + database; they are
covered by unit tests on the pieces (§8) and by the sandbox walkthrough in
`functions/apple-subscriptions/README.md §5`.

---

## 8. Checks run

**`deno check` — 17/17 clean** (`/root/.deno/bin/deno` 2.9.6), every function
plus both new shared files:

```
ok  _shared/applejws.ts        ok  ai-video/index.ts        ok  me/index.ts
ok  _shared/applejws.test.ts   ok  ai-voice/index.ts        ok  portfolio/index.ts
ok  admin/index.ts             ok  apple-subscriptions/…    ok  renders/index.ts
ok  ai-chapters/index.ts       ok  beacon/index.ts          ok  tours/index.ts
ok  ai-enhance/index.ts        ok  leads/index.ts           ok  uploads/index.ts
ok  ai-photo/index.ts          ok  listings/index.ts
```

**`deno test --allow-env _shared/applejws.test.ts` — 26 passed, 0 failed**, no
network. The suite mints a real three-certificate chain with WebCrypto and a DER
writer it also contains, injected through a `trustRoot` hook that no request can
reach (typed `Uint8Array`, which `JSON.parse` cannot produce; a wrong type is a
401, and that is itself a test). Covered: the embedded root's SHA-256 and byte
length · valid chain · wrong root · no override (must fail against the real
Apple root) · foreign intermediate · re-issued certificate · expired leaf ·
not-yet-valid chain · tampered payload · flipped signature byte · missing leaf
marker OID · missing intermediate marker OID · non-CA intermediate · `alg` not
ES256 · 2-cert chain · four malformed envelopes · trust-root type guard ·
foreign bundle id decodes so the caller can refuse it · all six product ids plus
five non-products · missing `expiresDate` · seconds-vs-milliseconds, string and
zero timestamps · revocation date · missing identity fields · and six
`deriveEntitlement` cases (active, grace, grace-expired, no renewal info,
refund/revoke, no dates).

**Postgres** — scratch Postgres 16 + `tests/ci-bootstrap.sql`, exactly what CI
does: all 19 migrations replay clean → **160/160 invariants pass** → `0009+`
re-applied → **160/160 pass again**. Then a 10-case functional script against
`apply_apple_entitlement`: purchase (trial→pro/apple) · stale older-expiry
`EXPIRED` does **not** downgrade (`reason: stale_notification`) · a real
`EXPIRED` does (`pro→free`) · a `manual` org is untouched in both directions
(`reason: manual_plan`) · an unlinked notification stores with `org_id null` and
applies on link · a second active subscription blocks the downgrade
(`reason: another_subscription_active`) · `effective_plan` returns `free` at 17
days past and `pro` at 15 · the 0010 expired-trial arm still returns `free` · a
bad status raises `RP400` · and `authenticated` is denied both tables, the RPC,
and `orgs.plan_source`.

**Secret scan** — `git diff b0e6b7f~1 HEAD` grepped for `sk-`, long bearers, PEM
private keys, `eyJ…` JWTs, `api_key=`, `password`, `secret =`: **no
credential-shaped strings**. The only env var this work introduces is
`APPLE_BUNDLE_ID`, and the only `console.log` calls in the new function emit
notification type, subtype, uuid, environment, verdict, and an unmapped product
id — no payload, no account token, no credential.

---

## 9. Open risks

1. **`--no-verify-jwt` is a single point of silent failure.** Deploy it without
   the flag and Apple gets 401s, retries for a day, gives up, and nothing in the
   product looks broken until a customer's plan does not lapse. The check is
   `last_notification_at` in the admin card, or ASC's "Send Test Notification"
   result. The `deploy-functions.sh` change in §2 is the durable fix.
2. **No live Apple JWS was ever verified.** Nobody can produce one without
   Apple's key, so the chain logic is proven against a synthetic chain plus the
   real Apple root and WWDR G6 certificates. **The first sandbox purchase is the
   real test** — do it before submitting. If the leaf ever fails a check the
   error message names it exactly (`leaf is not an App Store signing
   certificate`, `chain does not end at the pinned Apple root`, …).
3. **Certificate rotation.** If Apple ever re-roots off Apple Root CA - G3, this
   stops verifying — by design, because the alternative is trusting whatever is
   presented. The fix is a one-line constant swap in `_shared/applejws.ts`, and
   the test asserts the fingerprint of whatever is pasted.
4. **The 16-day backstop is a floor, not a ceiling.** An org whose `EXPIRED`
   notification is never delivered keeps its plan for up to 16 days past expiry.
   That is deliberate (Apple's maximum billing-retry grace, so shortening it
   would cut off customers Apple is still collecting from), but it is 16 days of
   free Pro in the worst case. Polling `/inApps/v1/subscriptions/{id}` with an
   ASC key would close it — that is the one thing `APPLE_ASC_*` would buy.
5. **`plan_source` defaults to `'trial'` for every existing org.** Comped
   accounts are unprotected until §3 item 5 is run. Deliberate: the alternative
   heuristic would have marked real payers as comps, and a comp that Apple can
   never downgrade is a permanent revenue leak.
6. **Team seats are still not enforced anywhere** (`plan_entitlements.seats`).
   Buying `team` grants the team allowances but not multi-seat behaviour — the
   same pre-existing gap the functions README already lists. Not in scope here,
   but it is now purchasable.
7. **`apple_subscriptions` survives `DELETE /me`.** Both `org_id` and `user_id`
   are `ON DELETE SET NULL`, so after an account deletion the row keeps nothing
   but Apple's own identifiers, a product id and a status — and a later
   notification for that subscription still lands instead of erroring at Apple.
   That is deliberate: the App Store subscription outlives the workspace,
   because Apple keeps billing until the user cancels in Settings. **Nobody is
   refunded or unsubscribed automatically.** If the product wants deletion to
   also cancel, that is new work and it needs an App Store Server API key.
8. **`POST /me/entitlement` does not call `assertNotDeleting()`.** Neither does
   `PATCH /me/brand`, so this is consistent with the file — and the SET NULL
   FKs above mean a purchase that lands mid-deletion cannot orphan anything.
   Flagged so it is a decision rather than an oversight.
