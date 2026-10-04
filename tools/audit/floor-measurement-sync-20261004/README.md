# Floor measurements wire, CAS and recovery proof

Run from the repository root on macOS with the installed Swift toolchain:

```sh
python3 tools/audit/floor-measurement-sync-20261004/run.py
for fault in drop-wire drop-fingerprint ignore-dirty drop-replay-adopt \
  rewrite-raw-keys legacy-ignore-edit discard-outline-only outline-fingerprint \
  legacy-v2-accept drop-local-raw-mirror omit-cas-base ignore-pending-measurements \
  wrong-cas-workspace ignore-cas-conflict omit-facts-fingerprint \
  ignore-facts-review skip-legacy-recovery ignore-cas-lineage \
  overwrite-shared-backup compare-backup-wire-only retain-backup-after-new-edit; do
  python3 tools/audit/floor-measurement-sync-20261004/run.py --inject-fault "$fault"
done
```

The positive run compiles actual Listing/measurement models, WorkspaceSync and
the anonymous-adoption journal. It also compiles extracted actual LiveAPIClient
create/PATCH/CAS/body/decoder/mapping methods, AppModel ordinary modification,
measurement save/sync/shared reload/review confirmation, and the editor save
method. Fixtures replace HTTP, active Auth/workspace metadata and file-path
resolution. Other WorkspaceSyncAPI operations deliberately throw: only the
tested cloud listing read is available.

Every run records exact source/harness hashes, actual and copied Listing hashes,
extracted body hashes, compile/run logs and a receipt in its printed owned
`/tmp/rendprop-floor-measurement-sync-*` directory. Controls mutate copied source
only, must compile, and must fail their named assertion. The original runtime
files are never edited. There are no live network requests, credentials, real
photos, camera sessions, customer rows or cloud writes.

## Exercised behavior

- Valid typed plans mirror their exact encoded string into the private
  `floor_measurements_v1` key. Both rectangle v1 and irregular-outline v2 use
  this key. Outline-only v2 is meaningful; an empty supported plan deliberately
  clears geometry. Model and full details envelope size checks happen before
  HTTP. Measured areas do not overwrite advertised listing `sqft`.
- Generic listing PATCH omits every private measurements key. Measurement saves
  instead send only exact cached `expected` and new `value` to the bound
  server/workspace CAS endpoint. Mid-request geometry edits advance only the
  acknowledged base and retain the newer pending plan; deleting the final
  outline requires its own acknowledged CAS write.
- Ordinary tagline edits use the generic dirty queue independently. Held
  requests exercise newer ordinary edits, failures, cancellation and account
  revision changes without falsely acknowledging the latest local state.
- New creation captures a persistent ordinary-facts fingerprint separately from
  its combined payload fingerprint. Lost create receipts plus geometry-only
  edits adopt office facts/attachments and use CAS, with no stale full-row PATCH.
  If the office changed geometry too, the phone copy is retained in conflict.
  Retrying creation cannot replace the original intent fingerprints.
- Older combined hashes cannot establish ordinary edit intent. Existing pending
  typed/raw drift is recovered on snapshot decode, sync and merge into CAS using
  the exact cached raw baseline. Ordinary local fields remain behind an explicit
  review fence. Confirming this iPhone's details permits their generic PATCH;
  explicitly loading shared listing details adopts remote facts while retaining
  the measurement backup. Loading only shared measurements does not approve
  ordinary facts. An unreadable old baseline is preserved without a guessed CAS.
- Actual shared reload rejects a local mutation made while its read was held.
  It retains the old measurement copy, adopts the exact shared base, and supports
  restoring the local copy through actual measurement save. Sequential shared
  measurements and shared listing-detail choices preserve the original phone
  backup without resetting fixture state. Repeated shared absence and equivalent
  JSON formatting also preserve it; a genuinely new pending plan or intentional
  empty plan becomes the new backup. Three copied-source controls remove backup
  preservation, substitute encoded-string comparison, or prohibit backup renewal
  and must fail the corresponding sequence assertions. Late CAS success or
  HTTP 409 after a shared load cannot revive or mark conflict on the replaced
  queue, and cannot submit a second measurement write or generic PATCH.
- Dynamic dictionary keys retain exact spelling through snake-case DTO decoding.
  Unsupported/future raw plans remain opaque instead of becoming an empty plan.
  Dirty/pending and protected geometry survive refresh; clean acknowledged
  geometry accepts authoritative remote absence. Bound identity and workspace
  changes prevent foreign receipt adoption or submission.
- Anonymous adoption preserves local geometry/raw wire while rebinding the same
  listing. A foreign account cannot restore its journal.

## Prior-version compatibility

`LegacyModels.swift.template` is mechanically extracted from commit `c2824e5`'s
complete version-one measurement declarations, stored Listing fields, tolerant
Listing decoder and details write helper. Namespaces are renamed to compile
beside current source. The frozen reader must accept a supported rectangle plan,
refuse typed outline-only v2, and preserve its exact raw representation on an
ordinary write. The current decoder recovers that representation after an old
snapshot round trip. Controls remove the version fence or atomic raw mirror and
must fail. Unmirrored historical typed edits use explicit legacy CAS/review
recovery; they are not treated as already uploaded.

Generic ordinary-facts PATCH still replaces its ordinary details bag; this
feature does not add per-field conflict resolution for all listing edits. The
measurement-only contract prevents geometry edits from implicitly invoking that
full-row write, and the older ambiguous-intent path requires an explicit choice.

This is offline source proof, not a physical-device or live-server test. The
separate `tools/audit/run_listing_measurement_cas.py` runner verifies the actual
database CAS, permissions, alias preservation and overlapping actors in owned
disposable PostgreSQL.
