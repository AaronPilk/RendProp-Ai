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
the six classified files omitted, all 211 remaining migrations applied and
the invariant suite reached a separate failing `media_provenance` assertion.
This schema replay does not certify the historical live jobs, producer
configuration transitions, or their resulting live-only function versions.
No live SQL was changed.
