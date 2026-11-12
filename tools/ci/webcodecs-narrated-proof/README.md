# First narrated WebCodecs proof — prepared, not run

This is a disposable diagnostic for the first three-second narrated Studio case at shipping commit `1c561d7b91d9b75bd7ba29aa081fcba959089fee`. It does not change the release checkout, package manifest, production exporter, or CI. A pass would establish this one fixture only.

## Pinned inputs

- Mediabunny `1.65.2`, MPL-2.0, installed separately under `../webcodecs-proof-dependencies/`. Its npm integrity, external lockfile SHA-256, exact ESM entry SHA-256, and canonical hash of all 293 installed package files are checked by `prepare-disposable-copy.py`. The generated test requires the exact external Vite alias path and checks that package tree again before and after the browser run.
- The preparation script checks 19 shipping input hashes, including the original Studio export, renderer, media/model, browser fixture, package lock, and CI runner policy. The disposable source should be created from the exact commit above with `git archive` or an equivalent immutable checkout.
- The local codec capability probe already showed Chrome 153 H.264/AAC support at 800×450. The proof checks actual 720×1280 fixture dimensions before any output.

## Scope and output

- The test selects **Mute audio** in the normal Studio UI and verifies that saved draft choice. Its 2× source video is generated with `-an`, so this does not establish original clip audio or pitch preservation.
- The experimental exporter allows only the three-clip, three-second photo → 2× video → photo edit with saved narration and no music, speech, or overlays. It uses the shipping `decodeMedia`, `seekMedia`, `drawFrame`, `OverlayPainter`, model timeline, and MP4 cadence verifier.
- Narration is rendered once to mono 48 kHz PCM with `OfflineAudioContext`, then encoded to AAC. Exactly 90 canvas paints become 90 timestamped `VideoFrame`/`VideoSample` submissions at 30 fps. Each sample add is awaited for library backpressure. The H.264/AAC MP4 is returned only after both tracks close, the muxer finalizes, 90 encoded packets are observed, and the shipping cadence verifier accepts it.
- The browser test retains the existing source restore, saved narration, decoded 660 Hz PCM, dissolve and whip pixel checks. It additionally requires exactly 90 distinct encoded packet presentation times and exactly 90 decoded MP4 frame presentation times, each within 1 ms of its `index / 30` position; duration must be within two frames of 3 seconds. It records packet timestamps, packet sizes, finalized/refused status, source hashes, runner facts, and an explicit `partialSuite: true` receipt. Source and dependency hashes must still match at the end for the result to count as passed. The refusal branch requires zero download events and no download link.

## Preparation and execution boundary

`prepare-disposable-copy.py --checkout <exact-1c-disposable-checkout> --dependency-root <external-dependency-root> --receipt <external-receipt.json>` prepares the isolated copy. `--validate-only` checks source pins and all transform anchors without writing. The script refuses to modify the active release checkout and refuses to overwrite existing diagnostic files.

After independent review, the parent agent owns any browser run. Set `WEBCODECS_PROOF_MEDIABUNNY_ENTRY` to the exact external `node_modules/mediabunny/dist/modules/src/index.js` and `STUDIO_BROWSER_EXECUTABLE` to the pinned browser, then invoke the disposable checkout's `apps/studio/tests/webcodecs-narrated-proof-browser.mjs` with the same default-device audio selection as the failed CI job. Keep all generated MP4, PNG, receipt, runner, and failure artifacts outside Git. Do not treat `prototype-case-passed` as a full Studio suite result or a release fix.

## Limits

- This proof does not handle audible original clip sound, pitch-preserved speed changes, music, speech, cutaways, other durations/ratios, or provider output. These remain on the shipping path.
- The 2× fixture is a constant-blue silent video. It tests timeline duration and transitions, but not frame-accurate seeking in moving source video.
- Mediabunny's `BufferTarget` allocates before calling its write handler. The proof has a finite three-second input, a 128 MiB post-output refusal, and an encoded-byte abort, but no hard preallocation memory cap.
- Mediabunny `Output.cancel()` cannot interrupt an output already in `finalizing`. The 66-second signal deadline covers media/encode operations that observe the signal, but it is not a hard finalization kill. An isolated browser process and outer test timeout are required for a bounded runtime experiment.

## Static checks completed

- `--validate-only`: 19/19 shipping hashes and all transform anchors passed.
- Generated browser script: `node --check` passed.
- Disposable Studio TypeScript: `tsc --project tsconfig.webcodecs-proof.json --noEmit` passed against the pinned Mediabunny declarations. The static checkout includes the one repository-level `custom-photo-prompt.ts` import used by Studio; no browser or media export has run.

Official API references: [Writing media files](https://mediabunny.dev/guide/writing-media-files), [Media sources](https://mediabunny.dev/guide/media-sources), [VideoSample](https://mediabunny.dev/api/VideoSample), [AudioBufferSource](https://mediabunny.dev/api/AudioBufferSource).
