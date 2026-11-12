# Launch readiness verdict — 2026-10-08

Question asked: "look at all of the app and tell me if we are ready to launch."

**Answer: No.** Not for paying customers, not for App Review, and not for a soft
launch beyond your own workspace. The app on the App Store today cannot publish a
tour, cannot run any AI feature, and can still take money. Two days of hard work by
Codex made the backend *safer* than on Oct 6 and *less usable*: it now fails closed
in more places, and every switch that would open it is raw SQL that nobody has run.

Method: two read-only agents walked the newest branch
(`fix/required-account-onboarding-20261008` @ `2c567a5`, the TestFlight 50/51 payload)
as a first customer and as a backend gate check; I re-verified every load-bearing claim
against production (Supabase project `ymgqpbnjpztwjsyvceld`, live site, App Store page,
build-42 source `204594a`) at ~19:30 UTC today. One agent claim (that `/pricing` shows
the old 8/150/8 numbers) was false and is excluded — live `/pricing` matches the DB.

---

## What a customer gets today (verified live)

| Surface | State | Evidence |
|---|---|---|
| **App Store 1.0.3 (42)**, live 5 days, IAPs on sale $49–$990, copy says "Explore, record and import without signing in" and "7-day free trial" | **Harmful.** A guest who taps upload gets HTTP 401 → build 42 refreshes, retries, gets 401 again → `AuthStore.signOut()` wipes the guest's tokens and pending adoption (`204594a LiveAPIClient.swift:216-228`, `AuthStore.swift:380-397`). Their cloud identity is orphaned. AI calls hit the same path. A purchase succeeds at Apple, the plan activates, and every AI route still 503s. | apps.apple.com/us/app/id6808982413; uploads v52 maps RP401→401 (`transport.ts:28`) |
| **Publishing** (any build) | **Blocked for 38 of 40 orgs.** Live triggers `subscription_trial_publication_admission` / `_render_admission` / `_upload_admission` (enabled, `tgenabled=O`) raise `RP402: Subscribe to activate hosted publication` for any org without a paid plan, override or funded trial. Trials are off. The app auto-uploads the full MP4 *before* asking, then shows "Upgrade plan" and "You've used your included tour renders" to someone who never had any. | `pg_trigger` readback; `20261006202500_bounded_subscription_trial.sql:204-246`; `RendpropApp.swift:1887-1893`; `PaywallHost.swift:48-49` |
| **AI** (photo studio, reel, aerial, drone, copy, voice, chapters, coach) | **503 for everyone but your org.** `serving_funding` = 0, `apple_serving_schedules` = 0, `serving_sponsor_pools` = 0, internal grants = 1. Message: "AI generation is not available for this workspace yet. Please contact support." — with no support button anywhere in the AI failure UI. Coach hides its 503 and answers with canned text that still says "Sign in with Apple is optional" and mentions "TestFlight Lab". | `funded-serving.ts:20-21`; live counts; `FlythroughDetailView.swift:2631-2667`; `CoachModel.swift:464-480` |
| **Paying** | **Build 50/51:** checkout is disabled client-side ("Paid subscriptions unavailable" / "The funded subscription trial is not activated") while onboarding, the Home banner and every "Upgrade plan" button still route there. **Build 42:** checkout works; a Production purchase returns `funded:false, reason:'unattested_proceeds_and_serving'` and the customer gets exactly what a free user gets. No in-app refund path; support is a mailto buried in Settings. | `PurchaseManager.swift:288-295, 556-566`; `apple-funding.ts`; `20261006164721…:401` |
| **Reels** | **Dead since Sep 7.** Seedance 28 consecutive failures, no attempt since Oct 2. `cost_ledger` has no paid generation of any kind since Oct 4. "Verified reel rollout" (Oct 7) was an ai-copy planner deploy with "no authenticated generation attempted". | `provider_health`; `AGENT-REEL-ROLLOUT-20261007.md:119-127` |
| **Activity since Oct 6** | 1 new user, 2 listings, 3 upload reservations, 55 app events (37 file_saved, 14 app_open, 2 paywall_viewed). Essentially only testers. | `app_events`, `auth.users` |

What works, and works well: Apple sign-in; on-device capture with pause/thermal/storage
recovery; on-device stabilised 60 fps render (no server worker involved — confirmed
`createRender` has no caller); the public tour page (photos → flythrough → agent card →
"Book a showing" → AI disclosure); lead capture with the demo form correctly removed;
the AI consent sheet; in-app account deletion and data export; Restore/Manage
subscription; legal pages live; `photos` and `listings` DML locked down; no third-party
code in the binary; no hardcoded prices; one support address everywhere.

---

## Three decisions only you can make (these are the real gates)

### 1. Which money model ships

Codex's "certified funding" model (live since Oct 6) refuses every AI call unless an
org has a `serving_funding` row backed by `apple_serving_schedules` (one row per SKU,
windows ≤ 31 days → re-seeded monthly), plus a per-org `provision_media_delivery_budget`
tied to that funding or uploads 503 "Bounded media storage activation pending", plus
optional photo partitions, plus a sponsor pool and a `trial_enabled` flag for trials.
Every step is raw SQL via service role; there is no admin tool, route or script
(only test fixtures call them). And under its worst-case reservation (31.1¢ per photo:
full 131k input tokens + 4,096 output tokens), the marketed 100/200/400 edits cannot fit
the 75%-net envelopes ($10.41 / $21.03 / $52.91), so Codex proposed 10/25/60 and you
asked why — correctly.

The alternative is the model that was live until Oct 6: per-feature meters +
`log_job_cost()` enforcing `cogs_ceiling_cents` (1200/2400/6000¢) as the hard backstop.
At list price a Gemini 3.1 Flash image is about 8¢ (≈1,300 output tokens × $60/M), not
31¢; 100 edits ≈ $8, and Starter at 100% utilisation of *everything* lands at the
$12 ceiling → ~71% net margin worst case, which you already accepted on Oct 5. Typical
utilisation is a fraction of that.

**Recommendation:** ship the ceiling model now. Keep Codex's journaling and refund-window
fixes, keep the Sandbox fence, but remove `fundedAttempt` from the AI routes until there
is an admin tool to provision funding in one click. Measure real per-edit cost from the
fal/Gemini invoices during the beta and revisit allowances with data, not a ceiling
estimate. If you prefer Codex's model, the gate is: an admin provisioning tool + monthly
schedule seeding + 10/25/60 allowances on the site and App Store — and none of that
exists today.

### 2. Account-first, and what the free tier gets

Codex flipped the product to Apple-account-first (build 50) — consistent with what you
asked for on Oct 1. But the App Store description, `review_notes.txt`, Terms §2,
Privacy §1, `/support`, four in-app strings and the coach all still say guest mode, and
CI *enforces* the guest wording in the legal pages (`scripts/check-legal.mjs:22-23`).
Apple rejected this app twice for sign-in gating (5.1.1(v), `docs/GPT-AGENT-BRIEF.md:17`);
the wall is defensible only if the account-based features behind it work for a new
account — today none do.

Separately: can a free account publish anything? The pricing page sells "free to
download and explore"; the live trigger says no publication without a paid plan.
**Recommendation:** one free published listing per account (it costs ~$0.03 of hosting
and is the entire conversion path), paid plans for AI and volume.

### 3. Stop selling what can't be served — today

Until #1 is resolved, either take the five subscriptions off sale in App Store Connect
or re-open the backend for build 42 (disable the three `subscription_trial_*` triggers
and return a non-401 refusal to guests). A customer charged $49 for a 503 is a refund,
a 1-star review and an App Review flag. This needs no engineering decision.

---

## Technical gates before a paid public launch (ordered)

1. **Security P0s unchanged since Oct 6.** Repo still **public**; legacy JWT keys still
   enabled (`disabled:false`, same `iat`) so the burned service-role key still works;
   `_bridge/repo-snapshot.tgz` and `~/Rendprop AI/repo/services/pipeline/.env` still on
   disk with provider keys; only the FAL key was replaced (Oct 7). Flip the repo private
   today (zero dependencies). Rotation needs an ordered cutover: functions/workers/Modal
   on `sb_secret_` keys (code is deployed; whether the runtime picked them is unverified)
   → public build with the publishable key (49+ has it; 42 does not) → disable legacy
   keys → delete the snapshot and `.env`. *The bridge queue (`1659–1662`) is cleaned
   out and the launcher removed — closed.*
2. **One real generation of each paid feature from a non-owner org**, recorded: photo
   edit, reel, aerial. Nothing paid has run since Oct 4. Fix or replace Seedance first.
3. **Alerting.** Zero of the six observability items landed; the new 401/402 gates leave
   no trace when a customer hits them. The one-migration hourly `ops_health_check` →
   push/email to admins is still the highest-value hour of work in this codebase.
4. **Copy and legal truth pass** (account-first, trial status, free tier): App Store
   description/review notes/screenshots, `/terms` §2, `/privacy` §1 (edited after its
   Oct 6 effective date without a date change), `/support` (wrong delete path),
   `/pricing` FAQ ("Eligible subscribers can start a 7-day trial") vs `llms.txt`
   ("not currently activated"), onboarding card promises, `ReviewSubmitView.swift:388`
   "no registration needed", `RenderStatusView.swift:288`, `SettingsView.swift:626`,
   `CoachModel.swift:476-480`, the MLS-feed promise (`NewListingView.swift:318`), and
   the "Coming soon"/"TestFlight Lab" tiles in the App Store build (Measurements says
   "Coming soon" on Home yet works inside every listing; "3D floor plan — Coming soon"
   is the RoomPlan scan the App Store description already sells).
5. **Wrong-state copy** that will generate support mail on day one: new users told
   "Your trial access has ended"; 402 publish refusals phrased as "allowance is used up";
   paid-but-unfunded users told to "return to its original account". Photo batches don't
   stop on the first 503 (N uploads, N failures). AI tiles never lock when the server says
   unavailable.
6. **App Review path.** A reviewer can create an account but cannot purchase (Sandbox
   fence + `provision_serving_funding('app_review')` requires their org to exist first)
   and cannot reach publishing or AI. The account-first review draft is unsubmitted and
   says "Continue with Apple" while the button reads "Sign in with Apple". Needs a
   pre-arranged working path (private-testing invite code or a funded reviewer org) and
   truthful notes.
7. **Release engineering.** CI for the build-51 payload `2c567a5` **failed 11/12** and
   TestFlight 51 shipped anyway; `main` unprotected; no deploy receipt covers the Oct 8
   00:27 UTC rollout; migration ledger drift is now 91 files; crons 5–7 (cleanup drains)
   still off; backups/PITR never tested. Three `some View` bodies regressed toward the
   build-37 crash class (`PhotoCompareView.body` depth 5→8, 15 ifs; `FlythroughDetailView.body`
   191 lines/37 modifiers; `ReelStudioView.body`) — split before the next archive.
8. **Phone acceptance** of build 50/51 is unchecked: Apple sign-in/cancel, guest-work
   transfer, StoreKit restore, camera, stale-screen close on account switch.
9. **Still open from Oct 6:** `/a/<handle>` portfolio pages empty (`member_portfolios` = 0,
   nothing seeds them); client-forwarding contact never grandfathered (1 contact, 0 verified);
   stuck-hold release; verification tokens reusable; Studio error boundary swallows errors.

---

## The fastest honest path to a real launch

- **Today:** IAPs off sale *or* backend re-opened for build 42; repo private; delete the
  snapshot and `.env`; pick the money model (#1) and the free-tier rule (#2).
- **Days 1–3:** if the ceiling model — remove `fundedAttempt` from the six AI routes and
  the three `subscription_trial_*` triggers (or scope them to "one free listing"), keep
  everything else Codex shipped; land `ops_health_check` + client `error` events; run and
  record one photo, one reel, one aerial from a trial org; fix/replace Seedance; copy and
  legal truth pass (update `check-legal.mjs` with it).
- **Days 4–7:** cut the next build from a **green** CI run; two-phone checklist; submit
  with the account-first notes and a working reviewer path; start the key-rotation cutover
  the day the new build is approved and 42 is gone.
- **Then:** Tocado Realty on real listings for two weeks before a dollar of ads. Watch
  the alert channel, the cost ledger and the fal invoice weekly.

---

## Where the two agent reports disagreed with reality

- "Live `/pricing` shows 8/150/8/2 … 3 seats" — **false**; live page shows 4/100/6/2,
  10/200/12/4, 25/400/25/8 matching `plan_entitlements`. Excluded.
- "/pricing says publishing is always free" — not found on the live page. Excluded.
- Everything else above that mattered was re-checked against a live artifact or the
  cited build-42 / branch source.
