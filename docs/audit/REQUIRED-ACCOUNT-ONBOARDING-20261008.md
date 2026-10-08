# Required account before onboarding

The owner requested that account creation or sign-in be the first step after downloading Rendprop. Previously, launch silently created a guest session and `hasOnboarded` alone selected business setup or Home. The source follow-up requires an identified account before either screen.

## User flow

1. New and signed-out users see **Welcome to Rendprop** and the native Apple account button. It creates an account or signs in to an existing one. There is no **Not now** or dismissal route. Terms, Privacy and help remain accessible.
2. After sign-in, unfinished business setup continues; otherwise Home opens. Invite links, notifications and upgrade screens wait until both account admission and setup are complete.
3. Cancelling Apple sign-in keeps the entry screen visible. Signing out closes private app presentations and returns there. A saved identified account can still use local work offline; a new sign-in requires connectivity.

The account step does not start an Apple trial, purchase or new subscription. Existing receipt and Restore paths retain their separate funding and identity checks. No plan price, allowance, server flag or provider route is changed here.

## Recovery and boundaries

Startup and foreground activation no longer mint anonymous accounts. Previously captured guest files and accepted upload journals are retained for the existing verified Apple adoption flow. A forced session invalidation preserves prepared handoff credentials; deliberate Sign out, Clear local data and Delete account retain their explicit policies.

Cached identity admission validates session shape, the UUID subject and the anonymous claim's type. Actual server requests still require a fresh credential and server verification; a parsed local JWT is not a signature verifier or a grant of server authority. The account subject controls remembered identity, and scheduling expiry cannot extend actual JWT expiry. A refresh for another account cannot replace the current account.

Offline UI fixtures are explicitly limited to the simulator. The required-screen fixture makes admission stricter, while retaining mocked APIs and avoiding host credentials. Physical Release builds do not accept those fixture switches.

## Validation checkpoint

The native source is frozen. Both independent reviewers identified concrete integration issues during review: stale remembered account/expiry metadata, an inherited expired bearer remaining on an API request, and forced API-401 sign-out discarding guest recovery credentials. All four paths were corrected, with compiled controls that remove the corresponding guard and must fail the unchanged checks.

| Check | Actual result |
| --- | --- |
| Account/session/refresh/deferred-route admission | 50 assertions passed; all 12 deliberately broken compiled variants were rejected. |
| Phase 1 regression discovery | 35/35 passed, zero skips. |
| Apple authorization-code/session ownership | 29 assertions passed; five compiled fault controls rejected. |
| Actual API request execution | 16 assertions passed; three compiled fault controls rejected, including stale-bearer removal and forced-401 handoff preservation. |
| Offline credential isolation and production adoption | Six mock-isolation and 16 adoption assertions passed. |
| Full physical-SDK Release app | Unsigned complete `RendpropSpatialTestFlight` build succeeded with frozen input hashes unchanged. This is compilation, not a phone test. |
| Rendered entry screen | One Release XCUITest passed on a fresh disposable iPhone simulator: Apple button visible, no Not now, Terms/Privacy/help visible. Exported screenshot and accessibility tree were retained; the screenshot was inspected. APIs were mocked and the Apple button was not tapped. |

The native source/test freeze is SHA-256 `09cb8c9450b92b8a75714c5acbf134002a851bb3cf0612e91b695433eb0e5818`. The SDK receipt is `5cc47b72dbb4da44d2db1249cf39a6d5dcada65fa49d2e97e31ced38afb7f6c2`; the rendered-screen receipt is `b71b0fee7e4d87ff8256375864d59d754f46dc859f0e9fa12da80f3a70d34d72`. Private local evidence retains actual extracted sources, compile/run logs, successful controls and earlier diagnostic failures. Both independent final reviews returned scoped GO after rehashing all 16 native/harness inputs and 377 retained proof files; their receipts are `470b3a630f148070003eb5cc7f38114328e70d949f759553e07d93613c728793` and `41ac2b7cbb55897fcde0471634ad4ab42f54b7095e49855137aced83a3349c39`. The postcompile iOS README update is explicitly documentation-only; frozen Swift, project and plist inputs are unchanged. Exact-source hosted CI remains pending at this source checkpoint.

Build **1.0.4 (49)** remains the last verified internal delivery at this checkpoint. This patch has not been delivered. Internal build-50 release helpers are prepared with source/CI admission still pending and archive/upload gates false; 54 closed helper checks passed in both normal and optimized Python. No new paid supplier tests, schema changes, credential rotation, trial funding or public App Store submission were performed. The separate [public-review draft](../appstore/account-first-review-draft-20261008.md) is unsubmitted; historical build-42 records remain preserved.

## Phone acceptance for the new build

- On a genuinely new install/account, verify that the Apple account screen appears before setup or Home. Cancel Apple sign-in once and confirm the account screen remains.
- Complete real Apple sign-in, finish business setup and reopen the app. Confirm the correct personal name, listings and workspace; compare with Studio using the same Apple identity.
- Sign out and confirm that private screens close. Sign back in to the same account and check saved listings, media and pending work.
- For an existing guest installation with saved work, verify adoption using the real Apple flow and confirm both the original files and recovered listing ownership.
- Open a team invite before sign-in and confirm it waits until sign-in and setup complete. Creating the account must not open a purchase sheet automatically.

These device checks are not established by simulator rendering or offline transport doubles.
