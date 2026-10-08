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
| Native UX follow-up after hosted failure | 147 assertions passed; all 15 compiled faulty variants rejected their intended case, including the original 12 controls and three account/setup admission controls. Only two test files changed; 178 production, project, asset, plist and UI-test inputs remain byte-identical to the reviewed source. |
| Apple authorization-code/session ownership | 29 assertions passed; five compiled fault controls rejected. |
| Actual API request execution | 16 assertions passed; three compiled fault controls rejected, including stale-bearer removal and forced-401 handoff preservation. |
| Offline credential isolation and production adoption | Six mock-isolation and 16 adoption assertions passed. |
| Full physical-SDK Release app | Both unsigned complete `RendpropSpatialTestFlight` and regular `Rendprop` builds succeeded. The regular compiler proof verifies the account sources without the lab or debug flags. This is compilation, not a phone test. |
| Rendered entry screen | One Release XCUITest passed on a fresh disposable iPhone simulator: Apple button visible, no Not now, Terms/Privacy/help visible. Exported screenshot and accessibility tree were retained; the screenshot was inspected. APIs were mocked and the Apple button was not tapped. |

The native source/test freeze is SHA-256 `09cb8c9450b92b8a75714c5acbf134002a851bb3cf0612e91b695433eb0e5818`. The SDK receipt is `5cc47b72dbb4da44d2db1249cf39a6d5dcada65fa49d2e97e31ced38afb7f6c2`; the rendered-screen receipt is `b71b0fee7e4d87ff8256375864d59d754f46dc859f0e9fa12da80f3a70d34d72`. Private local evidence retains actual extracted sources, compile/run logs, successful controls and earlier diagnostic failures. Both independent final reviews returned scoped GO after rehashing all 16 native/harness inputs and 377 retained proof files; their receipts are `470b3a630f148070003eb5cc7f38114328e70d949f759553e07d93613c728793` and `41ac2b7cbb55897fcde0471634ad4ab42f54b7095e49855137aced83a3349c39`. The postcompile iOS README update is explicitly documentation-only; frozen Swift, project and plist inputs are unchanged. Exact-source hosted CI remains pending at this source checkpoint.

The regular Release receipt is `a9a25ee6b361a7b2de4b2a225107f6b3b798664208b97f83c6276d29bf910c49`; its actual compiler-branch proof is `f9afb52097305f5fedfbffbfab11f1226b88cda2179b04d0582d14268031ea16`. Both bound the exact clean `942d1cc6` source with 252 native inputs unchanged. The first hosted run `37718971342` completed with 11 successful jobs and one failure: the native UX source test still expected the old `scenePhase` routing condition. Its retained actual log points to the stale literal at runner line 49. The production condition deliberately also requires account and onboarding admission. The harness-only follow-up checks that condition and exercises the actual deferred-route bodies with blocked-account and unfinished-onboarding cases. Its 147 assertions and 15 compiled fault controls passed; the original twelve mutation tuples and named failure oracles were preserved. The retained repair freeze is `1d142dc8e595a84e82762cc618603e859f9e08b6337a040eb0e76b1948535450`. A new complete hosted run is required before internal delivery; the failed run is preserved and is not accepted as release evidence.

The successor run `37720526905` was deliberately cancelled after a read-only scan found a later closed-fixture signature mismatch: its reel test double still exposed `signOut()` while the actual API body now calls `signOut(preservingAdoption: true)`. The second follow-up changes only that mock signature. The unchanged reel runner passed 89 regular assertions, 14 lab-dispatch assertions and all 13 original named compiled-fault controls. Its one-line repair freeze is `10c8188345e1b2368a2163aa42263e3951f3300936501e1d364ee43ecdd937ef`. The stub is not evidence of actual adoption-file preservation; that remains covered by the separate actual AuthStore/API tests above. Both superseded runs remain retained and unaccepted. The final complete hosted run and delivery are still pending.

Build **1.0.4 (49)** remains the last verified internal delivery at this checkpoint. This patch has not been delivered. Internal build-50 release helpers are prepared with source/CI admission still pending and archive/upload gates false; 54 closed helper checks passed in both normal and optimized Python. No new paid supplier tests, schema changes, credential rotation, trial funding or public App Store submission were performed. The separate [public-review draft](../appstore/account-first-review-draft-20261008.md) is unsubmitted; historical build-42 records remain preserved.

## Phone acceptance for the new build

- On a genuinely new install/account, verify that the Apple account screen appears before setup or Home. Cancel Apple sign-in once and confirm the account screen remains.
- Complete real Apple sign-in, finish business setup and reopen the app. Confirm the correct personal name, listings and workspace; compare with Studio using the same Apple identity.
- Sign out and confirm that private screens close. Sign back in to the same account and check saved listings, media and pending work.
- For an existing guest installation with saved work, verify adoption using the real Apple flow and confirm both the original files and recovered listing ownership.
- Open a team invite before sign-in and confirm it waits until sign-in and setup complete. Creating the account must not open a purchase sheet automatically.

These device checks are not established by simulator rendering or offline transport doubles.
