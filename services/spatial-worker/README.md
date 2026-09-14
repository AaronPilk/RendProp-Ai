# Automatic spatial reconstruction worker

The app uses the deployed Supabase`spatial` route, not this machine. This Modal
application polls the durable queue, claims ONE attempt, downloads its approved
private inputs, validates/reuses the ARKit adapter, trains on an ephemeralL4,
converts toSOG and uploads the sealed output for in-app private review. Customers
do not export folders, rent GPUs or run any command.

## Deployment status

**Automatic app-queue workflow is not yet accepted on a real cloud job.**
The September 14 controlled experiments are recorded in
[the ablation report](../../docs/audits/2026-09-14/SPATIAL-ABLATION.md).
Pose optimization alone, 30,000 training steps, and the first real-SfM profile
all failed visual acceptance. Two further CPU SfM candidates were rejected
before GPU training because of missing coverage or implausible camera poses.
No winning reconstruction profile is approved for deployment.

The disabled worker candidate now uses the exact-source L4 GPU SOG converter
verified by a separate private export probe: 500,000 Gaussians, three SH bands,
ten clustering iterations and an 8.61 MB output in 18.08 seconds. The actual
production decoder loaded that output. This verifies export compatibility,
not reconstruction quality or automatic queue acceptance. Importing `app.py`
or running tests neither starts the scheduler nor allocates a GPU.

Never enable this worker just to make a UI screenshot look complete. The backend
runtime row defaults disabled with zero budgets and the scheduler independently
requires both reviewed source`DEPLOYMENT_ENABLED=True` and
`SPATIAL_WORKER_ENABLED=true`. The current source has the former false and
attaches no Secret or schedule, so stale configuration cannot activate a disabled
deploy or incur recurring idle invocations. A bounded manual disabled invocation
can prove deployment without polling production or creating a GPU.
Read the standing brief before deployment;
no App Review metadata/build attachment changes are part of this service.

## Runtime contract

- Supabase migration0040 owns jobs, private frame metadata, worker leases and
  atomic global/day+organization/month reservations. Migration0039 deletion work
  must be integrated first and cover spatial keys before production enablement.
- Service key exists ONLY in the CPU controller, never the GPU sandbox or iOS.
- Migration0041 journals paid attempt and lease identities before allocation,
  provider ID before transfer, and independent file-removal/termination flags.
  It has no cascading job/account foreign keys. Failed cleanup remains pending
  after temporary controller files disappear or account deletion completes.
  Download/adapter failures before provider entry record `not_created` atomically;
  they cannot overwrite an existing ambiguous provider intent or grant dispatch.
- All HTTP requests identify the actual service as`Rendprop-Spatial-Worker/1.0`;
  no browser impersonation or firewall setting changes are used.
- Input files use expiring exact-host private download URLs; redirects refused.
 20–400JPEGs,32MiB/file,2GiB total; sidecars1MiB each, metadata16MiB total.
- `max_seconds`: first-profile lifecycle is fixed at7200s maximum authority;
  the actual providerTTL uses remaining time minus120s. Shorter configuration
  profiles need measured bootstrap support and are not silently accepted.
  The candidate admits `max_training_seconds` up to 4200 and `max_iterations`
  up to 30000; defaults remain 900 seconds / 3000 steps, with at most 500000
  Gaussians. Draft migration 0055 widens only the corresponding database check
  constraints; it has not been applied and does not change live runtime values.
- Database reservesUSD6 per attempt before queueing, conservatively covering the
  documented full sandbox lifetime and bounded CPU controller. This is not a
  measured typical room cost. No automatic refund or second paid GPU on ambiguous
  failure; actual invoice reconciliation is separate.
- One CPU controller container at a time,2CPU/4GiB,7500s timeout,
  no automatic invocation retries. Sandbox has1L4/4CPU/32GiB, hard TTL, no volumes,
  snapshots, ports or credentials. Network denied before media transfer.
- No provider8GiB disk limit is claimed. Modal rejected that explicit disk
  request; its parameter increases the default512GiB quota and can increase
  billable memory. The override is omitted. Input and output are separately
  bounded by the application at2GiB and32MiB; temporary derived datasets and
  dependencies also occupy scratch space.
- Export validates the L4/Vulkan device before private media transfer, uses GPU
  index 0 with no CPU fallback, binds the training PLY bytes/hash/count to its
  receipt, and checks the bounded SOG archive and conversion receipt. The
  converter has a 600-second process timeout within the existing job deadline.
- FinalSOG≤32MiB. One-write service output ticket binds a server-created revision,
  actual bytes and SHA256. Completion is server-confirmed and remains private.
- Lease renewal continues during output transfer. A failed heartbeat terminates
  compute. Finishing output serializes with heartbeat to avoid late mutations.
- Failure sends `provider_stopped:true` only before any allocation attempt or
  after terminal provider readback. An ambiguous CREATE/termination leaves it
  false so explicit retry cannot overlap an uncertain previous GPU lifetime.
- Raw captures are not public. Review/exclusion can revoke sharing; requested
  region edits cannot be published without an actual processed derivative.

## Required configuration (values are never committed)

Modal secret`rendprop-spatial-control-plane`:

- `SPATIAL_API_URL`: exact HTTPS Supabase`/functions/v1/spatial` base.
- `SPATIAL_SERVICE_TOKEN`: existing authorized service-role credential.
- `SPATIAL_INPUT_HOSTS`: comma-separated exact private R2download hostnames.
- `SPATIAL_WORKER_ENABLED`: absent/false until operational acceptance.

Supabase: spatial capability-signing secret, private R2 configuration, HTTPS tour
host origin, uploadv2 gateway/recovery deployment, explicit operational budgets.
The Edge handler authenticates user, worker, viewerMAC and public paths itself;
deployment must not let the outerJWT gateway reject the distinct capability paths.
No disabled`ai_routes`row is needed or should be enabled for this feature.

## Checks actually available locally

```
python -m unittest discover -s services/spatial-worker -p 'test_*.py'
python -m unittest discover -s tools/spatial-spike/training -p test_modal_room.py
```

These execute controller, provider-boundary, stream, integrity and lifecycle
assertions with synthetic inputs. They are not a GPU reconstruction acceptance
test. The actual pinned Modal1.5.3 application definition and disabled local
invocation have also been exercised without any provider allocation.

Remaining runtime proof: deployed automatic worker entry/queue integration,
acceptable source-bound real-room quality, finalized cost, real iPhone viewer
navigation/performance and native background upload through a network handover.
The floor and navigation box are capture-derived estimates, not RoomPlan geometry,
collision boundaries or trustworthy two-point measurements. No such claim is
made in the manifest or viewer.

## Reproducibility caveat

Base image, Node 22.22.0 archive, gsplat 1.5.3 commit, GLM gitlink,
PlayCanvas 2.22.1 and SplatTransform 3.4.2/npm lock are pinned. The 164 resolved
Python distribution versions are frozen to the baseline and checked for exact
equality after network denial and before private media transfer. Public apt
packages still resolve during setup, so the image is not fully hermetic.
Source-bound manual A/B/D training and the L4 export probe ran successfully;
the automatic app-queue path and acceptable real-room quality remain unproven.
