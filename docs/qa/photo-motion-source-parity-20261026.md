# Photo Motion predecessor source parity (2026-10-26)

The QA fresh PostgreSQL replay at `0da77da7` first stopped in
`20261022223138_aerial_opening_photo_motion_composition_20261022.sql` because
`public.property_video_photo_motion_saved_identity(text,jsonb)` did not exist.
The aerial migration deliberately pins predecessor bodies by `md5(prosrc)`;
those guards remain unchanged.

| Pre-aerial function | Aerial guard | Original fresh replay | Recovered v2 source |
| --- | --- | --- | --- |
| `property_video_photo_motion_saved_identity(text,jsonb)` | `28867ce20c2e3d208c78083f4a232376` | missing | exact match |
| `property_video_job_admit_photo_motion(uuid,jsonb)` | `208841bb1ad938ce350f523db1287e3b` | `da8de1d27abb427b3894739752a9c780` | exact match |
| `property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)` | `56b0bd247ea9461c5a71ce5a3cab46cf` | `6be253ed10f17272b0b25446095ad2c4` | exact match |

The other eight bodies pinned by that aerial guard already matched in the
original fresh replay. The missing function body is reconstructed exactly from
the next `20261022223142` curated-history migration by removing its final
appended producer-identity clause. Replacing one mutable-identity comparison
in each of the admission and publication bodies gives the other two exact
guard hashes. The recovered function retains `STABLE SECURITY DEFINER`, an
empty search path, `postgres` ownership, and private execute authority.

Read-only comparison against the connected RendProp Supabase project found
versions `20261022003118`, `20261022223052`, `20261022223138`,
`20261022223141`, and `20261022223142` marked applied. For all five, the
stored SQL has the same MD5 as the original repository file. This proves the
recorded migrations alone did not capture the three predecessor bodies that
the aerial migration actually accepted. The live functions have since been
replaced by later migrations, so their current bodies cannot supply the
pre-aerial definitions directly. This source repair deliberately changes the
historical `20261022003118` file; its bytes now differ from that version's
stored SQL on the live project. It does not change an already applied live
database or create a pending migration version.

`python3 tools/audit/test_photo_motion_saved_identity_handoff.py` passed on
disposable PostgreSQL 17: bootstrap, all migrations through `20261022223142`,
exact body and private-authority checks, and three independent negative cases
where the original aerial guard refused a tampered predecessor. A separate
full fresh replay then reached `20261023044520_photo_motion_bfb1_fixed_recovery_controller.sql`
and stopped at its predicate requiring a specific quarantined live aerial job;
that source-only producer adoption cannot run on an empty database without a
dedicated fixture or CI classification.

The fresh-schema replay now classifies six exact, SHA-pinned live-state
adoptions: the bfb1, c74, a1bb, and cf7 Photo Motion controller changes; the
Omni aerial route; and the reviewed Studio kit compare-and-swap. Each stored
live migration has byte-identical SQL to its repository file. The CI and
disposable runners still retain and hash their sources, but apply the other
211 schema migrations in order. Changing or removing any classified file
fails before replay. A disposable negative check verifies that the bfb1 file
still refuses an empty database at its exact historical job predicate. With
the six classified files omitted, all 211 remaining migrations applied. The
invariant suite initially exposed a stale 16-column `media_provenance` count;
the documented `photo_publication jsonb` addition makes 17, which the updated
invariant now verifies by name and type. The accepted-photo publication
migration is also applied once per fresh database: its guarded second
application is deliberately refused and covered by a disposable negative test.
This schema replay does not certify the historical live jobs, producer
configuration transitions, or their resulting live-only function versions.
No live SQL was changed.

The complete historical replay subsequently identified 21 more migrations
whose own second application refuses at its historical schema point. The
exact 22-file one-shot inventory, including accepted-photo publication, now
pins each filename, SHA-256, and first refusal text in
`tools/audit/run_database_regression.py`. All 22 apply once in both fresh
databases and are required to refuse a second application for the recorded
reason. Mutating or removing a classified source file fails the policy test.
The six live-state-only exclusions remain a separate classification.

The complete disposable PostgreSQL 17 audit at source commit `2daa15bc`
accepted all 211 schema migrations on each fresh database, verified all 22
guarded second-application refusals, replayed the other 164 migrations twice
at their historical points, and passed all 271 invariants on both databases.
Its publication and entitlement mutation controls behaved as expected, and
the owned cluster stopped. Evidence is in
`/tmp/rendprop-db-audit-lvh40s5l/receipt.json`. This validates the local
schema replay, not the six historical live-data adoptions or hosted runtime.
