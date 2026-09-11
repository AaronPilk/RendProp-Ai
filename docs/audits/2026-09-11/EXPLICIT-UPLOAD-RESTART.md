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
