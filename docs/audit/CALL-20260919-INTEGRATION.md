# September 19 integration — release remains NO-GO

The original Claude revision `7bcc624` must not merge unchanged. Its executable
footage-loss findings are in [the Task 1 verdict](CALL-20260919-VERDICT.md).
Candidate repairs and opt-in reflection removal are isolated on
`audit/call-fixes-20260919`, based on that Claude revision. Spatial remains off;
App Store Connect and production databases/services were not changed.

The review is [draft PR #1](https://github.com/AaronPilk/RendProp-Ai/pull/1),
targeting Claude's branch. The two highest-impact executed failures were a
same-second filename collision that deleted the joined take, and a join that
silently skipped an unreadable piece before deleting all originals. Both have
regressions and candidate fixes; the original revision remains NO-GO.

## What the candidate changes

Capture now keeps every original segment, journals complete takes for recovery,
rejects partial joins, blocks new recording while joining, and restores detected
person ranges after relaunch. Timing uses joined segment durations; Resume gives
feedback when the camera is unavailable, and the recording budget stays within
ten minutes. Photos-first re-entry applies corrected form fields. Tour photo
comparison shows complete frames and reports the correct original/edited split.
The photo prompt polisher also checks its generated text server-side.

Photo fallback now requires an already-enabled, eligible route. Migration 0056
marks those existing active rows without changing any model, price, enabled flag
or disabled row. Invalid edit names are rejected before quota use; missing photo
authorization fails closed and refunds both quota meters. The inherited edit-name
bypass was independently reproduced on the original revision as well.

Reflection removal is optional on the review screen. The user selects detected
intervals, sees selected seconds and plan allowance, and compares the generated
video with the original before accepting. Each local clip is at most 4.8 seconds.
The complete original remains saved independently. Extraction and splicing use
an explicit SDR BT.709 policy; original HDR files remain unchanged and original
audio stays on its original timeline.

Durable server jobs bind one submission to each saved clip UUID. SQL transactions
reserve the reel allowance and the batch budget together. Retries retrieve the
same job; uncertain provider submissions are not automatically repeated.
Failure/cancellation refunds the exact charged quota window once. Confirmed
provider costs remain recorded after cancellation; ambiguous provider costs
remain held for reconciliation. Definite pre-queue rejections release that hold.

Acceptance requires the completed batch and distinct complete original/edited
video assets, then writes one immutable linked video provenance row. The public
tour shows both videos with a reflection-removal disclosure. The acceptance UI
states that both videos are saved online and anyone with the original's link can
view it. This is not a private cloud backup.

This handoff implements the native review workflow and public disclosure.
The browser interval editor and cross-device recovery of unfinished edits remain
marked **planned** in the client capability inventory; this report does not
claim full Studio parity.

## Completed evidence

- Full simulator app build: **BUILD SUCCEEDED**, exit 0, at
  `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-call-final-build-szmyxa7x/build.log`.
- Final focused recovery UI test: **one test, zero failures**, 169.479 seconds,
  after a successful full build-for-testing. With camera access denied, it proves
  relaunch, retry, playable review, enabled Use this take, and system export
  sheets for the exact legacy file and second segment. No external save or
  recipient was selected. Evidence: `/tmp/rendprop-recovery-ui-final.xcresult`.
- Capture native checks: **33 join/recovery assertions and 9 persistence
  assertions**. The original defect reproducers still run separately against
  `7bcc624`. See [capture evidence](CALL-20260919-JOIN-REPAIR.md).
- Timing: finalizing preserves the complete `[1,10]` detected range; paused
  short ranges merge before filtering; 30/60 FPS both make **20 inference
  calls in ten seconds**. Motion sample endpoints are **9.9,10.3,10.5** with
  pause/join samples excluded. See [timing evidence](CALL-20260919-TIMING.md).
- Reflection native media: **21 function checks, 13 frame checks, five audio
  windows and three color-profile checks**. Full decoded audio matched all
  **576,512 samples** byte-for-byte; original sources were unchanged. See the
  capture/native report for source hashes, PCM hash and HDR limits.
- Reflection controller: **12 adversarial traces** pass, including cancel
  during an await, account change, lost submit response, failed refund request,
  invalid output, journal failure, later-clip preflight refusals, resumable rate
  limits and recovery of a committed apply receipt.
  See [controller evidence](CALL-20260919-REFLECTION-CONTROLLER.md).
- Photos-first exact-function check reuses the same listing while storing
  **200 Corrected Avenue**, latitude **28**, and creating no duplicate.
- Existing adoption behavior: **73 local-binding/persistence assertions** pass;
  all three deliberately broken method variants fail their assertions. The test
  scaffold supplies an inert missing preferences helper; product adoption logic
  was not changed. See [CI attribution](CALL-20260919-CI.md).
- First pushed candidate in the PostgreSQL 16 service container: **51 reflection
  SQL assertions before and after migration replay**, plus **46 concurrent
  transactions / 43 checks**. The full Supabase edge suite passed **802 tests**;
  other CI failures and their repairs are tracked separately in the CI reports.
- Final local server suite: **850 tests pass**, including **64 router/fallback
  tests**. The actual photo-handler matrix passes **309 assertions**. Native
  PostgreSQL 17 verifies 0055 and 0056 twice, disabled-row immutability and
  historical migration replay; its 266 invariants retain only the documented,
  unchanged agent-reel headroom failure. See [database evidence](CALL-20260919-CI-DATABASE.md).
- Real photo experiment: eight provider outputs inspected. New declutter removes
  the demo person, but both prompt versions fail permanent-detail preservation
  in two of three staging outputs. See [quality evidence](CALL-20260919-PHOTO-QUALITY.md).

Server, container CI and interactive recovery evidence are recorded in their
separate final verification reports; a passing native build alone is not a
complete release gate.

## Live provider gate and cost

Authenticated fal pricing returned **$0.14 per second** for
`bria/video/erase/prompt`. The candidate holds at most **$2.40 per batch**,
equivalent to about **17.14 seconds**, also limited by the user's remaining
AI clip allowance. The old 24¢-per-reel proxy is not used for this feature.
At the verified rate, three full 4.8-second clips cost **$2.016**; four exceed
the batch ceiling. A full six-minute pass would cost **$50.40** at this rate,
so the handoff's provisional $17.28 estimate does not
apply to this verified endpoint price.
The ledger records the verified rate and separately marks invoice reconciliation
as incomplete; a rate-based cost is not an invoiced charge.

One three-second static-video smoke, generated from the repository's public demo
photo, was attempted with the production prompt. fal returned **HTTP 403,
“User is locked. Reason: Exhausted balance.”** No job reference or output was
created, and no second paid POST was attempted. Its $0.42 figure is the intended
rate-based cost, not a claim of actual spend. The receipt is retained outside Git
at `/Users/pilksclaes/LocalRendpropAudits/call-20260919/bria-smoke/receipt.json`.

The eight photo requests have **53.6¢ configured cost** in total; their actual
invoiced cost is unavailable. No spatial experiment budget was spent here.

## Gates still preventing release

1. Staging preservation failed in the original and repeated comparisons;
   successful HTTP responses do not make that quality check green.
2. The fal account needs funding before a real Bria result can be inspected.
   Even a successful static smoke would not prove moving-room/reflection quality.
3. A real supported iPhone still needs the ten-minute 4K thermal/battery,
   interruption, lens, orientation and range-alignment checks specified in the
   timing report. Simulator/native synthetic media cannot supply that evidence.

No main merge or production activation is justified by this report.
