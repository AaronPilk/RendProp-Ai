# Outline editor calculations

Run from the repository root:

```sh
python3 tools/audit/floor-measurement-outline-editor-20261004/run.py
python3 tools/audit/floor-measurement-outline-editor-20261004/run.py --inject-fault=drop-original-geometry
python3 tools/audit/floor-measurement-outline-editor-20261004/run.py --inject-fault=drop-original-vector
python3 tools/audit/floor-measurement-outline-editor-20261004/run.py --inject-fault=drop-save-fence
```

The harness extracts the actual wall-vector, initialization, coordinate-entry,
candidate and save bodies from `FloorMeasurementsView.swift`. It compiles these
bodies unchanged alongside the actual Listing measurement models using
Foundation. Only the SwiftUI state wrapper and view declaration shell are
replaced with a small class boundary. It exercises calculations and callbacks;
it does not replace native UI tests or test camera measurement accuracy.

Checks cover bitwise coordinate preservation during metadata edits, feet and
meter entry, height boundaries, signed offsets, custom and diagonal bearings,
decimal commas, measured versus calculated closing walls, real geometry edits,
and the pending-wall/closing-review save fence. All three negative controls compile
and run deliberately mutated private copies and must fail at their intended
runtime assertions. A successful control invocation means the regression was
caught, not that its broken candidate passed.

Each invocation saves generated source, compiler/run logs and a source-hashed
JSON receipt in a fresh `/tmp` evidence directory, or the directory passed with
`--evidence`. It makes no network, provider, camera, or customer-file calls.
