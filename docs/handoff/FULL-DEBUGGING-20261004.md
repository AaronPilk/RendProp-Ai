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
| Contact/property input disappears when switching listings, pages or identities in Studio | Contact navigation asks before discarding edits. Ordinary property drafts survive navigation within the open tab; an active property save/reload blocks switching. Both draft stores are isolated by service instance, user, organization and listing. Old saves cannot clear newer drafts. Browser reload is not a durable draft backup. |
| Studio sends broad property/archive updates and cannot submit bathroom tenths | Studio uses the same atomic facts endpoint with explicit changes and raw expected values. Bathrooms accept tenths, including 2.3. |
| An Apple authorization code can be submitted under a later account, or an old success clears a newer code | Short-lived, bounded-attempt records are bound to the accepted Apple identity and exact session. Dispatch and acknowledgement verify that identity and the exact pending record. |
| Media/worksheet exports continue after account, workspace or listing replacement | Export admission, download completion, Photos permission and final completion verify the captured context. Already admitted Photos writes may complete; they are not falsely reported as cancelled. |
| Replaying an old signed purchase restores a refunded subscription or replaces a newer product | Verified purchase and signed-event chronology determine ordering. Reactivating the same refunded purchase requires an explicit newer outer `REFUND_REVERSED`. Expiry does not determine product order. |
| Revoking ordinary `UPDATE(details)` breaks Studio floor-plan attachment; a bare service-role replacement can bypass a later role/deletion change | A dedicated atomic RPC rechecks and locks actor, workspace, membership, listing and uploaded scoped asset, then compares the complete details snapshot and merges only the two attachment keys. |

Existing capture/storage, photo history, measurement geometry/recovery, gallery publication, upload, team/adoption/deletion, render, worker and public-tour regressions remain part of the full CI suite. Synthetic footage and source-bound tests establish software behavior, not real camera or generated-output quality.

## Verification and evidence

The accompanying `FULL-DEBUGGING-EVIDENCE-20261004.json` records final source hashes and the evidence boundary. CI results will be recorded after the isolated branch is committed and its complete twelve-job suite finishes. Individual fixtures execute actual Swift methods, complete Deno handlers, actual React browser workflows or real migrations against disposable socket-only PostgreSQL clusters. Altered-source fault controls must compile and fail at their named behavioral assertion.

| Focused check | Result |
|---|---|
| Native facts, actual client wire, review and reply binding | 65 assertions; four compiled fault controls |
| Native opened-form intent | 26 assertions; three compiled fault controls |
| Create/replay retirement and newer edits | 79 assertions across ten scenarios; three compiled fault controls |
| Apple identity-bound code | 27 assertions; four compiled fault controls |
| Native export context | 102 assertions; four compiled fault controls |
| Native shared-version review presentation | 27 assertions; two compiled fault controls |
| Final native measurement synchronization | 140 assertions; complete CI reruns all 21 compiled fault controls on the committed source |
| Studio | 441 unit tests; 10 connected facts, 16 property workflow, 9 contact navigation and 6 creation browser groups; meaningful navigation/facts controls |
| Full facts Deno handler | 66 assertions in a closed synthetic Auth/PostgREST transport |
| Ordinary facts SQL | 52 assertions on fresh/replayed schema, plus actual simultaneous same-field/disjoint-field clients |
| Apple subscription SQL/adapters | 39 chronology and 26 trial assertions on fresh/replayed schema; 69 offline signed-adapter tests, 12 concurrent receipt races and seven staged-rollout assertions |
| Floor-plan attachment | 25 real database assertions and 17 complete-handler tests, plus removed authority/comparison/client-boundary controls |
| Complete invariant inventory | 269 pass, one exact owner-retained Astra ceiling assertion remains red; all 270 rows, order and completion markers required |
| Final normal iPhone Release build | Unsigned `iphoneos` ARM64 build succeeded at 04:08:58 UTC on 5 October; every captured native/project input remained unchanged |

The first complete CI attempt exposed two obsolete fixture expectations, not a failed product comparison: the central runner still required 266 instead of 270 invariant rows, and a workspace test expected the older broad PATCH behavior. The inventory now requires all 270 rows without weakening names, order, completion or negative controls. The workspace fixture exercises scoped `PUT /facts` and separately verifies unsafe legacy writes receive 426 without changing either workspace. Its nine tests pass. The full corrected central database runner and all 37 mocked runner controls and nine registration checks passed locally.

The second attempt passed the complete 1,395-test edge suite and the central database checks, then exposed two further fixture expectations after ordinary authenticated column writes were revoked. The gallery fixture now changes its unrelated address through the scoped facts RPC and returns to the authenticated role for gallery permission checks. The measurement runner requires permission denial for a client trying to bypass its guard with a session variable, then verifies the accepted plan remained intact. Gallery checks, their fault controls and races, photographer/client delivery, and all twelve subsequent database/handler runners passed against a clean temporary source snapshot. Product grants and authorization controls were not relaxed.

The third attempt passed eleven jobs, but its fourth measurement control no longer produced a defect: deleting the direct replay-plan assignment was repaired by the independent facts acknowledgement path. The normal 140-assertion measurement run passed. The control now retains the stale pre-create typed plan at final replay persistence, across both legitimate adoption paths, and must fail at the original assertion that an unedited replay adopts the office plan. Runtime code and the expected rejection remain unchanged. The runner also verifies source and harness hashes at completion.

The fourth attempt passed every measurement control and the later export/contact steps, but the App Store isolation fixture inspected a background drain after a fixed 250 ms sleep. The actual drain waits for readiness and has a 20-second bound. A 400 ms asynchronous transport callback reproduced that premature observation at the exact assertion. The fixture now waits for actual OS completion with a three-second failure deadline, preserving every admission, journal, exactly-once and balanced-task assertion. Delayed positives pass; copied missing-completion and missing-end defects compile and fail at their named assertions. Production isolation/drain code is unchanged. All subsequent native source gates and the complete public/browser/encoding tail passed locally, including delayed observation and real encoded synthetic outputs. The independent CI artifact-collector change is recorded separately from the unchanged consumed media-test blocks.

Secret scanning also matched two source SHA-256 values next to paths containing Auth/API names. Both values were recomputed and matched their files. Current evidence separates path and hash fields; only the two exact historical commit/file/rule/line fingerprints are excluded. No key or credential was committed and broad secret scanning remains enabled.

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

The existing owner-retained Astra answer-ceiling invariant remains intentionally red and is named explicitly by CI; unexpected failures still fail the suite. No allowance or price row was changed, and these checks do not certify actual provider invoices or the owner's 75% margin after Apple's fee. Coach/admin contracts deferred in the build-44 report remain deferred. Studio accepts uploaded JPG/PNG/WebP floor-plan images; it does not edit native measurement geometry/worksheets or directly attach a PDF. Its draft recovery is limited to the open tab. Native forms' captured-context guards have executable-method coverage; the client contact sheet can refuse a stale-context Save without a displayed explanation, and that feedback path has no native tap-through acceptance.
