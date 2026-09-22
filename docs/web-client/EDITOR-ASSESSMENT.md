# Lane E — editor/render build-versus-buy assessment

Research date: 2026-09-10. Read-only public research and repository inspection; no vendor account, purchase, installation, desktop MCP call, upload, render, Apple action, or customer-data access. This is an architecture recommendation, not implementation approval or a performance result.

Read the new attached brief, all 628 lines of `docs/GPT-AGENT-BRIEF.md`, and all five `docs/research/2026-09-market/*.md` before research. Repository: `/Users/pilksclaes/Rendprop AI/spatial-testflight-20260910`; initially `db3c0f9`, final source inspection `f14081d49d5fb40b1dde59562176692ddb2664c6` as the parent continued its work. No repository changes by this lane.

## Decision

Do not select Palmier Pro as Rendprop's production rendering backend on the evidence available. Its documented integration is a local Mac editor/MCP workflow, and current software and hosted-service rights do not grant a white-label rendering business. Absence of a published suitable API is an evidence gap, not proof that a private enterprise agreement cannot exist.

Prefer a constrained Rendprop browser editor with local/proxy preview, a versioned edit-decision document in the existing backend, and canonical publication through the existing worker/queue seam. Evaluate selected Diffusion Studio editor packages as an implementation accelerator after license, dependency and sandbox review; do not adopt its complete product backend, agent, billing or account stack. The existing worker needs timeline-rendering work and finalization safety gates; it is not already a general editor backend.

This does not authorize spatial Phase B–E work or relax the real-room Phase A gate. Nothing here proves a reconstructed room, browser editor, or GPU workflow.

## 1. Palmier: desktop automation is not a verified tenant-safe rendering API

The official MCP guide requires Palmier Pro to be open and exposes a localhost MCP endpoint. Project-management and active-timeline tools operate on local editor state; export tools queue work and expose status, warnings and cancellation. These are useful automation primitives, but the guide does not specify a hosted tenant/job contract, independent headless process, per-tenant scopes, idempotency keys, render quotas or availability SLA. Do not infer that multiple project-management commands establish isolation between customer jobs. [Palmier agent/MCP documentation](https://www.palmier.io/docs/agent-and-mcp).

The current repository distinguishes historical GPLv3 source through v0.7.6/`last-gpl-source` from later proprietary binaries without corresponding published source. It requires Apple Silicon and macOS 26. The historical repository is not the source of the currently marketed application. [Current repository](https://github.com/palmier-io/palmier-pro). The later-binary license requires written permission for copying, modification, redistribution, sublicensing and derivative works outside its grant. [Binary license](https://raw.githubusercontent.com/palmier-io/palmier-pro/main/BINARY_LICENSE.md).

Palmier's June 22, 2026 terms retain users' input rights and permit commercial use of generated content subject to rights and applicable rules. That is different from permission to resell the tool: the terms prohibit resale, sublicensing or white-labeling without permission. They do not supply a production availability guarantee. [Terms, §§4–5 and service disclaimers](https://www.palmier.io/terms).

The June 22 privacy policy says editing media/projects stay local; requested assistant/generation inputs go to outside providers. It claims no Palmier training and contractual restrictions on providers' general-purpose training. Provider temporary retention remains possible for abuse, billing or reliability, without a fixed model-by-model duration. Optional diagnostics include device/error information and project counts, not media/project files. Account/support retention is purpose-based, with deletion by contact. The policy explicitly is not an NDA. A signed DPA, region/subprocessor schedule and deletion SLA remain procurement gaps. [Privacy policy, §§2–7](https://www.palmier.io/privacy).

Available-tool metadata in this session contained zero Palmier matches. No localhost server, installed project, application state or account was probed. Tool availability therefore was not operationally verified; no project mutation was attempted.

### Verified displayed prices, not backend-render quotes

| Product | Public price checked 2026-09-10 | What it does **not** price |
| --- | --- | --- |
| Palmier Free | $0 editor, local MCP and video/XML export | Hosted concurrent rendering, tenant storage, SLA |
| Palmier Pro | Limited-time $29/month; displayed regular $49; 5,000 generation credits/month | Final composition/render minutes |
| Palmier Max | Limited-time $69/month; displayed regular $99; 12,000 generation credits/month | A scalable rendering service |
| Palmier Enterprise | Custom | No published API unit rate or minimum commitment |
| Diffusion Studio Free | $0; unlimited exports up to 4K without watermark | A licensed hosted white-label rendering API |
| Diffusion Studio Pro | $19/month **billed annually** at displayed 2,500-credit tier; $228/year | A $19 cancel-monthly plan or server-render price |
| Diffusion Studio Teams | Custom | API SLA, hosting or white-label rights |

Palmier's rough 5,000-credit guide covers around 333 generated images or 2–7 minutes of generated video; generation is not encoding existing footage. Diffusion exports do not use credits; analysis/transcription/generation do. These subscriptions cannot populate a cost-per-server-render comparison. Promotional duration, taxes, API capacity and negotiated enterprise pricing are unknown. [Palmier pricing](https://www.palmier.io/pricing), [Diffusion Studio pricing](https://www.diffusion.studio/pricing).

**Palmier verdict:** no-go as a production dependency today. A separately approved staff creative-tool trial on owned/synthetic media could be useful, but would not validate SaaS architecture. No vendor contact or trial was initiated.

## 2. Diffusion Studio: reusable code, not a turnkey server service

The current `diffusionstudio/editor` repository is a SolidJS/Vite web editor with an Electron desktop shell and `dapi` CLI. Its JSX/SolidJS project source is compiled/evaluated into an ECS world; this is executable project code, not just passive JSON. Packages separate runtime, assets, reconciler and encoder. Its MPL-2.0 source excludes desktop branding assets. [Editor README](https://raw.githubusercontent.com/diffusionstudio/editor/main/README.md). Observed main package version: `0.204.2`; implementation must pin an audited commit and lockfile rather than track `main`. [Package metadata](https://raw.githubusercontent.com/diffusionstudio/editor/main/package.json).

The runtime advertises no DOM/Solid dependency, but the encoder explicitly needs browser-grade canvas, OfflineAudioContext, AudioWorklet and SharedArrayBuffer. A headless runtime is not proof that bare Node can export. [Runtime package](https://raw.githubusercontent.com/diffusionstudio/editor/main/packages/runtime/package.json), [encoder package](https://raw.githubusercontent.com/diffusionstudio/editor/main/packages/encoder/package.json). Current project/canvas CLI documentation expects a running local application. [CLI reference](https://raw.githubusercontent.com/diffusionstudio/editor/main/reference/README.md). Export documentation allows one export at a time and a 60-minute CLI wait; codec combinations can be unsupported, and malformed settings can fall back to defaults. These are upstream application behaviors, not acceptable Rendprop job-boundary guarantees. [Export contract](https://raw.githubusercontent.com/diffusionstudio/editor/main/reference/export.md).

The web configuration uses COOP `same-origin` and COEP `credentialless`; its desktop build expects vendor authentication configuration and a local API proxy. Copying the application wholesale would bring assumptions that conflict with Rendprop's one-backend requirement. [Vite configuration](https://raw.githubusercontent.com/diffusionstudio/editor/main/apps/web/vite.config.ts).

MPL-2.0 is file-level copyleft: distributing modified covered files requires their corresponding source and notices; separate proprietary files may remain separate. Serving minified covered JavaScript to browsers is distribution, not an exemption. Obtain legal/SBOM review before integration, preserve notices and exclude unlicensed branding. [MPL FAQ Q8–Q12/Q16](https://www.mozilla.org/en-US/MPL/2.0/FAQ/), [repository license](https://raw.githubusercontent.com/diffusionstudio/editor/main/LICENSE).

Do not confuse this repository with `diffusionstudio/core`: its README describes a separate watermark-removal license key and advises against server rendering. No current numeric core license price was verified. Older v3 documentation has different commercial licensing and is not a safe specification for the current editor monorepo. [Core repository](https://github.com/diffusionstudio/core), [older version documentation](https://docs.diffusion.studio/docs/version-3).

### Hosted product data terms are separate from self-hosted source rights

Diffusion's May 4, 2026 terms mention a public API but do not establish that it is a multi-tenant timeline-render API. Reselling/white-labeling its hosted service needs written consent; output commercial-use rights do not replace that permission. [Terms §§1,4–7](https://www.diffusion.studio/legal/terms-and-conditions).

Its May 4 privacy policy describes uploaded generation media in Google Cloud Storage `us-central1`, local project storage with backend synchronization where applicable, collected prompts/parameters, and multiple AI subprocessors. The media-retention wording combines deletion and 24 hours after creation without a sufficiently precise lifecycle contract; account deletion and backup purging describe 24-hour periods with exceptions. No explicit blanket no-training promise was found. Public access-control claims are not independently tested tenant isolation. Clarify retention, provider training and DPA terms before sending private media to the hosted product. [Privacy policy §§2,4,6,9](https://www.diffusion.studio/legal/privacy-policy).

For selectively reused code, Rendprop should own data processing and remove vendor endpoints, telemetry, AI routes and accounts. Do not execute user/agent-supplied JSX in the authenticated application origin. Use a closed, validated Rendprop JSON edit schema and a trusted compiler/adapter; isolate media workers without tokens, arbitrary network access or unbounded resource use. This is a proposed security boundary, not an audit of all upstream code.

## 3. Existing Rendprop seam: concrete capability and gaps

| Finding | Repository evidence |
| --- | --- |
| Existing queue → R2 source → FFmpeg → artifact/poster → render record path | [worker.py:392](</Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/services/worker/worker.py:392>) and [worker.py:430](</Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/services/worker/worker.py:430>) |
| Current transform retimes/scales one input, encodes H.264 all-intra and explicitly strips audio; it is not a general multi-track editor | [ffmpeg_render.py:360](</Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/services/worker/ffmpeg_render.py:360>) and [ffmpeg_render.py:382](</Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/services/worker/ffmpeg_render.py:382>) |
| Defaults: 1280 long edge, 60fps, 14Mbps, medium preset; not a proved 4K final-video service | [settings.py:220](</Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/services/worker/settings.py:220>) |
| 0.5 cents/output-minute is a configurable **estimate**, not measured compute billing; provider label defaults to `modal` | [settings.py:246](</Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/services/worker/settings.py:246>), [infra_costs.py:46](</Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/services/worker/infra_costs.py:46>) |
| Scratch check expects 2.5× source bytes; memory-backed scratch makes a 2GB source materially different from a tiny sample | [worker.py:306](</Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/services/worker/worker.py:306>) |
| Render duplicate-job replacement patches by `job_id` alone; this call has no attempt/fencing predicate | [db.py:611](</Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/services/worker/db.py:611>) |
| Native multi-shot composition exports with AVFoundation, not the worker's encoder | [ReelComposer.swift:248](</Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/apps/ios/Rendprop/Render/ReelComposer.swift:248>), [ReelComposer.swift:1010](</Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/apps/ios/Rendprop/Render/ReelComposer.swift:1010>) |

Reuse the queue, authorization, ledger, storage and publication seams; extend an operation within them after ownership/finalization tests. Do not launch a second job service. This inspection did not execute worker code, verify its deployed hosting provider or reproduce the stale-attempt race; it identifies the missing guard at the cited call. The research backlog already requires lease-fenced durable finalization and organizational controls. [ENGINEERING-BACKLOG.md:190](</Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/docs/research/2026-09-market/ENGINEERING-BACKLOG.md:190>), [E11/E12:214](</Users/pilksclaes/Rendprop AI/spatial-testflight-20260910/docs/research/2026-09-market/ENGINEERING-BACKLOG.md:214>).

The FFmpeg build also needs a license/SBOM check: upstream distinguishes LGPL code from optional GPL components such as libx264, and codec-patent questions remain separate. Do not describe the current binary as unconditionally LGPL-only. [FFmpeg legal guidance](https://ffmpeg.org/legal.html).

## 4. Rendering choice per operation — proposed, not built

| Operation | Proposed execution | Boundary/fallback |
| --- | --- | --- |
| Trim, reorder, text placement, timeline edits | Browser; bounded local/proxy playback and worker-generated thumbnails/waveforms | Save versioned edits to existing backend. No paid job per drag. |
| Interactive scrubbing | Capability-selected proxy/resolution and bounded decoded-frame cache | Lower preview fidelity honestly; never label dropped preview frames as export results. |
| Unsupported codec, heavy HDR, large originals | One cached worker proxy per source hash + profile | Existing authorized queue; bounded resource class and deadline. Reuse the proxy, not a new server render on each scrub. |
| Accurate approval preview | Canonical server render of an immutable edit revision | Approve artifact checksum plus revision; changing edits invalidates approval. |
| Published final | Same canonical artifact reused by web and iOS | No silent per-client re-encoding. Old published artifact stays available on failure. |
| Optional local draft download | Browser encoder, only after capability check | Explicitly noncanonical/unapproved; no automatic publication. |
| AI analysis/generation | Existing authorized `ai_routes`, reservation and ledger | No imported Palmier/Diffusion AI path, new account, disabled provider or automatic paid fallback. |
| Public playback | Existing delivery artifact | Do not ship the editor/runtime to every viewer. |

WebCodecs requires configuration support checks and resource/error handling; workers/OffscreenCanvas keep work off the UI thread, and VideoFrames must be closed. This supports a capability ladder, not a promise that every browser/device exports the same codecs or performance. [Chrome WebCodecs guidance](https://developer.chrome.com/docs/web-platform/best-practices/webcodecs). Set backpressure for offline exports; frame dropping suitable for real-time preview must not silently alter the final.

**Identical listing on web and iOS does not currently imply byte-identical output.** The safe contract is both clients retrieve the same stored canonical bytes and checksum for the same approved revision. An edit digest should include source hashes, normalized edits, renderer version, fonts/assets, color/audio/timebase and export settings. This avoids duplicate jobs but does not alone prove reproducible re-encoding. Independent encoders, metadata timestamps, fonts and hardware paths can differ. Exact re-render reproducibility needs its own pinned-environment tests; visual parity is a separate requirement.

## 5. Numerical model: prices are evidence; workloads are assumptions

### Public rate inputs

As checked 2026-09-10: Cloud Run Jobs' displayed Iowa/us-central1 on-demand prices are $0.000018/vCPU-second and $0.000002/GiB-second, with a one-minute minimum per started instance. Job lifetime includes non-encoding work; network/build/artifact charges are additional. This is a public reference rate, not selection of a new provider or proof of Rendprop's current bill. [Cloud Run pricing](https://cloud.google.com/run/pricing).

R2 Standard lists $0.015/GB-month, $4.50/million Class A and $0.36/million Class B operations, with free-tier allowances and billing-unit rounding. R2's free egress does not cancel another cloud's outbound charges. [R2 pricing, updated August 7](https://developers.cloudflare.com/r2/pricing/).

Stream lists $5 per prepaid 1,000 stored minutes and $1 per 1,000 delivered minutes. Its included encoding is playback transcoding, not Rendprop timeline composition; buffering/preloading can count as delivery. [Stream pricing, updated September 8](https://developers.cloudflare.com/stream/pricing/).

### Explicit illustrative workload — no benchmark was run

- 1,000 accepted listings/month; each has 2GB source, a 60-second final, and 0.2GB total retained outputs/proxies.
- One proxy and one final per listing; 1.10 charged-attempt multiplier. Each attempt is assumed to cost the full modeled time, including failed attempts.
- 2 vCPU + 8GiB for each job, whole-instance lifetimes of 60 seconds for a proxy and 120 seconds for final. Neither resource sufficiency nor these times is measured. Eight GiB is not arbitrary proof of safety: the cited 2.5× source scratch rule alone implies about 5GB scratch for a 2GB file; decoder/process overhead and larger inputs still need measurement or disk-backed storage.
- One month's cohort retained for a full month; no free-tier or committed-use discount credited; no AI.

Arithmetic: instance rate = `2 × 0.000018 + 8 × 0.000002 = $0.000052/second`. Compute/listing = `1.10 × (60 + 120) × 0.000052 = $0.010296`.

| Monthly cost component for this workload | Modeled amount | Qualification |
| --- | ---: | --- |
| Proxy + final compute | $10.296 | Approximately 1.03 cents/listing, **compute only** |
| R2 capacity | $33.00 | 2,200GB-month; retention growth changes this |
| R2 operations | Additional | Need actual multipart/read counts and account-level allowance/rounding; not assumed zero |
| Compute-host egress | Additional | `GB sent × actual route rate`; hosting/region not verified |
| Optional Stream final storage | $5.00 | Exactly 1,000 one-minute masters; duplicates add storage |
| Optional Stream viewing | $100.00 | Assumption: 100,000 watched minutes/month |
| Human review/support | $1,000.00 | Assumption: 2 minutes/listing at $30/hour |

Do not report a total cost per delivered listing from the compute line: operational storage, revisions, upload/proxy I/O, CDN requests, taxes, logs, idle capacity, support and human review remain relevant. Final artifacts may be stored twice in R2 and Stream by design.

Sensitivity with all other assumptions fixed: a final lifetime of 60/120/600 seconds yields monthly proxy+final compute of **$6.864 / $10.296 / $37.752**. Rendering 20 additional one-minute-billed server previews per listing adds **$68.64** compute/month; 120-second previews double that increment. Browser preview primarily improves interactive latency and avoids queue/operational load; it does not make browser CPU, battery, downloads or support free. For six retained monthly cohorts, the illustrative R2 capacity becomes $198/month, not $33.

### Build versus a hypothetical eligible API

Planning assumptions only, not vendor quotes or engineering commitments: selective editor/worker integration 600 hours at $100/hour plus 20 hours/month maintenance; a real eligible render API integration 200 hours plus 10 hours/month. The common Rendprop authentication/upload/approval/provenance work is required either way and excluded from this comparison. A full editor from scratch could require materially more; no estimate is claimed without a feature inventory.

At 24-month amortization, build fixed cost is $4,500/month; hypothetical buy fixed cost is $1,833.33/month **before** any vendor minimum and usage. If its comparable proxy+final price is `p`, and build's modeled compute is `c = $0.010296`, break-even accepted listings/month is `(40,000 / 24 + 1,000) / (p − c)`, only for `p > c` and equal quality/coverage. Assumed `p = $0.25 / $1 / $2` gives approximately **11,125 / 2,694 / 1,340 listings/month**. Shared costs cancel only when genuinely shared; vendor minimums, included storage, concurrency or extra revisions change the result.

Palmier has no verified comparable `p`, hosting entitlement or API SLA, so there is **no defensible Palmier break-even point**. The model identifies what a quote must answer, not a reason to buy or spend now. Research arithmetic was evaluated directly; no encoder workload was measured.

## 6. Acceptance questions before any adoption

For either vendor-operated rendering proposal, require written evidence of: headless deployment/API rights; white-label/commercial use; tenant-scoped credentials and job isolation; no-training coverage across every subprocessor; region and retention/deletion deadlines; per-operation pricing and hard spend ceilings; no automatic top-ups; concurrency/queue guarantees; idempotency and cancellation semantics; bounded polling/webhook recovery; export portability; security reporting and outage/termination behavior. An enterprise marketing plan is not these answers.

For the proposed build, first approve the shared edit/job schema, license boundary and resource policy. Then use owned synthetic fixtures to verify preview/final trim boundaries, fonts, captions, audio sync, HDR/SDR, unsupported-codec fallback, invalid executable document rejection, slow uploads, cancellation, duplicate requests, stale worker attempts and cross-tenant isolation. No new queue/auth/ledger, and no silent vendor fallback. These are future acceptance requirements, **not tests run in this lane**.

When a worker/provider fails, preserve draft revisions and the last approved output; mark failure or bounded retry honestly. Reconcile uncertain jobs before submitting again. Never publish a partial export or reuse an approval from different bytes. This extends, rather than bypasses, Rendprop's existing provenance, consent, fair-housing review and entitlements requirements.

## Verification and limits of this assessment

Primary public pages and raw source metadata were inspected on the stated date. No account configuration, `.env`, provider secret, customer media or desktop project was read. No package was installed; no server/GPU or browser export was run. No app/build/deployment was changed. Public policies are vendor claims, not independently verified operational controls or legal approval. Only temporary copies of this assessment Markdown were authored; no source commit was made. Eight arithmetic assertions passed; all 13 linked local file/line references existed. These checks validate the report, not media rendering performance or reliability.
