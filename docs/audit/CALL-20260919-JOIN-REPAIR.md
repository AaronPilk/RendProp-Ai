# Paused-take repairs and reflection-video peer verification

This supplements the original NO-GO in `CALL-20260919-JOIN.md`. The changes below are local candidate repairs. They do not claim physical-device capture, a production deployment, or a successful paid Bria edit.

## Capture repairs

- **J1:** recording and join filenames include a UUID. The join separately requires a new, nonexistent output whose resolved path is disjoint from every input.
- **J2:** joining fails on any missing, damaged, duplicate, or unsupported-format segment. Each input is inspected for playability, video tracks, duration, dimensions, transform and codec. Compressed sample buffers are counted; output must contain the total input samples with the complete expected duration and format. Aggregates or outputs over the importer’s 600-second ceiling are rejected without trimming.
- **J3:** `TakeRecoveryStore` atomically journals ordered segment paths and frozen tags, detections, timing, format and sidecar paths after each finalized piece and before joining. Successful joins are also journaled. Originals are retained after both success and Use this take, because the existing `onComplete` callback cannot acknowledge durable listing persistence. Saved takes supports retry and individual ShareLink exports after reopening/relaunch. Legacy `walkthrough-*.mov` files absent from valid journals appear under **Other recordings on this phone**, with date and size; they are not guessed into a take or deleted. An unreadable journal is retained and counted visibly. A journal-write failure stops before joining, offers manual export, and warns before closing without durable recovery.
- **J4:** joining is a finalizing state; record, lens changes and dismissal are blocked. Gyro logging ends and metadata is captured before awaiting export. The completed review receives that frozen record rather than current camera/tag state. The camera/motion callbacks and queued sidecar copy are supplied by the timing repair.
- **J5:** persistence writes and restores `personVisibleRanges`. Older snapshots default to no detections; malformed individual entries are salvaged separately, and invalid or out-of-bounds ranges are removed without losing the video or other tags.

Recovery intentionally retains storage for the original segments and joined output. There is no automatic destructive cleanup on a presumed successful handoff. A process killed during an unfinished first segment has no finalized-segment journal yet; the read-only legacy-file section can expose surviving files, but this is not a guarantee that AVFoundation finalized a playable movie before termination.

## Capture verification

Commands:

```sh
python3 tools/audit/call-20260919/join/run_join.py --revision 7bcc624
python3 tools/audit/call-20260919/join/run_persistence.py --revision 7bcc624
python3 tools/audit/call-20260919/join/run_join_regression.py
python3 tools/audit/call-20260919/join/run_persistence_regression.py
```

The two baseline commands extract audited production sources from Git and still reproduce the original defects. Their historical expectations were not rewritten to make the repaired source appear to pass.

The repaired native tests execute actual `TakeJoiner`, finish/retry/controller logic, button predicate/action, recovery store and persistence code, using local AVFoundation and synthetic media. UI scaffolding and unrelated dependencies are small stubs.

**33 join/controller/recovery assertions passed**, including unique paths, retention on success/failure, no silent partial success, a durable journal before export, metadata isolation, disabled Record, failed-join relaunch/retry, malformed-journal preservation, failed journal writes, legacy file discovery, and rejection of 600.75 seconds with both originals retained. **9 persistence assertions passed** for current, legacy and partially malformed snapshots.

Final receipts:

- Join/controller/recovery: `/tmp/rendprop-call-join-fixed-yxxlkank/receipt.json`.
- Persistence: `/tmp/rendprop-call-persistence-fixed-3mq_1ndo/receipt.json`.
- Re-executed original defects: `/tmp/rendprop-call-join-axddiimw/receipt.json` and `/tmp/rendprop-call-persistence-dxv2obwk/receipt.json`.

The receipts include source hashes and exact compile/run commands. All synthetic media and compiled programs remain outside Git. Full iOS build and interactive saved-take UI verification belong to the parent integration report; these native checks do not substitute for them.

## ReflectionVideo peer changes and evidence

The original local implementation preserved full original audio by composition and encoded all video spans, but its media primitives did not themselves enforce the 600-second source/output boundary. They also lacked an explicit shared color policy when mixing HDR camera footage with SDR AI output.

The peer changes:

- Enforce the importer ceiling in extract and splice, including final output; no source trimming.
- Apply the same explicit SDR BT.709 composition settings used by `RenderEngine` to extraction and the full splice. The original HDR file remains unchanged. This is a defined SDR delivery policy, not a claim of HDR-preserving output or measured real-iPhone highlight rendering.
- Confine export start/cancellation/completion state to one serial owner instead of capturing a non-Sendable `AVAssetExportSession` directly in a cancellation handler.
- Extend the actual native regression with portrait transforms, non-frame cut points at 29.97 fps, over-cap sources, PQ/BT.2020 input, original audio waveform measurements, and immediate cancellation.

Run:

```sh
python3 tools/audit/call-20260919/reflection/video.py
```

**21 function checks, 13 decoded-frame checks, 5 audio waveform windows and 3 color-profile checks passed.** Source media hashes remained unchanged; the source and test hashes are fenced through completion.

- Two replaced intervals in the 12-second source retained the original audio chirp with **1.0 zero-lag waveform correlation** in every tested window, including inside the replaced ranges. The complete decoded PCM also matched byte-for-byte: **576,512 samples**, SHA-256 `99666f6f87fec6d5de35ee1dd306032f3eaa06d2ee7d7a4f20108defce21dc7d`.
- Portrait source, extracted provider input and spliced output remained 240×320. Unedited sampled pixels differed by **0/255** at both tested times.
- The 29.97 fps source retained duration with cuts at 2.013–4.413 seconds; sampled frames before, inside and after the replacement had the expected colors.
- The synthetic HDR source was verified as BT.2020 primaries / SMPTE ST 2084 transfer / BT.2020 nonconstant matrix. Both normalized reference and spliced output were BT.709 in all three fields. Unedited sampled pixels differed from the same normalized reference by **0–2/255**.
- Five-second provider inputs, wrong-length/shape/overlapping replacements, sources over 600 seconds, and immediate cancellation were rejected.

Final reflection receipt: `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-reflection-video-0x1cjmf8/receipt.json`.

Initial fixture failures were retained as failed evidence: a legacy ffmpeg rotation metadata option produced an identity transform, and generic HEVC color flags did not preserve PQ/BT.2020 VUI fields. The final fixture explicitly sets display rotation and x265 color parameters, then verifies the resulting metadata. Untagged synthetic SDR comparisons were replaced with an explicitly tagged color contract rather than weakening pixel thresholds.

Limits: these are synthetic local media tests. They do not prove Bria’s removal quality, mobile thermal/battery cost, arbitrary Dolby Vision variants, or real-room HDR highlight appearance. No customer media, production services, paid calls, App Store Connect operations or deployment were used for this peer verification.
