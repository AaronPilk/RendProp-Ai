# Rendprop market research and local engineering handoff

## Read this first

This pass covers **solo agents, small teams, brokerages and enterprise/platform customers**. It used all three available subagents plus the coordinating agent: two primary-source research tracks, a capture-hardening track, independent review, and additional offline regression checks.

**No Apple/App Store Connect/TestFlight operation was performed in this pass.** No app upload, submission, metadata, pricing or distribution setting was changed. No backend was deployed, route enabled, new provider purchased, customer capture uploaded or production deletion exercised. Existing files and caches were not removed to free disk.

This is a substantial research and targeted engineering pass, **not a new blanket GO verdict for the entire app**. New local hardening is not in the previously uploaded TestFlight build 17. The physical room reconstruction and real agent-reel round-trip remain required gates.

## Complete report package

1. `MARKET-STRATEGY.md` — approximately 4,900 words: market evidence, all four segments, 37 candidate features, architecture, economics, distribution experiments and staged investment gates.
2. `ENGINEERING-BACKLOG.md` — approximately 3,500 words: 13 branch-sized units, actual source anchors, proposed Swift/TypeScript/API contracts, negative tests and precise completion criteria. Proposed snippets are not misrepresented as compiled production patches.
3. `COMPETITOR-EVIDENCE.md` — eight direct competitors, device/output/business-model distinctions, current public pricing where verifiable, enterprise requirements and 20 source entries.
4. `MEDIA-AND-GTM-EVIDENCE.md` — six media/AI/creative offerings, provider-rights issues, jurisdiction-specific disclosure evidence, segment buying motions and 16 source entries.
5. This file — work actually executed, commands, limitations and integration handoff.

The first four files contain more than 12,000 words and 45 unique public source URLs at the structural check. Source counts include technical/legal documentation as well as vendor and survey evidence. They are a research package, not 45 independent customer interviews. Primary-source facts, vendor claims, analytical inferences and proposed experiments are distinguished throughout.

## Most important conclusions

- **“First video plus 3D” is not supportable.** Giraffe360 and Matterport advertise overlapping combined-media products. The evidence does not establish equivalent implementation/quality, but it disproves broad category exclusivity.
- **Whole-market strategy needs different buying motions.** A coordinator, an independent agent and a platform product team do not buy the same promise. Use shared asset/identity/job foundations with different interfaces and commercial validation.
- **“Cents per room” remains an unproved component-cost hypothesis.** Include failures, retries, hosting, review and support before publishing margins. No paid reconstruction run occurred here.
- **Privacy and truthful media are product requirements.** Public derivative review, original linkage and jurisdiction-specific export behavior are necessary; a preview blur or metadata signature is not proof of safe/accurate output.
- **Some historical audit descriptions are stale.** CI exists; its iOS lane is static rather than a real Xcode test job. Provenance and team transaction foundations also exist. This pass did not independently reverify every production grant or historical P0.
- **Offline transcription is not the same as an offline reel pipeline.** Existing speech can use a server fallback (`SpeechTranscriber.swift:139–153`). The agent-reel planner sends transcript excerpts to its text provider (`agentreel.ts:370–385`), so omitting an address field does not guarantee that a spoken address stays on the phone. The backlog now makes this boundary explicit.
- **Revocation has a real limit.** It can deny future fetches within an engineered access/cache bound; it cannot recall bytes already downloaded or copied. Both roadmap contracts were corrected to state that.

## Code changed

Isolated worktree: `/Users/pilksclaes/Rendprop AI/spatial-hardening-20260910`.

Branch: `fix/spatial-capture-hardening-20260910`, based on `afa6923e443de9a3fc83c36fd8978b6e9eb85c4e`.

The first commit, `9b154c82e7e174403d48c22fca4026843fd9c6bf`, rejects unexpected saved-capture file sets/symlinks and bounds manifest/sidecar reads. The separately reviewed follow-up, `0f36496909eb45f1ce56303e07c17a3ab3fed7ee`, adds JPEG byte/dimension limits and is the final hardening branch tip. Both are local commits, not uploads or shared-branch changes.

Actual mechanisms in the final source:

| Mechanism | Source in hardening worktree | Behavior |
| --- | --- | --- |
| Bounded manifest and sidecars | `Sources/RasterWriter.swift:8`, `:119`, `:123` | 256 KiB manifest, 16 MiB sidecar; cap+1 bounded reads before decoding |
| Shared recovery validation | `Sources/CaptureArchive.swift:70` | Saved-capture recovery uses the same bounded manifest reader |
| Exact directory contents | `Sources/RasterWriter.swift:150` | Only the manifest, two directories and expected image/sidecar pairs; links/orphans fail without deleting anything |
| Raster dimension policy | `Sources/CaptureModel.swift:21` | Positive dimensions, ≤8192 per axis, ≤16,777,216 pixels with overflow-safe arithmetic |
| Encoded JPEG bound | `Sources/RasterWriter.swift:14`, `:54` | ≤64 MiB before ImageIO sees the source |
| Metadata before allocation | `Sources/RasterWriter.swift:54` | One JPEG, 8-bit, orientation 1, bounded dimensions matching calibration |
| Decoded raster verification | `Sources/RasterWriter.swift:42` | Actual decoded dimensions/depth must match metadata |
| Capture-start compatibility guard | `Sources/SpatialCaptureViewController.swift:124` | Check the actual selected format; unexpected oversized formats fail visibly before AR starts |

Paths in this table are relative to `tools/spatial-spike/capture-ios/`. Encoding orientation, crop/resize behavior, camera intrinsics and coordinate schema were not changed. The policy does not claim every future ARKit format or every iPhone fits the selected limits.

### Reproductions and regression evidence

Before the first fix, the new adversarial runner exited **1**, with one valid case passing and **six invalid cases incorrectly accepted**: sidecar link, image link, frames-directory link, an undeclared link, oversized sidecar JSON and oversized manifest JSON.

Before JPEG limits, a metadata-only preflight runner exited **1**, with one valid case passing and **three invalid cases incorrectly accepted**: a native JPEG padded one byte above 64 MiB, an 8193×1 header and an 8192×8192 header. Fixtures were small synthetic images, sparse padding or edited headers. No deliberately huge image was decoded to demonstrate the failure.

Final portable gate:

```sh
cd '/Users/pilksclaes/Rendprop AI/spatial-hardening-20260910'
bash tools/spatial-spike/capture-ios/verify.sh
```

Observed: **exit 0; 115 portable assertions; 7/7 archive-adversarial cases; 8/8 JPEG-resource cases; zero failures/skips**. Ten invalid UI-summary inputs were rejected. Deliberate failure/unknown-case controls exited **1**. An independent agent reran the actual final binaries and their negative controls with the same results. Tests cover maximum-point serialization, native-image positives, byte boundaries, metadata/calibration mismatches, pixel arithmetic and malformed limits.

Actual complete gate log: `/tmp/spatial-jpeg-final.tz0kyQ/verify.log`. Compiled test binaries and supporting diagnostics: `/tmp/spatial-capture-verify.MZGzc1/`. The hardening worktree was clean after the final commit.

### Targeted iOS framework typecheck

The coordinating agent also checked all seven actual capture source files against the installed iOS Simulator SDK, rather than relying on macOS portable tests to validate UIKit/ARKit calls:

```sh
cd '/Users/pilksclaes/Rendprop AI/spatial-hardening-20260910'
xcrun swiftc -typecheck -parse-as-library \
  -target arm64-apple-ios16.0-simulator \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.4.sdk \
  -module-cache-path /tmp/rendprop-spatial-integration.sLQDuM/DerivedData/ModuleCache.noindex \
  tools/spatial-spike/capture-ios/Sources/App.swift \
  tools/spatial-spike/capture-ios/Sources/CaptureArchive.swift \
  tools/spatial-spike/capture-ios/Sources/CaptureControls.swift \
  tools/spatial-spike/capture-ios/Sources/CaptureModel.swift \
  tools/spatial-spike/capture-ios/Sources/CaptureRecorder.swift \
  tools/spatial-spike/capture-ios/Sources/RasterWriter.swift \
  tools/spatial-spike/capture-ios/Sources/SpatialCaptureViewController.swift
```

Observed: **exit 0, no diagnostics**, Apple Swift 6.3.1. Evidence: `/tmp/rendprop-market-verification.GnutHA/capture-ios-sdk-typecheck.log` (empty diagnostic log; exit recorded in the execution transcript). New symbols were searched before this command. No source edits occurred during typechecking.

This is a targeted typecheck, **not an app link, Xcode project build, simulator run, archive or physical test**. It does not replace the later integrated release gate. Existing module cache was reused because free disk space was approximately 1.4–1.6 GiB; no caches were deleted.

## Other tests rerun this pass

### Supabase Edge Function unit suite

```sh
cd '/Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/services/supabase/functions'
DENO_NO_PROMPT=1 deno test --allow-read --allow-env --deny-net --node-modules-dir=auto .
```

Observed: **exit 0; 526 passed, 0 failed**, with typechecking and runtime network access denied. Runtime: Deno 2.7.13 / TypeScript 5.9.2. Evidence: `/tmp/rendprop-market-verification.GnutHA/deno-suite.log`. No live database or provider route was exercised; this is not an RLS/concurrency deployment proof.

### Training adapter and process guards

```sh
cd '/Users/pilksclaes/Rendprop AI/spatial-testflight-20260910'
PYTHONDONTWRITEBYTECODE=1 /tmp/spatial-training-verify.rUYL0A/venv/bin/python \
  -m unittest discover -s tools/spatial-spike/training -p 'test_*.py' -v
```

Observed: **exit 0; 24 tests, zero failures/skips**, 2.124 seconds. Existing Python 3.12.14/Pillow 12.1.1 used. Evidence: `/tmp/rendprop-spatial-offline-recheck.2msGU1/training.log`. These include pose/axis math, image/binary round-trips, altered input, process timeout and child-process cleanup using owned test fixtures. They do not run CUDA or reconstruct a room.

### Viewer benchmark harness

```sh
node --test tools/spatial-spike/viewer/benchmark.test.mjs
node tools/spatial-spike/viewer/benchmark.test.mjs --negative-control
```

First command: **exit 0; 7 tests, zero failures/skips**. Second: expected **exit 1**, asserting that empty animation-frame callbacks must never produce a valid FPS result. The wrapper required that exact failure. Runtime: Node 25.9.0. Evidence: `/tmp/rendprop-spatial-offline-recheck.2msGU1/viewer.log` and `viewer-negative.log`.

This proves harness accounting, invalidation and failure behavior, not SOG rendering or device performance. The upstream verifier requiring public downloads, combined iOS-build script, GPU trainer and browser viewer were not run in this offline subtask.

## What remains unverified

- Physical iPhone AR capture, real interruption timing, real saved-export behavior and thermal/memory limits.
- One actual room through reconstruction and a SOG viewer; actual cost, quality, training time and phone frame rate.
- A real 60-second agent-reel clip through strictly offline transcription and the live EDL route.
- Integrated Xcode build/UI regression of the new hardening commits. Prior build-17 evidence is historical and does not prove this new source.
- Atomic snapshot/export against a concurrently mutating local writer. Static file checks do not close that TOCTOU window.
- Every internal ImageIO allocation or total process memory. Encoded-byte/pixel bounds reduce exposure, not guarantee a device memory budget.
- Production RLS/parallel SQL behavior, credentials/rotation, provider contracts/settings, staging lifecycle rules, sweep schedules, runtime secrets or current App Store dashboard state.
- Enterprise readiness, negotiated API rights, willingness to pay, market share and real cohort margins.

Do not convert those limitations into a blanket “all tests passed” release claim. The new code is reviewed local hardening; the larger feature list remains proposed engineering.

## Prior related material retained

`tools/spatial-spike/INTEGRATION-VERIFICATION.md` and `IPHONE-TESTFLIGHT-CHECKLIST.md` retain the earlier build-17 delivery and owner testing instructions. They were not rerun or used to justify a new upload.

`tools/spatial-spike/RE-WALKTHROUGH-PRO-ASSESSMENT.md` retains the earlier recommendation **not to install** that upstream skill. It is an external Claude/provider video workflow, not an AR capture SDK or a missing Rendprop engine. Nothing from it was installed or executed in this pass.

## Final branch and integration state

Research is isolated on `research/market-and-next-build-20260910` in `/Users/pilksclaes/Rendprop AI/spatial-testflight-20260910`. Hardening is isolated on `fix/spatial-capture-hardening-20260910` in its separate worktree. Neither was merged into the shared feature branch or deployed by this work.

`git fetch origin` completed successfully without a shared-branch mutation. At that fetch, `origin/feat/agent-reel` was `cb9a6473896845b6382ac1caa36d1ae754a16874` and the existing integration branch was `afa6923e443de9a3fc83c36fd8978b6e9eb85c4e`.

Before future integration, inspect the then-current branch/diff, preserve other agents’ changes, incorporate the hardening commits into a dedicated integration branch, and run the actual project’s build/test gates. Do not upload or change Apple state until explicitly authorized after the pending submission response.
