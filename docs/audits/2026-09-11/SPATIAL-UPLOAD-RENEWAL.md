# Spatial upload renewal — 2026-09-11

Source unit follows `ebdeb53` on `fix/upload-rollout-recovery-20260911`.
No service deployment, customer operation or Apple operation occurred.

## Change

`SpatialUploadCoordinator.advanceFrame` now calls
`APIClient.renewUpload(assetID:)` for the original journaled asset, after a
complete probe. It no longer repeats `POST /uploads` to renew a room image.
That reservation route can allocate another asset when completion races it.

`SpatialUploadRecovery` uses the same production `UploadRecovery` validator as
general uploads: the asset and mode must match, unfinished replies must be v2,
and their URL must be a bounded capability. An `uploaded:true` response may
omit the URL and immediately proceeds to attaching the original ticket.
Account checks remain before and after renewal and now precede the probe too.
Original capture files, batch UUID, per-frame initial idempotency keys, journal
schema, task-ID fences and background drain are unchanged.

Generic409 errors no longer authorize renewal. Only the existing explicit
missing-receipt409 or transient503 enter by-id reconciliation; permissions,
expiry and terminal errors preserve the capture and report failure.

## Verification

`python3 tools/audit/run_spatial_client.py` passed native production-model tests
and six successfully compiled source mutants, then reran the original source.
Receipt: `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-client-3s8l9kwe/receipt.json`.
The added mutant turns a completed renewal into another PUT and fails the exact
"Completion won renewal race without another PUT" assertion. Existing mutants
cover privacy, progress, stale task callbacks, renderer revision and capture owner.

The native harness includes exact upload models extracted from `APIClient.swift`
and the complete shared renewal validator, not alternate permissive DTOs.
A source-presence gate separately checks that the actual coordinator invokes
by-id renewal with both account checks and no reservation call in that closure.
These are fixture/model tests, not proof of iPhone background delivery. Full
app build evidence will be recorded with the following Pause reliability unit.

The matching server `/uploads/:id/renew` route must be deployed before this
client is distributed; no handler without that route can authorize ambiguous
renewal. There is no new reconstruction/provider/Apple claim in this unit.
