# September 19 call-wave audit — NO-GO

**Do not merge `claude/call-fixes-20260917` at `7bcc624` into main.** The audited
range is `8d32f85..7bcc624`. The most serious counterexamples delete recorded
footage after a join reports success. This is the Task 1 answer, issued before
starting Task 2. Later repairs on `audit/call-fixes-20260919` do not change the
verdict on the original revision.

The complete handoff, call feedback and transcript were read before changes.
Work is isolated from Claude's checkout. No production data, route flags,
App Store Connect settings or customer media were changed during this audit.

## Findings ranked by user impact

| Priority | Finding | Execution and detail |
|---|---|---|
| P1 | Same-second segment/output filename alias causes cleanup to delete the entire joined take | [J1](CALL-20260919-JOIN.md#j1--p1-a-short-final-segment-makes-successful-cleanup-delete-the-joined-take): real AVFoundation export, allocator and caller cleanup |
| P1 | A failed input is silently omitted from a successful join, then every original is deleted | [J2](CALL-20260919-JOIN.md#j2--p1-an-unreadable-piece-becomes-silent-partial-success-then-all-original-pieces-are-deleted): real exporter with fault-injected unreadable input |
| P1 | Join failure exposes only the first piece; the remaining files have no durable recovery entry | J3: failure executed, missing recovery surface traced through actual persistence/UI |
| P2 | Resume silently does nothing when the camera session is stopped | L1 below: exact Swift function with controlled session/storage boundaries |
| P2 | Resume near ten minutes permits a take the app then rejects as too long | L2 below: exact cap/import functions plus real 600.75-second joined MOV |
| P2 | Record remains enabled during joining and clears the previous take's tags | J4: actual predicates/action/finish handler |
| P2 | Save/relaunch drops detected-person ranges | J5: actual PersistentStore round trip |
| P2 | Finalization can erase eight seconds of detected presence; padding overruns the file; thermal skipping keeps stale presence alive | [T1–T3](CALL-20260919-TIMING.md): extracted real functions and controlled callback traces |
| P2 | Returning to Start with photos discards corrected listing fields | L3 below: exact transition with in-memory model boundary |
| P2 | Mobile comparison hides 43.75% of a landscape photo; its ARIA text reverses original/edited visibility | [WEB-01/02](CALL-20260919-WEB.md): actual rendered Chromium, keyboard and geometry |
| P3 | Motion timestamps drift around pause, can go backwards, and continue past the movie during joining | T4: actual recorder and written sidecar; currently write-only, no current video-loss claim |

The prompt polisher's missing output fair-housing check was also executed on
both baseline and tip. It is a **pre-existing** defect, not attributed to these
waves; the later custom-edit input gate still rejects that text (WEB-03).

## L1 — stopped-session Resume has no feedback

`CameraManager.resumeRecording()` guards `session.isRunning` and returns before
setting any message or warning. A paused take with a stopped session remains
paused, makes zero recording-start calls, and shows no new feedback. The same
harness's low-storage control does set a warning. This proves the method's
behavior, not a particular phone-call notification ordering on hardware.

## L2 — cap rounding makes a valid capture unusable

`remainingSeconds = max(1, 600 - bankedSeconds)` allows a full additional second
when only a fraction remains. At 599.25, 599.75 and 600 banked seconds, the actual
functions permit totals of 600.25, 600.75 and 601 seconds; actual
`MediaImporter.validate` rejects each with `tooLong`. The join audit separately
exported a real 600.75-second MOV from 599.75 + 1 second pieces. This can block
Use this take after the user finishes filming. Correct the recording budget;
do not hide the defect by truncating footage during joining.

## L3 — photos-first re-entry discards form corrections

`NewListingView.startWithPhotos()`'s first reuse branch returns the stale
`photosListing` without applying the form, unlike its `createdListing` branch.
The executed sequence creates 100 Original Avenue, goes back, changes to
200 Corrected Avenue with a new coordinate, then presses Start with photos.
The stored and destination address remain 100 Original Avenue. The same check
confirms an empty form cannot create a listing and repeated taps do not duplicate
one. SwiftUI navigation itself is not simulated by this method-level check.

## Reproducers and evidence

Run the Python/Node commands documented in the three linked component reports.
Root lifecycle commands:

```sh
python3 tools/audit/call-20260919/lifecycle/run.py --revision 7bcc624
python3 tools/audit/call-20260919/lifecycle/photos_first.py --revision 7bcc624
```

Baseline lifecycle evidence: `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-call-lifecycle-fmojn9lc/receipt.json`.
Photos evidence: `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-call-photos-first-0x_knh75/receipt.json`.
Component reports carry source hashes and their evidence locations. These
baseline checks confirm defects; they are not fixed-product acceptance tests.

## Verification completed and still open

- Native iOS simulator build: **BUILD SUCCEEDED**, exit 0. Build log:
  `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-call-audit-build-jtu8ro9s/build.log`.
- Tour TypeScript passes; all seven gates pass **2,698 assertions**:
  693 unbranded, 692 routes, 707 upstream, 418 lead, 57 legal, 103 spatial, 28 bundle.
- Photo handler: **273 offline audit assertions**, 36 edit/space dispatches;
  shared Deno tests **46 pass**, ai-photo typecheck passes.
- Browser: **14 checks**, including confirmations of the two defects, a real
  410-second synthetic video, touch scrolling, and the no-JS fallback.
- Real AVFoundation join cases: seven; native persistence round trip passes as
  a defect reproducer. Timing harness and native TSAN complete; no race reported
  with the real `@Published` wrapper.

**Not completed:** real ten-minute 4K thermal/battery testing, physical iPhone
interruption/lens/format validation, and real model before/after comparisons
for CONDITION_LOCK. Prompt assembly tests do not prove image quality. Different
dimensions alone successfully exported in the join experiment; mismatch failure
is not a proven finding. The detailed reports distinguish other asynchronous
ordering hypotheses from executable findings.

Repairs and Task 2 must retain these limits in their acceptance report. Nothing
here authorizes merging the original revision merely because its builds pass.
