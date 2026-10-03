# Bria and saved-photo versions beta — 2 October 2026

## Delivery status

Internal **TestFlight 1.0.3 (43): AVAILABLE**, verified **2026-10-03 00:55:46 UTC**
(2 October locally) for the existing Rendprop team. Apple build
`da5b14ab-5e37-4125-a5fa-35d671bc1927` is VALID / INTERNAL_ONLY / IN_BETA_TESTING,
not expired and included in the existing internal group. English testing notes
were verified at 00:56:33 UTC. One upload succeeded; no tester/group changes or
public App Store submission were made for 43.

The [delivery receipt](../releases/TESTFLIGHT-43-20261002.json) binds runtime
`8de8fd070eec2d55b0f62e12fe8488c99752e8a3`, all twelve passing CI jobs, the
source-bound signed archive and Apple readbacks. **ai-video v47** is ACTIVE with
JWT verification; all **30 API-listed files** byte-match that source. The migration
is live as **`20261003003531`**, from source
`20261002225458_video_erase_direct_bria.sql`; do not apply it twice. Schema was
applied before the handler, then source, all twelve SQL function bodies, expected
grants, RLS and six private configuration values were verified. Job/stage client
access is denied; the existing membership-scoped held-cents read remains.
Security readback adds no ERROR/WARN over the existing 26 WARN entries. Quote and
status GETs without authorization both return 401 before provider work.

Regular **App Store 1.0.3 (42)** remains a separate submitted release. Its
[handoff](APPSTORE-42-20261002.md) and
[receipt](../releases/APPSTORE-42-20261002.json) are immutable snapshots. Internal
build 43 retains spatial testing. The public build-42 binding and Waiting for
Review state were read back after the internal upload. No global provider override
was enabled; regular App Store clients retain their existing fal transport.

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

The latest migration also preserves Presenter ancestry checks before reads,
idempotent replay, acceptance and each paid admission. Late receipts retain
once-only accounting while revoked output URLs are redacted. Current-schema,
historical-replay and direct-replay tests pass 119 checks plus the controller
integration; a pre-fix migration is rejected before historical replay can repair
its missing guard. Historical migrations remain unchanged.

## Narrow output-host starting point and recovery limit

The deployed starting allowlist contains only
**`d1ei2xrl63k822.cloudfront.net`**. A real February 2026
[Bria-owned eraser example](https://replicate.com/bria/video-erase-object/examples)
logs its native output under `/api/video/res/` on that exact host before copying
it to Replicate delivery. Bria's
[upscale example](https://replicate.com/bria/video-increase-resolution) independently
uses the same host. This is historical ownership/use evidence, not proof that
current direct v2 mask and erase outputs both use it. Current official video
OpenAPI examples use placeholder result URLs; SDK examples do not establish a
current generated-video host.

The beta is enabled for **one trusted owner** using six digest-confirmed private
configuration values. The exact output host and 2¢/4.5¢ stage rates above are
configured; the provider token already existed and was not read or embedded in
the app. Only the exact configured hostname is trusted. HTTPS, URL validation, rejected
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

All twelve CI jobs passed on the uploaded source in
[run 37081287467](https://github.com/AaronPilk/RendProp-Ai/actions/runs/37081287467).
The earlier `e140442` candidate exposed missing Presenter ancestry/revocation
guards in the new RPC replacements. Those were restored in `8de8fd0` and rejected
by a pre-fix negative control before deployment; historical migrations were not
rewritten.

The first CI attempt on `8de8fd0` retained a real transient source-playback failure:
the synthetic Studio export lasted **8.607033 seconds** with a **607 ms frame gap**
and brief original-audio dropout. A single strict rerun on identical source passed
all twelve jobs. Its actual H.264/AAC finishing artifact passed **11/11 checks**,
lasted **8.0355 seconds**, changed to the photo at **4.05 seconds**, and recorded
zero browser errors or external requests. The previously passing base artifact
lasted **8.023167 seconds**. Failed and passing artifacts remain preserved privately;
no exporter, fixture or tolerance changes were made. A passing rerun does not
certify every timing condition under load.

The final signed archive matches all **218 tracked inputs**, 139 tracked Swift
sources plus one generated source, and arm64 UUID
`21C2F4EF-ABD7-37DF-9DBF-443F0D25F04B`; archive and DerivedData dSYM bytes match.
Local UI checks used the earlier native candidate with production native code
identical to the final archive; backend guards/tests and documentation changed
after those runs. Simulator checks are separate from uploaded-archive phone acceptance.

The retained **actual uploaded IPA** was independently verified: valid Apple
Distribution signature, Team `5F5C5G25Y6`, build 43 and the same arm64 UUID. Its
37 file-backed native sections and seven resources byte-match the source archive;
all eleven IPA app files match the retained re-signed app. The transfer-log path
and checksum bind the package to the recorded upload. The IPA SHA-256 is
`bb5f943ff98273989aac60f5fafdb37d1f87023fe5d901fb3ae21699439cd8c6`.
Re-signing changes the executable checksum; no byte equality of the complete
signed executable is claimed. The IPA and customer evidence remain private.

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
| [Actual gallery-sync harness](../../tools/audit/gallery-sync-20261002/run.py) | 46 assertions over real synchronization/history source and held upload/API boundaries; three controls reject unrelated-error clearing, stale selection and missing provenance. Source files are synthetic and isolated. |
| [Reel failure tests](../../apps/ios/tests/ReelClipFailureTests.swift) and [runner](../../apps/ios/tests/run-reel-clip-failures.sh) | 80 assertions over the actual production loop and recovery code; swallowed-error mutation caught. API/media doubles, no network/provider calls. |
| [Reflection controller runner](../../tools/audit/call-20260919/reflection-controller/run.py) and [active fixture](../../tools/audit/call-20260919/reflection-controller/checks.swift) | 20 named scenarios, including seven consent boundaries; permission-epoch mutation caught. Historical baseline still reproduces its cancellation race. Controller/journal are real; video/API/upload implementations are doubles. |
| [Saved-photo UI regression](../../apps/ios/RendpropUITests/BetaPolishUITests.swift) | New actual Debug UI library/compare/export-selection/publication case and five existing queue/contact/metadata/room-tag regressions passed in preserved runs: six tests, zero failures/skips in those accepted runs. The new case also passed one focused Release/arm64 simulator run on build 43. MockAPIClient and synthetic legacy photos; no save-to-Photos, upload, paid generation or camera certification. Exact-source CI/archive/Apple delivery is separately verified above. |

Useful focused commands from the repository root:

```bash
node --test tests/phase1/consent-disclosure.test.mjs tests/phase1/consent-contract.test.mjs
bash apps/ios/tests/run-photo-delivery.sh
bash apps/ios/tests/run-reel-clip-failures.sh
python3 tools/audit/call-20260919/reflection-controller/run.py
deno test --deny-net --deny-env services/supabase/functions/ai-video/bria_test.ts services/supabase/functions/ai-video/erase_test.ts
python3 services/supabase/tests/video_erase_direct_bria_pg.py
```

## Delivery verification and phone acceptance

1. Completed: exact-source CI and regular/internal build checks; schema before
   handler; JWT, deployed source, grants, RLS and private beta configuration readbacks.
   Tester IDs and credentials remain outside Git.
2. Completed: signed source-bound internal archive, one upload, Apple processing,
   internal availability and English testing notes. The delivery receipt records
   the exact versions, hashes and verification limits.
3. On an authorized phone, install available build 43 without
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
