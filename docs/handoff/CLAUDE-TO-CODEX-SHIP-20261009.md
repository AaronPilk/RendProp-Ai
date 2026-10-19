# Ship handoff — Claude → Codex, 2026-10-09

Goal: everything on `claude/launch-blockers-20261008` live — website, Studio, iOS 1.0.4 on TestFlight, then App Store submission.

## Source of truth

- **Branch** `claude/launch-blockers-20261008`, all code at **`4c58540`** with this handoff committed on top, worktree `~/Rendprop AI/RendProp-Ai-launch-blockers`.
- It contains your `1f5650e` (and the `1cbaa22` merge) as ancestors, so `audit/launch-alignment-20261008` fast-forwards to it. Nothing of yours was rewritten.
- Not pushed yet: the sandbox has no GitHub credentials.
- Owner (Aaron) decisions now in force:
  - Monthly plans only.
  - Apple Small Business Program approved 2026-09-25, so the 15% rate applies from 2026-10-11.
  - No active subscribers, so grandfathering is moot.
  - All current app users are invited testers with unlimited use, via sponsorship from Aaron's workspace.

## Already LIVE — do not redeploy unless verifying

Supabase project `ymgqpbnjpztwjsyvceld`. Receipts are in `docs/releases/`.

| Migration (ledger version = repo filename) | What it does |
|---|---|
| `20261008235218 launch_round2` | One money authority, service windows, `/me` envelope |
| `20261009005727 launch_settlement_identity` | Yours: a ledger row binds only its exact attempt |
| `20261009005753 carry_paid_allowance_through_grace` | Yours: no new money during Apple grace |
| `20261009015823 small_business_commission_date` | 30% until `2026-10-11T07:00:00Z`, then 15% automatically |
| `20261009022239 admit_pre_and_grants` | Video hold netted once; `ledger_id` index; client TRUNCATE/TRIGGER/REFERENCES revoked |

Edge functions (all source-verified by readback): ai-photo **63**, ai-video **61**, ai-copy **30**, ai-chapters **35**, ai-voice **44**, coach **32**, studio **27**, me **60**, notify **20**.

Live data change: Richard Tocado's main workspace `bfd4427e…` now has a private-testing sponsorship, created through the same eligibility rules as Stephenie's.

Verify, read-only:

```sql
select version, name from supabase_migrations.schema_migrations order by version desc limit 5;
select public.serving_envelope_int('apple_commission_bps',0);
```

Expect `20261009022239` at the top, and `3000` before Oct 11 / `1500` after.

## 1. Push and CI

```
cd ~/Rendprop\ AI/RendProp-Ai-launch-blockers
git push -u origin claude/launch-blockers-20261008
```

Let CI run.

- **New/changed SQL suites:** `launch_blockers.sql` (189), `serving_grace.sql`, `serving_settlement_identity.sql`, `launch_blockers_pg.py` (races).
- **Single-application list:** `tools/audit/run_database_regression.py` has `20261008235218` and `20261009005727` in `SINGLE_APPLICATION_MIGRATIONS`. The other two Oct 9 migrations are replay-safe and were applied twice locally.
- **Local results, same tree:**
  - SQL suites all green: funded_serving 63, bounded_trial 65, hosting_retention, photo_partitions 33, video_erase 51, direct_bria 40, purchase_reservations 43, video_duration 31, transport 7, app_video_rejections 34.
  - Invariants 269/270: #267 needs a dblink on port 5432 and fails only in the sandbox.
  - Deno 1,804/0. Studio 469/0. Site all suites. `tools/asc/test_asc.py` 208/0.

## 2. Website + Studio

If Aaron already double-clicked `~/Rendprop AI/Ship-Rendprop-20261009.command`, this step and the push are done. Check `https://rendprop.com/terms` for "Starter, Pro and Team, each billed monthly" and skip ahead if it's there.

```
cd services/edge/tour-host && npm ci && npm run predeploy && npx wrangler deploy
cd ../../../apps/studio && npm ci && npm run verify && npx wrangler deploy
```

Workers: `rendprop-tour-host` and `rendprop-studio`.

After deploy, confirm:

- **`/pricing`:**
  - no `490`, `990`, "yearly" or "2 months free"
  - FAQ says published tours stay live "90 days after the subscription expires"
  - "No surprise meters" mentions the monthly AI cost budget
  - CTA reads "Try it on a real listing."
- **`/terms` §6:** monthly-only wording, and trial AI described as "drawn from a limited shared allocation".
- **`/llms.txt`:** monthly only; seats and video quality upgrades listed; trial AI described as limited.
- **Studio → Account & plan:** shows the AI budget card for a non-sponsored account. Sponsored testers see no budget card.

Rollback: `npx wrangler rollback` in either directory.

## 3. iOS 1.0.4 (needs Xcode — not compiled by Claude)

Files changed since your `1f5650e`:

| File | Change |
|---|---|
| `Purchases/Products.swift` | All annual ids in `notSoldAtLaunch`; `sellsAnnual`; neutral `annualBadge` |
| `Purchases/PaywallView.swift` | Monthly/Yearly picker only shown when `sellsAnnual` (false) |
| `Purchases/SubscriptionBillingContext.swift` | `checked()`: `kind != "sponsored"` guard; a malformed/overflowing pool returns a copy with `pool: nil` instead of dropping the envelope |
| `Screens/SettingsView.swift` | Pending activation branch no longer requires `servingEnvelope == nil` (a payer is never told to subscribe); envelope rows also in the legacy-shape branch |
| `Upload/UploadManager.swift` | `isTerminalAdmissionFailure` includes `isTrialCapacityUnavailable` |
| `Screens/HomeListingsView.swift` | Guide copy "Choose a plan. Every plan bills monthly." |
| `RendpropUITests/BetaPolishUITests.swift` | Asserts no period picker, selection reads "Monthly" |
| `RendpropUITests/PaywallShot.swift` | Comment only (p02 now SKIPs) |
| `tests/ServingPhotoPackageTests.swift` + `tests/run-serving-photo-package.py` | Sponsored case; overflowing pool keeps budget and shows "capacity unavailable"; structural counts updated |

Do:

1. Release build for device and simulator.
2. `python3 apps/ios/tests/run-serving-photo-package.py`, plus your other native harnesses: `run-native-trial*.py` and `run-purchase-fulfilment.py`. They source-check PaywallView and SettingsView.
3. UI tests, including `BetaPolishUITests` with the local StoreKit file.
4. Bump the build number. Archive from **this source** (not internal build 51). Upload to TestFlight.

## 4. Phone acceptance (Aaron + Codex, real device)

- Sign in with Apple; cancel. Saved-work transfer. Workspace switch isolation.
- Paywall on a named non-admin, non-sponsored account:
  - only three monthly plans; no Yearly tab
  - "Start 7-day free trial" / "Subscribe with Apple"
  - Restore and Manage both work
- Free tier: first listing publishes; a second listing shows "View plans". Free AI photo edits work. Plan & usage shows "Free AI allowance $X used · $Y available of $3".
- Sponsored tester (Aaron / Stephenie / Richard): no AI budget row; meters only.
- **Real provider acceptance, one each, non-admin non-sponsored account:** photo edit, reel, aerial. This is also the FAL verdict.
  - Seedance is still route #1 for `video.reel_clip` / `video.aerial`, with 28 failures and last success 2026-09-07. The fallbacks are hailuo and veo3.1.
  - If Seedance fails again, `provider_health.last_status` names why. Then disable that `ai_routes` row (`enabled=false`), with Aaron's OK.

After each success, check:

```sql
select request_key, stage, provider, model, hold_cents, state, ledger_id is not null as settled
from public.serving_cost_reservations order by created_at desc limit 10;
```

Every succeeded row must show `settled = true` within seconds. An unsettled succeeded row means a ledger writer's `request_key/stage/provider/model` doesn't match its hold. Report it; don't relax the trigger.

A refusal must show kind-specific copy. A shared-pool refusal must be 402 `trial_capacity_unavailable` with retry/support copy, never an upgrade prompt.

## 5. App Store submission (1.0.4)

- **Owner, first:** in App Store Connect, remove the three annual subscriptions from sale (`com.rendprop.app.{starter,pro,team}.annual`). By API: `python3 tools/asc/asc.py subscriptions unprice <id>`.
- `tools/asc/asc.py` now skips annual ids in every command unless `--include-annual`.
- **Metadata:** `docs/appstore/metadata/en-US/description.txt` is 3,952 chars and `review_notes.txt` is 3,980 chars (was 4,219, over Apple's 4,000 limit). Apply with `asc.py review apply`, then `asc.py status`.
- Screenshots must not show a Yearly tab. Add the new build to the version and submit.
- Unconfirmed: the "John Apple" workspace (`10ff6907…`, created Sep 9, free, no grant). Ask Aaron whether it's App Review. If it is, App Review is covered by `org_has_app_review_funding`, or by Sandbox trial grants that draw on the trial pool. The pool is 29,000¢ until 2026-11-08 and currently 0¢ spent.

## 6. Known, not fixed — don't reopen without Aaron

- **Supplier liability:** holds settle to catalog estimates, not measured usage. Input-size bound not enforced (accepts 24 MP / 8,192 px vs the 2,048 px assumption).
- **Apple price facts:** offer codes, win-back offers and non-US prices aren't recorded; the envelope assumes US list price. Create no offer codes until this is fixed.
- **Commission timing:** the switch keys on `now()`, not each term's purchase date. Zero subscribers today.
- **Lost finish:** a lost `serving_cost_finish` leaves its hold counted (over-count, rare).
- **Features refused for paying customers:** direct Bria erase and presenter have no quote, so they're refused for non-sponsored workspaces (fail closed).
- **Python worker:** its holds can't settle. The path is disabled.
- **Privacy crons:** three privacy cron drains are deliberately off. Confirm the privacy policy doesn't promise those sweeps.
- **Auth:** leaked-password protection is off (Apple-only sign-in).
- **Owner-only:**
  - repo private → ordered credential cutover (rotation runbook)
  - provider key rotation
  - Small Business Program date already set

## Rules

- **Secrets:** never print secret values; keys live in the Supabase dashboard or a gitignored `.env`. Contact email is **aaron@pilk.ai** — never skyway.media. Commit as `Aaron Pilk <273441888+AaronPilk@users.noreply.github.com>`.
- **Production writes:** no raw-SQL funding seeding. Don't change repo visibility or revoke production credentials without Aaron.
