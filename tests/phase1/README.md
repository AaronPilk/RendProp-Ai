# Phase 1 regression tests

These are asserting tests, not the pre-existing screenshot walk. No production
Supabase, R2, AI provider, purchase, account deletion or credential is needed.

## Offline production-source concurrency tests

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

Server knowledge is independently executable without runtime permissions or
downloads:

```sh
deno test --cached-only --deny-net --deny-env --deny-run --deny-read --deny-write services/supabase/functions/coach/
```

The new `knowledge_test.ts` imports only local production knowledge/formatter
code and uses no third-party test dependency. Existing action tests need their
already-cached pinned Deno standard-library assertions; absent cache fails rather
than downloading or skipping. This does not invoke the Coach endpoint or an LLM.

## Actual simulator screens, failed signup sockets, automatic recovery

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
listing and media; it does not substitute an action trampoline for the actual
buttons. The test configuration restricts its backend URL to `http://127.0.0.1`,
uses a synthetic publishable key and a different Keychain namespace per test,
and disables the screenshot suite's pretend signed-in state for this mode.
The overrides are unavailable in Release.

The server actually destroys signup TCP connections until the test restores
them through a separate control endpoint. Before restoration, each test asserts
that signup was attempted, no session was issued, the feature was not submitted,
connection retry is visible, and no Apple sign-in button is present. After
restoration there is **no second feature tap**. Tests assert one issued anonymous
session, expected feature-request counts, and the real success screen:

- Publish: one request, then **Share your link**.
- Photo: two photos in one batch, two edit requests, then **2 photos changed**.
- Aerial: one submission, polling/download, then **Aerial ready**.
- Reel: two selected photos, two submissions, polling/download/local composition,
  then **Your reel is ready**.

Provider responses and media are fixtures. Original/poster upload attempts receive
an intentional fast 503 because they are best-effort and storage is outside this
session-gate test. This verifies the actual app's signup/feature/control flow and
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
new mode. Their old Keychain/direct-network issues remain a Phase 3 finding.
Do not use those suites with real credentials as substitute verification.
These tests also do not certify optional Apple adoption, a paid restore, account
deletion, or all interactions during an unrelated workspace switch.
