# Rendprop iOS UI tests

This target contains screenshot walks **and** assertion-based integration tests.
A passing screenshot walk can still contain skipped steps. Read its activity
notes and inspect the actual attachments before accepting a screen. No
simulator test validates a camera, LiDAR, AR tracking or real-house coverage.

The [22 September phone receipt](../../../docs/handoff/CLAUDE-LIVE-DELIVERY-20260922.md)
records internal TestFlight 1.0.3 (31). The
[24 September Studio deployment](../../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md)
did not ship another iOS binary. Tests in source are not evidence that the owner
has received those changes.

## Choose the right case

| Case | What it covers | Setup / limits |
| --- | --- | --- |
| `RendpropUITests/testWalk` | Home, Add a home, Photo Studio, Reel Studio voice, Settings, owner console, routing, paywall and health screenshots (`01`–`09`) | Mock API. Missing controls are noted and skipped. Reel entry needs photos. |
| `ReviewerWalk/testReviewerWalk` | Onboarding, samples, profile, legal, deletion confirmation and AI consent (`r01`–`r11`) | Fresh app container. Required screenshots are asserted; sign-in `r10` is excluded for the mock identified session. Cancel is the only deletion action. |
| `ReviewerWalk/testAIConsentDecisions` | Focused real consent-sheet path, actions and granted state | Assertions require all three captured consent states; no AI edit. |
| `ReviewerWalk/testAskAILabelOnLongTitle` | Ask AI geometry/accessibility and opening Coach from a long-title sample | Assertions plus screenshots; no provider call. |
| `StoreShots/testStoreShots` | Marketing screenshot capture, including industry variants, reels, leads and hosted demo surfaces | Seed listing photos; hosted demo requires network. No actual AI edit, purchase or publication. |
| `PaywallShot/testPaywallShot` | Monthly, yearly and legal purchase UI | Local `SKTestSession` products; never presses Buy. Empty-price capture is not a deliverable. |
| `IndustryWalk` | Six business types (`testRealEstate`, `testVenue`, `testRestaurant`, `testRetail`, `testFitness`, `testOther`) | Screenshot/activity checks; inspect `CHECK FAIL` and `SKIPPED` notes. |
| `GuideShot`, `CoachShot`, `BuildFourteenShots` | Guide progress, mock Coach reply/actions, onboarding/plan banners and Team entry | Historical focused screenshot fixtures. Team/hosted screens may attempt their own requests; a UI mock flag is not a network firewall. |
| `OnboardingTour` | Recorded mock onboarding/product walkthrough | `bridge-cmd-onboardingtour.sh`; optional local media and render mode. Not a camera recording. |
| `SpatialCaptureIntegrationTests` | Lab navigation, honest unsupported controls and no export without capture | Simulator is expected to reject capture. |
| `SpatialProductIntegrationTests` | Listing-scoped 3D card, runtime-off hiding and unsupported capture state | Mock/synthetic fixtures; does not produce a real room. |
| `CaptureRecoveryTests` | Relaunch, joining a seeded saved take and opening original/part export sheets | Requires the isolated synthetic recovery setup below; does not write to a selected share destination. |
| `ProductionPlanUITests` | Photo-first property plan, local checklist persistence, no false cloud-save claim | Mock, no camera, upload or paid provider. |
| `SessionNetworkFlow` | Publish/photo/aerial/reel actions resume once after session-network recovery | Debug loopback server at `127.0.0.1:18765`, fixture control endpoints and a disposable simulator required. |

## Mock and local network behavior

Most walks launch with:

```text
-uiTesting
-hasOnboarded YES
-space.type real_estate
-appearance light
-ai.thirdPartyProcessing.consent.v2 YES
```

`Config.makeAPIClient()` then returns `MockAPIClient` and `AuthStore` exposes a
mock identified session. The old instruction to add an AuthStore hook is
obsolete: the hook is already implemented. Mock API results are fixtures, not
real AI outputs or live customer data. Do not use an existing customer-signed-in
simulator: separate clients and hosted WebViews are not globally blocked by
`-uiTesting`, and account deletion must never be confirmed in a screenshot walk.

`ReviewerWalk` omits `hasOnboarded` for its full walk and explicitly sets consent
to `NO`, real-estate identity and light appearance. Its two focused tests skip
onboarding. Use a new simulator/app container for a genuine first-run walk;
persisted onboarding completion otherwise changes the path.

`SessionNetworkFlow` adds `-sessionNetworkTesting`, which takes precedence over
the mock only in Debug. `RENDP_TEST_URL` must be loopback HTTP; the case expects
`/__control/reset`, `state` and `unblock` at port 18765. It exercises actual
local HTTP recovery, not Supabase or Apple sign-in. Do not select this case
without its fixture server.

## Run a focused case locally

The source of truth is [project.yml](../project.yml). The committed project now
contains the UI target; regenerate when source membership changes, and review
the resulting diff in an isolated checkout. Choose an available disposable
simulator rather than copying a UUID from a historical receipt:

```bash
cd apps/ios
xcodegen generate --spec project.yml
xcrun simctl list devices available
# Set this to the UUID of the disposable simulator selected above.
TEST_SIMULATOR_UDID='<simulator UUID>'
xcrun simctl boot "$TEST_SIMULATOR_UDID"
xcrun simctl bootstatus "$TEST_SIMULATOR_UDID" -b

xcodebuild test \
  -project Rendprop.xcodeproj \
  -scheme Rendprop \
  -destination "platform=iOS Simulator,id=$TEST_SIMULATOR_UDID" \
  -only-testing:RendpropUITests/ProductionPlanUITests \
  -resultBundlePath "/tmp/rendprop-production-plan-$(date +%Y%m%d-%H%M%S).xcresult"
```

Replace `-only-testing` with one case from the table after satisfying its
fixture needs. A result-bundle path must not already exist. Do not treat a
whole-target run without recovery/network fixtures as meaningful acceptance.

Saved-take recovery has its own
[fixture and source-preservation procedure](../../../tools/audit/call-20260919/join/RECOVERY-UI.md).
It uses a new simulator, generated color clips, an ordered journal and denied
camera/microphone access. Verify original hashes afterward.

## Existing Mac bridge scripts

The `bridge-cmd-*.sh` scripts are legacy owner-machine recipes. Most set
`ROOT="$HOME/Rendprop AI"` and operate on **`$ROOT/repo`**, even when invoked from
another checkout. Several use a historical simulator UUID; the store/paywall
scripts find or create “Store 6.9”. Inspect the selected checkout and simulator
before using one. Do not point a reset/uninstall step at a phone or an existing
simulator containing useful state.

| Script | Output under `~/Rendprop AI/_bridge/out/` |
| --- | --- |
| `bridge-cmd-uiwalk.sh` | `shots/` screenshots |
| `bridge-cmd-reviewerwalk.sh` | `reviewerwalk/`; uninstalls the app first |
| `bridge-cmd-storeshots.sh` | `storeshots/`; seeds photos and checks 1320 × 2868 size |
| `bridge-cmd-paywallshot.sh` | `paywallshot/`; copies valid monthly PNG to the bridge checkout |
| `bridge-cmd-industrywalk.sh` | `industrywalk/`, `checks.txt`, activity logs; `SIM_UDID` and `KEEP_APP` options |
| `bridge-cmd-onboardingtour.sh` | Product walkthrough recording; inspect script options before capture |

These scripts report per-stage exit codes and preserve evidence; do not assume
that their final shell exit alone certifies every screenshot or assertion.

## Export evidence

```bash
xcrun xcresulttool export attachments \
  --path /tmp/your-run.xcresult \
  --output-path /tmp/your-run-shots

xcrun xcresulttool get test-results activities \
  --path /tmp/your-run.xcresult \
  --test-id 'ReviewerWalk/testReviewerWalk()'
```

Use the exported manifest to map filenames to attachment names. Screenshots
have `.keepAlways` lifetime. Review failures, missing required captures,
`SKIPPED`, `FALLBACK`, `CHECK FAIL` and `STOREKIT` notes. The bridge scripts also
contain a legacy `xcresulttool ... --legacy` export fallback.

## StoreKit screenshots and real-device checks

`PaywallShot` loads [Rendprop.storekit](../Rendprop.storekit) through
`SKTestSession` before launching, sets USA / en_US, clears synthetic
transactions and disables purchase dialogs. The configuration is bundled in
the test target only; the scheme's Run-action StoreKit configuration alone
does not provide products to `xcodebuild test`.

`p01-paywall-monthly` is the review deliverable; `p02-paywall-yearly` and
`p03-paywall-legal` are supporting evidence. `p01-paywall-EMPTY` must never be
uploaded. These are local product/eligibility fixtures, not a successful
StoreKit sandbox purchase or proof of current App Store prices. See the
[IAP review procedure](../../../docs/appstore/iap-review/README.md) and
[store screenshot recipe](../../../docs/appstore/screenshots/README.md).

The owner still needs the [real-phone agency checklist](../../../docs/studio/agency-production-workflow.md#acceptance-on-a-real-phone)
for capture, interrupted uploads, phone/desktop sync and finished picture/audio.
