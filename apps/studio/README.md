# Rendprop Studio

Rendprop's browser creation workspace is live at [studio.rendprop.com](https://studio.rendprop.com/).
It uses React, TypeScript, the app's branding, and the same Supabase account and
workspace model as iOS. **Create** is the default destination; My homes/spaces,
Media and Business remain primary navigation. Home, AI tools and Content planner
are available under More tools.

The [6 October candidate](../../docs/handoff/LAUNCH-READINESS-20261006.md) adds
personal contact cards with explicit Save, separate workspace branding,
deliberately selected per-member hosted listings, industry-specific detail forms,
experimental prompt labels and clearer disabled controls. It pairs private media
imports with the new server photo authority and funded AI admission. These
changes require the coordinated schema/API/web rollout; historical deployment
versions below do not certify the candidate. The
[beta handoff](../../docs/handoff/LAUNCH-BETA-20261006.md) records actual browser
and regression evidence, plus live/device acceptance still required.

New subscriptions use the approved 90-day hosting grace period after expiry.
Existing testers retain their prior hosting policy. Provider generation and
failed attempts need a reviewed funded allowance, rather than a feature count
alone; no trial sponsorship has been activated. Higgsfield generation remains
disabled as requested by the owner.

[Photographer client delivery](../../docs/studio/photographer-client-delivery.md)
adds **My homes → Create & publish / Details → Listing contact**. Choose **My
client**, upload a separate contact photo and review the private inquiry email
before saving and publishing. **Business → Leads** keeps the inquiry and its email
status, with recipient confirmation before resend. The real estate work
preference is changeable in **Business → Account & plan**. Conflicting or unsaved
contacts block publication. This release is live on Worker
`1cc57a97-e685-4c7c-aae1-641901a0087d`: all **31 served application files** match
the connected release build, with 28 bundles totaling **330,202 B gzip** against
350,000 B. All 12 exact-source CI jobs pass. See the
[release handoff](../../docs/handoff/PHOTOGRAPHER-CLIENT-DELIVERY-20261001.md) for
backend/readback evidence and controlled cross-device/inbox acceptance still needed.

The [photo-delivery update](../../docs/handoff/ROOM-TOUR-PHOTO-DELIVERY-20261001.md)
adds **Download photo/photos** in AI Photo Studio, with clean MLS JPEGs, labelled
web/social JPEGs, unchanged verified originals and disclosure captions in a ZIP.
Default export keeps source framing/full available output; optional crops have
a preview. Declutter → stage → restyle uses the correct current/pre-staging image.
Pre-staging history lasts during the open Studio session; it is not yet a shared
native/desktop version-history contract. Its historical deployment used Worker
`70d092cd-0a7b-41d3-bc3f-16743907a4c5`; all 30 application assets matched source
`0e7c78c`, which passed all 12 CI jobs. See the
[delivery receipt](../../docs/releases/TESTFLIGHT-36-20261001.json).

Video export now prepares one source ahead and bounds frame waits by the segment
deadline and existing 30 fps capture interval. Actual MP4/AAC checks under delayed
callbacks preserve full source playback, transitions and audio without widening
acceptance bounds. A fully blocked browser thread remains outside that recovery.

`node tests/photo-delivery-browser.mjs` verifies actual photo UI, canvas JPEGs and
ZIP downloads using isolated synthetic provider replies; no paid generation.

The [1 October core release](../../docs/handoff/CORE-READINESS-20261001.md) is
live: rejected project creation/copy keeps the current edit, empty drafts no
longer create phantom recovery prompts, and billing copy explains subscription
activation. All 30 deployed files match the tested build; live saved-project
restoration and playback passed. iPhone 1.0.3 (34) carries the related workspace
and billing changes; real-phone acceptance remains separate.

The [27 September release checkpoint](../../docs/handoff/CODEX-STUDIO-COMPLETION-20260927.md)
confirms the new website, database migrations and Studio API v12 are deployed.
All 30 website files and 44 API runtime files match their release source. Bounded
AI editing, enhancement and speech analysis are active. A signed-in synthetic
upload-to-MP4 smoke and full-page project reload passed; final CI passed 12/12 jobs.
PR #8 merged to main as `10e2b22`. This release includes projects, sound, captions
and editing copies.
Native delivery and physical-phone acceptance remain separate from the website.
The [24 September record](../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md) preserves
the prior baseline.

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

**Model-powered edit planning, prompt enhancement and speech analysis are live.**
Activation uses 8-cent text and 3-cent speech per-request estimated limits. The
signed-in production smoke verified a reviewed enhancement, compound edit with
Undo/Redo, reviewed transcription and downloaded MP4 using synthetic sources. See
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
on-device tests. The release verified the existing signed-in browser workspace
and a synthetic saved-project AI/edit/export path. It did not perform a fresh
Apple sign-in, second-browser production restoration or phone-to-browser run.

Start, upgrade or change an Apple plan in Rendprop for iPhone under **Settings →
Plan & usage**. The seven-day introductory trial starts only after the customer
confirms an eligible Apple subscription offer; downloading or signing in does not
activate a trial. Apple determines eligibility and displays the renewal price.
Studio uses that same account/workspace subscription and offers a link to Apple's
subscription management; it does not run a separate web checkout.

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
required read handlers before dependent website assets. The
[latest release record](../../docs/handoff/PHOTOGRAPHER-CLIENT-DELIVERY-20261001.md)
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
headers and SPA fallback, and handles the known managed robots prefix explicitly.
The 27 September release matched all **30 files** with no verifier warnings. Its
connected gzip sizes were **135,649 B initial / 216,383 B Create / 318,219 B total**,
within separate budgets of 160,000 / 260,000 / 350,000 bytes. The editing-copy
encoder is loaded on demand. The connected check requires the exact intended
public configuration in the built bundle. CI passed all 12 jobs for the preceding
implementation and for the final test-fixture correction (`e5632ff`, run
`36325429637`).

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
# Current source audit — 5 October 2026

The [full-system follow-up](../../docs/handoff/FULL-SYSTEM-AUDIT-20261005.md)
adds client-recipient verification and failed-module recovery. The current source
returns real 404 for missing assets and permits the exact existing R2 host in
CSP. These changes are **not deployed**; production connection, forwarding and
private-media delivery remain separate acceptance gates. `node
tests/recovery-browser.mjs` tests the real production React boundary/lazy chunk
with a closed-network synthetic workspace.
