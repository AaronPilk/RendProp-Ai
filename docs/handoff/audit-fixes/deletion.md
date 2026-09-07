# HANDOFF-AUDIT-FIXES — three P0/P1s from the external release audit

Branch `fix/deletion`, worktree off `integrate/1.0.1`. All three live in
`services/supabase/functions/me/index.ts`; two came with a companion fix in
`leads/index.ts` and a new migration. No app (Swift) changes — fix #3 is
server-side only because build 5 is already in App Review.

## New / changed files

| file | what |
|---|---|
| `services/supabase/functions/me/logic.ts` | new — pure decision logic pulled out of `me/index.ts` (`DeletionPayload`, `payloadEmpty`, `dbEmpty`, `chunk`, `decideGhlTagAction`), same split as `apple-subscriptions/logic.ts` / `events/schema.ts` so it can be unit-tested without a live server |
| `services/supabase/functions/me/logic.test.ts` | new — 13 Deno tests for the above |
| `services/supabase/functions/_shared/ghl.ts` | new — `ghlOrgTag(orgId)` / `isGhlOrgTag(tag)`, the ONE place the tenant tag format is defined, imported by both `leads/index.ts` (writer) and `me/index.ts` (reader) so they cannot drift |
| `services/supabase/functions/me/index.ts` | edited — see fixes #1–#3 below |
| `services/supabase/functions/leads/index.ts` | edited — tags a contact via `ghlOrgTag()` instead of a hand-typed template literal (`:83`) |
| `services/supabase/migrations/0026_apple_transaction_binding.sql` | new — closes a concurrency gap in `apply_apple_entitlement()` (fix #3) |
| `services/supabase/functions/README.md`, `services/supabase/DEPLOYMENT.md` | edited — sweeper description now names all six cleanup targets (was four), and the GHL row states the tag policy |

---

## Fix 1 — `cleanup_complete` could be `true` before cleanup was complete (P0-4)

**Where:** `services/supabase/functions/me/index.ts`

- Root cause (pre-fix): `cleanupComplete` was computed and the tombstone
  written to `status: 'completed'` immediately after R2/Stream/CRM/Apple
  cleanup, then TWO MORE destructive steps ran unconditionally afterward —
  nulling `app_events.user_id/org_id` and deleting the `profiles` row — each
  wrapped in `step()`, which only appends to `warnings` on failure. A failure
  in either one never touched `cleanupComplete` or the tombstone, which by
  then already said `completed`.
- Fix: `payload.analytics_user_id` / `payload.profile_id` (`me/index.ts:1382-1383`)
  are collected in Phase 1, alongside R2/Stream/CRM/Apple, and written into the
  tombstone before anything is destroyed (Phase 2, unchanged). Both steps now
  run **inside** `processPayload()` (`me/index.ts:1218-1245`) — the same
  function the sweeper calls — so a failure clears nothing, leaves the field
  set, and shows up in `notes`/`warnings` exactly like an R2 or CRM failure
  does. `cleanupComplete` (`me/index.ts:1469`) is computed from
  `payloadEmpty(remaining)` (`me/logic.ts:66-70`) **after** `processPayload()`
  returns — i.e. after every destructive step, analytics and profile included,
  has actually run — and the tombstone write (`me/index.ts:1470-1476`) uses
  that same value. The old, separately-run "Phase 6b" / "delete profile" code
  is gone; `sweepDeletions()` (`me/index.ts:1520`) reconstructs
  `analytics_user_id`/`profile_id` from the stored payload
  (`me/index.ts:1549-1550`) and retries them through the identical code path.
- Preserved exactly as instructed: enumeration failures still abort before any
  mutation (Phase 0/1 `throw new HttpError(500, …)` calls, unchanged), and an
  auth-user delete failure is still a 500 (`me/index.ts:1484-1492`) —
  `ok` is only ever `false` there. `ok: true` elsewhere means the auth record
  — the account — is gone, which is what Apple's requirement is about;
  `cleanup_complete` is the separate, now-honest signal for background work.
  The response also gained `pending.analytics_cleanup` / `pending.profile_row`
  (`me/index.ts:1509-1510`) so a caller can see exactly what's still queued,
  not just a blended boolean.

**Verified:**
- `me/logic.test.ts` — `"payloadEmpty: false while analytics-forget or the
  profile row is still pending (P0-4)"` and the null/undefined counterpart:
  asserts `payloadEmpty()` reads `false` the instant either field is set and
  `true` once both are cleared, independent of every other field. Run: `deno
  test --allow-env me/logic.test.ts` → 13/13 pass.
- Read-through of the new control flow end to end (`me/index.ts:1298-1514`):
  confirmed `payload.analytics_user_id`/`profile_id` are set unconditionally
  in Phase 1 before the tombstone insert, confirmed `processPayload()` is the
  only place that clears them (on a successful write/delete, not merely on
  "no error thrown"), and confirmed the tombstone status write and the JSON
  response both read `cleanupComplete` computed from the post-`processPayload`
  `remaining`, never from a snapshot taken earlier.
- `deno check me/index.ts me/logic.ts` — clean.

---

## Fix 2 — cross-tenant CRM deletion (account A could delete tenant B's contact)

**Where:** `services/supabase/functions/me/index.ts`, `leads/index.ts`,
new `_shared/ghl.ts`

- Root cause (pre-fix): every tenant shares one `GHL_LOCATION_ID`
  (`leads/index.ts:73`), and `leads/index.ts` already tagged each contact
  `rendprop_org:<org_id>` on write — but the deletion path (a function named
  `deleteGhlContactsByEmail`, since replaced by `cleanupGhlContactForTenant`
  at `me/index.ts:1068-1125`) searched that shared location by email alone and
  deleted every exact match, ignoring tags entirely. Two tenants whose
  leads share an email (a shared vendor, a property manager, a repeat inquirer
  on two different agents' listings) had ONE GHL contact between them; deleting
  account A destroyed tenant B's contact with no record of it happening.
- Fix: `ghlOrgTag(orgId)` (`_shared/ghl.ts:12-14`) is now the ONE place the tag
  format is defined; `leads/index.ts:83` calls it instead of hand-building
  the string, and `me/logic.ts:24` imports the same function, so the writer and
  the reader cannot drift. `decideGhlTagAction(tags, orgId)`
  (`me/logic.ts:100-118`) is the entire policy for what deletion may do to a
  matched contact:
  - only this tenant's org tag present → `"delete"`
  - this tenant's tag **and** another tenant's tag both present → `"untag"`
    (removes only this tenant's tag via `DELETE /contacts/:id/tags`,
    `me/index.ts:1106-1114`; the contact and the other tenant's tag survive)
  - this tenant's tag absent, or the tag list could not be read at all
    (search result lacked it, the follow-up `GET /contacts/:id` failed, or the
    field wasn't an array) → `"leftover"` — **nothing is touched**, ever, on a
    guess. `cleanupGhlContactForTenant()` (`me/index.ts:1068-1125`) always
    re-fetches the full contact by id before deciding, because the search
    endpoint is not guaranteed to return tags on its summary rows.
  - `DeletionPayload.ghl_targets` (`me/logic.ts:27-30`, replacing the old flat
    `ghl_emails: string[]`) pairs every lead email with the org it belongs to,
    collected per-org in Phase 1 (`me/index.ts:1344-1352`) and deduped on
    `(org_id, email)` — not on email alone — so the same email across two of
    *one* user's *own* orgs still gets a cleanup pass for each
    (`me/index.ts:1354-1365`). A `"leftover"` outcome re-queues the target
    (`me/index.ts:1203-1209`) the same way a transport failure does, so it
    keeps showing up in `pending.crm_contacts` and in the tombstone rather than
    being silently dropped — the existing pattern for R2/Stream/Apple
    leftovers that never fully drain.

**Verified:**
- `me/logic.test.ts`, `decideGhlTagAction` block (7 tests): only-this-tag →
  delete; this-tag-plus-another → untag (asserts the OTHER tenant's tag is
  named in the reason, never silently dropped); tag absent → leftover; tags
  `undefined`/`null`/a non-array/`{}` → leftover for every case; non-string
  entries in the tags array are filtered out rather than trusted; an empty
  array is treated as "tag absent", not a crash. Plus a literal golden-value
  test pinning `ghlOrgTag("abc-123") === "rendprop_org:abc-123"` — the exact
  string every contact tagged before this fix already carries, so a future
  format change would be caught here before it orphans production tags from
  both sides at once.
- Read-through confirming `leads/index.ts` (write side, `:83`) and
  `me/logic.ts` (read side, via `_shared/ghl.ts`) import the identical
  function rather than each defining their own copy of the prefix.
- `deno check me/index.ts me/logic.ts leads/index.ts _shared/ghl.ts` — clean.
- **Not verified against a live GoHighLevel account** (no credentials in this
  environment) — the `fetch()` calls to `services.leadconnectorhq.com`
  themselves are untested against the real API; only the decision logic
  (`decideGhlTagAction`) and the control flow around it are exercised. The
  `DELETE /contacts/:id/tags` request shape (JSON body `{tags:[...]}` on a
  DELETE) matches GHL's documented v2 contacts API but should be smoke-tested
  against a sandbox location before this ships.

---

## Fix 3 — unbound StoreKit transactions could be claimed by the wrong account

**Where:** migration `0026_apple_transaction_binding.sql`;
`services/supabase/functions/me/index.ts:669-688` (comment only, no logic
change — see below)

**What was already there, verified rather than duplicated** (as the task
asked): migrations `0019`/`0021` already bind a subscription to whichever org
first links it (`apple_subscriptions.original_transaction_id` is the primary
key) and already refuse a later, different org's claim with a 409 — both
inside the RPC (`apply_apple_entitlement`'s `RP409`, enforced in the row lock)
and as a friendly pre-check at `me/index.ts:815-816` (mapped to the same HTTP
409 by `throwRpc()` at `me/index.ts:855` when the RPC itself raises it).
`invariants.sql:1550-1562`
(`"a subscription bound to one org cannot be claimed by another (RP409)"`)
already covers this — **sequential** — case, and nothing here duplicates it.

**The gap, found by reading 0021 closely and then reproducing it, not
assuming it away:** 0021's guard is `if found and v_existing.org_id is not
null and p_org <> v_existing.org_id then raise RP409`, where `found` comes
from `select … for update` run *before* the insert. `for update` locks rows
that exist; it cannot see a row that hasn't been inserted yet. For a
transaction NOBODY has bound before — exactly the unbound-JWS scenario this
whole fix is about — two overlapping calls both observe `found = false`, both
skip the guard, and both fall into the same
`insert … on conflict (original_transaction_id) do update set org_id =
coalesce(excluded.org_id, s.org_id)`. Whichever call's row lands durably
second resolves as a conflict against the first's now-committed row, and that
`coalesce` order means the **second** call's own `org_id` silently wins — a
successful-looking re-bind, with `org_updated: true` returned to BOTH callers
and no exception raised to either.

**Fix (0024):** the `ON CONFLICT` clause for `org_id` is reordered to
`coalesce(s.org_id, excluded.org_id)` — sticky, preferring what's already
persisted, the same pattern 0021 already uses for `environment` (0021
FINDING 3) — plus a post-write re-check: if the value the upsert actually
produced disagrees with `p_org`, this call now raises the identical `RP409` the
sequential guard raises, which rolls back everything this statement wrote.
Scoped to `org_id` only: every other field the JWS carries
(`product_id`/`environment`/`status`/…) is identical between two calls racing
on the *same* transaction, because those come from the verified JWS, not from
the caller's own session — only `p_org`/`p_user` differ, and `p_user` decides
no entitlement (see the migration's own header for the full reasoning).

**Verified — empirically, on a scratch Postgres 16, not just read through:**
1. Bootstrapped `tests/ci-bootstrap.sql` + replayed every migration
   `0001`…`0023` (pre-fix state) on a fresh local Postgres 16 (`pg_cron`
   installed via apt so `0022` applies exactly as CI's `postgres:16` image
   would). `tests/invariants.sql` → 181/181 pass, confirming a clean baseline.
2. **Reproduced the bug**: a sleep-injected copy of the exact 0021 function
   body, called from two genuinely concurrent `psql` sessions (real OS
   processes, real separate transactions — not simulated) racing to bind a
   brand-new `original_transaction_id` to two different orgs. Both received
   `{"ok": true, "org_updated": true, …}`; the stored `org_id` ended up
   pointing at whichever call committed second; **both** orgs read
   `plan = 'pro'` afterward. This is the exact failure 0021's own header
   describes as FINDING 1 ("BOTH orgs now read plan='pro' from ONE
   subscription") — reproduced again, one layer down, for the case 0021 didn't
   cover.
3. Wrote `0026_apple_transaction_binding.sql`, applied it on top
   (`0001`…`0024` fresh replay) → `tests/invariants.sql` → **181/181 still
   pass** (nothing in the existing sequential-case coverage regressed).
4. **Re-ran the identical concurrent race against the literal function body
   extracted from the committed 0024 file** (not a hand-copied variant — the
   test script parses `apply_apple_entitlement(...)` straight out of the
   migration): the call that commits second now gets a hard
   `RP409: This subscription is already used by another account` and its
   transaction rolls back completely (`last_transaction_id` on the stored row
   is the WINNER's, never the loser's); the org that committed first keeps the
   plan; the other org's plan is untouched. Repeated with the two sessions'
   start order reversed to rule out an ordering artifact rather than a genuine
   "first commit wins" — symmetric both ways.
5. Replayed the CI job's "re-appliable migrations" step (`0005b`, `0008b`,
   `0009`…`0024` a second time on the already-migrated database) →
   **181/181 invariants pass again**, confirming `0024` is idempotent.
- `me/index.ts:669-688` gained a comment explaining the gap 0021 left and
  pointing at 0024 — no logic change there; the existing pre-check
  (`me/index.ts:815-816`) and `throwRpc()` mapping (`me/index.ts:855`, calling
  into `_shared/http.ts`'s `throwRpc`) already turn the RPC's `RP409` into the
  same HTTP 409 the sequential case returns, so nothing needed to change on
  the edge-function side for this fix to take effect.

**Not verified:** no live App Store Server (sandbox or production) JWS was
exchanged — verification is entirely at the database layer, which is where
this specific race lives (the JWS-verification and appAccountToken checks
above it, `me/index.ts:704-790`, are unchanged and were not the focus of this
fix). A `deno test` for this fix would need a live Postgres reachable from
Deno to be meaningful; that infrastructure doesn't exist in this repo today
(`invariants.sql` runs from `psql`, not from Deno), so the empirical
verification above is SQL-level rather than a committed automated test.

---

## Test run summary

```
cd services/supabase/functions
deno check me/index.ts me/logic.ts me/logic.test.ts leads/index.ts _shared/ghl.ts   # clean
deno check <every other function's index.ts>                                        # clean, no regressions
deno test --allow-env --allow-net --allow-read .                                    # 229 passed, 0 failed (216 pre-existing + 13 new)
```

```
# services/supabase (scratch Postgres 16, not the real project)
psql -f tests/ci-bootstrap.sql
for f in migrations/*.sql (sorted); do psql -1 -f "$f"; done      # 0001…0024, clean
psql -f tests/invariants.sql                                       # 181 passed
# + the concurrency reproduction described under Fix 3
```
