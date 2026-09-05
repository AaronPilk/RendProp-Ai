# App Store Review readiness — Rendprop v1.0 (build 1)

Audited **2026-09-05** against the App Store Review Guidelines as published at
<https://developer.apple.com/app-store/review/guidelines/> (fetched the same day), on branch
`launch`. Scope: the iOS app binary, its `Info.plist`, `PrivacyInfo.xcprivacy`, and the shipped
store copy in `docs/appstore/metadata/en-US/`.

App shape, for context: iPhone-only, iOS 16+, portrait. Sign in with Apple is the only login and
is required only to publish; everything else works signed out. StoreKit 2 auto-renewable
subscriptions. First-party analytics, MetricKit, SKAdNetwork; no IDFA, no ATT prompt, no
third-party SDK of any kind.

**Verdict: ready to submit**, after the fixes below. Two of them were genuine first-submission
rejection risks (§3.1.1/3.1.3 external purchase CTAs, and §2.1(b) the paywall being unreachable
for a reviewer who never signs in). Everything else was already in good shape — the codebase
carries its own guideline reasoning in comments and it mostly holds up.

---

## 1. Pass/fail table

| Guideline | Verdict | Evidence |
|---|---|---|
| **1.2** User-generated content | **Pass** | No in-app feed, no user-to-user content, no way to browse another user's tours. The only inbound content is a contact-form submission from a web visitor addressed to the account holder — an inbox, not a social graph. Report path + published contact ship anyway: `Screens/SettingsView.swift:293-300` ("Contact support", "Report a problem with AI content or a tour" → `aaron@pilk.ai`, `SettingsView.swift:63`). |
| **2.1(a)** Completeness — placeholders | **Pass** (after fix) | Full-corpus grep for `coming soon` / `beta` / `TODO` / `placeholder` / `lorem` / `dummy` / `stub` / `debug` / `test mode` in `Text(` `Label(` `Button(` `navigationTitle(` returns nothing user-visible. The one `Text("COMING SOON")` (`RendpropApp.swift:2077`) sits in `tutorialsSection`, gated by `Config.showTutorials == false` (`RendpropApp.swift:1593`, `Config.swift:101`) — dead code, never rendered. Four softer forward-promise strings ("email alerts are coming", "photo upload is coming") **removed** — see §2, fix 3. |
| **2.1(a)** Completeness — functional URLs | **Pass** | Every user-visible URL returns HTTP 200 (checked live 2026-09-05): `rendprop.com/`, `/support`, `/privacy`, `/terms`, `/pricing`, `/f/estate-demo`, Apple's standard EULA, and the three "More from us" partner links (`pilk.ai`, `wsmlending.com`, `tractrealestate.com` — `RendpropApp.swift:2098-2103`). |
| **2.1(a)** Completeness — no crash on launch | **Pass** | No force-unwrap of any network or optional result anywhere in the target. The only two `!`/`as!` in the app are `layer as! AVCaptureVideoPreviewLayer` (`Capture/GuidanceOverlays.swift:10`, a `layerClass` override — cannot fail) and a static `mailto:` fallback (`SettingsView.swift:68`). Launch does not touch the network: `RendpropApp.swift:1446-1451` renders onboarding or `RootTabView` off `@AppStorage`, and `Analytics.start` (`:1466`) is fire-and-forget with backoff. |
| **2.1(b)** IAP visible to the reviewer | **Pass** (after fix) | Was a **fail**: the "Upgrade plan" row was wrapped in `if auth.isSignedIn`, and the review notes correctly tell the reviewer sign-in is only needed to publish. Every other paywall entry point is a server `402`, which a signed-out user can never receive (they get `401`). Net effect: a reviewer following the documented demo flow could not reach the paywall at all. **Fixed** — see §2, fix 2. Paywall now reachable signed-out at Settings → Plan & usage → Upgrade plan (`SettingsView.swift:475`). |
| **2.3.1** Accurate metadata, no hidden features | **Pass** | Every claim in `description.txt` is backed by shipped code — see §3 for the claim-by-claim trace. No hidden or dormant features: the owner console is server-gated (below), tutorials are flag-gated off. |
| **2.3.3** Screenshots show the app in use | **Human** | Screenshots are not in the repo. See §4. |
| **2.3.8** Metadata appropriate for 4+ | **Pass** | Name "Rendprop", subtitle, keywords, promo text all neutral. Sample listings are fictional and suffixed "(Sample)" (`Models/Listing.swift:597-630`). Age-rating answers in `docs/appstore/age-rating.md` target 4+ and match the content. |
| **2.5.1** Public APIs only | **Pass** | No `performSelector`, `NSSelectorFromString`, `valueForKey:` on system objects, `dlopen`, `objc_getClass`, or `_UI*` symbols anywhere in the target. Everything used is public: `RoomPlan`, `MetricKit` (`MXMetricManagerSubscriber`, `Analytics/CrashReporter.swift:31`), `SKAdNetwork.updatePostbackConversionValue` (`Analytics/Attribution.swift:119,131`), StoreKit 2, `SFSpeechRecognizer`, `CoreLocation`, `CoreMotion`, `AVFoundation`. |
| **3.1.1** All digital goods via IAP | **Pass** (after fix) | Was a **fail-risk**: four user-visible "See plans on the web" CTAs pointed at `rendprop.com/pricing` alongside the in-app "Upgrade plan" button. Permitted on the US storefront since 1 May 2025, but the page has no checkout now that IAP exists, so the link sold nothing and merely put an external purchase CTA beside an in-app one. **All removed** — see §2, fix 1. Grep for `pricingURL` / "See plans on the web" / `rendprop.com/pricing` across the target now returns comments only. |
| **3.1.2** Subscription disclosures | **Pass** | The paywall (`Purchases/PaywallView.swift`) carries every required element: **title** `plan.displayName` (`:412`), **length** `/month`·`/year` (`:146-150`) plus "Billed every month."·"Billed once a year." (`:369`), **price** from `Product.displayPrice` only (`:208-210` — no price string is compiled into the binary; grep confirms), **auto-renew sentence** in both the buy bar (`:259`) and the legal block (`:329`, text at `Purchases/Products.swift:256`), **trial disclosure** when eligible (`:320`, text at `Products.swift:260`), **Terms of Use** → Apple's standard EULA (`:335`, `Products.swift:251`), **Privacy Policy** → `rendprop.com/privacy` (`:338`), **Restore purchases** (`:297-310`). Empty-product-list state is honest, not broken (`:108-127`), and the review notes explain it. |
| **3.1.3** No external purchase steering | **Pass** (after fix) | Same fix as 3.1.1. `Config.pricingURL` is retired and returns `nil` unconditionally (`Config.swift:88`); the `Storefronts` resolver is left in place, referenced by nothing that renders UI (`RendpropApp.swift:2507+`). |
| **4.0 / 4.2** Minimum functionality | **Pass** | Substantial native app: camera capture, on-device video render, RoomPlan scanning, StoreKit, speech, MetricKit. Not a web wrapper. |
| **4.8** Sign in with Apple | **Pass, N/A by exemption** | There is no third-party or social login to trigger 4.8. Sign in with Apple is the **only** authentication surface (`Auth/SignInView.swift:18-20`, `Screens/RenderStatusView.swift:570` — the native `SignInWithAppleButton`; entitlement at `Rendprop.entitlements`). Nothing to offer as an equivalent. |
| **5.1.1(i)** Privacy policy in app | **Pass** | Settings → `Privacy Policy` (`SettingsView.swift:289`), plus on the paywall (`PaywallView.swift:338`) and inside the AI consent sheet (`RendpropApp.swift:2439`). |
| **5.1.1(ii)** Purpose strings + consent | **Pass**, with one note | All six purpose strings name the feature and the reason — camera, when-in-use location, microphone (reel voiceover only), motion, photo-library **add-only**, speech recognition (and it discloses the off-device fallback to Apple). `NSPhotoLibraryUsageDescription` is deliberately absent because every read path is the out-of-process picker — correct, and 5.1.1(iii) data-minimisation as written. Third-party AI processing has a real prior-consent gate (below). **Note:** first-party product analytics has no in-app opt-out — see §4, open item 5. |
| **5.1.1(ii)** AI consent before media leaves the device | **Pass** | `AIConsent` (`RendpropApp.swift:2280-2357`) blocks at the door of every AI surface, names the processors (Google, Topaz Labs) and states exactly what is and is not sent (`:2432-2437`). Verified every path that ships a photo or video off-device is behind it: Photo Studio (`FlythroughDetailView.swift:2192,2194`), Reel Studio (`:3561,3563`), Aerial (`:4360,4362`), room-name suggestion (`ReviewSubmitView.swift:848,859`), and — the one that carries the walkthrough video itself — the AI render tier picker (`ReviewSubmitView.swift:209-226`, gated at the moment of selection; the `.smooth` tier never leaves the phone). Revocable at Settings → Your data (`SettingsView.swift:261-268`) and revoked on account deletion (`:844`). |
| **5.1.1(v)** Account deletion | **Pass** | "Delete account" is always visible, two taps from the Settings root, never gated on sign-in (`SettingsView.swift:276`). Signed in → `DELETE /me` with the bearer JWT, and it refuses to wipe locally unless the server confirms `ok` (`:649-670,690-705`) — no half-deletion. Guests get an honest "Sign in to delete your account" (`:363`) plus "Clear data on this phone" directly below (`:278`), which is the correct answer since a guest has no server account. Local wipe is wholesale across every container directory (`:731-760`). |
| **5.1.2** Data use, ATT | **Pass** | No `ATTrackingManager`, no `advertisingIdentifier`, no `AppTrackingTransparency` import anywhere — grep-verified. Attribution is SKAdNetwork postbacks only (`Analytics/Attribution.swift`), which Apple expressly does not classify as tracking, so `NSPrivacyTracking = false` and no ATT prompt is the correct pairing. Analytics is first-party to our own `POST /events` with a fixed 19-word vocabulary and `[String: String]` props (`Analytics/Analytics.swift:56-62,99-119`) — no PII by construction, enforced again server-side. |
| **5.1.5** Location | **Pass** | One `CLLocationManager`, `requestWhenInUseAuthorization` only, `kCLLocationAccuracyHundredMeters`, one-shot, used solely to prefill the listing address (`Screens/NewListingView.swift:642-680`). Never "Always". Manual address entry is the primary path, so declining costs nothing — 5.1.1(iv) satisfied. |
| **5.2** Intellectual property | **Pass** | No third-party logos or trademarks in the bundle — `Resources/` holds only the app icon, an accent colour, and a self-contained `player/index.html` whose only external reference is `rendprop.com`. Sample listings are invented ("1247 Hillcrest Drive (Sample)", "Bella Notte (Sample)"). The demo tour is our own hosted content. The three "More from us" partner links are the owner's own properties. |
| **5.3** Gambling | **N/A** | Nothing of the kind. |
| **5.6** Developer code of conduct | **N/A** | Nothing of the kind. |

### Binary configuration

| Check | Result |
|---|---|
| `ITSAppUsesNonExemptEncryption` | `false` — present, so no export-compliance prompt at upload. |
| `UIBackgroundModes` | **Absent, correctly.** The app uses `URLSessionConfiguration.background` (`Upload/UploadManager.swift:185`) and `beginBackgroundTask` (`RendpropApp.swift:1066`) — neither requires the key. Declaring an unused background mode is itself a rejection cause. |
| `LSApplicationQueriesSchemes` | **Absent, correctly.** No `canOpenURL` call anywhere. |
| `CFBundleDisplayName` | `Rendprop`. |
| Version / build | `1.0` / `1` (`project.yml:9-10`, `project.pbxproj:444-445,422`). |
| Deployment target / family | iOS 16.0, `TARGETED_DEVICE_FAMILY = 1` (iPhone only) — matches the listing. |
| Orientation | Portrait only. |
| `SKAdNetworkItems` | Two Meta identifiers, both from Meta's own documentation. Nothing speculative. |
| Plist validity | `Info.plist`, `PrivacyInfo.xcprivacy`, `Rendprop.entitlements` all parse cleanly under `plistlib`. |

### Privacy manifest vs. actual API use

Every required-reason API the app calls is declared, with a reason code that matches how it is
actually used — checked by grepping for each API and reading the call site.

| Category | Used at | Declared reason | Correct? |
|---|---|---|---|
| File timestamp | `Support/FileStore.swift:143`, `Render/RenderEngine.swift:267,271`, `FlythroughDetailView.swift:1840,1842,…` | `C617.1` | Yes — all reads are inside the app's own container. |
| System boot time | `Capture/MotionRecorder.swift:137` (`ProcessInfo.systemUptime`, motion-sample alignment) | `35F9.1` | Yes — elapsed time between in-app events. |
| Disk space | `Support/FileStore.swift:56-57` (`volumeAvailableCapacityForImportantUsage`) | `E174.1` + `85F4.1` | Yes — both apply: the capture refuses a take that will not fit *and* shows the numbers to the user. |
| User defaults | throughout, app-only keys | `CA92.1` | Yes — no app group, no shared suite (`UserDefaults(suiteName:)` appears nowhere). |
| Active keyboards | **not used** | not declared | Correct — declaring an unused category invites questions. |

Collected data types (13) agree exactly with `docs/appstore/privacy-labels.md`, which is the
answer sheet for the App Privacy questionnaire. Spot-checked against what the app actually
sends: Sign in with Apple name/email, the Supabase user id, photos/videos, listing address and
precise coordinate, agent-card phone, listing story text, first-party product-interaction
events, the Keychain device UUID, MetricKit crash and performance summaries, and Apple's signed
transaction. Lead contact details arriving from the hosted form are the same declared types
(Name / Email / Phone) so they open no gap. `NSPrivacyTracking = false` with an empty
`NSPrivacyTrackingDomains` is the right pairing for SKAdNetwork-only attribution.

### Admin surface

Not reachable by a non-admin. The owner-console rows render only when the **server** says so:
`/me`'s `is_admin` flag, else a single probe of `GET /admin/spend` where anything but success
means no row (`SettingsView.swift:587-610`, drawn at `:227`). Presentation only — every admin
route re-checks `profiles.is_admin` server-side on every call. A reviewer cannot stumble into
it, and nothing on the device can unlock it.

---

## 2. Fixes applied

Six files touched, all Swift, all `swiftc -parse` clean. No behaviour change beyond what is
described. Nothing committed.

**1. Removed every external purchase CTA (3.1.1 / 3.1.3) — the main fix.**

Four user-visible "See plans on the web" links to `rendprop.com/pricing` sat next to the in-app
"Upgrade plan" button on 402 (quota) states. They were storefront-gated to the US, which was
defensible while the web page was the only way to pay — it no longer is, and that page has no
checkout, so the link bought the user nothing and cost the app an external purchase CTA sitting
beside an in-app one.

- `Config.swift:74-88` — `pricingURL` retired: now `static var pricingURL: URL? { nil }`,
  unconditionally, on every storefront. Kept as a property (per brief) so any future call site
  inherits "no external CTA" rather than re-introducing one. Comment rewritten to say why.
- `Screens/RenderStatusView.swift:270-281` — removed the `Link("See plans on the web")` from the
  publish-402 block. "Upgrade plan" → `PaywallRouter` remains.
- `Screens/FlythroughDetailView.swift:1393` — removed the `AIFailure.pricingURL` forwarder.
- `Screens/FlythroughDetailView.swift:1478-1488` — removed the `Link` from the AI-quota sheet.
- `Screens/FlythroughDetailView.swift:2175-2180` — removed the `Button("See plans on the web")`
  from the AI-failure alert; also dropped the now-dead `@Environment(\.openURL)` at `:1965`.
- `Screens/SettingsView.swift:851-854` — removed the dead `UserFacingError.pricingURL`
  forwarder (it had no consumers).
- `RendpropApp.swift:2481-2503`, `:1509-1511`, `Networking/APIClient.swift:953-954`,
  `SettingsView.swift:543-545,876-878` — comment blocks that documented the old US-storefront
  link rewritten so they describe what now ships. `Storefronts` left in place and harmless: it
  still resolves, nothing gates a purchase or renders UI on it.

**2. Made the paywall reachable signed-out (2.1(b)) — the fix that most likely saved a
rejection.**

`Screens/SettingsView.swift:462-476` — dropped the `if auth.isSignedIn` wrapper around
`PlanActionRows`. The review notes tell the reviewer that sign-in is only needed to publish, and
every other route to the paywall is a server 402 that a signed-out user cannot receive, so the
in-app purchases were effectively invisible to a reviewer following the documented flow.
Buying while signed out is safe and already handled: StoreKit takes the purchase, the
transaction is deliberately left **unfinished** until the server confirms it, and the user is
told "Sign in to finish turning on your plan. Your purchase is safe — nothing is lost."
(`Purchases/PurchaseManager.swift:414-421`). With `planName: nil`,
`RendpropProducts.isUpgradeable` returns true, so the row draws.

**3. Removed four forward-promise strings (2.1).** Honest, but they read as an unfinished app
and they are the exact phrasing reviewers grep for.

- `SettingsView.swift:129` — "Email alerts are coming — check here for now." → "…land here. Open
  Leads to read and reply to them."
- `SettingsView.swift:1025` — dropped "— email alerts are coming" from the empty-leads state.
- `SettingsView.swift:1449` — "Hosted tour pages show your initials for now — photo upload is
  coming." → "Hosted tour pages show your initials."
- `FlythroughDetailView.swift:914` — "Leads appear here; email alerts coming." → "Enquiries from
  this tour's share link appear here."

**4. Corrected a stale product count.** `RendpropApp.swift:2483-2489` said "six products"; the
app requests **five** (`RendpropProducts.notSoldAtLaunch` excludes Team yearly), which is what
`review_notes.txt` states. Comment only — but the two must not disagree when someone configures
App Store Connect from the source.

```
 apps/ios/Rendprop/Config.swift                     | 29 ++++-------
 apps/ios/Rendprop/Networking/APIClient.swift       |  2 +-
 apps/ios/Rendprop/RendpropApp.swift                | 43 ++++++++-------
 apps/ios/Rendprop/Screens/FlythroughDetailView.swift | 26 +++-------
 apps/ios/Rendprop/Screens/RenderStatusView.swift   | 14 ++----
 apps/ios/Rendprop/Screens/SettingsView.swift       | 39 ++++++++------
```

---

## 3. Metadata accuracy — claim by claim (2.3.1)

Each `description.txt` claim traced to shipped code. No claim is unsupported.

| Claim | Shipped? |
|---|---|
| Phone walkthrough → drone-style flythrough, rendered on device | Yes. `Render/RenderEngine.swift`; `Capture/`. Standard "Smooth" tier is fully on-device. |
| Room tagging, scroll-to-jump share link | Yes. `Capture/RoomTagBar.swift`, `Screens/ReviewSubmitView.swift`, `Models/Listing.swift:98`. |
| Contact form → leads inbox in the app | Yes. `LeadsView` (`SettingsView.swift:901+`), listing-scoped view at `FlythroughDetailView.swift:~900`. |
| AI Photo Studio — sky, twilight, lawn, tidy, add furniture | Yes. `FlythroughDetailView.swift:2160-2180` (styles), `api.aiPhotoEdit`. |
| Every AI edit labelled "virtually staged", original published beside it | Yes. `APIClient.swift:182` ("Virtually staged photo"), provenance log at `FlythroughDetailView.swift:649`, unaltered original published alongside (`RendpropApp.swift:454`). |
| Reels with own voiceover + word-by-word captions | Yes. `Voice/VoiceRecorder.swift`, `Voice/SpeechTranscriber.swift`, `Voice/CaptionRenderer.swift`. |
| Aerial intro, always disclosed as AI-generated | Yes. `api.aiVideoAerial`; disclosure at `FlythroughDetailView.swift:4536` ("AI-generated scenery, not real drone footage"). |
| **Floor plan — RoomPlan "on supported iPhones", or upload one** | **Yes, and the phrasing is exact.** Guarded by `RoomCaptureSession.isSupported` (`FlythroughDetailView.swift:6091`). On a phone without LiDAR the scan UI is not offered at all; the user gets "This device has no LiDAR for 3D scanning — but you can upload a PDF or image of your floor plan or blueprints. Your photos and video tour work on every device." (`:6154`) and the upload path, which is shown in **both** branches (`:6061`). No dead button, no crash, no over-claim. |
| Branded page + separate unbranded MLS link | Yes. `Models/Listing.swift:98` (`/f/`) and `:119` (`/u/`); UI at `RenderStatusView.swift:331`, `FlythroughDetailView.swift:353-359`. |
| Agent card on every tour | Yes. `AgentCard`, `SettingsView.swift:~1440`. |
| Five business modes re-theme the app | Yes. `SpaceType` (`Models/Listing.swift:597+`), switcher at `RendpropApp.swift:1621`. |
| Works without an account; sign-in only to publish | Yes. `Config.enableAuth` gates publish-time actions only; capture, render, AI tools and preview all run signed out. |
| Plan allowances (8/150/8/2, 25/300/20/6, 80/600/40/15+3 seats) | Server-enforced, and the same numbers are asserted in `services/supabase/tests/invariants.sql:165,174`. Displayed in-app from `/me`, never hardcoded. |
| Prices `$49 / $490 / $99 / $990 / $249` | Listed in the description only. The **app** shows `Product.displayPrice` exclusively — grep confirms no subscription price string is compiled into the binary. |

---

## 4. Open items — human only

1. **Sandbox purchase test, on a device.** Sign in with a Sandbox Apple ID and run each of the
   five products end to end: trial eligibility copy ("Start 7-day free trial" vs "Subscribe",
   `PaywallView.swift:314-316`), purchase → server sync → plan unlocks, **Restore purchases**,
   and "Manage subscription" opening Apple's sheet. Also test one purchase **while signed out**
   (now reachable — fix 2) and confirm the "Sign in to finish turning on your plan" message
   appears and the plan lands after signing in.

2. **Confirm App Store Connect has exactly the five products the app requests**, all in the
   `rendprop_plans` group, each with the 7-day introductory offer, each **attached to build 1**
   and in "Ready to Submit" — otherwise StoreKit returns an empty list, the paywall shows
   "Plans aren't available right now", and 2.1(b) is a rejection. The app deliberately does not
   request `com.rendprop.app.team.annual`; do not create expectations around it. (The local
   `Rendprop.storekit` file has six for testing — that is fine, it ships nothing.)

3. **Screenshots (2.3.3).** Not in the repo. Needed: app in use, not splash/login. Include **a
   screenshot of the paywall taken on the phone with live StoreKit prices** — reviewers look for
   it, and it is the cheapest possible answer to a 3.1.2 query.

4. **Terms of Use inconsistency (metadata — I do not own those files).** The paywall links
   Apple's standard EULA (`Products.swift:251`), which is correct if App Store Connect's License
   Agreement is left as the standard EULA. But `description.txt` advertises
   `Terms of Use: https://rendprop.com/terms`, a different document, and Settings links that one
   too (`SettingsView.swift:288`). Pick one and make all three agree: either put
   `rendprop.com/terms` in the ASC License Agreement field and link it from the paywall, or
   change the description line to the standard-EULA URL. Low risk, trivially avoidable.

5. **First-party analytics has no in-app opt-out (5.1.1(ii)).** The app collects product
   analytics with no consent prompt and no toggle. It is disclosed in the privacy manifest, the
   privacy label and the privacy policy, contains no PII by construction, and is not tracking —
   Apple rarely rejects on this, and many shipping apps do the same. But 5.1.1(ii) does ask for
   "an easily accessible and understandable way to withdraw consent", and GDPR is a separate
   question from App Review. I did **not** add a toggle: it needs a new persisted flag plus
   plumbing through `Analytics.track`/`flush` and it interacts with the website's privacy-policy
   text, which is outside this audit's scope. Recommended shape if you want it: an "Share usage
   analytics" switch in Settings → Your data, next to the existing "AI processing" row, with
   `Analytics.track` returning early when off. Owner's call.

6. **Device smoke test on a non-LiDAR iPhone** (e.g. a base iPhone 14/15) to confirm the floor
   plan screen shows the upload-only branch and nothing dead — the code path is correct by
   inspection but has not been run on hardware in this audit.

7. **Offline launch on device.** Airplane mode, cold launch, walk the demo flow. Static analysis
   found no crash path (no force-unwrapped network results), but this is worth two minutes.
