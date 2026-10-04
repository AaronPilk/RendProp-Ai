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
```

The runner compiles actual Listing/measurement models and WorkspaceSync.swift,
plus extracted actual LiveAPIClient create/PATCH/body/decoder/mapping methods
and AppModel modify/markDirty/syncListing methods. Fixtures replace only Auth,
HTTP execution/request construction and file-path resolution. Held asynchronous
boundaries exercise edits during create and PATCH, failed/cancelled writes and
account changes. Each run saves source hashes, compile/run logs and a receipt
under its printed owned `/tmp/rendprop-floor-measurement-sync-*` directory.

The six copied-source negative controls must compile, then fail their named
assertion. They do not edit runtime source. These tests use no real networking,
credentials, photos, camera sessions, customer rows or cloud writes.

Wire semantics:

- A valid typed plan is encoded under `details.floor_measurements_v1`, independently
  of the generic details form. Its 10,000-byte model cap and the complete
  16,000-byte UTF-8 JSON details envelope are checked before HTTP execution.
- A nil typed plan preserves raw wire strings, including invalid/future versions.
  Explicit clearing removes the raw key and typed field together, or writes an
  empty supported plan. The current editor uses the latter for removing all rooms.
- Dynamic details keys retain exact spelling through the snake-case DTO decoder.
  A malformed/future plan becomes a nil typed plan without hiding other facts.
- Dirty and protected local plans survive remote snapshots. Clean acknowledged
  listings accept authoritative remote absence/deletion; there is no indefinite
  local resurrection. Create replay uses the same merged details fingerprint and
  adopts remote measurements only within the existing identity/workspace guard.
  Pending fingerprints from older app snapshots remain compatible only while
  the typed plan contributes no independent edit beyond its raw details value.
- Measurement bodies omit photo/gallery fields and preserve known `floorplan_url`
  and other string details. Existing server PATCH replaces the entire details
  bag without a revision/CAS check. A stale clean snapshot or an unseen concurrent
  office edit can conflict with local facts, including a floor-plan URL. This
  feature does not change that existing protocol or claim conflict-free sync.

This is offline source-level proof, not a physical-device or live-server test.
