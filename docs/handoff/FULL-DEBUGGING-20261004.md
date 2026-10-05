# Full debugging — 4 October 2026

Four agents audited native capture/account/export behavior, Studio/public flows, subscription/backend behavior and listing synchronization. Work is isolated on `fix/full-debugging-20261004`, based on `f97e841`. Claude's shared checkout was not changed.

**This is a source remediation and verification report. The new changes have not been deployed or uploaded to Apple.** Existing internal TestFlight **1.0.4 (44)** remains the delivery recorded in `docs/releases/TESTFLIGHT-44-20261004.json`. Its original signed-source receipt remains unchanged.

## Reproduced problems and resulting behavior

| Problem | Result |
|---|---|
| A stale phone changes its cover/location and sends a full listing row, replacing newer office facts and attachments | Cover uses its dedicated operation. Ordinary facts carry only explicit changes and their original expected values. The database checks them atomically; a conflicting edit stays on the phone for review. |
| An edit form opened before a refresh saves all its old fields using a newer baseline | Only deliberately edited inputs are saved, using their opened baseline. Untouched price cents, area, headline, business fields and private attachments survive. Save also verifies account, session, workspace and listing binding. |
| A lost creation response can revive already saved intent or retry newer edits against pre-create values | Proven first-payload intent is retired. Only later phone edits remain, with the exact first payload as their expected base. Untouched office facts are adopted. An unprovable retry snapshot requires review. |
| SQL null, numeric/boolean details and timestamp microseconds are normalized away before conflict comparison | Expected values retain the raw server JSON types, key presence and timestamp string. Display formatting does not change the comparison baseline. |
| Older failures can mark a newly adopted shared version conflicted | Replies and errors verify the current queue's lineage, identity, workspace and listing binding. An old completion cannot revive a replaced queue. |
| A malformed successful response for another listing/workspace can clear intent and import unrelated facts | Facts and measurements replies must name the exact requested listing and organization before decoding into an accepted receipt. Synthetic wrong-target responses reproduced this path; there is no evidence of live server misrouting. |
| Contact/property input disappears when switching listings, pages or identities in Studio | Navigation asks before discarding edits; open-tab drafts are isolated by service instance, user, organization and listing. Old saves cannot clear newer drafts. Browser reload is not a durable draft backup. |
| Studio sends broad property/archive updates and cannot submit bathroom tenths | Studio uses the same atomic facts endpoint with explicit changes and raw expected values. Bathrooms accept tenths, including 2.3. |
| An Apple authorization code can be submitted under a later account, or an old success clears a newer code | Short-lived, bounded-attempt records are bound to the accepted Apple identity and exact session. Dispatch and acknowledgement verify that identity and the exact pending record. |
| Media/worksheet exports continue after account, workspace or listing replacement | Export admission, download completion, Photos permission and final completion verify the captured context. Already admitted Photos writes may complete; they are not falsely reported as cancelled. |
| Replaying an old signed purchase restores a refunded subscription or replaces a newer product | Verified purchase and signed-event chronology determine ordering. Reactivating the same refunded purchase requires an explicit newer outer `REFUND_REVERSED`. Expiry does not determine product order. |
| Revoking ordinary `UPDATE(details)` breaks Studio floor-plan attachment; a bare service-role replacement can bypass a later role/deletion change | A dedicated atomic RPC rechecks and locks actor, workspace, membership, listing and uploaded scoped asset, then compares the complete details snapshot and merges only the two attachment keys. |

Existing capture/storage, photo history, measurement geometry/recovery, gallery publication, upload, team/adoption/deletion, render, worker and public-tour regressions remain part of the full CI suite. Synthetic footage and source-bound tests establish software behavior, not real camera or generated-output quality.

## Verification and evidence

The accompanying `FULL-DEBUGGING-EVIDENCE-20261004.json` records final source hashes and the evidence boundary. CI results will be recorded after the isolated branch is committed and its complete twelve-job suite finishes. Individual fixtures execute actual Swift methods, complete Deno handlers, actual React browser workflows or real migrations against disposable socket-only PostgreSQL clusters. Deliberately removed guards must compile and fail at their named behavioral assertion.

The current beta-feedback read found **zero submitted screenshot or crash reports for build 44** at **03:14:07 UTC on 5 October**. That read does not establish the absence of unreported device crashes. The historical build-37 metadata stack overflow is distinct; current named SwiftUI components and the normal ARM64 Release build are checked separately.

Private local evidence remains under `/Users/pilksclaes/LocalRendpropAudits/full-debugging-20261004`. Customer screenshots, customer inventory, tokens, keys, signed media URLs and raw private Apple responses are not added to Git.

## Required rollout sequence

1. Review the atomic facts contract and establish a client upgrade boundary. The new legacy facts refusal is **426**; builds 42–44 still using broad ordinary PATCH writes cannot safely continue those writes after this cutover. Do not apply this package indiscriminately with a bulk migration push.
2. Apply the Apple **expand** migration `20261005024539_apple_entitlement_chronology.sql`. It preserves the deployed eleven-argument writer while adding the verified v2 writer. Unordered overlap invalidates its chronology; verified v2 writes restore verified watermarks.
3. Deploy and verify both updated `me` and `apple-subscriptions` handlers, and allow requests executing old handlers to drain. Old native restore HTTP bodies remain supported by the new handlers.
4. Apply Apple **contract** migration `20261005032635_apple_entitlement_legacy_cutover.sql`. Applying it before old handlers drain could acknowledge a refused refund into the notification dedupe ledger without enforcing the refund.
5. Coordinate `20261005024702_listing_facts_intent_cas.sql`, `20261005034754_studio_floorplan_attachment_cas.sql`, updated `listings`/`studio` functions, Studio assets and the matching new native build. Verify service-only grants, scoped requests, retained conflicts, attachment and same-account phone/office changes before broad team use. Preserve the deployed Topaz actual-output guard and existing budget fencing.

The two Apple migration phases are deliberately separated by a deployment and drain step. File ordering alone does not perform that step. Historical untracked subscription changes may remain `chronology_unavailable`; they need a trusted later event/purchase or reviewed reconciliation, not blind reactivation.

## Remaining acceptance

The source candidate is not a completed team-launch certification. Physical-phone camera/session/AR and room coverage, live phone-to-Studio synchronization, offer eligibility/purchase/restore, lead delivery and real provider output still require controlled acceptance. No customer rows, paid jobs, GPU runs, spatial flags, email deliveries, App Store submissions or Apple uploads were changed during this audit.

The existing owner-retained Astra answer-ceiling invariant remains intentionally red and is named explicitly by CI; unexpected failures still fail the suite. No allowance or price row was changed, and these checks do not certify actual provider invoices or the owner's 75% margin after Apple's fee. Coach/admin contracts deferred in the build-44 report remain deferred. Studio's open-tab draft recovery and its separate image-attachment workflow are also unchanged acceptance limits.
