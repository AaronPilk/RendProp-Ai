# First-create and lost-receipt facts intent

Run on macOS with the installed Swift toolchain:

```sh
python3 tools/audit/listing-create-intent-20261004/run.py
for fault in revive-replay-intent drop-replay-base retain-consumed-address; do
  python3 tools/audit/listing-create-intent-20261004/run.py --expect-regression --inject-fault "$fault"
done
```

The harness compiles captured actual Listing/Money/contact models and exact
production `CloudDraftCreation`, `ListingWireDetails` and `CloudSyncError`
declarations. Held create closures and synthetic mapped server receipts replace
transport. No credentials, native APIs, camera, customer files or runtime writes
are used. Local photo paths are inert reference values.

Ten scenarios exercise the three first-create cases: intent staged before the
first payload; no initial intent with an in-flight edit; initial intent with an
additional in-flight edit. Fresh and replay receipts are distinct. Replays first
simulate an accepted payload with a lost response. Office rows then contain
newer edits, including an office decision that returns a value to its pre-create
value. That decision must conflict with the correctly recorded create payload.
A changed retry snapshot retains its original fingerprint and requires review
when the original payload can no longer be proven. An untouched pre-create edit
is consumed by creation and must not survive as newer phone intent.
Additional cases preserve the coordinate pair, pending typed/raw geometry and
device references, and an explicit unarchive status during a replay.

Receipts record each scenario's visible facts, queued values/expectations,
comparison with the office CAS values and exact source/body/harness hashes.
Both production and harness hashes must still match after compilation and
execution; stale inputs fail the gate. Default execution requires every assertion
to pass. All three copied-source controls
must compile and reject their exact named behavioral assertion. They remove
unchanged replay intent retirement, original-payload replay base admission, or
consumed-address retirement.
`--expect-regression` also supports examining a known failing actual source.

Evidence lives in the printed `/tmp/rendprop-listing-create-intent-*` directory
or an explicit `--output-dir`. CAS admission here compares exact recorded
expectations; the root's database and handler proofs validate actual server CAS.
