# Gallery database verification

The gallery migration passed 16 focused regression groups against the complete ordered migration set on a fresh local PostgreSQL database. No production data, provider requests, or network listener were used.

Run from the repository root:

```sh
node apps/studio/scripts/test-gallery-schema.mjs
```

The script tests the actual `studio_gallery_update` SQL function as the `authenticated` role with synthetic named accounts and memberships. It verifies complete, contiguous ordering; replay after a lost response; rejection of stale order and cover snapshots; additions, removals, and replacement photo IDs between device snapshots; malformed order rejection; canonical enhanced cover selection with exactly one main photo; account, organization, role, and listing scope; and unchanged captions, original keys, enhanced keys, and AI staging flags. The SQL-null expected cover case matches PostgREST's mapping of an explicit JSON null. Refused calls are checked for partial row changes.

These tests model updates made between two device snapshots. They do not claim a simultaneous multi-process concurrency load test or paid AI-provider verification.

Portable receipt: [gallery-schema.json](gallery-schema.json). The complete local SQL assertions and PostgreSQL log are retained beside `/tmp/rendprop-gallery-schema-p4WT9l/receipt.json`. Migration review required no additional edits.
