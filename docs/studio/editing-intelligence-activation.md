# Studio editing intelligence: activation and acceptance

Implementation branch: `feat/studio-completion-20260924`. **Activated on 27 September 2026:** bounded AI editing, prompt enhancement and speech analysis passed a signed-in synthetic production smoke. The [release receipt](../handoff/CODEX-STUDIO-COMPLETION-20260927.md) records deployment, checks, estimated test costs and remaining acceptance limits. The historical inventory below preserves the preactivation state.

## What is implemented

`/studio/edit-plan` turns a bounded text request and edit metadata into a proposal using supported editor operations. `/studio/prompt-enhancement` improves a brief before the user submits it. Both use the existing model router, enforce one provider attempt, validate the answer, and preserve the current edit on errors. They do not inspect pictures, listen to audio, generate a presenter, or publish a reel. Music and reviewed source speech survive supported timing changes; this does not give the text model an audio mixing capability.

`/studio/media-analysis` transcribes one authorized, saved video from a property or a private account project. It returns word timing, source SHA-256, source duration, transcript segments, and up to five speaking-passage suggestions. Every suggested range and quotation comes from those words. These are speech suggestions, not visual shot rankings or verification of property claims. The user reviews wording before applying captions. A finished render is supported by the backend source resolver; the current CloudEditor integration submits uploaded capture-asset IDs.

For a named project, choose **Save project to account** and let the original finish uploading before transcription. Analysis never implicitly uploads local footage. The client looks up its saved source by hash, then sends only `{source_kind:"project_media",source_id:"…"}`. No listing is required. The server independently checks the exact actor, workspace and source, assembles only its server-owned immutable chunk keys, verifies each chunk and the full source SHA, and rechecks account/source authorization before and after the provider call. Knowing another user's same-content hash does not grant access.

Imported music uses private project-media chunks and an explicit property attachment. **Save music with property** uploads and attaches it before shared review or finished property delivery. Restoring a file verifies every chunk and the full SHA-256. Missing music blocks completion rather than silently exporting a different soundtrack. Selecting and uploading a track declares the user's permission; the application does not provide a music license.

## Historical read-only inventory — 24 September 2026

Project: `ymgqpbnjpztwjsyvceld`.

| Item | Observed state |
| --- | --- |
| `app_config.ai_router.enabled` | `true` |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` | Secret names present; values not read or printed |
| `copy.edit_plan`, `copy.prompt_enhancement` route rows | Absent |
| Four Studio enablement/price variables below | Absent |
| `stt.captions` OpenAI route | Enabled; route ID `0397c407-ce9a-4f51-880a-da7e8b326826`, `whisper-1`, `unit=minute`, `unit_cents=0.6000`, capabilities `stt,word_timestamps`, minimum plan `free`, privacy `retained_30d` |
| `HIGGSFIELD_API_KEY` | Absent; presenter generation remains disabled |

This table is historical: the text routes and four Studio variables were added in the 27 September rollout. An enabled generic copy or speech route alone does not enable the Studio endpoints. The app reports unavailable unless the explicit flags, eligible route, provider secret, writable account and entitlement checks pass.

## Activated configuration — 27 September 2026

The reviewed migration, Studio edge function v12 and matching website were deployed before the four bounded enablement variables were set at approximately 14:15 UTC. No unrelated routing rows were changed. For future releases, retain that schema → handler → website → activation sequence.

CLI migration `20260924235553_studio_editing_intelligence_routes.sql` seeds each absent task with an explicit route using the already deployed Anthropic adapter. It preserves any existing task rows, including disabled routes or nonstandard positions, and never changes the router master flag or any edge-function secret:

| Field | Activated route value |
| --- | --- |
| `provider` / `model` | `anthropic` / `claude-sonnet-5` |
| `position` | `1` |
| `unit` / `unit_cents` | `call` / `8` (conservative estimate, not measured invoice cost) |
| `capabilities` | `["text", "compliant"]` |
| `min_plan` / `privacy_tier` | `free` / `retained_30d` |
| `max_latency_s` | `30` |
| `params` | `{"effort":"low","max_output_tokens":1600}` |
| `enabled` | `true` in the route table; the separate Studio endpoint gates were enabled on 27 September |

The applied bounded activation values are:

```text
STUDIO_EDIT_PLANNER_ENABLED=true
STUDIO_EDIT_PLANNER_MAX_ESTIMATED_CENTS=8
STUDIO_MEDIA_ANALYSIS_ENABLED=true
STUDIO_MEDIA_ANALYSIS_MAX_ESTIMATED_CENTS=3
```

The two text features share the planner flag and allowance. Speech uses the existing eligible `stt.captions` Whisper route; no second speech route is necessary. Configuration values outside the code's allowed finite range fail closed. Keep Higgsfield/Presenter disabled.

For rollback, set the two `*_ENABLED` variables to `false`. Local editing, music mixing, existing files, manual captions and caption-file import remain available. A flag change cannot retract a request already accepted by a provider.

## Pricing and limits

Official sources checked for this work: [Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing) and [OpenAI Whisper pricing](https://developers.openai.com/api/docs/models/whisper-1). The activated Sonnet 5 route uses $2 per million input tokens and $10 per million output tokens. Whisper is $0.006 per minute. Recheck prices before activating a different model or publishing customer pricing.

The text request is limited to 24,576 UTF-8 bytes and 1,600 output tokens; the larger system prompt currently adds 4,039 bytes. A conservative byte-as-token input allowance is 28,615 × $2 / 1,000,000 = $0.05723, plus 1,600 × $10 / 1,000,000 = $0.016 for output: $0.07323 total, with margin to the 8-cent estimate for framing. Ordinary requests are smaller. Existing ledger integration records the configured route estimate, not invoice token usage. Do not present an 8-cent ledger entry as an actual measured charge. Recalculate the estimate when prompt or output ceilings change.

Text requests share limits of 12 per user per five minutes, 60 per user per day, 60 per organization per five minutes, and 100 globally per day. At the configured route estimate the global daily allowance is $8. A duplicate actor/organization/request UUID is rejected for 24 hours. Rejected requests may still consume a rate-limit reservation; they never trigger automatic paid retries.

Speech accepts a complete MP4/MOV with one embedded audio track, at most 24,000,000 bytes and 300 seconds. The server checks the movie header, audio header and sample timing, rejects fragmented files and external audio references, and compares provider duration to source duration. This is bounded container validation, not a full independent media decode. Word output is capped at 1,500 words and provider JSON at 256 KiB. The upload guide's [25 MB limit and word-timestamp contract](https://developers.openai.com/api/docs/guides/speech-to-text) are why this endpoint uses `whisper-1`, multipart bytes, `verbose_json`, and `timestamp_granularities[]=word`.

A full five-minute job has a 3-cent estimate at the current Whisper price. Speech limits are six per user per hour, 24 per organization per day, and 100 globally per day: at most $3 in global daily estimates. Actual invoice charges remain the provider's billing record. A cancelled, timed-out or invalid-answer attempt is still recorded once with an uncertain/returned outcome; no automatic resubmission occurs. The limits above are unrelated to the spatial experiment budget.

## Music sharing and withdrawal contract

Music stays private until explicitly attached and selected in a submitted property reel. Knowing another user's SHA-256 is insufficient to download, attach, finalize or submit their track. Review preview requires the exact current submitted revision and rechecks authorization after signing.

An explicit **Copy** creates an independent private snapshot and a narrow grant for only its selected music, tied to that immutable source version. A later withdrawal or private revision prevents new review reads and new copies. It does not rewrite an already completed recipient copy. This matches the existing copied narration behavior. Original source deletion, account deletion, binding/version deletion, or loss of current property/workspace access prevents further access. Already downloaded files or unexpired short-lived signed URLs cannot be retroactively erased from a browser.

The migration also fixes a pre-existing copy gap: another account cannot create a new copy merely by remembering an old submitted revision after the author withdraws or edits privately. Source-document and review locks serialize this decision with withdrawal. The author may still restore their own history without re-sharing it.

## Completed production smoke and remaining acceptance

The 27 September signed-in Chrome smoke used a dedicated synthetic saved project. Two originals completed upload, their expected hashes matched the database, and the UI reported actual AI enhancement/editing. Enhancement preserved a quoted title and only filled the composer after acceptance. A compound square-format/reorder/title edit worked, with Undo/Redo verified. Whisper returned all 12 expected words from a 15-second saved source; applying captions required explicit transcript review. A downloaded 960×960 H.264/AAC MP4 was 9.009533 seconds, with visible title/caption and the expected silent and spoken segments.

The final ledger contains **four successful single-attempt calls totaling 24.15 cents ($0.2415), estimated**: three 8-cent Sonnet text calls and one 0.15-cent Whisper call. Every row is marked `price_estimated=true`; the total is not a provider invoice. The unsupported overhead-generation request returned a clear capability limitation and did not fabricate an edit. Full-page reload and selection of the QA project restored its two source files, 1:1 nine-second edit and saved conversation. The QA project is intentionally retained for review.

These checks used the existing browser session. Fresh Apple OAuth, physical-phone capture, second-browser production restoration, second-account agency music-copy/withdrawal and every property-source variant were not certified by this smoke. Fixture and local PostgreSQL coverage for those boundaries is recorded separately, including isolated cross-browser restoration. Final CI passed 12/12 jobs for `e5632ff` in run `36325429637`. Presenter generation and spatial activation remain off.

## Reusable acceptance checklist

Offline tests use injected responses and synthetic media; they make no provider calls. They cover exact source authorization, SHA binding, timing and output bounds, cancellation, single-attempt accounting, private music isolation, copy grants, output disclosures, and withdrawal. Run the fresh PostgreSQL migration fixture and production-review regressions as well as Deno/frontend checks against the final combined branch.

For future changes or broader acceptance, use small explicitly tracked live checks with authorized assets and record request IDs, returned proposal, outcome and ledger estimate. The completed smoke above does not claim that every item in this broader checklist has run in production:

1. Check signed-in availability for all three endpoints. Unauthenticated calls must fail, read-only members must remain unavailable, and capability reads must not create ledger charges.
2. Request a multi-part edit such as square format, moving clip two first, and an exact quoted title. Inspect the proposed supported operations, unchanged source IDs and draft revision. Apply explicitly and confirm undo. Include one unsupported generation request and confirm a truthful unsupported answer rather than a fake edit.
3. Enhance a brief containing an exact price, date, quoted title and a negative instruction. Check that protected details and intent survive. Enhancement must remain editable text, not automatic execution.
4. Analyze a short owned recording with a known spoken sentence from both a saved property source and a saved private account project. Confirm a local-only project instead asks you to save first. Compare downloaded SHA, container duration and word timing; review names and numbers against the actual audio. Confirm source-time captions stay aligned after trim, split, reorder and speed changes. No camera is needed to validate a supplied recording.
5. Replay the same request ID and confirm one provider attempt and one cost entry. Abort a separate request once and confirm the UI preserves the edit and never retries automatically; an accepted request may still be charged.
6. Save imported music, reload on another signed-in browser, review and copy with a second permitted account, export, and listen to the resulting audio. Withdraw the author's review: new recipients must be denied while the already copied edit remains independent. Then revoke membership or delete the original source and confirm new access is denied.

Record real phone capture and spatial quality acceptance separately. Passing these editing checks does not establish camera quality, geometric accuracy, an agency's aesthetic quality, or permission to enable presenter generation.
