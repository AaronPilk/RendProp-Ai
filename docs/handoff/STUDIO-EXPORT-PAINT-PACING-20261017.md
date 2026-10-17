# Studio export paint pacing

Studio now paints each nonterminal30fps capture interval once, retaining every
clock read, audio/media drift guard, gain update, progress report and wakeup.
The final endpoint still paints. This removes redundant HD canvas/overlay work;
it does not change export timing or retry an unsafe render.

The current hosted silent-video failure correctly refused an AudioContext clock
plateau of at least110.9ms. The local unchanged diagnostic did not reproduce that
stall. It did expose122 draw submissions with43 duplicate buckets in its silent
fixture. The candidate produced62 draws and no duplicate buckets, with encoded
MP4/PCM/duration checks preserved. This is49.18% fewer draw submissions, not a
measured CPU saving or proof the hosted stall is fixed.

One ten-case audio sequence,17 units/type checks, fixed-resume regressions, real
AudioContext interruption, four preparation cleanup refusals and three strict
compiled negative controls pass. The paint-budget control checks only after the
original encoded-duration/PCM checks. CI now requires its exact duplicate-bucket
failure. No threshold, original clock, cadence or audio-quality oracle is relaxed.

Final retained packet: build88-silent-video-poststart-diagnosis/
FINAL-REVIEW-READY.json SHA54ae75b1ed8d28ece2ec15f7194fa46ef5ef2eee016e7e84b3b1e8e90611d1c1.
Independent final review9442beb0f295028204a386df4238edbcaa36224269a0cffbbddf659fff8329d7.
Current full hosted CI and a fresh Studio shipping artifact remain required.
