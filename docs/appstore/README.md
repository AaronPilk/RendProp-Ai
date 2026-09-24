# App Store listing and review assets

This directory contains the listing copy, review notes and screenshot recipes.
Its launch material began on 5 September 2026; README guidance was reconciled
with repository source on 24 September. These files are inputs to an owner-run
release, not proof of what App Store Connect currently displays.

The latest committed phone delivery receipt records
[internal TestFlight 1.0.3 (31) on 22 September](../handoff/CLAUDE-LIVE-DELIVERY-20260922.md).
The [24 September production release](../handoff/CODEX-STUDIO-LIVE-20260924.md)
updated Studio/backend only. App Store Connect was not accessed during this
README refresh, and new phone capture-plan/multi-video features must not be
advertised as delivered solely because their backend is live.

| Path | Purpose |
| --- | --- |
| [metadata/en-US/](metadata/en-US/) | Per-field text consumed by the release tooling; inspect it against the exact binary before applying. |
| [review-notes.md](review-notes.md) | Human-readable App Review instructions and context. |
| [metadata/en-US/review_notes.txt](metadata/en-US/review_notes.txt) | Machine-uploaded notes; `asc.py` skips the field when this file is absent. Keep it aligned with the separate Markdown guidance. |
| [privacy-labels.md](privacy-labels.md) | App Privacy questionnaire guidance; reconcile with actual collection and provider behavior for each release. |
| [age-rating.md](age-rating.md) | Age-rating answer guidance. |
| [screenshots/README.md](screenshots/README.md) | Nine-frame 6.9-inch plan, raw capture, composition and owner-run upload. |
| [iap-review/README.md](iap-review/README.md) | Local StoreKit paywall capture and its real-device verification limits. |
| [ASC-API-PLAN.md](ASC-API-PLAN.md) | Historical launch automation plan. Current tooling caveats are in [tools/asc](../../tools/asc/README.md). |
| [APP-STORE-CHECKLIST.md](../APP-STORE-CHECKLIST.md) | Broader release checklist; use dated delivery evidence to distinguish completed work from old launch assumptions. |

## Metadata measurements

Measured from the committed files on 24 September 2026 after trimming outer
whitespace, matching the tool's inputs:

| Field | Characters | UTF-8 bytes | Tool limit |
| --- | ---: | ---: | --- |
| `name.txt` | 8 | 8 | 30 characters |
| `subtitle.txt` | 29 | 29 | 30 characters |
| `promotional_text.txt` | 162 | 164 | 170 characters |
| `keywords.txt` | 94 | 94 | 100 bytes |
| `description.txt` | 3730 | 3802 | 4000 characters |
| `release_notes.txt` | 380 | 382 | 4000 characters |
| `review_notes.txt` | 3974 | 3976 | 4000 characters |

The review notes have only 26 characters of headroom. Re-measure after editing;
old counts are not a validation result for new text. The tool checks limits
before sending fields.

## Keep listing claims consistent with the product

- The repository's Starter/Pro/Team allowances in
  [Products.swift](../../apps/ios/Rendprop/Purchases/Products.swift) are respectively
  **4/100/6/2**, **10/200/12/4** and **25/400/25/8** for monthly tour renders,
  AI photo edits, reel clips and aerial intros. Team has two seats. These match
  the current description; verify live `plan_entitlements` when changing plans.
- The five displayed subscription prices in the description and local StoreKit
  fixture are Starter $49/month or $490/year, Pro $99/month or $990/year and
  Team $249/month. The app excludes Team Yearly via `notSoldAtLaunch`.
  A local fixture is not a fresh read of store availability or regional prices.
- Named-account continuity requires the same account and workspace and completed
  uploads. Do not turn offline capture or anonymous-session support into a claim
  that unsynced local files automatically appear on another device.
- Desktop chat editing and guided **Improve prompt** are live. Optional
  model-powered planning/enhancement and Higgsfield Presenter generation remain
  disabled in the 24 September release. Do not advertise disabled generation as
  a shipping phone feature.
- Keep property marketing focused on the space and product behavior; do not add
  demographic, school or neighborhood suitability claims.

## Older launch notes that are no longer current

The marketing source now calls the $49 plan **Starter**; the old “Solo” naming
blocker in this README was fixed. Analytics retention scheduling is implemented
by [0022_app_events_purge_schedule.sql](../../services/supabase/migrations/0022_app_events_purge_schedule.sql),
with an explicit fallback when `pg_cron` is unavailable. Check deployed schedule
and job history when verifying retention; do not infer operation merely from
having the migration file.

`tools/asc/asc.py` still has a launch-era `VERSION_STRING = "1.0"`, may select
another editable version, and has no `--version` override. Its apply bridge also
changes prices, territories, screenshots and review state. Reconcile the exact
release target before using that tooling; this documentation refresh does not
submit or alter the listing.
