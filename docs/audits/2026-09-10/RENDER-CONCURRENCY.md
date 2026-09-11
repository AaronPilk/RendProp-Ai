# RenderEngine: serial ownership and cancellation checkpoint

Source repair only; no deployment, TestFlight upload, App Store change or camera
test. Branch `fix/render-concurrency-20260911`, based on `2750953`. This is not
a whole-app concurrency/HDR verdict.

## Reproduced cause and actual code repair

The prior Release build log
`/tmp/rendprop-noncamera-ui-3_d1cfjd/build.log` reports four unique warnings:
baseline `RenderEngine.swift:592/594/599/604` captures `writerInput`, `reader`,
`readerOutput` and `writer` inside AVFoundation's Sendable ready callback.
The installed iOS26.4 SDK explicitly marks those four AV classes non-Sendable.
The warning demonstrates an ownership mismatch, not a reproduced customer crash.

`apps/ios/Rendprop/Render/RenderEngine.swift:582` now transfers those objects
after setup into `EncodeSession` (`:597`). The owner confines start/read/append,
writer completion and failure teardown to the same per-render serial queue.
Queue entrypoints assert their executor. The private `@unchecked Sendable`
conformance applies only to this explicitly confined owner; no framework import
annotation or blanket AV type conformance suppresses warnings.

At `:620`, task cancellation sets the existing locked flag and also dispatches
cleanup. Previously the flag was observed only during ready callbacks: a writer
under persistent backpressure could leave the continuation waiting indefinitely.
`writerFinished` (`:676`) returns to the owner queue before reading writer state;
`finish` (`:685`) consumes the continuation once before resuming it. Queued late
callbacks cannot append/resume after the phase becomes terminal. The ready
callback captures the owner weakly to avoid an input/callback/owner retain cycle.

The stabilization algorithm, geometry, retiming, frame cadence, all-intra
settings,9Mbps bitrate and existing-file replacement policy are unchanged.
No `RendpropApp.swift`, `AuthStore.swift`, UI or project generation file changed.

## Executed bounded proof

Run from the branch root:

```sh
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin python3 tools/audit/run_render_concurrency.py
```

The source-presence gate runs before compilation. The runner compiles the
complete actual RenderEngine and actual CaptureAsset/RoomTag; harness-only
boundaries replace app Documents paths, import duration constants and unrelated
SpaceType labels. Constants are checked against the real MediaImporter.

- Real iOS16-simulator-target SDK typecheck, Swift5 language mode and
  `-warnings-as-errors`: actual baseline fails with exactly the four named
  captures; repaired source passes with no diagnostics.
- Native macOS13-target AVFoundation execution, repeated twice:15 assertions
  per run, three actual1.5-second synthetic clips rendered and one early
  cancellation. It verifies duration, output existence, independent parallel
  renders, bounded progress, unchanged earlier output and no partial files.
- Actual private EncodeSession, with a controlled non-ready WriterInput:
  three additional assertions per run. The single ready callback is observed
  finished before cancellation; no further callback is delivered. Cancellation
  returns the expected error and closes the real AV reader/writer.
- Six real finished MP4s are independently probed: each has60 frames, all
  keyframes,64×48 dimensions,60fps and Rec.709 tags. These are format checks,
  **not HDR tone-mapping quality evidence**.
- Actual copied-source mutant removing only cancellation's queue wakeup
  compiles, then exits1 with `stalled encode cancellation did not resume`.
  The normal engine remains unchanged; no skipped test or timeout is green.

First full accepted evidence: `/tmp/rendprop-render-concurrency-hvysi4tw/`.
That receipt predates the final receipt Git-identity fields; the final clean
checkpoint rerun is reported alongside the commit. Each run retains exact
commands, exits, source hashes, encoded-media hashes and logs in `receipt.json`.

Harness corrections were not product findings: Swift diagnostics echo each
error in source context, so counting unanchored strings double-counted four;
the initial stalled-reader fixture omitted required videoComposition; ffprobe
includes extra tags/disposition even with selected stream fields. All three
caused nonzero gates and were repaired before claiming the full result.

## Still unverified

No full app/Xcode build, iPhone playback, real capture, long-file/device thermal
stress, memory/race sanitizer, HDR quality or Swift6-complete concurrency pass
ran. The pre-existing pass1 `runOnQueue` bridge and other app warnings are outside
this narrow unit. Existing system AV decoder calls can still block until the
current call returns; this does not promise a hard whole-render wall timeout.
Tests reuse existing compiler caches because the Mac has limited free disk.
