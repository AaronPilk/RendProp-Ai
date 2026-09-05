# RendpropUITests — the automated UI walk

One test, `RendpropUITests.testWalk()`, drives a booted simulator through every
main screen and attaches a screenshot of each to the result bundle. It exists so
the owner can look at nine PNGs and say "yes, ship it" without opening Xcode.

| # | Attachment | Screen |
|---|---|---|
| 01 | `01-home` | Home dashboard |
| 02 | `02-add-home` | Add a home (New Home / the "name your first home" gate) |
| 03 | `03-photo-studio` | AI Photo Studio for a real home |
| 04 | `04-reel-studio-voice` | Reel Studio, scrolled to **STEP 2 · ADD YOUR VOICE** |
| 05 | `05-settings` | Settings |
| 06 | `06-owner-console` | Owner console (spend · providers · usage · health) |
| 07 | `07-routing` | Owner console → AI routing |
| 08 | `08-paywall` | Paywall sheet (via `settings.upgradePlan` in Settings) |
| 09 | `09-health-probe` | Health section after "Test all keys" (`admin.testAllKeys`) |

Every screenshot is `lifetime = .keepAlways`, so it survives a passing run.

## What the walk assumes

The app is launched with these arguments (`-key value` pairs land in
`UserDefaults`' argument domain, which `@AppStorage` reads):

```
-uiTesting                                   → Config.makeAPIClient() returns MockAPIClient
-hasOnboarded YES                            → skip the intro
-space.type real_estate                      → the Homes/real-estate identity
-appearance light                            → deterministic screenshots
-ai.thirdPartyProcessing.consent.v1 YES      → skip the Guideline 5.1.2(i) overlay
```

`-uiTesting` is the important one: the walk NEVER talks to the live backend, so
no screenshot can contain a real customer, a real share link or a real spend
figure. `MockAPIClient.me()` reports `isAdmin: true`, which is what makes the
owner console reachable offline.

Two things outside this folder decide whether steps 04–09 produce a PNG:

1. **A signed-in session.** Settings only draws the owner-console rows when
   `AuthStore.shared.isSignedIn` is true, and with `Config.enableAuth == true`
   that needs a Keychain token the simulator does not have. The one-line
   `AuthStore` hook is written out in `HANDOFF-P5.md` (§ AuthStore hook) — it is
   not applied here because this agent does not own that file.
2. **Two photos in the simulator's library.** Reel Studio's card is disabled
   until the home has two photos. The bridge script seeds them with
   `xcrun simctl addmedia`; without them step 04 skips itself with a note.

Steps skip rather than fail. `continueAfterFailure = true`, no assertion in the
walk, and each step is an `XCTContext.runActivity` whose name records what
happened — so a missing paywall never costs you the other eight screenshots.

## Run it locally

`xcodegen generate` is NOT optional. `Rendprop.xcodeproj/project.pbxproj` is
committed and lists its sources individually; it contains neither the
`RendpropUITests` target nor the new `Screens/AdminFunnelView.swift` and
`Screens/AdminProbeAPI.swift`. Skip the generate step and `xcodebuild` fails
with "scheme has no test action" or "Cannot find AdminFunnelView in scope".

```bash
cd apps/ios
xcodegen generate
xcrun simctl boot CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E 2>/dev/null

xcodebuild test \
  -project Rendprop.xcodeproj \
  -scheme Rendprop \
  -destination 'platform=iOS Simulator,id=CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E' \
  -only-testing:RendpropUITests \
  -resultBundlePath /tmp/walk.xcresult
```

`-resultBundlePath` must not already exist — `xcodebuild` refuses to overwrite
one. Use a timestamped name (the bridge script does).

To watch it, open the Simulator app first; the walk runs in the foreground.

## Run it on the Mac build bridge

Use `apps/ios/RendpropUITests/bridge-cmd-uiwalk.sh` — it does xcodegen → boot → seed
photos → test → export → `ls` in one block, and reports each stage's exit code
without aborting the bridge.

## Getting the PNGs out of the `.xcresult`

### Xcode 16 and later (this is the one to use on Xcode 26.4)

```bash
xcrun xcresulttool export attachments \
  --path /tmp/walk.xcresult \
  --output-path ./shots
```

That writes every attachment into `./shots` plus a `manifest.json` describing
them. The exported files are named by the tool, not by the test, so map them
back to `01-home` … `09-health-probe` with the manifest — each entry carries an
`exportedFileName` and the name the test gave it
(`suggestedHumanReadableName`). `bridge-cmd-uiwalk.sh` does that rename for
you. Useful extra flags: `--test-id <identifier>` for one test, `--only-failures`
to export only failed tests' attachments.

### Legacy flow (still works, and is the fallback in the bridge script)

Every pre-Xcode-16 `xcresulttool` verb now needs `--legacy`:

```bash
# 1. dump the object graph and find the attachment payload ids
xcrun xcresulttool get --legacy --format json --path /tmp/walk.xcresult

# 2. pull one attachment out by its payloadRef id
xcrun xcresulttool export --legacy --type file \
  --path /tmp/walk.xcresult \
  --id <payloadRef id> \
  --output-path 01-home.png
```

The graph is nested: `actions._values[].actionResult.testsRef.id` → that object's
`summaryRef.id`s → each summary's `activitySummaries[].attachments._values[]`,
where `name` is `01-home` and `payloadRef.id._value` is the id to export.
`bridge-cmd-uiwalk.sh` walks exactly that path in its fallback branch.

Without `--legacy` those two verbs fail on Xcode 16+ with a deprecation error.

### Reading the skip notes

If a PNG is missing, the reason is in the bundle as an activity name:

```bash
xcrun xcresulttool get test-results activities \
  --path /tmp/walk.xcresult --test-id 'RendpropUITests/testWalk()'
```

Look for an activity whose name starts with `SKIPPED:` — it says exactly which
control was not found.
