# Create with chat

Studio opens on **Create**. Add photos or clips, describe the video, preview the
actual edit, and refine it in the same conversation. A property is optional for
starting a local video. The four primary destinations are Create, My homes/spaces,
Media and Business; Home, AI tools and Content planner remain under More tools.

The [24 September production record](../handoff/CODEX-STUDIO-LIVE-20260924.md)
is the verified baseline. This document also covers newer implemented project,
music, speech and editing-copy source awaiting a new deployment receipt.

The existing renderer, source handling, audio and export pipeline are reused.
Chat changes the same draft that Simple view and Pro view edit. A successful chat
request is one undoable revision. Unsupported requests do not partially change
the video. If a request arrives before media, Studio waits for a successful import
and then tries that same request against the actual clips.

## Improve prompt

The composer includes **Improve prompt**. It proposes clearer wording for review;
it does not execute the edit, create media, submit generation or send the message.
**Use this prompt** fills the composer. **Keep original** dismisses the suggestion.
Users may edit the proposed text before sending it.

There are two explicitly labeled methods:

- **Guided prompt suggestion** works offline. Supported quick commands become
  explicit wording only when the rewritten request produces exactly the same
  validated draft as the original. It preserves supplied title/caption text and
  operation order. Ambiguous, unsupported or missing-media requests retain the
  original wording and show useful notes. This is not an LLM or visual analysis.
- **AI prompt suggestion** uses the optional configured text route described
  below. It receives the brief, recent text and edit metadata; no media bytes,
  filenames, fingerprints or signed source URLs are included automatically.
  Text the user supplies is still sent. Suggestions cannot invent property facts
  or promise unimplemented effects. Review remains necessary; no model quality
  trial has been performed in this change.

A proposal belongs to the exact original text and draft revision. A late answer
cannot replace newer wording, an updated draft or another account's work. Stop
retains the original prompt. There is no automatic paid retry.

## Editing commands

The following commands work without a model call. Several commands can be joined
with semicolons. The displayed starter sentence is also supported as written.

| Intent | Example |
| --- | --- |
| Create a simple highlight | `Make a 15-second reel` |
| Shorten shot holds | `Make it shorter` |
| Order the current clips | `Put clip 3 first` |
| Supplied title | `Set the title to "Open house Saturday"` |
| Supplied caption | `Add caption "A place to gather" to clip 2` |
| Photo motion | `Add slow zooms` |
| Transitions | `Use smooth transitions` |
| Frame shape | `Make it square` |
| Original sound | `Keep original audio` |
| Imported music level | `Set music volume to 25 percent` |
| Music fades | `Fade music in and out over 2 seconds` |
| Music under speech | `Lower music under speech` |
| Undo | `Undo that` |

Timing extends photos only within their existing limits. Video may be shortened
within its selected span; it is not silently accelerated, repeated or extended.
Shortening can cut off speech, so inspect the preview. Timing/order edits refuse
drafts with timed narration or cutaways rather than shifting those tracks.

Chat does not infer rooms, recognize speakers, choose visually best shots, create
music, clone a person or generate new camera angles. **Sound & captions** supplies
separate explicit music import, reviewed beat cuts, subtitle import and optional
source-verified speech analysis. Speaking-passage suggestions quote transcript
evidence; they do not judge the picture or verify property facts. Reviewed captions
map source time through trim, split, reorder and speed changes. Existing AI tools
and the prompt library remain available under More tools.

## Saving and continuity

**Local video** saves draft metadata and recent chat in this browser, scoped to
the current user/workspace. Originals are kept in scoped browser storage when
available and verified before restoration. Browser storage can be cleared or
evicted, so keep the source files. This local state is not cloud backup.

**Save project to account** creates a named private video project and explicitly
uploads its originals. After that save, project changes and added media sync to
the account/workspace. The status distinguishes saved edit instructions from
completed uploads. Another browser can restore the project, conversation, video,
photos and music after exact integrity checks. Archive and conflict recovery are
explicit; archive does not delete originals or free storage. No property is required.

For a **property edit**, the recent conversation and current draft are saved in
one existing private `studio_documents` payload using its revision/CAS protocol.
Sources use the existing property upload and hash verification path. A second
browser can restore the saved draft, chat and uploaded originals. This remains
one private edit per user/property, alongside the separate named-project workflow.

The optional `conversation` field contains schema version 1, the matching draft
ID and up to 24 plain-text messages. Legacy documents without this field remain
valid. Malformed or cross-draft histories fail validation. Earlier-copy recovery
preserves paired chat. Existing source privacy, versions and review permissions
remain authoritative. Conflicts retain local work and require explicit recovery.

Capture plans, narration/setup helpers and team versions/review are expandable
sections below the editor. Existing entry URLs and phone handoffs still work.
General named projects stay private and do not enter property review. Native
**Save setup** is a supported-settings handoff, not synchronization of every
desktop timeline or music control. See [projects and finishing](projects-and-finishing.md)
for limits, large-video editing copies and restoration behavior.

## Optional text services

The new handlers are part of the authenticated `studio` edge function:

- `GET /studio/edit-plan` and `GET /studio/prompt-enhancement` report availability.
- `POST /studio/edit-plan` proposes finite operations against a particular draft
  revision; the browser validates them again before applying them.
- `POST /studio/prompt-enhancement` returns a text proposal only.

Both default to disabled. Activation requires all of:

1. `STUDIO_EDIT_PLANNER_ENABLED=true`.
2. `STUDIO_EDIT_PLANNER_MAX_ESTIMATED_CENTS` greater than zero and no more than 10.
3. A separately configured, enabled and eligible `ai_routes` row for each wanted
   task: `copy.edit_plan` and/or `copy.prompt_enhancement`. Unit must be `call`,
   and its positive estimated cost must fit the configured ceiling.
4. An eligible OpenAI or Anthropic model and its server-only provider credential.

Current source includes an idempotent route-seed migration for absent text tasks.
It preserves existing routes and never sets environment secrets or the router
master flag. The earlier recorded release had these services disabled; only a new
activation receipt establishes that they are live. There is no implicit model
fallback. Authenticated local creations can use an enabled text
route without first making a property; property edits additionally authorize the
listing. Role, membership, workspace deletion and account deletion are checked.

Every POST needs a new UUID Idempotency-Key. Duplicate submission is suppressed,
not replayed. Requests are bounded to 24 KiB, recent history to eight turns of
1,200 characters, output tokens to 1,600, and one provider dispatch to 30 seconds.
The client preserves the full current 2,000-character brief and drops older
history as needed to fit the byte budget, including multibyte text.

User/workspace/global rate limits and estimated attempt ledger records apply, including
uncertain outcomes. The estimate ceiling is **not** a provider invoice or an
atomic dollar-budget reservation. Paid retries and chain failover are absent.
Output is parsed into strict bounded structures; the model cannot publish,
upload, execute tools, change source identity or dispatch a generation job.

Higgsfield/Presenter generation remains disabled under the owner's prior
instruction. These text routes do not change that decision or the spatial budget.

Speech analysis is enabled separately and accepts an authorized saved property
video or a completed owned account-project original. It never uploads local
footage implicitly. The server verifies source identity, bounded bytes/timing and
current access, then returns reviewed word timing and passages. For exact flags,
route values, price estimates and live smoke cases, use [editing intelligence
activation](editing-intelligence-activation.md).

## Verification and release

Offline tests exercise actual React editors and the edge handler with synthetic
identities/media/providers. Real H.264/AAC files are exported and decoded to check
duration, shot order, transition pixels and continuous original audio. Browser
tests also cover media import failure, stale planner replies, navigation,
account/workspace changes, prompt preview/acceptance, source restoration and
conversation/draft CAS conflicts.

Project and finishing fixtures additionally exercise separate-browser source
restoration, account isolation, conflict copies, real encoded music mixes,
caption pixels, beat/passage Undo and explicit large-video editing copies. These
are software checks with synthetic media, not real-camera acceptance.

CI runs conversation export tests in Chrome on macOS because the locked Linux
Chromium lacks the required H.264/AAC encoder combination. The full App shell
fixture also runs in the normal Linux Studio job. Receipts and screenshots are
retained as CI artifacts.

The Presenter/prompt-library baseline is recorded as deployed. New source adds
named-project, private-media, property-music and text-route migrations; apply only
reviewed pending migrations before dependent handlers and Studio assets. The
updated [backend helper](../../apps/studio/scripts/deploy-backend.mjs) requires
explicit function selection, stages offline by default and verifies live JWT
policy/source readback when `--run` is supplied. Build checks distinguish initial,
signed-in Create and all-tool gzip budgets; see the [Studio README](../../apps/studio/README.md).
Offline tests do not prove live model quality, production account sync, camera
capture or real-person likeness. See the dated handoff for current test results
and delivery status.
