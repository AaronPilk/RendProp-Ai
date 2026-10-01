# Rendprop

Rendprop brings phone capture, video editing, AI creative tools and property
marketing into one workspace. Capture photos and walkthrough footage on iPhone,
continue a property edit in Studio, and prepare reels and hosted property pages.
Real estate is the primary workflow; the app also supports other space types.

Apple subscription plans are selected, upgraded and changed in the iPhone app
under **Settings → Plan & usage**. A seven-day trial starts only after confirming
an eligible Apple subscription offer; installing the app or signing in does not
activate a trial. Studio uses the same account/workspace subscription.

[Open Studio](https://studio.rendprop.com/) · [Website](https://rendprop.com/) ·
[Studio release record](docs/handoff/CODEX-STUDIO-COMPLETION-20260927.md) ·
[iPhone delivery record](docs/handoff/GUIDED-PANORAMA-TESTFLIGHT-20261001.md)

## Production status — 1 October 2026

| Area | Current state |
| --- | --- |
| Studio web | Live: Create with chat editing, Simple/Pro controls, named projects, music mixing, captions, editing-copy preparation and browser MP4/WebM export. |
| Prompt enhancement | Live guided and model-backed suggestions, reviewed before use; AI editing and reviewed speech captions are enabled with bounded costs. |
| Prompt library | Ten original recipes, adaptation, saved personal collections and result notes. Copying a prompt does not generate media. |
| Property workflow | Account-scoped media, one private edit per user/property, saved conversation, capture plans, versions and team review. Save project to account explicitly uploads general-project originals. |
| AI Presenter | Preparation, approvals and execution controls deployed; Higgsfield generation remains disabled. |
| iOS | Internal TestFlight **1.0.3 (33)** is available to the existing Rendprop team. Adds guided scan positions, optional native depth, local panoramic room tours and recovery/export. Open **Home → Guided room tour**. Physical-phone acceptance is pending; these panoramic tours do not yet publish or sync to Studio. |
| 3D walkthrough | Capture/upload/viewer and worker controls exist. Reconstruction quality has not passed acceptance; see the [spatial status](services/spatial-worker/README.md). |

The 27 September website release passed exact verification of **30 web files**; Studio API v12
matched **44 runtime source files**. Signed-in synthetic production checks passed
for source uploads, AI enhancement/editing, reviewed speech captions and a real
MP4 export. A full-page reload restored the QA project, sources and conversation.
Final CI passed **12/12 jobs**, and
[PR #8](https://github.com/AaronPilk/RendProp-Ai/pull/8) merged to main as `10e2b22`. The
[release record](docs/handoff/CODEX-STUDIO-COMPLETION-20260927.md) keeps these checks
separate from physical-phone, fresh Apple sign-in and second-browser acceptance.

## New creation tools

Studio now includes named private video projects with uploaded originals and
cross-browser restoration, imported music with mixing/fades/ducking, reviewed
beat-cut proposals, source-timed speech captions and speaking-passage suggestions.
An explicit local editing-copy tool prepares large recordings for the browser.
General projects need no property; property reels retain their agency review and
delivery workflow. See [projects and finishing](docs/studio/projects-and-finishing.md).

The [27 September release checkpoint](docs/handoff/CODEX-STUDIO-COMPLETION-20260927.md)
confirms the new website, four database migrations and Studio API v12 are deployed.
Bounded AI editing, prompt enhancement and speech analysis are activated, with a
successful signed-in synthetic upload-to-export-and-reload smoke. Four single-attempt
provider calls totaled **$0.2415 in estimated ledger cost**, not an invoice charge. [Editing intelligence activation](docs/studio/editing-intelligence-activation.md)
records gates, pricing estimates and acceptance checks. Presenter generation stays
disabled, and this work does not establish phone or spatial-quality acceptance.

## Start developing

For Studio, use Node.js **22.12 or newer**:

```sh
cd apps/studio
npm ci
npm run dev
```

Local creation works without a backend. A connected workspace requires the
public Supabase configuration described in the [Studio README](apps/studio/README.md).
Never put service-role or provider credentials in frontend environment variables.

```sh
# From apps/studio: unit tests, typecheck, build and distribution checks
npm run verify
```

Browser media tests also exercise real encoded synthetic videos. See the
[CI workflow](.github/workflows/ci.yml) and each component's test instructions for
the required browser, Deno, Python, PostgreSQL and Xcode environments. Simulator
tests cannot validate physical camera, ARKit/LiDAR capture or thermal behavior.

## Repository map

| Path | Purpose |
| --- | --- |
| [apps/ios](apps/ios/README.md) | Swift/SwiftUI app and device workflow |
| [apps/studio](apps/studio/README.md) | React/Vite production Studio |
| [services/supabase/functions](services/supabase/functions/README.md) | Authenticated APIs, public handlers and provider orchestration |
| [services/supabase/migrations](services/supabase/migrations) | Current database schema, RLS and RPC migration history |
| [services/edge/tour-host](services/edge/tour-host/README.md) | Public website, hosted tours, agent pages and lead capture |
| [services/edge/upload-gateway](services/edge/upload-gateway) | Upload transport gateway |
| [services/worker](services/worker/README.md) | Optional server render worker, ownership leases and publication |
| [services/pipeline](services/pipeline/README.md) | Python image/hero enhancement and cost accounting |
| [services/spatial-worker](services/spatial-worker/README.md) | Gated spatial queue controller and provider lifecycle |
| [tools/spatial-spike](tools/spatial-spike/README.md) | Capture/training/viewer experiments and evaluation |
| [tools/style-policy](tools/style-policy/README.md) | Offline style plans and blind-comparison protocol |
| [services/marketing-video](services/marketing-video/README.md) | Standalone marketing-video composition prototypes |
| [apps/web/player](apps/web/player/README.md) | Archived standalone scroll-player prototype |
| [services/api](services/api/README.md), [infra](infra/README.md) | Historical API design and infrastructure pointers |

## Workflow and release documentation

- [Create with chat and Improve prompt](docs/studio/conversational-creation.md)
- [Agency production, capture plans and review](docs/studio/agency-production-workflow.md)
- [Named video projects, music, captions and editing copies](docs/studio/projects-and-finishing.md)
- [Editing intelligence activation and acceptance](docs/studio/editing-intelligence-activation.md)
- [Prompt library](docs/studio/prompt-library.md)
- [AI Presenter and activation requirements](docs/studio/ai-presenter.md)
- [Brand assets](docs/brand/README.md)
- [iOS test boundaries](apps/ios/RendpropUITests/README.md)
- [Current Studio release record](docs/handoff/CODEX-STUDIO-COMPLETION-20260927.md)
- [24 September production baseline](docs/handoff/CODEX-STUDIO-LIVE-20260924.md)

The [original master build prompt](docs/MASTER-BUILD-PROMPT.md) records product
intent and planned work. Current source, tests and dated deployment receipts
establish what is implemented and live; roadmap language is not a shipping claim.
Historical audit and release folders retain their original measurements.

Use isolated branches when collaborating. Preserve migration history and existing
function authentication settings; apply schema before dependent handlers and web
assets. The updated [backend deployment helper](apps/studio/scripts/deploy-backend.mjs)
requires explicit function selection, stages offline by default and preserves
the declared JWT policy. With `--run`, it checks live policy and verifies deployed
source hashes. No disabled provider or spatial gate
should be activated merely to complete a UI demonstration.
