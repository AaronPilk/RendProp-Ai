# Rendprop — lane C tenancy/session handoff

2026-09-10. Source: `/Users/pilksclaes/Rendprop AI/spatial-testflight-20260910`, clean **f14081d49d5fb40b1dde59562176692ddb2664c6**, `integration/web-editor-foundation-20260910`. Paths/lines below are relative to that root. Full supporting detail: `/tmp/rendprop-web-tenancy-v728Lh/FINDINGS.md`.

## Decision

Reuse the existing Supabase identity, Edge API and team transaction model. **Do not certify E11 or browser tenancy end-to-end yet.** The owner-facing web transport does not exist; legacy writable ownership/provenance fields need a DB-boundary decision before browser UI consumes them as trusted data.

Read completely before work: new attachment, standing brief, all five market research docs, Supabase skill. No source/backend mutations, installs, DB startup, provider requests, Apple calls or customer-row queries. Only temporary reports were written. The original resource constraint was ~500 MiB free; root subsequently reported 4.9 GiB. I still did not start a database.

## Actual verification, not intentions

- **16 existing tests passed, 0 failed:** HTTP bounds 6; invite-code helpers 10. Command below exited 0.
- **6 actual-production-body mocked observations reproduced:** upstream 401/429/503/malformed-200 all become absent anonymous user (4); explicit deleted-org membership and null-RPC fallback both resolve deleted org (2). Injected dependencies; zero outgoing HTTP calls. The org helper's final TS `as string` annotation was removed only for Node execution.
- **Negative desired-contract check exited 1:** `assert.rejects` against the actual `userForToken` body given HTTP 503 failed with `Missing expected rejection`.
- **80 programmatic snapshot assertions passed** over read-only live catalog results: 16 table records, 8 function signatures, 11 column records. Counts include three cardinality assertions and checks confirming the risky grants below; this is **not 80 security scenarios passed**.
- **0 low-privilege JWT HTTP tests; 0 DB mutation tests; 0 transaction-concurrency tests; 0 browser-auth tests.** No green claim for these tiers.

```sh
# From services/supabase/functions
deno test --cached-only --no-config --no-lock --deny-net --deny-env --deny-read --deny-write --deny-run --no-prompt _shared/http.test.ts team/codes.test.ts
# ok | 16 passed | 0 failed (41ms)
```

## Reuse these pieces

- `apps/ios/Rendprop/Auth/AuthStore.swift:29`: anonymous session is a valid product session; `:48` generation guard; `:104` Keychain storage; `:310` local cancellation/sign-out; `:412` single-flight refresh; `:426` refresh-token rotation; `:705` anonymous signup. Browser should reuse the Supabase protocol, not create another identity service. Swift is a behavioral reference, not an importable JS transport.
- `Networking/LiveAPIClient.swift:103`: request/body construction; `:119` idempotency; `:185–207` proactive refresh plus one same-request 401 retry. Preserve body/key on retry. `Auth/SessionConnection.swift:1` and `tests/phase1/` provide offline cancellation/bootstrap fixture patterns.
- `services/supabase/functions/_shared/supabase.ts:39`: per-request caller client; `:67` bearer verified by Auth; `:84` workspace resolver; `:159` deletion gate. `_shared/cors.ts:6–11` already allows bearer/apikey/idempotency/x-org-id headers. No browser cookie/BFF or SSR session design is implemented by those headers.
- `migrations/0033_team_transactions.sql:89` invite accept; `:170` invite create; `:230` anonymous adoption; `:63` active org. Preserve retained personal workspaces. Call these through existing Edge handlers, **never directly with browser service credentials**.
- `apps/web/player/README.md:3,13` explicitly identifies the old web directory as archived/localStorage-stubbed. Canonical public player is `services/edge/tour-host/src/player.ts`; there is no owner web auth implementation to reuse literally.

## Ranked findings and concrete reproductions

### 1. P1 — failed anonymous adoption loses recovery path

`AuthStore.swift:619–629` captures only the old access token locally and overwrites persisted credentials with the identified session before `/adopt`; `:741–761` only logs failure. Next sign-in no longer has an anonymous stored token (`:733–735`), despite the retry comment. No durable pending handoff/anonymous refresh capability exists here.

Reproduce in isolated transport fixtures: anonymous session + synthetic listing → identified token exchange succeeds → `/adopt` fails/drops → restart. Old workspace remains, new account lacks access, old retry credentials are unavailable through this flow. Server `adopt/index.ts:69–77` collapses outages/invalid JSON into null and `:92–96` reports `ok:true, adopted:false`; expired token is not proof of completed adoption. Actual-body mocked cases confirmed the classification.

**Implement:** durable source/destination-bound pending handoff before replacement; transaction receipt/replay; recoverable credential lifecycle; explicit upstream-error versus expired-token handling. Do not log credentials or gate product features on identification.

### 2. P1 — workspace selection/liveness is inconsistent

`_shared/supabase.ts:86–95` verifies explicit membership without live-org check; `:105–117` falls back even when liveness-aware `active_org_for_user` returns null (`0033:69–81`). Two mocked production-body cases confirmed a deleted org is returned. This does not give a non-member arbitrary org access.

`listings/index.ts:157–166` ignores `X-Org-Id` when listing; `:175–188` edits any member-visible listing without matching the selected header. A dual-org member selecting B still gets A+B rows and can edit A. RLS allows their legitimate memberships; selected-workspace behavior is a separate, currently inconsistent contract. `LiveAPIClient.swift:103–135` and `TeamAPI.swift:126–160` do not send org selection. No explicit client workspace-switch contract was found.

**Implement:** fail-closed live-org resolver, explicit all-workspaces versus selected-workspace API semantics, consistent header/listing matching, user+org cache keys, non-destructive switching.

### 3. P1 gate before trusting browser ownership/provenance fields — direct Data API bypasses validation

Live grants confirm `photos` allows authenticated table-wide I/U/D. Role policies admit owner/admin/agent (`0007_p0_lockdown.sql:55–60`); `listing_id`, `original_key`, `enhanced_key`, `is_staged` are writable (`0001_init.sql:94–103`). Agent fixture can directly PATCH these without the media pipeline, including moving between listings they may edit. Marketing is rejected by RLS. Omitted explicit UPDATE WITH CHECK is **not** itself a bypass: PostgreSQL reuses USING where applicable.

`listings.main_photo_key` is client-writable (`0008b:15–19`) but prefix ownership validation is Edge-only (`listings/index.ts:123–130`). `agent_id` cannot UPDATE, but can INSERT and references any profile (`0001:39–42`), bypassing handler attribution (`listings/index.ts:150`). Test direct low-JWT PATCH/INSERT with exact affected-row/state assertions; not run live.

Current public disclosures use immutable `media_provenance` (`tours/index.ts:78–98`), not `photos.is_staged`; gallery uses verified capture assets (`:122–140`). **No claim that flipping the legacy flag currently strips the public disclosure.** Narrow/retire mutable trust fields or enforce their ownership at DB write boundaries before the browser depends on them.

### 4. P2 — TeamAPI diverges from common retry/recovery

`TeamAPI.swift:126–160` gets a token once, directly sends, and throws on 401; no forced refresh/retry unlike LiveAPIClient. It also lacks invite operation idempotency; lost successful response can leave a reserved seat/code unavailable to the sender (`:183–191`, `team/index.ts:277–280`). Test fresh-looking token→401→refresh success, and commit→response-drop→retry. Consolidate authorized transport semantics and define recoverable invitation retry; do not create a third divergent browser transport.

### 5. E11 incomplete — mutation-time authority and governance

Create/accept have under-lock role/seat checks (`0033:102–153,180–205`). Revoke/remove use service writes after an earlier role lookup (`team/index.ts:173–185,283–315`). Pause admin request after `requireManager`, remove admin, resume: stale request can still mutate. Define and test mutation-time authorization; this is not a demonstrated seat-overcapacity exploit.

Assets remain with org (`team/index.ts:316–318`); old invite replay checks membership (`0033:124–129`). New requests consult live memberships, but member removal does **not** revoke the user's global Auth session. Define org-scoped revocation versus unrelated personal workspace access, delegated tokens, in-flight requests and presigned URL lifetime. Revision approvals, delegated listing access, transfer policy and branch precedence are proposals (`ENGINEERING-BACKLOG.md:214–220`), not implemented governance. Team UI still falsely says joining requires an empty personal workspace (`TeamView.swift:232,439`; compare `0033:86–88`).

## Proven controls and remaining proof gap

Read-only metadata: all 16 selected tables RLS-enabled; seven server-owned product/cost tables deny authenticated I/U/D; six internal tenancy RPCs deny anon/authenticated execution and allow service only. Profile admin/token INSERT/UPDATE denied (`0017_admin_role.sql:69–70`). Org admin differs from product-wide admin. Some anon SELECT grants exist but membership policies constrain rows; grants alone are not a leak. Org INSERT/DELETE grants have no matching RLS policies, so are not usable merely because granted.

CI exists (`.github/workflows/ci.yml:101–178`), but 1,865-line `tests/invariants.sql` has no 0033/team RPC assertions. Its auth bootstrap is not GoTrue/PostgREST (`ci-bootstrap.sql:43–55`); PG16 CI is not live PG17 parity. Invariant fixtures contain destructive cleanup (`invariants.sql:1848`) and must never run against production.

## Implementation/test order

1. Agree role matrix and selected-workspace contract; fix adoption recovery and DB trust-field grants/constraints before browser forms.
2. Build one typed browser transport over existing Edge routes/Supabase identity; preserve anonymous access, refresh single-flight, stable retry keys, user/org cache separation and optional identity-linking conflict rules.
3. Once resources/authority permit, create an explicitly owned fresh loopback-only fixture database with run-ID sentinel and verified PGDATA. Reject arbitrary DATABASE_URL/live credentials; no production fallback. Installed deno/psql/postgres/supabase were located, but no stack started here.
4. SQL role tier: reuse bootstrap/migrations only locally; assert current role/claims/RLS, positive fixtures and exact denied mutation outcomes. Concurrent tests require separate connections, not sequential SQL blocks.
5. Real JWT tier needs disposable local Auth+PostgREST, not admin catalog queries. Actors: A owner/admin/agent/marketing, unrelated B member, dual-member, removed member, anonymous-auth user, unauthenticated caller. Test every protected table, sensitive column/RPC, workspace mismatch, all upload ticket/part/complete/abort paths including `role:"render"`.
6. Exercise one-code/two-users, last-seat concurrent invites, revoke/accept race, removed replay, adoption restart/outage, retained personal assets, two-tab token refresh, stale account responses. Weaken one policy/check **only in a separate disposable fixture** and require non-zero negative-control exit. Require exact counts, zero unexpected skips and source/version receipts.

Current official docs checked: [Anonymous Sign-Ins](https://supabase.com/docs/guides/auth/auth-anonymous), [Sessions](https://supabase.com/docs/guides/auth/sessions), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security), [API security](https://supabase.com/docs/guides/api/securing-your-api), [Changelog](https://supabase.com/changelog). Anonymous Auth uses authenticated DB role; browser storage loss, dynamic SSR isolation, refresh rotation and delayed JWT revocation require explicit tests. Deployed code parity, Auth/CAPTCHA/redirect/session settings, secrets and storage lifecycle remain manual gates—not verified defects or completed tests.
