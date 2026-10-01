# Call-wave audit: capture timing and person ranges

Audited `8d32f85..7bcc6241b6ae53eaecde76e49da5e378661cc31b`, on the isolated
`call-audit-20260919` checkout. Read the complete September 19 handoff, call
feedback and call transcript first. This is the timing sub-audit; the recording
lifecycle, joining/recovery and persistent-store audits are separate.

**Person ranges are not yet a reliable input to paid reflection removal.**
There are executable counterexamples for dropped ranges, ranges beyond the
video, stale detection state and a motion sidecar that diverges from the joined
video. None of the sidecar observations is claimed to lose the video itself:
the sidecar is currently write-only. No cloud jobs, phone connections, customer
media, App Store Connect operations or production edits were performed.

## Reproduce

From the checkout root:

```sh
python3 tools/audit/call-20260919/timing/run.py
```

The runner extracts the actual `CameraManager` implementations of
`currentRecordedSeconds`, `hasTakeInProgress`, `ingestPersonSample`,
`closePersonRange`, `detectPeople` and `captureOutput`; their bodies are not
reimplemented in the test. It compiles the complete `MotionRecorder` after
replacing only the unavailable CoreMotion input, monotonic clock and private
visibility boundaries. It uses actual native CoreVideo buffers and sampling,
controlled Vision results, controlled movie durations, and actual main-queue
dispatch. These are adversarial event traces, **not observations of a physical
iPhone's AVFoundation callback latency or Vision accuracy**.

It also runs a native ThreadSanitizer stress with the actual `@Published`
thermal-message wrapper. JSON, generated Swift, source hashes, compiler logs
and sanitizer output go to a new temporary evidence directory on every run.
The executable checks describe the audited defects, so a corrected implementation
is expected to change the assertions rather than preserve these outcomes.

Verified run on September 19:
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-call-timing-20260919-9s0adabd/receipt.json`.
The same receipt is preserved under
`tools/audit/call-20260919/timing/receipt-7bcc624.json`.
Both Swift compiles and the ordinary executable succeeded. The sanitizer probe
exited zero and did not report a data race.

## T1 — P2: finalization can erase a valid person range

Locations: `CameraManager.swift:398`, `:837–839`, `:849–854`, `:530–534`.

Trigger a first segment containing a person from approximately 1–9 seconds,
then Stop. Before `didFinishRecordingTo` has banked its duration, deliver four
negative Vision results. They can be four newly processed frames during a
longer finalization, or outstanding results; the detector continues running
through finalization. The real `currentRecordedSeconds` returns **zero** in
`.finalizing` for the first segment because it returns only `bankedSeconds`.
`closePersonRange` then clears `personRangeStart` and discards the now
zero-length range. When `deliverTake` later closes at the actual ten-second
file end, there is nothing left to close.

Executable result: `finalizingDropsEightSecondRange: []`.

This is a deterministic state-machine counterexample. The test does not prove
that a particular phone needs four detector periods to finalize a file.
At 60 FPS the existing sampler delivers up to four detector results per second,
so the vulnerable interval is shorter than its advertised two-Hz cadence.

The range timeline should freeze consistently while the segment is finalizing,
and completion should close against the actual banked media duration. Do not
let a detector callback use an earlier segment's clock to close the active one.

## T2 — P2 before Task 2: range padding and pause boundaries are not normalized

Locations: `CameraManager.swift:442–446`, `:849–865`;
`CaptureView.swift:602`.

Two independent executed cases:

| Input trace | Actual stored ranges | Expected invariant |
|---|---|---|
| Person visible through the end of a ten-second video | `[0, 10.5]` | End is at or before the actual video's duration |
| Two adjacent detected half-second stretches, split by Pause | `[]` | Joining removes wall time; adjacent visible content should be considered together before minimum-duration rejection |

`closePersonRange` pads the end by 0.5 seconds without a final media clamp.
`useTake` copies the ranges directly into `CaptureAsset`; nothing here bounds
them to the probed asset duration. An eraser using these values can request an
invalid tail or overstate the number of seconds it will process. No current
paid consumer exists, so this is not claimed to be an existing billing incident.

The pause example loses both half-second stretches because each is rejected
before the merge. It is not a removed-wall-time bug: the positive control with
a thirty-second hold correctly stays on a four-second joined timeline and
produces `[1, 4.5]` after padding. The same control exposes the separate 0.5-second
terminal overrun. Normalize merged/clamped ranges against the completed asset
before filtering by minimum duration or quoting processing seconds.

## T3 — P2: thermal skipping leaves an unverified warning and open range alive

Locations: `CameraManager.swift:798–811`, `:822–842`.

Raise the warning with two positive samples, then set the existing thermal
message. Subsequent `detectPeople` calls return before updating the state.
In the executed sixty-second trace the warning remains true with **zero new
Vision passes**, and the stored range becomes `[0, 61]` for a video ending at
60.5 seconds. A person who left when the device became hot is therefore still
reported present for the entire remaining take.

The opposite direction also has a gap: a person appearing after thermal
inference stops will have no range. That is a coverage limitation, not evidence
that the person is absent. A paused detector needs an honest unavailable state;
its stale positives must not silently become billable seconds. Capture metadata
should distinguish observed presence from intervals with detection unavailable.

The actual modulo-15 sampler was executed on native buffers representing ten
seconds at each supported cadence:

| Capture cadence | Handler invocations in ten seconds | Inference requests (body + face) |
|---|---:|---:|
| 30 FPS | 20 | 40 |
| 60 FPS | 40 | 80 |

Thus max-quality capture schedules **four handler invocations a second**, not
two. These are scheduled-call counts with fake inference, not a thermal or
battery measurement and not a guarantee of delivered real-device throughput.

## T4 — P3 until a sidecar consumer exists: paused wall time is not the joined media clock

Locations: `MotionRecorder.swift:112–123`, `:157–177`;
`CaptureView.swift:305–306`, `:545–567`;
`CameraManager.swift:668–680`.

Three executed counterexamples:

1. Logging starts at uptime 100. Pause is tapped at 110, but the current movie
   segment finishes at 110.4; the next segment starts at 140. The actual
   `MotionRecorder` timestamps the next sample at **10.1**, while its joined
   movie time is **10.5**. It also drops the motion sample at 110.3 even though
   that frame belongs to the first segment. Pausing at the button press and
   resuming at the delegate callback cannot account for the movie's measured
   segment lengths. The 0.4-second delay is controlled input, not a phone
   measurement; the error scales with the actual stop/start callback delays.
2. A pre-pause motion callback arrives after Resume. Because `ingest` uses the
   current `pausedAccum`, not the recording epoch containing the sample's
   timestamp, timestamps go **99.9 → 69.99 → 100.01** in the generated trace.
   The mutex prevents simultaneous mutation; it does not identify stale samples
   or prevent a timestamp from moving backwards across a pause.
3. `handleFinished` awaits the join before calling `endLogging`. If recording
   stops at uptime 110 and joining takes until 115, the real recorder accepts a
   sample at movie time **14** for media that ended at **10**. The test verifies
   the actual call-site ordering, executes the motion functions with that
   controlled join interval, writes the real sidecar through `endLogging` and
   decodes its JSON to confirm the persisted last timestamp is 14. It does not
   run AVFoundation export itself.

Use the actual media timeline for each segment and reject samples outside that
segment's recorded interval. Stop or freeze logging before awaiting any join;
file writing can still happen afterwards on the existing file queue. The
repository explicitly says these sidecars are currently not uploaded or read,
so the immediate severity is lower than a footage-loss bug.

## Observations that are not promoted to proven production findings

- `detectPeople` queues only a Boolean. Its callback has neither the source
  frame's presentation timestamp nor a take/segment generation. The actual
  function can attribute two queued positives from an old take to a fresh
  take at **0.1 seconds** in the controlled trace. No real-device event sequence
  demonstrating this exact rapid-retake ordering was collected, so this is an
  asynchronous-boundary risk rather than a claimed observed user incident.
- The luma queue reads `thermalMessage`, which is written on main. A stress
  test preserving the actual Combine `@Published` wrapper performed 100,000
  reads/100,000 writes under ThreadSanitizer and reported **no data race**.
  Replacing that wrapper with a plain optional produces a race, but is not a
  faithful model and is not supporting evidence. This check is not a proof of
  all cross-queue camera state or of SwiftUI thread isolation.
- `.right` is consistent with the source's intended unrotated landscape
  video-data buffer and portrait movie output. The harness does not run real
  Vision inference and therefore **does not validate** this assumption for the
  actual camera buffers. No orientation defect is asserted without that test.
- Synthesized `CaptureAsset` decoding compatibility is not ranked here. The
  active persistent-store path uses a separate `PersistedAsset`; that path is
  covered by the joining/persistence audit. An unused standalone Codable
  decoding failure would not prove startup data loss.

## Required physical-device evidence before calling detection cheap or reliable

No ten-minute 4K thermal/battery test was performed. A simulator, desktop
generated-buffer loop, and a nominal ~2 Hz comment cannot establish that claim.
The owner or a device-testing session needs to run a controlled comparison with
the **same real supported iPhone**, ambient conditions, lens, stabilization,
screen brightness, initial battery/thermal state and 4K frame rate. Compare
camera + light meter alone to camera + light meter + both Vision requests,
changing only inference. Test 4K/30 and the max-quality 4K/60 tier separately.

For each complete ten-minute take, collect recording duration/frame count,
frame-drop/discontinuity evidence, detector invocation count and latency, main
thread responsiveness, thermal-state transitions, peak memory, measured energy
and battery change. Include a pause/resume and camera interruption, and inspect
the final joined file, room-tag boundaries, sidecar endpoints and person ranges.
Use non-customer fixtures: a consenting tester in direct view and mirrors,
including a small face-only reflection, with known entry/exit times and both
lenses. Record missed intervals and warning-clear latency, not just whether a
banner appeared once. Preserve camera buffer orientation and compare it to the
saved portrait movie before deciding whether `.right` is correct.

The comparison should report actual numbers and repeatability; this audit sets
no invented acceptable battery threshold. Any Task 2 cost estimate must use
normalized intervals, separately acknowledge unobserved footage, and remain
opt-in as the handoff requires.

## Local repairs and fixed regressions

The audited September 17 implementation remains reproducible with `timing/run.py`,
which now reads `7bcc624` through `git show` by default. The repaired working
tree is separately exercised by:

```sh
python3 tools/audit/call-20260919/timing/regression.py
```

The fixed run compiles the real changed camera functions and complete motion
recorder, retaining only the framework/input doubles. It produced these results:

- The finalizing trace now preserves `[1, 10]`.
- Adjacent half-second spans across Pause merge to `[0.5, 2]` before filtering.
  Invalid/non-finite spans are rejected; final padding is clamped to media length.
- Heat freezes evidence at the last sampled time, clears the stale positive and
  exposes an unavailable message. The previous sixty-second false range becomes
  `[0, 3.5]`. No inference runs while thermal availability is false.
- Source timestamps converted through the capture synchronization clock control
  ranges; queued results from an old segment/availability generation are ignored.
  Both 30 and 60 FPS produce **20 handler calls in ten seconds**.
- Measured segment durations supply joined offsets. The retained sidecar times
  are **9.9, 10.3, 10.5**: the written stop tail stays, a stale pre-pause callback
  is rejected, and pause/join samples are excluded. The actual sidecar write,
  checkpoint and asynchronous rebind were decoded; the source sidecar remains.
- A stopped camera session now gives actionable Resume/Stop feedback. Exhausted
  or less-than-one-frame headroom delivers the existing pieces; whole-frame and
  CMTime flooring keeps all requested take totals at or below **600 seconds**.
  No footage is trimmed to conceal an overrun. Single-frame and unprobeable files
  are retained for the recovery flow rather than silently deleted.

Receipt: `tools/audit/call-20260919/timing/receipt-fixed.json` (temporary evidence
directory `rendprop-call-timing-fixed-bcgvw3s2`). Native Swift parsing and
`git diff --check` also passed. These checks do not replace the full iOS build,
the other capture/recovery regressions, or the physical-device evidence above.
In particular, the file delegate's host anchor remains an **estimate**; a
per-segment timeline removes accumulated pause drift but does not prove exact
sensor-to-movie alignment. The controller callbacks freeze motion before the
capture view begins joining, with UI wiring owned by the recovery repair.
