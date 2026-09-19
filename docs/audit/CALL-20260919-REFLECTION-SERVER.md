# Video reflection removal server — 2026-09-19

Implementation is ready for review; production output quality remains **NO-GO**.
The real Bria smoke attempted by the parent task was rejected HTTP 403, exhausted
fal balance, before a request ID or output existed. This report does not claim a
successful provider run, customer-room quality, deployment, or invoice reconciliation.

## Delivered contract

- `GET /ai-video/declutter/quote?listing_id=UUID`: advisory remaining clip allowance,
  4.8s target clip limit, 240¢ batch ceiling, 14¢/input second and org COGS headroom.
  A configured key does not prove provider credit availability.
- `POST /ai-video/declutter`: complete public video `asset_id`, matching `listing_id`,
  UUID `batch_id`, `purpose:"reflection_removal"`, optional bounded guarded prompt,
  and stable UUID `Idempotency-Key`. It returns 202 with an owned durable job ID and
  server status URLs. Identical repeats recover that receipt without another media
  read, quota charge or paid dispatch; different input with the same key conflicts.
- `GET /ai-video/status?erase_job=UUID`: caller/org-owned status. The same job ID is
  supported inside this endpoint's encoded `status_url` / `response_url` parameters.
- `POST /ai-video/declutter/cancel`: `batch_id` or `request_id`. Either cancels its
  whole batch and refunds each original quota receipt once. A batch cancellation
  arriving before the first POST creates a durable tombstone. Late submission 409
  consumes nothing. An applied batch 409 cannot be discarded retroactively.
- `POST /ai-video/declutter/apply`: `batch_id`, distinct full `original_asset_id` and
  `altered_asset_id`. Both are complete video uploads with role/bucket `render` /
  `renders`, same listing and matched duration ≤600s. Every selected job must have
  finished and remain unrefunded. Acceptance creates one linked, truthful video
  disclosure; identical retries recover it. Clip assets cannot masquerade as the
  full walkthrough. The public pair plays both videos and links the unedited one.

## Money, races and authorization

Migration 0055 defines service-only RPCs and RLS-closed job/batch tables. Every
external action checks current owner/admin/agent membership, org, listing and
asset scope. Org locks serialize reservation, cancellation, state transition and
acceptance. The claim commits before the provider POST; an uncertain outcome is
never automatically re-dispatched. Existing role/route flags and disabled models
are unchanged.

Bria's account-authenticated pricing endpoint was verified by the parent task on
2026-09-19: `$0.14`, unit `seconds`, currency `USD`. It agrees with the
[model page](https://fal.ai/models/bria/video/erase/prompt). Admin inventory,
`APP_AI_UNIT_CENTS` and `HANDOFF-DB.md` now use 14¢/input second; the old 4¢/clip
image-inpainting placeholder is removed. Confirmed provider receipts record the
verified rate once, with `price_estimated:false` and `billing_reconciled:false`.
This is priced provider usage, not proof of the eventual invoice.

SQL reserves the precise verified video duration×14¢, sums it across the batch,
and refuses above 240¢. The shared monthly-spend RPC includes unresolved cost
holds, with an authorization-scoped aggregate for tenants. Reflection transitions
share the existing `org_month_spend` advisory lock with `log_job_cost`. Quote limits
also shrink to the remaining monthly headroom. Legacy app-AI routes still use
best-effort ledger writes after provider work; this change does not redesign
reservations for every existing provider route.
Monthly and burst allowance receipts store the exact charged windows. A late
refund cannot decrement a replacement window, and cancellation never reverses
provider COGS. Definitive prequeue HTTP 4xx rejection releases the unbilled hold;
5xx, timeout or lost response retains it for reconciliation. Stale dispatch claims
expire after 2 minutes and processing jobs after 30 minutes when status, quote or a
new submission is accessed. User allowance returns even if the app lost the job
receipt. Unresolved provider holds deliberately survive this expiry.

The upload API stores client-claimed duration. The new bounded MP4 probe therefore
checks actual container movie/track/media/sample timing and sample counts before
reservation: `mvhd`, `tkhd`, `mdhd`, `stts`, `stsz`; one video track, no fragmented
movie, ≤2 MiB metadata, ≤64 box reads, 15s overall read deadline. It skips media payload
with range requests. Strict<5s and cost use the longest video timeline, including
encoder padding; full-pair comparison uses the movie presentation duration.
Audio/video priming differences are bounded to 150ms. Invalid or inconsistent
media fails before quota/provider. This checks container/sample-table consistency;
it does not decode video or defeat fully fabricated internally consistent headers.

Acceptance verifies real full-video durations too, but does not cryptographically
prove that every frame in the uploaded splice is the provider result. The user's
explicit original/result review remains the content-quality gate. Legacy photo
provenance RPCs stay photo-only; accepted video provenance cannot be relinked via
legacy PATCH. Deferred foreign keys preserve legitimate listing deletion cascades.

## Verification

- Actual production handler with injected external boundaries: 13 Deno tests,
  covering preflight/no-charge, actual media duration mismatch, duplicate receipt,
  ambiguous dispatch/no retry, provider rejection, missing key, persistence,
  cancellation race, expired claims, status ownership links and apply receipt.
- Those plus existing drone/motion/drift suites: 147 tests pass. Old source-slicing
  tests now use route boundaries because the durable status dispatcher moved
  ahead of the old routes; their guard assertions remain unchanged.
- Clean native PostgreSQL 17: every migration 0001–0055 in order; 0055 replayed;
  51 transactional authorization/quota/cost/refund/provenance/deletion assertions
  pass before and after replay. Forty-six real parallel transactions exercise
  duplicate dispatch, duplicate COGS, cancellation/completion, 240¢ batch cap and
  cancellation racing the first reservation, and eight reflection-versus-pipeline
  monthly-ceiling races. PostgreSQL 16 container CI now has
  both contract/replay and parallel tests; its result is a separate required gate.
- Four real ffmpeg source files (fast-start/tail metadata, audio, 4.8s/10s/600s)
  pass the actual probe. A real 10s file with only its movie duration forged to 3s
  is refused. Twenty synthetic native AVFoundation fixture MP4s pass read-only
  probing, including extraction, splicing, portrait, fractional rate and HDR.
  The 600.75s fixture parses correctly but is refused by the ≤600s apply boundary.
- Tour-host TypeScript check and all seven npm gates: 2,698 assertions pass.
  A separate actual-renderer video disclosure check passes 25 assertions for
  branded and MLS-safe output; neither emits the original video as an image or
  applies a photo slider to it. No vendor/pricing details appear in tour UI.
- `deno check` passes for ai-video, admin and tours; no deployment or paid call
  was performed by this subtask.

Evidence runners: `tools/audit/call-20260919/web/run-erase-postgres.py`,
`erase-concurrency.py`, `real-mp4-probe.py`, `probe-mp4-fixture.ts`,
`video-provenance.mjs`; production tests: `ai-video/erase_test.ts` and
`services/supabase/tests/video_erase.sql`. Native logs and generated media are
outside Git. The provider smoke receipt is owned by the parent task; no customer
media or credentials are committed here.

The first pushed candidate subsequently passed the new reflection checks in the
PostgreSQL16 service container (51 assertions twice and 46 parallel transactions /
43 checks), and the full Supabase edge suite passed 802 tests. Older database gates
exposed separate baseline issues; see `CALL-20260919-CI-DATABASE.md` for their
reproduction, bounded 0056 repair and historical replay correction.
