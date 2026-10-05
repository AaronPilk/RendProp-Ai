# Native listing facts review

```sh
python3 tools/audit/listing-facts-review-20261004/run.py
```

The compiled checks run the actual detail-card admission, comparison row
renderer, sheet context check and load/resolve bodies against the complete
production Listing/contacts/Money types. Only model transport and unrelated UI
state are doubles. They verify legacy/conflict/review card visibility, exact
phone/shared values, sold state, safe nonfinite coordinates, editable indexing
and details, private/server metadata omission, account/session/workspace/listing
change rejection, both choices and retained failure/reload state. Source wiring
also requires the Cancel action and disabled stale/error buttons.

Two compiled controls fail their intended checks:

```sh
python3 tools/audit/listing-facts-review-20261004/run.py --inject-fault drop-review-context
python3 tools/audit/listing-facts-review-20261004/run.py --inject-fault expose-private-details
```

No production network, credentials, camera or customer files are accessed. This
establishes the comparison/action logic, not SwiftUI rasterization or physical
phone usability. The root listing-sync harness separately verifies actual
AppModel resolution and atomic backend update behavior.
