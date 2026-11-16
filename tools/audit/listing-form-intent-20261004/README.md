# Native listing form intent verification

Run `python3 tools/audit/listing-form-intent-20261004/run.py` on macOS with Xcode command-line tools. It extracts the actual `ListingFormData`, edit-sheet initialization/save, create-screen reuse helper, `AppModel.modify`, DTO mapping and intent/sync methods. Model source files are copied into the evidence directory before compiling so a concurrent edit cannot change compiler inputs. The receipt checks source hashes again after execution.

The fixture opens a form, refreshes the underlying listing with newer shared facts, and saves one deliberate field change. It verifies untouched area, exact price cents, the real-estate headline, business fields, unknown details and plan attachments survive. Same-field edits keep their opened expected value and a conflict retains local input. Account/session/workspace replacement rejects the old form. Existing draft reuse and monotonic first binding are exercised. New creation retains full form application with integer cents.

Controls deliberately restore a full form save, adopt the fresh remote baseline for a stale edited field, or truncate the opened price. Each must compile and fail at its exact intended behavioral assertion:

```
python3 tools/audit/listing-form-intent-20261004/run.py --inject-fault=broad-form
python3 tools/audit/listing-form-intent-20261004/run.py --inject-fault=fresh-baseline
python3 tools/audit/listing-form-intent-20261004/run.py --inject-fault=price-rounding
```

A matched control returns success only after recording the underlying failing execution and expected rejection. An unrelated compiler/runtime failure fails the audit.

Limitations: this is a source-bound actual-method gate, not a full iOS application or SwiftUI UI test. The sheet initializer replaces the environment model with an injected synthetic model and replaces `State(initialValue:)` with a primitive form property. Haptics, dismissal, Auth, workspace and transport are owned stubs. No credentials, customer rows, camera, Photos, live providers or Apple writes are used. PostgreSQL races, full release compilation, and physical-phone acceptance are separate evidence.
