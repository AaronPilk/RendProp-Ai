# Automatic spatial reconstruction worker

The app uses the deployed Supabase `spatial` route. This Modal application is
the controller implementation for polling its durable queue, claiming one
attempt, downloading approved private inputs, validating the ARKit dataset,
training in an ephemeral L4 sandbox, converting to SOG and uploading sealed
output for private review. The intended product flow does not require customers
to export folders, rent GPUs or run commands.

## Deployment status — 24 September 2026

**Automatic app-queue reconstruction is not accepted for release.** All seven
completed ablations on the owner's later 400-frame capture are NO-GO. There is
no accepted `spatial_runtime` profile. See the [current results and costs](../../tools/spatial-spike/README.md#current-evidence--24-september-2026)
for every run, the fixed evaluation set and the remaining capture-quality work.
The September 11 153-frame run was the earlier blurry baseline, not the latest
experiment. The old billing-cycle allocation refusal is historical.

Gross spatial spend in the reconciled September 24 evidence is $19.98118436
against the unchanged $25 total ceiling. The $6 queue reservation is a
worst-case hold, not the typical price or a new experiment allowance. Reconcile
actual usage and pending holds before any further paid run; do not infer
remaining authority from a configured daily budget.

All four activation gates remain separate:

1. The database `spatial_runtime` row must have `enabled=true` and positive daily
   and organization-month budgets with room for a reservation.
2. Reviewed source must set `DEPLOYMENT_ENABLED=True` in `app.py`.
3. The controller environment must have `SPATIAL_WORKER_ENABLED=true`.
4. The Modal application must actually be deployed.

Current source keeps gate 2 false and attaches no Secret or schedule, so stale
configuration cannot activate a disabled deployment. Importing `app.py`, running
synthetic tests, or making a bounded disabled invocation does not allocate a GPU.
The latest reviewed spatial report records no enablement. Studio's separate web
release does not establish spatial readiness.

Before activation, integrate and test an accepted dataset/trainer/converter
profile, prove the disabled deployment entry, then perform the owner's real-phone
upload → queue → private-viewer acceptance within the remaining budget. Raising
database values alone cannot reproduce the separate 30,000-step experiments:
this source still enforces 7,000 steps/1,800 training seconds and disables pose
optimization. Do not enable the worker for a screenshot. App Store Connect is
outside this service's deployment scope.

## Runtime contract

- Supabase migration 0040 owns jobs, private frame metadata, worker leases and
  atomic global/day + organization/month reservations. Migration 0039 already
  includes spatial input/output/history enumeration and sidecar removal, with
  tests in `services/supabase/tests/account_deletion_spatial.sql`. Verify the
  deployed deletion stack and durable cleanup receipts before enablement;
  source presence is not a fresh live-schema check.
- Service key exists ONLY in the CPU controller, never the GPU sandbox or iOS.
- Migration 0041 journals paid attempt and lease identities before allocation,
  provider ID before transfer, and independent file-removal/termination flags.
  It has no cascading job/account foreign keys. Failed cleanup remains pending
  after temporary controller files disappear or account deletion completes.
  Download/adapter failures before provider entry record `not_created` atomically;
  they cannot overwrite an existing ambiguous provider intent or grant dispatch.
- All HTTP requests identify the actual service as `Rendprop-Spatial-Worker/1.0`;
  no browser impersonation or firewall setting changes are used.
- Input files use expiring exact-host private download URLs; redirects refused.
  20–400 JPEGs, 32 MiB/file, 2 GiB total; sidecars 1 MiB each, metadata 16 MiB total.
- `max_seconds`: first-profile lifecycle is fixed at 7200 s maximum authority;
  the actual provider TTL uses remaining time minus 120 s. Shorter configuration
  profiles need measured bootstrap support and are not silently accepted.
  `max_training_seconds`: trainer subprocess ≤1,800 s (default 900 s).
  `max_iterations`: ≤7,000 (default 3,000); Gaussians ≤500,000.
- The database reserves USD 6 per attempt before queueing, conservatively
  covering the sandbox lifetime and bounded CPU controller. Migration 0043
  returns a reservation only for a cancelled or expired attempt never claimed
  by a worker and without a provider receipt. Dispatched/ambiguous work keeps
  its charge. There is no second paid GPU on ambiguous failure; actual invoice
  reconciliation is separate.
- One CPU controller container at a time, 2 CPU/4 GiB, 7,500 s timeout,
  no automatic invocation retries. Sandbox has 1 L4/4 CPU/32 GiB, hard TTL, no volumes,
  snapshots, ports or credentials. Network denied before media transfer.
- No provider 8 GiB disk limit is claimed. Modal rejected that explicit disk
  request; its parameter increases the default 512 GiB quota and can increase
  billable memory. The override is omitted. Input and output are separately
  bounded by the application at 2 GiB and 32 MiB; temporary derived datasets and
  dependencies also occupy scratch space.
- Final SOG ≤32 MiB. One-write service output ticket binds a server-created revision,
  actual bytes and SHA256. Completion is server-confirmed and remains private.
- Lease renewal continues during output transfer. A failed heartbeat terminates
  compute. Finishing output serializes with heartbeat to avoid late mutations.
- Failure sends `provider_stopped:true` only before any allocation attempt or
  after terminal provider readback. An ambiguous CREATE/termination leaves it
  false so explicit retry cannot overlap an uncertain previous GPU lifetime.
- Raw captures are not public. Review/exclusion can revoke sharing; requested
  region edits cannot be published without an actual processed derivative.

## Required configuration (values are never committed)

Modal secret `rendprop-spatial-control-plane`:

- `SPATIAL_API_URL`: exact HTTPS Supabase `/functions/v1/spatial` base.
- `SPATIAL_SERVICE_TOKEN`: existing authorized service-role credential.
- `SPATIAL_INPUT_HOSTS`: comma-separated exact private R2 download hostnames.
- `SPATIAL_WORKER_ENABLED`: absent/false until operational acceptance.

Supabase: spatial capability-signing secret, private R2 configuration, HTTPS tour
host origin, upload-v2 gateway/recovery deployment, explicit operational budgets.
The Edge handler authenticates user, worker, viewer MAC and public paths itself;
deployment must not let the outer JWT gateway reject the distinct capability paths.
No disabled `ai_routes` row is needed or should be enabled for this feature.

## Checks actually available locally

```
python -m unittest discover -s services/spatial-worker -p 'test_*.py'
python -m unittest discover -s tools/spatial-spike/training -p test_modal_room.py
```

These execute controller, provider-boundary, stream, integrity and lifecycle
assertions with synthetic inputs. They are not a GPU reconstruction acceptance
test. The actual pinned Modal 1.5.3 application definition and disabled local
invocation have also been exercised without any provider allocation.

Remaining runtime proof: deployed automatic worker entry/queue integration,
acceptable source-bound real-room quality, that accepted job's reconciled cost,
real iPhone viewer navigation/performance and native background upload through a network handover.
The floor and navigation box are capture-derived estimates, not RoomPlan geometry,
collision boundaries or trustworthy two-point measurements. No such claim is
made in the manifest or viewer.

## Reproducibility caveat

Base image, Node 22.22.0 archive, gsplat 1.5.3 commit, GLM gitlink,
PlayCanvas 2.22.1 and SplatTransform 3.4.2/npm lock are pinned. The inherited experiment setup still
resolves transitive Python dependencies and apt packages during setup. A locked,
prebuilt deployment image and a reproduced deployment-profile CUDA build remain
release gates. Separate experiment builds and mocked provider tests do not
close production reproducibility or quality acceptance.
