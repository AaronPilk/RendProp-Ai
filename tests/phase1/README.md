# Phase 1 regression tests

These are asserting tests, not the pre-existing screenshot walk. No production
Supabase, R2, AI provider, purchase, account deletion or credential is needed.

This folder name records the original audit phase, not the maturity of the whole
product. For current release evidence see
[the Studio deployment record](../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md)
and [iOS test guide](../../apps/ios/RendpropUITests/README.md). Camera, ARKit/LiDAR,
interruption and thermal acceptance require the owner's physical phone.

## Offline production-source concurrency tests

`node --test tests/phase1/formatters-runtime.test.mjs tests/phase1/duplicate-listing-snapshot.test.mjs`
compiles actual production formatters, capture metadata and persistence code,
plus mechanically extracted review labels and the sync binding guard. It checks
nonfinite/out-of-range numbers and duplicate saved IDs without dropping rows or
media. Deliberate assertion failures and three unsafe conversion/guard mutants
must fail; the mutants reproduce Swift traps. These executable checks do not
replace the Release SwiftUI detail tests described in the iOS test guide.

Run `bash tests/phase1/run-unit.sh` from this worktree. This compiles the real
`Auth/SessionConnection.swift` with the Swift test entry point. It asserts
single-flight retry, continuation of the original four waiting actions,
independent cancellation, generation replacement, and waking an existing retry
delay. A ten-second watchdog fails the process if a continuation never resumes.

The same gate compiles the complete production `CoachModel.swift` and
`CoachAPI.swift` with `CoachOfflineTests.swift`. The test calls the actual
`CoachOffline.answer` matcher: five account-question variants, existing/empty
project state, unrelated MLS/next-step responses, and the anonymous-account
deletion explanation. It runs a deliberate exit-1 assertion before trusting
the 37 positive assertions. Only unrelated app types are inert test stand-ins;
API, analytics, purchases, consent and disk-backed app-state access trap if
called. This is an offline response check, not CoachView/consent UI or live
Supabase publication/deletion verification. No iOS simulator or Xcode app build
is launched by this portable gate.

It also executes `run-coach-privacy.sh`: the full production model makes scripted
offline-to-online sends, then resends a deliberately old/provider-echoed address
bubble after a cached listing rename. The 32 assertions cover transcript redaction,
local-only bubbles, scoped project/action IDs, missing workspace, and account,
workspace, revision and industry changes during consent/provider awaits. Four
separately compiled source mutants must fail their intended runtime assertions.
Unrelated app/provider boundaries are inert; no real network, credentials or
customer files are used.

Server knowledge is independently executable without runtime permissions or
downloads:

```sh
deno test --cached-only --deny-net --deny-env --deny-run --allow-read --deny-write services/supabase/functions/coach/
```

The new `knowledge_test.ts` imports only local production knowledge/formatter
code and uses no third-party test dependency. Existing action tests need their
already-cached pinned Deno standard-library assertions; absent cache fails rather
than downloading or skipping. This does not invoke the Coach endpoint or an LLM.

## Actual simulator screens, failed identified-refresh sockets, automatic recovery

Run `bash tests/phase1/run-network.sh`. Requires Xcode, its iOS 26.4 simulator
runtime, Node, and ffmpeg on PATH. Port 18765 must be free. The script creates a
NEW simulator; never repoint these fixture tests at a device with customer data.
It shuts down that simulator and stops its own loopback server afterward, but
retains the simulator, logs, video fixture, DerivedData and result bundle.

The script intentionally does not deploy anything. Its last statement is
`exit "$FAIL"`; a compiler error, malformed control JSON, unavailable test server,
missing button, failed assertion or xcodebuild failure is a nonzero exit.

`SessionNetworkFlow.swift` renders the real RenderStatusView, PhotoStudioView,
AerialIntroSheet and ReelStudioView. The Debug-only fixture root seeds a local
identified account, listing and media; it does not substitute an action trampoline for the actual
buttons. The fixture uses the ordinary token exchange and refresh methods.
The test configuration restricts its backend URL to `http://127.0.0.1`,
uses a synthetic publishable key and a different Keychain namespace per test,
and disables the screenshot suite's pretend signed-in state for this mode.
The overrides are unavailable in Release or on physical devices. This suite
requires **Debug**; the separate detail-metadata fixture tests can use Release.
Simulator tests use local ad hoc signing so the real AuthStore can access its
isolated Keychain. An unsigned/linker-only app is rejected by Keychain with
`errSecMissingEntitlement`; that is a test setup failure, not a token failure.

The server actually destroys identified-token refresh TCP connections until the test restores
them through a separate control endpoint. Before restoration, each test asserts
that refresh was attempted, one identified test account was admitted, zero
refreshes succeeded, zero guest signups occurred, the feature was not submitted,
connection retry is visible, and no Apple sign-in button is present. After
restoration there is **no second feature tap**. Tests assert one successful
single-flight refresh of the same identified account, zero guest signups,
expected feature-request counts, and the real success screen:

- Publish: one request, then **Share your link**.
- Photo: two photos in one batch, two edit requests, then **2 photos changed**.
- Aerial: one submission, polling/download, then **Aerial ready**.
- Reel: two selected photos, two submissions, polling/download/local composition,
  then **Your reel is ready**.

Provider responses and media are fixtures. Original/poster upload attempts receive
an intentional fast 503 because they are best-effort and storage is outside this
session-gate test. This verifies the actual app's identified refresh/feature/control flow and
local composition, **not** deployed Supabase settings, provider semantics, storage
integrity, billing caps, StoreKit Sandbox, or App Review approval.

## Diagnostic SDK reproduction

`VideoProbe.swift` contrasts an AVAssetTrack whose parent asset goes out of scope
with one whose parent is kept alive. Compile with `xcrun swiftc -parse-as-library`
and pass a valid local mp4. This is an SDK lifetime diagnostic, not a replacement
for the real Reel Studio regression test. The SDK's AVAssetTrack.h declares its
asset reference weak. The production composer now retains each source asset
through insertion/export.

## Boundaries

The existing `-uiTesting` screenshot suites are not made safe generally by this
new mode. Their historical Keychain/direct-network findings require checking the current
[iOS test guide](../../apps/ios/RendpropUITests/README.md) before choosing a suite.
Do not use those suites with real credentials as substitute verification.
These tests also do not certify optional Apple adoption, a paid restore, account
deletion, or all interactions during an unrelated workspace switch.
