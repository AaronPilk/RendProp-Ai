# Reflection controller adversarial review — 19 September 2026

The new iOS controller is repaired and passes the twelve offline controller checks below. This is a local control-flow and persistence verdict, not a production deployment, provider-quality verdict, or real billing receipt. Full iOS integration/build and the server's accounting tests are recorded separately by their owners.

## Reproducer and scope

From the repository root:

```sh
python3 tools/audit/call-20260919/reflection-controller/run.py --baseline
python3 tools/audit/call-20260919/reflection-controller/run.py
```

The runner compiles the complete actual `ReflectionRemoval.swift` and `ReflectionAPI.swift`, with access-control-only inspection shims. The journal, filesystem copy, task generation, Combine account observation, cancellation, retry, and model mutation are real. API/upload/video/download boundaries are deterministic doubles; held continuations deliberately ignore cancellation to reproduce late results. All media are synthetic 16-byte markers in an isolated temporary directory, not playable video or customer files. Baseline execution adds one `nonisolated` annotation to work around the initial independent Swift isolation compile failure.

The baseline fixture preserves the initial Task 2 implementation, not Claude's September 17 capture code: `tools/audit/call-20260919/reflection-controller/BaselineReflectionRemoval.swift`, SHA-256 `eba8c02326017e10815d803d1aa99ed20916807caf1baa1faf35ab3a217a19db`. Committed-format receipts are `receipt-baseline.json` and `receipt-fixed.json` in that directory and include the exact source/test hashes.

## Proven baseline failure and repair

**P1 before repair:** Cancel a batch while extraction is awaiting, receive cancellation confirmation, start a replacement batch, then allow the first extraction to return. The original `process` writes the first batch's input path into the second batch's piece at baseline lines 199–201. `operationID` previously guarded only final busy-state cleanup. The executable baseline reports `lateCancelledExtractPoisonsNewBatch: true`; repaired source reports `false`.

The repaired controller pins its owner account, scopes cached controllers by account and listing, binds each operation to a task-local generation, and checks owner/generation/cancellation after every asynchronous boundary before mutating state. Account changes cancel local work and revoke preview/result access; the UI separately gates players, exports, and actions on `accountMatches`. Each durable clip UUID is created before upload/submit and retained across retry and relaunch.

Cancellation now invalidates old work before attempting a journal write. A full disk or failed journal replacement cannot prevent the server cancellation request. Known unusable media, terminal provider failure, or a definitive processing API 400/402 rejection automatically requests batch cancellation/refund; transient connection failures leave a resumable journal and show no claim of refund until acknowledged. A server-committed apply with a lost response is recovered using the same full original/altered IDs after cancellation returns 409, without selecting the edited video after Cancel.

Before provider work, the controller creates its own complete original copy. It does not overwrite the external capture. The journal stores paths relative to Documents and restores them on relaunch. Only explicit acceptance changes `AppModel.assets`, after disclosure/provenance acknowledgement and a check that the listing still contains the expected source/result.

## Executed repaired checks

| Trace | Observed outcome |
| --- | --- |
| Cancel, restart, then release old extraction | Old operation cannot write an input path into the new batch. |
| Submit reaches server double but response is lost; reconstruct controller from disk | Same clip UUID submitted twice; one server-double job; preview eventually available. |
| Preserve full original | Owned copy initially matches all source bytes; overwriting the synthetic external capture does not change the preserved copy. Processing does not select the result. |
| Provider returns 8 seconds for a requested 3-second clip | Result rejected; exactly one batch cancellation requested and acknowledged; original remains selected. |
| Refund endpoint offline, then explicit retry | Cancellation remains requested but unconfirmed; UI reports uncertainty; retry records confirmation. |
| Account changes during a held upload | New account receives a distinct controller with no old work; late upload does not checkpoint or submit a provider job; preview/result access revoked. |
| Second clip receives a definitive 400 or 402 after the first completed | Entire batch is automatically cancelled/refunded; original remains selected. Both status codes are independently exercised. |
| Second clip receives 429 after the first completed | No cancellation; retry resumes the same batch and completes both jobs. |
| Journal replacement fails during Cancel | Server cancellation still requested and acknowledged; late extraction cannot submit. |
| Apply commits while response is held, then user cancels | Cancel's 409 triggers an identical idempotent apply to recover the stored receipt; original remains selected and completion count stays zero. |
| Release that old apply response, then explicitly accept again | Old response does nothing; the subsequent explicit acceptance selects the saved result exactly once. |

All twelve checks pass. `swiftc -frontend -parse` passes for both controller/API files; `git diff --check` passes. The root task owns the full native build and UI verification.

## Explicit limits and integration facts

- No provider job, real credit debit/refund, remote upload, production data, customer media, phone, or App Store Connect was used. The server contract is independently tested by the server owner; client doubles cannot prove its accounting.
- Native extraction/splicing, playable-output duration/framing/audio, device storage/performance, and visual reflection-removal quality require their separate media/device/provider checks. These controller markers do not prove those properties.
- Task cancellation cannot force the existing UploadManager continuation to return. A late upload may finish, but this controller cannot checkpoint it into another account/batch or issue the subsequent paid request. The application's existing account-switch handler owns global upload cancellation.
- The current coordinated server contract accepts full original and altered videos in the public `renders` bucket. Acceptance uploads both there for provenance; the independent local copy remains. Keeping provenance originals private would require a coordinated server asset-validation and retrieval contract change. This is not described as a private cloud backup.
- Real ten-minute 4K capture thermal/battery/Vision orientation evidence remains unmeasured; see the timing audit for that gate. The controller tests do not replace it.
