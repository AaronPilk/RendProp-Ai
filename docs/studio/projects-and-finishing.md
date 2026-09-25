# Video projects, sound and captions

Studio's Create workspace uses the same edit for Chat, Simple and Pro views.
Start with media and a brief, review the preview, refine it and export. Property
reels retain their existing delivery and agency review workflow. A general video
project does not require creating a property.

## Save and continue

Local creation keeps original files in this browser's account/workspace-scoped
IndexedDB storage. Browser storage can be cleared or evicted; keep your originals.
It is not cloud backup. **Save project to account** creates a named private project
and explicitly uploads its source files. Changes then save with revision checks.
The status distinguishes saved editing instructions from fully uploaded originals.
Wait for **Project and originals saved to your account** before moving devices.

Open that project using the same Apple account and workspace in another browser.
Studio verifies each downloaded part and the complete file before relinking it.
Music uses the same restoration path. A missing file is reported; it is never
silently replaced or omitted from the export. An interrupted upload resumes from
confirmed parts. An uncertain completed write can be verified without another PUT.

Each account/workspace supports up to 100 named projects. Archive is reversible
and does not delete media or free storage. Private project media reserves at most
512 MiB per workspace, with 128 MiB per file and immutable 8 MiB upload parts.
Storage reservations count unfinished files too. Individual cloud file deletion
and automatic orphan reclamation are not provided by this release; the durable
account/workspace deletion process inventories all possible part keys before
removing metadata and waits out upload authority. These limits are enforced.

Concurrent devices cannot overwrite each other silently. **Open newer saved
version** first preserves the browser edit independently. **Recover browser edit**
opens it as a local copy, which can be saved under another name. Up to 20 distinct
browser recovery snapshots are retained without silent eviction; remove one only
after keeping the work you need. Account changes abort pending writers and use
separate media, conversation and recovery scopes.

## Sound and speech

Expand **Sound & captions** to add music you have permission to use. Supported
music is limited to 16 MiB and three minutes. Preview and export share trim,
timeline offset, volume, fades and ducking under speech or original audio.
Missing or mismatched music blocks playback/export rather than changing the mix.
Studio does not supply a commercial music license or catalog.

Chat can change music volume, fades and ducking. Beat analysis produces a cut
proposal for review; applying it is one undoable change. It does not guarantee
that an agency's preferred musical phrasing or visual rhythm has been reproduced.

For saved, eligible video, speech analysis returns source-timed words and suggested
speaking passages. Review names, numbers and wording before applying captions or
choosing a passage. Captions follow source time through trims, splits, reordered
clips and speed changes, and remain visible over photo cutaways. A chosen speaking
passage changes the clip's trim and captions together, with Undo.

Manual SRT/VTT import remains available. Subtitle intervals do not become invented
word-level timings. Removed footage no longer leaves its unused transcript in the
current shared draft; the prior version remains in local Undo history.

Speech service activation, exact media limits, pricing estimates and the single
provider-attempt policy are in [editing intelligence](editing-intelligence-activation.md).
Speech passage suggestions are based on the transcript. They are not visual
scene recognition or a factual certification of a property's features.

## Large footage

**Large video? Create an editing copy** loads its encoder only when opened.
Choose a supported original up to 2 GiB, three minutes and 4K. Studio reads it in
bounded chunks, makes a 720p H.264/AAC copy, checks the resulting size/timing and
fingerprints both files. Keep the tab visible. Hiding, canceling or leaving the
task stops preparation; incomplete output is not imported.

Preview the copy's picture, color and sound, then choose **Use editing copy**.
You can download both the copy and its provenance JSON. The full-resolution
original stays on your device; saving this project uploads the editing copy.
The provenance file identifies the original but does not back it up. HDR/color,
heavily compressed audio and unusual phone codecs still require visual/listening
review in the actual destination browser.

## Property and agency delivery

Use **Save music with property** before sharing or delivering a property edit.
Submitted review preview and explicit version copies include only the selected
authorized music. Knowing another account's content hash grants no access.
Withdrawal blocks new review reads and new recipient copies. An already completed
authorized copy remains an independent edit; source/account deletion and lost
property/workspace access prevent further media access. Previously downloaded
files and issued short-lived URLs cannot be recalled instantly.

Named general projects are private to their creator. Shared review remains tied
to property reels. Native **Save setup** shares supported reel settings; it is not
the desktop timeline, music mixer or project list. See the [agency workflow](agency-production-workflow.md)
for the real-phone and second-account acceptance checklist.

## Verification

`projects-browser.mjs` runs the real project/editor components with separate
browser storage and an isolated CAS/object-store fixture. It verifies local
recovery without upload, explicit account saving, cross-browser originals,
account privacy, conflict copies, archive and a deferred-writer account switch.

`finishing-browser.mjs` encodes and decodes actual synthetic H.264/AAC video. It
checks music/original/narration amplitudes, fades and ducking, caption pixels,
speech-passage and beat-cut Undo, invalid source rejection, cancellation and a
130 MiB 4K input converted to 720p with bounded reads. These are camera-free
software checks. They do not certify real recordings, artistic quality, spatial
reconstruction or a new native release.
