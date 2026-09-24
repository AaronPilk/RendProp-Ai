# Rendprop Studio

Rendprop's browser creation workspace is live at [studio.rendprop.com](https://studio.rendprop.com/).
It uses React, TypeScript, the app's branding, and the same Supabase account and
workspace model as iOS. **Create** is the default destination; My homes/spaces,
Media and Business remain primary navigation. Home, AI tools and Content planner
are available under More tools.

The [24 September production record](../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md)
is the latest deployment evidence. It supersedes the pre-release status in earlier
handoffs and the September 14 screenshots. This README describes the source at
that release; provider availability and native releases have separate gates.

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

The prompt library contains ten original recipes, scene/timeline adaptation,
custom collections, source links and test feedback. Property workflows also
include shared capture plans, saved versions, review/approval and native handoffs.
Setup and review controls are expandable below the editor.

- [Conversational creation and enhancement](../../docs/studio/conversational-creation.md)
- [Agency production workflow](../../docs/studio/agency-production-workflow.md)
- [Prompt library](../../docs/studio/prompt-library.md)
- [AI Presenter and activation requirements](../../docs/studio/ai-presenter.md)

**Optional model-powered edit planning and prompt enhancement remain disabled.**
Their routes and activation configuration are absent in the recorded release.
Higgsfield Presenter generation also remains disabled; its preparation, approval
and original-media workflows do not authorize a paid generation. Existing unrelated
AI tools use their own routes and explicit generation controls.

## Local work and account sync

The local editor and planner work without an account. Local source files stay in
the browser; saved metadata is not a media backup. Originals must be reselected
after reload and their full hashes must match. Undo/Redo retains up to 20 steps
within 64 KiB of metadata; undoing removal restores instructions, not a released
file binding. Local chat is browser-scoped metadata.

Sign in with the same Apple account and choose the same workspace to access cloud
properties and uploaded media. Property-linked draft and recent conversation save
in one revision-checked document, with conflict/recovery handling. This is one
private edit per user/property, not an unlimited archive of named projects.
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
source/hash verification. The older `scripts/deploy-backend.mjs` does **not** cover
the combined Presenter/privacy release and forces a uniform JWT setting; do not
use it unchanged for that release.

After checking the intended public connection configuration and backend release:

```bash
npm run verify
npx wrangler deploy --dry-run
npx wrangler deploy
node scripts/verify-deployed.mjs
```

The verifier compares the custom domain against the exact local build, checks
headers and SPA fallback, and records the known managed robots prefix. At the
24 September release, all 27 files matched; CI had passed all 12 jobs and the
connected JavaScript gzip total was 293,933 bytes of the 300,000-byte ceiling.

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
- [`src/features/prompts/`](src/features/prompts/), [`src/features/presenter/`](src/features/presenter/):
  prompt collections and gated Presenter workflow.
- [`src/data/`](src/data/): wire contracts and bounded authenticated reads.
- [Studio API](../../services/supabase/functions/studio/README.md): authenticated
  media, documents, creation and review handlers.
