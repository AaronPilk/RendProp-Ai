# App Review Information — Rendprop 1.0.1 (build 22)

Everything App Store Connect asks for on the "App Review Information" panel, as of
**2026-09-12** (first written 2026-09-05 for 1.0; reworked for build 22 with the new plan
allowances and the per-industry free week). This supersedes the template in
`docs/APP-STORE-CHECKLIST.md` §7, which was written before subscriptions shipped and still
said *"nothing is charged in this version"*. **That sentence must not be pasted into App
Store Connect** — the app sells auto-renewable subscriptions and saying otherwise is a 3.1.2
rejection waiting to happen.

---

## Sign-in required?

**No.** Answer "Sign-in required: No" and leave the demo-account fields empty. Everything —
capture, rendering, the AI tools, publishing a tour and buying a subscription — works with no
account: the app opens an anonymous session for itself. Sign in with Apple is optional
(Settings → Account; it carries a workspace to a new device). The one screen behind it is
Settings → Team, because a seat belongs to a person, and nothing a reviewer needs is there.
If the reviewer prefers an account anyway, any Apple ID works via Sign in with Apple — there
is no invite list and no allow-list.

## Notes field — copy-paste

> The text Apple actually receives lives in `metadata/en-US/review_notes.txt` (≤ 4000 characters; `asc.py review apply` uploads that file, never this one). Keep the two in step — the block below is a verbatim copy.

> Rendprop turns an iPhone walkthrough into a smooth "drone-style" property tour, hosted as a web link the user shares with clients.
>
> NO ACCOUNT IS REQUIRED (the 5.1.1(v) fix). Every feature, publishing and the subscription purchase included, works on first launch with no registration. The app opens a session for itself in the background: no email, phone or password is asked for or stored. There is no sign-in screen in the normal flow.
>
> NEW IN THIS BUILD (22): (a) Plan allowances changed; prices did not. Starter $49: 4 tour renders, 100 AI photo edits, 6 reel clips, 2 aerial intros, 1 seat. Pro $99: 10 renders, 200 edits, 12 clips, 4 aerial intros, 1 seat. Team $249: 25 renders, 400 edits, 25 clips, 8 aerial intros, 2 seats (was 3). (b) The free week is sized to the business type chosen at setup: real estate 3 tour renders, single-location businesses 1 (below). (c) An upload interrupted mid-way recovers on its own or offers "Start over". (d) Sign in with Apple after signing out works every time. (e) Nothing new needs an account. (f) A 3D room-scanning feature exists in the code but is switched off server-side and does not appear in the app.
>
> Sign in with Apple is offered only as an option in Settings > Account, to carry a workspace to a new device. That screen says so and offers "Not now". It is never required to reach a feature or to buy.
>
> THE ONE EXCEPTION, and nothing a reviewer needs is behind it: Settings > Team. A seat belongs to a person, so starting or joining a team asks for Sign in with Apple. Seats are not sold there: the Team plan is an ordinary auto-renewable subscription bought through StoreKit like the other four, and no link in the app leaves it to buy anything.
>
> FREE WEEK: a new install gets seven days with a larger allowance, then drops to the free plan (1 tour render a month). Real estate: 3 tour renders, 60 photo edits, 4 reel clips, 2 aerial intros. Event venue, restaurant/bar, retail/grocery, gym/studio or other business: 1 tour render, 60 photo edits, 4 reel clips, 1 aerial intro. Automatic, no card, no account; the last intro screen says so. It is deliberately NOT called a "free trial" in the UI, so it is not confused with the 7-day StoreKit introductory offer on the paid plans.
>
> DEMO FLOW: Home > "See it in action" plays a live sample tour - scroll inside the video to move through the space. To build one: Home > "Add a home" > paste a listing link or an address > "Upload a video" or "Record a walkthrough" > tag rooms > "Create tour". The flythrough renders on the device.
>
> SUBSCRIPTIONS: auto-renewable, StoreKit 2, five products in one group (rendprop_plans) - Starter and Pro monthly or yearly, Team monthly - each with a 7-day free introductory offer. They unlock the monthly allowances above. Settings > "Plan & usage" > "Upgrade plan" reaches the paywall from a cold launch with no account; "Manage subscription" opens Apple's own sheet. Every price comes from StoreKit's Product.displayPrice; there is no other way to pay in the app. If the paywall says "Plans aren't available right now", StoreKit returned no products, i.e. they are not yet approved.
>
> ACCOUNT DELETION (5.1.1(v)): Settings > "Your data" > "Delete account", always visible. It deletes the server-side account, published tours, uploaded media and leads, then wipes local data. It works for a session that never signed in with Apple, since the app created that account silently.
>
> AI-GENERATED CONTENT: the AI photo edits (sky, twilight, lawn, tidying, virtual staging) and the AI aerial intro alter imagery. Every altered asset carries an in-app disclosure, the tour page shows a persistent "Virtually staged" label, and the unaltered original is published beside the edit. A listing's Compliance section lists every AI asset and exports the audit log.
>
> USER CONTENT: users record their own spaces (the app says "Only record spaces you have the right to record and publish"). No in-app feed, no way to browse another user's content.
>
> Contact: aaron@pilk.ai

## What changed for build 22 (the facts behind the notes)

- **Plan allowances** (prices unchanged: Starter $49/mo or $490/yr, Pro $99/mo or $990/yr,
  Team $249/mo): Starter 4 tour renders, 100 AI photo edits, 6 reel clips, 2 aerial intros,
  1 seat; Pro 10 / 200 / 12 / 4, 1 seat; Team 25 / 400 / 25 / 8, **2 seats** (was 3).
- **Free week, per business type**: real estate 3 tour renders, 60 photo edits, 4 reel clips,
  2 aerial intros; single-location businesses (event venue, restaurant/bar, retail/grocery,
  gym/studio, other) 1 tour render, 60 photo edits, 4 reel clips, 1 aerial intro. Then the
  free plan: 1 tour render a month.
- **Uploads** interrupted mid-way recover on their own or offer "Start over".
- **Sign in with Apple after sign-out** works every time.
- **Nothing new needs an account.**
- A **3D room-scanning** feature exists in the code but is switched off server-side and does
  not appear in the app — it is mentioned so a reviewer reading the binary is not surprised.

## What is NOT part of review

The **owner console** (Settings → "Spend & providers", AI routing, provider key health,
funnel) is a first-party admin surface. It renders only when the signed-in account is
flagged `isAdmin` by our server, which no reviewer account will be. Do not describe it in
the review notes, do not supply credentials for it, and do not ask the reviewer to look at
it — it is not a feature of the app under review, and mentioning it only invites questions
about an area the reviewer cannot reach.

Likewise, do not mention TestFlight, "early access", a roadmap, or any unreleased feature
in the notes. (2.3.1) The one deliberate exception is item (f) in the build-22 paragraph: it
discloses that dormant room-scanning code ships switched off, so a reviewer who finds it in
the binary is not surprised — it promises nothing.

## Contact fields

| Field | Value |
|---|---|
| First / last name | Aaron (owner) |
| Phone number | **required — fill this in**; App Review will not accept an empty phone field |
| Email | aaron@pilk.ai |

## Attachment

Attach the IAP review screenshot described in `docs/appstore/iap-review/README.md` to the
**subscription group's** review information (not the app's) if App Store Connect asks for
one. The five products themselves each need a review screenshot showing the paywall with
that plan visible. (`com.rendprop.app.team.annual` is **not sold at launch** — see
`docs/handoff/launch-P1.md` §5.3 — so it needs neither a product nor a screenshot yet.)

## Pre-submission truths a reviewer will test

These are not copy — they are the four things that must actually be live, or the notes
above become false:

1. `https://rendprop.com/privacy` and `https://rendprop.com/terms` resolve (the paywall,
   Settings, and the App Store listing all link to them).
2. `DELETE /me` is deployed, so "Delete account" succeeds for anonymous sessions and
   signed-in accounts alike.
3. Sign in with Apple completes against the live Supabase Auth project.
4. A tour published from a device opens on another device from its share link.

`docs/APP-STORE-CHECKLIST.md` §1 tracks these as blockers.
