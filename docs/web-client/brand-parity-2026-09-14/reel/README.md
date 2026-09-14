# Reel and batch-photo workflow evidence

The native-style **Photos → Voice → Make it** entry uses the existing shared
property media and saved editor document. Opening a card selects a media picker;
it does not reset the sequence or move the current edit to another property.

| Receipt | Result | Evidence |
| --- | --- | --- |
| [Picker browser](picker-browser.json) | 5 groups passed | Requested property opens once; open/close/replay preserves an existing other-property edit; real 50-row paging reaches photo 51; cross-property import requires review; same-property sources append without another upload; voice/plan actions retain the edit's property; desktop and 390px layout fit. |
| [Editor regression](editor-browser.json) | 13 groups passed | Actual source restoration and hashes, cloud revisions, native setup import, source-linked plans, completed-output recovery, MP4 exports, decoded transitions, narration and continuous agent audio. |
| [Component tests](component-tests.json) | 23 passed, 0 failed or skipped | 12 batch-controller checks and 11 media-picker/download checks. Covers explicit paid dispatch, partial failures, stop, account changes, source identities, stream limits, provenance, save recovery and pagination. |

The browser suites use real components, export code and sync code against
isolated service fixtures. The exported H.264/AAC files were decoded to check
picture and audio behavior. Both browser receipts report zero unexpected
external requests and zero page errors. No paid provider, live customer record,
email, invitation or public tour was used. These receipts do not establish
physical iPhone capture behavior or production AI output quality.

## Product boundaries

- **One active desktop edit per user/workspace.** Its property association is
  explicit. The cards do not create separate saved timelines per property.
  Adding another property's media requires the existing move confirmation;
  moving can upload previous sources into that property. Completed media remains
  attached to properties independently of the active edit.
- **Uploads and finished exports are explicit.** Phone photos/videos must finish
  uploading before Studio can use their bytes. On desktop, export MP4, then use
  **Save video to listing** to put the finished video back into shared media.
  Native **Save setup** shares known photo IDs and semantic settings, not every
  local clip, recording, geometry file or native editing graph.
- **Batch previews need review/save.** Up to six photos use the same edit, with
  one AI request per photo. Generated previews remain in the current property
  session until saved to its gallery. Failed saves reuse retained output/upload
  receipts; an ambiguous paid generation is never automatically repeated.
- **Headshot files do not yet have full continuity.** The native photo picker
  stores a local JPEG and its brand sync sends contact/social text. Studio edits
  public headshot/avatar URL fields; it has no equivalent headshot file-upload
  and crop workflow. Do not claim native headshot bytes synchronize automatically.
- The browser supports 12 base clips, 128 MiB per source, 512 MiB total and a
  three-minute edit. Native camera/LiDAR capture and local scan editing remain
  device workflows. Importing native settings does not reconstruct an arbitrary
  AVFoundation timeline.

## Reproduce

From `apps/studio`:

```sh
node --import tsx --test tests/creative-batch.test.ts tests/reel-media-picker.test.ts
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node tests/reel-media-browser.mjs
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node tests/cloud-editor-browser.mjs
```

The checked-in receipts omit machine-specific temporary artifact paths. Their
fixtures use synthetic media and example account identifiers.
