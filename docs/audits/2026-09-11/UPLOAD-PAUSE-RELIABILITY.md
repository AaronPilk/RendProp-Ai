# Upload Pause and multipart receipt reliability — 2026-09-11

Separate follow-up to general recovery `ebdeb53` and spatial migration
`9d79394`, on `fix/upload-rollout-recovery-20260911`.

## Fixed and independently exercised

- `UploadManager.pause()` used to cancel multipart tasks already dispatched.
  A one-write operation interrupted before its stored receipt can become
  irrecoverably uncertain. Pause now stops scheduling and lets up to three
  dispatched parts (or one single transfer) settle. It retains their task IDs,
  progress and ETags. The Settings caption explains this behavior.
- Part completion delegates record receipts while paused but cannot schedule
  the next part or complete the object until explicit Resume.
- Delayed `getAllTasks` callbacks recheck current asset and uploading status
  before resuming suspended tasks. A Resume→Pause race cannot restart them.
- A delayed renewal error cannot change a newly paused record to Failed.
- Settings displays the saved failure reason, not only a generic Failed label.

The added initializer injects API, URLSession and persistence boundaries while
executing the **complete real UploadManager**. The shipping singleton still
uses its real OS-owned session, UploadStore and network monitor.

## Tests and limits

`python3 tools/audit/run_upload_recovery.py`:
**69 native assertions, seven compiled mutants detected, original restored.**
Receipt: `/tmp/rendprop-upload-recovery-gmu84ov6/receipt.json`.

This test now instantiates the real manager, not just its Codable state. It
executes selection, bounded slicing, task creation/dispatch, Pause, delegate
completion, same-asset reconciliation and completion manifests against an
in-process session/API boundary. No request leaves the fixture process.

1. Three of four tiny synthetic parts start. Pause cancels/suspends none.
2. Their completion delegates preserve ETags while the fourth stays pending.
3. In a separate relaunch-style fixture, renewal returns three server-confirmed
   ETags. The actual manager applies them and starts only the fourth part.
4. Pausing that last part allows it to settle, without publishing. Resume then
   completes using exactly all four original ETags and zero new reservations.
5. Delayed enumeration and delayed503 both preserve explicit Pause.
6. Duplicate/out-of-range/empty confirmed receipts and changed multipart
   session are rejected; original fixture bytes remain unchanged.

Two new compiled source mutants cancel on Pause or ignore confirmed ETags.
Each compiles successfully, then fails its specific runtime assertion. Five
existing mutants still detect re-PUT, missing legacy consent, version rollback,
changed asset and discarded Resume identity. Test-only Foundation task/session
subclasses emit two deprecated-init warnings; production upload sources emit
no warning in the native compile. These fixtures do not prove nsurlsessiond
behavior during a real iPhone suspension or mobile-network handover.

### Application build

After source-symbol checks, from `apps/ios`:

```sh
xcodebuild build -project Rendprop.xcodeproj -scheme Rendprop \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/rendprop-upload-rollout-derived-20260911 \
  CODE_SIGNING_ALLOWED=NO
```

Exit0, **BUILD SUCCEEDED**. Final log:
`/tmp/rendprop-upload-rollout-spatial-pause-final-20260911.log`.
The final incremental build reported only the pre-existing AppIntents metadata
warning. This covers the spatial renewal and Settings/Pause source together.
No UI walk, camera test, project regeneration or archive occurred here.

## Remaining explicit restart UX — NOT FIXED

Expired or permanently uncertain v2 **photos** remain bound to their original
content-derived journal and reservation. Re-selecting identical bytes does
not constitute a new paid attempt and does not discard the first ticket.
There is no implemented explicit v2 Restart confirmation yet.

Reproduction: upload a photo with a journaled asset; make its server reservation
terminal/expired; select the identical photo for the same listing/role again.
`DirectUploader.swift:26,42` loads the original content-keyed journal;
`UploadRecovery.swift:57,129` only allows replacement after an explicitly
approved **legacy** cancellation, not arbitrary expired v2 replacement.

Actual caller gap: `RendpropApp.swift:569,607,662` uses `try?` for altered photo,
gallery and poster uploads. Those paths can discard the reason rather than
offer actionable per-file recovery. **Do not call this closed by the new
Settings failure text**, which covers the general video journal only.

Required next unit: return a structured per-photo recovery item to each caller;
show Preserve original / Restart upload confirmation with the allowance impact;
on explicit Restart reconcile completion again, persist one new attempt UUID,
acknowledge cancellation of only that expired asset, and create exactly one
replacement under the new attempt key. Handle completion-winning-cancellation,
lost cancellation reply, relaunch, account switch and batch partial success.
Do not bulk-abort, delete media, silently change keys, or promise that repeated
Resume/re-selection can fix a terminal v2 ticket.

No customer upload/cancellation, backend deployment, archive, TestFlight or
App Review change occurred in either follow-up unit.
