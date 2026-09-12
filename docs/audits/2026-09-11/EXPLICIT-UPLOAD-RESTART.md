# Explicit upload restart — iOS implementation, 2026-09-11

Branch `fix/upload-explicit-restart-20260911`, based on integration `71f9eb7`.
No deployments, customer mutations, Apple operations or GPU runs occur here.

## Core contract

`POST /uploads/:assetID/restart` receives `{confirm_new_attempt:true}` and one
persisted UUID Idempotency-Key. The matching server implementation owns the
exact old-to-child linkage, cancellation and bounded admission. The phone
never falls back to abort + fresh reservation, relabels a ticket, refunds
usage, or creates an automatic new attempt. A chain allows at most three
explicit restarts; the server remains authoritative.

Optional ticket fields are `restart_required`, `restart_reason`,
`restart_generation` and `retry_after_seconds`. Reasons are expired,
interrupted or cancelled. A live write awaiting its recorded deadline is a
wait receipt, not permission to restart; no URL is needed for that metadata.
Existing exact snake-case/decoder conventions are preserved in all API clients.

Every explicit restart probes completion first. Completion or a concurrent
completed reply returns the original asset without new bytes. Otherwise only
the named linked endpoint can return a replacement. The original journal key
stays stable; the restart intent saves owner, parent asset and UUID before the
call, and saves returned child identity before acting on its state. A lost
reply therefore cannot create another child. An expired child remains visible
and needs a new explicit action against that child, not a new independent chain.

Foreground photos now retain source identity, byte count, SHA256 and relative
path in the existing protected per-photo journal. Pending items are filtered
by the live credential owner. The original file is never removed. A failed
journal read is never overwritten with an empty/default record.

## Core native evidence

Command: `python3 tools/audit/run_upload_recovery.py`.
Receipt: `/tmp/rendprop-upload-recovery-40m_gsvm/receipt.json`.
**96 assertions, ten compiled mutation controls detected; restored source passes.**

The suite executes actual DirectUploader/recovery/journal and the full real
UploadManager against isolated session/API boundaries. New tests cover explicit
photo restart, same UUID after lost reply, one linked child, original completion
winning, account-switch fencing, unrelated409 rejection, active-write wait
metadata, durable pending-photo visibility, concurrent calls sharing one actor
journal reservation, and corrupt-journal byte preservation.

New compiled mutants overwrite corrupt receipts, recreate a saved restart UUID,
and call restart after successful completion. Each compiles, then fails its
specific runtime assertion. Seven earlier mutants still detect duplicate PUT,
missing legacy consent, version rollback, changed asset, discarded Resume
identity, cancelled in-flight Pause, and ignored confirmed multipart ETags.

The receipt hashes the working source, including the in-progress UI/manager
follow-up; final combined app/UX verification is recorded below when finished.
This is not a live-provider race or an iPhone network-handover test.

## Delivery boundaries

The server restart/renewal contract must be deployed before distributing the
client. Missing restart routes produce an explicit service-update error and
preserve the saved intent. No source commit by itself changes the deployed app.
The following commit adds Settings confirmation/recovery UI, photo-failure
visibility, video integration and spatial-frame restart/pause semantics.

## Integrated iOS follow-up (source frozen for final verification)

- Settings lists incomplete owner-bound photo receipts, including a process
  death before any error catch. Currently active actor-owned photos are hidden
  from that interrupted list. Retry reconciles; only a structured required
  receipt or an already-saved explicit intent exposes Restart.
- Video and each spatial JPEG use the linked restart route. A lost reply keeps
  the parent and UUID. Returned child identity and consumed intent are saved in
  one journal write, including already-completed, busy and expired replies.
- Cancel, Resume and beginning another video cannot discard an unresolved
  restart intent. Continue saved restart reconciles that operation first.
- Video ticket requests establish the normal anonymous session before binding
  their owner. Delayed ticket/part/OS callbacks and photo-batch scheduling are
  fenced to that owner. Already-dispatched physical writes can settle; another
  workspace cannot launch the next write or receive stale completion notices.
- Spatial Pause stops scheduling without cancelling an in-flight JPEG. Paused
  suspended tasks do not consume running-transfer slots; explicit Resume can
  reattach the same task.
- Photo failures are visible on Home and in Settings. Successful information
  has a separate dismissible notice. A disclosure-link failure truthfully says
  the bytes uploaded and linking failed, rather than claiming transfer failed.

Final frozen native run **passed** at
`/tmp/rendprop-upload-recovery-tzgkflkl/receipt.json`: **119 assertions**, all
**15 successfully compiled mutants rejected**, restored production pass, and
all source hashes unchanged through the run. It includes full actual
UploadManager runtime tests. There are two fixture-only deprecated URLSession
subclass initializer warnings and zero production-source native warnings.
An earlier run was correctly rejected when a source edit occurred during a
mutant compile; that partial run is not used as final proof. Executable source
and tests are frozen at `d51714b` (following core `804f912`).

Additional focused proof already passed:

- `python3 tools/audit/run_spatial_coordinator_recovery.py`: **12 assertions**
  and **3 compiled mutants** rejected. Receipt
  `/tmp/rendprop-spatial-restart-0wmus6rg/receipt.json`. This compiles selected
  actual coordinator method bodies with injected persistence/pump/API/session
  boundaries; it is not a whole-coordinator or iOS background-daemon test.
- `python3 tools/audit/run_spatial_client.py`: **75 assertions**, **6 compiled
  mutants** rejected, restored pass. Receipt
  `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-client-63l6r0k6/receipt.json`.
- Independent actual LiveAPIClient wire harness: 41 assertions and 5 negative
  controls passed against the corrected adapter (separate harness commit
  `17de00c`). It caught the initial raw-String Idempotency compile defect;
  production now uses `.key(operationID.uuidString.lowercased())`. Fresh
  source-hash-bound rerun receipt:
  `/tmp/rendprop-upload-restart-wire-_5g6thv1/receipt.json`.

The first generic simulator build exited **65** because of that adapter error:
`xcodebuild build -project Rendprop.xcodeproj -scheme Rendprop -destination
'generic/platform=iOS Simulator' -derivedDataPath
/tmp/rendprop-explicit-restart-derived-20260911 CODE_SIGNING_ALLOWED=NO`.
Log: `/tmp/rendprop-explicit-restart-build-20260911.log`. No successful full-app
build is claimed here; the parent is running the corrected integrated source.

### Still distinct acceptance work

- Retrying saved photo bytes does not automatically replay a failed poster or
  disclosure-link attachment. The UI explicitly asks to reopen the listing or
  contact support for the link; this remains separate from transfer recovery.
- Real iPhone Wi-Fi loss, suspension/termination delivery, and a live linked
  restart against the deployed backend are not executed by these fixtures.
- No camera test, TestFlight upload or App Review mutation occurred in this unit.

## Settings compiler follow-up

The parent's corrected integrated full build found a separate SwiftUI
type-checking timeout in Settings' inline photo-confirmation Binding at
`SettingsView.swift:467` (pre-refactor line). Log:
`/tmp/rendprop-upload-recovery-app.kRcexp/build.log`; build exit **65**.
The follow-up changes only Settings view decomposition and this receipt note:
explicit `Binding<Bool>`, typed photo-confirmation actions, separate Uploads
section/current-video/photo-notice/photo-row builders, and opaque form/dialog
boundaries. All consent text, generation limits, persisted-intent guards,
account recovery actions and dismissal behavior are retained.

`xcrun swiftc -frontend -parse apps/ios/Rendprop/Screens/SettingsView.swift`
and `git diff --check` pass. Parsing is not type-checking or an app build;
the parent reruns the integrated app build/UI test against this patch.
