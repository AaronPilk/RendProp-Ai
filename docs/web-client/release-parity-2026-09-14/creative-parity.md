# Creative Studio: implemented workflows and verification

The Creative Studio uses the current account, selected workspace and existing property records. Completed photo/video outputs use the native upload and property-media contracts. Creative drafts and saved narration use account-scoped cloud records; signed download links are refreshed from stored references rather than saved in documents.

## Eight verified workflow groups

| Workflow | Implemented behavior | Browser verification |
| --- | --- | --- |
| Photo Studio | Cloud photo or desktop import; twilight, sky, lawn, declutter, staging and custom edits; edit suggestions and prompt help. The full original is uploaded before generation. The reviewed result saves with original/altered provenance and a property-gallery row. Known altered photos reuse their actual original; an altered file without an original is not offered as an untouched source. | Source upload precedes generation; original and edited asset IDs attach to the existing disclosure; the saved gallery action confirms completion. |
| Scripts and plans | Reviewed property facts, chosen photos, tone and duration drive scripts and ordered shot plans. Saved plans hand actual photo IDs, durations, captions and an explicitly selected saved narration to the editor. Agent-on-camera plans retain a selected uploaded base video, duration, actual timed transcript and cutaways. SRT/VTT import reads original cue times and saves reviewable plain text. | Plan generation/save, disabled handoff while unsaved, optional narration selection, SRT import, actual base-video ID and timed cutaway handoff; source/transcript restore after switching properties. |
| Draft recovery | `creative:<listingId>` stores scripts, shots, chapters, agent-video binding, transcript and cutaways. Browser recovery is scoped to user/workspace/property. A changed cloud revision requires an explicit choice between recovered and cloud drafts. | Local text survives property switches; simulated phone revision cannot be silently overwritten; the chosen version saves normally. |
| Voiceover and captions | Existing native voice catalog and allowance; explicit generation from reviewed text; persisted audio reference, word timings, disclosure, playback/download and SRT export. | One narration request; saved voice appears; captions download; optional editor handoff passes the saved result ID without a capability URL. |
| Generated video | Existing reel, grounded aerial, drone upscale and short declutter APIs. Private server-owned result rows retain recoverable status. Completed MP4s use native upload reservations and immutable completion receipts. Original/result attachment accepts verified video assets rather than the older photo-only RPC. Reel/aerial accuracy review samples actual video frames. | Queued result restores and finishes; output enters shared media; actual sampled fixture frames reach the review API; publication permission follows stored QC. |
| Room chapters | Existing chapter suggestions become editable labels/times; applying them is restricted to a tour whose render job uses the selected source video. | Two suggested chapters are reviewed and applied to the matching tour. |
| Ask Rendprop | Contextual questions use bounded messages, listing facts and media counts. Private access notes and full media are not sent in the copy/coach context. | A next-step question receives a readable answer; copy requests exclude private fixture notes. |
| Responsive navigation | Scoped tool panels, selected property, readable outputs, feedback and resume controls; desktop columns become one column at narrow widths. | 1440px desktop and 390px phone widths; no document overflow or page errors. Tool tabs scroll inside their own navigation strip. |

The shot-plan and agent-plan browser checks exercise the Creative component's real handoff payloads. The editor's compositing/export, continuous base audio, captions and source restoration have their own editor fixture receipts; those are separate from the Creative fixture.

## Edited-output disclosure

`POST /studio/edit-output` finalizes an already completed MP4 against saved source capture/photo IDs and an optional owned narration result. The server resolves source keys from the current property's records, retains known AI visual/narration disclosures, and labels every browser assembly as edited. It does not invent a single untouched original for a multi-source video or certify that client-selected records prove the final pixels/audio.

The private saved result records the selected sources. Known held generated sources cannot be finalized into an apparently ordinary edit. Database publication checks follow nested edits, reject revoked or missing source QC, and retain known visual AI disclosure on the existing app-publish path. The completed edit's provenance cannot be reassigned. A lost reply or interrupted disclosure write resumes the same output record.

Ordinary recorded videos and ordinary browser edits remain free of a false virtual-staging flag. Their edited-media sentence remains visible. The original photo records and any existing per-source disclosures remain independently available.

## Receipts

- [Creative browser fixture](creative-fixture.json): **8 groups passed**, zero external requests and page errors. Includes SRT import, shot-plan and agent-plan handoffs. Screenshots were visually reviewed at both viewport sizes: [desktop plans](creative-plans-desktop.png), [mobile plans](creative-plans-mobile.png). The white photo thumbnails are synthetic fixture images.
- [Creative and overlay unit tests](creative-ui-tests.txt): **17 passed** — 8 creative model checks, 4 subtitle parser checks and 5 timed-overlay/source checks.
- [Creative backend tests](creative-backend-tests.txt): **27 passed** — 11 result/import/recovery checks, 4 QC projection checks, 9 edited-output checks and 3 generated-video provenance checks. The full video-status regression follows a completed provider fixture through the upload gateway, promoted immutable MP4 key, verified original/output attachment and signed saved result.
- [Edited-output SQL checks](creative-edit-output-sql.json): **12 passed** in an isolated local PostgreSQL instance, including execution of the actual native photo-only resolver from migration 0012. The test deliberately verifies that generated video attachment must not use that resolver.
- Earlier generated-quality migration verification: `apps/studio/scripts/test-creative-quality-schema.mjs`, **10 checks passed** for exact source/output/request matching and normal recorded-video behavior.

Reproduce from the repository root:

```sh
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node apps/studio/tests/creative-browser.mjs
deno test --allow-env services/supabase/functions/studio/creative.test.ts services/supabase/functions/studio/creative-quality.test.ts services/supabase/functions/studio/edit-output.test.ts services/supabase/functions/studio/generated-proof.test.ts
node apps/studio/scripts/test-edit-output-schema.mjs
```

Run the 17 frontend unit tests from `apps/studio` with `node --import tsx --test tests/creative.test.ts tests/creative-transcript.test.ts tests/editor-overlays.test.ts`.

Local detailed receipts:

- Browser screenshots and raw receipt: `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-creative-browser-QhFaOV/`
- Backend log: `/tmp/rendprop-creative-backend-tests-20260914.log`
- SQL result: `/tmp/rendprop-edit-output-schema-receipt-20260914.json`

## Concrete limits

- These fixtures generate no paid provider work, invitations, customer messages or public tours. Production account sync/upload/read-back is covered by the release's separate live receipt. Live paid image/video/narration quality and physical iPhone behavior are not established by these fixtures.
- Studio does not automatically transcribe a recorded file. Import UTF-8 SRT/VTT subtitles or review actual phrase start times. Imports are bounded to 256 KiB, 200 phrases, 200 characters per phrase and the selected 6–180 second video; missing timestamps are never invented. Phone speech-recognition hardware remains a native workflow.
- Browser photo framing uses supported still/push/pull/pan motions. Generative camera-motion descriptions require real generated clips; transferring a plan does not secretly dispatch or bill generation.
- Browser narration input is bounded to 1,000 characters. The Edge importer accepts completed MP4 provider results up to 48 MiB; a larger provider output is reported as requiring another import path rather than marked saved.
- An edited MP4 has a source declaration and inherited checks. Its final composited pixels and audio are not independently certified by the source QC verdict.
- Photo previews become shared media only after the explicit gallery-save action. A failed provenance write preserves a downloadable preview but does not claim a successful disclosed gallery save.
- Studio's private video job references survive reload and signing-token expiry for their original account. Direct native jobs created outside that wrapper retain their existing native recovery workflow; their completed uploaded media can still be shared. Historical local-only native files are not uploaded simply by deploying the website.
- New phone cloud-import/setup behavior requires the companion native build described in the main release report. Source media must finish its normal upload before another device can retrieve its bytes. Creative and editor documents preserve semantic intent; they do not reconstruct arbitrary local AVFoundation graphs, camera/RoomPlan capture state or unuploaded audio/geometry.

The Supabase query/write adapters follow the documented [insert/select behavior](https://supabase.com/docs/reference/javascript/insert). The final review also checked the current changelog; no relevant Edge query/insert breaking change required an SDK migration.
