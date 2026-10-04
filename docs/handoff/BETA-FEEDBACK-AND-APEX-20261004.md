# Beta feedback and Apex measurement review — 4 October 2026

## Scope and delivery

Fresh TestFlight feedback was retrieved and reviewed in full. This follow-up
also studies Apex's published measurement workflow and fixes several concrete
native UI/reporting defects. Work is on isolated branch
`fix/beta-feedback-20261004`, based on `a8df47a` from
`feat/floor-plan-measurements-20261004`. Claude's checkout was not edited.
No Apple submission, subscription change, workspace deletion, feature enablement,
paid provider call, migration or backend deployment was performed here.

The earlier Measurements work is in draft PR 23. All 12 CI jobs passed on
`a8df47a`; it remains outside TestFlight build 43 and App Store build 42. A green
build is not real-phone AR/camera acceptance.

## Complete feedback inventory

The own-app, GET-only Apple snapshot finished at **2026-10-04 19:29:28 UTC**.
Both screenshot and crash feeds exhausted pagination and matched their reported
totals: **40 screenshot submissions / 41 images**, including **13 new build-43
submissions / 14 images**. All 39 nonempty written comments were read. The new
images were visually reviewed; the 27 earlier images were byte-identical to the
previous inventory, so prior visual reviews were retained. One build-37 crash
feedback submission is unchanged. This is available submitted feedback, not a
complete automatic-crash census.

Private evidence remains under
`/Users/pilksclaes/LocalRendpropAudits/beta-feedback-20261004/20261004T192917Z`.
The sanitized triage JSON SHA-256 is
`dd028a3aca7dbb7403a217477cd7354ba3c02c762ec20e62547c7beb00463af8`.
Tester identities, contact values, customer screenshots, raw crash logs and
signed download URLs are excluded from Git. The numbered rows below use that
private inventory's stable newest-first index.

### New build-43 submissions

| Index | Feedback | Disposition |
| --- | --- | --- |
| 0 | Show which photo is selected for the listing | Fixed in source on the reported listing file grid and the separate Photos libraries. Selection, Cover and saved-to-Photos state remain separate. The file viewer also passed a kind-prefixed row ID to an unprefixed saved-version action; corrected at that boundary. Closing Compare refreshes the relevant grid. |
| 1 | Make desktop Studio discoverable | Added a named Studio card in Settings and nonsample listing detail, with URL and the currently supported Apple-account/workspace instructions. Explicitly distinguishes uploaded media from phone-only files. Studio does not currently offer the native email-login path. |
| 2 | Why does auto-renewal show disabled? | Screenshot is the owner's aggregate churn notification report, not this person's subscription setting. A renewal-status notification does not establish entitlement termination or an app-induced billing defect. No renewal settings changed. Plain-language churn wording remains polish work. |
| 3 | Rename Homes to Listings and distinguish its icon | Real estate collection tab now says Listings with a list icon; agent collection title says My Listings. Photographer Client listings and other industry themes remain. |
| 4 | Why are there 31 empty workspaces? | Screenshot is the aggregate cohort exclusion count, not 31 duplicate picker entries. The predicate excludes every workspace with no listing, upload reservation or Apple subscription, including genuine people who never start. Native wording now states the recorded-work denominator and unused exclusions. Do not delete rows based on this count. The review also found and fixed silently zeroed 24-hour/seven-day activation counts caused by numeric-suffix decoder keys. |
| 5 | Investigate five crashes and 13 errors | Separate analytics source: 11 of 13 errors are ordinary launch metrics; two are old hangs. Three crash events were reported by build 37 with original diagnostic version lost; two build-37 diagnostics were delivered by build 40. This does not prove a build-43 crash. Routine MetricKit metrics now stop emitting errors; actual crash/hang/CPU/disk diagnostics are retained. Historical aggregate rows are unchanged. |
| 6 | Apple sign-in key should be active | Owner health checks a four-value server token-exchange/revocation bundle, while native Apple login uses a Supabase id-token exchange. A false bundle check cannot identify which value is missing or prove native login is disabled. Health copy now says setup incomplete without inventing a specific absent key. Actual sign-in acceptance remains separate. |
| 7 | Why is an optional provider off? | Optional configuration is not a shipped-generation entitlement. Existing Higgsfield generation remains intentionally disabled under the owner's enterprise/privacy condition. No optional provider was switched on. |
| 8 | FAL should be active | FAL is configured; No activity was a ledger lookback, not a disabled-key result. Health now distinguishes recent ledger activity from live credential/output verification. Older reel upstream failures remain separately unresolved. |
| 9 | Check keys; ElevenLabs diagnostic fails | The account endpoint returns structured missing-permission information, previously mislabeled wrong key. The narrow correction reports an unverified permission state and preserves real invalid-auth failures. It neither widens key scope nor proves TTS generation. |
| 10 | Clean up paywall UI | Open design work. Keep actual StoreKit prices, eligibility, trial/renewal disclosures and purchase-unavailable reasons; do not change pricing or allowances from this layout request. |
| 11 | Coach should know the account and explain Needs attention | Open implementation work. Backend drops 12 of 14 native screen names; no selected-project ID or safe attention reason is sent. Coach also omits the selected workspace header. Add bounded authorized context and deterministic recovery actions, not raw provider errors or cross-workspace records. |
| 12 | Add business logo and format phone entry | Open implementation work. Client cards already accept a client photo/business logo; the owner's profile needs a distinct hosted-logo path. Preserve international numbers while formatting domestic display and normalizing actual phone links. |

### All earlier submissions

These retain their existing release/source dispositions; they were not all
reimplemented or retested during this follow-up. See the linked prior reports
for verification limits.

| Index | Build | Feedback | Current disposition |
| --- | --- | --- | --- |
| 13 | 42 | Gallery sync warning explanation | Existing recovery/warning handling; actual-source gallery race checks in prior delivery. A visible warning is not proof that the selected photo reached the cloud. |
| 14 | 42 | Reel creation fails | Build 43 preserves completed clips and stops after failure. Read-only logs show 18 reel HTTP 502s and a Seedance failure streak in the reported interval. Instrumentation does not preserve the exact upstream status; cause/recovery remains unproven. |
| 15 | 40 | Edit listing facts and nearby attractions | Fact editing is implemented with prior UI tests. Nearby-attraction enrichment remains feature work. |
| 16 | 40 | Better centering, level and wide-angle photos | Existing guided lens/level capture corrections; photographic acceptance requires the physical phone. Perspective/composition enhancement is separate work. |
| 17 | 40 | Access declutter and staging separately | Build 43 retains distinct libraries and downloads; this branch adds selection visibility. |
| 18 | 40 | Preserve the decluttered result after staging | Same persistent history/base fix; predecessor files are retained. Do not reapply an older implementation that deletes them. |
| 19 | 40 | Table/wall altered by AI | Output quality remains unresolved; generation must preserve actual architecture and be reviewed. |
| 20 | 40 | Refrigerator moved | Same unresolved architecture/object-preservation concern. |
| 21 | 40 | Furniture differs between views | Cross-angle staging consistency remains unresolved. |
| 22 | 40 | Furniture blocks doorway | Placement/accessibility validation remains unresolved. |
| 23 | 40 | Window invented or altered | Architecture fidelity remains unresolved. |
| 24 | 40 | Editing artifacts | Quality evaluation and review remain required. |
| 25 | 40 | Edited photos unavailable | Existing saved history and explicit viewed-version exports address access; physical Files/Photos delivery still needs owner acceptance. |
| 26 | 40 | Explain one failed edit | Existing per-photo failures and retained completed outputs; no guarantee every provider attempt succeeds. |
| 27 | 40 | Declutter works well | Positive feedback retained; not a certification of every image. |
| 28 | 37 | Room-scan standing position | Existing handheld guidance changes; still physical-device beta acceptance. |
| 29 | 37 | Room-scan target/positioning confusion | Same open camera acceptance; spatial remains separate experimental scope. |
| 30 | 28 | Published fly-through dominates page | Existing listing-first page/modal/scroll-view changes; published-viewer checks are in prior delivery. |
| 31 | 27 | Landing page quality/navigation | Same page corrections and HD media work; no screenshot can certify all source/output resolution. |
| 32 | 27 | Enhancement takes too long | Existing background photo work/status and safe skipping; upstream speed/ETA is not guaranteed. |
| 33 | 27 | Show useful progress | Existing global completed-photo percentages; do not fabricate per-provider completion percentages. |
| 34 | 27 | Phone action opens email | Existing explicit phone/email actions; physical call/mail handling remains device acceptance. |
| 35 | 27 | Address suggestions | Autocomplete exists; live geocoder behavior is a separate acceptance check. |
| 36 | 27 | Require a listing/address before capture | Existing project-first gate; screenshot already showed disabled capture actions and guidance. |
| 37 | 24 | Invite code fails | Historical invite/adoption/race fixes; real team invitation acceptance remains separate. |
| 38 | 24 | Joining a team is hard to find | Existing workspace/join navigation improvements; retain team onboarding acceptance. |
| 39 | 24 | No written comment; invite error screenshot | No extra defect inferred beyond the historical invite state. |

Prior delivery context: [beta polish](BETA-POLISH-20261002.md),
[Bria/photo versions](BRIA-PHOTO-VERSIONS-BETA-20261002.md),
[crash hardening](IOS-CRASH-HARDENING-20261002.md), and
[October 3 reconciliation](CLAUDE-AUDIT-RECONCILIATION-20261003.md).

## Apex: what to take from it

Reviewed the official [Apex product page](https://apexappraisalsolutions.com/apexsketch/),
[help index](https://apexappraisalsolutions.com/av7-help/), and linked drawing
guides. This was documentation research, not hands-on Apex acceptance or watched
video playback. Some linked guides carry older version/copyright dates.

Apex's core workflow is **wall distance plus direction → a closed perimeter →
area classification and calculations**. It is not just a collection of room
rectangles. [Draw First](https://apexwin.com/support/ApexSketchv7/ApexSketchv7-DrawFirst.pdf)
documents perimeter entry, alignment, closure and area definition. Its
[angle guide](https://www.apexwin.com/support/ApexSketchv7/ApexSketchv7-DrawingAngles.pdf)
supports rise/run or length plus turn angle; its
[curve guide](https://www.apexwin.com/support/ApexSketchv7/ApexSketchv7-DrawingCurves.pdf)
and [subtraction guide](https://www.apexwin.com/support/ApexSketchv7/ApexSketchv7-DrawFirst-Auto-Subtract.pdf)
cover curved walls and open-below/negative areas. Area categories and calculation
breakdowns matter to a measurer, as do undo, reuse of another floor, labels,
doors/windows and print/PDF output.

Apex markets field/desktop workflows, offline use, Portal sync, and
[Leica DISTO Bluetooth connectivity](https://apexappraisalsolutions.com/fee-appraisers/).
No public API, geometry exchange contract or SDK specification was found in the
reviewed material. A brochure's conversion services do not establish a native
SHP/API export feature. Do not promise editable Apex import or generic Bluetooth
laser compatibility without a supported contract and real hardware tests.

The current Rendprop Measurements feature handles furnished homes through manual
room dimensions, optional approximate AR measurement, arranged rectangles and
image/PDF exports. **It does not author irregular closed perimeters or calculate
professional gross living area.** Room sums never change advertised square
footage. See [the current feature](FLOOR-MEASUREMENTS-20261004.md).

Recommended next measurement build:

1. Keep the simple room-dimension entry. Add a separate guided outline mode:
   enter successive wall lengths/directions, visible undo, snap and close-loop
   checks, with clear treatment of diagonal walls and room partitions.
2. Add a worksheet with floor/area categories, explicit included/excluded areas,
   source/units and calculation breakdown. Do not silently turn interior room
   totals into advertised living area or an appraisal measurement.
3. Edit the same geometry in Studio with deliberate phone/desktop revision
   conflict handling. Current whole-details writes lack that protection; native
   typed plans are retained by Studio but not editable there yet.
4. Keep authoritative Apex PDF/image attachment usable for the brother now.
   Explore direct interoperability or supported laser devices only after their
   contracts/hardware are available.

Professional reporting rules depend on property type and measurement basis;
the [Fannie Mae improvements guide](https://selling-guide.fanniemae.com/sel/b4-1.3-05/improvements-section-appraisal-report)
and [exhibit requirements](https://selling-guide.fanniemae.com/sel/b4-1.2-01/appraisal-report-forms-and-exhibits)
are reasons to preserve that distinction, not a claim that Rendprop is certified.

## Verification and remaining release work

Verification completed:

- Existing actual photo-history/export checks pass **340 assertions**.
- Actual cohort model/request decoder checks pass **40 assertions**; four
  independently compiled numeric-key regression controls are rejected.
- Actual backend probe suite passes **23 tests** with network/write/run denied;
  typed permission denial remains unverified and generic auth failure is unchanged.
- Actual Swift admin-state/CrashReporter checks pass **18 assertions**;
  removing permission mapping and restoring routine launch errors both compile
  and fail the intended runtime assertions. Actual diagnostic categories remain.
- The native Debug target compiles against the real iOS SDK. The focused
  synthetic UI case passes with **one test / zero failures** (143.7 seconds):
  retained declutter/staging exports and selections, visible Studio entry, the
  exact listing file-grid selection action, refresh, reopening, and distinct
  download accessibility labels. A reserved status line keeps thumbnail tops
  aligned. Screenshots and the accessibility hierarchy are retained privately.
- Backend typecheck/lint, runner syntax and diff checks pass. New offline checks
  are registered in the existing CI jobs.

The first UI attempt wrongly assumed a tab bar on the direct-detail fixture.
The next caught selection modifiers propagating onto the sibling download
buttons. The corrected flow passes; after the small row-alignment adjustment,
the full focused case passes again. Those failed logs are retained rather than
reported as successful runs. The fixture uses MockAPIClient and procedural
photos; it is not a physical-device, camera, actual Photos save or provider test.

The first PR-24 CI run (`37230943082`) passed 11 of 12 required jobs. Its
public-viewer check failed when returning from playback to Explore. The viewer
and harness were identical to the previous passing PR-23 run; the failure's
receipt did not retain timing values, so its exact cause cannot be recovered.
Investigation found a concrete test defect: the reference clock was sampled
before Playwright dispatched the click while the real video was advancing.
The check now samples in the click capture phase, before the production handler,
and deliberately advances playback by over 0.2 seconds before tapping. The
original 0.15-second tolerance, source retention, muted/paused controls and
accessible slider checks remain. No production viewer code changed.

The corrected loopback Chromium test passes **195 assertions**. Playback advanced
0.248406 seconds from the old sample but only 0.000329 seconds from the tap.
Two independent controls compile and reach the intended assertion after 85
earlier checks: restoring the stale sample fails even though the real handoff
is preserved within 0.000152 seconds; injecting a real rewind fails with a
4.288872-second position loss. Both have zero JavaScript errors. CI now requires
both controls to fail for that exact reason and retains their numeric handoff
receipts. This establishes the timing defect and continued rewind detection;
it does not retroactively prove the first CI failure had that specific cause.

New work is not automatically in a signed TestFlight build.
The permission classification needs an admin function deployment; native changes
need a signed build. The routine-metric correction does not rewrite historical
analytics or change the current aggregate RPC. No camera, laser, AR distance,
paid AI output, actual StoreKit purchase or real-account sync was tested here.

Next priorities from the reviewed feedback are Coach context/workspace parity,
clearer paywall selection, hosted logo/phone formatting, provider failure
observability and real AI architecture/consistency evaluation. Measurement outline
authoring is the next step for the brother's professional workflow; it should
not be represented as completed by the existing rectangular-room feature.
