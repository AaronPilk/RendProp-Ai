# CI #224 (run 38071986005, d5ed053) — "double-speed-transient-waiting" refusal, classified

Hosted receipt (job 114271106587 log): export-resume suite passed (7 checks); audio suite: normal-speed-stall ok,
split-segments ok, double-speed-pitch ok (2x, 879 Hz, RMS 0.088), double-speed-stall refused (expected),
double-speed-transient-waiting REFUSED with the stall message (unexpected) -> suite stopped there.

Mechanism check (sandbox, tip code, instrumented local copy that records the detector's measurement and marks
"wouldRefuse" instead of aborting, so the exported audio can be analysed): zz-loss-experiment.mjs,
renderer-only SIGSTOP starvation (S1's freeze.sh), 24 runs. Every run the real detector would have refused
(measured loss >= 2/30 s on two consecutive readings) produced a recording that fails at least one real
oracle (zero-RMS gap, pitch collapse to 550-740 Hz, or +35-95 % duration stretch); every run it would not
have refused had no zero-RMS gap and kept 880 Hz within 30 Hz. No false positive observed. Mild sub-threshold
artifacts exist at 150/400 ms starvation (weakest RMS 0.043-0.074, pitch 855-895 Hz) -> the threshold is
lenient, not strict. The fixture's synthetic `waiting`/`playing` events are inert on the 2x media path
(the only `playing` listener is in the 1x buffer path), so the hosted refusal required real measured loss:
an environment underrun on the starved macOS runner, the same mechanism that failed #218/#220 with the
old event-based detector, now far less frequent (#223 passed the identical control).
