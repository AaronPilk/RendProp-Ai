# Anonymous adoption: durable handoff, not inferred success

2026-09-10 Eastern (verification logs cross September11 UTC). Isolated branch
`fix/anonymous-adoption-recovery-20260911`, based on `2750953`. First bounded
checkpoint toward finding1, not full closure: the deletion/adoption race and
receipt-bound local listing rebind below remain open. Photo trust fields,
live-org resolution and shared web transport also remain open.
No deployment, Apple action, real authentication, customer media or production
mutation. The parent's dirty STATUS.md was not edited.

## Implemented contract

- `Auth/AuthStore.swift:657`: read the active source credentials with an
  error-reporting Keychain read. Before replacing the session, persist a single
  versioned envelope containing source UUID, destination UUID, operation UUID,
  source access token and source refresh token. Keychain read/write failure
  refuses replacement; a conflicting older handoff is never evicted.
- `Auth/AnonymousAdoptionRecovery.swift:71`: retrying the same pre-activation
  handoff retains its operation ID and captures any newly rotated **active
  source** credentials. Tokens stay in the existing ThisDeviceOnly Keychain
  namespace, not defaults/logs/analytics. One pending handoff is supported;
  attempting a conflicting anonymous transfer reports a conflict.
- `AuthStore.swift:243,249,674,786`: launch, foreground and optional sign-in
  retry the persisted handoff. Logout preserves it. Only the matching
  identified destination may submit; the session-generation guard fences late
  completion after logout/account switch. Features/purchases are not gated.
- `AnonymousAdoptionRecovery.swift:116`: single-flight recovery; at most two
  adoption POSTs and one source refresh per invocation. Source refresh never
  installs its token as the active identified session. If rotation returns
  after logout, only the still-matching saved source operation receives its
  new credential; no further adoption or stale success clearing occurs.
- `SettingsView.swift:270`: non-secret recovery status, labeled retry and
  support-email actions. No token, UUID, automatic account switch or destructive
  action. This binding was source-tested, **not visually rendered/tested**.
- `functions/adopt/index.ts:21,179`: verify identities with Auth, then use the
  exact source/destination/operation receipt before testing an expired source
  token. Auth401/403 means credential recovery is needed, not adoption success;
  network/429/5xx and malformed successful Auth responses remain failures.
  Confirmations require the exact binding and a valid org UUID. Request input
  has a16KiB limit; this is not a claim of a whole-process memory ceiling.
- `0038_anonymous_adoption_recovery.sql:18,49`: service-only receipt lookup
  and receipt-writing transaction. Exact receipt replay is read-only. A new
  transfer locks Auth rows (sorted), then profiles (sorted), then the org;
  current `auth.users.is_anonymous` must still be true for the source and false
  for the destination. Ownership is rechecked under lock. A concurrent source
  promotion cannot rely on Edge's stale anonymous-user response. Membership, listing attribution, active
  workspace and immutable receipt commit together. No receipt-less fallback.
  A source can transfer once. Exact replays do not reset workspace selection
  or re-grant removed membership. Source/destination/org/op substitutions fail.
- `0038:110`: the existing three-argument service RPC is a compatibility wrapper
  around the same transaction, preserving source/destination/org checks and
  exact existing receipts. Its deterministic legacy operation uses PostgreSQL's
  built-in SHA256, matching the updated Edge legacy payload path; no extension
  or package was added. Anonymous Auth cleanup is **deferred**, explicitly
  `source_cleanup_pending:true`; no source user or workspace is deleted here.

## Executed evidence

| Tier | Actual result | Evidence |
|---|---|---|
| Unchanged actual Edge handler |2passed/15failed, exit1; desired recovery assertions fail | `/tmp/rendprop-adoption.cZpgwM/route-before.log` |
| Initial AuthStore source contract |3tests fail, exit1 | `/tmp/rendprop-adoption.cZpgwM/source-before.log` |
| Missing Settings recovery contract |3pass/1fail, exit1 before section | `/tmp/rendprop-adoption.cZpgwM/settings-before.log` |
| Final actual Edge handler |30passed/0failed/0ignored, exit0 after formatting | `/tmp/rendprop-adoption.cZpgwM/route-final.log` |
| Actual Foundation recovery helper |59 assertions pass, exit0 | `/tmp/rendprop-adoption-swift.kDiPaZ/swift.log` |
| Deliberate Swift failure |exit1, one failed assertion | Same directory `negative.log` |
| Actual copied Swift guard mutants |4mutants compile successfully, then each fails executable assertions/exit1 | Same directory `mutants.log`; copied sources/logs under the exact path printed there |
| AuthStore/Settings source binding |4tests pass, no skips; not runtime UI | Same directory `source.log` |
| Real local PostgreSQL17.11 |38prior migrations apply; before0038 fails for missing durable receipt;0038 applies/replays | `/tmp/rendprop-adoption-db-ktatggz0/receipt.json` |
| Promoted-source regression before SQL guard |exit3 because the actual old transaction accepted the forbidden transfer | `/tmp/rendprop-adoption.cZpgwM/promotion-before.log` |
| Actual SQL fixture |35assertions pass after apply, after replay and after restored guard, exits0 | Same final DB directory `after.log`, `replayed.log`, `restored.log` |
| Actual removed SQL binding guard |exit3 for accepted forbidden cross-source replay; original restored and re-proved | Same DB directory `reject-receipt-mutant.log` |
| Real concurrent SQL connections |4scenarios, each with observed lock overlap: legacy replay0/0, competing destination0/1 (RP409), committed source promotion0/1 (RP403, no transfer), rolled-back promotion0/0 (legitimate transfer). Winner/receipt/membership counts checked | Same final DB receipt `concurrentCases` and per-case logs; aggregate `/tmp/rendprop-adoption.cZpgwM/database-auth-final.log` |
| Actual AuthStore SDK typecheck |exit0, zero diagnostics for AuthStore, recovery and SessionConnection with inert Config/API types | `/tmp/rendprop-adoption.cZpgwM/auth-sdk-typecheck-final.log`; compile-only, no app link/run |

All local clusters were stopped and retained. Final DB receipt says
`accepted:true, clusterStopped:true` and hashes the migration/test sources.
Earlier concurrency run `/tmp/rendprop-adoption-db-ii31ahk7` correctly rejected
the competing destination, but the harness wrongly expected `psql -c` exit3
(the `-f` convention). It actually exits1. That run remained red; the exact
expectation was corrected and both actual races rerun. No product guard was
weakened. The first promotion attempts failed before reaching that assertion
(missing locale at startup, then retained race-fixture rows affecting an
over-broad count); neither is claimed as the before-fix proof. The final
`promotion-before.log` reaches and rejects the accepted forbidden operation.
Earlier25/32/33-assertion fixture runs are superseded by35, not additive.

Exact commands from the isolated worktree:

```sh
deno test --cached-only --no-config --no-lock --node-modules-dir=none \
  --allow-env --allow-read --deny-net --deny-run --deny-write \
  services/supabase/functions/adopt/adopt.test.ts
bash tests/phase1/run-adoption.sh
PYTHONDONTWRITEBYTECODE=1 python3 tools/audit/run_adoption_regression.py
```

The first attempted Deno command used `--node-modules-dir=manual`, which could
not find a local npm tree and did not execute tests. Switching to `none` reused
the existing Deno cache with network denied; nothing was installed. The new
route tests are discovered by the existing edge-regression file inventory.
The dedicated Swift/SQL commands are not newly wired into CI in this unit.

The DB runner accepts no URL/credentials, creates its own Unix-socket-only
cluster under `/tmp/rendprop-adoption-db-*`, checks PGDATA/name/listeners before
fixtures, and has a1GiB free-space guard. It uses the already installed explicit
`/opt/homebrew/opt/postgresql@17/bin` binaries. This dedicated gate does **not**
rerun or change the known197/198 headroom invariant and does not certify0037.

## Limits and release ordering

- **Deletion/adoption race remains open in this checkpoint.** The unchanged
  `functions/me/index.ts:1385–1444` snapshots ownership and artifact targets
  before inserting its deletion intent, then purges from that earlier snapshot.
  A source deletion can enumerate, adoption can transfer, and stale deletion
  can then remove the destination's adopted org/media. Another simple adoption
  existence check cannot close this gap. A separately assigned0039 unit must
  bind deletion intent, current ownership and cleanup snapshot transactionally
  under the same Auth→profile→org lock protocol. No `/me` edits are included.
- **Local listing links are not rebound yet.** The unchanged
  `RendpropApp.swift:86–118` clears local server/share identifiers on account
  change, including anonymous→identified adoption. This checkpoint's receipt
  success does not restore them; the next publish can create another listing
  instead of editing the adopted one. Server originals and local media remain,
  but useful linkage is lost. The next authorized unit must persist a
  source/operation/destination-bound local identity snapshot before replacement
  and rebind only after that exact receipt; arbitrary account switches must
  continue to clear stale references. Finding1 is not closed by retained tokens.
- No GoTrue/PostgREST service was started. Route identity responses, client
  transport and Keychain storage are synthetic injected dependencies. Actual
  Swift logic and PostgreSQL transactions were executed, but not real JWT
  validation, Apple exchange, iOS Keychain lock/unlock or process termination.
- The refreshed-source response can be lost before its rotated credential is
  stored. Provider refresh reuse/revocation policy and crash behavior still
  require a disposable Auth integration/device test. We preserve the handoff
  and distinguish failure; we do not promise recovery from permanently revoked
  or expired credentials without an already committed receipt.
- A phone whose old app already discarded its anonymous credentials cannot
  be retroactively recovered by this patch. Existing receipts are created only
  by the new transaction; no historical transfer is invented from expiry.
- Old clients still lack the durable local envelope. The compatibility wrapper
  prevents a receipt-less RPC path, but does not repair an old client's crash
  storage behavior. Old Edge code retains its old preflight/deletion behavior
  until that code is replaced; don't claim migration alone removes those calls.
- Deploy migration0038 before the new Edge handler; the compatibility wrapper
  keeps old three-argument callers working during the transition. Drain/replace
  old handlers before claiming the no-deletion behavior. Build the new iOS
  source with XcodeGen so the new Auth Swift file is in the app target. No such
  deployment, app build, UI run or Apple upload happened in this unit.
- Optional sign-in may be refused if the recovery envelope cannot be saved or
  belongs to another unfinished transfer. This protects the existing anonymous
  session; recording/editing/rendering/purchases still require no registration.
- Physical Keychain persistence, app relaunch, simultaneous real authenticated
  HTTP calls and visible Settings/accessibility remain release gates. The new
  Settings section follows existing Form/Label/type styles; source assertions
  are not proof of layout, VoiceOver or Dynamic Type.

Primary references checked September10: [Supabase changelog](https://supabase.com/changelog),
[anonymous identity/conflict semantics](https://supabase.com/docs/guides/auth/auth-anonymous),
[session refresh rotation](https://supabase.com/docs/guides/auth/sessions),
[verified user lookup](https://supabase.com/docs/reference/javascript/auth-getuser),
[Auth error codes](https://supabase.com/docs/guides/auth/debugging/error-codes),
[PostgreSQL binary SHA256/byte functions](https://www.postgresql.org/docs/17/functions-binarystring.html).
Supabase/Postgres skills informed RLS/revokes, error classification, short
transactions and consistent locking. Installed Supabase CLI scaffolded the
migration, then it was renamed to the explicitly reserved repo0038 slot; no
CLI upgrade or live advisor/schema command was run.
