# App Store listing and review assets

**27 October 2026 candidate:** The current 1.0.5 release source has a new
Aerial intro route available to eligible paid accounts with aerial allowance.
The older generic aerial endpoint remains private beta. Physical aerial
quality acceptance is still open. It also has photo-based Listing videos,
optional recorded walkthroughs, and
one draft listing with limited photo edits during an eligible 7-day Apple
trial. New video/aerial generation and website publication require paid
access. Floor plans, measurements and 3D tours remain outside the standard
release. The local metadata and [review notes](review-notes.md) distinguish
the two aerial routes; they are not proof of TestFlight delivery,
device acceptance or App Store submission. The dated material below is
historical and must not be used as the current release checklist.

**October 16 working state:** the last verified public version is 1.0.4 (74),
and internal TestFlight 1.0.5 (87) is available. The next photo-first candidate
and Kie permission integration are unfinished; no new App Store submission or
release is authorized. Use the [current local workflow draft](photo-first-review-draft-20261016.md)
and the [owner checklist](../handoff/OWNER-REQUEST-CHECKLIST-20261014.md).
The dates and build claims below are historical. The machine-uploaded metadata
has not been replaced by this draft and must be reconciled with the accepted
binary before any future upload.

This directory contains the listing copy, review notes and screenshot recipes.
Reconciled on 2 October 2026 for the regular 1.0.3 App Store release.
**6 October delivery:** internal TestFlight **1.0.4 (46)** is available to the
existing internal group, verified by Apple on 7 October at 00:47:51 UTC (6 October
locally). See [its delivery record](../releases/TESTFLIGHT-46-20261006.json) and
[the dormant trial rollout](../handoff/TESTFLIGHT-46-AND-DORMANT-TRIAL-ROLLOUT-20261006.md).
No newer public version was submitted. Trial code is included in build 46 and
source-verified in the backend/Studio, but funding/configuration remain disabled.
New paid checkout is closed in build 46; the old public build 42 lacks that new
purchase guard. Paid photo bundles, protected media and physical acceptance still
have unresolved launch gates. Do not submit another release from these notes alone.

**1.0.3 (42) was submitted at 20:17:03 UTC on 2 October and was then Waiting for Review.** Apple
confirmed the exact version, attached eligible build and one submitted review
item. Release is automatic after approval; this is not an approval or public
availability claim. The [App Store release receipt](../releases/APPSTORE-42-20261002.json)
binds runtime source `204594a`, all twelve CI jobs, the actual uploaded IPA,
metadata, five screenshots and the review readback.

For experimental spatial testing, the phone delivery receipt records
[internal TestFlight 1.0.3 (41), available on 2 October](../releases/TESTFLIGHT-41-20261002.json).
This is the historical build-41 record, superseded for internal testing by 46.
The owner authorized that upload and its build-specific testing notes. Apple
confirmed availability to the existing internal group. This did not attach a
build to an App Store version or submit an App Review. Physical-phone capture
and reconstruction quality remain unverified; TestFlight availability is not
evidence that every feature is ready for public release.

| Path | Purpose |
| --- | --- |
| [metadata/en-US/](metadata/en-US/) | Per-field text consumed by the release tooling; inspect it against the exact binary before applying. |
| [review-notes.md](review-notes.md) | Human-readable App Review instructions and context. |
| [metadata/en-US/review_notes.txt](metadata/en-US/review_notes.txt) | Machine-uploaded notes; `asc.py` skips the field when this file is absent. Keep it aligned with the separate Markdown guidance. |
| [privacy-labels.md](privacy-labels.md) | App Privacy questionnaire guidance; reconcile with actual collection and provider behavior for each release. |
| [age-rating.md](age-rating.md) | Age-rating answer guidance. |
| [screenshots/README.md](screenshots/README.md) | Five representative native 6.9-inch frames for 1.0.3, raw capture and composition. |
| [iap-review/README.md](iap-review/README.md) | Local StoreKit paywall capture and its real-device verification limits. |
| [ASC-API-PLAN.md](ASC-API-PLAN.md) | Historical launch automation plan. Current tooling caveats are in [tools/asc](../../tools/asc/README.md). |
| [APP-STORE-CHECKLIST.md](../APP-STORE-CHECKLIST.md) | Broader release checklist; use dated delivery evidence to distinguish completed work from old launch assumptions. |

## Metadata measurements

Measured from the local 28 October 2026 source draft after trimming trailing
newlines, matching the tool's inputs. These counts do not imply an ASC upload:

| Field | Characters | UTF-8 bytes | Tool limit |
| --- | ---: | ---: | --- |
| `name.txt` | 8 | 8 | 30 characters |
| `subtitle.txt` | 29 | 29 | 30 characters |
| `promotional_text.txt` | 153 | 153 | 170 characters |
| `keywords.txt` | 96 | 96 | 100 bytes |
| `description.txt` | 3720 | 3720 | 4000 characters |
| `description_team_seats.txt` | 3903 | 3905 | 4000 characters; selected only by `catalog_copy.py --include-team-seats`, not by `asc.py metadata` |
| `release_notes.txt` | 709 | 709 | 4000 characters |
| `review_notes.txt` | 3533 | 3535 | 4000 characters |
| `review_notes_team_seats.txt` | 3773 | 3775 | 4000 characters; selected only with `review --include-team-seats` or `catalog_copy.py --include-team-seats` |

Re-measure after editing; old counts are not a validation result for new
text. The tool checks limits before sending fields.

Current source truth: Measurements, floor plans and 3D tours are
Coming soon cards on Home and in each listing's toolbox. They open nothing and
no plan includes them, so the description, review notes and keywords no longer
describe measurement entry, plan import or RoomPlan/LiDAR scanning. Do not
reintroduce those claims until a signed build re-enables the tool.

## Keep listing claims consistent with the product

- The source catalog in [Products.swift](../../apps/ios/Rendprop/Purchases/Products.swift)
  defines Pro, Max, Ultra and three-seat Team at 60, 120, 250 and 600 monthly
  credits. These are post-trial targets; confirm the funded server grant and
  exact StoreKit product before claiming a paid allowance on a device.
- The base app asks StoreKit for four monthly subscriptions. Annual products
  and Team 4–9 variants are dormant in this source; a separate paid-Team-owner
  activation is required for the seat variants. Team's current ASC price was
  $249.00 at the 28 October readback, with $249.99 scheduled for 30 October.
  Rely on Apple's localized `Product.displayPrice` for the amount charged.
- The $39.99 U.S. 100-credit consumable and $25 U.S. per-property luxury
  website consumable are prepared in ASC but their production gates were off
  at the 28 October readback. The candidate description and review notes state
  those conditions; [submission readiness](submission-metadata-readiness-20261028.md)
  tracks what must be verified before either purchase is advertised as live.
- Named-account continuity requires the same account and workspace and completed
  uploads. Do not turn offline capture or anonymous-session support into a claim
  that unsynced local files automatically appear on another device.
- Desktop chat editing and guided **Improve prompt** are live. Optional
  model-powered planning/enhancement and Higgsfield Presenter generation remain
  disabled in the 24 September release. Do not advertise disabled generation as
  a shipping phone feature.
- Keep property marketing focused on the space and product behavior; do not add
  demographic, school or neighborhood suitability claims.
- The regular App Store scheme excludes spatial entry points and new spatial
  uploads even when the server capability flag is enabled. The explicit lab
  scheme remains available in internal TestFlight 46. Neither is a claim that
  physical capture or reconstruction quality passed.
- AI consent revocation stops the remaining unsent photo batch. A revoke/regrant
  does not revive the old batch; already dispatched results may still arrive.
- App Privacy now includes Audio Data for app functionality, linked to identity,
  without tracking. Apple computed 12+ after declaring user-generated content
  and infrequent alcohol references in the business templates.

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
release target before using that tooling. The dated delivery receipt records the
completed exact-version submission; do not rerun the legacy apply bridge.
