# Launch fixes — 2026-10-08 (Claude → Codex handoff)

Branch: `claude/launch-fixes-20261008` (worktree `~/Rendprop AI/RendProp-Ai-launch-fixes`),
based on `fix/required-account-onboarding-20261008` @ `ec1e3e6` (the TestFlight 51 payload).
Two commits: `78556e0` (backend, **deployed**) and `c90ef58` (iOS + site + metadata, **not built**).
Verdict that motivated this: `docs/audits/LAUNCH-READINESS-VERDICT-2026-10-08.md`.

## Owner decisions applied (Aaron, 2026-10-08 — "take over and apply all fixes")

1. **Cost model = ceiling.** Per-feature meters + `log_job_cost()` monthly COGS ceilings
   (1200/2400/6000¢) are the serving authority. The funded-serving model stays in the
   codebase and the schema, inert, behind `app_config.serving_mode`.
2. **Free tier = one published listing per workspace, for life.** Paid plans add AI
   allowances and more listings. Apple's own 7-day introductory offer is the trial.
3. **Account-first stands.** Guests (public build 42) get a clean 403 "Sign in with Apple
   to upload and publish" instead of being signed out; anonymous uploads stay closed.

## What is LIVE in production (verified)

| Item | Live artifact |
|---|---|
| Migration `20261008201736 launch_ceiling_mode` | `app_config.serving_mode = {mode:ceiling, free_published_listings:1}`; `serving_mode()`, `free_published_listings()`, `free_publication_admitted(org,listing)`, `grant_sandbox_trial(...)`; exact-anchor patches to `subscription_trial_paid_or_override`, `subscription_trial_render_guard`, `subscription_trial_upload_guard`, `upload_new_admission` (RP401→RP403), `serving_operation_complete`, `subscription_serving_activation`, `client_recipient_verification_consume` (single-use). Dry-run + readback: 2 paid/override orgs, 35/40 orgs hold a free slot, admin activation `private_sponsorship`. |
| Migration `20261008201840 ops_health_alert` | `ops_health_findings()`, `ops_health_check()`, category `ops_alert`, cron job 8 `ops-health-check` at :07 hourly. First run queued 4 rows (Seedance + gpt-image-2 dead streaks) and **all 4 were sent** (push + email) at 20:19:02 UTC. |
| Functions (source-verified via `deploy-backend.mjs --run`, Supabase CLI 2.120.0) | ai-photo 59, ai-video 57, ai-copy 26, ai-chapters 32, ai-voice 41, coach 28, studio 24, notify 19, **me 56**. Receipt: `docs/releases/BACKEND-LAUNCH-CEILING-MODE-20261008.json`. JWT policy unchanged (me/notify false). |

Repo migration files carry the live ledger versions (`20261008201736_…`, `20261008201840_…`), so
no new ledger drift from this work.

### Behaviour now

- Named accounts: every AI route works again (`fundedAttempt` short-circuits in ceiling mode;
  meters + ceilings bound spend). `boundedPhotoChain` keeps the operator chain; helper fences off.
- Publishing: paid Apple plans publish/upload without funding rows; free workspaces may publish
  one listing (re-publishing it is free); the second listing returns RP402 "Subscribe to activate
  hosted publication" → paywall.
- Purchases: a Production purchase applies the plan and `subscription_serving_activation` reports
  `available:true, funded:false, authority:existing_non_apple` (the client enum has no "ceiling"
  value; this is its "available, unfunded" shape). No funding RPC is called.
- Sandbox purchases (App Review, TestFlight testers): `me` grants a 7-day `trial` plan
  (3/60/4/2/1, 1200¢ ceiling) via `grant_sandbox_trial`; never downgrades a paid workspace.
- `/me` now returns `serving_mode` ("ceiling" | "funded") for the native paywall.
- Guests: `assertPaidAiIdentity` and `upload_new_admission` refuse with 403/`forbidden`.
- Alerts: hourly; one push + one email per admin per finding per UTC day; findings = provider
  dead streaks, video attempts without success, journaled AI ops without completion, stuck
  worker jobs, pending Apple notifications > 1h, failing notifications, funded-mode-unfunded,
  spend > $50/24h, any org ≥ 80% of its ceiling.

### Switching back to the funded model (when provisioning tooling exists)

```sql
update public.app_config set value = value || '{"mode":"funded"}'::jsonb, updated_at = now() where key = 'serving_mode';
```
Edge functions re-read it within 30 s. Everything Codex built resumes: holds, schedules, pools,
media budgets, held trials, the Sandbox fence. The hourly alert `funded_mode_unfunded` fires
if the mode is funded while no funding exists.

## On the branch, NOT yet built or deployed — Codex owns these

### A. iOS (compile, test, phone-check, TestFlight 52)

Swift was edited without a compiler. Changes are small and string-heavy; the one logic change
is the paywall. Please compile first, then run the native suites.

- `Purchases/SubscriptionBillingContext.swift`: `servingMode`/`isCeilingMode` decoded from
  `/me`; `PurchaseDispatchAdmission.allows(... ceilingMode: Bool = false ...)` allows an ordinary
  purchase in ceiling mode (defaulted param keeps existing call sites and tests compiling).
- `Purchases/PurchaseManager.swift`: `canStartNewPurchase` → `ceilingModePurchaseAllowed()` in
  ceiling mode; `ceilingShowsIntroOffer(for:)` (StoreKit eligibility only);
  `canCheckTrialAvailability` false in ceiling mode; `purchase()` skips the held-trial block
  (`!ceilingMode`) and passes `ceilingMode` to dispatch admission. Held-trial code path is
  untouched for funded mode; the source-grep anchors in `tests/run-native-trial*.py` are kept.
- `Purchases/PaywallView.swift`: ceiling-mode header, `buyTitle` ("Start 7-day free trial" /
  "Subscribe with Apple" / "Confirm plan change with Apple"), `disclosure` from
  `SubscriptionOfferPolicy`.
- `Purchases/PaywallHost.swift` `.trialEnded` copy → free-tier explanation (new accounts are
  not "trial ended"). `Plan/PlanBanner.swift` free-state detail.
- `Screens/RenderStatusView.swift`: publish 402 → "View plans" → `.upgrade` (the server
  sentence explains why; no invented "used your renders"); offline copy.
- `Screens/FlythroughDetailView.swift`: `AIFailure.isServiceUnavailable`; `actionHint`
  copy; AIFailureCard + Photo Studio alert get **Contact support** (mailto aaron@pilk.ai);
  reel 5xx copy; "3D walkthrough" card no longer mentions TestFlight Lab;
  `Analytics.trackAIFailure` on reel and aerial failures (inside `MainActor.run`).
- `Photos/PhotoEditService.swift`: batches stop on the first service-unavailable failure;
  failure telemetry via `Task { @MainActor in … }`.
- `Networking/APIClient.swift`: `APIError.isServiceUnavailable`.
- `Analytics/Analytics.swift`: `trackAIFailure(_:step:error:)` → `error` event with
  `category/step/code/detail` (server schema already allows these).
- Copy: `ReviewSubmitView` (no "no registration needed"), `SettingsView` sign-out + delete
  account subscription note, `CoachModel` (account-first answer, no TestFlight Lab),
  `NewListingView` (no MLS-feed promise), `HomeListingsView` (no "credit quote", no Lab).
- `tests/run-native-trial.py`: `actionHint` anchor updated to the new sentence.

Please run: `apps/ios/tests/*` (swiftc suites), `run-native-trial.py`, `run-native-trial-hold.py`,
the Release simulator compile, then the build-50/51 phone checklist plus: paywall on a
**named non-admin account** shows "Subscribe with Apple" / "Start 7-day free trial", a Sandbox
purchase lands as a 7-day trial plan (Home banner "Trial"), a second listing publish on a free
account shows the server sentence and "View plans", a photo batch with the AI provider
unreachable stops after the first failure and shows Contact support.

### B. Site (`services/edge/tour-host`) — wrangler deploy

`src/legal.ts` (Terms §2 + Privacy §1 account-based + one free listing; **Effective October 8,
2026**), `public/support.html` (delete path Settings → Your data; requirements), `public/llms.txt`
(allowances, trial, account-first), `public/index.html` lede, `scripts/check-legal.mjs` +
`scripts/check-routes.mjs` (new wording/date). Local `npm test`: all suites green (unbranded 687,
routes 732, legal 92/92, bundle gate 28, client delivery, audit boundaries).

### C. App Store metadata (`docs/appstore/metadata/en-US`)

`description.txt` (account-first paragraph; free first listing), `review_notes.txt` (ACCESS,
NEW IN 1.0.4, SPATIAL Coming-soon cards, REVIEW path incl. 5 free photo edits, TRIAL incl.
Sandbox → trial plan, DELETION), `release_notes.txt`. `account-first-review-draft` button
label fixed to "Sign in with Apple".

### D. Not done here (deliberately)

- Credential rotation (service-role JWT, fal/Gemini/Anthropic/KIE): needs the ordered cutover
  (functions/workers/Modal on `sb_secret_` → public build on the publishable key → disable
  legacy keys → delete `_bridge/repo-snapshot.tgz` and `~/Rendprop AI/repo/services/pipeline/.env`).
  Build 42 still ships the legacy anon JWT, so legacy keys cannot be disabled until 42 is replaced.
- Cron jobs 5–7 (cleanup drains) stay off pending review of what they delete.
- `member_portfolios` seeding (empty `/a/<handle>` pages), stuck-hold release RPC, Studio
  error-boundary telemetry, the three deep `some View` bodies
  (`PhotoCompareView.body`, `FlythroughDetailView.body`, `ReelStudioView.body`).
- Seedance: the provider is still dead (28 consecutive failures, last success Sep 7). The
  hourly alert now reports it. Fix or swap the reel provider; until then the Reel tile is live
  and will fail with the honest copy.

## Housekeeping

- Worktree `RendProp-Ai-launch-fixes` had linux-arm64 `node_modules` created for tests/deploy
  (`apps/studio`, `services/edge/tour-host`, `services/supabase/functions`); they were removed
  after use. Run `npm ci` on the Mac before using those folders there.
- Backend edge suite: 1,795 passed / 0 failed / 1 ignored (pre-existing). New tests:
  `_shared/serving-mode.test.ts`; `paid-ai-auth.test.ts` expects 403 for guests;
  `applejws.test.ts` stitched import includes `servingMode`; `me/billing.test.ts` models
  `serving_mode` and asserts `/me` reports it.
- The deploy used `apps/studio/scripts/deploy-backend.mjs --run` with the owner's Supabase
  access token read from `_bridge/.supabase-token` inside the shell; the value was never
  printed or copied.
