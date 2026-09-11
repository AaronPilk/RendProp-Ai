# Claude deployment report — independent readback, September 11

This checkpoint supersedes the earlier missing-Supabase/build18 inventory in
`SPATIAL-DELIVERY-STATUS-20260911.md`. Those earlier observations were correct at
their recorded time; another operator subsequently deployed/uploaded. This is a
read-only verification, not an instruction to swap the App Review submission.

## Confirmed live

At approximately18:42UTC, the RendProp Supabase project returned **22 ACTIVE
Edge Functions**, including`spatial` version1. All21 previously observed function
JWT flags were preserved. Spatial has platform verification disabled as required
by its capability/public-read design; app owner routes authenticate in the
handler. Metadata ACTIVE is not an end-to-end functional test.

Migration history now includes worker_publish_transaction(0035),
upload_publication_immutability(0036),0037,0038 and0040. This verifies their history
entries, not independently the exact chronological application order or every
statement byte. Versions0037/0038/0040 are literal short history keys;0035/0036
have timestamp keys. No0039 entry was returned.

Root retrieved the actual deployed source files for`spatial`v1(7 files),
`uploads`v32(10 files) and`me`v30(12 files). All29 comparisons were exact text
matches against checked-in source at8263e25 (application source2612c7c). These
findings therefore apply to those deployed functions, not just a proposed patch.
The remaining19 function bundles were not independently source-compared.

Runtime SELECT returned:

```text
enabled                    false
daily_budget_cents          0
org_monthly_budget_cents    0
job_cap_cents              600
max_seconds               7200
max_training_seconds      900
```

The600-cent value is a worst-case attempt reservation, not an observed provider
invoice or a direct provider billing stop. The SQL check fixes it to600 in
`0040_spatial_jobs.sql:8`; provider lifetime/termination and actual invoice
reconciliation remain separate obligations.
An independent read-only`pg_constraint` query also confirmed the installed
`spatial_runtime_job_cap_cents_check` is`job_cap_cents >= 600 AND job_cap_cents <= 600`.
Explicit retries can reserve another600, up to three attempts for the same
capture (`0040:388`), so a capture can reserve1,800 cents within the global/org
limits. “Six dollars a job” should not be read as six dollars for all retries.

Apple readback18:43:32UTC confirms **build19 VALID**, not expired, uploaded
2026-09-11T11:14:50-07:00 (14:14:50Eastern). At18:45:20UTC the correct Apple field
`buildAudienceType` returned`INTERNAL_ONLY`; its beta detail returned
`internalBuildState=IN_BETA_TESTING`, `externalBuildState=NOT_APPLICABLE`.
The beta-group relationship read returned403, so this check does not prove the
individual owner's group assignment.

Version1.0 remains **WAITING_FOR_REVIEW attached to build16**. No Apple mutation
was performed. Apple's documentation confirms internal-only builds cannot be
submitted for App Store review/distribution:
[Test your beta app](https://developer.apple.com/tutorials/develop-in-swift/test-your-beta-app).
That restriction does not require changing the pending build16 submission to
continue internal testing.

Local build19 archive/export evidence exists at`/tmp/rendprop-b19.28811`.
The corresponding worktree's HEAD8263e25 has no app/capture-source difference
from2612c7c; its two dirty files are generated project files. The export log
records upload success14:13:50.698Eastern. A source-bound build19 release receipt
was not found. Archive/source/time consistency is not a cryptographic proof
that the exact archive was the binary uploaded. Do not invent such a receipt.
The inspected archive executable SHA256 is
`3e9664a593dfca58a3d3e3be91ac19b7e28f1da83016f7b56d101b43ac867f55`.

## Correction: build18 is not categorically incompatible with new upload tickets

`transport_version` identifies the server ticket, not the iOS build. Build18
source`ed0131b` posts the same body (`LiveAPIClient.swift:327`) and decodes the
same ticket fields (`LiveAPIClient.swift:1647`); current`uploads/index.ts:282`
accepts it, and0037 inserts transport_version2 at`:155`. The response retains
asset_id/mode/put_url/upload_id/part_size/part_count/storage_key at
`uploads/index.ts:580`. The old uploader PUTs the returned URL
(`ed0131b:Upload/DirectUploader.swift:78`), compatible with the gateway's
query capability (`uploads/gateway_contract.ts:59`) and200/ETag response
(`services/edge/upload-gateway/handler.ts:223`). Multipart numbers/ETags also
retain the same contract. No new Authorization header is required for that PUT.

The actual rollout break is **unfinished legacy tickets**:

1. Obtain a ticket before0037/current-handler rollout, then resume it afterward.
2. `/part-urls` and unfinished `/complete` reject transport_version1 with409
   (`uploads/index.ts:350`,`:377`). Already-completed legacy tickets still replay
   successfully (`:378`).
3. Reusing the same stable idempotency key finds that old asset with no v2
   reservation and returns409 (`0037:139`).
4. A deliberate legacy abort and fresh ticket can migrate the upload
   (`uploads/index.ts:328`, `0037:413`), but the general old uploader does not
   automatically do that. This is a recovery change, not permission to discard
   original local media or bulk-abort customer uploads.

There is also an interrupted-v2 recovery mismatch: uncertain/incomplete physical
writes cannot simply be sent again (`uploads/transport.ts:123`,`:151`). The
general UploadManager/DirectUploader sources are unchanged betweened0131b and
2612c7c, so compiling them as build19 does not automatically repair that flow.
The new spatial uploader has separate recovery logic; do not generalize it to
all app uploads. No production upload was attempted in this read-only check.

## Material gaps omitted from “everything is deployed”

### 1. Upload gateway and viewer are separate Cloudflare deployments

The configured Cloudflare account containing the live`rendprop-tour-host`
returned four Workers and **no`rendprop-upload-gateway`**. Tour-host's newest
deployment is September8,19:31:04.533UTC,100% version
`c32b5949-c73a-4f77-95ad-d1e88ed5eb2d`. It was not updated by the reported
Supabase deployment. Source for the new viewer routes is at
`services/edge/tour-host/src/index.ts:409` and`:413`.

Uploads now require gateway configuration before reserving any new ticket:
`functions/uploads/index.ts:283`; `functions/uploads/transport.ts:45` requires
matching gateway origins and a capability secret. There is no reusable R2 URL
fallback. Checked-in`services/edge/upload-gateway/wrangler.jsonc:7` still contains
empty origins and intentionally unconfigured bucket placeholders.

No runtime secret values were read. A gateway deployed under another name,
account or host was not established. Thus the precise finding is a missing
gateway in the checked deployment inventory and **unverified actual upload
readiness**, not an executed assertion that every current upload failed. If the
required settings are absent, all new ticket creation returns503 regardless of
iOS build. If settings point to an absent gateway, transfer fails later.
Updating the phone does not repair either configuration/deployment problem.

### 2. Modal worker is absent; current billing denial is not established

At18:43:10–18:43:29UTC, pinned Modal1.5.3 listed one experiment app with zero tasks
and zero active sandboxes. Lookup of`rendprop-spatial-worker` with creation
disabled returned NotFound in the configured environment. The deployable app
name/scheduler are in`services/spatial-worker/app.py:11` and`:29`.

The previous spend-limit termination is historical. No new allocation was
attempted in this check. The owner's newer screenshot shows apparent headroom;
it is not evidence that Modal is currently denying allocations. Do not ask the
owner to raise limits again solely on that old error. The existingUSD25 total
one-room approval remains the limit; it is not recurring production authority.

### 3. Disabled generation is not disabled ingestion

`spatial_create` inserts jobs at`0040_spatial_jobs.sql:135` and
`spatial_attach_inputs` stores metadata at`:169` without reading enabled.
Only`spatial_start` checks the disabled/zero-budget configuration at`:200`.
Consequently, a capture can be uploaded and attached before generation returns
“not configured.” Do not describe that switch as keeping all captures local or
as a complete ingestion shutdown.

### 4. Spatial deletion/cleanup still needs implementation

The deployed`me` source collects capture assets/photos/renders at
`functions/me/index.ts:1305` and`:1315`, but omits current spatial output keys,
sidecars and historical attempts. Its deletion sequence at`:1422` likewise
omits the spatial tables. Those tables deliberately lack listing/org cascade
foreign keys (`0040_spatial_jobs.sql:18`) so external object identities survive.
Without the missing reconciliation, survival becomes retained data rather than
a completed cleanup. Disabled generation does not avoid the sidecar issue.
Concrete code-level reproduction: generate a room, then let account deletion
successfully process every enumerated non-spatial target. `me/index.ts:1469`
can report`cleanup_complete:true` because the payload has drained, while the
unlisted spatial model, manifest, sidecars and history remain. Its sweeper at
`:1538` only consumes the recorded payload; it cannot discover omitted targets.
This was reasoned from the exact deployed source, not exercised on user data.

Do not blindly apply the unfinished0039 file by itself. The separate deletion
worktree's0039 revokes direct deletion_requests writes, while the currently
deployed handler inserts its tombstone directly at`me/index.ts:1386`. The paired
handler/RPC integration is required, and the WIP0039 itself still needs spatial
enumeration. Never validate this by deleting a real production account.

The worker's provider receipt/identity is also inside a TemporaryDirectory
(`services/spatial-worker/worker.py:326`). Durable provider cleanup records,
real selective-redaction derivatives, actual file transfer and real-room phone
acceptance remain unfinished. A deployed handler or successful mock walk does
not close these items.

## Recommended next action — not an Apple review swap

1. Verify/configure/deploy the separate upload gateway and viewer, then test the
   actual non-destructive upload path with a designated fixture, including old
   client behavior. Do not assume build19 alone fixes uploads.
2. Complete paired deletion/provider cleanup integration; the disabled runtime
   is not a substitute for it.
3. Deploy the bounded automatic controller and prove one private real room under
   the existing experiment cap, then review quality/navigation on the owner's
   phone. Configure an explicitly authorized production budget separately.
4. Continue internal testing with build19 or a later verified internal build.
   Keep the submitted build16 unchanged unless the owner explicitly changes that
   instruction. There is no need to manufacture build20 just to test on a phone.
5. For an eventual App Store build, either deliver a complete spatial feature or
   exclude it from that release for **all** App Store users. Do not hide a
   functioning feature selectively from reviewers. An unfinished feature creates
   a rejection risk, not a guarantee about Apple's decision. See Apple's
   [completeness and accurate-metadata rules](https://developer.apple.com/app-store/review/guidelines/).

All cloud operations in this fact-check were reads. No budget enablement,
provider allocation, deployment, deletion, upload or Apple-review change occurred.
