# Upload restart: actual-source offline wire regression

Observed 2026-09-11 20:07 Eastern (2026-09-12 00:07 UTC).

## Result

PASS against the fixed iOS working source: **41 assertions**, all **five deliberate negative controls rejected**, restored original binary passes again. No network transport, backend mutation, build distribution or Apple action occurred.

The harness also independently rejects the actual original source at `eeb841bb26bc1e552a4f1b3a805e6dec289cb903`: its `restartUpload` passed a raw `String` where `makeRequest` requires `LiveAPIClient.Idempotency`. The actual compiler exits 1 with `cannot convert value of type 'String' to expected argument type 'LiveAPIClient.Idempotency'`. This is not inferred from a string search and is not a fabricated failing fixture.

The source fix belongs to the iOS implementation unit: `.key(operationID.uuidString.lowercased())` at `apps/ios/Rendprop/Networking/LiveAPIClient.swift:414`. This codebase's enum case is **`.key`**, not `.provided`.

## Reproduction

This new test unit branches from `eeb841b`; it intentionally does not edit the production iOS source. Until the iOS fix is integrated, give the harness that working tree explicitly:

```sh
python3 tools/audit/run_upload_restart_wire.py \
  --root '/Users/pilksclaes/Rendprop AI/upload-explicit-restart-20260911'
```

After integrating both units, run from the integrated root:

```sh
python3 tools/audit/run_upload_restart_wire.py
```

Requirements: macOS, Xcode command-line tools with `xcrun swiftc`, Python 3, and `/usr/bin/sandbox-exec`. The runtime is deliberately executed with `(deny network*)`; there is no skip/fallback if the compiler or sandbox is unavailable. Compiler calls have a 90-second timeout. Every run keeps an independent `/tmp/rendprop-upload-restart-wire-*` directory containing the extracted Swift, binaries, each command's full output and a JSON receipt. A failed run leaves `accepted: false` and exits nonzero. These temporary logs are not a durable release artifact; the observations and source hashes below are committed for handoff.

## What actually executes

`tools/audit/run_upload_restart_wire.py` extracts checked, unique source spans verbatim. It does not retype the method or rewrite production declarations to make them compile. The generated client supplies only storage/initialization and an injected `execute(URLRequest)` that records the outgoing request and returns synthetic data, or throws an injected timeout.

Actual declarations in the tested source:

- `LiveAPIClient.swift:67`: URL builder.
- `LiveAPIClient.swift:82`: typed `Idempotency` policy.
- `LiveAPIClient.swift:103`: request/header/body builder, with its actual bounded and derived-key helpers.
- `LiveAPIClient.swift:268`: actual generic decoder.
- `LiveAPIClient.swift:394`: upload DTO-to-model mapper.
- `LiveAPIClient.swift:412`: `restartUpload`.
- `LiveAPIClient.swift:1722`: `UploadTicketDTO`.
- `APIClient.swift:13`: actual `UploadTicket` model; actual `APIError` is also extracted.
- `DirectUploader.swift:160`: actual SHA-256 helpers referenced by the request-key builder.

Only fixture configuration and authorization values are supplied (`fixture-publishable-key-not-a-secret`, `fixture-token-not-a-jwt`). No real app configuration, Keychain value, environment credential or account data is used. Request destinations are synthetic `.invalid` domains; no `URLSession` is present in the transport fixture.

`tests/phase1/UploadRestartWireTests.swift` asserts:

- Exact `POST /functions/v1/uploads/<original asset UUID>/restart` URL.
- Exact body bytes `{"confirm_new_attempt":true}`.
- Lowercased saved operation UUID in `Idempotency-Key`; JSON headers and injected fixture authorization.
- An injected lost response propagates as a timeout. An explicit replay sends the same route, body bytes and UUID header. A different explicit operation has a different key.
- Fresh replacement, active-write waiting, exhausted generation 3, original-completion winner and multipart receipts decode through the actual mapper.
- Snake-case `restart_required`, `restart_reason`, `restart_generation`, `retry_after_seconds`, `transport_version`, `confirmed_parts` and upload identifiers retain their meanings.
- Optional absent/null fields remain optional. A waiting/failed/completed receipt does not invent a PUT URL.
- Five malformed response shapes reject through actual `APIError.decoding` after exactly one injected execute.

The five negative controls each change one extracted source expression in a separate temporary file. They never modify the repository. The compile mutant must fail for the expected type error; each runtime mutant must compile successfully and then exit nonzero for its exact expected assertion:

| Mutation | Expected failure | Observed |
| --- | --- | --- |
| Typed `.key(...)` replaced with raw `String` | Swift `String` → `Idempotency` type mismatch | Compiler exit 1 |
| Saved key replaced with `.perAttempt` | `Restart header uses the saved operation UUID` | Runtime exit 1 |
| Consent `true` replaced with `false` | `Restart body is exactly explicit confirmation` | Runtime exit 1 |
| DTO retry interval discarded | `Snake-case retry_after_seconds survives the actual mapper` | Runtime exit 1 |
| DTO generation discarded | `Snake-case restart_generation survives the actual mapper` | Runtime exit 1 |

## Source-bound evidence

Passing full receipt: `/tmp/rendprop-upload-restart-wire-3x4wwsu7/receipt.json`.

Original-source rejection receipt: `/tmp/rendprop-upload-restart-wire-5w743hxo/receipt.json`.

Passing source tree was the iOS agent's **working** source over `804f9126bea28c43d2852f2a95f8a789cb5dc4d0`, not a claim that unmodified `804f912` passes. Each full input file was rehashed after execution; a parallel edit would invalidate the receipt. Re-run on the final integrated commit before assigning this result to a phone build.

| Bytes | SHA-256 |
| --- | --- |
| Actual `LiveAPIClient.swift` | `974577dd33dc1439e69fc4f62636a7b8ee208b61e74e175fd5d580595ef205f1` |
| Actual `APIClient.swift` | `4b0436d86539d1bf5f5ec541243ed76cf8c830ca1c13e5fa703911d6dbb79174` |
| Actual `DirectUploader.swift` | `1bdfb645b1606a16035e6f85f4d0262d53542a129eb4c9f44bc9704e836f0c1b` |
| Extracted Swift envelope | `c7224454ab73533ffe2626ae0456ea83b35a1b82e707bb7cd5c0277c987e85b0` |
| Compiled actual-wire binary | `18fb06d3a7dce25b44d686d060bf498c4c7f987bfec9a271088383271c9103f5` |
| Python harness | `879ca49a30a0618d530705677c6bff76e1954719f7512651d5a8214185a6c21c` |
| Swift assertions | `10e3676cf10dcccff43c3cb00a448d222ddee29e4e521dd61c46cca65713d0c6` |

Compiler: Apple Swift 6.3.1 (`swiftlang-6.3.1.1.2 clang-2100.0.123.102`), `-swift-version 5 -parse-as-library`, target `arm64-apple-macosx26.0`.

## Limits / integration action

This closes the gap where an engine fixture's mocked APIClient never compiled the actual wire adapter. It is **not** a full iOS build, live backend replay proof, HTTP status/401 refresh test, upload byte-transfer test, persistence/crash test, owner-switch proof, UI walk or TestFlight validation. The actual `execute` method and surrounding app actor/protocol context are intentionally not included; those still need the normal app build and separate integration tests. A valid synthetic response does not prove a deployed endpoint returns it.

Integrate the iOS implementation commit first or alongside this test commit, then run this harness on that exact final source before the release build. No existing CI file was changed in this bounded unit; the command can be added to the macOS pre-build gate by the integration owner.
