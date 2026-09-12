# Edge CI failure: deletion test descriptor, 2026-09-11

## Observed failure

[Workflow 34662282586](https://github.com/AaronPilk/RendProp-Ai/actions/runs/34662282586),
head `2ca9c7a6219393845382928fb448d6bead7d4a51`, job `103467084865`:
all 22 function entry points type-checked, but the test step ended at
`2026-09-12T00:38:42Z` with **726 passed / 1 failed module**.

The only failing module was `services/supabase/functions/me/deletion.test.ts`.
Its top-level line 22 spread `Object.getOwnPropertyDescriptor(Deno, "serve")`
and added a `value`. On CI's pinned Deno 2.9.6, `serve` is an accessor. The
resulting descriptor contains both accessor and data fields, and JavaScript
rejects it before the 27 deletion tests register:

```
TypeError: Invalid property descriptor. Cannot both specify accessors and a value or writable attribute
```

The descriptor setup was introduced with the deletion fixture in `441b46a`.
This is not a failure of the newly added upload restart tests or of a deployed
handler. Those upload tests passed in the same CI job. Local Deno 2.7.13 exposes
the data-descriptor case, explaining why the explicit-list local run executed
all **753 tests = 726 + 27** successfully.

## Narrow correction

`me/deletion.test.ts:25` now installs a fresh configurable data descriptor,
preserving enumerability, and still restores the exact original descriptor in
the existing finally block. It does not spread any getter/setter into the
replacement. No production source, workflow pin, test assertion, network
permission or test selection is weakened or changed.

## Independent regression

Command: `python3 tools/audit/run_deletion_serve_descriptor.py`.
Receipt: `/tmp/rendprop-deletion-descriptor-ldwdzpj0/receipt.json`, accepted=true.

The harness executes the actual deletion module against both descriptor shapes:

- Data descriptor: **27 passed / 0 failed**.
- Accessor descriptor: **27 passed / 0 failed**.
- A deliberately restored spread-descriptor bug fails with the exact CI
  TypeError, after type-checking; a different failure is not accepted.
- A missing-restoration mutant fails the exact original-descriptor restoration
  assertion; a different failure is not accepted.
- Restored production under an accessor: **27 passed / 0 failed**.

Only the Deno.serve property shape is adapted. The actual handler and shared
helpers run, requests use synthetic fixtures, process credentials are not
inherited, and network/process/write permissions are denied. The source hash
must remain unchanged throughout the proof. The first harness attempt was
correctly rejected because a mutation fixture lacked the handler's deletion.ts
sibling; the final harness copies all actual siblings and does not use that
failed run as evidence.

Local runtime remains Deno 2.7.13; the accessor shape reproduces the observed
2.9.6 failure, but a new hosted CI run is still required to claim the complete
pinned-runtime workflow is green. No iOS edits, deployment, Apple operations
or customer-data mutation occurred in this CI repair.
