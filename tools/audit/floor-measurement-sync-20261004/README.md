# Floor measurements wire and sync proof

Run from the repository root on macOS with the installed Swift toolchain:

```sh
python3 tools/audit/floor-measurement-sync-20261004/run.py
python3 tools/audit/floor-measurement-sync-20261004/run.py --inject-fault drop-wire
python3 tools/audit/floor-measurement-sync-20261004/run.py --inject-fault drop-fingerprint
python3 tools/audit/floor-measurement-sync-20261004/run.py --inject-fault ignore-dirty
python3 tools/audit/floor-measurement-sync-20261004/run.py --inject-fault drop-replay-adopt
python3 tools/audit/floor-measurement-sync-20261004/run.py --inject-fault rewrite-raw-keys
python3 tools/audit/floor-measurement-sync-20261004/run.py --inject-fault legacy-ignore-edit
python3 tools/audit/floor-measurement-sync-20261004/run.py --inject-fault discard-outline-only
python3 tools/audit/floor-measurement-sync-20261004/run.py --inject-fault outline-fingerprint
python3 tools/audit/floor-measurement-sync-20261004/run.py --inject-fault legacy-v2-accept
python3 tools/audit/floor-measurement-sync-20261004/run.py --inject-fault drop-local-raw-mirror
```

The runner compiles actual Listing/measurement models and WorkspaceSync.swift,
plus extracted actual LiveAPIClient create/PATCH/body/decoder/mapping methods
and AppModel modify/markDirty/syncListing methods, the actual editor save method,
plus the complete anonymous
adoption journal. Fixtures replace only active Auth, HTTP execution/request
construction and file-path resolution. Held asynchronous
boundaries exercise edits during create and PATCH, failed/cancelled writes and
account changes. Each run saves source hashes, compile/run logs and a receipt
under its printed owned `/tmp/rendprop-floor-measurement-sync-*` directory.

The ten copied-source negative controls must compile, then fail their named
assertion. They do not edit runtime source. These tests use no real networking,
credentials, photos, camera sessions, customer rows or cloud writes.

The bounded `LegacyModels.swift.template` is mechanically extracted from commit
`c2824e5`'s complete version-one measurement declarations, stored Listing fields,
tolerant Listing decoder, and details write helper.
The runner renames their namespaces so the actual prior decoder compiles beside
the current implementation. It must accept a supported rectangle plan, refuse
outline-only version two, and preserve its raw wire on an unrelated facts write.
The `legacy-v2-accept` control removes that version fence and must fail this check.
The actual editor mirrors the complete encoded wire into `Listing.details` in
the same `model.modify` closure as the typed plan. The frozen older snapshot
decoder rejects typed v2 but retains its raw representation; after the old
snapshot re-encodes, the current app recovers the exact outline. Typed-only
unsaved historical snapshots with stale raw details do not gain this guarantee.
The `drop-local-raw-mirror` control removes the save mirror and must fail.

Wire semantics:

- A valid typed plan is encoded under `details.floor_measurements_v1`, independently
  of the generic details form. Its 10,000-byte model cap and the complete
  16,000-byte UTF-8 JSON details envelope are checked before HTTP execution.
  The key remains the same for both version-one rectangle plans and version-two
  outline plans. Version two can contain outlines with no rooms: it is not empty.
- A nil typed plan preserves raw wire strings, including invalid/future versions.
  Explicit clearing removes the raw key and typed field together, or writes an
  empty supported plan. Removing the last room or outline uses the latter;
  the harness proves a last-outline clear during an in-flight PATCH requires a
  second write and cannot be acknowledged by the older receipt.
- Dynamic details keys retain exact spelling through the snake-case DTO decoder.
  A malformed/future plan becomes a nil typed plan without hiding other facts.
- Dirty and protected local plans survive remote snapshots. Clean acknowledged
  listings accept authoritative remote absence/deletion; there is no indefinite
  local resurrection. Create replay uses the same merged details fingerprint and
  adopts remote measurements only within the existing identity/workspace guard.
  Pending fingerprints from older app snapshots remain compatible only while
  the typed plan contributes no independent edit beyond its raw details value.
- The actual anonymous-account journal preserves edited irregular outlines and
  their raw wire while rebinding the same listing and marking it dirty. A foreign
  account cannot apply that journal. Outline-only measurements do not replace
  the listing's independently entered advertised `sqft` in create, PATCH, local
  snapshots or anonymous adoption.
- Measurement bodies omit photo/gallery fields and preserve known `floorplan_url`
  and other string details. Existing server PATCH replaces the entire details
  bag without a revision/CAS check. A stale clean snapshot or an unseen concurrent
  office edit can conflict with local facts, including a floor-plan URL. This
  feature does not change that existing protocol or claim conflict-free sync.

This is offline source-level proof, not a physical-device or live-server test.
