# Rollback SQL for the 2026-10-17 production migrations

| Migration file | Live record | Rollback | Proven |
|---|---|---|---|
| `20261017115012_conservative_pipeline_cost_binding.sql` | `20261017175731` (applied 17:57Z) | `ROLLBACK-20261017115012-conservative_pipeline_cost_binding.sql` | disposable PG: restores `serving_ceiling_spent_cents` `d053fe5b` and `serving_cost_finish` `8a15681f`, drops the two helpers and the empty binding table |
| `20261017190000_provider_attempt_supplier_reference.sql` (E3) | not applied | `ROLLBACK-20261017190000-provider_attempt_supplier_reference.sql` | disposable PG: restores 8-arg `provider_attempt_finish` `7516d4d9`, drops the 9-arg overload and `provider_request_ref`; run only after `property` is rolled back |
| `20261017190100_app_video_rp402_copy.sql` (E8) | not applied | `ROLLBACK-20261017190100-app_video_rp402_copy.sql` | `prove-e8-rollback.sh` / `.log`: 15ff3c0d → 9828980a, owner+ACL unchanged, idempotent, re-apply and replay OK, unknown body refused |

Each rollback refuses an unknown body instead of normalising it. None touches
historical rows. Run with `psql -v ON_ERROR_STOP=1 -f <file>` against the
target only after reading the live bodies first.
