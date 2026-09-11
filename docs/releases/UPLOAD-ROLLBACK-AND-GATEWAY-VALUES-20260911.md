# Upload rollback and gateway handoff — September 11,20:17–20:23UTC

Read-only verification of the owner's latest Claude report. This supersedes the
earlier uploads-v32 deployment facts; no infrastructure or Apple changes were
made by this check. No production upload, account deletion or GPU run occurred.

## Values Claude does not need the owner to find manually

Cloudflare's live R2 inventory in account`9c332c75b96cc642621dad5d86d4bf18`
(the account hosting Rendprop) confirms these existing buckets:

| Worker binding | Existing bucket | Observed access |
| --- | --- | --- |
| UPLOADS | `rendprop-uploads` | r2.dev disabled; no R2 custom domains |
| RENDERS | `rendprop-renders` | existing r2.dev public endpoint enabled; no R2 custom domains |

`rendprop-public` also exists but is **not** the RENDERS binding. Deployed
uploads-v33 `_shared/r2.ts:30–32` uses these matching defaults, and repository
`services/supabase/DEPLOYMENT.md:149` records the intended mappings. Runtime
environment overrides were not read; deployment should verify that the existing
R2_BUCKET_UPLOADS/R2_BUCKET_RENDERS settings agree before binding the gateway.
No bucket should be created, renamed or made public merely to configure it.

Recommended new gateway origin: **`https://uploads.rendprop.com`**.
This is a recommendation, not an already-deployed endpoint or a claimed owner
hostname selection. Read-only checks returned:

- `rendprop.com` is an active zone, ID`e49d349dfbdd91dfa8d3119f79ff687a`.
- No exact`uploads.rendprop.com` DNS record.
- No wildcard`*.rendprop.com` DNS record.
- No Worker custom-domain binding for`uploads.rendprop.com`.
- Existing Worker routes cover only`rendprop.com/*` and`www.rendprop.com/*`.

No observed conflict with the proposed hostname. Bind it to the **upload Worker**,
not directly to the uploads R2 bucket. Private photos/spatial results must remain
private. Spatial storage already uses the private uploads bucket at
`functions/spatial/storage.ts:13–15`.

Configuration mapping for the chosen origin (preserve the rest of the config):

```text
Worker UPLOADS bucket                 rendprop-uploads
Worker RENDERS bucket                 rendprop-renders
UPLOAD_GATEWAY_ORIGIN                 https://uploads.rendprop.com
UPLOAD_GATEWAY_ALLOWED_ORIGIN         https://uploads.rendprop.com
Worker SUPABASE_ORIGIN                https://ymgqpbnjpztwjsyvceld.supabase.co
Worker SUPABASE_ALLOWED_ORIGIN        https://ymgqpbnjpztwjsyvceld.supabase.co
```

The two gateway-origin values must match on the Supabase ticket issuer and
Cloudflare Worker. `UPLOAD_CAPABILITY_SECRET` must be provisioned identically
on those two sides; the gateway also needs its service-role credential, as
declared by`services/edge/upload-gateway/wrangler.jsonc:14`. No secret values
belong in this handoff. The origin values are URLs, not cryptographic secrets.

## Uploads v33 rollback independently confirmed

Supabase reports`uploads` ACTIVE v33, platform JWT verification true, bundle
SHA256`b273b5a6d52f15691921becd47dab13526e564c2985154ec298f0514dc99b6de`.
All eight fetched deployed source files exactly match commit
`8ce5e4abdb3fcfcd7feff58f9a837c4db2b163db`.

It no longer depends on transportConfiguration/the missing gateway. That removes
the specific ticket-creation failure. **It does not independently prove that a
real phone upload now succeeds.** No ticket→PUT→complete→publication test was
performed in this read-only check; “go shoot a listing; it'll upload” remains
stronger than the independently observed evidence.

The rollback retains more than just completion_parts. At the deployed commit:

- HEAD size/type and ETag-conditional copy: `uploads/index.ts:575–624,643–652`.
- Signed canonical Content-Type REPLACE: `_shared/r2.ts:303–334`.
- Unique candidate key plus terminal/old-key compare-and-set:
  `uploads/publication.ts:7–12`, `uploads/index.ts:154–156,643,664–685`.
- Ambiguous DB responses retain candidates; a losing completion deletes only
  its candidate: `uploads/index.ts:672–689`.
- Exact multipart coverage and frozen completion manifest:
  `uploads/publication.ts:16–29`, `uploads/index.ts:519–570`.

These are source findings, not fresh live race tests. The installed0036 trigger
is part of the correctness contract, not just its completion_parts column.

## Temporary rollback limitations Claude must preserve in the handoff

### Spatial ingestion is incompatible with v33 tickets

v33 inserts capture_assets without transport_version/reservations at
`uploads/index.ts:426–436,844–861,890–904`. Migration0037's omitted-column default
is1 (`0037_upload_transport_budget.sql:5`). Spatial attachment requires BOTH
version2 and a completed upload reservation (`0040_spatial_jobs.sql:158–163`).

Concrete flow: request a spatial JPEG ticket → ordinary direct upload/completion
may succeed → POST /spatial/:id/inputs returns409, “image needs a completed private
upload ticket.” It cannot queue. Enabling runtime budgets does not fix this.
Do not simply relabel legacy assets as version2 without the actual transport
and completed reservation receipt.

### Outstanding v2 tickets also need deliberate recovery

v33 does not settle v2 reservations. An already-issued v2 multipart ticket may
become uploaded while its reservation remains open. The v2 single-upload staging
key (`0037:190–194`) also differs from v33's expected staging key
(`uploads/index.ts:149,517`). Do not claim mixed in-flight uploads resume
seamlessly in either deployment direction. Preserve original local media and
reconcile exact ticket IDs; do not bulk-abort customer uploads as a shortcut.

### Physical transfer budget protection is temporarily absent again

v33 charges declared bytes once (`uploads/index.ts:241–259`) but returns reusable
direct R2 PUT URLs (`_shared/r2.ts:80–90,163–172`). An oversized or repeated
staging PUT can consume writes/storage before complete rejects it. Publication
compare-and-set remains intact; the gateway's one-dispatch/exact-length physical
transfer protection does not. Record this as an availability rollback with an
open cost-control regression, not a fully closed release finding.

## Correct rollout order from this state

1. Confirm existing runtime bucket mappings and select the unused gateway host.
2. Configure real R2 bindings, gateway origins and matching signing material;
   deploy and verify gateway routing/TLS/service access **before** switching the
   live Supabase ticket issuer back to v2. Existing renders' public settings
   must not be changed as a side effect.
3. Use a controlled, explicitly scoped synthetic upload to prove ticket, actual
   transfer, receipt, complete and publication. Include replay/interruption and
   old-client/legacy-ticket recovery; never delete a real account as a test.
   New ticket issuance alone is not end-to-end success.
4. Deploy/verify the separate tour-host 3D routes; confirm the actual private
   viewer shell and model path, not only an ACTIVE deployment status.
5. Finish spatial cleanup integration and durable provider records, deploy the
   bounded automatic worker, then prove the owner's saved room within the
   existingUSD25 experiment authority. Do not infer a current Modal billing
   block solely from the old terminated sandbox.
6. Keep generation unadvertised as working until real-room completion/navigation
   is proved. Keep the pending App Review build16 unchanged; internal phone
   testing does not require a replacement review submission.

No infrastructure changes or paid allocations were made by this verification.
It provides the missing configuration facts and identifies the rollback's actual
scope; it is not itself a deployment receipt or a functional-upload pass.
