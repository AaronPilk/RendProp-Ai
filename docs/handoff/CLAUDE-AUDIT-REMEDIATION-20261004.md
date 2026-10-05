# Claude audit remediation — 4 October 2026

Source fixes on isolated branch `fix/claude-audit-20261004`, based on
`576d532be2daa94dc2c8446fc66611fb4b2952be` and stacked on the irregular-outline
feature. The supplied audit was read in full and checked against actual source,
read-only production data and the owner's FAL dashboard. No production schema,
function, subscription configuration, camera, paid generation, Apple submission
or shared branch was changed by this work. These fixes need delivery.

## Confirmed issues and final behavior

| Audit item | Source fix and practical result |
|---|---|
| P0-1: definite video refusal consumes budget/allowance | A proven refusal without a receipt releases its durable hold before allowance refund. Timeout, 5xx, ambiguous acceptance and unavailable release remain fenced; no second provider POST occurs. Rejection tombstones retain the submission key. |
| P0-2: every room save replaces listing facts | New service-only measurements CAS writes only the private plan. One concurrent writer wins; the other keeps its local geometry and receives a conflict. Square footage, price, sold/archived state and Studio attachment remain untouched. |
| P0-3: older clients rename/private plans vanish or leak | Unambiguous snake/camel aliases are recovered. A database trigger protects private keys from ordinary updates. Public filtering covers snake/camel/future variants in branded, unbranded and embedded responses. Conflicting/unknown values remain private and uneditable. |
| P0-4: first history operation excludes older gallery photos | Existing photo siblings are reconciled before first capture, edit, removal or publication. Untouched legacy siblings stay selected; a corrupt index or missing selected bytes cannot silently clear the server gallery. Legacy filenames do not certify source authenticity. |
| Cover/review/badges | Cover comes from the approved selection; staging requires explicit review at both selection entry points. A compare presentation carries photo and cover intent together. File-grid badges describe the family's selected earlier version even when its latest version differs. Missing one file does not blank all badges. |
| Coach address and workspace leak | Offline replies omit full addresses; transmitted history excludes local fallback messages and redacts retained legacy addresses. Requests capture owner/session/workspace and send the exact org header. Backend schema accepts the 14 actual native screens and preserves their scope. |
| Failed FAL status looks processing/502 | Both polling paths recognize completed-with-error and failed result retrieval as terminal failure. Logs retain bounded provider status/class without raw bodies, prompts, keys or signed URLs. Catalog authentication explicitly leaves generation unverified. |
| Export sources/freshness/layout | Images/PDFs include per-area entered/phone source, UTC plan date, calculated-edge labels and schematic/not-to-scale/not-survey text. Phone-source floors explicitly describe the straight 3D ruler and matching endpoint height for horizontal lengths. PDFs use US Letter landscape with one centered transform. All rooms get a dimension/source record, including when outlines define area. Sharing rechecks immutable geometry, provenance, address, binding, session, conflict and older-facts review. Worksheet rows paginate and separate wrapped names from source labels. |
| Remaining UI/source issues | Photo badges are named SwiftUI components; real-estate UI walks target Listings. Decimal feet are explained. The legacy convex-hull total is labeled Scan hull estimate with its limitation on the export. |

The independent native review also found three additional data-loss paths and
reproduced them before the final fixes:

1. **Lost create receipt plus measurement-only edit:** the old generic dirty
   flag caused a stale full-row PATCH after a successful measurement write.
   First create now persists a separate fingerprint of ordinary facts. A
   geometry-only retry adopts office facts and retains its independent CAS queue.
2. **Upgrade of pending typed geometry:** a generic PATCH excluded measurement
   keys, cleared dirty and allowed a refresh to erase the unsent plan. The
   actual decoder, sync and merge recover a persisted CAS queue first. Older
   ordinary intent that cannot be proven stays local behind an explicit review
   choice. Arbitrary photo edits or loading only shared measurements do not
   approve ordinary replacement. Shared-detail choice keeps a local measurement
   backup; keep-iPhone-details choice confirms the ordinary replacement.
3. **Repeated shared loads replaced the backup:** loading shared measurements,
   then choosing shared listing details copied the already adopted shared plan
   over the phone backup. Sequential loads now retain that backup when the
   typed plan and cached raw value still match the shared baseline. New pending
   local geometry can replace it; shared absence cannot erase it. Actual-method
   coverage includes both choices, noncanonical JSON, an absent shared plan,
   restoring through CAS and deliberately empty local geometry.

Successful and conflicting late replies also verify the current queue's base,
pending state, binding and workspace. A shared reload during an in-flight save
cannot have its replacement queue revived by the old reply.

## FAL: evidence, not a root-cause claim

Production health metadata recorded 28 failures, the last recorded success on
7 September and last failure on 2 October. That does not establish uninterrupted
failure for 27 days or prove an exhausted/locked account.

The read-only dashboard check showed **$25 current credits**. The available
30-day Errors view showed two Topaz 503 rows and one Flux 422 row, and no Seedance
row. September usage was $22.16, including $19.36 Topaz and $2.80 Seedance. This
is a limited account/dashboard observation; no historical lock evidence or
identity match to the deployed secret was established. No key was read.

Actual Seedance durations, resolution and aerial options agree with the current
[official endpoint schema](https://fal.ai/models/fal-ai/bytedance/seedance/v1/pro/fast/image-to-video/api).
The original fast rejection cause remains unknown. **Real generation needs a
controlled paid canary and an output review before it can be called working.**
Catalog success, mocked adapter tests and an account balance cannot replace it.

## Verification

Results use synthetic media and owned disposable databases. Their scope is
software behavior; they do not certify camera accuracy or AI video quality.

| Check | Actual result |
|---|---|
| Complete edge-function suite | 1,389 passed, 0 failed, 1 database-dependent test ignored in that invocation |
| Separately run ignored presenter controller | 119 SQL checks plus actual controller lifecycle test: 1 passed, 0 failed |
| Photo history and actual publication bodies | 389 model assertions and 77 real gallery/publisher assertions; four compiled fault controls |
| Native photo workflows | 2 passed: legacy siblings/cover/review/removal and saved declutter/staging libraries |
| Final native measurement sync/recovery methods | 139 assertions and 21 compiled fault controls: actual wire, decoder, create replay, CAS, reload, explicit review, refresh, late replies, repeated shared-load backups and adoption |
| Measurement geometry/model | 628 assertions; exact dimensions, polygon areas, deductions, unit conversion, validation and wire persistence |
| Coach native behavior | 37 offline reply and 32 privacy/scope assertions; four compiled fault controls |
| Measurements database | 44 assertions on fresh apply and replay; actual two-writer race; removed-precondition and removed-lock controls caught |
| Video budget database | 34 rejection assertions and 101 preserved ordinary-video assertions on fresh apply/replay; 51 reflection and 37 direct-Bria assertions; shared-ceiling races, eight settlers/one receipt and removed-lock control |
| Export admission and actual PDF loops | 71 assertions and eight compiled controls; Letter page bounds, per-page transforms, conditional 3D ruler wording and six valid 40-character names/pagination tested at draw-position level |
| Photos-save export safety | 18 assertions and three compiled controls |
| Native measurements UI | L outline and rectangle flows: 2 passed; prior exporter L rerun: 1 passed; final Letter exporter L rerun: 1 passed. All four final pages visually inspected with correct 792 × 612-point paper, sources, date and 15 m² net area. |
| Final normal iPhone Release build | Unsigned `iphoneos` arm64 build succeeded with final recovery and late-reply guards; no upload/signing |
| Web capability inventory and brand tokens | 17 checks passed with the dedicated measurements route mapped; missing-upload, low-contrast and disabled-validator controls each failed as required. Inventory coverage does not establish browser/device parity. |
| Published-listing browser proof | 195 checks passed normally and with a deterministic 350 ms observer delay. Missing chapter seek, stale Explore reference and actual rewind each failed at their exact intended assertion; the extracted CI wrapper accepted all three controls. |

The L test verifies 16 m² gross, a 1 m² opening and 15 m² net, a marked calculated
closing wall, actual export/3D/reopen and linked deletion without resurrection.
The rectangle test checks overlap rejection, unit conversion and dimensions.
The final Letter run compiled the current source but did not exercise the
conditional older-snapshot review choice or phone-source warning rendering;
those branches have actual-method/source-bound tests and the final Release
compile, not a native tap-through. Maximum-length pagination has source-loop
proof, not extreme-name UIKit glyph rasterization. Normal final PDF pages were
inspected. Initial final-build/installation attempts hit disk exhaustion; failed
logs were retained and only the successful retries count as acceptance.

The final CI run at `96a4e2e` passed eleven jobs but missed the brief chapter-seek
polling window while normal video playback advanced. A 350 ms test-observer
delay reproduced the same failure without changing the page or decoder. The
browser check now records the exact seek event, actual decoded frame and pixels
from observers registered before the production click handler. It retains the
seek precision, frame bounds, pixel threshold and bounded stall rejection;
CI includes the delayed positive and a missing-seek fault. No product code or
timeout was changed for that correction. The final delivery receipt must bind
the subsequent commit and complete CI result before this branch is called
verified.

Source hashes and verification artifacts are indexed in
[`CLAUDE-AUDIT-EVIDENCE-20261004.json`](CLAUDE-AUDIT-EVIDENCE-20261004.json).
The provider detail is in
[`PROVIDER-DISPATCH-REJECTION-20261004.md`](PROVIDER-DISPATCH-REJECTION-20261004.md).

## Delivery and remaining limits

Apply these new migrations before replacing their matching functions:

- `20261004215403_app_video_rejected_submission_release.sql` → `ai-video`.
- `20261004220253_listing_measurement_compare_and_set.sql` → `listings`.

Deploy the corresponding `tours`, `coach` and `admin` source changes and deliver
a new signed iPhone build before claiming the fixes are available to users.
The new Coach contract requires a captured `X-Org-Id`; older native clients
without that header receive a 409 and use their local fallback. Coordinate
that function rollout with the updated binary; do not present it as a
transparent server-only upgrade for old clients.
Read back deployed hashes, grants and schema; exercise same-account phone/Studio
and two-writer conflict resolution against the deployed version. Read-only
production preflight found no measurement-namespace rows and no oversized
details rows; it was not a migration application.

This branch contains live Topaz guard `0b4a87b`. Any later function deployment
must preserve its actual-output probe and 16¢/second worst-case hold. Do not
deploy older shared branches that lack that guard. No existing migration was
rewritten and Claude's shared checkout was not edited.

**Shared-team launch remains blocked by ordinary listing writes.** A stale phone
choosing a main photo or saving coordinates can still issue a full-row update
and overwrite newer, unedited Studio facts, sold/archive state and floor-plan
attachments. This path was verified in the current source; no corresponding
production or physical-phone mutation was performed. Measurement saves are
protected, but this branch does not fix the ordinary path. The next delivery
needs explicit changed-field intent, atomic conflict protection, retained local
conflicts and a safe rejection/upgrade boundary for older builds 42/43.
Studio does not yet edit raw measurement geometry; exporting and attaching a
plan image remain separate workflows. Imported edited cloud photos need a
verified server provenance binding before edited bytes can be republished.
Removing a family from an imported listing hides it on that iPhone; the additive
cloud-gallery path preserves already published photos. Its confirmation now
states that distinction rather than promising a public deletion.

Allowance refund after a definite rejection is best effort, ordered after the
durable release but not atomically coupled to it. Uncertain historical jobs and
failed counter refunds require operational reconciliation. Accepted jobs that
later fail are not automatically free. Prices, feature quantities and the 75%
margin policy were not changed or re-certified by this audit.

The dormant Python render worker remains dormant. Its activation/cost path was
not rebuilt. The phone ruler remains a straight 3D point-to-point estimate;
exports now state that source and limitation. Spatial flags, GPU runs, camera
capture and Apple submission were left untouched.
