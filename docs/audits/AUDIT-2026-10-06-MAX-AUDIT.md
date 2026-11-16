# Max audit — 2026-10-06

Seven read-only agents against `origin/fix/cas-conflict-terminal-20261006` @ `4a209d4`
(regression review of the remediation branch, four never-audited services, CI/supply
chain/secrets, data model + DR, observability, Xcode release engineering, test-suite
quality), then every P0 checked against **production** (RendProp project
`ymgqpbnjpztwjsyvceld`, 20:50 UTC). Nothing edited but this file. Tags: VERIFIED =
live artifact or file:line read this session; INFERRED = reasoned from verified facts.

**What changed since the 10-05 review:** the remediation branch is no longer "not yet
live." At **19:24 UTC (3:24 PM EDT) today** all 25 edge functions were redeployed
(`ai-photo` 53, `ai-video` 52, `uploads` 48, `me` 49, `admin` 31, `studio` 18 …) and the
migration ledger now ends at `20261006192705_upload_identity_monthly_technical_ceiling`,
with `funded_serving_and_app_review_authority`, `apple_sandbox_authority_fence`,
`photo_authority_rpc_expand` and `brokerage_pricing_service_acl` all applied. Two of
the regressions the review agent predicted "on deploy" are therefore **live now**.

---

## P0 — live in production right now

### P0-1. AI generation is refused for 38 of 40 workspaces (VERIFIED)

- `serving_cost_reserve` exists live. Its predicate (repo file
  `20261006164721_funded_serving_and_app_review_authority.sql:151-155`): unless the org
  has an internal-testing or private-testing grant, it looks up current `serving_funding`
  and raises **`RP402: This workspace has no funded serving allowance`** when none exists.
- Live counts: `serving_funding` **0 rows**, `apple_serving_schedules` **0**,
  `serving_sponsor_pools` **0**, orgs with a grant **2** (the owner's `team/manual` org
  and one trial), live orgs **40** (31 trial, 8 free, 1 team). `funded_now` = 0 for every org.
- The deployed `ai-photo` v53 bundle contains `_shared/funded-serving.ts` and calls
  `fundedAttempt(` three times; `funded-serving.ts` calls `serving_cost_reserve`. The
  branch wires the same gate into ai-copy, ai-chapters, ai-voice, coach, ai-video and
  Studio edit-plan/transcription/presenter — all redeployed at 19:24 UTC.
- Client effect: `_shared/http.ts:238` maps RP402 to `plan_required` (the message does
  not contain "limit reached"/"ceiling reached"). Build 44 `APIClient.swift:1403` treats
  `plan_required` as quota; `:1449` shows **"This feature isn't included in your current
  plan."** and `:1438` **"Upgrade your plan to continue."** — a subscribed user is sent
  to the paywall.
- Nothing recorded it: refused attempts raise *before* the reservation insert, so
  `serving_cost_reservations` = 0 rows, `serving_operations` (6h) = 0, and deliberate
  `HttpError`s are never logged (`http.ts:110-117`). Whether any customer has hit this
  since 19:24 UTC is **unknowable from the data** — which is the observability finding
  (§6) proving itself on day one.
- Also live: `serving_operation_begin` requires `auth.users.is_anonymous is false`
  (`:257`), so a paying anonymous guest is refused even with funding — contradicting the paid-guest
  exception the upload gate makes.
- **Rollback:** redeploy the previous versions of the six AI functions (and the Studio
  function). `serving_cost_reserve` is only called from new code, so the SQL can stay.

### P0-2. Anonymous users cannot upload or publish, and build 44 loops forever (VERIFIED)

- `upload_new_admission` is live and is called from inside the patched body of
  `reserve_upload_assets` (confirmed with `pg_get_functiondef`). For an anonymous actor
  without a Production Apple subscription on a paid plan it raises **`RP401: Sign in to
  upload media…`** (`20261005222001_upload_identity_monthly_technical_ceiling.sql:11-23`).
- The deployed `uploads` v48 `uploadRPC` only recognises `RP(400|403|404|409|429|503)`
  (`uploads/transport.ts:28`) — RP401 falls through to **503 "Durable upload state
  unavailable — retry"** (string present in the deployed bundle; "RP401" absent).
- Build 44 `UploadManager.swift:790-797` treats 5xx as transient and auto-resumes;
  `ReviewSubmitView.swift:75,258` lets anonymous users submit; `AuthStore.swift:29-33`
  counts anonymous as signed in. Result: silent infinite retry, no "sign in" prompt.
- Population: **32 of 38 auth users are anonymous**, all active in the last 30 days.
- Still published at the branch tip: `tour-host/public/llms.txt:7` — "Everything works
  without an account, publishing included."
- **Rollback:** redeploying the old `uploads` function is *not* enough — the gate is in
  the SQL body. Re-create `upload_new_admission` without the anonymous branch (keep the
  monthly ceiling), or revert the `reserve_upload_assets` patch.

### P0-3. The burned Supabase service-role key was never rotated (VERIFIED key lineage; live validity INFERRED, high confidence)

- The leaked `services/pipeline/.env` is still inside `_bridge/repo-snapshot.tgz`
  (Sep 3) and byte-identical at `Rendprop AI/repo/services/pipeline/.env` (mtime
  2026-08-25). Its `SUPABASE_SERVICE_ROLE_KEY` is a legacy JWT, `role=service_role`,
  `iat=1787239990`. (Agent compared SHA-256 digests in memory; no value was printed.)
- That digest equals the `service_role` key the Management API listed on 2026-09-12
  (`_bridge/out/1597-fix-drain-key.log`), and bridge scripts installed it as a
  production Worker secret on 09-11 and again on 09-12 (`_bridge/cmd/1543-gateway.sh:69-75`,
  `1555-deploy.sh:85-86`).
- Live today: `get_publishable_keys` returns the legacy anon JWT with the **same
  `iat=1787239990`, `type: legacy`, `disabled: false`**. Legacy anon and service_role
  share one JWT secret and one mint; rotating it would have changed the anon key in
  `Config.swift:62`, which is unchanged through today. The runbook itself says so
  (`SECRETS-ROTATION.md:53`, `AUDIT-RESPONSE-2026-08-28.md:154-157`).
- The same `.env` holds `FAL_KEY`, `GEMINI_API_KEY`, `ANTHROPIC_API_KEY`, `KIE_API_KEY`
  identical to the burned snapshot. Every doc that mentions rotation says it was not
  done (`LAUNCH-READINESS-20261006.md:116`; `handoff/audit-fixes.md:38-40`).
- **Impact:** anyone holding the snapshot has RLS-bypassing read/write on all customer
  data. Rotation requires: new JWT secret or disabling legacy keys → update
  `Config.swift` anon key → new iOS build → update Worker secret, Modal secret, `.env`.

### P0-4. The GitHub repository is public (VERIFIED)

`https://github.com/AaronPilk/RendProp-Ai` renders logged-out with the **Public** badge
(`repository_public: true`), 356 commits, 26 PRs, full tree. World-readable right now:
every audit in `docs/audits/` (including this one once pushed) listing open weaknesses
with file:line; the Supabase org id and project ref
(`services/supabase/supabase/.temp/linked-project.json`, committed because
`.gitignore:28` ignores the wrong path); `Add API Keys.command`; 418 CI artifacts;
`main` is unprotected with no required checks and its HEAD CI is red. No secret *values*
are in history (602 commits / 211 refs scanned — only the public anon key), so this is
an exposure-of-map problem, not a key leak. Flip to private today; the audit docs alone
are a targeting guide.

### P0-5. The Mac build bridge is unsigned RCE-as-owner, next to plaintext production credentials (VERIFIED)

- `_bridge/Rendprop Build Bridge.command:9-22` runs every `cmd/*.sh` with `bash "$f"`.
  No allowlist, signature, owner/mode or "fully written" check. `out/` is readable back
  — an exfiltration channel.
- The folder is mounted read-write into every Cowork agent sandbox (`test -w` true this
  session; nothing was written). Codex very likely has the same access (INFERRED). Any
  process running as the user can write there.
- Plaintext in the same folder: `.supabase-token` (Supabase PAT — drives raw SQL on
  production via the Management API), `.asc/AuthKey_*.p8` + issuer, `.apns/AuthKey_*.p8`,
  `.elevenlabs-key`, `.worldlabs-key` (+ `.bak128`), `.upload-capability-secret`,
  `.asc/review-contact.json`. The wrangler OAuth + refresh token are reachable from
  scripts (`cmd/1603-cf-creds.sh:6-7`).
- **Four stale scripts are queued and will run the next time the bridge starts**
  (present in `cmd/`, no `out/` log): `1659-declutter-supersede-build.sh` (builds my
  withdrawn branch), `1660-push-for-codex.sh` (`git push origin HEAD`),
  `1661-testflight-add-tester.sh` (ASC API tester changes — already done by hand),
  `1662-fetch-crash-log.sh` (copies from `~/Downloads` into the shared folder). These
  are mine from Oct 1 and are all obsolete. **Delete them before the bridge is ever
  started again.** I did not delete them: the folder is yours and the repo is read-only.

---

## P1 — regressions that shipped at 19:24 UTC (or will on the next client build)

| # | What broke | Evidence |
|---|---|---|
| R3 | **Photographer-mode client forwarding stopped for the one existing contact.** New verification columns are NULL (`20261005220001…:33-34`); enqueue/resend/prepare/summary all require `recipient_verified_at` (`:64-68`, `:183-195`); already-queued deliveries marked skipped (`:197-201`). Builds 42/44 have no verify action — only Studio or the unreleased native build can clear it. Live: `listing_client_contacts` = 1 row, verified columns present. VERIFIED. |
| R4 | **In-flight legacy video jobs may be unrecoverable.** `assertLegacyVideoReceipt` (`ai-video/index.ts:2283-2293`) matches the URL segment before `/requests/` against `app_video_cost_reservations.model`, which stores the full id (`fal-ai/topaz/upscale/video`); fal's status URLs carry only the app root → 403 "This older job needs verified account recovery." The test uses `fal-ai/synthetic`, where both forms coincide (`fal-status-handler_test.ts:64-67`). New jobs carry a 2-hour token (`jobtoken.ts:79`); every submission 503s if `JOB_TOKEN_SIGNING_SECRET` is unset. INFERRED on production flag state. Live: no unsettled video holds today, so no customer is currently stuck. |
| R5 | **Legacy `/a/<handle>` portfolio pages now return `tours: []`** with an empty agent card (`portfolio/index.ts:49-58`); no migration seeds a selection, even for single-member orgs. VERIFIED; `portfolio` v40 deployed. |
| R6 | **Demo-tour lead form returns 400** (`leads/index.ts:229` rejects demo slugs) while `tour-host/src/demo.ts:217-222` still renders the form. Those leads were your own funnel (`tour-demo` → GHL). VERIFIED; `leads` v40 deployed. |
| R7 | **Purchase/restore now depend on the funding RPC.** `fundVerifiedAppleTransaction` runs after entitlement (`me/index.ts:1289,1380`) and throws 503 on any RPC error (`_shared/apple-funding.ts:9`); the client then never finishes the transaction and retries every foreground. An RP409 "periods cannot overlap" (`provision_serving_funding:96`) cannot be cleared by restoring. VERIFIED code path; `me` v49 deployed. |
| R8 | **Next native build: account/workspace switch no longer resets tabs.** `.id(user:workspace)` removed from the TabView (was `f64c842 RendpropApp.swift:3058`); pushed `FlythroughDetailView` only clears its export sheet (`:753-756`). Previous user's listing can remain on the stack on a shared device. VERIFIED code; runtime INFERRED. |
| H7 | **Upload ceiling RP429 also loops** on builds 42/44 (`UploadManager.swift:793-797` auto-retries 429). VERIFIED. |

## P1 — App Review cannot pass the next submission (VERIFIED)

The Sandbox fence is live. A reviewer's Sandbox receipt is refused unless an operator
first runs `provision_serving_funding('app_review')` against a *named, single-member
owner org* — capped at 7 days / $5, once per account for life (`:97-108`). Sign-in is
Apple-only (`SignInView.swift:20`), so you cannot hand Apple a pre-provisioned account;
nothing seeds or automates the grant; one Topaz clip at 16¢/s exhausts $5; and the grant
shows the account as Pro before any purchase (`:207`). Without it the reviewer sees
*"This workspace needs authorized testing access before it can activate a test
subscription…"* (`PurchaseManager.swift:558-559`), and on builds 42/44 *"…this workspace
cannot activate it…"* Expect a **Guideline 2.1** rejection. Separately, this branch
adds "Coming soon" / "TestFlight Lab" copy to the App Store build that approved build 42
(`204594a`) did not have (`RendpropApp.swift:3703-3721`, `HomeListingsView.swift:13-133`,
`CoachModel.swift:464-466`), contradicting `review_notes.txt:7` — 2.1/2.2 exposure.

Also VERIFIED: refused Sandbox transactions are remembered but never `finish()`ed
(`PurchaseManager.swift:552-565`) → StoreKit redelivers at every launch and the app
re-POSTs and re-shows the error on every foreground.

---

## Half-done fixes (VERIFIED)

- **Wrong-window refund fix covers video only.** `refund_rate_receipt` refunds the
  original window (`20261005220556:14-21`); photo/voice/chapters still call
  window-agnostic `refund_rate` (`ai-photo:185-186`, `ai-voice:370`, `ai-chapters:358-359`).
- **Stuck holds still have no release path.** No admin RPC, no TTL; `serving_cost_finish`
  refuses to change an uncertain/succeeded hold (`:177-178`). Permanent within the month.
- **Verification links are not one-use.** Consume never checks `consumed_at` (`:126-131`).
  Verify rate limit keys on client IP but the caller is the Worker → one global 20/min bucket.
- **Studio error boundary swallows everything** — fixed string, no `componentDidCatch`,
  no telemetry (`StudioBoundary.tsx:7-24`).
- **`photos` is still directly writable** (live `INSERT/UPDATE/DELETE = true` for
  `authenticated`). The expand migration is applied, Studio v18 is deployed; the
  *contract* migration (`20261005215832`) is the one remaining step — apply it now.
- **Brokerage pricing ACL: resolved.** All six `brokerage_*` functions now revoked from
  anon *and* authenticated live, including `brokerage_cogs_ceiling_cents` and
  `brokerage_contract` (the gap from 10-05). Closed.

---

## Observability — why reels were dead 27 days and nobody knew

Root cause (six gaps, all VERIFIED in source): **(1)** no alerting of any kind — no
error service, webhook, scheduled health check, admin notification category or CI
schedule; **(2)** the only reader of `provider_health` is the router behind the
`ai_router` flag (seeded off, `0018:63`), and the admin dot turns red only while the
10-minute circuit is open (`SettingsView.swift:6150-6156`) — a row with 28 failures and a
27-day-old `last_ok_at` renders grey "Quiet"; **(3)** admin "health" measures config
presence (`admin/index.ts:703-705`) and vendor-level billing over 7 days (`:718-723`) —
a Topaz success keeps "fal" green while Seedance is dead; **(4)** the app sends
`reel_made ok:true` only — the failure path emits no event (`FlythroughDetailView.swift:10467-10490`);
**(5)** logs are free text with zero request/org/user ids; deliberate HTTP errors are
never logged (`http.ts:110-117`); **(6)** ~1 attempt/day with no canary.

Live today: Seedance still `consecutive_failures=28`, `last_ok_at 2026-09-07`,
`last_fail_at 2026-10-02` — **no attempt since Oct 2**. Also never-succeeded in
production: `veo3.1/fast/image-to-video` (7 fails), `gpt-image-2` (3 timeouts),
`flux-pro/kontext` (2 fails). The "403 User is locked" theory remains unproven; the
last success coincides with `3c502e2` (Sep 7, +1,106 lines rewriting the reel path) —
the stronger lead.

**Minimal change set (ranked; each ≤ a day):**

1. **Hourly `ops_health_check()` + `ops_alert` notification category** → push/email to
   `profiles.is_admin` via the existing outbox and `notify` (pattern `0049:122-143`;
   category list `20261005220001:60-62`; copy switch `notify/copy.ts:99-205`). This
   alone would have paged you on day one of the Seedance outage *and* today at 19:25.
2. **Client failure events carrying the server code** — `Analytics.track("error",
   [category, step, code, detail])` in the reel/photo/aerial failure paths; the server
   schema already accepts it (`events/schema.ts:145`).
3. **Feed generation outcomes into `provider_health`** from the status routes
   (`ai-video/index.ts:1725-1766, 1852-1868`), guarded once per request.
4. **Admin green = a real generation succeeded in the last N hours**, per feature,
   from billing rows + reservation attempts; red on attempts-without-success.
5. **Shared JSON logger** with `{fn, route, org_id, user_id, idem-hash, provider,
   provider_status, error_class, vendor_reason}`; log every 5xx; fix vendor 402 being
   classified `validation` (`common.ts:93`) — it blames the customer's photo for our
   billing problem.
6. **Deploy markers** (`{function, version, sha, time}` on every deploy) + `docs/RUNBOOKS.md`.

Five SLIs with SQL are in the observability agent's report; SLI-2 alone
(`provider_health where consecutive_failures>=3 or last_ok_at < now()-24h`) returns the
Seedance row today.

---

## Data model + disaster recovery

**HIGH (VERIFIED):**

- **A removed team member can never finish deleting their account.** `listings.agent_id`
  is a blocking FK to `profiles` (`0001:42`); `remove_org_member` leaves `agent_id` set
  (`0048:588-591`); the deletion writer only reassigns inside orgs the user still belongs
  to (`20261005150445:339-345`) → `profiles.delete()` fails (`me/index.ts:1567`), the
  request stalls to manual review after 12 sweeps (`0039:368-386`) **after** the solo-org
  data has already been purged irreversibly.
- **Owners/admins can hard-DELETE listings through PostgREST.** Live:
  `has_table_privilege('authenticated','listings','DELETE') = true`; RLS delete policy
  exists (`0007:49`). A hard delete skips the soft-delete media inventory (fires on UPDATE
  only, `20261005220002:126`) → R2/Stream objects never cleaned; surviving
  `upload_reservations`/`spatial_jobs` rows later make account deletion fail with RP409;
  cascades presenter profile → drafts → creative results of *other* listings.
- **Cleanup for soft-deleted listings never runs.** Live `cron.job`:
  `upload-cleanup-drain`, `listing-lead-privacy-drain`, `private-message-retention` are
  all **`active = false`**. The renders bucket's public `r2.dev` domain holds 235/237
  capture assets; undelete is allowed, so a restored listing can point at purged objects.
- **No backup strategy exists.** Pro plan, us-west-2; PITR/retention/restore test never
  mentioned anywhere; `DATABASE-EXECUTED-RESULTS:165` says backup/restore is unproven;
  R2 has no versioning or retention lock; Stream holds 0 videos (fed *from* R2).

**MED:** a team member's account deletion cascade-deletes team-owned Studio content via
direct `auth.users` FKs; owner deletion promotes nobody; `video-reflections/<org>/<job>.mp4`
outputs are never deleted; "anonymized" Apple rows still carry the deleted user's id as
`appAccountToken`; `deletion_requests.email` kept forever; `cost_ledger` deleted for solo
orgs while `app_video_cost_reservations.cost_ledger_id` tombstones dangle.

**Constraints:** `render_jobs.status`, `listings.space_type`, `cost_ledger.feature/provider`,
`apple_subscriptions.plan/environment`, `notification_log.category/channel` are free text;
`listings.price_cents`, `cost_ledger` amounts and every `plan_entitlements` column have no
`≥ 0` check; no unique on `capture_assets.storage_key`; `notification_outbox(dedupe_key)`
has two identical unique indexes.

**Rebuild-from-zero:** migration order check **passes** (all 57 numbered files sort before
all 50 timestamped ones) but `0005b_`/`0008b_` don't match the CLI's `^([0-9]+)_` pattern,
there is no `supabase/config.toml`, 17 migrations patch earlier bodies by text replacement
(5 pinned by md5), and four files were edited after being applied. Ledger drift was
≥ 21 files recorded under other versions before today; all 20 files applied today were
re-stamped (`20261006191524`–`192705` vs. their `20261005…`/`20261006164721…` filenames),
so the ledger now disagrees with ≥ 41 filenames. Not in migrations at all: Vault secrets, pg_cron/pg_net, Auth
providers, function secrets, manual cron jobs.

**If we lost X tonight:** Supabase → schema yes (by hand, not `db reset`), data only from
an untested platform backup of unknown retention; R2 → every capture, photo, tour and AI
output gone permanently; Cloudflare → same plus site/Studio/tours down; Apple → no
updates and Sign-in-with-Apple identities at risk; GitHub → survives in local clones; the
Mac → production keeps running but every signing/ASC/APNs/management key must be
re-issued. No second admin exists on any of them.

---

## CI / supply chain / deploy path

- **Production deploys bypass CI and review.** `ci.yml` has no deploy job (only
  `wrangler deploy --dry-run`, `:609-610`). `main` is unprotected; 5 of the last 6 main
  runs are red. Bridge history: 24 scripts ran raw SQL on production via the Management
  API, 12 hand-inserted `schema_migrations` rows, 24 deployed functions, 35 deployed
  Workers; 10 checked for a clean tree, 1 checked CI. `supabase db push --include-all` was
  attempted twice and stopped only by a CLI flag error, exiting 0 (`1275-property.log`).
  Nothing — no hook, no CI gate — prevents a bulk push; `check-migration-ledger.mjs` is
  advisory and unwired. The upload-gateway production config exists only inline in
  `_bridge/cmd/1555-deploy.sh:70-80`.
- **Floating deps on the deploy path:** `npx --yes wrangler@latest` ×16 with production
  credentials in env; `npm:@supabase/supabase-js@2` floats the major in the service-role
  client module (`_shared/supabase.ts:12`); `esm.sh/aws4fetch@1.0.20` signs R2 in five
  modules; `deno.lock` is gitignored (`.gitignore:29-30`).
- **CI hardening:** no top-level `permissions:`; six jobs have none; `npm audit --omit=dev`
  checks a package with zero runtime deps; no Studio/Python/Deno audit; gitleaks binary
  unpinned by checksum. All `uses:` are full-SHA pinned and match their tags (good); no
  `pull_request_target`; `.gitleaksignore` is exact fingerprints only (good).
- **CVEs (runtime):** worker `urllib3 2.2.3` (6 HIGH incl. CVE-2026-21441/-44431) and
  `requests 2.32.3` (2 MOD); spatial `Pillow 12.1.1` (12 HIGH, decodes user captures —
  disabled service). Dev-only: `undici 7.29.0` (TLS validation bypass), `sharp 0.35.x`,
  `source-map-js 1.2.1`.
- **Reproducibility:** no `.nvmrc` (CI node 22, Mac 24.14); CI Python 3.12 vs Dockerfile
  3.11; no `.xcode-version`; archives only from the laptop (Xcode 26.4.1).
- iOS has **zero third-party dependencies** (no `Package.resolved`, no Pods). Strength.

## Release engineering (iOS)

Release settings are correct (`-O`, wholemodule, dwarf-with-dsym, no DEBUG in Release,
`ENABLE_NS_ASSERTIONS=NO`); `uploadSymbols` true in all export plists; the
Info.plist/entitlements/privacy-manifest matrix is consistent except an unused
`NSMotionUsageDescription`. **`-uiTesting` is not a backdoor:** `Config.swift:78-84` is
`#if targetEnvironment(simulator)`, compiled to constant `false` on device, with a CI
negative control (`run-app-store-boundaries.sh:22,75,183-184`).

Problems: **what shipped is not in the repo** — every branch says 1.0.3/31 (lab 43) while
42/44/45 shipped via CLI overrides; no git tags; none of the three shipped commits is on
`main`. **Lab and App Store builds are interchangeable** (same bundle id, entitlements,
name, icon, version train, tester group; the lab project has a scheme named `Rendprop`;
`asc.py build attach` doesn't filter `buildAudienceType`) — only the export-options
choice in a private script keeps them apart. `demo.mp4` (9.4 MB, **~48% of the 19.7 MB
IPA**) ships although three docs say it doesn't. `xcodegen` output is not reproducible
(group named after the checkout directory) — the cause of the long-lived uncommitted
`project.pbxproj`. `MockAPIClient` (with `isAdmin: true` fixtures) is compiled into the
device binary, unreachable but present.

## Never-audited services

All four are **dormant** and can spend nothing today. `services/api` is a dead schema
(9 of 18 tables don't exist in migrations; would create `users` with email/phone and no
RLS if ever applied). `spatial-worker` is the best-built: strict URL/host/size validation,
no LLM, private bucket, no double-spend — but the controller holds the **full
service-role key** (`spatial/index.ts:391`, plain `===`), the GPU sandbox has open
egress while installing unpinned packages (`modal_setup.sh:11-20`), spend never reaches
`cost_ledger`, and a failed attempt still charges the full 600¢. `pipeline` (only runs
inside the dormant render worker) **pays for Gemini and then throws the result away**
for any non-sponsored workspace: the Anthropic QC step is unpriced → refused
(`funding.py:77-83`) → `enhance_frame` ships the original (`enhance.py:371-382`) after 1–2
Gemini calls per room already went out; it still writes `cost_ledger` directly at ~½ the
real tariff (`cost_ledger.py:189-207`, `costs.py:12-13` uses Gemini 2.5 pricing); and
internal-testing workspaces have no money ceiling except a per-job cap adjustable to
$10,000 by env var (`config.py:195`). `marketing-video` has an injectable shell template
(`gen.py:316,320`) if ever productised.

## Test suite — does green mean safe? No.

1,331 `Deno.test` declarations (~1,521 at runtime), 270 SQL invariants, ~398 Studio tests,
868 iOS check sites, 0 coverage tooling. Of 30 sampled tests: 11 strong, 9 medium, 10
tautological/proxy. Every one of the seven shipped bugs (build-37 overflow, dead reels,
writable `photos`, Topaz $12/$48, measurements full-row write, camelCase leak, and this
branch's `40001` PostgREST retry loop) has the same shape: the oracle was derived from
the implementation (`dronecost.test.ts:54-61` asserts a constant equals itself;
`public-details_test.ts:171-176` used the production predicate), the check was an
enumerated list instead of a universal rule (`invariants.sql:84-93` tests 11 of ~83
tables for DML denial — `photos` wasn't one), or the boundary was mocked (no real fal, no
real PostgREST, no device stack, the fixtures asserted `40001` as *correct*). All 65 UI
tests and the device-crash regression test never run in CI (`XCTSkip` on device).

Eight missing tests worth more than the existing 1,521 combined: default-deny grant
sweep over every table/function; real PostgREST in the loop; device-stack render matrix
in Release; daily paid canary (reel/aerial/drone) with alerting; independent price oracle
not imported from `ledger.ts`; minimal-write contract per mutation; public-route privacy
fuzz with case/separator variants; published-number parity (`pricing.html`/`llms.txt`/
paywall/Studio vs `plan_entitlements`).

---

## Confirmed correct on the branch (VERIFIED)

No shipped client writes `photos` directly (builds 42/44 only `SELECT` via PostgREST,
`LiveAPIClient.swift:416-418`); the photo RPCs take `p_actor` from the JWT and check
actor/org/listing/asset on every branch; the Sandbox fence routes only on the verified
App Store environment and leaves Production restore and mixed histories intact; old
signed video tokens still verify; lead notifications fire without GHL (`trg_leads_notify`
untouched); recipient tokens are 256-bit CSPRNG, SHA-256 stored, 24h server-enforced,
GET side-effect-free; promotional email is skipped cleanly at enqueue/drain with push
intact; Studio 404 change is safe; deep-link queue (32, newest dropped, full-URL dedup)
and single paywall host are sound; today's CAS branch correctly swaps `40001` for
`PT409` with md5 guards and is not last-write-wins (deploy edge handlers before the
migration — which happened in the right order today).

---

## Ranked actions

**Today (owner + Codex):**
1. Roll back P0-1 (redeploy prior AI function versions) and P0-2 (SQL: drop the anonymous
   branch from `upload_new_admission`). Then decide the product question these fixes
   pre-empted: *is Rendprop anonymous-first or not?* The code now says no; `llms.txt`,
   the App Store review notes and 32 of 38 users say yes.
2. Delete `_bridge/cmd/1659–1662*.sh`. Move every `_bridge/.*` credential into the
   keychain or Supabase/Cloudflare secret stores; make the bridge refuse scripts not
   listed in a signed manifest.
3. Make the GitHub repo private.
4. Rotate the Supabase JWT secret (or disable legacy keys) + fal/Gemini/Anthropic/KIE,
   then ship a build with the new anon key. Record a dated rotation receipt.
5. Apply `photo_authority_acl_contract`; revoke `DELETE` on `listings` from
   `authenticated` (soft-delete only); enable cron jobs 5–7 once the drains are reviewed.

**This week:** observability items 1–4; seed the App Review grant path or relax the fence
for reviewers; fix R3–R7; `listings.agent_id` reassignment on member removal; backup/PITR
decision + one restore test; `.nvmrc`/`.xcode-version`/tags per shipped build; bump
`urllib3`/`requests`; branch protection + required CI on `main`.

**Still open from earlier audits:** media revocation design (public bucket), legal
publication, serving-cost allocation ($10/$21/$53 vs ~71% worst case), Small Business
Program effective date, fal balance check, fair-housing semantic bypasses, data export,
`security.txt`.

---

## Method and limits

Every live claim above came from a query, catalog read or deployed-bundle grep this
session; every code claim has a file:line on `4a209d4` or the named build commit. Not
verifiable from here: the service_role key's current validity (inferred from the
unchanged legacy anon mint — strong, not absolute); whether the provider side revoked the
burned keys; the production `ai_router` flag and `JOB_TOKEN_SIGNING_SECRET`; edge-function
request logs (the log tables are not exposed through this connector); whether any
customer has hit RP402/RP401 since 19:24 UTC (no artifact records refusals).

Two corrections to earlier Claude notes stand: the "27 days" duration is a `provider_health`
inference, not proven continuous (the table has no history), and the 10-04 "User is
locked" cause is unproven. Nothing in this audit was asserted from memory of code I
wrote; where a 10-05 finding was closed by Codex (brokerage ACL), it is marked closed.
