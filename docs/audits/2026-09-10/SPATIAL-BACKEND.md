# Spatial backend implementation — 2026-09-11

Implemented on the shared `feat/spatial-product-20260911` integration worktree.
No migration, Edge function, GPU allocation, runtime budget, or Apple change was
deployed by this unit. The Supabase skills guided service-only grants, ownership
locking, explicit operational limits and disposable PostgreSQL verification.

## Later root-integrated recovery checkpoint

The earlier remaining-work items3–5 below are now implemented in source:
explicit same-capture retry (max3attempts, fresh atomic reservation, stable-key
replay, prior GPU-stop/deadline gate); undispatched cancel/resume retaining input
bindings and reservations; independent expiry plus owner-status refresh.
Historical attempt snapshots preserve previous output keys/leases for cleanup.
The first cloud profile now requires7200s; shorter unexecutable configurations
are rejected. Backend/browser room-label, anchor-ID, floor and camera-distance
admission now agree for the four reproduced mismatch cases.

Root's completed current DB gate:69 SQL assertions after apply/replay/restoration,
publication negative control and three observed lock races, including same-key
retry. `/tmp/rendprop-spatial-db-dmp7_mcp/receipt.json` accepted=true.
The prior68-assertion SQL execution was not a green harness: runner still
expected41 and exited1. Root corrected the count and added the69th assertion.
Root also reran25 Edge tests plus the output-digest mutant:
`/tmp/rendprop-spatial-edge-kqb0u1f2/receipt.json`.
Dedicated HTTP tests for the new recovery routes and different-key retry/
cancel-versus-claim overlap remain to be added. No live service was changed.
The baseline detail below remains useful historical evidence, not a claim that
the recovery routes are absent in the current source.

## What the actual source now does

- `services/supabase/migrations/0040_spatial_jobs.sql`: durable listing-scoped
  jobs, immutable per-capture input bindings, operational runtime configuration,
  global daily/org monthly worst-case reservations, replay checks and a worker
  lease. A runtime-created room starts private. Defaults cannot spend: disabled
  and budgets zero. Anonymous app sessions are accepted; marketing cannot write.
- The ownership lock order is profile → org → listing → job. Queue reservations
  serialize under the org/runtime/window locks. Maximum three active jobs per
  org. A repeated create/start/claim cannot duplicate one paid attempt.
- Existing completed private upload-v2 JPEG tickets are the only image input
  authority; arbitrary keys, URLs, public render uploads and incomplete tickets
  are rejected. JSON sidecars stay in private DB rows. Start checks exact frame
  coverage, actual recorded byte totals, ordered timestamps and nonzero points
  before consuming a generation reservation.
- Worker claim, heartbeat, one-time output dispatch, output acknowledgement,
  complete and fail are lease-fenced. The claim route expires abandoned leases
  in a separate transaction; it does not rent another GPU for them.
- The sandbox receives expiring GET URLs and a narrow output-upload capability,
  not Supabase/R2 secrets. The Edge handler hashes the actual ≤32 MiB output
  body before an immutable, conditional, server-signed PUT. Replays recover the
  recorded write; they do not authorize another physical write. Completion
  HEAD-checks the sealed key and validates the scene manifest.
- `spatial_follow_listing_owner` follows the listing attribution change made by
  account adoption, preserving its original creator separately and keeping an
  existing worker lease alive after the anonymous→Apple handoff.
- Private owner view capabilities are 15 minutes and bind job, artifact revision
  and live actor membership. They live in a URL fragment, then an Authorization
  header, not query logs. Model responses require the matching revision and are
  no-store streams, not a redirect to a public original.
- Current-artifact privacy approval and room exclusion are durable. Exclusion or
  any new review revokes sharing immediately. Nonempty region requests remain
  private and cannot be misrepresented as processed redactions.
- `services/supabase/functions/tours/index.ts` attaches uniquely matching public
  3D room anchors to existing chapters at request time. No rerender is needed.
  A missing 0040 table/read failure only suppresses optional anchors; it cannot
  make an existing flythrough return 503. Duplicate labels remain unbound.

Full API/payload/limit contract:
`services/supabase/functions/spatial/README.md`.

## Tests actually executed

1. `deno check services/supabase/functions/spatial/index.ts
   services/supabase/functions/tours/index.ts` exited 0.
2. `python3 tools/audit/run_spatial_edge_regression.py` exited 0.
   **25 Deno tests passed, 0 ignored**, exercising the actual route handler,
   input/scene validation, capabilities, actual body hashing and late binding.
   The DB/R2 interfaces in these tests are doubles, not production proof.
   A copied-source mutation that removes the output digest equality was rejected
   with exit 1 by the actual output route test.
   Receipt: `/tmp/rendprop-spatial-edge-ktycdt2_/receipt.json`.
3. `python3 tools/audit/run_spatial_regression.py` exited 0 against a newly owned
   socket-only PostgreSQL cluster. Actual migrations 0001..0038 plus 0040 ran.
   **41 SQL assertions** passed after application, after migration replay and
   after restoring the deliberate mutant. The same fixture failed before 0040
   with exit 3 for the expected missing-table assertion. Removing the publish
   privacy guard failed with exit 3 for the expected forbidden-publication test.
   Two concurrent-session cases passed: one-budget/two-starts and
   one-queued-job/two-worker-claims. Both explicitly observed PostgreSQL
   `wait_event_type = Lock`; state readbacks proved one reservation and one lease.
   Receipt: `/tmp/rendprop-spatial-db-uxw_bk7i/receipt.json`.
   The exact fixture-owned clusters were stopped, not production databases.

The receipts contain source SHA-256 and command evidence. Logs remain local;
these are not hosted-Supabase, real-R2, actual provider or phone acceptance tests.

## Remaining work — explicitly not closed

1. **Deletion integration is a production gate.** Existing account deletion does
   not enumerate spatial output objects/private frame metadata. The new tables
   intentionally do not cascade away the only cleanup identity. Integrate 0039
   and spatial tombstone/lease cleanup before enabling production uploads.
2. **Actual region processing is not implemented by this unit.** A request is
   durable, revokes the public view and blocks publication, but no derivative is
   generated yet. Browser masking does not count as redaction. Whole-room
   exclusion and explicit owner approval for a room needing no redaction work.
3. **Explicit failed-capture retry is the next server/client unit.**
   `unique(listing_id,capture_id)` intentionally prevents silent duplicate paid
   attempts; currently it also means a failed capture cannot become a new paid
   attempt through `/create` or `/start`. Implement an explicit user-requested
   retry operation with a new idempotency key, immutable reuse of already
   completed input tickets, a fresh worst-case reservation and no overlapping
   old provider lifetime. Do not tell the user to rescan or alter the capture ID
   to bypass this guard. A leased job is not automatically retried.
4. **Abandoned uploading jobs need cancel/retention recovery.** Their pending
   status can consume the three-active-job slots. The upload gateway's own
   reservation sweeper does not yet cancel these spatial job rows. Implement a
   listing/actor-authorized cancellation and retention mechanism, with real
   cleanup journaling rather than data deletion in a test.
5. **Lease-expiry UI when the controller is unavailable needs a follow-up.**
   Expiry is durable when the dispatcher next calls `/worker/claim`. If that
   controller stops entirely, GET status currently returns the last stored
   processing state until the expiry job runs. Add an authorized narrow expiry
   transaction/status refresh or an independently scheduled sweep.
6. **Provider execution and phone proof are still required.** Input signed GET
   URLs last 15 minutes; the controller must transfer before expiry or request
   refreshed read authority. A 32 MiB Edge hash/conditional PUT must be measured
   against hosted function memory/time limits. No real SOG has been received by
   this unit, and no on-phone viewer quality/performance claim is justified.
7. **Operational rollout is intentionally separate.** Configure signing, upload
   v2, private storage, the viewer origin/assets, controller credentials and an
   owner-approved budget. Deploy only this spatial function with platform JWT
   verification disabled; its handler explicitly authenticates each route.
   The GPU account billing ceiling remains an owner/operator gate.

Do not call this a complete production feature yet. This is the implemented,
tested backend foundation; the incomplete units above remain required.

## Files owned by this unit

- `services/supabase/functions/spatial/{index,contract,capability,storage,chapters}.ts`
- `services/supabase/functions/spatial/spatial.test.ts`
- `services/supabase/functions/spatial/README.md`
- `services/supabase/migrations/0040_spatial_jobs.sql`
- `services/supabase/tests/spatial_jobs.sql`
- `services/supabase/functions/tours/index.ts` (small optional binding addition)
- `tools/audit/run_spatial_regression.py`
- `tools/audit/run_spatial_edge_regression.py`
- This report.

The CLI also generated untracked `services/supabase/.temp/cli-latest`; do not
include it in the feature commit. No other agent's changes were staged or
committed by this unit.
