# Rendprop Studio: local browser editor

Implemented in `apps/studio/src/editor/` on `feat/web-studio-20260912`. This is a local
editing/export capability. It creates no server render job, publication, approval,
provider request, or paid operation. It does not implement the canonical artifact
path described in [ARCHITECTURE.md](ARCHITECTURE.md).

## Integration

```tsx
import VideoEditor from './editor/VideoEditor';
import { validateDraft, type EditDraft } from './editor/model';

<VideoEditor
  active={currentPage === 'editor'}
  initialDraft={validatedSavedDraft}
  onDraftChange={(draft: EditDraft) => saveForCurrentWorkspace(draft)}
  importRequest={{ id: stableOperationId, files: alreadyFetchedFiles }}
/>
```

`initialDraft` is mount-only. The host must finish validating the saved draft before
mounting and remount with a new key on identity/workspace changes. Ordinary navigation
keeps the editor mounted after its first visit, in a hidden section; `active={false}`
pauses/releases the preview decoder and cancels an active export without revoking
verified local file URLs. Returning to the editor does not require reselection.
Actual unmount (including an identity/workspace change) releases all media. The host scopes
saved drafts to their workspace. `validateDraft(value: unknown)` validates and rebuilds
allowlisted fields; `parseDraft(json)` additionally enforces the JSON size ceiling;
`serializeDraft(draft)` produces a portable JSON plan. Invalid data throws a useful
error. The editor itself also validates `initialDraft`.

`importRequest` appends to the current sequence, consumes each stable operation ID
once during that component lifetime, and validates the whole batch before accepting
it. Imports are sequential, atomic, and revision-fenced. An import arriving during
another import receives an explicit retry notice. Root code owns any authenticated
download; the editor receives real `File` objects and makes no network request.

The component imports its own scoped `editor.css`. It adds no npm dependencies.
The editor owns its visible, atomic status announcement. Optional `onNotice` is an
observer for integrations, not a request to render the same message again; Studio
does not forward it into the host banner. Successful edits clear old completion
messages along with their invalidated download. The headline and empty-state copy
are industry-neutral.

## Implemented behavior

- Import local JPG, PNG, WebP, MP4, WebM, and browser-decodable MOV files. Decode errors
  identify the browser limitation. SVG/HTML are rejected.
- Select a clip, move it earlier/later using named buttons, or remove it from the edit.
- Set photo duration; trim video in/out; change horizontal/vertical crop focus.
- Undo/Redo timing, captions, title, framing, order, aspect ratio, audio mode,
  removal, and added-media edits, within the bounded session history below.
- Choose 9:16 (720×1280), 16:9 (1280×720), or 1:1 (960×960).
- Set a persistent title overlay and each clip's caption, burned into the canvas.
- Play/pause/replay and scrub the actual sequence, with source trim offsets respected.
- Keep original video audio by default, or explicitly select Mute audio. Photos are
  silent. There is no generated music, voice replacement, or cross-clip audio bed.
- Save/open a portable edit-plan JSON file. Save plans include the source's complete
  SHA-256 hash plus metadata, but never a `File`, blob URL, decoder, or output URL.
- Reselect missing files after reload. Matching name/size/date is insufficient; the
  complete content hash and media metadata must match before reconnecting a source.
- Export an actual local video Blob and expose a download link only on success.

New photos start at 3 seconds; new videos use up to their first 6 seconds. This is
stated in the sequence help and import notice, and all source duration remains
available to the trim controls. Over-limit batches are refused; files are not dropped
from a selection and timelines are not silently truncated.

## Undo/Redo and removed-media lifecycle

The recovery branch adds a pure validated history engine: at most **20 combined
Undo/Redo steps and 64 KiB of UTF-8 snapshot/label payload**. Older, more distant
steps expire first; large plans can therefore retain fewer than 20. History holds
edit metadata only, never files, thumbnails, decoders, blob URLs, or completed
exports. The existing 12-file/160 MiB media bounds are unchanged. This payload cap
does not claim a hard browser-process heap limit.

Repeated changes within one focused field are grouped until blur or pointer release.
Undo/Redo buttons are keyboard accessible; Ctrl/Cmd+Z and Ctrl/Cmd+Shift+Z (or Ctrl+Y)
work while focus is inside the editor but outside input fields. Native text-field
undo is left alone. Real edits after Undo discard the redo branch; a no-op value does
not consume history, clear redo, or invalidate a valid export.

Undo/Redo restore exact validated content under the **same edit ID and a newly
incremented revision**. They never reuse a previous export identity. Both stop
playback, abort an active export, and revoke a completed download. Opening a plan,
reloading, or changing workspace/identity starts a new history; portable plans and
autosaved drafts persist only current edit intent, not history.

Removing a clip still immediately releases its original local media and thumbnail.
Undo restores its original hash, cuts, caption, position, and framing, but the user
must reselect that original file to preview/export it. The toolbar/removal/undo
notices state this explicitly. Reselection still verifies the entire SHA-256 plus
media metadata; a same-ID/different-source resource cannot be silently reattached.
Reselection itself does not consume history, so Redo can remove the clip again.
Undoing an import follows the same release/reselection contract. No hidden media
cache grows behind the timeline as clips are removed and re-added.

## Export and audio

The exporter captures a canvas at a requested 30fps and encodes with `MediaRecorder`.
It probes actual APIs and MIME/codec configurations. MP4 is offered only when a
H.264/AAC configuration is advertised; WebM uses VP8/Opus or the browser's supported
WebM configuration. The download extension comes from the recorder's actual MIME
type, never from a renamed WebM. Recorder construction/encoding can still fail after
capability advertising; failure yields a visible notice and no completed download.

For original audio, the export-button gesture creates/resumes one `AudioContext` and
a `MediaStreamAudioDestinationNode`. The destination's audio track joins the canvas
video stream. Each active video is connected through `createMediaElementSource`;
the source is disconnected at its cut. Audio goes to the recording destination rather
than the speakers. A zero-valued constant source keeps the recording audio clock
running through photos; otherwise Chromium can omit leading silence and shift the
first video's audio to the start of the file. Images produce silence. Recording starts/resumes before advancing
a video so encoder startup cannot discard the beginning of speech. Audio has no
silent fallback: if required APIs or audio startup fail, the export fails and explains
that the user may explicitly choose Mute audio or change browser.

The recorder pauses while loading the next clip. Both preview and export use the
same crop/text renderer. Encoding is real-time and browser-scheduled, so duration,
frame rate, and cut alignment have small scheduling/encoder overhead. This is not a
frame-exact offline renderer and does not claim parity or byte identity with iOS or
the future canonical server renderer. Keep the tab visible; hiding it cancels export
and pauses preview. Revision/identity changes, leaving the editor, unmount, cancellation, encoder errors,
deadline expiry, and output-cap overflow invalidate an in-progress export. Any edit
also revokes the previous download URL. Native media startup promises have explicit
timeouts and cancellation races so a blocked `play()`/audio resume cannot hang cleanup.

## Local limits

| Resource | Ceiling |
| --- | --- |
| Clips per edit | 12 |
| Each encoded input file | 32 MiB |
| Total encoded inputs | 160 MiB |
| Photo dimensions | 12 megapixels, maximum dimension 12,000 |
| Video dimensions | 8.4 megapixels, maximum dimension 12,000 |
| Source video duration | 0.5–300 seconds, known finite duration |
| Photo timeline duration | 0.5–30 seconds |
| Minimum trimmed video duration | 0.5 seconds |
| Total edit duration | 180 seconds |
| Caption/title | 120/80 characters, at most four explicit lines |
| Portable edit JSON | 64 KiB |
| Undo/Redo history | 20 combined steps; 64 KiB UTF-8 snapshot/label payload |
| Encoded output held in memory | 128 MiB |
| Export deadline | twice edit duration plus 60 seconds |
| Native media event/startup wait | 15 seconds |
| Video playback stall during export | 10 seconds |

The 32 MiB file cap is intentional: Web Crypto's digest is not streaming, so each
file is hashed in one bounded allocation, sequentially. This version does **not**
support importing a multi-gigabyte iPhone walkthrough or promise a resumable uploader.
Source blob URLs refer to files; full video files are not loaded as base64. Thumbnail
images are small 240×160 JPEGs. Only the current source is decoded per preview/export
pipeline, not every timeline source. Browser decoder/encoder memory is implementation
dependent; pixel limits are checked when dimensions become available, not a guarantee
of a hard browser-process memory cap against pathological media.

## Verification

Recovery-branch source verification on 2026-09-12: `npm run typecheck` and
`npx tsx --test tests/editor*.test.ts` pass (**19 tests, zero skipped**). Six new
engine tests cover all reversible operations, grouping, divergent redo, no-ops,
combined count/byte bounds, source release/full-hash identity, corrupt/cross-plan
history, invalid edits, and revision exhaustion. Negative cases assert rejection
without mutating the history. The browser runner now additionally asserts restored
trims/captions/order/ratio, missing-file recovery after Undo removal (including a
wrong-file rejection), active-export cancellation by Undo, and exactly one
editor-owned completion announcement for every actual export. **Fresh integrated
browser proof passed at 18:08 UTC: 18 checks, seven real exports, zero skips/errors.**
It includes the new Undo/Redo UI and checks exact served build bytes. See
[the recovery iteration](STUDIO-RECOVERY-2026-09-12.md) and its dedicated receipts.
The older 13-check evidence below is preserved as history, not reused as new proof.

Executed locally on 2026-09-12 against the final frozen production build:

- `npx tsx --test tests/editor*.test.ts`: 13 tests passed, zero skipped. Covers trim
  boundaries, reorder immutability, cover-crop geometry, all plan/input limits, schema
  validation, removal of unknown persisted fields, full-content file matching,
  revision/identity cancellation, and cancellation/deadlines of pending native waits.
- `npm run typecheck`: passed.
- `tests/browser-editor.mjs` in Chrome 152.0.7977.83: **13 checks passed, seven real
  downloads, zero skipped**, 16:21:47–16:22:15 UTC. Every offered format was exported
  and decoded; no external requests, uncaught browser errors, or asset errors.
- A dynamic 3-second synthetic H.264/AAC source was trimmed to 0.5–2.5 seconds.
  Both outputs were 720×1280; AAC/Opus tracks had two channels at 48 kHz. Decoded
  audio RMS was 0.08832/0.08829 and measured frequency 440.617/440.109 Hz,
  proving actual original-tone samples. Caption checks found 4,819/4,856 light
  pixels in a region proven dark before export.
- Reordered a one-second photo ahead of the two-second video, exported both formats,
  and decoded frames to verify order. The leading-photo interval had RMS **0** in
  both exports; tone after the cut measured 439.717/439.710 Hz. This regression
  caught and verified the fix for missing leading silence in Chromium's audio track.
- Explicit mute and square-photo exports contained no audio stream. Editing a
  completed revision removed its stale download. Revision change, Cancel, simulated
  hidden state, and editor navigation each cancelled active export without a
  download; subsequent export succeeded. Navigation preserved selected local files.
- Fresh full-page screenshot and extracted output frame visually inspected: title
  and caption were burned in and readable. The separate workspace suite covers
  reload and full-hash file-reselection behavior.
- Earlier manual Chromium editor-scoped axe: zero violations, 26 passes; one incomplete contrast
  group over thumbnail/gradient backgrounds still needs manual visual assessment.
  This was not rerun as part of the final export suite and is not a claim of complete
  WCAG compliance.

| Final decoded output | Video / audio | Duration | Bytes |
| --- | --- | ---: | ---: |
| Trimmed video MP4 | H.264 / AAC | 2.038267 s | 231,618 |
| Trimmed video WebM | VP8 / Opus | 2.025 s | 122,718 |
| Photo→video MP4 | H.264 / AAC | 3.010467 s | 293,064 |
| Photo→video WebM | VP8 / Opus | 2.999 s | 285,015 |
| Explicitly muted video MP4 | H.264 / none | 2.072467 s | 257,552 |
| Square photo MP4 | H.264 / none | 2.026400 s | 33,684 |
| Photo export after cancellations | H.264 / none | 2.032000 s | 37,315 |

The run verified actual served `index-CLxeL-BH.js` and `VideoEditor-BQUBAGWf.js`
against built bytes. The full dist fingerprint before and after was
`22467bf283acaf7c3193748e51852a67feef0ea21c7d8f58930797481fe3e5fd`.
The receipt, source fixtures, screenshots, and downloaded files are in
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-editor-browser-iYF3by`.
The final receipt has a durable copy at
[`evidence/2026-09-12/editor-browser.json`](evidence/2026-09-12/editor-browser.json).
The OS temporary directory is not a durable release artifact. Earlier manual axe
evidence is separate at `/tmp/rendprop-editor-proof.aupOKp`.
Safari, Firefox, physical phones, long clips near the limits, and publication remain
unverified by this editor-only check.

### Deployed preview verification

The same suite passed on `https://studio.rendprop.com` on 2026-09-12,
16:31:06.321–16:31:34.469 UTC: **13 checks, seven real downloads, zero skipped**
in 28.148 seconds using Chrome 152.0.7977.83. The fresh context made no cross-origin,
non-read, redirect, or WebSocket request and reported no browser or asset errors.
No account was used, and fixtures and encoded exports stayed local.

The actual browser-received 867-byte HTML and both JS/CSS pairs exactly matched
the frozen build. JS names remained `index-CLxeL-BH.js` and
`VideoEditor-BQUBAGWf.js`; the dist fingerprint was
`4adf6e9a492d98ad482c6ac48bff97cd9d73df13fa821b01f9086dff03c170fe`.
The fingerprint differs from the earlier local receipt because the later build
added the deployment's `no-transform` response-header directive, without changing
HTML, JS, or CSS. This editor suite does not request or verify `robots.txt`.

The deployed run decoded trimmed MP4 H.264/AAC at 2.036700 seconds (222,015 bytes)
and WebM VP8/Opus at 2.027 seconds (122,644 bytes), both with two-channel 48 kHz
audio and measured original tone near 439.709 Hz. Photo→video exports were
3.035600/3.013 seconds; the leading photo's audio RMS was 0 in both, with the tone
retained after the cut. Mute, square-photo, stale-download invalidation, all four
cancellation paths, navigation media retention, and post-cancellation recovery
also passed. The hidden-state check remains an explicit platform-event simulation,
not a physical OS-tab visibility test.

The separate durable receipt is
[`evidence/2026-09-12/deployed-editor-browser.json`](evidence/2026-09-12/deployed-editor-browser.json).
Raw screenshots, fixtures, and outputs are in the non-durable OS temporary directory
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-editor-browser-NrtpnZ`.
The local-run receipt above is preserved unchanged.

Reproduce a quick functional test:

1. Run Studio locally and open Video editor without creating an account.
2. Add a small photo. Set its duration to 2 seconds and enter a caption.
3. Export the offered MP4 or WebM and download the resulting file. Decode it with
   `ffprobe`/a media player; verify aspect ratio, caption, nonempty bytes, and duration.
4. Add a short video with audible speech, trim it, and export with original audio.
   Verify the actual audio samples, then export again with Mute audio and verify the
   absence of audio. Move the photo ahead of the video and check the first frame.
5. Start a longer export, edit its caption or press Cancel, and verify no download is
   produced for the interrupted revision. Repeat by hiding the tab and leaving editor.
6. Save/reopen/reload the plan. Reselect a different file with the same displayed
   metadata and verify refusal; the original file must reconnect successfully.

The repeatable production-byte suite is `apps/studio/tests/browser-editor.mjs`:

```sh
# Build once. Do not rebuild dist while either browser suite is running.
npm run build
node tests/browser-editor.mjs --start-preview --base-url=http://127.0.0.1:4181
# Or use an existing frozen production preview:
node tests/browser-editor.mjs --base-url=http://127.0.0.1:4179
# Only after the deployed preview's bytes match the same frozen local dist:
node tests/browser-editor.mjs --deployed-preview --base-url=https://studio.rendprop.com
```

It requires ffmpeg, ffprobe, and the installed Playwright Chromium runtime. Set
`STUDIO_BROWSER_EXECUTABLE` to an installed Chrome executable when needed.
`--start-preview` serves existing built bytes and deliberately does not rebuild.
The default is localhost HTTP only. `--deployed-preview` permits exactly
`https://studio.rendprop.com` and cannot be combined with `--start-preview`.
Both modes use fresh isolated contexts with service workers blocked and permit
only same-origin GET/HEAD requests. Non-read requests, cross-origin requests,
redirects, and WebSockets are blocked and fail the run. The deployed mode performs
the same local-file editing/export checks without signing in or uploading media;
it does not relax the built/served HTML and asset byte comparisons.
The test creates synthetic fixtures in a new directory under the operating system's
temporary root, opens a fresh browser context, and blocks external requests. Its
JSON receipt includes built/served asset SHA-256 hashes, codecs, decoded audio RMS
and 440 Hz frequency, duration measurements, caption pixel counts, screenshots,
and output file hashes. The process exits nonzero on a failed assertion or any
change to dist during the run. No media check silently skips unsupported encoding:
it exports every format actually offered by the browser, prefers MP4 when offered,
and verifies WebM instead on browsers whose capability probe does not offer MP4.
An advertised format that fails encoding is a test failure, not a fallback.

Timing allows an explicit ±0.35-second real-time encoder tolerance for the 2-second
single-clip and 3-second sequence edits. WebM recordings without a duration header are measured from actual packet
timestamps. Silent tracks are rejected by decoding samples and checking the source
tone; burned caption pixels are checked against a region proven dark in the source.
The suite also verifies explicit mute, photo-only export, revision cancellation,
manual cancellation, hidden-state cancellation, navigation cancellation, and successful
export afterward. A reordered photo→video sequence is exported in every offered
format; decoded pixels check the order, and decoded audio checks both leading-photo
silence and the original 440 Hz tone after the cut. A playback/navigation regression proves that visiting the planner
pauses playback and preserves selected media when returning to the editor.
Chromium headless keeps tabs visible when switched/minimized, so the hidden-state
check explicitly simulates `document.hidden` during a real `visibilitychange`
dispatch. Its receipt does not claim an actual OS tab-hiding test. Full-hash media
reselection is covered separately by `tests/browser-workspace.mjs`.

API references used: [MediaRecorder MIME type](https://developer.mozilla.org/en-US/docs/Web/API/MediaRecorder/mimeType),
[recorder pause](https://developer.mozilla.org/en-US/docs/Web/API/MediaRecorder/pause),
[recorder resume](https://developer.mozilla.org/en-US/docs/Web/API/MediaRecorder/resume),
and [Web Crypto digest's non-streaming input](https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto/digest).
