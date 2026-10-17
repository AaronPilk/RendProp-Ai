# Durable property videos (build79)

The actor-authenticated API freezes1–100 exact owned photo-version receipts,
order/motion, presentation, narration and optional pinned licensed music. It
continues after the app exits only after a successful durable enqueue. It never
publishes automatically. The separate service-only worker is the sole dispatcher.

## Client contract

All client routes require a fresh named-user JWT. Listing routes check current
write access and the selected library; jobs return physical `org_id` separately
from logical `selected_library_org_id`. Creating/resuming work additionally
requires an AI processing permission header:

- `x-rendprop-ai-consent: property-video-jobs-v1`: the original permission.
  Creates legacy/FAL work only; resumes only a job saved under v1.
- `x-rendprop-ai-consent: property-video-jobs-v2` with
  `x-rendprop-ai-consent-disclosure: <disclosure_revision>` (1-200 visible
  ASCII): the user allowed the listed processors of the CURRENT published
  disclosure (`GET /processor-consent`). Required to create a native-4K Kie
  video, accepted for any other create, persisted on the job and immutable.
  Resume needs only the v2 token and accepts it for any job.
- Anything else: 403 `consent_required`.

Processor-permission refusals are fast and clear; SQL
(`property_video_job_admit_v2`) re-enforces every rule at admission:

- Create, native-4K recipe without v2, or any v2 naming a stale revision: 403
  `processor_consent_required` `{error, code, operation_id, listing_id,
  selected_library_org_id, processor_consent:{token, disclosure_revision,
  processors}}` (show that disclosure, then retry with its revision).
- Create needing that check while no disclosure is published: 403
  `processor_disclosure_unpublished` (same context fields).
- Resume with v1 for a job saved under v2: 403 `processor_consent_required`
  `{error, code, job_id, required_consent:"property-video-jobs-v2"}`.
- Optional owner-only `x-rendprop-quality-test-grant: <uuid>` on create
  (malformed: 400). SQL checks the exact grant scope (actor, listing, ordered
  sources, operation, expiry, budget) and the recipe is quoted with the saved
  native-4K profile; without the header the global selector decides, unchanged.
  Every paid Kie clip re-checks the grant and consumes one create per attempt.
- `GET /property-video-jobs/processor-consent`: 200 `{token,
  disclosure_revision, processors, profiles}` (no-store), or 404
  `processor_disclosure_unpublished`.

- `POST /property-video-jobs`: frozen `JobInput`, header
  `Idempotency-Key: property-video:<operation_id>`. Returns202 full `JobReply`.
- `GET /property-video-jobs/:job_id`: fresh progress/result. Result URLs are
  short-lived private capabilities; clients must refresh and never persist them.
- `GET ?listing_id=&expected_org_id=&operation_id=`: exact operation/context
  echoes, `job` (explicitly null when absent), `operation_closed` and
  `closed_reason` (`capacity_refused`, `abandoned` or null). Only a durable
  capacity refusal or an explicit discard closes an operation. Admission,
  refusal, discard and lookup serialize the same DB operation; closed
  operations cannot enqueue. A missing `closed_reason` from an older
  deployment means `capacity_refused`.
- `POST /operations/:operation_id/abandon` `{listing_id,expected_org_id}` with
  `Idempotency-Key: property-video-abandon:<operation_id>` (C2). No AI consent
  or new work. Returns 200 with the lookup shape after resolving the exact
  operation under its admission lock: an accepted operation returns its
  existing `job` unchanged (cancel/recover it normally); a capacity refusal is
  reported as `capacity_refused`; only an operation the server never accepted
  or refused is permanently tombstoned (`closed_reason:"abandoned"`). Replays
  return the same outcome. A later `POST /property-video-jobs` for that
  operation returns 409 `operation_abandoned`; if a discard commits after the
  route's pre-check, the database fence refuses admission with 409 instead.
  Tombstones are per actor, never move to another property and require the
  same write access and library as creation. Clients must not forget a saved
  request locally until this route (or the lookup) confirms the outcome.
- `GET ?listing_id=&expected_org_id=&offset=`: bounded20-job history.
- `GET /sources?listing_id=&expected_org_id=&offset=`: actual selected gallery
  masters (100/page), exact version/provenance and ready prepared aliases.
  Explicit gallery IDs keep their saved order. Legacy Studio photo rows use
  their saved gallery order and chosen edited key; a missing or withdrawn edit
  stays unavailable rather than silently becoming the Original. Only libraries
  without photo rows use the chronological capture fallback. This projection
  does not change a saved video's frozen recipe or the user's manual tap order.
- `POST /sources/prepare`, key `property-video-source:<operation_id>`: owned
  selected JPEG/PNG/WebP master→video JPEG alias. Original/export/gallery master
  stays unchanged. GET `/sources/prepare/:preparation_id` refreshes its receipt.
- `POST /:job_id/cancel`: durable stop, full `JobReply`, preserves ready output.
- `POST /:job_id/resume` `{}`: explicit same-job capacity-pause recovery. Only
  proven non-dispatched attempts reset; accepted/private clips remain. Maximum
  three pre-dispatch resume cycles and original four-hour deadline remain.
  Active/ready lost-reply replays return the current reply without another cycle.
- `POST /cancel-all` `{operation_id,reason}` with
  `Idempotency-Key: property-video-stop:<operation_id>`: actor-wide privacy stop,
  including pending image preparation. This route needs neither AI consent nor
  the outgoing library. Its first count is replayed without stopping later jobs.
- `POST /audio/prepare`: actor/operation/listing, exact bytes/SHA/MIME. Ready
  replay needs no PUT. Typed own audio uses `audio/mp4` or `audio/mpeg`,≤20MiB.
- `POST /audio/:id/complete` verifies retained bytes/SHA; Studio can use the
  authenticated `PUT /audio/:id/content` gateway instead of broad R2 browser CSP.

Job states: `queued`, `generating`, `quality_review`, `composing`, `ready`,
`cancelled`, `failed`, `needs_reconciliation`. `resume_available` is true only
for a live, safe pre-dispatch capacity pause. Ready includes exact master/poster
asset IDs, measured1080 geometry, SHA/bytes, all ordered source receipts,
truthful original-photo fallback count and pinned music evidence. Native/browsers
must review the private master and explicitly Publish/Republish it.

## Private execution

Worker JWT gateway policy is deliberately false because modern service secrets
are not user JWTs. The handler checks the exact configured service credential
before any parse/read. This does not grant public/actor impersonation access.
Two fixed CPU slots and DB admission allow two in-flight sources/job and four
supplier attempts globally. Every paid attempt still uses the existing price,
quota, paid-window money hold, ledger binding, provenance and source QC helpers.

An accepted signed provider receipt is retained even if settlement/provenance
reconciliation is temporarily unavailable. It is polled without another POST.
Unknown acceptance never blindly retries. Definitive capacity failure pauses
without replacing motion with a photo; explicit resume reuses completed work.
The upfront whole-recipe capacity check is conservative but is **not** a parent
reservation: another device/job can consume capacity afterwards.

Narration gets an initial `inspect_audio` CPU phase before any paid video clip.
The exact audio is fully decoded and measured. Edge compares its duration with
`5*n-(n-1)*(dissolve?8/30:whip?5/30:0)` plus0.1s codec tolerance. Long/invalid
speech is refused without trimming or paid clip dispatch. VoiceOff skips this.
Callbacks are leased, source/manifest-bound and replay-safe. CPU phases alone
retry at most three times. Preparation performs EXIF orientation/ICC→sRGB on a
working copy; the full original remains the export master.

Known cancelled supplier receipts may be polled as status JSON only. A verified
terminal result frees their concurrency slot without video download, new input,
QC, refund, hold release or ledger change. Truly unknown acceptance remains
fenced until deadline. Completion queues one current-actor/current-device APNs
notice; cancellation/revocation never changes the notification recipient.

## Activation and release ownership

Source ships with `app_config.property_video_jobs.enabled=false`, Cloudflare
Worker `ENABLED=false`, and each music catalog track disabled. No deployment,
service resources, credentials, allocations or charges were made by these tests.
Root owns migration/deploy/activation, exact image digest, actual provider/phone
acceptance and App Store release. The existing Store74 candidate is unchanged.

Apply reviewed migrations in order:
1. `20261014183851_background_property_videos.sql`
2. `20261014193515_property_video_prepared_sources.sql`
3. `20261014200302_property_video_recipe_allowances.sql`
4. `20261014202049_property_video_index_pages.sql`
5. `20261014213831_registered_background_video_delivery.sql`

Deploy the reviewed functional closure: `property-video-jobs` (JWT true),
`property-video-worker` (JWT false/private credential), `property-video-plan`,
`ai-video`, `notify`, `tours`, `listings`, and the sibling's `studio` projection.
Shared provider adapters also appear in `ai-photo`/`admin` bundles; root should
use the deploy tool's exact closure/readback and decide those deployed identities.
No additional Supabase secret names are introduced. Existing service, R2,
provider, job-token signing and APNs config remain required. The dedicated
Cloudflare service needs `EDGE_SERVICE_ROLE_KEY` and `RENDER_TRIGGER_KEY` plus
exact `MEDIA_HOSTS`; the CPU gets no provider, database or R2 admin secret.

## Reviewed usage policy

Starter/legacySolo30, Pro60 and Team150 generated shots; raw legacy trial20.
Future trial offer20 edits, ceiling1500¢, inclusive schedule upper bound1500¢.
Free300¢ lifetime and the existing$290 trial pool/enddate stay unchanged.
Paid allocation is50% of verified net receipts less existing hosting reserve:
current15%commission Starter2032¢, Pro4157¢, Team10532¢. Individual meter maxima
are not promised to fit simultaneously. Current FAL catalog20-shot/QC bound is
676.908¢;20 default2K stages622.592¢ plus conservative planner20¢ totals1319.50¢.
Actual routing/costs can change and the server reprices before admission.

Existing funded receipt replays/slices and prior trial caps/used counters retain
original budgets; a new attested trial schedule or paid renewal is required for
larger funded commitments. This migration seeds no sponsor dollars or funding.
High-cost Kling promotion is not implied by these allowances. Hosted CPU100-shot
throughput, real locked-phone completion/APNs, actual default supplier output
quality, real narration and fresh normal-customer/trial admission remain release
acceptance items; synthetic fixture colors do not certify them.

## Local verification

- `python3 services/supabase/tests/property_video_jobs_pg.py`: actual migrations,
  RPC/roles/source/payment/output/privacy and concurrent admission/cancel races,
  plus compiled missing global-lock/audio-duration negative controls.
- `python3 services/supabase/tests/property_video_abandon_pg.py`: C2 discard
  RPC/trigger/roles, concurrent discard versus enqueue/admission/refusal,
  held-lock interleavings in both orders, read-committed fail-closed checks
  and compiled lock/fence/isolation negative controls.
- `python3 services/supabase/tests/property_video_websites_pg.py`: explicit
  publication/immutable output/reselect/refund/consumable assignment regressions.
- `deno test --allow-env --allow-read --allow-net` on `ai-video`, `notify`,
  `property-video-jobs`, `property-video-worker`, `property-video-plan`, `tours`:
  closed Auth/PostgREST/R2/provider transports; actual route/adapters/crypto run.
- Studio `tests/deployment-tooling.test.ts`: explicit safe first deployment,
  private false-JWT boundary, exact transitive source/policy readback controls.

## Registered large-master delivery

An exact ready immutable background master may be up to1536MiB. Generic media
objects and the ordinary admission RPC keep their256MiB bound. The private/public
gateway receives server-derived `object_limits` only after ready job/output,
asset/SHA/size, current source/library and visibility checks. A large read names
its exact admitted key and consumes all<=256MiB budget chunks in one database
transaction; any later refusal rolls back every chunk. No larger generic grant
or funding allocation is created. Active responses stream without whole-body
buffering with a30min total/60s idle bound. Private capabilities still authorize
new requests for600s; retries/seeks after expiry require a refreshed capability.
