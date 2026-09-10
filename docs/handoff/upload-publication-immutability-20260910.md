# Upload publication immutability — local repair, not deployed

Base reviewed: `7d0b0ca3ab7fb579348480e40c43f89d5c222e31`.
Scope: uploads route, pure publication vocabulary, migration 0036, synthetic
regressions. No iOS, provider routing, worker pipeline, live database, or R2
changes were performed. Supabase and Cloudflare/R2 skill guidance informed the
new migration and the separation between storage operations and database state.

## The defect and the narrower guarantee

The original actual-handler test reproduced two same-size, valid snapshots:
copy A reached the shared destination and its database update won; delayed copy
B then overwrote that same destination. Both source ETag conditions held. The
unmodified route failed the desired byte-immutability assertion (exit 1,
0 passed / 1 failed). A second SELECT or source ETag alone cannot fence the
destination write.

The repaired single-PUT path uses a server-generated UUID **per completion
attempt** in the destination key. After copying the HEAD-selected source
snapshot, it publishes that key with a conditional database UPDATE. A loser
returns the database winner, not its local key. No later completion copies to
the winner's destination. This guarantees completed-publication identity under
the stated deployment/storage assumptions; it is not a claim of zero temporary
objects, zero cleanup failures, or prevention of storage/spend abuse.

Cloudflare's [R2 S3 compatibility table](https://developers.cloudflare.com/r2/api/s3/api/)
lists CopyObject source conditions, and does not supply the assumed
destination-publication transaction. [R2 consistency](https://developers.cloudflare.com/r2/reference/consistency/)
also documents last-writer-wins behavior for same-key concurrent writes.
Consulted 2026-09-10. This repair does not treat S3-only UploadPartCopy features
as R2 guarantees.

## State machine and cleanup ownership

All terminal transitions use the same row predicate: asset ID, original ticket
key, `uploaded=false`, `upload_aborted=false`.

| Operation | Winning transition | Losing/uncertain transition |
| --- | --- | --- |
| Single complete | Copy to fresh key; CAS sets completed key; only then delete shared staging | Return completed DB winner; delete only this attempt's distinct candidate. A DB error preserves the possible winner and returns 503. |
| Multipart complete | CAS freezes canonical number/ETag list before assembly; same manifest only; verify in place, then CAS complete | Different manifest gets 409. Identical concurrent assembly has the same selected parts. If abort won, a returning completer deletes its late assembled object. |
| Abort | Persist terminal abort before R2 cleanup; keep upload ID for cleanup retry | Completed winner gets 409, with no object cleanup/reset. Already-aborted ticket can retry cleanup. |
| Size/type mismatch | Persist terminal abort before deleting rejected source | If another completion won, return that winner without deleting/resetting it. |

`uploads/index.ts:150` centralizes conditional updates; completion starts near
line 486. `uploads/publication.ts` requires all parts exactly once (1..recorded
count, maximum 10,000), sorts and normalizes the same ETag quoting used by R2.
Nothing filters malformed parts into validity. `part-urls` and ticket replay
refuse terminal aborted rows. Existing authorization, declared MIME/size,
per-file/per-MiB charging, refunds and role limits remain in force.

A multipart object already present **without** a frozen manifest is a legacy
ambiguity. It must not adopt a new caller's claims merely because HEAD has the
expected size. Complete returns 409 without freezing that claim; explicit abort
can cancel it, followed by a new ticket. A concurrent new handler that already
froze the manifest can still be recognized by reloading the row. Recovery of a
bound assembly requires the original frozen manifest, including when R2 reports
NoSuchUpload. No 12 GiB single-object copy or server-side byte buffering is added.

Migration 0036 freezes completed `id`, `listing_id`, `uploaded`, `storage_key`,
`bucket`, `kind`, `bytes`, `content_type`, `upload_id`, `upload_aborted` and
`completion_parts`. It forbids reopening aborted rows or replacing an already
frozen manifest. It does **not** freeze probe fields (duration, dimensions, fps,
codec, gyro/drone flags, SHA metadata), chapter rows, or prohibit the separate
authorized DELETE/cascade path. SHA remains supplied metadata, not newly
verified content evidence. Tenant writes were already revoked by migration 0007.

## Consumer compatibility

Ticket `storage_key` is now explicitly provisional for singles. Use `asset_id`
through upload/publish, or the completed row's returned key for final storage.
An already-completed replay returns the winner even if an old PUT URL has been
used again; it does not adopt or need to inspect the new staging bytes.

Reviewed source consumers at the base commit:

- `apps/ios/Rendprop/Networking/LiveAPIClient.swift:359–379`: completion returns
  Void and ignores the response row. UploadManager records the ticket key as
  bookkeeping but completes and marks done by asset ID; no final URL is derived
  from that cached key. No client source change is required for these callers.
- `0011_app_publish_and_lifecycle.sql:395–403,420–452` derives public poster/video
  keys from the current completed capture-assets row. `0012_provenance_and_unbranded.sql:141–160`
  similarly derives the verified original key, not a client arbitrary key.
- `functions/tours/index.ts:124–139` selects `gallery-` basenames. The new suffix
  preserves both `gallery-` and `original-` prefixes, directory and extension.
  Original images retain the 50 MB lane; gallery/poster remain 10 MB.
- `services/worker/db.py:543` fetches current storage key;
  `services/worker/worker.py:387–397` downloads it and preserves its extension.
- `functions/me/index.ts:1317–1323` inventories the current winning key for
  deletion. It does **not** discover new unreferenced crash-orphan candidates.

No assertion is made about untracked/third-party clients that constructed URLs
directly from ticket keys. The older upload-contract document's same-ticket-key
and re-staged-replay-409 description is superseded by this repair for singles.

## Exact local verification

Installed Deno 2.7.13, existing cache only. From the worktree root:

```sh
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin \
  DENO_DIR=/Users/pilksclaes/Library/Caches/deno NO_COLOR=1 \
  deno test --cached-only --deny-net --deny-run --deny-write \
  --allow-env --allow-read services/supabase/functions/uploads/
```

Result: **46 passed, 0 failed, 0 skipped, exit 0**, including typechecking.
16 existing MIME tests + 6 pure manifest/key tests + original race + 23 actual
route scenarios. The route tests intercept Deno.serve and every fetch, use fake
credentials only, and bound each scenario to five seconds. No socket, database,
provider, upload, or customer byte is used. The 12 GiB case holds metadata only,
uses the real 32 MiB part planner / 384-part manifest, and proves no CopyObject
branch is taken—not 12 GiB transport/performance.

The two legacy-unbound regressions were run before their route fix: **0 passed,
2 failed, exit 1** (15 other tests filtered out in that narrow red control).
The final gate has no filters or skips. `git diff --check` passes.
Standalone `env -i PATH=/opt/homebrew/bin:/usr/bin:/bin
DENO_DIR=/Users/pilksclaes/Library/Caches/deno NO_COLOR=1 deno check --deny-import
services/supabase/functions/uploads/index.ts` also passes (exit 0). A separate
attempt forcing `--node-modules-dir=manual` failed because this sparse worktree
has no local node_modules; no installation was performed to bypass that failure.
Evidence: `/tmp/rendprop-upload-immutability.UBbVFS/legacy-before.log` and
`ci-positive-final.log`. An intermediate fixture-import ordering error failed
23 route tests; the final fixture imports environment-capturing modules only
after installing its fake environment, and the full final gate above passed.

`completion_race.test.ts` and `publication_route.test.ts` register both actual
route suites in the existing edge-function test directory. Consequently the
existing GitHub edge test step and `run_edge_regression.py` discover them as
required positive tests; they are no longer an optional expected failure.

`services/supabase/tests/negative_upload_publication.sql` is a **19-check,
synthetic, rolled-back** SQL fixture, guarded to the root-owned disposable
Unix-socket audit cluster. It tests frozen publication fields, allowed probe
and chapter writes, DELETE/cascade, terminal abort, and manifest immutability.
It is authored but **not run by this agent**. Root must run migration application,
replay, invariants and this fixture against actual disposable PostgreSQL before
calling the database behavior verified. No iOS/UI or live R2 proof is claimed.

## Required cutover and residuals

Before any separately authorized deployment: pause new upload mutations and
drain all old uploads handlers (including in-flight completes/aborts); apply
0036 and verify schema; deploy the new route; resolve unbound legacy multipart
assemblies via explicit cancellation/re-ticket; only then resume mutations.
Migration-first is mandatory for the new fields, but migration alone cannot
fence an old handler's storage copy/delete. Do not roll back to old route code
against active tickets and claim this guarantee. Old completed objects are not
renamed by the migration; the old-handler drain is part of their protection.

Crash/timeout between R2 and DB can leave unreferenced candidates; uncertain DB
acknowledgements deliberately retain them. There is no durable attempt inventory
or automatic orphan collector in this patch. Cleanup failures are best effort:
in particular `/abort` can return ok after a failed staging DELETE. Staging
lifecycle configuration is an outstanding operational gate, not a guarantee of
immediate removal. A delayed old presigned PUT may recreate staging after abort.

Host-only signed PUT/part URLs do not physically enforce declared bytes at R2:
oversized staged/part data and replay requests can consume storage, requests or
bandwidth until expiry. Declared byte budgets are unchanged and are not a
physical acceptance cap; later deletion/lifecycle cannot undo incurred cost.
ETag selection is the storage API's identity check, not independent cryptographic
file verification. This unit closes publication races under these assumptions;
it does not claim complete upload cost containment or a cross-service transaction.

## Follow-up: bind verified Content-Type, not only the body's ETag

Independent review found a remaining single-PUT metadata race in `a00f673`:
after HEAD returned `image/jpeg`, identical bytes could be re-PUT with the same
ETag but `text/html`. Default CopyObject metadata behavior inherited the newer
type while the database still recorded the verified old type. Unique keys
protected the destination from later copies, but did not correct that first copy.

The uploads caller now passes its already-allowlisted, canonical observed base
type to an optional `copyObject` argument. That branch supplies
`x-amz-metadata-directive: REPLACE` and explicit `Content-Type`. A strict header
shape guard rejects noncanonical values before dispatch. Unspecified source
metadata is intentionally not inherited; the caller does not promise to preserve
client cache-control, encoding, disposition or custom metadata. No additional
HEAD is substituted for binding the copy operation itself. Multipart is unchanged.

[Cloudflare's R2 compatibility reference](https://developers.cloudflare.com/r2/api/s3/api/)
explicitly lists CopyObject support for the metadata directive and Content-Type.
[The linked S3 operation reference](https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html)
defines `COPY` as default and `REPLACE` as request-supplied metadata. These were
checked on 2026-09-10; this is documentation support, not a live R2 test.

The pinned [aws4fetch 1.0.20 signer source](https://github.com/mhart/aws4fetch/blob/v1.0.20/src/main.js)
excludes Content-Type from signed headers by default. The replacement branch
therefore opts into `aws: { allHeaders: true }`. The regression inspects the
actual signer's resulting SignedHeaders and requires Content-Type, the metadata
directive and the source ETag condition, without printing signing material.
`git grep` found only the uploads route calling this helper in tracked code.
Omitting the optional argument retains its prior COPY behavior; a compatibility
test explicitly covers omission. No other provider, route or schema was changed.

Evidence retained in `/tmp/rendprop-upload-metadata.qMCcU9/`:

- `before.log`: actual-route metadata-swap regression against the old helper,
  **0 passed / 1 failed, exit 1**, with stored `text/html` versus expected
  `image/jpeg` (23 unrelated scenarios filtered out for this red control).
- `unsigned-negative.log`: metadata replacement without the signer opt-in also
  **fails, exit 1**, specifically because Content-Type is absent from SignedHeaders.
- `after.log`: the unfiltered uploads-directory command above now passes
  **51 tests, 0 failed, 0 skipped, exit 0**: all prior 46 plus the metadata race,
  optional-COPY compatibility, eight malformed replacement inputs, observed
  parameter normalization and server-default-type compatibility.

The same actual-route CI wrapper discovers the added regressions automatically.
The unchanged remaining limits above still apply: metadata normalization is not
media sniffing/decoding, a verified content hash, a cleanup guarantee, or a
physical upload-cost cap. No live R2 request was made.
