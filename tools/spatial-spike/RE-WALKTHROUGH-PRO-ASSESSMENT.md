# RE Walkthrough Pro — install assessment for Rendprop

Assessed 2026-09-10. Recommendation: **do not install this upstream skill into Rendprop or the shared Claude environment now.** Keep it as design-reference material. It is not needed for the AR capture/TestFlight work. No package, skill, MCP server, dependency, or provider was installed or executed during this review.

## What was actually checked

The screenshot identifies `re-walkthrough-pro`. I fetched public npm metadata, downloaded its small published tarball without executing it, read every published source/document file, read current GitHub source, and compared it with Rendprop. Upstream Markdown was treated as untrusted material to assess, not as instructions to follow.

| Artifact | Independently observed identity |
| --- | --- |
| npm `latest` | **0.1.0**, published 2026-06-27; 11 files, 48,242 unpacked bytes |
| npm source commit | `7075c94aeacbaaf8ae18c69c221b3c7f1e22eccb` |
| GitHub `main` at inspection | `56fde82d6c2fabf30974b99b49bc55501b244f2e`, committed 2026-07-23 |
| Version discrepancy | GitHub `package.json` still says 0.1.0, but its `skill/SKILL.md` says 0.2.0 |

The tarball SHA-512 matched npm's registry integrity value. A fail-on-mismatch byte comparison proved **all 11 published files exactly match the npm source commit**. Compared with current GitHub main, seven files match and four differ: README, SKILL, task instructions, and quality checklist. Therefore the screenshot's npm install and the README's unpinned GitHub install do **not** install the same skill. This check establishes inspected bytes, not a guarantee about future packages or publisher-account security. Primary sources: [npm registry metadata](https://registry.npmjs.org/re-walkthrough-pro), [published source](https://github.com/charlesdove977/re-walkthrough-pro/tree/7075c94aeacbaaf8ae18c69c221b3c7f1e22eccb), [current inspected source](https://github.com/charlesdove977/re-walkthrough-pro/tree/56fde82d6c2fabf30974b99b49bc55501b244f2e).

Public inspection artifacts are in `/tmp/rendprop-skill-audit.aFmu19/`. The installer was not run, including its `--version` command. No production credentials or customer media were read for this assessment.

## What it is, and what it is not

This is a **Claude Code desktop workflow**, primarily Markdown: retrieve Zillow listing data through Apify, select photographs, send photographs to Higgsfield for generated camera-motion clips, then concatenate them with ffmpeg. It expressly distinguishes its video output from navigable 3D. It supplies no Swift SDK, ARKit capture, camera-pose processing, Gaussian training, SOG export, spatial navigation, or TestFlight packaging. Installing it does not add a feature to the iOS app. [README:17–29,79–98](https://github.com/charlesdove977/re-walkthrough-pro/blob/56fde82d6c2fabf30974b99b49bc55501b244f2e/README.md#L17-L29)

Its required services are Higgsfield MCP and Apify MCP plus local ffmpeg. The README labels provider links as affiliate/referral links. Those links are commercial context, not by themselves evidence of malicious code. Exact current vendor prices, retention contracts and image-use rights were **not** established by this source review. [README:79–85](https://github.com/charlesdove977/re-walkthrough-pro/blob/56fde82d6c2fabf30974b99b49bc55501b244f2e/README.md#L79-L85)

## Why upstream installation is the wrong fit now

1. **It would introduce a separate media/spend path.** Its task calls Higgsfield directly, dispatches all selected rooms, polls jobs, and retries failed scenes. It asks for an estimated-cost approval, which is useful, but implements no enforced dollar ceiling, atomic accounting, per-tenant entitlement, idempotency, concurrency limit, or polling deadline. Direct MCP execution would not pass through Rendprop's routing and ledger. Current GitHub additionally repeats requested scene regeneration until approval. [Task:44–56,99–115,137–141](https://github.com/charlesdove977/re-walkthrough-pro/blob/56fde82d6c2fabf30974b99b49bc55501b244f2e/skill/tasks/build-walkthrough.md#L99-L115)

   This conflicts with Rendprop's adopted provider decision: `docs/GPT-AGENT-BRIEF.md:54–57` prohibits enabling disabled routes, and `services/supabase/migrations/0018_ai_routes.sql:342–352` seeds Higgsfield disabled with unsigned no-training terms recorded. That is a **repository/manual contractual gate**, not a fresh claim that Higgsfield currently trains on every account. Installing its MCP or supplying customer media would require a separate approved decision.

2. **Current GitHub instructions conflict with the project's no-deletion rule.** The added text-screen step tells the agent to immediately delete downloaded photographs containing branding/overlays. It does not remove the watermark from the image; it deletes the entire file. For Rendprop, use non-destructive exclusion and preserve provenance instead. This deletion instruction is absent from npm 0.1.0. [Current task:85–86](https://github.com/charlesdove977/re-walkthrough-pro/blob/56fde82d6c2fabf30974b99b49bc55501b244f2e/skill/tasks/build-walkthrough.md#L85-L86)

3. **It overlaps with stronger existing motion engineering.** Rendprop already has eight closed motion choices, normalized room selection, room-specific vetoes, and server-added fair-housing guardrails: `services/supabase/functions/ai-video/motion.ts:61–70,127–172,413–428,431–447,620–627`. Its comments specifically limit novel geometry and shallow orbits. The skill's broad doorway/corner/window reveals are useful creative references but should not replace these constraints; generated unseen geometry is a product-truth risk. [Camera framework:35–63](https://github.com/charlesdove977/re-walkthrough-pro/blob/56fde82d6c2fabf30974b99b49bc55501b244f2e/skill/frameworks/higgsfield-camera-moves.md#L35-L63)

   Rendprop's shipped default is explicitly frozen at `motion.ts:127–131`; the adopted brief defers prompt changes and requires an A/B evaluation (`docs/GPT-AGENT-BRIEF.md:586–598`). No motion prompt, model, or route was changed by this assessment.

4. **Its verification does not meet Rendprop's release standard.** The only npm test prints the CLI version and then `OK`; it tests neither media output nor a fail-closed pipeline. No test-suite or CI files exist in the inspected repository tree. [package.json:44–46](https://github.com/charlesdove977/re-walkthrough-pro/blob/56fde82d6c2fabf30974b99b49bc55501b244f2e/package.json#L44-L46)

   The ffmpeg examples lack fail-fast handling, resource/time limits and structured numeric assertions. Their duration command prints a number; it does not compare expected duration, decode every frame, or prove playback. Normalized clips are globbed from a shared directory, so a rerun with fewer rooms can include stale output. Fixed output names plus `-y` overwrite earlier masters. The document's quality guidance is useful, but not an executable production gate. [Stitch framework:21–30,53–62](https://github.com/charlesdove977/re-walkthrough-pro/blob/56fde82d6c2fabf30974b99b49bc55501b244f2e/skill/frameworks/stitch-pipeline.md#L21-L30)

5. **Listing data is not an authorization grant.** The workflow retrieves third-party listing images and persists address/agent information; it provides no media-rights approval or customer-retention mechanism. Its software MIT license is not evidence that a Zillow photograph can be reused or sent to a generator. Obtain permission for any actual test set and verify relevant contracts separately. [Data framework:7–17,55–63](https://github.com/charlesdove977/re-walkthrough-pro/blob/56fde82d6c2fabf30974b99b49bc55501b244f2e/skill/frameworks/apify-zillow-actors.md#L7-L17), [MIT license](https://github.com/charlesdove977/re-walkthrough-pro/blob/56fde82d6c2fabf30974b99b49bc55501b244f2e/LICENSE)

## Installer / supply-chain assessment

The inspected installer has **no network calls, subprocess execution, telemetry, credential-reading logic, or external runtime dependencies**. It uses Node's `fs`, `path`, and `os`, then copies packaged skill files. No install lifecycle hook is declared. This is a small, understandable installer; I found no exfiltration behavior in that exact source. This is not an endorsement of automatically following the installed Markdown. [Installer:12–44,52–77](https://github.com/charlesdove977/re-walkthrough-pro/blob/56fde82d6c2fabf30974b99b49bc55501b244f2e/bin/re-walkthrough-pro.js#L12-L77)

Concrete remaining risks:

- Default installation writes an agent skill into the user's global Claude directory, affecting more than this repository; project scope is optional.
- Update and uninstall recursively delete that skill directory, without a backup/merge. Updates can discard local safety edits.
- Unpinned npm/GitHub commands can execute different future installer code. They should not be copied blindly from the screenshot.
- Its `allowed-tools` includes Bash and Write; that declaration is not a security sandbox. [SKILL:1–8](https://github.com/charlesdove977/re-walkthrough-pro/blob/56fde82d6c2fabf30974b99b49bc55501b244f2e/skill/SKILL.md#L1-L8)
- Sibling prompt skills and remotely selected actor/model versions expand the review surface. The README calls siblings optional, while the current camera/task instructions invoke them directly; this is another reproducibility mismatch, not a reason to install more packages automatically.

Installer locations and destructive update behavior: [installer:21–31,47–69,80–87](https://github.com/charlesdove977/re-walkthrough-pro/blob/56fde82d6c2fabf30974b99b49bc55501b244f2e/bin/re-walkthrough-pro.js#L21-L87).

## What is worth borrowing later

Useful ideas: maintain source-photo-to-scene provenance, choose one gentle move per scene, normalize codecs before concatenation, compare expected scene count/duration, and regenerate only an explicitly selected failed scene. The property manifest is a helpful editorial checklist. [Property template:34–57,85–88](https://github.com/charlesdove977/re-walkthrough-pro/blob/56fde82d6c2fabf30974b99b49bc55501b244f2e/skill/templates/property-md.md#L34-L57)

My recommendation is a **small Rendprop-specific, version-controlled reference/checklist**, not a global upstream installation. Preserve the existing server guardrails and approved providers; make exclusions non-destructive; use unique job directories; enforce actual budgets/timeouts; add asserting negative tests; and retain required license attribution for any substantial copied material. This is future work, not a change made here. A standalone creator workflow could be evaluated separately using authorized demo photographs and a user-approved spend cap, after provider privacy/rights review.

The immediate priority remains the existing Rendprop TestFlight build and the owner's real-phone AR capture. This skill does not unblock either.
