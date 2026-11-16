# Aerial media-purpose guard across PostgreSQL 16 and 17 (2026-10-26)

The fresh PostgreSQL 16 CI replay stopped at
`20261023191327_studio_internal_aerial_media_purpose_20261023.sql:191`, in
the `studio_gallery_copy_source` post-replacement guard. The same full audit
passed on local PostgreSQL 17. The migration's prior definition check passed
on both versions, and its replacement `prosrc` MD5 was exactly the pinned
`eca7169c1b82e4e2fa75728d221c9ed5` on both.

An isolated transaction on PostgreSQL 16.15 compared every `pg_proc` metadata
key before and after that exact replacement. Only `proargdefaults` differed:
the stored node tree's source-location offsets changed from `127/159` to
`130/169`. Both trees deparse to `NULL::uuid, NULL::uuid`. The same transaction
on PostgreSQL 17.11 reported no metadata difference. This was a PostgreSQL
version difference in the raw representation of unchanged argument defaults,
not an altered default, body, owner, ACL, or volatility.

The historical migration now compares `pg_get_expr(proargdefaults,0)` before
and after the replacement while retaining the exact prior definition, owner,
ACL, every other `pg_proc` metadata key, and the pinned replacement body MD5.
The focused CI control changes one default to a zero UUID and separately
changes `STABLE` to `VOLATILE` in a disposable copy. Each must trigger the
unchanged guard error; the transaction must leave all three functions exactly
as they were. These two controls passed on both PostgreSQL 16.15 and 17.11.

The connected live Supabase project reports PostgreSQL 17.6. Its stored SQL
for version `20261023191327` has MD5
`fc662e61410e34e68427989d4d2aa7ae`, matching the original repository
file byte-for-byte. The repaired repository file has MD5
`a2f0183a756220766fb037c7fb7e9967` and SHA-256
`5653255c71cfc69474e4b6b8e56c8820802ada536fccc1b2361cc127660ef185`.
This source-only repair does not modify live SQL or the migration's business
behavior; the already deployed live file remains the original version.

At source commit `a341bb54`, the full disposable audits passed on both
PostgreSQL 16.15 and 17.11: 217 reviewed migrations, 211 applied on each
fresh database, 22 exact guarded second-application refusals, 164 double
replays, and 271/271 invariants in the initial and replayed databases. Their
publication and entitlement negative controls passed, and both owned clusters
stopped. Receipts are
`/tmp/rendprop-db-audit-qgvgnwxd/receipt.json` (PG16) and
`/tmp/rendprop-db-audit-tz9btwgr/receipt.json` (PG17). This verifies local
PostgreSQL replay; it does not verify hosted runtime behavior or the six
separately classified historical live-state adoptions.
