# App Review Information — Rendprop 1.0

Everything App Store Connect asks for on the "App Review Information" panel, as of
**2026-09-05**. This supersedes the template in `docs/APP-STORE-CHECKLIST.md` §7, which
was written before subscriptions shipped and still said *"nothing is charged in this
version"*. **That sentence must not be pasted into App Store Connect** — the app now
sells auto-renewable subscriptions and saying otherwise is a 3.1.2 rejection waiting to
happen.

---

## Sign-in required?

**No.** Answer "Sign-in required: No" and leave the demo-account fields empty. The app is
fully usable as a guest; the only gate is publishing (see below). If the reviewer prefers
an account anyway, they can create one with any Apple ID via Sign in with Apple — there is
no invite list and no allow-list.

## Notes field — copy-paste

> The text Apple actually receives lives in `metadata/en-US/review_notes.txt` (≤ 4000 characters; `asc.py review apply` uploads that file, never this one). Keep the two in step.

> Rendprop turns a walkthrough you film on an iPhone into a smooth "drone-style" property
> tour, hosted as a web link the user shares with clients.
>
> DEMO FLOW (no account needed): Home tab → "See it in action" plays a live sample tour —
> scroll inside the video to move through the space. To build one: Home tab → "Add a home"
> → name it → "Add walkthrough video" (record, or import any clip from the photo library)
> → tag rooms → "Create tour". The flythrough renders on the device.
>
> SIGN IN WITH APPLE is required only to PUBLISH a tour to the web, because publishing is
> what creates the hosted page, the unbranded MLS link, and the contact form. Capture,
> on-device rendering, the AI photo studio, reels, aerial intros, and floor plans all work
> signed out.
>
> SUBSCRIPTIONS: Rendprop sells auto-renewable subscriptions through StoreKit 2 — Starter,
> Pro, and Team, monthly or yearly, in one subscription group ("rendprop_plans"), each with
> a 7-day free introductory offer. They unlock monthly allowances for tour renders and the
> AI features (see the plan list in the App Store description). Settings tab → "Plan &
> usage" → "Upgrade plan" opens the paywall; "Manage subscription" opens Apple's own
> management sheet. No price is compiled into the app — every price shown comes from
> StoreKit's `Product.displayPrice`. There is no other way to pay inside the app.
>
> IF THE PAYWALL SAYS "Plans aren't available right now": that message appears only when
> StoreKit returns no products — i.e. before the six subscriptions are approved, or before
> the Paid Applications agreement is Active. It is the app's correct, non-crashing
> behaviour for an empty product list, not a bug. Once the products are approved with this
> build, the paywall lists all three plans with live prices and the "Start 7-day free
> trial" button.
>
> ACCOUNT DELETION: Settings tab → Account → "Delete account". It deletes the server
> account, published tours, uploaded media, and leads, then wipes local data. It also works
> for guest users (local wipe only, because there is no server account).
>
> AI-GENERATED CONTENT: the AI photo edits (sky, twilight, lawn, declutter, virtual
> staging) and the AI aerial intro produce synthetic or altered imagery. Every altered
> asset carries a disclosure sentence in-app, the tour page shows a persistent "Virtually
> staged" label to viewers, and the unaltered original is published alongside the edit.
> A listing's Compliance section lists every AI asset with its disclosure and can export
> the audit log as CSV.
>
> USER CONTENT: users record their own spaces. The app carries the notice "Only record
> spaces you have the right to record and publish." There is no in-app feed and no way to
> browse another user's content, so there is nothing to moderate between users.
>
> Contact: aaron@pilk.ai

## What is NOT part of review

The **owner console** (Settings → "Spend & providers", AI routing, provider key health,
funnel) is a first-party admin surface. It renders only when the signed-in account is
flagged `isAdmin` by our server, which no reviewer account will be. Do not describe it in
the review notes, do not supply credentials for it, and do not ask the reviewer to look at
it — it is not a feature of the app under review, and mentioning it only invites questions
about an area the reviewer cannot reach.

Likewise, do not mention TestFlight, "early access", a roadmap, or any unreleased feature
in the notes. (2.3.1)

## Contact fields

| Field | Value |
|---|---|
| First / last name | Aaron (owner) |
| Phone number | **required — fill this in**; App Review will not accept an empty phone field |
| Email | aaron@pilk.ai |

## Attachment

Attach the IAP review screenshot described in `docs/appstore/iap-review/README.md` to the
**subscription group's** review information (not the app's) if App Store Connect asks for
one. The six products themselves each need a review screenshot showing the paywall with
that plan visible.

## Pre-submission truths a reviewer will test

These are not copy — they are the four things that must actually be live, or the notes
above become false:

1. `https://rendprop.com/privacy` and `https://rendprop.com/terms` resolve (the paywall,
   Settings, and the App Store listing all link to them).
2. `DELETE /me` is deployed, so "Delete account" succeeds when signed in.
3. Sign in with Apple completes against the live Supabase Auth project.
4. A tour published from a device opens on another device from its share link.

`docs/APP-STORE-CHECKLIST.md` §1 tracks these as blockers.
