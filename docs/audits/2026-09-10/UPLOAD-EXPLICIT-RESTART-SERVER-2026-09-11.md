# Explicit upload restart — server unit, 2026-09-11

## Scope and actual result

Implemented on `fix/upload-restart-server-20260911`, based on integration
`71f9eb77d866554d9902610f519ef0092cc019d4`. This is local source plus isolated
tests, **not a deployment or a live-upload proof**. No customer data, GPU,
production RPC, cloud cleanup, Apple submission, or credential change occurred.
No gateway dispatch behavior was weakened.

The Supabase migration/RPC guidance shaped the service-only transactional
implementation; the Worker guidance kept the existing one-dispatch stream
authority intact. The migration was CLI-scaffolded with
`supabase migration new upload_explicit_restart --workdir services`, then
numbered `0042` according to the reserved repository sequence.

## Failure addressed

The v2 gateway irrevocably charges an operation at its first dispatch. A lost
or interrupted PUT can leave `dispatching`, `uncertain`, or `rejected` with no
durable stored receipt. Blindly sending the same capability again cannot make
that operation writable a second time. A reservation also expires after 48
hours. Previously `/renew` could only return a usable ticket or a generic
error; the phone had no durable server-linked replacement action.

Relevant existing mechanisms remain unchanged:

- `0037_upload_transport_budget.sql:220` claims once, moving held bytes to
  spent; line241 records the 15-minute write deadline.
- `0037_upload_transport_budget.sql:277` only acknowledges a read-only storage
  observation; it does not authorize another write.
- `0037_upload_transport_budget.sql:308` serializes completion/cancellation;
  lines350–356 release **held only** and queue cleanup after the last known
  write deadline plus one hour.
- `uploads/transport.ts:98` can still recover an exact existing R2 receipt
  without retransmitting. `/complete` can still recover its recorded copy.

## Wire contract

All routes require the normal user authentication, visible listing, write role,
and account-not-deleting checks. SQL independently rechecks current workspace
and actor authorization. Marketing and another tenant cannot use these RPCs or
obtain a replacement through the HTTP handler.

### `POST /uploads/:asset_id/renew`

Existing completed tickets return their original completion receipt. Pending
v2 tickets now use `upload_restart_state`. The usual `UploadTicket` has these
additive fields:

```json
{
  "restart_required": true,
  "restart_reason": "expired",
  "restart_generation": 0
}
```

Reasons are exactly `expired`, `interrupted`, or `cancelled`. Such a receipt
contains the original asset identity/type/mode but **no `put_url`**. A generic
RPC/config/network error remains an error, never implied user consent.

A currently dispatched operation whose write deadline has not elapsed returns:

```json
{
  "restart_required": false,
  "restart_reason": null,
  "restart_generation": 0,
  "retry_after_seconds": 450
}
```

That receipt also has **no transfer URL**. The phone should show “Confirming
previous upload” and wait/recheck, not call the receipt malformed, restart
automatically, or cancel a healthy dispatched transfer. The optional delay is
an integer in 1…900 seconds. Another completion may finish earlier.

Implementation: `uploads/index.ts:328`, `uploads/index.ts:665`,
`0042_upload_explicit_restart.sql:24`.

### `POST /uploads/:asset_id/restart`

Header: a durable UUID `Idempotency-Key` for this explicitly approved action.
The exact JSON body is:

```json
{"confirm_new_attempt": true}
```

No other body fields are accepted. The phone cannot choose a replacement key,
role, size, content type, org, or actor. The immutable stored reservation spec
is cloned by SQL into a new asset/key under the same listing.

Possible outcomes:

1. Original completion won: original `uploaded:true` receipt, no new charge.
2. No previous replacement: atomically cancel the old reservation, reserve its
   one child under the existing daily budget, persist the link, return child.
3. Original request replay, even with a different UUID: return that **same
   direct child**, even if it is now expired, cancelled, busy, or completed.
4. Ticket is still usable: HTTP409 `error=upload_restart_not_required`.
5. Already at generation 3: HTTP409 `error=upload_restart_exhausted` and no
   changes to ticket count, bytes, parent state, or asset count.
6. Budget/capacity denial: HTTP429; the original cancellation rolls back in the
   same transaction. There is no half-cancelled, unlinked replacement window.

The three-restart limit means **four total upload attempts**, including the
original. It is a recovery guard, not a subscription entitlement or a global
per-file deduplication guarantee. Existing original-ticket admission remains
available under the unchanged org/day caps; the client must not silently escape
the chain limit by making a fresh `/uploads` call.

The client must persist the returned child before classifying its state.
An expired direct child needs a **new explicit action targeting that child**;
replaying its parent's HTTP request never silently advances to a grandchild.
Keep local media throughout failure, exhaustion, and uncertain responses.

Implementation: `uploads/index.ts:340`, `0042_upload_explicit_restart.sql:57`.

## Transaction and storage reasoning

- `upload_restart_state` takes the existing listing → asset → reservation locks.
  `restart_upload_asset` retains them through completion check, direct-child
  replay, cancellation, budget admission and parent linkage.
- The lock is shared with `settle_upload_reservation`. A completion committed
  first returns the original winner. If restart wins, later original
  publication fails, including a late old copy receipt.
- Parent link is durable in `upload_reservations`; it does not depend on the
  existing partial pending-asset idempotency index, which excludes completed
  and aborted assets. One parent admits one child across competing UUIDs.
- New UUID storage identity prevents an uncertain old writer from overwriting
  its child. The old operation remains charged and queued. “Interrupted” does
  **not** assert that the provider stopped, that no bytes arrived, or that
  cleanup has already run.
- Only unspent held bytes are released. A single 4-byte attempt interrupted
  after first dispatch leaves 4 spent; its child reserves 8 more for its own
  upload+copy. Expected balance is tickets 2 / held 8 / spent 4, not spent 0.
- Existing limits remain 2,000 tickets and 200 GiB physical-byte held+spent per
  org/UTC day. Old/new day budget rows are locked in sorted order to avoid a
  midnight lock-order inversion. Old reservation balance is settled in its
  original day; child admission is in the current day.
- There are no new cascading cleanup FKs. Actual 0039 snapshots all old and
  child reservation/operation keys before retiring rows. Actual 0040 rejects
  cancelled or uncompleted tickets; only the completed private child can attach
  to a spatial capture. An already-attached completed parent is not restartable
  into a different input, because its completion receipt wins.

## Verification actually completed

All tests below use synthetic fixture identities/content only.

| Command | Actual result | Receipt |
|---|---|---|
| `python3 tools/audit/test_upload_restart_db.py` | **40 passed**, zero skips, two deliberate SQL mutations each caused an assertion failure; both restored cases passed; owned cluster stopped | `/tmp/rendprop-upload-pg-9a_hvtkj/receipt.json` |
| `python3 tools/audit/verify_upload_restart.py` | **122 passed**, zero skips; two copied actual-handler mutations rejected by assertions; 15 restored tests passed | `/tmp/rendprop-upload-restart-p7rnum7x/receipt.json` |
| `python3 tools/audit/verify_upload_transport.py --tsc <existing integration tour-host TypeScript>/bin/tsc --deno-dir /Users/pilksclaes/Library/Caches/deno` | **122 passed**, native Worker adapter typecheck passed; deliberate final-byte stream defect exited 1 | `/tmp/rendprop-upload-offline-9yew9uac/receipt.json` |
| `deno check --deny-import services/supabase/functions/uploads/index.ts` | Exit 0, actual handler typechecked | terminal result |
| `git diff --check` and `python3 -m py_compile tools/audit/test_upload_restart_db.py tools/audit/verify_upload_restart.py` | Exit 0 | terminal result |

The 40 SQL cases include 20 existing transport cases plus 20 new recovery cases.
They apply the actual repository migration sequence including 0039/0040/0041/
0042 to an independently initialized PG17 server with `listen_addresses=''`,
verify its exact temporary data-directory identity, and accept no existing DB
URL. Two races explicitly observe waiters blocked on real PostgreSQL locks
before release: competing restart UUIDs and completion winning before restart.
Other cases cover daily admission rollback, midnight accounting, immutable
photo/multipart spec, late old copy, original/direct-child completion replay,
four-attempt exhaustion, role/cross-tenant/deletion denial, migration replay,
actual deletion payload contents, and actual spatial attachment.

The 122 Deno tests execute the real handler/transport code, but substitute
PostgREST and R2 fixture responses; they are **not live service or real-SQL
end-to-end tests**. PostgreSQL assertions above independently execute the real
RPCs. Tests are registered in `uploads/transport_route.test.ts`, not isolated
from the existing functions CI suite. The exact-count transport gate now
expects 122 rather than 100.

Earlier failed checks are not counted as green:

- First SQL run passed 36 cases, then correctly failed its negative-control
  gate because the mutant caused an unexpected RPC error rather than the
  intended assertion category. Receipt `/tmp/rendprop-upload-pg-k2t9p6ys/` has
  `accepted:false`. The RPC-response assertion was corrected, then all gates
  rerun on the final source.
- `deno check --cached-only ...` was rejected by this installed CLI (exit 1).
  Its supported `--deny-import` check was then run and passed. No dependency
  install or remote fallback was used.

## Integration / rollout requirements

1. Integrate this commit with the paired iOS recovery unit; this backend commit
   does not implement the phone journal/consent UI. The phone must handle busy
   no-capability receipts, generation 3 exhaustion, direct-child persistence and
   explicit spatial input-ticket rebinding before any transfer or attach.
2. Deploy in this order: **additive migration 0042 → the matching uploads
   handler supporting renew/restart → the paired iOS client**. A missing RPC
   yields 503, never an alternate direct-PUT path. Replay of 0042 was tested and
   preserves links/spend. This does not rewrite deployed 0037.
3. Confirm the deployment is the canonical v2 gateway transport. Nothing here
   proves a currently deployed rollback/direct-presigned handler supports this
   contract, or that live gateway origins/secrets are configured.
4. Pair the existing 0039 deletion-intent migration with its matching `me`
   handler before enabling broader ingestion. Full spatial dependencies0040/
   0041 must also match their deployed code. The new restart fields do not add
   a separate cleanup table, but do not magically deploy the missing cleanup
   integration either.
5. Confirm upload cleanup scheduling and R2 lifecycle backstops. This unit
   does not run cleanup, verify live lifecycle rules, or promise object removal
   before the provider deadline/drain. No automatic refunds or second writes.
6. Run combined iOS background/relaunch/account-change and spatial upload tests
   on the integrated commit before a separately authorized internal TestFlight
   build. No App Review change is part of this work.

## Explicit remaining limitations

- This is safe **explicit restart**, not automatic recovery of every ambiguous
  write. An uncertain provider write might actually exist without a durable
  receipt. Existing read-only recovery remains available in the transport, but
  this new metadata route does not scan all ambiguous R2 operations first.
  Completion should be probed before requesting restart. If a fresh attempt is
  approved, its additional physical bytes remain budgeted even if the old write
  later appears. No claim of zero duplicate physical cost.
- A still-dispatching attempt can need up to 15 minutes before the server can
  offer restart. The receipt makes that wait explicit rather than granting a
  premature second dispatch. A bounded automatic periodic client recheck is a
  UI responsibility; this unit does not create a scheduler.
- Adjacent adoption limitation, **unchanged here**: 0038 can replace membership
  identity while an old upload reservation keeps its original `actor_id`.
  `0037_upload_transport_budget.sql:234` rejects dispatch once that original
  actor lacks write membership; 0042:30–44 validates the *current* actor but does
  not classify stale original authority as `interrupted`. An otherwise planned
  ticket can still look healthy until explicitly aborted/expired. Do not claim
  transparent adoption recovery is closed by this unit.
- Legacy v1 tickets use the separate explicit rollout recovery; this endpoint
  deliberately does not invent physical-byte history for them.
- No actual live background upload, camera capture, GPU training, customer
  account deletion, or TestFlight upload was exercised by this isolated unit.
