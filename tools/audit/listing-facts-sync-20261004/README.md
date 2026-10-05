# Ordinary listing synchronization proof

Run `python3 tools/audit/listing-facts-sync-20261004/run.py` on macOS with Xcode command-line tools. The harness compiles the actual listing model, JSON decoder, facts serializer, AppModel setters, synchronization and explicit shared-version review methods. Auth, workspace and transport are owned synthetic boundaries. Each receipt binds extracted methods, model files and harness inputs by SHA-256 and checks the source again after execution.

Coverage includes sparse changed-field intent, SQL null versus zero, raw timestamps and typed detail values, coordinate pairs, persistence, office changes, retained conflicts, review choices, newer edits during a save, late errors after adopting the shared version, and identity/workspace replacement. Changing a main photo must not stage an ordinary full-row update. Clearing a Studio-archived sold marker must explicitly restore its shared status.

Ordinary facts and measurement receipts must contain the exact submitted listing and workspace UUIDs. Wrong, missing or malformed identities are rejected before model mapping; actual synchronization retains local intent and rejects unrelated returned facts. This tests malformed-response defense with synthetic responses and does not claim live response misrouting.

These compiled fault controls must fail at their named behavioral assertions; the runner succeeds only when the expected regression is reproduced:

```
python3 tools/audit/listing-facts-sync-20261004/run.py --inject-fault broad-wire
python3 tools/audit/listing-facts-sync-20261004/run.py --inject-fault wrong-workspace
python3 tools/audit/listing-facts-sync-20261004/run.py --inject-fault late-conflict
python3 tools/audit/listing-facts-sync-20261004/run.py --inject-fault drop-receipt-scope
```

The separate `tools/audit/listing-facts-handler-20261004.ts` executes the entire actual Deno handler with a closed Auth/PostgREST transport. `tools/audit/run_listing_facts_cas.py` applies the real migrations in an owned socket-only PostgreSQL cluster, tests fresh/replayed SQL and runs real simultaneous clients. Neither native/handler doubles nor database fixtures certify physical-phone UI, live deployment, camera, provider output or paid purchases.
