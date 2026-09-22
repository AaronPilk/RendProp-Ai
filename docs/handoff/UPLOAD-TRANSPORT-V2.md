# Upload transport v2 — local implementation, rollout still gated

Scope: upload transport and its durable reservation/candidate journal only.
This does **not** close worker/Stream artifact recovery, execute a deployment,
configure a production gateway, move customer media, or prove a remote R2 upload.
The source starts from `2750953`; migration **0037** is reserved for this unit.
Adoption (0038) and deletion snapshot work (0039) remain separate units.

## What changes

`services/supabase/functions/uploads/index.ts` retains the existing ticket,
batch, part-URL, completion and cancellation payload vocabulary. `put_url` and
part `url` are now opaque, expiring gateway capabilities, **not** R2 presigned
PUTs. No configured/allowlisted gateway means HTTP 503 before reservation.
There is no memory-counter or host-only-presigned-URL fallback.

The new Worker in `services/edge/upload-gateway/` checks HMAC capability scope,
claims the exact server-journaled operation, and streams to a fixed R2 binding.
The client cannot supply an object key, bucket, upload ID, or reserved length.
It validates Content-Length when present, counts actual streamed bytes, rejects
encoded bodies and withholds the final byte until true EOF. A Cloudflare
`FixedLengthStream` adds an independent sink-length check. Thus an oversized
body cannot authorize its first N bytes as an accepted N-byte object. The
offline tests include a deliberately aggressive sink that commits immediately
upon receiving N bytes; even it cannot commit an invalid prefix.

One durable claim authorizes **one application-level storage dispatch**. A
concurrent call gets a retryable error; a completed transfer returns its stored
ETag without forwarding replacement bytes. SQL/service uncertainty is closed,
not a reason to create another dispatch. The S3 create/assemble/copy helpers use
`sign` + native `fetch`, avoiding aws4fetch's automatic fetch retry loop.

Existing iOS consumers inspected: `Networking/LiveAPIClient.swift` ticket and
part-URL decoding; `Upload/DirectUploader.swift` PUT request builders; and
`Upload/UploadManager.swift` completion/retry handling. They treat these URLs as
opaque and consume the ETag header. Declared MIME is enforced; the pre-existing
allowlisted server-guess MIME case remains supported. Original/gallery prefixes,
public/private bucket tags and the DB-selected winning key are preserved.
These are source/fixture compatibility findings, **not** a new device UI run.

## Reservation and publication state

0037 adds service-role-only, RLS-enabled tables:

| Table | Durable responsibility |
|---|---|
| `upload_budget_windows` | UTC reservation-day ticket, held-byte and dispatched-byte totals |
| `upload_reservations` | Original actor/workspace, immutable request identity, 48-hour expiry and one terminal settlement |
| `upload_operations` | Pre-dispatch exact key/session identity, claim, receipt/uncertainty and cleanup lease |

Transactions lock listing → capture asset → reservation → budget and contain
no storage/network calls. A single photo/video reserves 2N bytes (ingress and
promotion copy); multipart reserves N (parts, then assembly in place). Claiming
an operation moves its byte authority from held to spent. Completion/cancellation
releases **only** remaining held bytes once; dispatched, rejected and uncertain
authority is never refunded, even after deletion. Concurrent retries use the
same terminal reservation, not independent refund-counter decrements. Batch
asset creation and reservation commit atomically.

Limits remain 64 MiB for a single request, 32 MiB multipart parts, 12 GiB total
video (384 parts), role-specific photo limits, 200 photos/batch and 256 requested
part URLs/call. New reservations use a conservative 200 GiB/day **authorized
object-byte** ceiling including single promotion copies, and 2,000 tickets/day.
This is stricter than the old declared-ingress-byte counter. It is not a bill,
measured disk usage, converged storage cost, or a guarantee against provider
internal retries. Each body has a 10-minute application deadline; multipart
continues across bounded requests, never a 12 GiB Worker body.

An uncertain receipt can be recovered only by read-only observation of its
registered identity: exact object HEAD; bounded ListParts with exact part
number/size; or exact-key multipart initialization inventory. Missing, mismatched
or ambiguous observations remain uncertain. No blind re-create/re-upload is
issued. Failed/invalid body operations require cancellation/re-ticketing when
their bytes cannot be proven. These conservative retries can charge an allowance
without a persisted object; that is intentional fail-closed authority, not a
claim that the provider charged those bytes.

Completion uses only confirmed receipts and the previously frozen multipart
manifest. Single promotion writes the operation's unique immutable destination;
the same DB transaction publishes it and settles its reservation. The existing
0036 completed-row guard remains intact. Probe/chapter metadata and legitimate
asset deletion are not disabled.

## Cleanup and deletion boundary

Service-only `POST /uploads/sweep` processes at most 16 expirations and 16 cleanup
entries per call, with four cleanup workers. Expiry and missing-asset cancellation
release only held authority. Cleanup takes a DB lease on an unpublishable key,
records storage success/failure, retries failures, and never labels an unconfirmed
delete successful. Multipart cleanup operates on its initialization/session
entry rather than deleting the same assembled key once per part. A lost
initialization with no discoverable session stays explicitly unresolved.

The three journal/budget tables intentionally do **not** cascade when auth,
organization, listing or capture-asset rows are removed. Deletion/adoption work
must preserve them. The ordinary deletion payload still owns the completed
winner key; this journal owns transport/candidate leftovers. Original-actor
authority is rechecked before new dispatch/publication; this unit does not
transfer an anonymous reservation to a newly authenticated actor.

Retired v1 tickets may be cancelled and their known stage/session inventoried,
but receive no new presigned URL. Their old physical spend is explicitly unknown,
not refunded. Previously unregistered historical completion candidates are not
magically discovered by this migration. A separate approved legacy inventory is
required. Terminal cleanup waits beyond the application write deadline before
deletion; arbitrarily delayed provider-side effects are not proven impossible by
an HTTP timeout. Uncertainty and cleanup backlog must remain operationally visible.

## Required rollout order — not executed

1. Inventory pending legacy tickets/candidates. Stop old ticket issuance and
   drain old handlers and already-issued bearer URLs/requests. Merely waiting
   one URL TTL does not prove a request accepted just before expiry has stopped.
2. Apply 0037; review ACLs/advisors in the approved environment. This local work
   used disposable PostgreSQL, not Supabase production or its advisors.
3. Provision the gateway with explicitly reviewed routes, fixed R2 bucket
   bindings, separate signing/service secrets and exact allowlisted gateway and
   Supabase origins. Committed origins are empty, bucket names unconfigured,
   workers.dev/preview routes disabled. Do not deploy the example configuration.
   `observability: false` is an inert rollout setting, not a recommendation to
   operate blind. Configure redacted aggregate metrics before activation; never
   log signed capability URLs, Authorization headers or uploaded body content.
4. Verify synthetic exact/short/oversized/replay/interrupted uploads against an
   approved fixture bucket, then install the uploads handler configuration.
   Check the actual Cloudflare plan's request-body limit; parts, not whole
   multi-GiB videos, cross the Worker.
5. Configure and verify a service-only sweep schedule plus alerts for unresolved
   initialization, expired reservations and cleanup failures/backlog. No schedule
   or production invocation was created here. Set an approved journal retention
   policy; deleting unknown entries would destroy the only cleanup identity.
6. Run actual iOS/browser interruption/resumption tests with synthetic large
   files. Do not roll back to v1 presigning after v2 starts; fail closed instead.

An unkeyed batch retry is still a new logical reservation; the existing photo
batch client sends no idempotency identity. Its abandoned holds expire durably,
but automatic client reconciliation of an entirely lost batch response is not
claimed. Network ingress, Worker/DB CPU, rejected requests, R2 request charges,
provider-internal behavior and sustained request flooding remain separate cost
risks. This unit does not promise zero-bill DDoS protection or enforce media
ownership, file magic, perceptual quality, or publication suitability.

## Reproducible local gates

Use existing installed dependencies only; do not install or contact live services
as a fallback. The sibling tour-host package already pins Wrangler 4.129.0; types
were generated from the gateway configuration. Local TypeScript was 5.9.3,
Deno 2.7.13 and PostgreSQL 17 (owned Unix-socket-only cluster).

```sh
python3 tools/audit/verify_upload_transport.py \
  --deno-dir "$DENO_DIR" \
  --inject-fault no-final-byte-guard
# Required negative exit: 1, due to the invalid-prefix assertion.

python3 tools/audit/verify_upload_transport.py \
  --deno-dir "$DENO_DIR" \
  --tsc services/edge/tour-host/node_modules/.bin/tsc
# Requires all 100 transport/publication tests, no skips, and native typecheck.

python3 tools/audit/test_upload_transport_db.py
# Creates its own local cluster; never accepts an existing database URL.

node tools/audit/verify_upload_gateway_runtime.mjs \
  --modules services/edge/tour-host/node_modules
# Six scenarios through the actual adapter, native FixedLengthStream and local
# R2.put/uploadPart; outbound SQL is intercepted, never sent to a live service.
# Add --inject-fault redirect-error for a required native-runtime exit 1.

deno test --cached-only --deny-net --deny-run --deny-write \
  --allow-read --allow-env services/supabase/functions
```

The before-change actual-route control returned 200 plus a reusable R2 URL with
no gateway configuration, failing the expected 503 assertion (exit 1). Current
offline gates and exact counts are recorded in their unique `/tmp` receipts;
the final handoff supplies those paths. This unit's final local run had 647 edge
tests, including the 100 focused upload/transport tests, plus six native runtime
scenarios and 20 PostgreSQL cases (zero skipped). These are overlapping suites,
not additive independent coverage counts. The SQL runner additionally installs
two defective functions only in its owned cluster, requires their intended
assertion failures, restores the source and reruns the same cases. It stops its
cluster and writes the final receipt even on a failed assertion.

The native workerd test caught `redirect: "error"` being unsupported even though
TypeScript and Deno accepted it. The gateway now uses manual redirect handling
and rejects every non-2xx response without forwarding service credentials. It
also preserves the local short/oversized-body error before a storage boundary
can serialize its abort as a generic error. The final native gate bundles the
unmodified actual adapter. It does not emulate a production Cloudflare plan or
claim network throughput, remote storage billing, or actual Supabase JWT checks.
The native harness bounds startup, individual cases and disposal and retains
its receipt even when a test fails.

Primary references checked 2026-09-10: Cloudflare documents bearer/reusable
[presigned URLs](https://developers.cloudflare.com/r2/api/s3/presigned-urls/),
the native [R2 Workers API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/),
[FixedLengthStream](https://developers.cloudflare.com/workers/runtime-apis/streams/transformstream/),
[S3 recovery API support](https://developers.cloudflare.com/r2/api/s3/api/) and
[Workers limits](https://developers.cloudflare.com/workers/platform/limits/).
These document interfaces and constraints; they do not replace an approved
deployed fixture test.
