# Team private listing libraries — 2026-10-09

## Owner requirement

An invited agent keeps their own account and listings. Only the actual Team
account owner can switch between its explicitly linked agents. Invited agents,
including admin/marketing seat roles, cannot open sibling libraries or manage
the parent subscription. A personal library's owner role, effective Team plan,
private tester sponsorship or global app-admin flag is not this authority.

This permission change is separately authorized from the Home-only visual
refresh. Other screens keep their existing visual design.

## Implementation

`20261009192550_team_private_listing_libraries.sql` adds service-only fresh
library/listing authority and an owner-pinned finite Team relationship. The
agent retains their existing private library rather than receiving another
empty shared content workspace. The directory exposes explicit read/write and
switch capabilities. Exact listing RLS also fences old shared-Team records.

Legacy listings remain in their actual source org with unchanged listing IDs,
media keys and property URLs. Their logical library follows the original agent.
Native and Studio retain this distinction in listing, media, edit and sync
requests. The invited agent sees only their own assigned old records. Removing
a seat revokes owner delegation without moving or deleting the agent's content.

Normal Team feature, serving-cost, storage and render usage is pooled against
the parent subscription. Immutable billing identity stamps keep previously
admitted liabilities on that parent after removal; later work uses the agent's
current private entitlement. Actor-aware resolution is required even for legacy
rows physically stored in an old parent org. Unlimited internal testing keeps
its existing separate funding rules; an actual sponsoring owner may view its
explicitly linked testers under the owner's requested rule.

Account purchase identity is independent of the selected content library.
`workspace_directory.billing_org_id` identifies the account's purchase/Team root;
each row's billing identity is the selected content's serving root. Owner viewing
an agent can still manage the parent's seats/subscription. An agent cannot use
their private-library owner role to manage the parent or read its transaction IDs.

Picker/recovery copy says listing library. Only explicit fresh owner authority
shows Switch agent. Individual accounts and invited agents do not get a switcher.
A rejected cached delegation is cleared; own local files remain preserved.
Join notices and Terms/Privacy explain owner access before joining.

## Verification and publication

Local fresh-schema and exact-replay tests pass 78 Team, 28 workspace and 34
readiness controls, covering sibling RLS, owner delegation,
legacy records, seat removal, usage pooling and immutable liabilities. A compiled
sibling-access defect is caught by the unchanged raw RLS assertion. A real
parent/child last-dollar concurrency test admits exactly one writer, refuses
one with RP402 and records one parent liability. Final source-bound receipts
record counts and inputs; do not substitute static role checks for these tests.

Native final receipt records 989 assertions and 104 negative controls. Studio
has 478 unit tests, typecheck and 13 browser checks, including owner viewing an
agent and an invited agent's restricted management controls. Actual simulator
SDK build and Home appearance tests passed. The full Deno regression passed 1,858 tests with zero failures and one ignored
local-SQL presenter integration case. Focused actor-aware billing controls also
passed. Closed handler fixtures now implement the new RPC contracts while
retaining their recovery, money and negative-control oracles; the original
first-run failures are retained in the private evidence directory.

Private receipts:
`/Users/pilksclaes/LocalRendpropAudits/team-private-libraries-20261009/` and
`/Users/pilksclaes/LocalRendpropAudits/design-refresh-20261009/team-privacy/`.

At this handoff's initial writing these changes are local and have **not** been
applied to production or uploaded to TestFlight. Update this section with actual
CI, migration/function readback and Apple processing receipts when they occur.
Never claim phone/camera/purchase acceptance from the closed test fixtures.

## Deployment compatibility and retained limitations

The migration is transactional and exact-definition pinned. Apply only after
final verification, then deploy the dependent edge functions and matching
Studio/native clients. Older clients with a cached shared-parent selection may
receive RP403 until they update/select their private library. They cannot mint
owner delegation or access sibling listings. After new shared liabilities exist,
keep their billing stamps and strict RLS on rollback; forward-correct rather
than restoring broad shared-member policies.

Old pending invites created by a nonowner admin cannot establish the new
owner-pinned link: the actual Team owner must reissue them. This is intentional.
The legacy Brokerage contract is excluded from automatic paid-Team delegation.

An old explicitly selected public member portfolio stored under a shared Team
org may no longer appear after seat removal. Individual published property URLs
keep their identities. Public portfolio/profile/card ownership was deliberately
not broadened or migrated here: retain fail-closed public selection and treat
legacy portfolio continuity as a separate compatibility follow-up.

Owner cloud sync currently retrieves all authorized libraries with existing
10,000-row/32-MiB bounds and filters the selected library for display. Invited
agents retrieve only their own. A later large-Team pagination improvement must
preserve merge/missing-row semantics and never fabricate content membership.
