# General iOS upload recovery — 2026-09-11

Branch: `fix/upload-rollout-recovery-20260911`, based on `baf77f9`.
Worktree: `/Users/pilksclaes/Rendprop AI/upload-rollout-recovery-20260911`.

## Delivery status

Implemented and tested locally. **Not deployed, not uploaded to TestFlight.**
This does not change App Review, existing customer tickets, uploaded objects,
provider settings, or the owner's spending/headroom decision.

Deploy the matching `uploads` handler with `POST /uploads/:id/renew` before
rolling out this client. An older handler without that endpoint deliberately
cannot authorize an ambiguous retry; the original file remains on the phone.

## Why the old behavior failed

1. `UploadManager` retried a single PUT using the same URL after a timeout,
   or discarded its ticket after expiry. A timeout cannot distinguish a failed
   transfer from storage committing and its response getting lost.
2. Explicit Resume discarded the server asset/session/ETags on any terminal
   response. A v1 ticket rejected after the v2 rollout was never cancelled,
   so its stable key kept conflicting with the old reservation.
3. Foreground photo paths repeated PUT and complete together. A successful
   complete with a lost response therefore resent the entire photo.
4. Repeating **POST /uploads with the same key is not sufficient**: migration
   `0037_upload_transport_budget.sql:139` looks up only unfinished assets. If
   completion wins a race, another POST can allocate a fresh paid reservation.

## Implemented behavior

- `UploadRecovery.swift:116`: probe complete before any recovery transfer.
  Successful completion returns the existing asset, without renewing or sending
  bytes. An unrelated conflict, expiry, permissions failure or malformed receipt
  does not authorize cancellation or replacement.
- `UploadRecovery.swift:41`: recognize only the exact server legacy-retirement
  messages with HTTP409. Upper-case `CONFLICT` does not bypass the status check;
  arbitrary text containing “legacy” is not permission to cancel.
- `UploadManager.swift:122`: explicit Resume retains the operation key, asset,
  multipart session, existing part ETags and transport version. It only authorizes
  a subsequent, server-confirmed legacy migration.
- `UploadRecovery.swift:129`: explicit legacy recovery persists the exact
  cancellation target before aborting it. Only a confirmed abort permits a new
  ticket using the **same original key**. A lost abort response resumes that
  durable intention. No batch abort or original-file deletion is used.
- `LiveAPIClient.swift:444`: abort decodes `ok` **and** `upload_aborted` via
  `decodeExact`; a random2xx or `{ok:true}` alone is not a cancellation receipt.
- `uploads/index.ts:328`: new same-asset renewal looks up the authorized asset,
  never calls `reserveAssets`, returns already-completed tickets without a PUT
  capability, and refuses unfinished legacy or aborted tickets. Recovery of an
  uncertain operation still goes through the existing durable server journal.
- `uploads/index.ts:619`: multipart renewal returns stored, server-confirmed
  part ETags; client progress no longer depends solely on a lost PUT response.
- `UploadRecovery.swift:68`: a renewal must retain asset identity, mode and
  multipart session/shape. A versionless or v1 response cannot relabel a v2
  reservation. Renewed PUTs must have the bounded v2 capability shape.
- `DirectUploader.swift:11`: posters, originals, altered photos, gallery photos
  and ordinary photo batches use the same recovery implementation. Protected
  per-photo receipts persist before byte dispatch; bounded batches use at most
  three concurrent per-file operations and resume completed files independently.
- `DirectUploader.swift:19`: anonymous session connection completes **before**
  binding the journal owner. No registration or identified-account gate is added.
- `DirectUploadJournal.swift`: receipt files are excluded from backup, protected
  until first authentication, bounded to64KiB each, and written atomically.
- `UploadManager.swift:1346`: inability to persist the ticket/task/cancellation
  identity prevents the physical dispatch; it does not discard the original.
- Video background task callbacks/progress check the current per-task identifier,
  so an old task cannot complete a replacement task with the same asset/part name.

The generated project change is limited to eight source-reference entries for
the two new Swift files. Worktree-name/capture-reference churn from xcodegen was
removed; no version, signing, resources, scheme or Apple settings changed.

## Verification receipts

### Actual native Swift

Command, repository root:

```sh
python3 tools/audit/run_upload_recovery.py
```

Final receipt: `/tmp/rendprop-upload-recovery-oi6zohu4/receipt.json`.
**46 assertions, five deliberate source mutants caught, restored source passes.**
Every mutant first compiled successfully, then failed its targeted runtime
assertion; compiler/import errors were not accepted as a negative control.

The harness compiles the complete production `UploadManager`, `DirectUploader`,
`UploadRecovery`, `DirectUploadJournal`, and `UploadStore`. Wire models/errors
are extracted verbatim from `APIClient.swift`, not rewritten as permissive test
models. Only the app/API/transfer boundary is replaced. It tests:

- PUT committed but its response lost: one physical fixture write.
- complete committed but its response lost: one PUT, no replacement reservation.
- request failed before storage dispatch: complete → same-ticket renew → transfer.
- unprovable v2 write: no second PUT and no silent cancellation.
- v1 migration: no automatic cancellation; explicit resume cancels exactly one
  retired asset, preserves the key and uploads the original once.
- lost abort response, versionless rollback, expired ticket, revoked workspace.
- exact snake-case abort receipts, old persisted video records and retained ETags.
- first-launch anonymous connection and unchanged original fixture bytes.

Five defects injected into actual source: skip reconciliation and resend,
remove legacy consent, allow versionless renewal, ignore asset identity, and
clear ticket/parts in explicit Resume.

These are native fixture tests, **not** a real iPhone/network-handover test.

### Actual Edge handler, offline fixtures

```sh
deno test --cached-only --deny-net --deny-run --deny-write --allow-read --allow-env \
  tools/audit/uploads_renewal_test.ts \
  tools/audit/uploads_transport_test.ts \
  tools/audit/uploads_publication_test.ts \
  tools/audit/uploads_completion_race_test.ts
```

**51 passed,0 failed**: seven new renewal tests plus44 existing transport,
publication and completion-race tests. The actual handler runs with fixture
PostgREST/R2; there are no real requests, deletes, uploads or cancellation calls.
Database/provider concurrency is not inferred from these in-memory fixtures.

### Full application build, isolated products

Source symbols were searched before building. Project generated with
`xcodegen generate`, then source additions reduced to the eight necessary
project references. Final command, `apps/ios`:

```sh
xcodebuild build -project Rendprop.xcodeproj -scheme Rendprop \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/rendprop-upload-rollout-derived-20260911 \
  CODE_SIGNING_ALLOWED=NO
```

Exit0, `BUILD SUCCEEDED`.
Log: `/tmp/rendprop-upload-rollout-build-final-20260911.log`.
This compiles both real API implementations with the added protocol method.
Warnings remain outside this upload unit in `RendpropApp.swift`,
`NewListingView.swift`, and AppIntents metadata extraction. Earlier full build
also reported the existing `VoiceRecorder.swift` Bluetooth deprecation.
No full UI walk, camera session, archive or Apple operation ran in this unit.

## Explicit remaining boundaries

1. **Real phone interruption/relaunch/handover remains an acceptance gate.** The
   generic upload engine still acknowledges background-session event draining
   immediately; a metadata completion interrupted by iOS suspension is recovered
   on foreground/relaunch. This unit does not claim continuous background cloud
   completion under every suspension condition.
2. Existing pre-upgrade foreground photo uploads did not persist asset IDs.
   Their old conflicting key alone is insufficient authority to find/abort a
   customer ticket. Do not bulk-abort or delete local media to work around it.
3. Expired or irrecoverably uncertain v2 reservations remain explicit failures.
   Replacing them is a separate, deliberate per-ticket user workflow; this
   patch does not silently spend a fresh allowance on them.
4. The separate spatial uploader still calls POST /uploads for its same-key
   renewal. It should migrate to the new same-asset renewal contract, including
   the completed response, in its own tested follow-up. Do not claim this patch
   automatically changes the spatial coordinator.
5. Photo receipt files are small but have no pruning/retention policy yet.
   Completed records avoid re-uploading the same original; cleanup must retain
   unfinished records and must never remove the original photo.
6. Header example check: historical `bcba804:docs/handoff/launch-P2.md:518`
   contains a five-byte literal placeholder, not a JWT. Its SHA256 is
   `3c469e9d6c5875d37a43f353d4f88e61fcf812c66eee3457465a40b0da4153e0`.
   A bounded scan of lines490–550 found no JWT. No secret value/header was
   printed or used. There is consequently no real token/role/expiry to certify
   at that pointer; this is **not** a credential-rotation clearance.

No deployment, TestFlight delivery, customer data change, new provider spending,
or credential-rotation completion is claimed by this receipt.
