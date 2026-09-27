# Property video production workflow

Capture planning, editable reels and team review connect around an existing property. Spatial capture remains a separate workflow. The [24 September production record](../handoff/CODEX-STUDIO-LIVE-20260924.md) establishes the deployed baseline; the newer music, speech, named-project and editing-copy features described here are implemented in source and await a new release receipt. Phone workflow acceptance and App Store Connect remain with the owner.

## Agent workflow

1. Open a property on the phone and choose **Plan your video**. Select a listing highlight, agent-led tour or market update, then add a short brief.
2. Capture footage using the existing photo/camera tools. Separate video takes can be selected from Photos into the new clip library. Importing these clips does not replace the property's main walkthrough.
3. Review the originals, mark the checklist yourself and upload the clips. A checklist answer is not a focus, audio or upload-quality certificate. Actual uploaded asset receipts link footage to shots.
4. Open the same account, workspace and property in Studio. The plan, uploaded originals and saved reel are associated with that property. Open another property to work on its separate reel.
5. Choose footage, review a guided draft, then adjust its sequence, captions and timing. Use **Sound & captions** for uploaded music, subtitle import, reviewed beat cuts and optional speech analysis. Agent tours and market updates preserve the explicitly chosen speaking range. The target duration is a planning hint, not a promise to invent or repeat footage.
6. Play the complete edit, save its sources and any selected music, and submit the saved version for review. **Save music with property** attaches that file for restoration and handoff. Submission shares the reel and a frozen copy of the saved capture brief with eligible workspace members.
7. Apply feedback, export, and save the result to the listing using the existing delivery tools.

## Agency workflow

Open the team review queue to see submitted reels. Preview restores the exact original files, selected narration and authorized music used by the saved edit. Missing music blocks playback/export instead of silently omitting it. Timestamped comments refer to that document revision. Editing the source invalidates approval; later private edits and notes stay private until submitted again.

An eligible editor can explicitly copy a submitted version into their own private reel for the same property. The source remains unchanged. If the editor already has a saved reel, the replaced version is preserved first. The copy uses a revision check and freezes local editing while it completes. An uncertain response requires loading the latest saved edit before work resumes; it does not blindly retry the copy or resume a stale writer.

Saved version history contains submissions and drafts preserved before replacement. Restoring a version creates a new current revision. It does not rewrite history. Full review history stays attached to the source author's reel; an agency copy has its own review lifecycle.

Withdrawal or a private new revision blocks new review reads and new recipient copies. An already completed copy remains an independent snapshot, including the narrow grant for its selected music. Source/account deletion and lost current property/workspace access prevent further reads; previously downloaded files and unexpired signed URLs cannot be recalled instantly.

Existing permissions continue to apply. Marketing members can read submitted reviews but cannot edit or approve. Owners/admins and the property's assigned agent can approve; other authorized agents can comment and request changes. Account deletion, membership removal and property/workspace deletion revoke access.

## Editing capabilities and boundaries

- Guided listing highlight, agent tour and market update drafts are ordinary editable plans. Applying a recipe is explicit and undoable.
- Chat, Simple and professional controls work on the same draft. Trimming, splitting, playback speed, captions, photo motion, cutaways, original audio, saved narration and imported music use the same preview/export renderer.
- Music supports trim, offset, volume, fades and ducking, with reviewed beat-cut proposals and Undo. Uploading a file declares permission; Studio does not supply a music license or catalog. Palmier and Runway are not installed or integrated by this workflow.
- Optional speech analysis returns verified source-timed words and speaking-passage suggestions. Review wording before applying captions or a passage. Captions follow trims, splits, reorder and speed, including over photo cutaways. This does not rank picture quality, recognize rooms, choose semantic cutaways, invent market facts, or reproduce an agency's signature style.
- MP4 export depends on the browser’s H.264/AAC recording support. Property delivery requires MP4; a browser offering only WebM can download a local draft but cannot save that file as a finished property video. The full export/audio regression runs in Chrome on macOS, while general Studio workflows also run in Linux Chromium.
- Current browser limits still apply: 12 sequence clips, up to 12 photo cutaways, 128 MiB per source, 512 MiB of unique source media and a 3-minute timeline. Splitting a video does not count its bytes twice.
- For a large recording, **Create an editing copy** accepts a supported original up to 2 GiB, three minutes and 8.4 megapixels, then creates a local 720p H.264/AAC copy. Import is explicit after preview. The original remains on the device, and only the editing copy is uploaded with the project. Check color, picture and sound; this does not promise support for every phone codec.

For videos unrelated to a listing, use a named private account project. These support uploaded originals, cross-browser restoration, music and captions without making a property, but do not enter the property review queue. Limits and exact behavior are in [projects and finishing](projects-and-finishing.md); AI gates are in [editing intelligence](editing-intelligence-activation.md).

## Acceptance on a real phone

Software and synthetic-media tests cannot validate a camera or real property coverage. Before calling the workflow ready for an agency pilot, use a real phone to:

- Record several separate takes, import them, relaunch and verify each original still plays.
- Upload on the intended network, interrupt connectivity, then resume and check that Studio contains each clip once.
- Change a capture-plan note on the phone, reopen the same property in Studio and verify it. Make concurrent edits on both devices and resolve the visible conflict without losing the local draft.
- Make a reel from that footage, check exposure, stabilization, speech clarity, pacing, reviewed caption timing and the final exported picture/audio together. If using an editing copy, compare its color and detail with the original.
- Submit it to a second real workspace account; review, copy, edit, resubmit and approve. Confirm the source author's edit and saved prior versions remain intact.

Simulator builds and camera-free UI tests verify compilation, navigation and local state only. They are not camera acceptance.

## Rollout order

The production-review migration is already recorded in the verified baseline. Apply only reviewed pending migrations for named projects, private media, property music and text-route seeds before dependent `studio` handlers and Studio assets. Preserve existing migration history and JWT settings. The [selected-function helper](../../apps/studio/scripts/deploy-backend.mjs) stages offline by default and deploys only an explicit selection with `--run`. Deliver iOS separately through the owner's release process; a web release does not ship a native binary. No shared branch should be force-pushed.

Review authority and immutable versions remain server-owned. Approval is never trusted from an author-editable JSON payload. Copy creates access only to selected authorized narration/music in the shared snapshot; it does not expose the author's other creative history or generate new audio.

Deploying this source does not require enabling spatial or Presenter generation. Text and speech activation have separate bounded checks. Do not advertise the full phone-to-agency workflow as accepted until its backend, Studio and matching phone build are deployed and the real-device checklist above passes.
