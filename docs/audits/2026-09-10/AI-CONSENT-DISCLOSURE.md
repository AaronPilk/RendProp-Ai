# AI consent disclosure: source audit and bounded correction

Date: 2026-09-10. Audited source: `audit/full-regression-20260910` at
`7d0b0ca3ab7fb579348480e40c43f89d5c222e31`. Line references below refer to that
immutable baseline unless labelled changed. No production requests, dashboard,
provider calls, credentials, Apple actions or customer media were used.

## Findings established by source

1. **Wrong model attribution and missing intermediary.**
   `apps/ios/Rendprop/RendpropApp.swift:2967–2970` places Seedance in Google's
   card and lists Topaz without fal.ai. `services/supabase/functions/ai-video/index.ts:604–607`
   identifies Topaz, Bria, Veo and `bytedance/seedance`; `:656–675` makes the
   video fallback provider **fal**. `:1298–1328` and `:1493–1522` select and
   submit aerial/reel routes. `_shared/providers/fal.ts:79–142,254–263` sends
   the media/prompt to `queue.fal.run`, not directly to Google or Topaz.
   Name fal.ai as the service and distinguish its model families from recipients.
   Model namespace/seed attribution is source evidence, not proof of the
   reseller's internal subprocessor transfers.

2. **The global “photos and videos are never sent to Anthropic and OpenAI”
   statement is false.** `RendpropApp.swift:2971–2972` is contradicted by
   `Screens/FlythroughDetailView.swift:4385–4392`: the actual animation flow
   sends the source photo and sampled generated-clip frames for a quality check.
   `Networking/LiveAPIClient.swift:1018–1040` serializes those bytes;
   `ai-video/index.ts:1596–1638,2225–2244` constructs the judge's image parts.
   Its hardcoded fallback is Anthropic (`:2101–2137`); `:2154–2179` supplies
   images to Anthropic or OpenAI. Migration `0018_ai_routes.sql:431–438` seeds
   both. This is images extracted from video, not evidence that this route
   uploads the complete original movie to those two providers.
   In addition, `ai-photo/index.ts:631–671` routes actual photo bytes to the
   selected adapter. Enabled seed rows `0018_ai_routes.sql:298–317` include
   OpenAI photo editing; `_shared/providers/openai.ts:313–329` submits the
   actual image and optional mask to `/v1/images/edits`.

3. **The blanket street-address/name/email/phone/location promise is not
   enforced.** `RendpropApp.swift:3101` promises “never” while:

   - `FlythroughDetailView.swift:8359–8362,8467–8476` replaces `{address}` in
     generated copy with the listing address, storing the filled `aiScript`.
     `:8514–8529` then submits that script for AI narration.
     `LiveAPIClient.swift:1080–1092` and `ai-voice/index.ts:618–633,661–670`
     forward it to ElevenLabs. This ordinary two-action flow disproves the
     promise even without adversarial input. Address exclusion from the
     earlier copy-model request does not carry through to text-to-speech.
   - `Coach/CoachModel.swift:144–147` sends chat history verbatim;
     `coach/index.ts:182–194` trims/bounds it, but does not redact PII.
     `coach/prompt.ts:221–232` includes that text in the provider prompt,
     dispatched to Anthropic/OpenAI at `coach/index.ts:283–304`.
   - `ai-photo/index.ts:508–514,593–600` embeds custom text in the prompt.
     `ai-video/index.ts:799–808,1242–1252` bounds region/style and rejects a
     leading house-number pattern, not all addresses or contact information.
     Fair-housing validation is not a general privacy scrubber.
   - Selected media can visibly contain addresses, people or documents. The
     traced media submission paths do not establish automatic privacy removal.

   Do not turn this into an unsupported claim that GPS metadata is definitely
   forwarded: this audit did not establish that. Likewise, do not resurrect the
   older Coach exact-address-context defect: **current**
   `CoachModel.swift:199–205,235–272` removes leading house numbers and suffix
   components for automatic project labels. It deliberately preserves street
   labels; it is not a universal PII detector for arbitrary project names.

4. **ElevenLabs and several data uses are missing.** The three cards omit
   ElevenLabs, despite the unconditional TTS call at `ai-voice/index.ts:649–670`.
   The “what we send” list also omits scripts/transcript excerpts, chat history,
   project context and quality-check frames. `ai-copy/index.ts:799–832,893–917`
   sends writing/planning requests, not just Coach text. Its supported text
   providers include Anthropic, OpenAI and Gemini (`:360–389`).
   `ai-chapters/index.ts:518–562` uploads walkthrough video to Gemini for
   chapter analysis. These are disclosures, not claims that every tool uses
   every provider or that AI quality checks prove room fidelity.

## Source-backed recipient inventory

| Service in corrected consent | Data/use supported in this baseline |
|---|---|
| Google (Gemini) | Photo edits, video analysis, writing assistance. `ai-photo/index.ts:476–489,631–671`; `ai-chapters/index.ts:536–562`; `ai-copy/index.ts:389`. |
| fal.ai | Selected media/prompts for generated video and edits. Models represented by code/seeds include ByteDance Seedance, Google Veo, Topaz Labs, Bria, FLUX and MiniMax Hailuo. `ai-video/index.ts:604–607,1158–1164`; `_shared/providers/fal.ts:79–170`; `0018_ai_routes.sql:267–317,324–373`. |
| Anthropic and OpenAI | Chat/context, writing requests, source photos/generated-clip frames for checks; OpenAI photo editing. Evidence above. |
| ElevenLabs | Narration script, including an address or other details it contains, plus selected voice. `ai-voice/index.ts:635–670`. |

**Seeded is not live.** `router.ts:258–308` reads mutable database routes and a
feature flag; `chain.ts:57–65,79–92` supplies fallback and may try another
provider after an eligible failure. No live flag, row, secret model override,
actual provider choice, credential availability or deployed code was checked.
MiniMax's seeded 768p reel fallback is filtered out by the current 1080p caller
(`ai-video/index.ts:1503–1508`); naming it as an available model family does not
claim it runs for that caller. Kie/Higgsfield adapters exist, but their relevant
rows are seeded disabled (`0018_ai_routes.sql:327–330,342–365`); no changes to
them are authorized or made. Adding a different recipient requires owner review
and updated consent, not reliance on this static inventory.

## Exact implemented replacement copy

Title remains “Rendprop's AI runs in the cloud”.

Intro: “Cloud AI tools send the media, text and project context needed for your
request through Rendprop's servers to the providers below. Some tools use more
than one provider, including for quality checks or fallback.”

- **Google (Gemini):** “Receives photos, video or text for photo editing, video
  analysis and writing assistance.”
- **fal.ai:** “Receives photos, video and prompts for AI edits, generated clips
  and upscaling. Available models include ByteDance Seedance, Google Veo,
  Topaz Labs, Bria, FLUX and MiniMax Hailuo.”
- **Anthropic and OpenAI:** “Receive chat, project context and writing requests.
  Quality checks can also send source photos and frames from generated clips;
  OpenAI can edit photos.”
- **ElevenLabs:** “Receives your voiceover script, including any address or
  personal details in it, and your selected voice to generate narration.”

First bullet: “What we send depends on the tool: selected media and sampled
frames, edit prompts, chat history, project context, script text and transcript
excerpts. For aerials, enter only city and state in the region field.”

Second bullet: “Review before sending: media can show people, addresses or
documents. Text and project labels can contain personal information. Remove
anything you do not want processed by these providers.”

Third bullet: “These services process what is sent to return your result.
Rendprop does not sell your media and does not use it for advertising.”

The existing Rendprop business-policy statement is retained, not newly inferred
from code. No provider retention, no-training, deletion deadline, anonymity or
legal-compliance assurance is added. Agree, decline, Settings revocation and
the existing non-AI fallback explanation remain present; layout/IDs unchanged.
Consent v2 must be required even if a v1 grant exists because this materially
corrects which recipients and data were disclosed. Historic test receipts stay v1.

## Still open — not fixed by an iOS copy patch

- `services/edge/tour-host/src/legal.ts:295–298` already discloses Anthropic
  media QC, contradicting the old app card, but omits OpenAI and ElevenLabs.
  `:287–288,299–302` also asserts provider-purpose restrictions that this source
  audit cannot validate. Privacy HTML and its publication are **unchanged**.
- `legal.ts:283–284` no-training wording, router `privacy_tier` annotations,
  and fal's requested 24-hour output-object lifetime
  (`_shared/providers/fal.ts:35–37,262`) are not proof of actual training,
  retention, abuse logs, input storage, subprocessors, region or deletion terms.
  The lifecycle header is a request, not an all-data retention guarantee.
- Owner must reconcile the published Privacy Policy, commercial agreements,
  account-specific settings and current enabled/legacy routes. Do not enable
  disabled vendors to match a broader disclosure. Do not represent static copy
  as a dynamically enforced recipient allowlist or server-side consent ledger.
- Misleading source comments remain outside the narrow UI patch, notably
  `FlythroughDetailView.swift:8452–8459` claiming local substitution keeps the
  address from every third-party model, and `coach/prompt.ts:70–71` calling an
  address safe to send. This unit does not alter data processing.

## Verification and limits

Production diff is limited to `RendpropApp.swift` disclosure strings/comments
and the v2 key. The eight current XCTest launch sources, current UI-test README
and reviewer-script comments now reference v2; their interaction logic and all
historic receipts are unchanged. The two new files in `tests/phase1/` live
outside the app target. No server or privacy HTML file changed.

Commands from the worktree root, with actual results:

- Before the production change:
  `node --test tests/phase1/consent-disclosure.test.mjs` — **exit 1**, 0 pass,
  5 fail, 0 skipped. Includes the real extracted v1 class accepting the old
  saved grant instead of requiring a v2 decision. Log:
  `/tmp/rendprop-consent-audit.9Bjhgi/before.log`.
- After:
  `node --test tests/phase1/consent-disclosure.test.mjs tests/phase1/consent-contract.test.mjs`
  — **exit 0**, 9 pass, 0 fail, 0 skipped. Four existing structural UI guards,
  four new copy/key/launch-fixture contracts, and one compiled behavioral test.
  The latter extracts the exact production `AIConsent` class (no body rewrites),
  imports real Foundation/Combine, and substitutes only the storage access with
  a new UUID-named **real Foundation UserDefaults suite**, never the app's
  defaults. It performs **24 assertions across three processes**: v1-only
  requires consent; grant persists v2 and resumes callers; a new process loads
  the grant, revokes it; another process loads the revocation, declines and
  cancels without granting. The deliberate unknown-scenario control exits **1**.
  Log: `/tmp/rendprop-consent-audit.9Bjhgi/final.log`.
- `/usr/bin/swiftc -frontend -parse` on `RendpropApp.swift` and all eight edited
  XCTest Swift files — **exit 0**, empty diagnostics. Syntax only, not iOS SDK
  type checking, app linking, Xcode build or UI execution. Exact invocation in
  `/tmp/rendprop-consent-audit.9Bjhgi/verify.sh`; output `parse.log` beside it.
- `git diff --check` — **exit 0**. The explicit `FAIL=1` / `exit "$FAIL"`
  verification wrapper above finished **FINAL exit=0**. Its symbol checks run
  before test/parse commands. Whole-tree `git grep` of the old key identified
  the current fixtures; no v1 reference remains in app/current XCTest source.
  The new behavioral test intentionally retains v1 as the migration fixture.

Final compiled evidence:
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-consent-policy.UPNbQF/`
contains the mechanically extracted class, test harness and executable.
The test's new preferences suite is
`com.rendprop.offline-consent-tests.225b62bb-f7ff-4cba-aeeb-deaacab0275f`.
Test-only preferences/artifacts are retained; no existing preferences or files
were deleted. This proves macOS Foundation persistence of the extracted
controller, not the iOS app's storage container or UI lifecycle.

No UI, accessibility, font-layout, physical-device, live-provider, retention or
App Review result is established by this audit. A freshly rebuilt focused
consent UI gate is required after the copy grows; do not reuse screenshots of
the previous binary as proof. The Supabase skill's changelog check used
<https://supabase.com/changelog> after the markdown endpoint was unavailable;
no relevant platform implementation change was made. The Cloudflare skill was
used only to identify and read the existing legal-page source, not deploy it.
