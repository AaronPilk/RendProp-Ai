# Buffered narration and music alignment

The Studio exporter started original audio before awaiting `video.play()`, but
started narration and music afterward. When playback began promptly but promise
delivery was delayed, the optional tracks shifted later. The fix schedules all
buffered tracks against one segment audio origin before awaiting that promise.

Music gain data is prepared before capture starts or resumes. One bounded gain
curve and at most two original-audio ducking boundaries replace gain updates
that previously depended on later animation frames. Existing gain policies,
clock thresholds, stall refusals, revision checks and cancellation remain.

The same new test fails on the old exporter at actual encoded narration onset.
The fix passes both new MP4/AAC/PCM cases. Moving the optional starts back after
playback produces the same intended failure. The ten existing audio cases,
seventeen clock/frame tests and focused typecheck also pass. Independent review
verified the three source files and retained evidence. The CI control requires
this exact PCM failure, a real playing source, valid output and matching source
hashes; a startup or safety refusal cannot satisfy it. Its validator passed
against the actual retained omission receipt.

Evidence: external `build88-export-buffered-track-alignment/v2/REVIEW-READY.json`
(`553da496`), independent review (`77e9c306`), exact integration receipt
`ROOT-SOURCE-INTEGRATION.json`, and CI source review (`f9f98d0f`). The external
folder is `/Volumes/Rendprop Files/Builds/Active/`.

This is separate from the hosted post-start AudioContext plateau. The passive
diagnostic passed locally and in its dedicated hosted run without reproducing
that plateau; it establishes neither its cause nor a repair. Current full CI and
a fresh Studio build are still required. Optional-mix tests use two-second clips;
the maximum 180-second envelope allocation is source-bounded, not benchmarked.
No paid generation, provider activation or release occurred.

The next coherent CI also observes native browser audio spans around its actual
first freeze/MP4 case. This test-only observer leaves the original six cases,
assertions, product clocks and refusal outcomes intact. It has a bounded native
buffer, stream and event count; parsing occurs after capture. The sanitized
receipt requires a native clock marker and bounded page-time bracket before
claiming usable alignment. Missing categories, markers or complete data remain
explicitly incomplete. Raw trace bytes stay local and are not included by the
current CI artifact patterns. Syntax, 24 parser checks and three intended
omission controls pass; actual native transport is unexecuted at this checkpoint.
Evidence: external `build88-startup-native-trace-observer/REVIEW-READY-V2.json`
(`f633f033`). A passing observed export still cannot explain the earlier stall.
