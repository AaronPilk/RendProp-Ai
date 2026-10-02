# Bria and saved-photo versions beta — 2 October 2026

## Delivery status

Internal **TestFlight 1.0.3 (43): PREPARING**. Build 43 has not been uploaded or
verified available in Apple. The direct-Bria migration and dependent `ai-video`
changes have not been deployed. Final exact-source CI, signed archive, deployment
readbacks and Apple availability remain delivery gates. This document records
prepared behavior and local verification; it is not a delivery receipt.

Regular **App Store 1.0.3 (42)** remains a separate submitted release. Its
[handoff](APPSTORE-42-20261002.md) and
[receipt](../releases/APPSTORE-42-20261002.json) are immutable snapshots. Internal
build 41 remains the delivered spatial beta until build 43 availability is
verified. No App Store binary or production provider selection is changed by
preparing this beta.

## Direct Bria is an explicit internal beta

The internal `SPATIAL_CAPTURE_LAB` scheme can send the direct-Bria processor
acknowledgement after the person grants the new disclosure. The server also
requires `BRIA_BETA_ENABLED=true` and an explicit `BRIA_BETA_USER_IDS` allowlist
containing the authenticated user ID. The allowlist is server configuration;
client-supplied IDs cannot establish eligibility. A token alone does not select
Bria. Normal App Store clients and other users retain the existing fal reflection
transport. An eligible beta request with unavailable pricing, hosts or credentials
fails before dispatch instead of silently switching providers.

The consent disclosure names direct **Bria** separately from fal's model list.
Its preference key is `ai.thirdPartyProcessing.consent.v3`; a stored v1 or v2
grant does not authorize this disclosure. The wire acknowledgement is
`bria-video-v1`. Revocation stops unsent work and cancels the local reflection
workflow. Completed provider work cannot be recalled; admitted spend remains
recorded. No provider credential belongs in the app or this repository.

The [direct adapter](../../services/supabase/functions/ai-video/bria.ts) follows
the current official [masking](https://docs.bria.ai/video-editing/masking) and
[eraser](https://docs.bria.ai/video-editing/editing/erase-object) contracts:
one mask submission, status reads, then one separately admitted eraser submission.
The application requires measured clips under five seconds, requests
`auto_trim=false`, MP4/H.264 and preserved eraser audio. Bria documents a 750p
processing limit and recommends 24 FPS. These constraints and requested options
do not certify removal quality, audio delivery or preservation of room geometry.

## Price, credits and durable accounting

Signed-in Bria catalog readback on 2 October confirmed **2¢/second for masking**
and **4.5¢/second for erasing**. Those are catalog rates, not an invoice or a
successful billed-provider trial. Server configuration must pin the confirmed
rates and a price version for each job. Invoice reconciliation remains separate.
Bria's provider-side free allowance does not bypass Rendprop's AI clip allowance,
workspace processing budget or user consent.

The existing **240¢ reflection-batch fence** remains. Both stage amounts are
reserved against the workspace ceiling before the first paid POST. Each stage
has a committed admission receipt before dispatch, an immutable provider reference
and once-only rate-based cost accounting. Accepted mask work is accounted for even
if erase is never submitted. Ambiguous dispatch retains its hold for reconciliation.
There is no automatic paid POST retry or provider fallback. Cancellation/failure
returns the user's clip allowance to its original quota window and releases
unpaid later-stage holds; it does not erase provider spend already incurred.

The [migration](../../services/supabase/migrations/20261002225458_video_erase_direct_bria.sql)
pins provider, models, rates, consent and output hosts per job. Current configuration
changes do not reroute existing jobs. Stage admission checks current authorization,
source availability, cancellation and the processor acknowledgement again.

## Narrow output-host starting point and recovery limit

The proposed starting allowlist contains only
**`d1ei2xrl63k822.cloudfront.net`**. A real February 2026
[Bria-owned eraser example](https://replicate.com/bria/video-erase-object/examples)
logs its native output under `/api/video/res/` on that exact host before copying
it to Replicate delivery. Bria's
[upscale example](https://replicate.com/bria/video-increase-resolution) independently
uses the same host. This is historical ownership/use evidence, not proof that
current direct v2 mask and erase outputs both use it. Current official video
OpenAPI examples use placeholder result URLs; SDK examples do not establish a
current generated-video host.

Only the exact configured hostname is trusted. HTTPS, URL validation, rejected
redirects, credential-free media downloads and bounded size/time apply; there is
no wildcard CloudFront, S3 or CDN permission. The API token is sent only to the
fixed Bria API/status origin. A current result at any other host fails closed.

An unknown mask host can strand a **paid mask output**: the accepted reference and
cost ledger remain, but no usable output URL is stored and erase is not admitted.
An unknown final eraser host can strand both paid stages. The current poll returns
a status error, then timeout or cancellation returns the user allowance and
releases unpaid holds. The existing job's pinned allowlist cannot be repaired by
changing the environment, and terminal jobs do not resume through normal app
polling. Recovery would require an explicit service-only procedure using the
retained provider reference; no such recovery flow is delivered here. The narrow
allowlist is a bounded beta starting point, not a promise of end-to-end output
availability or recovery. No paid live Bria generation was used for these local
verification results.

## Saved-photo libraries, downloads and listing selection

**Photos → Latest / Decluttered / Staged** now exposes the newest applicable saved
version per photo family. Browsing an older clean version does not replace the
latest editing workspace. Compare offers saved-version chips and **All edits**;
retained verified originals remain available. Legacy source files with incomplete
history are labeled **Earlier source**, not certified as unaltered originals.

**Download decluttered photo**, **Download staged photo** and **Download original**
or **Download earlier source** open export with the version currently being viewed.
The export sheet retains full available resolution by default, original aspect,
destination disclosures and optional reviewed framing. Files and Photos delivery
do not mutate stored versions or select a public listing photo.

**Use this version on listing** is a separate explicit choice. Staging remains a
preview until chosen. Selecting the decluttered version for publication leaves
the latest staged workspace and its saved bytes available, without another paid
edit. Native publication reconciles the selected gallery while preserving
concurrent eligible cloud additions. Version lineage itself remains local to the
iPhone; another device does not receive a complete shared history or all original
and edited files merely because a listing photo was published.

## Reel failure and resume behavior

Reel generation stops at the first failed photo and shows its position and a
readable recovery action. It retains previously completed clips; **Finish reel
from saved clips** can finish with those clips without regenerating them. Returning
to setup does not imply that the failed paid request was uncharged, and the app
does not automatically resubmit it.

Read-only production evidence showed 18 `reel-clip` HTTP 502 responses in the
20:35–20:49 UTC interval, with repeated upstream provider failures. The configured
fal model path/input shape agrees with its current official contract. The precise
fal account/provider cause remains unproven. Prepared backend diagnostics record
only provider/model, known error class and HTTP status, without raw provider bodies,
media or credentials. The native stop/resume fix is not proof that the upstream
service has recovered.

## Verification and evidence boundaries

All **27 available beta attachments were reviewed**. The reviewed feedback and
readback surfaced **0 new crash reports**; this is not a complete crash census.
Customer screenshots, contact information, account identifiers and audit evidence
remain private outside Git.

| Check | Local result and scope |
| --- | --- |
| [Consent disclosure](../../tests/phase1/consent-disclosure.test.mjs) and [actual persistence fixture](../../tests/phase1/AIConsentPersistenceTests.swift) | Exact production consent source: 25 grant/relaunch/revoke/decline/cancel assertions and 20 separate old-v2 migration assertions. Reusing v2 was caught by a privacy mutation control. Combined disclosure/scroll contracts pass 11 tests. |
| [Direct adapter tests](../../services/supabase/functions/ai-video/bria_test.ts) and [handler tests](../../services/supabase/functions/ai-video/erase_test.ts) | Network/environment-denied fixtures cover contract shapes, hosts, byte/time limits, consent/cohort selection, rejected versus ambiguous dispatch and durable stage flow. No paid provider or real output-quality test. |
| [Direct SQL contracts](../../services/supabase/tests/video_erase_direct_bria.sql) and [owned PostgreSQL runner](../../services/supabase/tests/video_erase_direct_bria_pg.py) | Fresh/replay policy checks and eight-connection admission/receipt races pass on disposable native PostgreSQL; no production migration applied by these tests. |
| [Photo history tests](../../apps/ios/tests/PhotoVersionHistoryTests.swift) | 340 assertions; two mutation controls caught library/selection regressions. Stored source/history tests do not certify generated-photo fidelity. |
| [Reel failure tests](../../apps/ios/tests/ReelClipFailureTests.swift) and [runner](../../apps/ios/tests/run-reel-clip-failures.sh) | 80 assertions over the actual production loop and recovery code; swallowed-error mutation caught. API/media doubles, no network/provider calls. |
| [Reflection controller runner](../../tools/audit/call-20260919/reflection-controller/run.py) and [active fixture](../../tools/audit/call-20260919/reflection-controller/checks.swift) | 20 named scenarios, including seven consent boundaries; permission-epoch mutation caught. Historical baseline still reproduces its cancellation race. Controller/journal are real; video/API/upload implementations are doubles. |
| [Saved-photo UI regression](../../apps/ios/RendpropUITests/BetaPolishUITests.swift) | New actual Debug UI library/compare/export-selection/publication case passed: one test, zero failures/skips. MockAPIClient and synthetic legacy photos; no save-to-Photos, upload, paid generation or camera certification. Remaining release-wide gates are pending. |

Useful focused commands from the repository root:

```bash
node --test tests/phase1/consent-disclosure.test.mjs tests/phase1/consent-contract.test.mjs
bash apps/ios/tests/run-photo-delivery.sh
bash apps/ios/tests/run-reel-clip-failures.sh
python3 tools/audit/call-20260919/reflection-controller/run.py
deno test --deny-net --deny-env services/supabase/functions/ai-video/bria_test.ts services/supabase/functions/ai-video/erase_test.ts
python3 services/supabase/tests/video_erase_direct_bria_pg.py
```

## Delivery gates and phone acceptance

1. Pin the final runtime source and pass its required CI/regular and internal-beta
   build checks. Apply the reviewed schema before the dependent handler, preserve
   JWT/authentication settings, and verify deployed source/grants/configuration.
   Keep real tester IDs and credentials outside Git.
2. Archive the internal scheme as build 43, inspect its actual package, upload once
   and read back Apple processing, internal availability and testing notes. Record
   deployed versions and final receipts before calling this release delivered.
3. On an authorized phone, install 43 after availability is verified without
   deleting saved work. Confirm v2 consent requires a fresh v3 disclosure, decline
   blocks the tool, and revocation stops unsent work during quote/upload/poll.
4. Compare saved Latest/Decluttered/Staged photos with their retained source. Check
   verified **Original** versus legacy **Earlier source** labels, viewed-version
   export to Files/Photos, available resolution and disclosure. Choose publication
   separately; verify the selected public photo and retained local latest workspace.
5. Exercise one bounded, explicitly accepted reflection interval with the private
   beta cohort only after configuration is ready. Check audio/timing, removal masks,
   mirrors, architecture and original/edited comparison. Inspect stage receipts and
   quota/spend behavior if a host or provider fails; never use a hidden paid retry.
6. Verify a reel interruption stops at the failed photo and retains earlier finished
   clips across the documented recovery path. Finishing saved clips must not generate
   them again. A successful phone result is separate from proving the fal outage cause.

Simulator checks and these software fixtures do not certify camera framing,
physical lenses, AR/LiDAR, thermal behavior, walking motion, room reconstruction,
staging consistency or generated-media quality. Those remain real-phone and
human-review acceptance work.
