# Creation-first Studio and prompt enhancement — 24 September 2026

Branch: `feat/conversational-studio-20260924`.
Base: `7d96e93` on `feat/agent-presenter-20260924` (draft PR #6).
Checkout: `/Users/pilksclaes/Rendprop AI/conversational-studio-20260924`.

**Built and verified offline. Not deployed.** This is a stacked change; main was
still `d14cc1b` and PR #6 unmerged when packaging started. No production resources,
Higgsfield settings, spatial code/flags, iOS files or App Store Connect changed.
No live provider calls, media uploads or spend. Shared checkouts were untouched.

## What the user asked for

Make content creation the obvious primary workflow: upload media, type a brief,
see the real video draft, refine through chat. Retain the professional tools but
remove the large collection of setup panels from the initial view. The user then
explicitly added a prompt-enhancement feature.

## Result

- Create is the default page, with four primary navigation destinations. Home,
  AI tools and Content planner are under More tools. Existing URLs still work.
- Local creation needs no property. Property-linked edits retain account sync.
  The distinction is visible, and switching does not silently move/upload media.
- Chat is attached to the actual existing editor/renderer. Supported operations
  change timing, order, supplied text, photo motion, transitions, ratio and sound.
  One message produces one undoable revision. Manual views share that same draft.
- A brief can precede media; it waits for successful import. Failed imports,
  impossible timing, unsupported requests and stale replies preserve the draft.
- **Improve prompt** proposes wording with original/proposal review, Use this
  prompt and Keep original. Acceptance only fills the composer; Send remains a
  separate action. Guided enhancement verifies equivalent edit results. Optional
  AI enhancement is configured separately and also proposes text only.
- Conversation and property edit save in one CAS payload. Recent chat has 24
  bounded text messages, matched to the draft ID. Old documents remain compatible.
  Local chat is scoped browser storage, not a new account-synced project store.
- Capture plans, setup helpers, versions and reviews are expandable below Create.
  Existing phone/native-recipe/Presenter handoffs and export behavior remain.

See [the workflow and exact activation contract](../studio/conversational-creation.md).

## Text services and limits

New authenticated `studio` endpoints are `/edit-plan` and `/prompt-enhancement`.
Their model routes are `copy.edit_plan` and `copy.prompt_enhancement`.
Both are **disabled by default**. No route or flag was inserted/enabled.
Activation needs explicit eligible route pricing and the documented
`STUDIO_EDIT_PLANNER_*` configuration. Higgsfield generation remains off under the
owner's existing instruction; these text routes cannot turn it on.

Metadata-only requests omit original source filenames, fingerprints, URLs and
bytes. User-supplied prompt text is included. Auth, deletion, membership, role,
listing scope, rate limits and UUID retry suppression are enforced. There is one
bounded provider request, no retry/failover, and estimated attempted-call ledger
recording. This is **not a hard dollar reservation or invoice proof**.

The client validates finite edit plans again and rejects changes to a newer
draft. Enhancement responses match the exact original text; acceptance also
checks the original draft revision. The backend validates quote/number fidelity
and rejects fields that could request actions. This cannot prove all semantic
fidelity; the user reviews the proposal before sending.

## Verification

- Studio: **376 unit tests**, TypeScript, build and asset checks passed. Final
  JavaScript gzip total: **293,826 bytes / 300,000 ceiling**.
- Studio edge folder: **157 Deno tests passed**, one existing owned-Postgres
  integration test ignored outside its dedicated environment. The new endpoint
  subset contains **31 tests**. Entry-point typecheck passed. HTTP, identity,
  storage and provider calls are fixtures, with no network permission.
- Conversation browser: **16 grouped checks**, including seven for prompt
  enhancement: preview/use/send, dismissal, unresolved intent, mocked AI, cancel,
  malformed answers, stale draft and account replacement. Real synthetic MP4
  output is H.264/AAC; decoded order/transitions and original 660 Hz audio verified.
- Cloud editor: **16 grouped checks**, including paired chat/draft writes, second
  browser restoration without another upload, and remote conversation conflicts.
  Real 3.03-second H.264/AAC output, dissolve/whip pixels and continuous narration
  verified. Agent cutaway export retains continuous original audio.
- Shell **6**, connected **8**, property reels **7**, production/review **10**,
  guided recipes **4**, Presenter navigation **4** browser groups passed. The
  account refresh negative control still fails for its intended regression.
- Desktop/mobile screens were visually inspected. All browser fixtures reject
  external requests. CI includes the new shell and conversation/MP4 checks and
  retains their receipts/screenshots.

Final local evidence under the system temporary directory:

- `rendprop-conversation-qgHop0/receipt.json`
- `rendprop-cloud-editor-kW6uW2/receipt.json`
- `rendprop-creation-shell-LMCaaN/receipt.json`
- `rendprop-connected-browser-9E5DMZ/receipt.json`
- `rendprop-property-reels-2Op5wS/receipt.json`
- `rendprop-production-94SXeH/receipt.json`
- `rendprop-guided-recipes-GOXOGe/receipt.json`
- `rendprop-presenter-app-Fp45S4/receipt.json`

One review found that 2,000-character messages overflowed the old 1,200-character
history contract. The new request builder preserves the full current brief,
truncates older turns, and drops oldest history until UTF-8 JSON fits 24 KiB.
Cross-layer tests pass the actual browser builder into the actual backend parser.
Capability availability is bound to the latest scope/activation so returning to
a workspace cannot briefly inherit its earlier enabled state.

### Export timing caught by CI

The first GitHub run (`36050431489`) passed eleven jobs but failed the macOS media
gate: its three-second narrated mixed-media edit exported as 3.4944 seconds.
The original duration threshold was retained. A controlled reproduction delayed
only delivery of each `resume` event by 250 ms; the old exporter then produced
3.530933 seconds. It awaited the notification after capture had already resumed,
recording idle time before starting the next clip's clock.

The bounded fix calls `resume()` and requests a frame without awaiting that
notification, matching the existing `start()` handling. It retains the pause
barrier before disposing source media, original source spans, playback speed and
audio path. The [MediaRecorder specification](https://www.w3.org/TR/mediastream-recording/#dom-mediarecorder-resume)
sets recording state synchronously and queues the capture/event work.

`tests/export-resume-browser.mjs` builds the actual fix and a test-only restoration
of the old await. Both receive the same delayed notifications. It checks encoded
duration, transition pixels, narration, photo-leading silence and a distinctive
opening sound in the first 0.15 seconds of the video to catch clipped speech.
Cloud export receipts now include native recorder/media/audio timing and full
ffprobe details before assertions; CI retains actual synthetic MP4 artifacts.
The browser exporter remains real-time and is not a frame-exact offline renderer.

The four-check differential regression passed at
`rendprop-export-resume-uiZnD6/receipt.json`: negative-control durations were
3.5673/3.556733 seconds, corrected durations 3.066867/3.050767 seconds
(narrated/original audio). The corrected opening window retained its distinct
990 Hz tone with RMS 0.113; leading silence, later 440 Hz audio, 660 Hz narration
and decoded dissolve/whip frames passed. The existing sixteen-check cloud export
fixture also passed after the fix at `rendprop-cloud-editor-DW6k5q/receipt.json`.

## Delivery and remaining release work

No new database migration in this branch. Do not blindly deploy the combined
stack: PR #6 has four unpublished migrations and a documented preexisting
production-review migration-history mismatch (`20260924153826` filename versus
`20260924165200` live ledger). Follow its handoff and schema/read-handler sequence.

No live model quality trial, production same-account phone/web test or camera test
was performed. The chat is intentionally bounded: no room/speech understanding,
automatic music, digital presenter generation, silence removal, arbitrary effects
or new camera angles. Unsupported wishes remain visible instead of being reported
as completed. Optional model routes require configuration and controlled quality
evaluation before enabling. UI/offline completion must not be described as a
deployed or fully validated AI production system.
