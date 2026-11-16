# Terminal compare-and-set conflicts — 2026-10-06

A stale Studio edit reached the production facts RPC, but the caller received no HTTP response before its 30-second timeout. The first intended edit succeeded; the stale request's journal records an ambiguous network outcome. The harness subsequently replaced that transport classification with `unexpected-rejection-status`. That label does not prove an incorrect HTTP status was received.

Production log counts independently identified repeated `40001` errors in `save_listing_facts` after the caller timed out. Supabase documents that raising this serialization-failure code for an application conflict causes PostgREST 14 to retry the transaction indefinitely. A semantic stale-value conflict must use the terminal custom code `PT409`. See [Supabase's exact troubleshooting guide](https://supabase.com/docs/guides/troubleshooting/high-cpu-and-infinite-transaction-retries-when-using-custom-error-codes-in-rpc-functions-77326b) and [PostgREST 14 custom HTTP error codes](https://docs.postgrest.org/en/v14/references/errors.html#raise-errors-with-http-status-codes).

The additive migration `20261006193633_cas_conflicts_terminal.sql` replaces only five literal application-conflict codes in three current functions:

| Function | Replacements | Reviewed old body MD5 | Terminal body MD5 |
| --- | ---: | --- | --- |
| `save_listing_facts(uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb)` | 2 | `7ced278d1c3685915093ef333b701194` | `79b9931a7ee69d46436a80304145cacb` |
| `save_listing_measurements(uuid,uuid,uuid,text,text)` | 2 | `90890dc9f97234d95caadd6a6c8ff037` | `18d0428995631a94c5506d8b8c14eee6` |
| `studio_attach_floorplan(uuid,uuid,uuid,uuid,jsonb,text)` | 1 | `b35ee6a76f54347b4c6df872b395e905` | `9afe2477225c8f16a83a66fe47363d5e` |

Unknown body drift fails the migration. A replay accepts only the exact terminal body. All comparisons, locks, role and deletion checks, signatures, grants, owners, function configuration and volatility are preserved. The two Edge handlers recognize `PT409` and retain their existing `40001` mapping for genuine serialization errors during transition. No client retry setting is changed: the defective loop occurs inside PostgREST before its RPC response, so disabling JavaScript retries would not resolve it.

Local reproduction uses the actual migrated functions in owned, socket-only PostgreSQL fixtures. It performs successful edits, stale edits and identical desired-value replay. Replacing only `PT409` with the former `40001` makes the conflict fixture fail despite retaining the comparison, proving the terminal code is tested separately from protection against overwritten values. Independently removing comparisons or row locks still violates the concurrent-edit invariants and is caught by existing controls.

Validation commands:

```sh
python3 tools/audit/run_listing_facts_cas.py
python3 tools/audit/run_listing_measurement_cas.py
python3 tools/audit/run_subscription_chronology.py
deno test --cached-only --allow-read --allow-env services/supabase/functions/listings/measurements_test.ts services/supabase/functions/studio/listing-actions.test.ts
deno run --cached-only --allow-env --allow-read tools/audit/listing-facts-handler-20261004.ts
```

The facts runner includes fresh and replayed facts (52), nearby-note (6) and floor-plan (25) assertions, complete-body and authority drift controls, and real same-field/disjoint-field writer races. The measurement runner includes 44 assertions in each schema phase and comparison/locking negative controls. Actual Edge route tests include both terminal and transitional error codes and assert one RPC invocation for each refusal. The chronology runner compiles its fault controls from the current function definitions so it cannot restore a superseded conflict code or remove a later facts allowance.

Release review must add the exact measurement function to the prior 76-function catalog proof, which did not inventory that RPC, and update only the changed facts and floor-plan body expectations. Deploy both PT409-aware Edge handlers before applying this additive migration. Preserve the failed API journal and reconcile its owned fixture through read-only queries; do not reset it or replay a possibly dispatched mutation.

The official guide warns that replacing a function does not stop already looping in-flight transactions. Any exact-backend termination is a separate root-owned operational action. This patch's local SQL/route tests do not claim hosted PostgREST acceptance, a successful resumed API journey, or any live deployment. Native build 45 is unchanged.
