# Rendprop Studio

Rendprop's browser creation workspace is live at [studio.rendprop.com](https://studio.rendprop.com/).
It uses React, TypeScript, the app's branding, and the same Supabase account and
workspace model as iOS. **Create** is the default destination; My homes/spaces,
Media and Business remain primary navigation. Home, AI tools and Content planner
are available under More tools.

The [24 September production record](../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md)
is the latest deployment evidence. It supersedes the pre-release status in earlier
handoffs and the September 14 screenshots. This README also describes newer
source for projects, sound, captions and editing copies. Those additions await a
new production receipt; provider activation and native releases have separate gates.

## Create, refine and export

Add photos or videos, describe the edit, review the real draft, and refine it.
Chat, Simple and Pro views share the same editor. Guided chat supports timing,
clip order, supplied titles/captions, photo motion, transitions, aspect ratio and
sound. Each accepted chat instruction is one undoable revision. A brief entered
before media waits for successful import.

**Improve prompt** shows the original and proposed wording. **Use this prompt**
only fills the composer; **Send** applies the request. Guided enhancement runs
locally and checks equivalent edit results. Unsupported requests remain visible;
it does not invent room recognition, speech understanding, arbitrary effects,
new camera angles or completed generation.

**Sound & captions** adds imported music with trim, offset, volume, fades and
ducking; reviewed beat-cut proposals; timed subtitle import; and optional source-bound
speech captions and speaking-passage suggestions. Chat can adjust the music mix.
**Large video? Create an editing copy** prepares a local 720p H.264/AAC copy before
an explicit preview/import. These tools do not replace the original on the device.

The prompt library contains ten original recipes, scene/timeline adaptation,
custom collections, source links and test feedback. Property workflows also
include shared capture plans, saved versions, review/approval and native handoffs.
Setup and review controls are expandable below the editor.

- [Conversational creation and enhancement](../../docs/studio/conversational-creation.md)
- [Agency production workflow](../../docs/studio/agency-production-workflow.md)
- [Named projects, finishing and editing copies](../../docs/studio/projects-and-finishing.md)
- [Prompt library](../../docs/studio/prompt-library.md)
- [AI Presenter and activation requirements](../../docs/studio/ai-presenter.md)

**The recorded production baseline has model-powered edit planning and prompt
enhancement disabled.** Current source seeds bounded text routes and implements
speech analysis; deployment and explicit activation remain separate steps. See
[editing intelligence](../../docs/studio/editing-intelligence-activation.md) for
the configuration and acceptance record. Higgsfield Presenter generation remains
disabled; its preparation, approval
and original-media workflows do not authorize a paid generation. Existing unrelated
AI tools use their own routes and explicit generation controls.

## Local work and account sync

The local editor and planner work without an account. Local source files stay in
account/workspace-scoped browser storage, with file hashes checked on restoration.
Browser storage can be evicted or cleared; retain the originals. Undo/Redo retains
up to 20 steps
within 64 KiB of metadata; undoing removal restores instructions, not a released
file binding. Local chat is browser-scoped metadata.

Sign in with the same Apple account and choose the same workspace to access cloud
properties and uploaded media. Property-linked draft and recent conversation save
in one revision-checked document, with conflict/recovery handling. This is one
private edit per user/property. Separately, **Save project to account** creates a
named private general video project and explicitly uploads its originals. After
that save, project changes and added originals sync to the same account/workspace.
The status distinguishes saved instructions from completed media uploads. Named
projects support cross-browser restoration, archive and explicit conflict recovery;
they do not create a property or enter the property review queue.

The project limit is 100 per account/workspace. Cloud originals share a 512 MiB
workspace allowance, including unfinished reservations, with 128 MiB per file.
Archive does not reclaim storage; individual cloud-file cleanup is not implemented.
Synced documents also support content plans and custom prompt collections.
Uploads, finished-video saves and publication remain explicit actions.

Phone-only footage becomes available after upload. Native **Save setup** shares
supported reel settings; it cannot reconstruct every local AVFoundation timeline,
recording or LiDAR scan. Camera capture and physical phone acceptance remain
on-device tests. The release verified a restored signed-in browser workspace and
guided enhancement, not a new phone-to-browser acceptance run or live AI quality.

## Develop and verify

Run from this directory (`apps/studio`). Use Node **22.12+** and the committed
lockfile. Real-media browser checks also need `ffmpeg` and `ffprobe`.

```bash
npm ci --no-audit --no-fund
npm run dev
```

```bash
npm run verify
npx playwright install chromium
node tests/creation-shell-browser.mjs
node tests/conversation-browser.mjs
node tests/cloud-editor-browser.mjs
node tests/export-resume-browser.mjs
node tests/prompts-browser.mjs
node tests/browser-connected.mjs
node tests/browser-connected-control.mjs
node tests/projects-browser.mjs
node tests/finishing-browser.mjs
```

`verify` runs unit tests, typechecking, the Vite build and distribution checks.
The browser suites use synthetic media and isolated service fixtures. They do not
prove live Apple OAuth, provider quality or camera behavior. On macOS, set
`STUDIO_BROWSER_EXECUTABLE` to an installed browser if needed. The connected
negative-control harness deliberately exercises a broken refresh implementation.
See [CI](../../.github/workflows/ci.yml) for the complete test matrix.

## Configuration and deployment

Only the two public fields from [.env.example](.env.example) belong in the frontend:
`VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`. Set them through the build
environment or ignored `.env.production.local`. The build rejects unexpected
`VITE_` fields and server-role keys. Apple keys, provider keys and all other server
secrets must stay server-side. An unconfigured build is a local-only preview;
passing distribution checks alone does not prove a connected production build.

The static Worker in [wrangler.jsonc](wrangler.jsonc) serves only Studio; the apex
marketing site and hosted tours use a separate Worker. Release schema and all
required read handlers before dependent website assets. The latest release record
includes migration reconciliation, exact function versions/JWT settings, and
source/hash verification. The updated [backend helper](scripts/deploy-backend.mjs)
requires an explicit list of functions and stages their import closure offline by
default. `--run` uses the existing Supabase CLI login/environment, verifies current
live policy against [function-jwt-policy.json](../../services/supabase/function-jwt-policy.json),
deploys only the selection, then downloads and hash-checks the deployed source.
It never applies migrations, activates providers or discovers all affected
entrypoints for you; include every consumer of changed shared code in the selection.

```bash
# Offline source staging and receipt; no deployment
node scripts/deploy-backend.mjs --functions studio
# After schema, tests and selection review, explicitly deploy that selection
node scripts/deploy-backend.mjs --functions studio --run
```

After checking the intended public connection configuration and backend release:

```bash
npm run verify
node scripts/check-dist.mjs --require-connected
npx wrangler deploy --dry-run
npx wrangler deploy
node scripts/verify-deployed.mjs
```

The verifier compares the custom domain against the exact local build, checks
headers and SPA fallback, and records the known managed robots prefix. At the
24 September release, all 27 files matched; CI had passed all 12 jobs and the
connected JavaScript gzip total was 293,933 bytes under that release's former
300,000-byte total ceiling. Current source checks separate gzip budgets: 160,000
bytes for initial assets, 260,000 for signed-in Create, and 350,000 across all
workspaces/tools. The editing-copy encoder is loaded on demand. The connected
check also requires the exact intended public configuration in the built bundle;
the next release receipt must record its own measurements.

`Cache-Control: no-store, no-transform` is intentional: it preserves the strict
CSP and prevents Cloudflare JavaScript Detection from changing Studio HTML.
Do not enable inline scripts to mask a failed byte check. The known managed robots
prefix means crawl blocking is not proven; noindex remains enabled.

## Code map

- [`src/App.tsx`](src/App.tsx): navigation, account/workspace scope and orchestration.
- [`src/editor/`](src/editor/): validated edit intent, chat, prompt enhancement,
  media import, preview and real-time browser export.
- [`src/features/sync/`](src/features/sync/): property drafts, paired conversation
  saves, native setup and cloud source restoration.
- [`src/features/projects/`](src/features/projects/): named projects, private
  chunked originals, browser recovery and project speech-analysis requests.
- [`src/features/prompts/`](src/features/prompts/), [`src/features/presenter/`](src/features/presenter/):
  prompt collections and gated Presenter workflow.
- [`src/data/`](src/data/): wire contracts and bounded authenticated reads.
- [Studio API](../../services/supabase/functions/studio/README.md): authenticated
  media, documents, creation and review handlers.
