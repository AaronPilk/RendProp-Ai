# App Privacy questionnaire — exact answers

App Store Connect → your app → **App Privacy**. Answers valid for the `launch` branch as
of **2026-09-05**. This replaces the table in `docs/APP-STORE-CHECKLIST.md` §4, which was
written before first-party analytics, the device identifier, MetricKit diagnostics,
SKAdNetwork attribution, and subscriptions existed and still says *"Usage Data /
Analytics → No — the app ships no analytics SDK"*. **That answer is now false.** The app
ships no *third-party* analytics SDK; it does collect first-party product analytics.

**"Does this app collect data?" → Yes.**

The source of truth for every row below is `apps/ios/Rendprop/PrivacyInfo.xcprivacy` plus
`Purchases/` and `Analytics/`. The privacy manifest and this questionnaire must agree —
Apple compares them.

---

## 1. Data types to declare as COLLECTED

Every row: **Not used for tracking**. See §3.

| Apple category → data type | Linked to the user? | Purposes | Why we collect it |
|---|---|---|---|
| Contact Info → **Email Address** | Linked | App Functionality | Sign in with Apple (may be a private-relay address). |
| Contact Info → **Name** | Linked | App Functionality | Sign in with Apple; shown on the agent card. |
| Contact Info → **Phone Number** | Linked | App Functionality | The phone number on the agent card, printed on the user's public tour pages. |
| Contact Info → **Physical Address** | Linked | App Functionality | The listing's street address — it is the product being toured, and it is published on the tour page. |
| User Content → **Photos or Videos** | Linked | App Functionality | The walkthrough video and listing photos uploaded to render and publish a tour. Includes finished reels, whose audio is the user's own voiceover. |
| User Content → **Other User Content** | Linked | App Functionality | Listing details and story text (taglines, room notes, business details). |
| Identifiers → **User ID** | Linked | App Functionality | The Supabase auth user id every listing, tour, and lead hangs off. |
| Identifiers → **Device ID** | Linked | **Analytics**, App Functionality, **Developer's Advertising or Marketing** | A UUID this app generates on first launch and keeps in its own Keychain item, sent with every analytics batch so the funnel counts people rather than taps. **Not the IDFA** (never requested) and not the IDFV. |
| Location → **Precise Location** | Linked | App Functionality | The listing's map pin. Two sources, both rounded to 3 decimals before they are stored or sent anywhere — a one-shot Core Location fix, and a forward geocode of the typed address (fixed 2026-09: this path previously stored the unrounded geocode result — see `docs/handoff/audit-fixes.md`). Three decimals is at Apple's Precise threshold, so **declare Precise, not Coarse** — rounding to 3 decimals is data minimization, not a lower privacy-label tier. The in-app "Open in Maps" link opens by the typed address itself; it falls back to this same rounded fix only when the listing has no address, and never sends a raw, unrounded coordinate. |
| Usage Data → **Product Interaction** | **Linked** | App Functionality, **Analytics**, **Developer's Advertising or Marketing** | First-party funnel (`POST /events`): a fixed 19-word event vocabulary plus a few enum/count props. The server attaches the account id when signed in, which is what makes it Linked. Also the tour-page view counter. |
| Diagnostics → **Crash Data** | Linked | App Functionality, Analytics | MetricKit crash summaries only — kind, signal/exception number, a termination reason clipped to 120 chars with path-shaped tokens removed, and one frame name. Never a full call stack. No third-party crash SDK. |
| Diagnostics → **Performance Data** | Linked | App Functionality, Analytics | MetricKit hang / CPU / disk-write exceptions and a median launch time, one small number or category each. |
| Audio Data | Linked | App Functionality | The voiceover recording, submitted to `SFSpeechRecognizer` for captions (`Voice/SpeechTranscriber.swift`). `requiresOnDeviceRecognition` is **not** forced true — it tracks `supportsOnDeviceRecognition`, and even an on-device attempt that fails retries once with it set to `false` — so on a device/locale without an on-device model, or after that retry, the recording is sent to **Apple's** speech-recognition servers over the network (Apple's own docs: `requiresOnDeviceRecognition = true` is what "prevent[s] ... sending audio over the network" — false is the alternative). `NSSpeechRecognitionUsageDescription` in `Info.plist` already tells the user this can happen. Added 2026-09 — previously undeclared; see §6. |
| Purchases → **Purchase History** | Linked | App Functionality | StoreKit 2. The app posts Apple's signed transaction (JWS) to our server, which stores **Apple's transaction id, original transaction id, product id, environment, and expiry** in `apple_subscriptions` in order to unlock the plan. We never see or store card details, and we do not use purchase data for advertising. |

## 2. Data types to answer NO to — and the reason, if asked

| Data type | Why "No" |
|---|---|
| Financial Info → Payment Info | Apple processes every payment. We receive a signed transaction, never a card. |
| Contacts | The app never reads the address book. |
| Browsing History, Search History | Neither exists in the app. |
| Health, Fitness, Sensitive Info | Never touched. The "gym" mode describes a *venue*, not a person's fitness. |
| ~~Audio Data~~ | **Moved to §1, 2026-09.** Previously answered No here on the reasoning that the recording only leaves as part of an already-declared video. That covers the publish path, but misses that transcription itself can send the raw recording to **Apple's** servers (§6) — which is collection, just not collection *by us*. See §6 for the full reasoning. |
| Coarse Location | We store a coordinate at Precise resolution, so it is declared as Precise instead. Declaring both is wrong. |
| Advertising Data | No ad SDK, no ad inventory, no IDFA. |
| Other Diagnostic Data | Everything MetricKit gives us is already declared as Crash or Performance Data. |
| Other Data Types | Nothing left over. |

Motion / gyroscope data is processed on-device for stabilization and never leaves the
phone → not declared.

## 3. Tracking (App Tracking Transparency)

**"Do you or your third-party partners use data for tracking?" → NO.** The app never
presents an ATT prompt, and `NSPrivacyTracking` is `false` in the privacy manifest.

The owner buys Meta ads, so expect this to be questioned. The answer: Apple defines
tracking as linking this app's data with data from *other companies'* apps or websites for
targeted advertising or ad measurement, or sharing it with a data broker. Rendprop does
neither.

* Attribution is **SKAdNetwork only** (`Info.plist` → `SKAdNetworkItems` carries Meta's two
  ids; `Analytics/Attribution.swift` calls `SKAdNetwork.updatePostbackConversionValue`).
  iOS itself sends the signed postback; it carries a campaign id and a conversion value
  (0 install · 1 signup · 2 home_created · 3 tour_published · 4 paywall_viewed ·
  5 purchase_completed) and **no identifier**. Apple expressly does not classify
  SKAdNetwork as tracking.
* Product analytics is first-party end to end: our own `POST /events`, our own Postgres,
  read only by the owner. No Firebase, no Mixpanel, no ad SDK, no pixel, no IDFA.
* `NSPrivacyTrackingDomains` is empty, correctly — there is no domain to list.

**Never add the ATT prompt unless that changes.** Prompting without tracking is itself a
review problem.

## 4. Retention and the two extra questions

* App analytics events are purged after **180 days** (`purge_app_events`, scheduled as a
  Supabase cron job — see `docs/handoff/launch-P3.md` §5.2). The privacy page says so.
* "Data is used to track you across apps and websites owned by other companies" → **No**
  for every row.
* Optional data disclosure: **Precise Location is optional** — the user can decline the
  location prompt and type the address instead. Tick "this data is optional" for Location
  only; everything else is required for the feature it belongs to.

## 5. ⚠️ One thing the integrator must fix in code

`apps/ios/Rendprop/PrivacyInfo.xcprivacy` declares twelve collected data types but **not**
`NSPrivacyCollectedDataTypePurchaseHistory`, because the manifest predates the StoreKit
work. The App Privacy answer above declares Purchase History, so the manifest and the
questionnaire currently disagree. Add this dict to `NSPrivacyCollectedDataTypes` (this file
is owned by the iOS agent, not by this document):

```xml
<!-- Apple's signed transaction: transaction id, original transaction id,
     product id, environment and expiry, stored server-side to unlock the
     plan. No card details ever reach us. -->
<dict>
  <key>NSPrivacyCollectedDataType</key>
  <string>NSPrivacyCollectedDataTypePurchaseHistory</string>
  <key>NSPrivacyCollectedDataTypeLinked</key><true/>
  <key>NSPrivacyCollectedDataTypeTracking</key><false/>
  <key>NSPrivacyCollectedDataTypePurposes</key>
  <array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
</dict>
```

Everything else in the manifest already matches the answers above.

## 6. Audio Data was undeclared (2026-09 audit finding, now fixed)

**The manifest now declares `NSPrivacyCollectedDataTypeAudioData`** (Linked, Not used for
tracking, App Functionality). The App Store Connect answer must change to match: **Audio Data
→ Yes / Linked / Not tracking / App Functionality.**

The evidence, so this isn't taken on faith:

* `Voice/SpeechTranscriber.swift` sets `request.requiresOnDeviceRecognition = onDevice`, where
  `onDevice = recognizer.supportsOnDeviceRecognition` — it does **not** force on-device
  recognition. A device or locale without an on-device model gets `false` immediately, and a
  device that *does* support on-device recognition still retries once with `false` if the
  on-device attempt fails outright (see the `catch` in `transcribe(_:)`).
* Apple's own documentation for `requiresOnDeviceRecognition` says: "Set this property to
  `true` to prevent an `SFSpeechRecognitionRequest` from sending audio over the network." The
  converse is stated plainly: `false` sends audio over the network.
* `Info.plist`'s own `NSSpeechRecognitionUsageDescription` — shown to the user in the
  permission prompt — already says this out loud: *"Transcription runs on this iPhone when the
  device supports it; otherwise the recording is sent to Apple's speech recognition service to
  be turned into text."*
* Rendprop's own backend is not part of this path. `SpeechTranscriber` only calls into Apple's
  `Speech` framework; no `LiveAPIClient`/network call to our own domain carries the audio. Only
  the transcript text comes back into the app.

The previous "No" answer reasoned that the recording only leaves the device as part of an
already-declared, published video (still true, and still covered under **Photos or Videos** —
not double-declared here). What it missed is that *transcription itself* — which runs whether
or not the reel is ever published — can send the raw recording off-device to a third party
(Apple). "Not collected by us" is not the same as "not collected" for this questionnaire: the
data still leaves the device, off to a service Rendprop's own feature code invoked.

One open judgment call for the app owner, not resolvable from the code alone: this entry is
declared **Linked**, matching every other row in this manifest (there is currently no
`Linked: false` row at all) and on the reasoning that the recording is a specific signed-in
user's own voice, captured against their own listing. Apple's Speech framework may or may not
tie the recognition request itself to the user's Apple ID on Apple's end — that is Apple's
practice, not something this app's code controls or can inspect, and it does not change what
*this app* should declare about data its own feature caused to be collected. If the app owner's
own reading of Apple's guidance differs, this is the row to revisit — not whether Audio Data
should be declared at all.
