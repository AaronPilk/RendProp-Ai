# External audible-original proof draft

This is a diagnostic copy only. Shipping source remains at `1c561d7b91d9b75bd7ba29aa081fcba959089fee`; no production dependency, exporter, workflow or account is changed. The separate narrated/muted WebCodecs proof passed locally. Audible-original v2 captured 31 PCM blocks and then refused `pcm-credit-exhausted`; preserved v3 refused on the active recording-clock guard before PCM. V4's first audible-original case passed its strict PCM, pitch, frame, transition and cleanup checks, but the second delayed-promise case refused in pre-content `AudioStartupClock` before arming. No v5 browser result exists yet.

## Scope

The synthetic edit is a purple photo for 0.5 s, a blue H.264/AAC source for 4 s played at 2× for 2 s, and a red photo for 0.5 s. The source emits 990 Hz for its first 150 ms and 880 Hz afterward. The fixture explicitly selects original audio and contains no narration or music. The frozen prior proof's 90-frame video loop is byte-identical in the derived exporter.

`audible-pcm-worklet.js` captures an exact 144,000-frame stereo window with eight reusable 1,024-frame credits. `audible-pcm.ts` validates sequence, frame origin and finite PCM, awaits progressive AAC adds, and refuses source loss or clock drift. The browser harness checks decoded first sound, 880 Hz ±30 Hz pitch at 2×, 40 ms continuity, two silent photo regions, exactly 90 encoded/decoded video frames, strict dissolve/whip pixels, two-frame duration agreement, bounded resource closure, source hashes and the entire pinned Mediabunny package tree. It includes eight drafted refusal cases and a delayed-promise positive case. These checks have **not** run yet.

V3 leaves the eight-credit limit, sample window, AAC calls, media clocks and quality assertions intact. On a Worklet fault, it records the exact sample frame, sent sequence, outstanding count, received recycles, current/pool availability, maximum outstanding/pool and the last flush/recycle frame and epoch times, when `Date` is available. The main thread retains received and returned counts, a 40-entry ring of recent credit handoffs with performance and epoch times, Web Audio sample rate/latency/output timestamps when available, and independent wall/Web Audio records before and after the native `video.play()` call and its promise settlement. Missing optional clock APIs yield null observations and do not affect capture. `maxQueueDepth` alone excludes returned credits still in transit to the Worklet; compare the two sides of this trace before proposing a buffer or scheduling change.

V4 keeps those observations and also stores the original predicted wall origin with its exact performance and AudioContext inputs. It records the last eight inputs to `RecordingClock.read`, including whether the read occurred inside the wait loop or at its target, and copies the existing drift error's finite numeric cause fields. Both `clock.read` calls retain the same arguments and error behavior. This diagnostic does not change the drift threshold, audio clock, credit pool, playback schedule, media assertions or refusal policy.

V5 changes only pre-content readiness polling to the owned single timer used by shipping `awaitAudioStartup`: the same `AudioStartupClock` and two-second deadline still refuse an unstable or backward clock. It retains the last eight startup readings and any error cause in the bounded observation. The RAF-or-timer helper remains in active capture. No credit, capture-origin, media, quality or refusal threshold changes are made.

## Static preparation for root-owned execution

The preparer requires a fresh disposable `git archive` of the exact shipping commit, separate from the active checkout, and the already-installed external Mediabunny 1.65.2 package. It verifies shipping file pins and the package lock, integrity, entry and whole-tree digest before copying six files. It refuses to overwrite an existing diagnostic file.

```sh
python3 prepare-audible-copy.py \
  --checkout /ABSOLUTE/EXTERNAL/DISPOSABLE/SOURCE \
  --dependency-root '/Volumes/Rendprop Files/Builds/Active/native-1.0.9-147-20261111/evidence/diagnostics/webcodecs-proof-dependencies' \
  --receipt /ABSOLUTE/EXTERNAL/preparation.json
```

After independent review, root may run the partial proof with the existing Studio `node_modules`, the pinned Chrome executable and FFmpeg. The harness's default `hosted-exact` profile requires Node 24.22.2, Chromium 153.0.8010.12 and FFmpeg/ffprobe 9.0.2. `--local-observation` only labels a differing local toolchain and cannot be reported as the hosted gate. Default device audio is used; no test-only silent sink is selected.

```sh
AUDIBLE_PROOF_MEDIABUNNY_ENTRY='/ABSOLUTE/EXTERNAL/node_modules/mediabunny/dist/modules/src/index.js' \
STUDIO_BROWSER_EXECUTABLE='/ABSOLUTE/PINNED/CHROME' \
node /ABSOLUTE/EXTERNAL/DISPOSABLE/SOURCE/apps/studio/tests/audible-proof-browser.mjs
```

The harness writes `receipt.json`, the downloaded MP4 on success, and a final screenshot under its emitted absolute artifact directory. A result named `prototype-case-passed` is a partial fixture result only. Full feature parity still needs narration, music, audible original source in multiple clips, moving-video frame accuracy, 180 s memory bounds, and abort/finalize containment.
