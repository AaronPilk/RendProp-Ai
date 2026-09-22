# Account deletion + spatial cleanup integration — 2026-09-11

## Result and scope

Implemented and locally verified on `fix/spatial-deletion-integration-20260911`, based on `baf77f93082e608b1321fdb0927bdabba08bb3fa`. This is source ready for integration, **not a production deletion or deployment receipt**.

The read-only draft in `/Users/pilksclaes/Rendprop AI/deletion-intent-20260911` supplied the original transaction/handler regression work. It was copied and adapted into this isolated branch; that user-owned worktree was not edited. No production SQL, deletion request, R2 deletion, Modal cleanup, Apple change, or deploy was invoked.

The Supabase and PostgreSQL skills informed the shared mutation-lock ordering, service-only grants, explicit search paths, and owned socket-only database verification.

## Changes and source map

All paths below are relative to this repository.

| Area | Implementation / evidence |
| --- | --- |
| Ownership and adoption boundary | `services/supabase/migrations/0039_account_deletion_intent.sql:53`: locks Auth user, profile, sorted orgs and listings before computing solo/shared scope. Adoption-winning data is not deleted. |
| Spatial inventory | `0039_account_deletion_intent.sql:97`: includes current output and every prior attempt output, including planned/dispatching unpublished models; validates canonical scene/org/listing/revision binding. Captures every current/history GPU lease. Malformed history aborts before destruction. |
| Pose/private metadata removal | `0039_account_deletion_intent.sql:227`: unpublishes and excludes scenes before deleting spatial input sidecars, manifest-bearing history and job rows. The intent retains cleanup identities, not the room's poses or manifest. |
| Upload storage inventory | `0039_account_deletion_intent.sql:143`: inventories journaled keys, known multipart IDs and legacy single-PUT staging keys; rejects orphaned or inconsistent ownership instead of guessing. Removes journals only after preserving their cleanup identities. |
| Durable boundary | `0039_account_deletion_intent.sql:217`: the intent INSERT precedes destructive SQL. Both commit together; any SQL exception rolls the entire transaction back. External cleanup starts only after the returned receipt. |
| Late writes | `0039_account_deletion_intent.sql:154`: storage cleanup waits through provider deadline plus 15 minutes, upload dispatch deadline plus one hour, and at least 75 minutes when legacy transport tickets exist. This deliberately does not call an early delete final proof. |
| Provider removal proof | `0039_account_deletion_intent.sql:258`: only matching durable `spatial_provider_attempts(job_id, lease_token)` with BOTH `files_removed` and `terminated` may drain. Missing schema/row, expired TTL and the old `provider_stopped` flag are not proof. |
| Cleanup result fence | `0039_account_deletion_intent.sql:269`: exact request lease, target-subset/identity checks, no premature storage deadline clearing, independent provider proof recheck, real Auth/profile-row absence checks. |
| Handler boundary | `services/supabase/functions/me/deletion.ts:18`: rejects malformed/unbound receipts before any external cleanup. `snapshot_version=2` distinguishes the expanded inventory from legacy/draft snapshots. |
| Truthful HTTP outcome | `me/deletion.ts:72` and `me/index.ts:1197`: Auth removal stays in the durable payload. Auth delete failure returns 500; successful sign-in removal can return `ok:true, cleanup_complete:false` with explicit pending counts. |
| Actual external-cleanup executor | `me/index.ts:1042`: provider-readiness checks, bounded multipart aborts and R2 deletes, existing Stream/GHL/Apple/analytics/profile processing; failed/unvisited entries stay queued. |
| Fair retry queue | `me/deletion.ts:95` and `0039_account_deletion_intent.sql:325`: per-request due time; five-minute backoff after a pending pass, 15-minute processing lease. Five permanently pending accounts cannot monopolize every sweep. |
| Preserved shared org | Shared listings reassign their departing attribution under the transaction; the existing0040 trigger follows ownership for spatial jobs. No shared-team spatial input/output is included in the departed seat's cleanup list. |

## Verification actually run

Working directory: `/Users/pilksclaes/Rendprop AI/spatial-deletion-integration-20260911`.

```sh
python3 tools/audit/run_deletion_regression.py --provider-commit 88066a3887852d3d6e4c021ac901783cea05d133
python3 tools/audit/run_deletion_handler_regression.py
git diff --check
```

All exited **0**. Evidence:

- SQL receipt: `/tmp/rendprop-deletion-db-anj99iu6/receipt.json`; `accepted:true`, `clusterStopped:true`.
- Actual-handler receipt: `/tmp/rendprop-deletion-handler-pgv9e7qb/receipt.json`; `accepted:true`.
- SQL: **32 account-deletion assertions + 30 spatial/upload/provider assertions**, run after application, migration replay, and restoration after mutants.
- Actual provider0041 source used: `88066a3887852d3d6e4c021ac901783cea05d133`; SHA-256 `2a215773b18752223746df5030279d46c73ef19a0bc76ee24ebed0677b6e0243`.
- The paired test applies the actual0041 table/RPC (including app-name, source hash and sandbox identity constraints), then calls its actual cleanup RPC after0039 deleted the spatial parent.
- It also applies0039 in fresh numerical order **before0040 exists** and asserts the exact v2 receipt. Partial spatial schema is an error, not an empty inventory.
- The baseline stale-ownership schedule deliberately exits **3**, showing the old split transaction can delete the adoption winner.
- A real mutation disabling canonical-object ownership validation deliberately exits **3** for the expected forbidden-photo operation.
- A real mutation treating absent/unconfirmed GPU cleanup as success deliberately exits **3** at the missing-provider-proof assertion.
- Actual Deno `index.ts` handler plus pure logic: **41 passed, 0 failed**. Fixture `fetch` is synthetic; Deno runs with network/run/write denied and synthetic-only environment credentials.
- The actual old `baf77f9` handler is loaded separately and deliberately exits **1** for the adoption-winner case (0 passed / 1 failed / 26 filtered out). No fake replacement old implementation is used.
- Handler coverage includes malformed receipts, Auth failure, final-CAS failure, retained private GPU files, provider-journal outage, missing cleanup categories, future storage deadlines, actual R2 helper DELETE/abort paths against a fixture, storage failure, per-pass provider limit, historical manual work and sweeper execution.

### Actual concurrency, not consecutive requests

Each case observes transaction one at its PostgreSQL barrier and transaction two waiting on a real row lock before releasing the first:

| Case | Process exits | Verified result |
| --- | --- | --- |
| Adoption commits first | 0, 0 | Destination keeps org/listing; deletion has no solo-org authority. |
| Adoption rolls back first | 0, 0 | Deletion inventories and removes the original owner's workspace. |
| Deletion commits first | 0, 1 | Adoption rejects the pending deletion intent. |
| Deletion rolls back first | 0, 0 | Adoption succeeds; no deletion intent or destructive result survives. |
| Spatial deletion commits first | 0, 1 | Actual `spatial_claim` rejects unavailable ownership; no GPU lease is created. |
| Spatial claim commits first | 0, 0 | Deletion inventories that exact newly committed lease before removing the job. |

Only the newly created socket-only PostgreSQL cluster was stopped. No user database was touched.

## Integration and rollout requirements

1. Integrate this branch with the provider0041 commit. No provider allocation should be enabled without the durable provider journal and its paired worker/route implementation.
2. Deploy **0039 and the paired new `me` handler together under a controlled old-handler drain**.0039 revokes direct service writes to `deletion_requests`; deploying only the migration makes the old handler unable to create its tombstone. Rolling only the function back after the migration is not compatible.
3. Fresh installs can apply0039,0040,0041 in order. Existing databases that already contain0040 can apply0039. The paired local fixture covers actual0041 as well.
4. Leave spatial generation disabled until all integration/release gates pass. This unit changes no runtime budget, entitlement or provider configuration.
5. Configure/verify the service-role deletion sweep schedule and provider cleanup controller operationally. This code does not create a production cron.
6. Confirm actual R2 permissions/lifecycle, Stream token, Apple revocation configuration, and GHL tenant tags in a separately authorized runtime verification. Local fixture responses do not prove those live services work.
7. Account deletion and App Review / TestFlight remain separate operations; this unit made no Apple change.

## Explicit remaining cases — not silently marked complete

- **Pre-journal GPU attempts:** a historical lease missing a0041 provider row remains pending. A provider `stopped` flag or TTL cannot establish private-file removal. Its original provider identity/cleanup evidence must be reconciled.
- **Ambiguous multipart CREATE:** an operation that dispatched but never recorded its returned upload ID retains `unresolved_uploads` (operation ID, bucket and canonical key). The current sweep cannot safely invent the missing upload ID, and `finish_account_deletion` cannot remove that category. A separate assisted multipart-list/reconciliation unit is still required.
- **Already-running legacy render workers:** their job IDs remain `unresolved_render_jobs`; they have ambient provider credentials and no equivalent durable remote-output cleanup journal. They require assisted reconciliation. New spatial provider journaling does not retroactively fix the older render engine's remote lifetime.
- **Unverified legacy deletion receipts:** remain manual-only, preserving original payloads. Never replay arbitrary `db.ids` from old receipts against an adoption winner.
- **Pre-existing unrecorded R2/Stream orphans:** this inventory covers DB-bound assets and upload/spatial journals, not every historical orphan that an earlier implementation failed to record. An ownership-bounded provider inventory/lifecycle audit is still a manual release gate.
- **Orphaned/malformed ownership rows or excessive inventories:** transaction aborts with nothing touched and requests assisted deletion. No partial inventory authorizes destructive cleanup.
- The provider journal itself and aggregate budget/audit records remain as minimal non-cascading reconciliation/audit data; the room's image/pose/manifests and output objects are the cleanup targets. A retention policy for minimal completed audit records is a separate product/legal decision.
- The current R2 helper's network timing is unchanged. If an invocation outlives its cleanup lease, final CAS fails, and the durable original payload remains retryable; no completion is claimed.

Thus this closes the transactional ownership and known spatial cleanup omissions **in source**, but it is not a claim that every historical production deletion can now finish without reconciliation.

## Source-bound hashes from accepted receipts

```text
fffc79902a2be3e824d483ba993d69170758f70c572e7a2f9ae50becab6fafe9  services/supabase/migrations/0039_account_deletion_intent.sql
49398f0153672ca82bb7ba3ef901ccea25aceeb6c0f0c6ff56839e3f42ab9b9e  services/supabase/functions/me/index.ts
6caf14a5305e3b9fec335ee12cab7f40e2bd6063be28df3ab555146a241bb0bf  services/supabase/functions/me/deletion.ts
3c96b3165c3420a2705a32ee9449a8d950778b6e1e4d74b6d75eee3d92299624  services/supabase/functions/me/logic.ts
2e4d720981cabe05302a10b3dc9473c7e087559755ba630c41049462782549e5  services/supabase/tests/account_deletion_spatial.sql
b0af5e0a2ea9c19e44c490b844d82f9f1307dfab7e2e053b1ceb687311ba6dc8  tools/audit/run_deletion_regression.py
56c93eec7e24433766595a8c207be9a3f9744424909262b490262227e8b5c9e0  tools/audit/run_deletion_handler_regression.py
```

The full receipts hash every migration/test/shared source used. Temporary logs may be removed by the OS; this report preserves the commands, outcomes, exact sibling provider source and principal tested source hashes.
