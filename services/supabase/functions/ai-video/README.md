# AI video submission, cost holds and failures

`index.ts` serves authenticated video generation, polling, quality checks and
the gated Bria reflection-removal test. Ordinary reel, aerial and Topaz jobs
use `cost-reservation.ts` before their single provider submission. Provider
adapters live in `../_shared/providers/`.

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

Quota refunds use the existing best-effort `refundRateLimit` path. The durable
release must complete first, but release and the two quota refunds are not one
database transaction. A failed quota refund needs reconciliation; do not promise
an atomic or guaranteed credit refund. These allowances are feature counters,
not a customer cash/credit wallet.

Unresolved holds survive month rollover. Confirmed releases are excluded from
spend; accepted settlement replaces a hold with one ledger row. There is no
automatic hold expiry or fallback after an uncertain submission. The shared
ordinary-video/reflection budget and existing authorization/deletion fences
remain in force. Applying this branch requires
`20261004215403_app_video_rejected_submission_release.sql` before the function
update.

## Polling and diagnostics

FAL `COMPLETED` can carry `error` or `error_type`; both the adapter and legacy
GET `/ai-video/status` report this as `status: "failed"` without fetching the
result. A failed completed-result response also becomes a terminal failure.
Successful responses retain `status`, `video_url` and the existing drift block.
An unchecked generated clip is not automatically approved for publishing.

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
  ai-video/dronecost.test.ts \
  admin/probe.test.ts
```

Provider requests are mocked; network permission allows dependency imports.
To verify SQL with installed PostgreSQL binaries, run from the repository root:

```sh
python3 services/supabase/tests/app_video_cost_pg.py
```

The runner uses a fresh owned Unix-socket-only cluster, clears inherited
credentials, and records source hashes, actual concurrent admission/settlement
results and a removed-lock negative control. No live database or paid provider
call is involved. The dated [evidence summary](../../../../docs/handoff/PROVIDER-DISPATCH-REJECTION-20261004.md)
records results and investigation limits.
