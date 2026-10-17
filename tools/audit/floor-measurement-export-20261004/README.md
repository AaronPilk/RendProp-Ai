# Floor-plan Photos export proof

Run on macOS with the installed Swift toolchain:

```sh
python3 tools/audit/floor-measurement-export-20261004/run.py
python3 tools/audit/floor-measurement-export-20261004/run.py --inject-fault drop-context-check
python3 tools/audit/floor-measurement-export-20261004/run.py --inject-fault ignore-cancellation
python3 tools/audit/floor-measurement-export-20261004/run.py --inject-fault drop-completion-check
```

The runner extracts and compiles the actual `PhotosLibrarySaver.saveImage`,
`ensureAddAccess`, error types and `PlanExportSheet.save` from the current native
source. It does not mirror their implementation. Only UIImage, Photos permission
and write boundaries, haptics, and the caller's state container are doubles.

Held permission/write continuations exercise valid success, context change
during permission, cancellation, write failure, denied/limited permission,
invalid initial context, and context change during an already submitted write.
The last case cannot undo a submitted Photos operation; it must suppress stale
success UI. Three copied-source negative controls must compile then fail their
specific named assertion. Runtime files are never modified.

Each run retains source/body hashes, extracted source, compile/run logs and a
receipt in its printed owned `/tmp/rendprop-floor-measurement-export-*` directory.
No real Photos library, permissions, camera, network, credentials or customer
files are accessed. This verifies ordering and caller state offline; it does not
claim a physical-device Photos test.
