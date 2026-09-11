# Spatial provider receipts and one-room continuation

Source branch: `fix/spatial-provider-receipts-20260911`, based on `baf77f9`.
This document records source/offline verification before the proposed room run;
it does not claim reconstruction, deployment or iPhone acceptance.

## Durable provider journal

`0041_spatial_provider_attempts.sql` introduces a service-only, RLS-protected
table without cascading foreign keys. It retains distinct paid `attempt_key`
and dispatch `lease_token`, immutable provider name/ID, bounded source hash,
deadline, terminal code and independent file-removal/termination flags.

The worker must commit intent before CREATE and acknowledge the returned
provider ID before transferring any source or media. Replayed intent grants
no second dispatch. An ambiguous CREATE remains pending and is reconciled only
by its exact pre-recorded name. A finished sandbox does not by itself prove
explicit directory deletion. Cleanup acknowledgements remain writable after
the job/listing/account disappears; the deletion integration consumes both
confirmed flags. Arbitrary SDK bodies, tokens, photos, poses and raw logs are
not stored in this journal.

`provider_journal.py` sends small receipts outside the controller's temporary
directory. A locally successful cleanup without a durable acknowledgement is
not a successful job. An interrupted controller can still leave a pending
journal row requiring assisted provider cleanup; no autonomous orphan-sweeper
has been proven by this unit. A missing/ambiguous provider is never treated as
deleted merely because its TTL elapsed.

The scheduled deployment source is explicitly disabled (`DEPLOYMENT_ENABLED`
false) and attaches no service Secret. Even a stale environment
`SPATIAL_WORKER_ENABLED=true` cannot activate it. Enabling the deployment,
its service credential and operational budgets is a separate reviewed action.

## Actual verification

- `python3 -m unittest discover -s services/spatial-worker -v`: 38 tests,
  exit0. Includes actual disabled entry invocation with synthetic decorators,
  no-allocation on missing journal acknowledgement, no transfer before ID
  acknowledgement, temporary-directory removal with retained external receipt,
  lost CREATE response, terminal failure and durable cleanup failure.
- `python3 -m unittest discover -s tools/spatial-spike/training
  -p 'test_modal*.py' -v`: 35 tests, exit0. Six continuation tests prove prior
  charge retention, unchanged original marker, no second attempt, rejected
  changed evidence, active GPU/unterminated old allocation, and ambiguous CREATE
  preserving the new reservation. The initial test fixture used an unresolved
  macOS temporary path and correctly failed lineage checks; the fixture was
  fixed to use its resolved path, not by weakening the production check.
- `deno test --allow-net --allow-env --no-check spatial/`: 26 tests, exit0.
  Executes the provider receipt route with injected database fixtures; actual
  Postgres behavior is covered separately below.
- `python3 tools/audit/run_spatial_provider_regression.py`: exit0. New owned
  socket-only PostgreSQL17 database; 20 assertions on first apply/replay/restore.
  Red-before-migration exit3; deliberate always-dispatch mutant exit3 at the
  replay guard. Evidence: `/tmp/rendprop-provider-db-zkk1d46k/receipt.json`.
  The owned database was stopped. No production SQL was executed.
- Targeted Python negative control replaced `ProviderJournal.plan` with a no-op
  in memory. `test_no_allocation_without_durable_intent_acknowledgement` exited1
  because CREATE was called once. The source was never weakened.

## Existing approval continuation

The prior failed allocation's independently read usage is **$1.09974939**.
Its original allocation marker and all receipts remain unchanged. Its provider
exit137 and historical billing-limit reason do not prove today's allocation
eligibility; the newer dashboard shows headroom and only a fresh CREATE can
establish whether Modal will allocate now.

Fresh read-only observation at `2026-09-11T21:09:45.528674Z`, pinned Modal1.5.3:
the exact experiment app had **zero active sandboxes** and the previous sandbox
polled terminal137. No allocation was made by that check.

The reviewed private continuation plan is
`/Users/pilksclaes/LocalSpatialExperiments/room-retry-20260911-plan-v1.json`.
It hashes the original marker, prior provider/billing receipts, exact approved
153-frame prepared dataset and runner source. It records the still-unconfirmed
prior remote-directory deletion honestly. It does not erase old reservations
or infer an unused $25 allowance.

Published compute rates checked September11: L4 $0.000222/s, Sandbox CPU
$0.00003942/core/s, RAM $0.00000667/GiB/s. The reviewed profile is one L4,
4-core hard limit,32GiB hard limit,7200s provider TTL, broad-US1.15 multiplier:
**$4.9110336000** conservative full-lifetime compute, not an invoice.
Prior plus fresh bound is **$6.0107829900**, within the existing **$25 total**
approval. Sources: [Modal pricing](https://modal.com/pricing),
[region selection](https://modal.com/docs/guide/region-selection).

The new runner holds the same approval lock and writes a separate immutable
retry marker before its single call to the existing `modal_room.run`.
It rechecks plan hashes, committed clean source, the exact app, zero active
sandboxes and previous termination. It never creates a new app, changes billing,
retries allocation automatically or increases the budget.

Pending command, authorized only after parent review and clean source:

```sh
MODAL_PROFILE=rendprop-room-experiment \
  /Users/pilksclaes/.local/bin/uv tool run --from modal==1.5.3 python \
  tools/spatial-spike/training/modal_retry.py run \
  --plan '/Users/pilksclaes/LocalSpatialExperiments/room-retry-20260911-plan-v1.json' \
  --state '/Users/pilksclaes/LocalSpatialExperiments/modal-room-20260911-01' \
  --confirm-one-allocation
```

The experiment runner requests900s training/3000 steps/500000-gaussian maximum,
collects bounded private PLY/held-out diagnostics, then removes its scoped
remote directory and terminates/polls the sandbox in `finally`. A source-bound
provider receipt saves the allocation ID immediately. Logs are streamed and
bounded; failures preserve terminal evidence without printing SDK credentials.
No scheduled production budgets, Apple review settings, or public room
publication are part of this experiment authorization.
