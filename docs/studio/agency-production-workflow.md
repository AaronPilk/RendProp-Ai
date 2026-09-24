# Property video production workflow

This change connects capture planning, editable reels and team review around an existing property. It extends the existing editor and upload system. Spatial capture remains a separate workflow.

## Agent workflow

1. Open a property on the phone and choose **Plan your video**. Select a listing highlight, agent-led tour or market update, then add a short brief.
2. Capture footage using the existing photo/camera tools. Separate video takes can be selected from Photos into the new clip library. Importing these clips does not replace the property's main walkthrough.
3. Review the originals, mark the checklist yourself and upload the clips. A checklist answer is not a focus, audio or upload-quality certificate. Actual uploaded asset receipts link footage to shots.
4. Open the same account, workspace and property in Studio. The plan, uploaded originals and saved reel are associated with that property. Open another property to work on its separate reel.
5. Choose footage, review a guided draft, then adjust its sequence, captions and timing. Listing highlights suggest pacing; agent tours and market updates preserve the explicitly chosen speaking range. The target duration is a planning hint, not a promise to invent or repeat footage.
6. Play the complete edit, save its sources, and submit the saved version for review. Submission shares that reel and a frozen copy of the saved capture brief with eligible workspace members.
7. Apply feedback, export, and save the result to the listing using the existing delivery tools.

## Agency workflow

Open the team review queue to see submitted reels. Preview restores the exact original files and selected narration used by the saved edit. Timestamped comments refer to that document revision. Editing the source invalidates approval; later private edits and notes stay private until submitted again.

An eligible editor can explicitly copy a submitted version into their own private reel for the same property. The source remains unchanged. If the editor already has a saved reel, the replaced version is preserved first. The copy uses a revision check and freezes local editing while it completes. An uncertain response requires loading the latest saved edit before work resumes; it does not blindly retry the copy or resume a stale writer.

Saved version history contains submissions and drafts preserved before replacement. Restoring a version creates a new current revision. It does not rewrite history. Full review history stays attached to the source author's reel; an agency copy has its own review lifecycle.

Existing permissions continue to apply. Marketing members can read submitted reviews but cannot edit or approve. Owners/admins and the property's assigned agent can approve; other authorized agents can comment and request changes. Account deletion, membership removal and property/workspace deletion revoke access.

## Editing capabilities and boundaries

- Guided listing highlight, agent tour and market update drafts are ordinary editable plans. Applying a recipe is explicit and undoable.
- Simple and professional controls work on the same draft. Trimming, splitting, playback speed, captions, photo motion, cutaways, original audio and saved narration use the existing renderer.
- Recipes do not transcribe speech, choose semantically relevant cutaways, generate video, invent market facts, automatically beat-match music or reproduce a particular agency's signature style.
- Music licensing and a music mixing track are not supplied by this change. Palmier and Runway are not installed or integrated by it.
- Current browser limits still apply: 12 sequence clips, up to 12 photo cutaways, 128 MiB per source, 512 MiB of unique source media and a 3-minute timeline. Splitting a video does not count its bytes twice.
- A captured 4K original may exceed the browser's memory/file limits. The phone preserves it; this change does not silently compress, discard or claim the browser can edit every phone recording.

## Acceptance on a real phone

Software and synthetic-media tests cannot validate a camera or real property coverage. Before calling the workflow ready for an agency pilot, use a real phone to:

- Record several separate takes, import them, relaunch and verify each original still plays.
- Upload on the intended network, interrupt connectivity, then resume and check that Studio contains each clip once.
- Change a capture-plan note on the phone, reopen the same property in Studio and verify it. Make concurrent edits on both devices and resolve the visible conflict without losing the local draft.
- Make a reel from that footage, check exposure, stabilization, speech clarity, pacing and the final exported picture/audio together.
- Submit it to a second real workspace account; review, copy, edit, resubmit and approve. Confirm the source author's edit and saved prior versions remain intact.

Simulator builds and camera-free UI tests verify compilation, navigation and local state only. They are not camera acceptance.

## Rollout order

Apply the new timestamped production-review migration, deploy the `studio` edge function, then deploy Studio. Deliver the iOS changes through the normal reviewed release process after reconciling Claude's current spatial branch. No existing shared branch should be force-pushed.

The migration adds review authority and immutable version records. Approval is never trusted from an author-editable JSON payload. The copy endpoint creates a private narration reference only for the voice selected in the shared snapshot; it does not expose the original author's creative history or generate new audio.

Deploying this branch does not require enabling a spatial flag or a paid provider. Do not advertise the full workflow as live until the backend, Studio and the matching phone build are all deployed and the real-device acceptance above passes.
