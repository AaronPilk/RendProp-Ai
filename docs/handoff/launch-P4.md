# HANDOFF-P4 — "Test all keys": a $0 authenticated probe of every credential

Branch `launch-p4`. Two commits: `b15acab` (server) and `7add686` (iOS + one
probe refinement).

The owner's question was *"are all my API keys actually working?"* The console
could only answer *"is the env var set?"* — and a rotated key, a truncated
paste, a key from the wrong account and a perfectly good key all read
`configured: true`. Six of these keys (ElevenLabs, OpenAI, Anthropic-as-a-key,
Kie, Higgsfield, World Labs) had never been exercised from deployed code at all.

`GET /admin/providers/probe` now makes one **$0, idempotent, read-only** call per
vendor and reports what each one said.

---

## 1. Files

| file | change |
|---|---|
| `services/supabase/functions/admin/probe.ts` | **NEW** — `PROBES` (13) + `probeAll()`, the sanitizer and the classifiers |
| `services/supabase/functions/admin/probe.test.ts` | **NEW** — 17 tests, no network |
| `services/supabase/functions/admin/index.ts` | **EDIT** — route, its own rate limit, `admin_last_probe`, `last_probe` on `/admin/providers`, header + 404 list (+141/−3; the 3 deletions are the three lines replaced) |
| `services/supabase/functions/_shared/r2.ts` | **EDIT, APPEND-ONLY** — `probeBucket()` (+45/−0; nothing above line 355 moved) |
| `apps/ios/Rendprop/Screens/AdminProbeAPI.swift` | **NEW** — protocol + models + Live + Mock + copy helpers |
| `apps/ios/Rendprop/Screens/SettingsView.swift` | **EDIT** — +271/−0, every hunk a pure insertion inside `AdminConsoleView` at ≥ line 1972. `Plan & usage` (380–520) untouched |

Nothing under `Networking/`, `Purchases/`, `Analytics/`, `Voice/`, no other edge
function, no `project.yml`, no `Config.swift`, no migration (`app_config`
already exists and takes any key — migration 0018).

---

## 2. The probe table

Every endpoint and every bad-key status below was **verified against the live
vendor with a deliberately-bogus key on 2026-09-05**, not read off a doc page.
The observed status is in each probe's comment in `probe.ts`.

| provider | endpoint (all $0) | doc | what a pass proves | bad key → |
|---|---|---|---|---|
| `gemini` | `GET generativelanguage.googleapis.com/v1beta/models?pageSize=1`, hdr `x-goog-api-key` | [ai.google.dev/api/models](https://ai.google.dev/api/models#method:-models.list) | the key lists models; no tokens billed | **400** `INVALID_ARGUMENT` ⚠ |
| `fal` | `GET api.fal.ai/v1/models?limit=1`, `Authorization: Key …` | [fal.ai/docs/platform-apis/v1/models](https://fal.ai/docs/platform-apis/v1/models) | see the note below | 401 |
| `openai` | `GET api.openai.com/v1/models?limit=1`, Bearer | [platform.openai.com/…/models/list](https://platform.openai.com/docs/api-reference/models/list) | the key lists models | 401 |
| `anthropic` | `GET api.anthropic.com/v1/models?limit=1`, `x-api-key` + `anthropic-version: 2023-06-01` | [platform.claude.com/…/models/list](https://platform.claude.com/docs/en/api/models/list) | the key lists models; zero tokens | 401 |
| `elevenlabs` | `GET api.elevenlabs.io/v1/user/subscription`, `xi-api-key` | [elevenlabs.io/docs/…/subscription/get](https://elevenlabs.io/docs/api-reference/user/subscription/get) | the key reads its own account **+ characters left, plan tier** | 401 |
| `kie` | `GET api.kie.ai/api/v1/chat/credit`, Bearer | [docs.kie.ai/…/get-account-credits](https://docs.kie.ai/common-api/get-account-credits) | the key reads its balance **+ credits left** | **HTTP 200, body `code:401`** ⚠⚠ |
| `higgsfield` | `GET api.higgsfield.ai/requests/{all-zero-uuid}/status`, `Authorization: Key ID:SECRET` | [docs.higgsfield.ai/…/get-request-status](https://docs.higgsfield.ai/docs/api-reference/requests/get-request-status) | **404** = we got past auth (documented: "does not exist **or belongs to another account**") | 401 |
| `worldlabs` | `GET api.worldlabs.ai/marble/v1/credits`, hdr `WLT-Api-Key` | [docs.worldlabs.ai/…/credits/get](https://docs.worldlabs.ai/api/reference/credits/get) | the key reads its balance **+ credits left** | 401 |
| `cloudflare_r2` | signed `ListObjectsV2` `max-keys=1` on `R2_BUCKET_UPLOADS` (via `r2.ts probeBucket`) | [developers.cloudflare.com/r2/api/s3/api](https://developers.cloudflare.com/r2/api/s3/api/) | the **exact** SigV4 credentials the upload path uses sign a real request | 403 (see §6) |
| `cloudflare_stream` | `GET api.cloudflare.com/client/v4/accounts/{id}/stream?per_page=1`, Bearer | [Cloudflare Stream list](https://developers.cloudflare.com/api/resources/stream/methods/list/) | the token reads the Stream account **+ videos visible** | **400 + `errors[].code 9106`** ⚠ |
| `ghl` | `GET services.leadconnectorhq.com/locations/{GHL_LOCATION_ID}`, Bearer + `Version: 2021-07-28` | [GHL get location](https://marketplace.gohighlevel.com/docs/ghl/locations/get-location) | the token authenticates against the CRM location leads are upserted into | 401 |
| `turnstile` | `POST challenges.cloudflare.com/turnstile/v0/siteverify`, `secret=…&response=<never-issued>` | [Turnstile server-side validation](https://developers.cloudflare.com/turnstile/get-started/server-side-validation/) | anything **but** `invalid-input-secret` means the secret is right | 400 `invalid-input-secret` |
| `apple` | **no network** — WebCrypto import of the `.p8` (ES256/P-256) | [TN3194](https://developer.apple.com/documentation/technotes/tn3194-generating-and-validating-a-sign-in-with-apple-authorization-code) | the `.p8` is a readable private key. **Nothing more** — see §3 | n/a |

### ⚠ Three vendors do not use 401, and would have been misreported

1. **Gemini answers `400 INVALID_ARGUMENT` ("API key not valid")**. The generic
   401/403 rule would have shown a dead Gemini key as amber "unexpected answer"
   instead of red "wrong key". Special-cased.
2. **Kie answers HTTP `200` with `{"code":401}` in the BODY.** Reading only the
   HTTP status would have reported a **dead Kie key as WORKING** — the single
   most dangerous possible bug in this file. The body's `code` is authoritative.
   (`providers/kie.ts` already documents this behaviour.)
3. **Cloudflare answers `400` with `errors[0].code = 9106` "Authentication
   failed"**. Codes 9106 / 9109 / 10000 are matched explicitly.

### The fal endpoint — what I found, and why not the alternatives

The task suggested `rest.alpha.fal.ai` or a 401-vs-404 queue trick. What is
actually true (all verified live):

* `GET api.fal.ai/v1/models?limit=1` with **no** `Authorization` header → **200**.
  It is a *public* index, so on its own it proves nothing.
* The same URL with a **bogus** key → **401** `{"type":"authorization_error"}`.
  So a key that IS sent is genuinely validated. **This probe always sends one**
  (an unconfigured fal never reaches `run()`), therefore a 200 here does prove
  the key. This is stated in the row's `how` text so the console is honest about
  it, and it is the reason the row is worded the way it is.
* `GET queue.fal.run/{model}/requests/{unknown-id}/status` → **404**
  `{"status":"NOT_FOUND"}` with no key, **401** `{"detail":"invalid key
  credentials"}` with a bad one. This also works and I verified it, but it needs
  a hardcoded model slug and leans on a 401-vs-404 split fal does not document.
* `GET api.fal.ai/v1/models/usage` was **rejected**: fal documents it as
  **Admin-scope**, and an API-scope `FAL_KEY` would fail it — a false red on a
  working key.

The plain 200/401 with no model id won.

---

## 3. What is honest rather than green

* **`apple`** — there is **no** $0 authenticated probe. Both Apple token
  endpoints need a real user artefact (a single-use `authorizationCode` that
  expires in ~5 minutes, or a stored refresh token); neither can be
  manufactured, so any request we could build would be rejected for the missing
  artefact and could not tell a good key from a bad one. What it *does* prove is
  that the `.p8` imports as an ES256 key — exactly what `clientSecret()` in
  `_shared/apple.ts` does before every Apple call, so a paste that lost its
  newlines or PEM armour fails here for the same reason it would fail there.
  That is the common failure and it is now caught. The row says
  *"Private key parses. Signing in still needs a real person."*
* **`ghl` 403** is reported as a **pass** with a sentence. LeadConnector answers
  **401** for a token it does not recognise, so a 403 means the token
  authenticated and simply lacks `locations.readonly` — which is fine, because
  lead sync only needs `contacts.write`. Reporting that as a failure would red a
  perfectly working CRM key.
* **Not configured → `ok: null`, grey "Not set"**, never red and never green. An
  unset optional key (Kie, Higgsfield, Stream, World Labs) is a feature that is
  off, not a fault.

---

## 4. Env NAME mismatches found (worth the owner's attention)

| # | what | where |
|---|---|---|
| 1 | **`Add API Keys.command` writes the wrong Higgsfield names.** It writes `HIGGSFIELD_API_KEY` / `HIGGSFIELD_API_SECRET`; `providers/higgsfield.ts` and `set-secrets.sh` both read `HIGGSFIELD_API_KEY_ID` / `HIGGSFIELD_API_KEY_SECRET`. Anyone who follows the double-click script gets a Higgsfield that is silently unconfigured. (That file is the *pipeline* `.env`, a different consumer — but the names read as if they were the same thing, which is how this bites.) | `Add API Keys.command` lines 31–32 |
| 2 | Same file writes `R2_ACCOUNT_ID`; the edge functions read `CLOUDFLARE_ACCOUNT_ID`. | `Add API Keys.command` line 45 |
| 3 | **`OPENAI_API_KEY` is read by `providers/openai.ts` but is not in `set-secrets.sh`.** Following the repo's own secret script leaves OpenAI unset. (`docs/AI-ROUTER-CONTRACT.md` §130 asserts it "is already set" — that assertion is not backed by anything in the repo.) | `services/supabase/set-secrets.sh` |
| 4 | **`WORLDLABS_API_KEY` exists nowhere in the repo.** There is no worldlabs adapter, no entry in `set-secrets.sh`, and the only references are a `router.test.ts` fixture, a `MockAPIClient` fixture and `docs/research/3D-VIDEO-BRIEF-2026-09.md`. I chose the name `WORLDLABS_API_KEY`; until somebody sets it the row reads "Not set", which is the truth. **If the owner prefers a different name, change it in one place** (`probe.ts`, the `worldlabs` probe's `env_names`). | new |
| 5 | **Stream's token is read under three names.** `_shared/stream.ts` accepts `CLOUDFLARE_STREAM_API_TOKEN` → `CLOUDFLARE_STREAM_TOKEN` → `CLOUDFLARE_API_TOKEN` (a past outage: following `set-secrets.sh` left Stream deletion silently unconfigured). The console's `PROVIDERS` lists only `CLOUDFLARE_STREAM_TOKEN` + `CLOUDFLARE_STREAM_CUSTOMER_CODE` — and `CUSTOMER_CODE` is only used to build HLS URLs, never to authenticate. **The probe reads the same three names in the same order as `stream.ts`**, so it can never disagree with the code that actually deletes videos. | `_shared/stream.ts` vs `admin/index.ts` PROVIDERS |
| 6 | **The console's provider inventory is missing four vendors it already calls.** `admin/index.ts` `PROVIDERS` has no `openai`, `elevenlabs`, `higgsfield` or `worldlabs` row, so `/admin/providers` and `/admin/health` say nothing about them. The probe covers **13**; the inventory covers **10** (and one of its 10, `render_compute`, has no key to test). Not fixed here — that is an edit to the inventory, which is a wider change than this task owns. The iOS side carries its own display-name map so the extra rows still read as words. | `admin/index.ts` PROVIDERS |

---

## 5. Route, limits, and the `last_probe` record

```
GET /admin/providers/probe          (admin only)
→ 200 { checked_at, probe_count, ok_count, fail_count, not_probeable_count,
        results: [ { key, configured, ok, latency_ms, error_class, how,
                     message, detail, env_names, doc } ],
        last_probe_recorded }
→ 429 { error: "You've tested the keys a few times already. You can test again
                in about an hour.", code: "rate_limited" }
```

* Gated by the **existing** `requireAdmin()` (which the dispatcher runs before
  the method check and which fails closed).
* Charged the general `admin:{userId}` 60/min limiter **and** its own durable
  `admin-probe:{userId}` **6 per hour** — one tap is eleven outbound requests,
  and nothing else in this function makes any.
* Still a `GET`, so the console's read-only 405 rule is unchanged.
* Each probe: `AbortController`, **8 s** ceiling, `Promise.allSettled` so one
  vendor can never blank the other twelve answers. Measured wall clock for all
  13 concurrently: **947 ms**.
* Records `app_config.admin_last_probe = { at, ok_count, fail_count,
  not_probeable_count, by }`. `by` (the admin's user id) is stored for the same
  audit reason the routing switches store `changed_by`, and — matching this
  file's own privacy rule — is **never returned**.
* `GET /admin/providers` gains an additive `last_probe: { at, ok_count,
  fail_count } | null`, so the console can say *"Last tested 12 min ago: 9 ok,
  1 failed"* without re-running anything. `null` until the button is first used.

**No credential, and no response body, leaves `probe.ts`.** Every upstream
string goes through `sanitize()`, which redacts any 24+ character token-shaped
run (`/[A-Za-z0-9_\-]{24,}/g` → `[…]`) **and then** truncates to 80 chars — that
order is load-bearing and is tested. OpenAI's 401 body, which quotes a masked
form of the key you sent, is not passed through at all. Nothing here logs a
body, a URL or an error object; the one `console.log` is three counts.

---

## 6. Checks run

```
deno check admin/index.ts admin/probe.ts admin/probe.test.ts _shared/r2.ts   ✅ clean
deno lint  admin/probe.ts admin/index.ts _shared/r2.ts                        ✅ clean
deno test --allow-env --allow-net admin/probe.test.ts                         ✅ 17 passed, 0 failed
swiftc -parse Screens/AdminProbeAPI.swift Screens/SettingsView.swift          ✅ clean
```

**Live end-to-end against all eleven vendors with deliberately-bogus keys**
(throwaway script, not committed): 12 of 13 classified `auth`; `cloudflare_r2`
classified `network` because the fake account id does not resolve in DNS (see
below); `apple` classified `other`. An automated assertion confirmed **none of
the bogus key values appeared anywhere in the JSON payload**.

**Secret grep over the full branch diff**: the only matches are the four
`FAKE_*` fixtures in `probe.test.ts` (which the tests assert get redacted) and
the literal `-----BEGIN PRIVATE KEY-----` PEM *marker* in the parser. No real
credential in the diff.

### Could NOT verify

* **R2's 403-on-bad-secret path.** R2's account id is part of the hostname
  (`<account>.r2.cloudflarestorage.com`), so a fake account id fails DNS before
  any signature is checked. The 403 branch is therefore reasoned from the S3/R2
  spec, not observed. *(This did produce a real improvement: a DNS failure here
  is far more often a mis-pasted `CLOUDFLARE_ACCOUNT_ID` than an outage, so that
  message now names the variable instead of saying "fetch failed".)*
* **Every PASS path except two.** I have no real keys, so `ok: true` was only
  observed for `turnstile` (using Cloudflare's *published* always-pass test
  secret `1x0000…AA` — a documented public value, not a credential) and for
  `apple` (with an ES256 key generated inside the test). The other eleven pass
  paths are a plain "2xx ⇒ ok" on an endpoint whose 401 I did observe.
* **Cloudflare Stream with a real account id + a bad token.** Only the fake-
  account-id 400/9106 shape was observed; a real account with a bad token may
  answer 403 or 400/10000. All are matched.
* **Nothing was run against production Supabase** and nothing was deployed, per
  COMMON.md.

---

## 7. Deploy

Normal function deploy — **no migration, no new secret required**:

```bash
cd services/supabase
supabase functions deploy admin --project-ref ymgqpbnjpztwjsyvceld
```

`probe.ts` is a sibling module of `admin/index.ts`, so it ships with that one
deploy. `_shared/r2.ts` is bundled into every function that imports it, so the
other functions pick up the appended `probeBucket()` on their next deploy —
it is additive and unreferenced by them, so redeploying them is not required.

---

## 8. Changes I need in files I do not own

**8.1 — `apps/ios/Rendprop/Networking/APIClient.swift` (optional, cosmetic).**
Add one line to `struct AdminProvidersReport` (~line 1188), after
`var providers: [AdminProvider]? = nil`:

```swift
    /// `last_probe` from GET /admin/providers — when the keys were last actually
    /// TESTED (Screens/AdminProbeAPI.swift). nil until the owner has pressed
    /// "Test all keys" once.
    var lastProbe: AdminProbeLastRun? = nil
```

With that in place, delete `AdminProvidersLastProbeEnvelope` and
`adminLastKeyProbe()` from `Screens/AdminProbeAPI.swift`, drop
`adminLastKeyProbe` from the `AdminProbeAPI` protocol and both extensions, and
in `SettingsView.swift` replace the `if let probeAPI { lastKeyProbe = … }` block
in `loadCompanions()` with `lastKeyProbe = providers?.lastProbe`. **This is
purely tidying — it removes one extra GET to `/admin/providers` per console
open. Everything works today without it.**

**8.2 — `services/supabase/set-secrets.sh` (recommended).** Add the two names
the functions read but the script does not write:

```bash
  OPENAI_API_KEY="OPTIONAL_BLANK" \
  WORLDLABS_API_KEY="OPTIONAL_BLANK" \
```

**8.3 — `Add API Keys.command` (recommended).** Fix the three names in §4 so the
double-click path and the edge functions agree.

**8.4 — `docs/ADMIN-CONSOLE-CONTRACT.md` (documentation).** It is at "Version 1"
and does not yet describe `GET /admin/providers/probe` or the additive
`last_probe` field on `GET /admin/providers`. The shape is in §5 above and in
the header comment of `admin/index.ts`.

---

## 9. What the OWNER (Aaron) has to do himself

1. **Set the keys that are not set.** `OPENAI_API_KEY` and `WORLDLABS_API_KEY`
   are read by code but written by no script; `KIE_API_KEY`,
   `HIGGSFIELD_API_KEY_*` and `CLOUDFLARE_STREAM_TOKEN` are deliberately blank
   pending terms. Until each is set its row reads grey **"Not set"** — which is
   correct, not a bug.
2. **Press the button once after deploy**, from the owner console → Health →
   *Test all keys*. Until then `/admin/providers` `last_probe` is `null` and the
   footer reads "Never tested". Budget six taps an hour.
3. **Expect `apple` to read "Can't test" in blue.** That is deliberate and §3
   explains why. It is not a broken key.
4. **If any row comes back red "wrong key"**, that key is genuinely rejected by
   the vendor right now — rotate it in the dashboard and re-run
   `set-secrets.sh`. The row names the env var it read.
5. **Nothing here spends money.** Every probe is a list / credit-balance /
   status read. If a future probe is ever added, the bar is the same: $0,
   idempotent, and never a generation.
