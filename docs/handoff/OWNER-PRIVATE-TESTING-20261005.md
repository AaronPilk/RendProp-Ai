# Owner testing access and private tester invitations — 2026-10-05

## Intended behavior

The product owner's manually assigned Team workspace has an explicit, revocable internal testing grant. It lifts business seat, monthly feature and monthly COGS allowances for internal testing. Retail Team pricing and allowances are unchanged. Technical provider caps, concurrency, per-job admission and settlement, deletion fences, disabled provider integrations and the spatial experiment budget still apply.

An invitation from a configured internal testing host sponsors the recipient's existing private workspace. It does not put the recipient into the host's content membership. The recipient keeps their own name, cards, listings, media, leads, Apple purchase bindings and stored plan. The selected private workspace receives an effective Team allowance projection while the sponsor and beneficiary remain eligible. Private workspaces retain one seat and cannot relay the sponsorship to another team.

Enrollment selects an existing eligible workspace deterministically, preferring an existing allocation, then a workspace with listings, then the saved selection. It does not create, merge or delete a workspace. The owner roster shows tester identity and access status, without exposing the tester's projects. Removing a tester revokes the allocation and preserves saved work. Invite replay requires the original recipient and a still-active allocation. Accepted legacy shared invite codes are not converted into private receipts.

Configured host privacy mode is sticky: expiry or revocation cannot make subsequent invitations silently grant shared content access. Ordinary customer teams retain their existing shared workspace behavior; the app explicitly describes that mode. This is not a general retail pooled-billing or project-assignment release.

## Schema and server changes

- `20261005195004_workspace_internal_testing_grants.sql`: service-managed master grants; qualified authority predicate; preserved entitlement and seat function attributes/ACLs; strict deployed-body guards.
- `20261005200559_private_internal_testing_sponsorships.sql`: deny-all client tables for host registration and sponsorships; service-only allocation/context/roster/removal RPCs; private invite receipts; guarded additions to the existing entitlement, seat and accept functions.
- `functions/_shared/internal-testing.ts`: validates server context against the verified user and selected workspace. Invalid or unavailable authority fails closed.
- `/me`: reports effective sponsored Team/manual access with the raw source retained separately. A beneficiary cannot manage the host subscription. Mixed revocation/allowance reads fail closed.
- `/team`: returns the recipient's private workspace on join; adds a metadata-only tester roster for managers; revokes private access without deleting projects.

These migrations accept only reviewed existing function bodies and abort atomically on an unknown body. Apply them individually; do not bulk-push pending unrelated beta migrations.

## Native behavior

The app explains private testing access separately from a shared workspace. Private invites use the tester role. Internal testing allowances display as Unlimited rather than the finite compatibility integer. When a live session has no selected authorized workspace, cached houses remain hidden and the user is offered Choose a workspace; saved files are preserved.

The current installed build needs a workspace refresh after removal from a shared team. In Settings → Workspace, select the original private workspace that contains the user's listings. Identical workspace names have an ID suffix in the picker. Do not delete an existing empty workspace merely because a user reports confusing duplicate names.

## Verification and release boundaries

The source-bound native allowance/privacy harness passed 120 assertions and 13 separately compiled fault controls. Both unsigned generic physical iOS Release builds compiled successfully. This does not constitute a TestFlight upload, device camera test or installation.

The complete closed Deno functions suite passed 1,465 tests with zero failures and one ignored test. Actual minimal production-derived `/me` and `/team` bundles separately passed 50 tests, including ordinary anonymous team reads. The master grant runner passed 56 SQL assertions on fresh, replay and standalone paths plus seven compiled fault controls. The private sponsorship runner passed 81 assertions on all three paths plus 14 compiled controls, two concurrent invite commit/rollback cases, real account-deletion/FK cleanup and master revocation versus already admitted accounting. Previously admitted work may finish and settle; a fresh reservation after committed revocation must obey the original caps. No paid writers were changed. Receipts and exact source bindings are recorded outside Git with no real account identifiers.

Production Edge deployments must be derived from the current live bundles with only the reviewed index and new helper changes. Repository `/me` also contains pending beta changes whose schema has not been deployed. Preserve all other deployed file bytes and verify JWT remains enabled. Verify the exact uploaded files by reading the deployed bundle back.

Live account support actions and deployment receipts are private audit artifacts. No real user/org IDs, email addresses, API keys or purchase records belong in migrations or fixture files.

## Production result

Both migrations were applied individually. `/me` version 47 and `/team` version 20 are ACTIVE with JWT verification enabled. All 18 Me and seven Team deployed files read back byte-for-byte equal to the approved minimal bundles. Unauthenticated probes returned 401.

The authorized existing tester was allocated to their original two-listing workspace. The temporary manual-Team bridge was restored to the original expired trial source, so access now depends on the revocable sponsorship. Effective allowances remain Team/unmetered with one private seat; the host counts the owner plus the private tester without granting a host content membership. Stored identity, the two private workspaces and their saved listings were preserved.

Live authenticated RLS probes show zero host listings visible to the tester and zero tester listings visible to the host owner. The tester can read their two own listings and the bound private boolean helper is active. Actual service-role entitlement projection is Team. Direct authenticated calls to the legacy entitlement RPC already fail on the intentionally service-only brokerage table; `/me` uses the existing service-role adapter. No client table privilege was expanded to work around that old limitation.

Retail and industry entitlement rows match the pre-change snapshot exactly. Spatial runtime values and the cost-settlement function digest are unchanged. New allocation tables have RLS enabled with zero client policies; allocation/roster/context mutation RPCs are not executable by authenticated or anonymous clients. The security-advisor response at readback matched its pre-change snapshot; existing warnings remain.

Native source is built and tested but has not been uploaded to TestFlight in this support release. The currently installed app may still need the original private workspace selected under Settings → Workspace after refreshing. Broader beta backend/iOS rollout remains a separate deployment; these minimal Edge bundles do not ship those pending changes.
