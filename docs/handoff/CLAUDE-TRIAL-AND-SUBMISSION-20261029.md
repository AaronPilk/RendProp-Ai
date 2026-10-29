# Claude handoff: free trial live, 1.0.5 submission staged (2026-10-29)

Everything here was done against production on 2026-10-29 between 19:19Z and 19:50Z. Read-backs are quoted.

## 1. Free trial: live

Card-backed first-100 cohort. The owner set the USD 1,000 cap with Codex on 2026-10-28T21:15Z and chose "Switch the trial on today anyway" at 19:09Z.

| Object | Value |
|---|---|
| Card authority | `8df1123c-da16-419b-b3db-f573506c58a8`, reference `rendprop-first100-card-trial-2026-10`, 2026-10-29T19:25:30Z to 2027-04-27T19:25:30Z, 100,000 / 50,000 / 50,000 cents, 100 holds |
| Provider verification | `5d247187-e3a2-4c96-9c72-c94c43956274`, verified 19:31:01Z, valid_until +8 days. **New holds stop at 2026-10-30 19:31Z unless it is re-recorded.** |
| Media reserve | `card-trial-media-2026-10`, card_backed_auto_refill, 10,000 cents authorized, tariff at the enforced floors, db 1,500, logs 300, reserves total 7,808 |
| Pool | `5a41ecbe-6c85-4eeb-9465-02d41f997b73`, `card-trial-pool-first100-2026-10`, 50,000 cents, 2026-10-29T19:26Z to 2026-11-29T19:26Z, last new hold 2026-11-22T19:26Z |
| Schedules (USA, USD, 7 days, 500 cents, trial reserve 100) | pro29 `042b8a2d…` 29990 / floor 2099; starter `c58b2f48…` 49000 / 3430; pro `6e4687a8…` 99990 / 6999; team `48f08365…` 249990 / 17499 |
| Media template | enabled, `card-trial-media-2026-10`, 10,000 requests, 20 GiB, 2 GiB stored |
| Config | `subscription_trial_config.enabled = true`, pool admissions on, serving mode still `ceiling` |

Read-back after go-live: trial_enabled true, admissions true, holds 1, available 49,500 cents, authority active, all four SKUs `subscription_trial_media_template_ready = true`. The rolled-back dry run on a fresh owner returned the expected offer: 5 edits, 0 walkthroughs, 0 listings, 7 days, 1 GiB.

`subscription_trial_activation_readiness()` still reports `private_launch_authority_clear = false` and `local_prerequisites_met = false`. The causes are the owner's Team QA grant, the open sponsorships and the stale October holds. The runtime does not read this flag. Settle those or record an owner acceptance later.

**Evidence**, private and outside Git: `/Volumes/Rendprop Files/Builds/Active/public133-submit-20261029/trial-activation-20261029/`. It holds the owner approval, KIE and fal screenshots (owner's, plus fresh 19:30Z reads in the owner's Chrome), the payment evidence, the ASC SKU readback, per-SKU schedule evidence, the pool approval, the media reserve and the template evidence. The database holds only their SHA-256s.

**Paid purchases are unaffected.** In ceiling mode, `fundVerifiedAppleTransaction` returns `ceiling_mode` before any schedule lookup unless `credit_paid_funding_route` says credits are active.

### Daily renewal: required

`trial_card_authority_active` needs a verification younger than 24 hours. Scheduled tasks can't be created from this machine. The owner must create the cloud task from `Claude outputs/trial-provider-check-TASK.md` (runs at 7:17 AM and 7:17 PM), or someone must run that prompt by hand. If it lapses, intro-eligible customers can't subscribe at all until it is renewed. Existing holds still convert.

Stop levers are the same as in the activation plan:
- admissions off (reversible);
- config off (reversible);
- let the check lapse;
- revoking the authority is permanent.

## 2. App Review hold

Reservation `3311fda7-2049-4f4e-b843-794473e993b8`: demo actor `e5327bb5…`, org `f1b27a04…`, Pro29. It was inserted as postgres with the admission lock and has no media snapshot, so it can never convert to trial funding. As service_role, `prepare_subscription_trial_purchase` now replays it instead of RP409, and `/me` returns the same held offer. The Sandbox free intro then hits `grant_sandbox_trial` → `paid_workspace` → plan `pro`. It uses 1 of 100 holds and USD 5 of the pool.

## 3. App Store Connect (1.0.5, draft 588fd78e, not submitted at the time of writing)

- Listing description and What's New no longer mention monthly credit numbers. The trial is stated as U.S., five AI photo edits. Live text: `docs/appstore/live-1.0.5-20261029/`.
- Review notes are rewritten (3,876 characters) with the Pro path: Check trial availability, then Continue with Apple, using the demo account.
- Subscriptions:
  - starter.monthly v3 is "Max Monthly" and pro.monthly v3 is "Ultra Monthly". Both were "Starter Monthly" and "Pro Monthly" before.
  - team.monthly v3 now says three seats.
  - pro29 v1 no longer says "60 AI credits".
  - Max, Ultra and Team review screenshots were replaced with the current all-plans paywall (1320x2868). The old ones are in `Claude outputs/build133/asc-backup/`.
- Draft items: version 1.0.5, four subscription versions, credits.100 v1 and website.premium.property v1.
- **The repo metadata files are unchanged on purpose.** `docs/appstore/metadata/en-US/*` and `tools/asc` (`asc.py` SUBSCRIPTIONS, `catalog_copy.py`) still hold the credits-active copy their tests pin. Running `asc.py subscriptions` or `catalog_copy.py apply` would put "N AI credits monthly" back on the live store. Run them only once the monthly credit catalog is really active.

## 4. Repo

`services/supabase/migrations/20261029175419_reviewer_usage_summary_window.sql` matches the production ledger statement byte for byte (md5 `be0a7ef98417559b8bf677b00aedd73a`, 1,934 characters). It is `create or replace` only, so the regression replay twice is fine.

## 5. Open issues, by priority

1. **Declutter fails during a funded Production trial.** `subscription_trial_cost_guard` refuses `photo.suggest`, and iOS always runs the Declutter assessment first. Staging, sky, twilight, lawn and custom edits work. Fix it before customers reach the trial: allow `photo.suggest` when a matching `photo_declutter_assessment_admissions` row exists. `photo.qc` is refused the same way.
2. **1.0.4 (build 74, live) cannot fund a trial purchase.** In ceiling mode it opens Apple's sheet without a hold, so `fund_reserved_subscription_trial` answers `trial_purchase_not_reserved` and `/me/entitlement` returns 503. This predates today. 1.0.5 approval fixes it for anyone who updates.
3. The legacy `trial_sponsor_pool` ends 2026-11-08. Sandbox trial grants for new non-sponsored accounts stop after 2026-11-01 00:00Z.
4. An intro-eligible Apple ID on a non-U.S. storefront can't subscribe; the region gate blocks it.
5. The owner's Mac internal disk is full (166 MB at 19:45Z). A 48 GB orphaned `~/Downloads/.git` from 2026-08-14 has no commits and no index.
6. Build 133 simulator check (`Claude outputs/build133/sim133.sh`): the first run failed only because the disk was full. Rerun it after freeing space.
