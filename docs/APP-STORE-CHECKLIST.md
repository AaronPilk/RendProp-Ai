# App Store Submission Checklist — Rendprop iOS

Practical, in-order checklist to get build 0.1.0 (1) through App Review. Written against the
code as of 2026-08-26. Items marked **BLOCKER** must be true before you press Submit.

---

## 0. State of the build (already done in code — verify, don't redo)

- [x] Bundle ID `com.rendprop.app`, display name "Rendprop", version `0.1.0`, build `1` (project.yml / Info.plist)
- [x] iPhone-only (`TARGETED_DEVICE_FAMILY = 1`), portrait-only, iOS 16.0+ — **no iPad screenshots or iPad testing required**
- [x] App icon present: `Rendprop/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png` (single-size 1024 format — valid for iOS 16+)
- [x] `ITSAppUsesNonExemptEncryption = NO` in Info.plist (HTTPS only → exempt; no export-compliance docs needed, no prompt at upload)
- [x] `UIBackgroundModes` removed (app uses background `URLSession` for uploads, which needs **no** background mode; keeping `fetch`/`processing` with no `BGTaskScheduler` invites review questions)
- [x] All permission strings present: Camera, Microphone, Photo Library (read + add), Location When In Use, Motion
- [x] Sign in with Apple entitlement (`com.apple.developer.applesignin`) — required because the app offers third-party-free login only; also satisfies 4.8
- [x] In-app account deletion: Settings → Account → **Delete account** (server `DELETE /me` + full local wipe) — Guideline 5.1.1(v)
- [x] No "test mode" / "beta" / "Phase 2" wording anywhere user-visible
- [x] AI-edited content disclosed in-app ("Virtually staged" label on enhanced tours; staging/declutter copy says AI)

## 1. BLOCKERS — resolve before submitting

- [ ] **BLOCKER — Privacy Policy URL must be live**: `https://rendprop.com/privacy` (and `/terms`). These are served by the tour-host Cloudflare worker; that deploy must happen **before** submission. Apple validates the privacy URL and reviewers click it. Settings → Legal links to both.
- [ ] **BLOCKER — `DELETE /me` must be deployed** on the Supabase edge API. The app's Delete-account button calls it when signed in; if the route 404s, deletion fails with a retry alert and a reviewer testing 5.1.1 will reject. (Signed-out/guest deletion works regardless — it's a local wipe.)
- [ ] **BLOCKER — Apple sign-in must actually work live**: Supabase Auth needs the Apple provider enabled + function secrets set (see `services/supabase/DEPLOYMENT.md`). The reviewer will tap "Publish" and hit the sign-in gate. If the exchange fails, that's a 2.1 "app is broken" rejection.
- [ ] **BLOCKER — publish flow end-to-end**: publish a real tour from a device on the live backend and open the share link on a second device before submitting. The reviewer will do exactly this.

## 2. App Store Connect record

1. [ ] appstoreconnect.apple.com → My Apps → "+" → New App
2. [ ] Platform iOS · Name **"Rendprop"** — note: the name may already be taken by another app; if rejected at creation, fall back to "Rendprop: AI Property Tours" (subtitle-style names are fine and help search)
3. [ ] Primary language English (U.S.) · Bundle ID `com.rendprop.app` (register it first at developer.apple.com → Identifiers if it's not in the dropdown, with Sign in with Apple capability checked) · SKU e.g. `rendprop-ios-001`
4. [ ] Category: **Business** (primary), Photo & Video (secondary) — Business matches real-estate/venue tooling
5. [ ] Pricing: **Free** app with **auto-renewable subscriptions** (six products in group `rendprop_plans` — see §8 and docs/handoff/launch-P1.md §5 for the exact App Store Connect setup)

## 3. Screenshots (iPhone only)

App Store Connect currently requires **one iPhone size**; the rest auto-scale.

- [ ] **6.9-inch** (iPhone 16 Pro Max class): **1320 × 2868** portrait — required set, 3–10 shots
- [ ] Optional extra sets if you want pixel-perfect on older phones: 6.7" 1290 × 2796 · 6.5" 1284 × 2778 (or 1242 × 2688) · 5.5" 1242 × 2208
- [ ] **No iPad set** — the app is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`)
- How: Xcode → iPhone 16 Pro Max simulator → run the app → Cmd+S per screen. Suggested order: Home showroom → live demo tour (scrub mid-frame) → capture screen → Review & Submit (tiers) → AI Photo Studio before/after → shared tour player → Profile card
- [ ] Screenshots must show the app as submitted — no "coming soon" overlays, no device frames with wrong device

## 4. App Privacy (nutrition labels) — exact answers for this stack

"Does this app collect data?" → **Yes**. Then:

| Data type | Collected? | Linked to user? | Used for tracking? | Purpose |
|---|---|---|---|---|
| Contact Info → Name | Yes (Apple sign-in) | **Linked** | No | App functionality |
| Contact Info → Email | Yes (Apple sign-in; user may hide) | **Linked** | No | App functionality |
| User Content → Photos or Videos | Yes (walkthroughs/photos uploaded to publish tours) | **Linked** | No | App functionality |
| User Content → Other (listing details: address, price) | Yes | **Linked** | No | App functionality |
| Identifiers → User ID | Yes (Supabase user id) | **Linked** | No | App functionality |
| Location → Precise Location | **Optional collect** — used on-device to prefill the address; the address (not coordinates stream) is stored with the listing → answer Yes, Coarse/Precise per what you store, Linked, App functionality | | | |
| Usage Data / Analytics | **No** — the app ships no analytics SDK | — | — | — |
| Tracking (ATT) | **NO** — nothing is used for cross-app tracking; never add the ATT prompt unless that changes | | | |

Notes: motion/gyro data is processed on-device for stabilization and not collected → not declared. Diagnostics: none (no crash SDK).

## 5. Age rating

- [ ] Questionnaire: answer **None/No** to everything (violence, gambling, medical, unrestricted web, user-generated content forum, etc.) → lands at **4+**
- Tours are creator-published links viewed outside the app; there is no in-app browsing of other users' content, so the UGC questions are honestly "No"

## 6. Version metadata

- [ ] Description: lead with the outcome (phone walkthrough → cinematic tour link), mention AI photo enhancement and the multi-industry modes. Do **not** use "beta", "test", or promise unshipped features (2.3.1)
- [ ] Keywords: real estate tour, virtual tour, listing video, property video, virtual staging, walkthrough, open house
- [ ] Support URL: `https://rendprop.com` · Marketing URL (optional): same
- [ ] Privacy Policy URL: `https://rendprop.com/privacy` (**must be live — see §1**)
- [ ] Copyright: 2026 Rendprop

## 7. App Review Information (copy-paste template)

Sign-in required: **No demo account needed** — the app is fully usable as a guest. Fill the notes field with:

> Rendprop turns a phone-shot walkthrough video into a smooth "drone-style" property tour that agents share as a web link.
>
> DEMO FLOW (no account needed): Home tab → "See it in action" shows a live sample tour (scroll inside the video to move through the space). To create your own: Homes tab → + → create a listing → record or import a short walkthrough → Review & Submit → the tour renders on-device.
>
> SIGN IN WITH APPLE is required only when PUBLISHING a tour to the web (it creates the hosted share link and lead capture). Everything else — capture, on-device rendering, AI photo preview — works without an account.
>
> ACCOUNT DELETION: Settings tab → Account → "Delete account". This deletes the server account, published tours, and uploaded media, then wipes local data. Works for guest users too (local wipe).
>
> AI-GENERATED CONTENT DISCLOSURE: Optional AI features (virtual staging, declutter, aerial intro shots) produce synthetic imagery. Any tour altered by AI displays a persistent "Virtually staged" label to viewers, and aerial intros are presented as AI-generated in-app. Prices shown next to render tiers are informational; nothing is charged in this version ("Included with your plan during early access").
>
> Contact: aaron@pilk.ai

- [ ] Attach a phone number in the review contact fields

## 8. Payments / IAP (StoreKit 2 — launch branch, 2026-09-05)

- The app sells **auto-renewable subscriptions** through StoreKit 2 (`apps/ios/Rendprop/Purchases/`): Starter $49, Pro $99, Team $249 per month, annual = 10 months, one subscription group `rendprop_plans`, 7-day free introductory offer. **No price string is compiled into the binary** — every price comes from `Product.displayPrice`, so App Store pricing changes need no app update.
- The server is the only source of truth for a plan: every verified transaction is sent as JWS to `POST /me/entitlement` and Apple's App Store Server Notifications V2 hit `POST /apple-subscriptions/notify`; both verify the JWS chain against the pinned Apple Root CA G3 before touching `orgs.plan` (migration 0019). An unsynced transaction is never `finish()`ed.
- [ ] App Store Connect, in this order (details + copy-paste text in docs/handoff/launch-P1.md §5): Paid Applications agreement **Active** (products load as an empty array until it is) → subscription group `rendprop_plans` → the six product ids `com.rendprop.app.{starter,pro,team}.{monthly,annual}` with levels Team 1 / Pro 2 / Starter 3 → 7-day free intro offer on each → App Store Server Notifications V2 URL `https://ymgqpbnjpztwjsyvceld.supabase.co/functions/v1/apple-subscriptions/notify` on **both** Sandbox and Production → a sandbox tester account.
- [ ] Paywall shows the two links App Review requires for auto-renewables (3.1.2): Apple's standard EULA and `https://rendprop.com/privacy` — **that privacy page must be live before submission.**
- The rendprop.com/pricing link-out (`Config.pricingURL`) stays US-storefront-only per 3.1.1(a) and is now secondary to in-app purchase; it must never be the only way to pay.

## 9. TestFlight first (recommended — do this today, submit from the same build)

1. [ ] Xcode: select "Any iOS Device (arm64)" → Product → **Archive**
2. [ ] Organizer → **Distribute App** → App Store Connect → Upload (automatic signing, Team `5F5C5G25Y6`)
3. [ ] App Store Connect → TestFlight tab → build appears after processing (~10–30 min). Export-compliance prompt should not appear (`ITSAppUsesNonExemptEncryption` is set); if asked, answer "None of the algorithms mentioned"
4. [ ] Add yourself as an **internal tester** → install via TestFlight on a real phone
5. [ ] Smoke test on-device: onboarding → sample tour → record → render → **sign in with Apple → publish → open share link** → AI photo edit → **delete account**
6. [ ] When it survives that pass, go to the App Store tab → add the same build to version 1.0 → Submit for Review

## 10. Known content/compliance positions (if review asks)

- **AI-altered property imagery**: disclosed to end viewers via the "Virtually staged" watermark label (this also matches MLS/real-estate advertising norms); aerial establishing shots are AI-generated and labeled as such in-app — restate this in review notes (§7)
- **Camera/mic/photos/location/motion**: all have clear purpose strings; location is used only to prefill the listing address
- **Token storage**: session tokens are in UserDefaults (Keychain migration is on the roadmap) — not an App Review criterion, but fix before scale
- **Guest mode**: core functionality does not require login → compliant with 5.1.1(i); sign-in is required only for the account-based publish feature

---

### Fast answer sheet

| Question | Answer |
|---|---|
| Encryption / export compliance | Exempt — HTTPS only, `ITSAppUsesNonExemptEncryption = NO` already in Info.plist |
| Content rights | User-generated walkthroughs; in-app notice: "Only record spaces you have the right to record and publish." |
| Tracking / ATT | No tracking, no ATT prompt |
| Ads | None |
| Age rating | 4+ |
| Sign-in | Sign in with Apple only, publish-gated, guest mode available |
| Account deletion | Settings → Account → Delete account (server + local) |
