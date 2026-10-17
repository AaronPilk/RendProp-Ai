# App Privacy questionnaire — exact answers

> **October 17 source correction — no published-answer change.** The Audio Data rationale below now includes the demonstrated Rendprop narration-upload path. Other Diagnostic Data is explicitly unresolved beyond MetricKit. This document still describes the last verified October 2 questionnaire; it is not a fresh authenticated read. The reviewed backend is deployed with Kie inactive. The attempted fresh Apple privacy read on October 17 reached the App Store Connect sign-in page; no sign-in or answer change was performed.

> **October 16 integration note — not a new published questionnaire.** The 14-type answers below describe the verified October 2 state. The photo-first/Kie candidate is not live. Selected property photos map to Photos or Videos; camera-motion/source text maps to the existing Other User Content category. Adding a processor does not by itself prove that existing data-use answers remain complete. Kie's operating/improvement license and lack of an express training exclusion require the provider-use purpose reconciliation before activation; do not certify App Functionality-only from the source code. Additional purposes may need declaration. No App Store Connect answer or native privacy manifest was changed in this pass. The draft notice is [RENDPROP-KIE-NOTICE-DRAFT-20261016](../legal/RENDPROP-KIE-NOTICE-DRAFT-20261016.md); the current workflow draft is [photo-first-review-draft-20261016](photo-first-review-draft-20261016.md). Apple requires partners' relevant collection/use and optional primary-function data to be considered: [official App Privacy guidance](https://developer.apple.com/app-store/app-privacy-details/), checked October 16. Consent alone does not exempt this primary function from disclosure, and possible model improvement is not automatically cross-company advertising tracking. No ATT change is inferred.

App Store Connect → your app → **App Privacy**. Reconciled for regular
**1.0.3 (42), 2 October 2026**. The authenticated Apple UI confirmed **14
published data types**, including Audio Data for App Functionality, linked to
identity and not used for tracking. Existing thirteen declarations were retained.
See the [release receipt](../releases/APPSTORE-42-20261002.json).

The older launch checklist's claim that the app collects no analytics is stale.
Rendprop has first-party product analytics and diagnostics, without a third-party
analytics SDK. Reconcile these answers with the shipped privacy manifest and
actual feature/provider collection when changing the product.

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
| Usage Data → **Product Interaction** | **Linked** | App Functionality, **Analytics**, **Developer's Advertising or Marketing** | First-party funnel (`POST /events`): an allowlisted event vocabulary plus a few enum/count props. The server attaches the account id when signed in, which is what makes it Linked. Also the tour-page view counter. |
| Diagnostics → **Crash Data** | Linked | App Functionality, Analytics | MetricKit crash summaries only — kind, signal/exception number, a termination reason clipped to 120 chars with path-shaped tokens removed, and one frame name. Never a full call stack. No third-party crash SDK. |
| Diagnostics → **Performance Data** | Linked | App Functionality, Analytics | MetricKit hang / CPU / disk-write diagnostics, reduced to small duration/category fields. The routine metric-payload callback currently uploads no launch histogram or median launch time. |
| Audio Data | Linked | App Functionality | Owned voice narration is uploaded through `Networking/PropertyVideoNarrationUpload.swift` using prepare / immutable audio PUT / complete, bound to the exact account, library and property, for the property-video compositor. This is an independent Rendprop collection path. Apple Speech transcription is a separate platform path; it is not the basis for declaring Apple's own collection as Rendprop collection. See §6. |
| Purchases → **Purchase History** | Linked | App Functionality | StoreKit 2. The app posts Apple's signed transaction (JWS) to our server, which stores **Apple's transaction id, original transaction id, product id, environment, and expiry** in `apple_subscriptions` in order to unlock the plan. We never see or store card details, and we do not use purchase data for advertising. |

## 2. Data types to answer NO to — and the reason, if asked

| Data type | Why "No" |
|---|---|
| Financial Info → Payment Info | Apple processes every payment. We receive a signed transaction, never a card. |
| Contacts | The app never reads the address book. |
| Browsing History, Search History | Neither exists in the app. |
| Health, Fitness, Sensitive Info | Never touched. The "gym" mode describes a *venue*, not a person's fitness. |
| ~~Audio Data~~ | **Already declared in §1.** The current source independently uploads retained narration to Rendprop. The older explanation relying solely on Apple Speech is superseded by §6. |
| Coarse Location | We store a coordinate at Precise resolution, so it is declared as Precise instead. Declaring both is wrong. |
| Advertising Data | No ad SDK, no ad inventory, no IDFA. |
| Other Diagnostic Data | **OPEN — do not certify No from MetricKit alone.** MetricKit is covered by Crash and Performance Data, but retained backend/vendor technical logs require a separate collection, linkage, retention and purpose assessment. Functional job/cost receipts are not automatically diagnostic data. No checkbox or manifest change is made by this source note. |
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

## 5. Purchase History is declared in the shipped manifest

The regular build's `PrivacyInfo.xcprivacy` includes
`NSPrivacyCollectedDataTypePurchaseHistory`: Linked, Not used for tracking,
App Functionality. It contains fourteen collected-data declarations, including
Purchase History and Audio Data. The older instruction to add a missing purchase
entry is resolved; do not add a duplicate.

## 6. Audio Data: published state and current source rationale

The existing manifest declares `NSPrivacyCollectedDataTypeAudioData`, Linked,
not used for tracking, for App Functionality. The retained October 2 receipt
records that published answer. This source correction does not republish it.

The current feature has an independent Rendprop audio path:

- `apps/ios/Rendprop/Networking/PropertyVideoNarrationUpload.swift` validates an
  owned narration file, records its digest and exact property/account context,
  calls audio prepare, transfers the audio bytes, then confirms completion.
- `services/supabase/functions/property-video-jobs/index.ts` handles the
  owned narration preparation/completion contract. The worker compositor consumes
  the selected narration asset for the requested video.
- This supports retaining Audio Data / Linked / App Functionality without
  treating Apple's own Speech collection as collection by Rendprop. The Kie
  property-video request has `sound:false` and contains no narration/music field;
  narration is a separate Rendprop/compositor flow.

`Voice/SpeechTranscriber.swift` can use Apple's network recognition when on-device
recognition is unavailable or its attempt fails. Its permission explanation remains
relevant to that feature. The older claim that Apple's own collection alone
requires this developer label is superseded. Native manifest comments still carry
that historical explanation; the declaration itself is retained, and the comment
correction should accompany the next deliberately bound native source revision.

Apple's questionnaire concerns developer/partner collection and use. Its treatment
of Apple's own collection is distinct. Review the actual app and vendor paths,
rather than inferring all purposes or linkage from a framework flag. See
[App Privacy definitions](https://developer.apple.com/app-store/app-privacy-details/)
and [Manage App Privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/),
checked October 17, 2026. Keeping a source manifest aligned does not establish a new
published questionnaire.

## 7. Remaining privacy reconciliation before Kie activation

- Obtain a fresh complete authenticated questionnaire read; the October 17 attempt
  reached sign-in, so the October 2 evidence remains the latest verified answers.
- Map retained technical error/diagnostic logs separately from operational job,
  payment and consent records. `propertyVideoPollDiagnostic` emits a closed event,
  phase, allowlisted error name and HTTP status; it intentionally excludes provider
  bodies, media URLs, tokens and IDs. Source logging alone does not establish the
  hosting/vendor retention or whether platform metadata permits linkage.
- Confirm API/account-specific input and log retention, deletion, improvement,
  training, human review, downstream processors and advertising/broker uses.
  Neither a no-training guarantee nor actual training is established by the
  reviewed general Terms. Keep unspecified purposes unknown.
- Reconcile verified purposes, public notice and the frozen client/server
  permission revision before any activation. Keep Kie inactive and the draft
  notice unpublished while those decisions remain open. No new ATT inference or
  App Store Connect change is authorized by this document.


## October 17 source-only diagnostic inventory

The current diagnostic review is recorded in [Diagnostic console minimization](../handoff/DIAGNOSTIC-CONSOLE-MINIMIZATION-20261017.md). First-party diagnostic uploads carry device/session identifiers; the server attaches the signed-in user/org. Hosted invocation metadata can also permit linkage. Do not describe these records as unlinked or infer an Other Diagnostic Data answer from MetricKit alone. Current hosted/vendor log retention and the complete authenticated App Store Connect questionnaire still need verification.

The Gemini, Apple-exchange catch and ledger console changes remove demonstrated freeform provider/error-text logging paths while preserving client responses, cost records and intentional correlation. This is data minimization, not a finding that credentials or customer content were historically exposed. Native privacy declarations and published answers are unchanged; native source comments and this internal rationale were corrected. The public legal example mentioning median launch time remains a separately tracked notice correction; no processor notice is published by this documentation change.
