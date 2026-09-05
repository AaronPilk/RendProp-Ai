# HANDOFF-P5 — automated UI walk (XCUITest screenshots of every main screen)

Branch `launch-p5`. Nobody had ever run the app through an automated walk; this
adds one, so the owner can approve nine screenshots instead of nine manual taps.

**Everything here is additive.** No existing line of `project.yml` changed
(verified byte-for-byte), no shipped screen changed, and the test bundle is
never part of an archive.

---

## 1. What was built

| File | What it is |
|---|---|
| `apps/ios/project.yml` | **edited (append only)** — target `RendpropUITests` + an explicit shared scheme `Rendprop` |
| `apps/ios/Rendprop/Config.swift` | **edited** — `Config.isUITesting`; `makeAPIClient()` returns `MockAPIClient` under `-uiTesting` |
| `apps/ios/RendpropUITests/RendpropUITests.swift` | **new** — `testWalk()`, the nine-screenshot walk |
| `apps/ios/RendpropUITests/README.md` | **new** — how to run it, and the `xcresulttool` extraction recipes |
| `_bridge-cmd-uiwalk.sh` | **new** (worktree root, not under `apps/`) — the exact bash for the Mac bridge |

### The walk

| # | Attachment | Screen | Status today |
|---|---|---|---|
| 01 | `01-home` | Home dashboard | works |
| 02 | `02-add-home` | Add a home | works |
| 03 | `03-photo-studio` | AI Photo Studio on a real home | works |
| 04 | `04-reel-studio-voice` | Reel Studio, STEP 2 · ADD YOUR VOICE | needs 2 photos — see §5 |
| 05 | `05-settings` | Settings | works |
| 06 | `06-owner-console` | Owner console | needs the AuthStore hook — §3 |
| 07 | `07-routing` | AI routing | needs the AuthStore hook — §3 |
| 08 | `08-paywall` | Paywall sheet | skips itself until P2 lands |
| 09 | `09-health-probe` | Health after "Test all keys" | skips itself until P4 lands |

Every attachment is `lifetime = .keepAlways`. The test has **no assertions**:
`continueAfterFailure = true`, generous waits, and one
`XCTContext.runActivity(named:)` per step whose name records "SKIPPED: …" and
the reason. A missing control never costs the other screenshots.

Lookup order is always **identifier → visible label text → nothing**. Never
coordinates. The identifiers in §2 do not exist yet, so every step also matches
the real button titles read out of the source — the walk works before and after
those insertions land.

### Launch arguments (verified against the actual `@AppStorage` keys)

```
-uiTesting                                → Config.makeAPIClient() ⇒ MockAPIClient
-hasOnboarded YES                         → RendpropApp.swift  @AppStorage("hasOnboarded")
-space.type real_estate                   → RootTabView @AppStorage("space.type"); SpaceType.realEstate == "real_estate"
-appearance light                         → Appearance.light.rawValue == "light" (deterministic shots)
-ai.thirdPartyProcessing.consent.v1 YES   → AIConsent.storageKey
```

`-key value` pairs land in `UserDefaults`' `NSArgumentDomain`, which both
`@AppStorage` and `UserDefaults.standard.bool(forKey:)` read.

The consent argument is **not optional**: `PhotoStudioView` and `ReelStudioView`
both run `if await AIConsent.shared.ensureGranted() == false { dismiss() }`, so
without it the walk photographs a disclosure overlay and then an empty screen.

---

## 2. Accessibility identifiers — paste-ready (files I do not own)

All of these are one added line. None changes behaviour, layout or copy.

### `apps/ios/Rendprop/RendpropApp.swift`

**a) `home.addHome`** — `addHomeButton`, line 1840. Anchor:

```swift
        .buttonStyle(ScalePressStyle())
        .accessibilityLabel(Text("Add a \(noun)"))
    }
```
becomes
```swift
        .buttonStyle(ScalePressStyle())
        .accessibilityLabel(Text("Add a \(noun)"))
        .accessibilityIdentifier("home.addHome")
    }
```

**b) `home.listing.first`** — `homesList`, line 1801. Anchor (inside
`ForEach(Array(projects.prefix(3)))`):

```swift
                .buttonStyle(ScalePressStyle())
            }
            if projects.count > 3 {
```
becomes
```swift
                .buttonStyle(ScalePressStyle())
                // UI walk: same id on every row is intentional — XCUITest's
                // `firstMatch` takes the topmost, which is the newest home.
                .accessibilityIdentifier("home.listing.first")
            }
            if projects.count > 3 {
```
*(If you prefer per-row ids, switch the ForEach to
`ForEach(Array(projects.prefix(3).enumerated()), id: \.element.id) { index, listing in`
and use `index == 0 ? "home.listing.first" : "home.listing.\(index)"`. The walk
only needs the first.)*

**c) `home.feature.photos`** (and every sibling tile for free) —
`featureButton(_:)`, line 1874. Anchor:

```swift
        .buttonStyle(ScalePressStyle())
        .accessibilityLabel(Text("\(feature.actionTitle). \(feature.promise)"))
    }
```
becomes
```swift
        .buttonStyle(ScalePressStyle())
        .accessibilityLabel(Text("\(feature.actionTitle). \(feature.promise)"))
        .accessibilityIdentifier("home.feature.\(feature.rawValue)")
    }
```
Gives `home.feature.tour`, `home.feature.photos`, `home.feature.reel`,
`home.feature.floorPlan`, `home.feature.aerial`.

### `apps/ios/Rendprop/Screens/FlythroughDetailView.swift`

**d) `detail.photoStudio`** — `toolboxSection`, line 600. Anchor:

```swift
                NavigationLink { PhotoStudioView(listing: currentListing) } label: {
                    toolCard("AI Photo Studio", sample ? createFirst : "Sky · tidy · furniture",
                             "wand.and.stars", RPGradient.photo, ai: true, dimmed: sample)
                }
                .buttonStyle(ScalePressStyle())
                .disabled(sample)
```
becomes — add one line after `.disabled(sample)`:
```swift
                .disabled(sample)
                .accessibilityIdentifier("detail.photoStudio")
```

**e) `detail.reelStudio`** — same section, line 608 (the `intent: .reel` link):

```swift
                NavigationLink { PhotoStudioView(listing: currentListing, intent: .reel) } label: {
                    toolCard("Make a reel", sample ? createFirst : "Video + your voice",
                             "film.stack", RPGradient.reel, ai: true, dimmed: sample)
                }
                .buttonStyle(ScalePressStyle())
                .disabled(sample)
                .accessibilityIdentifier("detail.reelStudio")
```

Optional but useful — the same id on the reel card *inside* PhotoStudioView
(`reelCard`, line ~2563), because that is the card the walk actually taps:

```swift
        Button { showReelStudio = true } label: { reelCardFace }
            .buttonStyle(ScalePressStyle())
            .disabled(!canMakeReel)
            .accessibilityIdentifier("detail.reelStudio")
            .accessibilityLabel(Text(canMakeReel ? … ))
```

**f) `reel.step.voice`** — `stepVoiceCard`, line 4784. Anchor (the closing
modifiers of that `VStack`):

```swift
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var voiceModePicker: some View {
```
becomes
```swift
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityIdentifier("reel.step.voice")
    }

    private var voiceModePicker: some View {
```

### `apps/ios/Rendprop/Screens/SettingsView.swift`

**g) `settings.ownerConsole` + `admin.tab.routing`** — lines 229–241. Anchor:

```swift
                    NavigationLink {
                        AdminConsoleView()
                    } label: {
                        Label("Spend & providers", systemImage: "chart.bar.doc.horizontal")
                    }
                    // MARK: - router additions
                    NavigationLink {
                        AdminRoutingView()
                    } label: {
                        Label("AI routing", systemImage: "arrow.triangle.branch")
                    }
```
becomes
```swift
                    NavigationLink {
                        AdminConsoleView()
                    } label: {
                        Label("Spend & providers", systemImage: "chart.bar.doc.horizontal")
                    }
                    .accessibilityIdentifier("settings.ownerConsole")
                    // MARK: - router additions
                    NavigationLink {
                        AdminRoutingView()
                    } label: {
                        Label("AI routing", systemImage: "arrow.triangle.branch")
                    }
                    .accessibilityIdentifier("admin.tab.routing")
```
Note for whoever reads the contract: **routing is a sibling row of the console,
not a tab inside it**, and there are no tabs in `AdminConsoleView` — it is one
`List` of sections. `admin.tab.routing` / `admin.tab.health` keep the contract's
names; they mark rows/sections.

**h) `admin.tab.health`** — `AdminConsoleView.healthSection`, line 2396:

```swift
        } header: {
            Text("Health")
        } footer: {
```
becomes
```swift
        } header: {
            Text("Health")
                .accessibilityIdentifier("admin.tab.health")
        } footer: {
```

### Owned by other agents — the walk only consumes these

- **`settings.upgradePlan`** (P2) — on the "Upgrade plan" control inside
  Settings → **Plan & usage** (`usageSection`, `SettingsView.swift` ~line 429).
  The walk scrolls Settings looking for it for 3 s and skips step 08 otherwise.
- **`paywall.root`** (P2) — on the root view of the paywall sheet. The walk
  waits 7 s for it after tapping upgrade.
- **`admin.testAllKeys`** (P4) — the probe button in the Health section of
  `AdminConsoleView`. The walk scrolls the console for it, taps it, waits 5 s,
  screenshots, and skips step 09 otherwise.

---

## 3. AuthStore hook — REQUIRED for screenshots 06 and 07 (I do not own this file)

`Config.enableAuth == true`, so `AuthStore.init` sets `isSignedIn` from a
Keychain token the simulator does not have. With no session:

- Settings' **Plan & usage** shows "Sign in to see your plan…";
- `loadUsage()` returns early, so `resolveAdminAccess()` never runs;
- `showAdminConsole` stays `false` and **the whole Owner console section is not
  drawn** — steps 06, 07 and 09 have nothing to tap.

`MockAPIClient.me()` already returns `isAdmin: true` (`MockAPIClient.swift:136`),
so the admin half is solved. The missing half is the session.

**`apps/ios/Rendprop/Auth/AuthStore.swift`, line 150.** Anchor:

```swift
    init() {
        let hasToken = Self.storedAccessToken() != nil
        // Dev stub stays "signed in"; real auth gates on a persisted token.
        self.isSignedIn = Config.enableAuth ? hasToken : true
```
becomes
```swift
    init() {
        let hasToken = Self.storedAccessToken() != nil
        // Dev stub stays "signed in"; real auth gates on a persisted token.
        // UI WALK: `-uiTesting` makes every API client a MockAPIClient (see
        // Config.makeAPIClient), which answers every route with no token. Report
        // a session so Settings draws Plan & usage and the owner-console rows —
        // otherwise the walk photographs an empty screen. A launch argument can
        // only come from Xcode / `xcodebuild test`, never from a shipped build.
        self.isSignedIn = Config.isUITesting ? true : (Config.enableAuth ? hasToken : true)
```

One changed line. Nothing else in the file needs to move — `signOut()` at
line 272 can keep its current behaviour (the walk never signs out).

**Why this is safe:** all three `Config.makeAPIClient()` call sites
(`AppModel:60`, `UploadManager:182`, `AuthStore:313`) go through the same
factory, so under `-uiTesting` there is no `LiveAPIClient` anywhere in the
process. A "signed in" flag with a mock client cannot produce a real request,
and `AuthStore.currentAccessToken` still returns nil, so nothing could be
authorised even if one were attempted.

`hasOnboarded` needs no hook — `-hasOnboarded YES` works through the argument
domain, which is exactly what `@AppStorage("hasOnboarded")` reads.

---

## 4. Bridge command

`_bridge-cmd-uiwalk.sh` at the worktree root. It is `bash _bridge-cmd-uiwalk.sh`
and nothing else; it does not push, deploy or touch production.

Stages, each reporting its own exit code and never aborting the bridge
(`set -u -o pipefail`, the `.xcresult` path captured in `$RESULT`):

1. `cd ~/"Rendprop AI"/repo/apps/ios && xcodegen generate`
2. `xcrun simctl boot <udid> 2>/dev/null` + `bootstatus`
3. **seed two PNGs into the simulator's photo library** with
   `xcrun simctl addmedia` (this is what unlocks step 04 — see §5)
4. `xcodebuild test -project Rendprop.xcodeproj -scheme Rendprop -destination 'platform=iOS Simulator,id=CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E' -only-testing:RendpropUITests -derivedDataPath ~/"Rendprop AI"/_bridge/dd-ui -resultBundlePath "$RESULT" > /tmp/rp-ui.log 2>&1`
   then `echo TEST_EXIT=$?` and `grep -E "error:|Test Case|passed|failed" /tmp/rp-ui.log | tail -30`
5. export the attachments into `~/"Rendprop AI"/_bridge/out/shots/`
6. `ls -la` the PNGs

`-resultBundlePath` is timestamped (`walk-$(date +%s).xcresult`) because
`xcodebuild` refuses to overwrite an existing bundle.

### `xcresulttool` — both recipes

**Xcode 16+/26 (use this one):**
```bash
xcrun xcresulttool export attachments --path walk.xcresult --output-path ./shots
```
Writes every attachment plus a `manifest.json` mapping `exportedFileName` →
`suggestedHumanReadableName` (the names the test set: `01-home` …
`09-health-probe`). The script renames them from that manifest. Extra flags:
`--test-id`, `--only-failures`.

**Legacy (fallback branch in the script):** every pre-Xcode-16 verb now needs
`--legacy`:
```bash
xcrun xcresulttool get --legacy --format json --path walk.xcresult
xcrun xcresulttool export --legacy --type file --path walk.xcresult \
  --id <payloadRef id> --output-path 01-home.png
```
The ids live at `actions._values[].actionResult.testsRef.id` → each object's
`summaryRef.id` → `activitySummaries[].attachments._values[].payloadRef.id`.

**Reading a skip note:**
```bash
xcrun xcresulttool get test-results activities --path walk.xcresult \
  --test-id 'RendpropUITests/testWalk()'
```

---

## 5. Known gaps — which screenshots may be missing, and why

1. **04 `04-reel-studio-voice` is the fragile one.** Reel Studio's card is
   `.disabled(!canMakeReel)` and `canMakeReel` is `photos.count >= 2`
   (`FlythroughDetailView.swift:2554`). There is no other entry point that
   doesn't already require an AI-generated aerial. The walk therefore tries to
   add two photos through the real PHPicker; the bridge seeds the library with
   `xcrun simctl addmedia`. PHPicker is a separate process and this is the one
   step I would expect to flake. It fails soft: `SKIPPED: the "Make a reel" card
   is disabled…`. If the owner needs this screenshot reliably, the cheapest fix
   is a `-uiTesting` seed of two bundled images into
   `EnhancedPhoto.directory(for:)` on first appear — that is inside
   `FlythroughDetailView.swift`, which I do not own, so I have not written it.
2. **06 / 07 / 09 need the §3 AuthStore hook.** Without it the owner-console
   section is not drawn at all and three steps skip.
3. **08 and 09 skip until P2 and P4 land.** By design; they are one-line
   identifier contracts (§2) and cost nothing when absent.
4. **02 lands on `NewListingView`, not `StartProjectSheet`.** The contract
   assumed the big "Add a home" button raises the start-project sheet; in the
   code it is a `NavigationLink { NewListingView() }` (`RendpropApp.swift:1826`).
   Both screens are titled "Add a home"/"New Home", so the screenshot is still
   the right one — noting it so nobody thinks the walk took a wrong turn.
   `StartProjectSheet` *is* exercised on the way to step 03.
5. **Samples are not usable for step 03.** Every toolbox tool is
   `.disabled(sample)` on a seeded demo listing, so the walk creates a real home
   ("1 Walk Test Street") through the "Take photos" gate first. That home
   persists in the simulator between runs; `xcrun simctl erase <udid>` resets it.
6. **The walk writes to the simulator's Documents.** It creates one listing and,
   if photos were seeded, two image files. Nothing leaves the simulator.
7. **`captureScreenshotsAutomatically: false`** is set on the scheme's test
   action so the export directory contains the nine named PNGs instead of
   hundreds of per-step captures. Flip it in `project.yml` if a failure ever
   needs frame-by-frame evidence.

---

## 6. Owner (Aaron) — nothing to do

No App Store Connect change, no dashboard secret, no certificate. The UI test
target signs with the same `DEVELOPMENT_TEAM` (`5F5C5G25Y6`) and
`CODE_SIGN_STYLE: Automatic` as the app; a simulator build does not need a
provisioning profile at all.

---

## 7. Checks run

| Check | Result |
|---|---|
| `swiftc -parse RendpropUITests/RendpropUITests.swift` | exit 0 (XCTest symbols don't resolve on Linux; `-parse` is syntax only, as expected) |
| `swiftc -parse Rendprop/Config.swift` | exit 0 |
| `project.yml` — Python `yaml.safe_load` | parses; `targets: [Rendprop, RendpropUITests]`, `schemes: [Rendprop]` |
| `project.yml` — Node `js-yaml` (second parser) | same tree |
| `project.yml` prefix vs. original | byte-identical for all 56 original lines (`diff` clean) |
| `bash -n _bridge-cmd-uiwalk.sh` | clean |
| both embedded `python3` blocks | `compile()` clean |
| secret grep over the diff | no credential material — see below |

Secret grep `apikey|secret|token|password|Bearer|eyJ|sk-|SUPABASE_.*KEY` over the
full diff **and** every new file: the only hits are the *word* "token" in this
document's prose and in the quoted `AuthStore` snippet in §3. No key, no
credential, no new URL, no new endpoint. `Config.swift`'s existing anon-key
constant is outside the diff — the only lines added there are `isUITesting` and
the two-line guard in `makeAPIClient()`.

### XcodeGen keys used, with the ProjectSpec section each comes from

Checked against
`https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md`:

| Key | Section | Value used |
|---|---|---|
| `targets.<name>.type` | Target | `bundle.ui-testing` |
| `targets.<name>.platform` | Target | `iOS` |
| `targets.<name>.sources[].path` / `.excludes` | Target Source | `RendpropUITests`, excludes `README.md` |
| `targets.<name>.dependencies[].target` | Dependency | `Rendprop` |
| `targets.<name>.settings.base` | Settings | build settings map |
| `schemes.<name>.build.targets` | Scheme / Build | `Rendprop: all`, `RendpropUITests: [test]` (allowed values include `run`, `test`, `profile`, `analyze`, `archive`, `all`, `none`) |
| `schemes.<name>.run.config` | Scheme / Run | `Debug` (`storeKitConfiguration` is the sibling key the integrator adds) |
| `schemes.<name>.test.config` / `.targets` | Scheme / Test | `Debug`, `[RendpropUITests]` (targets may be a String or an object) |
| `schemes.<name>.test.captureScreenshotsAutomatically` | Scheme / Test | `false` |
| `schemes.<name>.profile.config` / `.analyze.config` / `.archive.config` | Scheme | `Release` / `Debug` / `Release` |

Two settings need explaining, because they exist only to defeat inheritance:
`INFOPLIST_FILE: ""` and `GENERATE_INFOPLIST_FILE: YES`. The project-wide
`settings.base` points **every** target at `Rendprop/Info.plist` with
`GENERATE_INFOPLIST_FILE: NO`; a test bundle must not use the app's plist, and
an inherited `INFOPLIST_FILE` beats the generator, so both are overridden at
target level. Nothing about the app target's plist changes.

### Not done / not touched

- The bridge was **not** run — I have no Mac and the contract says the
  integrator drives it. Every command in `_bridge-cmd-uiwalk.sh` is
  syntax-checked but unexecuted, and the walk has never been executed against a
  simulator. Treat the first bridge run as the real test; the skip notes in the
  `.xcresult` will say precisely which step needs attention.
- No file outside the five listed in §1 was created or modified.
