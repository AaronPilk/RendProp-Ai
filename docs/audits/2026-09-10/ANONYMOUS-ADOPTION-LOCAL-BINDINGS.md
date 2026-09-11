# Anonymous adoption: receipt-bound local listing links

2026-09-10 Eastern / September11 UTC. Unit branch
`fix/adoption-local-bindings-20260911`, based on reviewed recovery checkpoint
`16a04ce`. This addresses that checkpoint's local-link gap; it does not replace
its server receipt/credential work or close the separately assigned `/me`
deletion-snapshot race. No deployment, Apple call, production account, user
media, migration or provider operation was used.

## Demonstrated defect

The unchanged AppModel account-change callback queued `forgetServerIdentities`.
That cleared each local listing's `serverID`, share links and published-render
ID. A successful adoption receipt did not restore them. The next call to
`ensureServerListing` therefore created another cloud listing.

Before editing production source, the actual old `forgetServerIdentities` and
`ensureServerListing` bodies were mechanically extracted and compiled with the
actual Listing/Money types, plus inert transport and file-path dependencies.
The synthetic published listing then made **one create call**, failing the
expected original-ID/no-create contract with **exit1**:
`/tmp/rendprop-adoption-local.rOvm4J/before.log`. Compilation succeeded;
`Before.swift` and `before.mjs` in that directory preserve exact construction.
This is a model-method reproduction, not an iOS screen or real server test.

## Implemented boundary

- `Auth/AdoptionLocalBindings.swift:6`: versioned, non-secret metadata journal,
  bound to source UUID, destination UUID and operation UUID. It records only
  existing non-sample local/server listing IDs and their actual share/render
  identifiers. It copies no media, credentials or editable listing text.
- `RendpropApp.swift:138`: optional sign-in persists that journal in the **same
  atomic state file** as the existing library, after the source Keychain
  envelope is durable and before active-session replacement. Missing/unloaded
  state, failed writes, conflicting pending bindings and in-flight source
  listing-create/publish/sync work refuse this handoff. No library truncation.
- `RendpropApp.swift:113`: account-change clearing is synchronous metadata work,
  not a queued Task that could erase a later rebind. The persisted identity
  owner also lets actual `load()` clear a prior account's references after a
  crash interrupted an account-change save. No media is loaded or removed by
  this callback; ordinary snapshot encoding remains synchronous as before.
- `RendpropApp.swift:157`: only the exact current-destination receipt can merge
  original identifiers into surviving local listings. Editable fields stay
  current and become dirty for a later PATCH. Deleted local listings are not
  resurrected. A conflicting new server ID is not overwritten. IDs and the
  applied confirmation marker commit atomically; a failed save restores the
  previous in-memory state and leaves Keychain recovery intact.
- `AnonymousAdoptionRecovery.swift`: the missing-hook defaults fail closed.
  Receipt acceptance invokes the local atomic-rebind hook **before** removing
  the source envelope. Existing session-generation checks fence callbacks after
  logout/switch. Launch waits for AppModel to load, then retries recovery before
  background listing sync/publish.
- `RendpropApp.swift:484`: a specific pending adopted listing refuses duplicate
  cloud creation with a Settings recovery action in its error text. Unrelated
  new listings and the still-active source remain usable. Creation is fenced
  against double-submit and a reply for a different current user.
- Failed Keychain removal after rebind remains retryable. A subsequent switch
  preserves the latest links for those same receipt-bound IDs; a matching
  receipt can reapply them on return. An already cleared, confirmed transfer
  does **not** hold unrelated future account switches hostage. Keychain read
  errors are not treated as an absent pending transfer.
- `PersistentStore` (inside `RendpropApp.swift`, not the empty Support shim):
  save now returns success/failure. Missing new fields are legacy-compatible.
  A present malformed journal salvages readable listings, exposes a non-secret
  recovery error and refuses to overwrite the original state bytes. That is a
  storage-recovery condition, not a silently empty successful library.

The journal cap is **1MiB of encoded metadata**. It refuses optional handoff
rather than truncating identifiers; it is not a cap on capture, listing count,
media, or total process memory. Duplicate local or server IDs are refused. The
atomic file write covers metadata, not arbitrary disk hardware failure.

## Executed verification

Exact gate, from this isolated worktree:

```sh
bash tests/phase1/run-adoption.sh
```

Final exit0 aggregate:
`/tmp/rendprop-adoption-local.rOvm4J/final-gate.log`.
Detailed gate directory: `/tmp/rendprop-adoption-swift.pK0C9d`.

| Executed surface | Result |
|---|---|
| Actual Foundation credential/recovery helper |65 assertions pass; forced failure exits1 |
| Actual copied helper mutants |5 compile successfully and then fail executable assertions/exit1, including bypassed local-persistence confirmation |
| Existing AuthStore/Settings source contracts |4 pass, no skips; source checks only |
| New source binding + executable wrapper |2 Node tests pass, no skips |
| Actual extracted AppModel metadata methods, complete PersistentStore, real Listing/Money/Render/RoomTag/CaptureAsset types |61 Swift assertions pass; forced failure exits1 |
| Actual extracted AppModel mutants |3 compile then fail assertions/exit1: omitted restored IDs, ignored persistence failures, evicted pending binding |

The 61-assertion executable's sources, binary, logs, actual mutant copies and
source-hash receipt are retained at:
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-local-binding-swift-mmOCgm`.
Its `receipt.json` identifies the exact source hashes and limited runtime scope.
All state fixtures are synthetic and created in that owned temporary directory;
no customer library or photograph was read. The three copied AppModel mutants
are not repository edits.

The portable fixture initially assumed JSON dictionary encoding order was
stable, which made identical synthetic JWT claims sometimes encode differently.
That caused two honest failing assertions in `/tmp/rendprop-adoption-swift.4dtTKT`.
The fixture now uses sorted JSON keys; no production token comparison was
weakened. New extraction harness setup errors (URL percent-encoding and an
ambiguous `load` declaration) also exited nonzero and executed no Swift tests;
the final harness scopes extraction uniquely to AppModel and uses fileURLToPath.

The actual AuthStore/recovery/SessionConnection sources also **typechecked**
against installed iOS Simulator26.4 SDK / iOS16 deployment target, using inert
Config/API dependency types and the existing module cache. Exit0, empty
diagnostics: `/tmp/rendprop-adoption-local.rOvm4J/auth-sdk-typecheck.log`.
This did not compile/link the whole app, exercise callbacks through SwiftUI,
run a simulator, or access an actual Keychain.

## Remaining proof and scope limits

- The actual `/me` deletion snapshot race remains a separate0039 unit; this
  local fix cannot prevent server-side stale deletion from erasing an adopted
  org. No full data-loss-closure claim is made here.
- `AuthStore.persistTokens` still writes active access/refresh slots separately
  and ignores their return values. The source recovery envelope is preserved,
  but this unit does not claim atomic active-session writes or successful
  recovery under every partial Keychain failure. Physical locked-Keychain,
  process-termination and real Auth token-rotation tests remain necessary.
- A server receipt confirms the workspace transfer, not the continuing
  existence of every historical listing/share link. Server authorization still
  governs later calls. No cloud hydration, multi-workspace selector or arbitrary
  account-to-account cache retention is introduced.
- Historical lost local IDs cannot be invented. A receipt without its matching
  local journal is not enough to clear local recovery successfully. Deploy/build
  the local unit together with16a04ce rather than representing that first
  checkpoint alone as complete end-user recovery.
- Existing upload/publish/compliance caches are still cleared on account change;
  this unit restores listing/share/render identities, not background upload
  state or an exactly-once media upload guarantee. Local media remain untouched.
- Malformed recovery metadata prevents overwriting its state file, including
  autosaves. The error is explicit, but edits made afterward are not claimed
  durable until storage recovery; use recovery help, never a delete/reset test.
- New source pickup still requires XcodeGen before the eventual full app build.
  App-wide build/link, non-camera UI, visible recovery copy/accessibility and
  real device persistence are **not verified by these portable checks**.
- No new auth/feature/purchase requirement, analytics event, provider, dependency
  or network service was added. No source cleanup, deployment or production
  destructive operation was performed.
