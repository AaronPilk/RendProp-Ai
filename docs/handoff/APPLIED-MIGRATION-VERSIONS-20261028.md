# Applied migration versions after Build 131

Build 131's signed release source remains at `ef791167`. Its credit-pack SQL was
applied to production under a later migration-history version. The card-backed
trial SQL was then applied under a later version than its first source filename.
This follow-up only renames the source files and updates references. It does not
change SQL bytes or production history.

| SQL purpose | Original source filename | Production history / canonical source filename | SHA-256 of SQL bytes |
| --- | --- | --- | --- |
| Sandbox credit-pack test authority | `20261028180000_credit_pack_sandbox_test_authority.sql` | `20261028212254_credit_pack_sandbox_test_authority.sql` | `fa511e40ac5da499def68957f9ecf4d5058efb4b746f42ef402771ed4737e70d` |
| Card-backed trial authority | `20261028211732_trial_card_backed_authority.sql` | `20261028213014_trial_card_backed_authority.sql` | `3d5d2b8a77cc08f236bdedc844bf3ee1a587df5157ec9aed95313a2f4e42ea3d` |

Supabase compares migration timestamps with `supabase_migrations.schema_migrations`.
After this source branch is integrated, confirm `supabase migration list` shows
both canonical versions aligned before any future `supabase db push`. A dry run
should show neither SQL file as pending. If either appears pending, stop and
reconcile the history; do not reapply these one-time authority migrations.
The migration regression pins both canonical names and their SQL hashes.
A different database that recorded either original source version needs its own
history reconciliation before using this production-aligned source branch.
