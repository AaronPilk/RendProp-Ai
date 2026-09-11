# Spatial service v1 — source contract and operational gates

This service is implemented source, not a claim that a real room was
reconstructed or that production has been deployed. It uses existing Supabase,
private R2, the bounded upload-v2 gateway and the web tour viewer. Anonymous app
sessions work; there is no plan or Apple-account gate added here.

## App contract

- `POST /spatial`, `Idempotency-Key: UUID`, body
  `{listing_id, capture_id,
  room_label, manifest}`. The manifest is the
  complete native capture manifest.
- JPEGs use existing private `POST /uploads` photo tickets and `/complete`.
  `POST /spatial/:id/inputs` accepts
  `{files:[{ticket_id, relative_path, frame}]}`: at most 16 completed v2 image
  tickets per request. JSON frame sidecars live in the private DB; the app does
  not fake them as JPEGs or presign arbitrary types.
- `POST /spatial/:id/start {}` freezes exact coverage and consumes one
  worst-case reservation atomically. Repeating it does not queue another GPU
  attempt.
- `GET /spatial?listing_id=UUID` returns `{jobs:[...]}`; `GET /spatial/:id`
  returns one job. States: uploading, queued, processing, review, ready, failed.
  Owner status reads also expire overdue processing leases.
- `POST /spatial/:id/retry {}`, with a new stable UUID Idempotency-Key for the
  observed failed attempt, reuses the SAME job/capture/inputs. Maximum three
  attempts. It reserves a new attempt atomically, waits for previous provider
  termination or its deadline, and preserves historical output/lease metadata.
  An HTTP replay of a prior retry key never queues another paid attempt.
- `POST /spatial/:id/cancel {}` pauses only uploading/queued work; it deletes
  nothing and does not claim to terminate a running provider. `/resume {}`
  returns that undispatched capture to uploading; `/start` reuses an existing
  undispatched reservation without charging it twice.
- Every app mutation returns a job: `id`, `listing_id`, `room_label`, `status`,
  `progress` (0..1), nullable `failure_code`, nullable `artifact_revision`,
  `privacy_state`, nullable `viewer_url`, nullable `share_url`, timestamps,
  `attempt_number`, `can_retry`, `can_cancel`, `can_resume`, nullable `retry_after`.
- `POST /spatial/:id/review` accepts
  `{artifact_revision, approved,
  exclude_room, redactions:[{min:[x,y,z],max:[x,y,z]}]}`.
  Any review immediately revokes sharing. Region requests are retained but **not
  falsely reported as processed**: nonempty redactions cannot publish until
  actual artifact processing is implemented. A whole-room exclusion revokes
  access immediately.
- `POST /spatial/:id/publish {artifact_revision}` requires explicit approval of
  the current artifact and no pending redaction or exclusion. An empty-redaction
  review means the owner explicitly judged that room needs no redaction; it is
  not an automatic privacy scan or an automatic approval.

Limits: 20..400 frames; 32 MiB/image; 2 GiB total images; 64 KiB manifest; 1
MiB/sidecar; 16 MiB total sidecar metadata. Oversize requests are refused, never
silently truncated. Existing files remain on the phone.

## Worker contract

These controller calls require service-role authorization. The GPU sandbox must
never receive service-role or R2 credentials.

1. `POST /spatial/worker/claim {worker_id}` returns `{job:null}` or
   `{job:{id,listing_id,room_label,lease_token,lease_expires_at,deadline_at,
   max_seconds,max_training_seconds,max_iterations,max_gaussians,max_cost_cents,
   inputs:[{relative_path,ticket_id,storage_key,bytes,frame,download_url}],manifest}}`.
   Download URLs last 15 minutes. Input transfer occurs before that expiry.
2. Every <120 seconds,
   `POST /spatial/worker/:id/heartbeat
   {lease_token,progress,cost_cents}`
   renews only the current lease. Cost is a monotonic conservative estimate,
   **not an invoice assertion**. Progress <=0.95.
3. `POST /spatial/worker/:id/output-ticket {lease_token,bytes,sha256}` returns
   `{upload_url,upload_token,artifact_revision,method:'PUT',content_type:
   'application/octet-stream',bytes,expires_at}`.
   Limit is 32 MiB encoded SOG.
4. PUT those bytes to `upload_url` with `Authorization: Bearer upload_token` and
   the declared content type. The server bounds and hashes the actual body,
   journals one physical write, header-signs one conditional R2 PUT to an
   immutable revision key, and acknowledges only stored output. No final-key PUT
   URL exists. A lost write response gets HEAD/metadata recovery, not another
   physical write.
5. `POST /spatial/worker/:id/complete {lease_token,cost_cents,manifest}`. The
   scene manifest must contain schema_version=1, scene_id, artifact_revision,
   format=sog, bytes, sha256, gaussian_count, bounds `{min,max}`, floor_y,
   eye_height, floor_source (`capture_estimate` or `roomplan`),
   navigation_bounds_source=`capture_estimate`, initial_camera
   `{position,target}`, rooms `[{id,label,position,target}]`,
   provenance=`captured`. Server validates finite geometry and the sealed
   artifact binding, ignores privacy approval from the worker, and transitions
   to private review.
6. Failure:
   `POST /spatial/worker/:id/fail
   {lease_token,failure_code,cost_cents,provider_stopped}`. Worker
   failure codes are bounded lowercase/underscore identifiers. Expired workers
   cannot publish and are never automatically requeued into another paid
   attempt. `provider_stopped:true` requires actual terminal provider proof or
   proof allocation was never attempted; failure alone is insufficient.
   `/worker/claim` first runs a separate expiry transaction. An independent
   authenticated `POST /spatial/worker/sweep {}` can expire leases even when
   the operational runtime is disabled; it does not start compute.

Runtime default is **disabled and both budgets zero**. The fixed $6 worst-case
reservation covers the current 7,200-second GPU lifecycle plus bounded
controller cost; it is not an app price or expected reconstruction cost.
Training separately defaults to 900 seconds, 3,000 iterations and 500,000
Gaussians. No configuration change or paid provider allocation was performed by
creating this source.

## Viewer, privacy and rollout

`viewer_url` uses `/s/:id#access=<15-minute HMAC capability>` so access
credentials are not URL queries in server logs. The shell keeps the token only
in memory. `GET /spatial/:id/manifest` and `/model?revision=UUID` receive it in
Authorization. Every read verifies current artifact and live membership. Public
requests without a capability require the current approved, unexcluded,
published revision and a live home/workspace. Model bytes stream directly with
no redirect and no-store. Approved scenes late-bind uniquely named flythrough
chapters; no video rerender is needed. Duplicate room labels remain inert
instead of guessing.

Production gates still required:

- Apply/test upload 0037, adoption 0038, spatial 0040 and the deletion
  integration. The existing account-deletion enumeration does **not yet include
  spatial output and sidecars**; do not enable production capture upload until
  it does.
- Configure the upload-v2 gateway and its exact immutable-write lifecycle rules;
  configure `SPATIAL_CAPABILITY_SECRET` (32..256 characters), existing private
  R2 credentials and `TOUR_PUBLIC_BASE_URL`. Never expose these secrets to the
  phone.
- Deploy spatial with platform JWT verification disabled **for this function
  only** because public approved reads and custom scoped output/viewer
  capabilities are authenticated by the handler. Owner routes always call
  Supabase Auth.
- Deploy the bounded worker/controller and viewer assets, configure runtime
  budgets under owner authorization, resolve Modal account billing limits, and
  test one actual capture. Do not infer a GPU/model success from fixture tests.
- Complete real region-redaction processing before claiming the full privacy
  feature. Pending requests already prevent sharing; browser hiding is not a
  fix.
- Test real phone background transfer, cellular/Wi-Fi transition, GPU failure,
  private navigation and visual quality. Then apply internal TestFlight gates.

Verification commands:

```
deno check services/supabase/functions/spatial/index.ts services/supabase/functions/tours/index.ts
python3 tools/audit/run_spatial_edge_regression.py
python3 tools/audit/run_spatial_regression.py
```

The Edge fixture exercises actual handler branches with DB/R2 doubles. The DB
fixture creates a private socket-only PostgreSQL, applies actual migrations,
asserts baseline failure, assertions/replay, a deliberately weakened publish
negative control, and two concurrent budget/claim races with observed lock
waits. Neither harness calls production or deletes customer data.
