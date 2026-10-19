# AI video submission, cost holds and failures

`index.ts` serves authenticated video generation, polling, quality checks and
the gated Bria reflection-removal test. Ordinary reel, aerial and Topaz jobs
use `cost-reservation.ts` before their single provider submission. Provider
adapters live in `../_shared/providers/`.

The [5 October full-system audit](../../../../docs/handoff/FULL-SYSTEM-AUDIT-20261005.md)
describes **source-only changes** below. Its verification uses synthetic local
databases and mocked providers. It does not establish that these migrations,
handlers or signing prerequisites are deployed. Earlier release records describe
their own historical versions; do not infer current production behavior from this README.

## Submission contract

| Provider outcome | Cost journal | Generation allowance | Next action |
|---|---|---|---|
| Local preparation fails before HTTP | Record an explicit status-0 rejection and release the hold | Attempt refund only after release commits | A new intentional attempt needs a new key |
| Definitive HTTP refusal without any job receipt | Record rejection and release the hold | Attempt refund only after release commits | Return sanitized status/class |
| Timeout, HTTP 408/409/425/5xx, or unusable acceptance | Retain the hold | Retain the allowance | Reconcile; never automatically submit again |
| Rejection release cannot be confirmed | Retain the hold | Retain the allowance | Reconcile the journal |
| Accepted receipt | Settle once into the cost ledger | Retain the allowance | Return the receipt so the result remains accessible |
| Accepted receipt but settlement unavailable | Retain the hold | Retain the allowance | Return the receipt; reconcile settlement |
| Accepted job later fails | Keep its accounting receipt | No automatic refund | Report terminal failure; reconcile actual billing separately |

The refusal statuses are `400,401,402,403,404,405,413,415,422,429`. A response
containing a receipt-shaped field, including a nested `request_id`, `job_id`,
`task_id` or `id`, is treated conservatively as uncertain. Status 0 is generated
only by server preparation before a provider request; it is not an HTTP status
or a client assertion. Release is service-only and requires the original actor,
workspace and key. Released records remain immutable tombstones: release does
not authorize another POST with the same key.

Submission-rejection refunds are best effort. The durable release must complete
first, but release and the two quota refunds are not one database transaction.
They now use `refundRateReceipt`, which only decrements the exact window that
charged the attempt. A failed refund needs reconciliation; do not promise a
guaranteed credit refund. These allowances are feature counters, not a customer
cash/credit wallet.

Unresolved holds survive month rollover. Confirmed releases are excluded from
spend; accepted settlement replaces a hold with one ledger row. There is no
automatic hold expiry or fallback after an uncertain submission. The shared
ordinary-video/reflection budget and existing authorization/deletion fences
remain in force. Applying this branch requires
`20261004215403_app_video_rejected_submission_release.sql` before the function
update.

## Original-window receipts and drift refunds — source only

`bump_rate_receipt` returns each charged burst/monthly window. Before dispatch,
`app_video_cost_reserve_v2` confirms those charges and stores immutable window
and optional listing references in `app_video_allowance_receipts`, alongside the
existing priced reservation and permanent idempotency tombstone. A completed
older window never authorizes a refund against a newer counter.

Drift refusal uses the service-only `app_video_refund_drift` transaction. It
requires current actor/workspace authority and an owned, settled provider-request
receipt. It records a refund once, caps refunds at 20 per workspace window and
restores only the original charged quota window. It does not delete provider
spend or provide a cash refund. Only actual `retry`/`refuse` judge decisions call
it; an unavailable judge (`hold`) and an accepted clip do not.

The function update requires `20261005220556_app_video_allowance_receipts.sql`
and the output-intent schema in
`20261005220002_privacy_cleanup_inventory.sql` before serving these paths.
Existing uncertain holds retain their full accounting fence; this change does
not reconcile an unknown paid-provider result or introduce hold expiry.

## Polling and diagnostics

FAL `COMPLETED` can carry `error` or `error_type`; both the adapter and legacy
GET `/ai-video/status` report this as `status: "failed"` without fetching the
result. Definitive completed-result refusal becomes a terminal failure;
HTTP 408/429/5xx retrieval failures retain saved-job recovery.
Successful responses retain `status`, `video_url` and the existing drift block.
An unchecked generated clip is not automatically approved for publishing.

New submissions return signed owner-bound status/response links, including
router-off FAL submissions. The provider request receipt remains available.
Signature, expiry, authenticated actor and selected workspace must match before
credentialed polling. A listing reference comes from the signed submission or
its immutable allowance journal, never a status-request field. Older unsigned
FAL links require an exact actor/workspace/provider/model/request journal match;
possession of a vendor URL alone grants no access.

`JOB_TOKEN_SIGNING_SECRET` is required even when the router is off. Readiness is
checked before quota charges and provider dispatch; an unavailable signer returns
503. Inspect secret-name metadata without printing its value. Rotation affects
existing two-hour signed receipts and needs an explicit recovery plan.

The signed status path registers the actual output key and downloaded byte count
through `register_private_ai_output` before R2 PUT. Registration rechecks current
account/workspace/listing authority and deletion state. A failed registration or
PUT returns a recoverable saved-job error instead of dispatching a new generation.
This inventory does not revoke historical public R2 URLs or recover an unmapped
legacy output automatically.

Responses and submission logs retain provider status, error class and
rejected/uncertain outcome. They exclude raw vendor bodies, prompts, media URLs
and credentials. Provider 401/403 errors do not sign the Rendprop user out.
The FAL admin catalog probe reports key authentication separately from actual
generation availability; catalog success proves neither funded generation nor
model access.

Topaz's conservative maximum-tariff admission and settlement policy remains
unchanged. See [the Topaz cost report](../../../../docs/handoff/TOPAZ-AND-MARGIN-20261004.md).
Cost-ledger values remain estimates until reconciled against provider billing.
These fences do not establish the complete subscription margin policy.

## Verification

From `services/supabase/functions`:

```sh
deno test --allow-read --allow-env --allow-net --node-modules-dir=auto \
  _shared/providers/fal_submission_audit_test.ts \
  _shared/providers/providers_test.ts \
  ai-video/cost-reservation.test.ts \
  ai-video/cost-reservation-handler_test.ts \
  ai-video/fal-status-handler_test.ts \
  ai-video/output-journal.test.ts \
  ai-video/dronecost.test.ts \
  admin/probe.test.ts
```

Provider requests are mocked; network permission allows dependency imports.
To verify SQL with installed PostgreSQL binaries, run from the repository root:

```sh
python3 services/supabase/tests/app_video_cost_pg.py
python3 tools/audit/run_backend_billing_authority.py
```

The runner uses a fresh owned Unix-socket-only cluster, clears inherited
credentials, and records source hashes, actual concurrent admission/settlement
results and a removed-lock negative control. No live database or paid provider
call is involved. The dated [evidence summary](../../../../docs/handoff/PROVIDER-DISPATCH-REJECTION-20261004.md)
records results and investigation limits.
