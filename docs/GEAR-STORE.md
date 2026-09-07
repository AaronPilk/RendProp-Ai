# GEAR-STORE — "Gear we recommend" (Amazon Associates), verified rules + rollout (2026-09-07)

Branch `feat/gear-store`. A short, remote-controlled list of filming gear
(gimbals, mics, lights, tripods, wide-angle lenses, storage) shown in the app
so a person buys the right kit and the owner earns an Associates commission.
Ships in **1.0.1** compiled in and completely invisible — see §3.

For the mechanics of editing the catalog itself (the tag, ASINs, turning it
on) see `services/edge/tour-host/public/GEAR-README.md`. This doc is the rest
of the story: the rules that shape every line of code in `Gear/`, the order
of operations to actually turn the section on, and the map of every file this
feature touches outside its own folder.

---

## 1. Amazon's rules (Associates Operating Agreement, checked 6 Sep 2026)

These are the rules `Gear/GearStore.swift` and `Gear/GearView.swift` are built
around. Re-check the Operating Agreement before flipping `enabled: true` —
Amazon changes it without much notice, and this list is a snapshot.

1. **The app must be free, and Associates links must be reachable without
   paying.** Rendprop is free to download, and Gear reads no sign-in state
   and no plan/entitlement — `GearStore.isAvailable` and every entry point
   check only the remote catalog, never `AuthStore` or `Purchases/`. A
   signed-out person on the free plan sees exactly what a paying, signed-in
   owner sees.
2. **Never in a WebView.** Every tap goes through
   `UIApplication.shared.open(_:)` (`GearStore.open`), which hands the link to
   Safari or the Amazon app via its universal link. There is no in-app browser
   anywhere near Gear, and nothing in `Gear/` imports `WebKit`.
3. **No price tracking, price alerts, or anything that reads like a deal
   feed.** `GearItem` has no price field, no rating field, no stock field —
   there is nothing to display even by accident. Blurbs describe what a
   category of gear *does* for filming a walkthrough, never a review claim
   ("highly rated", "best-selling") and never a number that looks like a
   price.
4. **The Associates disclosure must be visible.** "As an Amazon Associate,
   Rendprop earns from qualifying purchases." ships in `gear.json`
   (`disclosure`) and `GearView` pins it in its own banner above the list, so
   it is on screen before any product regardless of scroll position.
5. **The mobile app itself must be approved separately.** Having an
   Associates account is not enough — the *app* is submitted for review
   under Mobile Apps in Associates Central, and only after it is live and
   free in the App Store (Amazon reviews the live listing, not a build).
   This is a policy gate the code cannot enforce for you — see §2.
6. **Commission on this category (cameras & photo / electronics accessories)
   runs 3–4%** under the standard Associates fee schedule. Re-check the
   current rate card before relying on a number in any owner-facing copy —
   Amazon revises fee schedules periodically and this file will not update
   itself.

Everything above is also summarized in the header comment of
`Gear/GearStore.swift` — if the two ever disagree, this file is the one to
trust and the code comment is the one to fix.

## 2. Owner's approval steps, in order

**Do not do step 6 until step 5 has actually happened.** Nothing in the app
enforces that order — `gear.json`'s `enabled` flag is a plain switch anyone
with repo access could flip early. It has to be a habit.

1. Ship 1.0.1 (this feature, compiled in and hidden — §3) and get it through
   App Review, live and free in the App Store.
2. If you do not already have one, join Amazon Associates at
   `affiliate-program.amazon.com`.
3. In Associates Central, find **Mobile Apps** (under the account/tools menu)
   and submit Rendprop for approval. You will need the live App Store listing
   URL. Amazon's reviewers are checking for exactly the rules in §1 — free
   app, no WebView, disclosure visible, no price/rating claims — so a build
   that fails this doc's rules will fail their review too.
4. Wait for Amazon's approval e-mail. Only after that:
5. Get your tracking ID: Associates Central → account menu → **Manage Your
   Tracking IDs**. Put it in `gear.json`'s `associates_tag`
   (`services/edge/tour-host/public/gear.json`) — GEAR-README.md walks
   through the exact field.
6. Fill in real ASINs for the items you're confident in (SiteStripe or the
   product URL's `/dp/<ASIN>` — GEAR-README.md §"An ASIN per item"). You do
   not have to fill in every item; one valid ASIN is enough to turn the
   section on, and the rest can follow.
7. Set `"enabled": true`, keep `"version": 1`, save, then
   `cd services/edge/tour-host && npm run deploy`.
8. Verify on a phone: Settings → "Gear we recommend" and the Home tile appear
   (immediately on a fresh install; within ~6 h on one already running — the
   app caches the catalog and refreshes at most that often). Tap one item,
   confirm it opens Amazon with `?tag=<your tag>` in the URL. Give Associates
   Central a day and check its own click/earnings report for the click.

## 3. What ships in 1.0.1

The code ships complete and compiles in; the section itself ships **off**.
Nothing here is a placeholder pending a future release — the remote
`gear.json` (§2, steps 5–7) is the only thing standing between this build and
a visible Gear section, and turning it on needs no app update and no new App
Review.

Concretely, hidden until `enabled: true` **and** a valid `associates_tag`
**and** at least one item with a real ASIN, per `GearStore.isAvailable`:

- The "Gear we recommend" row in Settings → Legal & support.
- The Home tile (`GearHomeLink`, near the bottom of the Home tab).
- `GearView` itself — unreachable with both entry points hidden, and it
  never re-checks `isAvailable` on its own (see its file header).

The shipped `gear.json` has `enabled: false`, `associates_tag: ""`, and every
item's `asin` empty — so today, on every build, all three are invisible. See
`services/edge/tour-host/public/GEAR-README.md` for the full field-by-field
editing guide.

## 4. Files

### The feature's own files (`apps/ios/Rendprop/Gear/`, plus the catalog)

| File | What it is |
|---|---|
| `apps/ios/Rendprop/Gear/GearStore.swift` | Wire models (`GearCatalog`/`GearCategory`/`GearItem`), the `GearStore` singleton (fetch, disk cache, `isAvailable`, filtering, `open(_:)`), the `-uiTesting` sample catalog |
| `apps/ios/Rendprop/Gear/GearView.swift` | `GearView` (the list screen) and `GearHomeLink` (the Home tile) |
| `services/edge/tour-host/public/gear.json` | The live catalog, served as-is at `https://rendprop.com/gear.json` |
| `services/edge/tour-host/public/GEAR-README.md` | How to edit `gear.json` (not published — excluded by `.assetsignore`) |
| `services/edge/tour-host/public/.assetsignore` | Excludes `GEAR-README.md` from the Worker's static-asset upload |
| `docs/GEAR-STORE.md` | This file |

### Shared files this feature edited (file:line as of this commit — a later commit can move these; search the anchor text if a line number is stale)

| File:line | What changed |
|---|---|
| `apps/ios/Rendprop/Config.swift:107` | Added `Config.gearCatalogURL` (`https://rendprop.com/gear.json`) |
| `apps/ios/Rendprop/Analytics/Analytics.swift:61` | Added `"gear_opened"`, `"gear_item_tapped"` to `Analytics.vocabulary` — without this, `Analytics.track` silently drops both events in Release and hits `assertionFailure` in Debug (the vocabulary guard exists precisely to catch an unregistered name at the call site) |
| `apps/ios/Rendprop/Screens/SettingsView.swift:28` | Added `@ObservedObject private var gearStore = GearStore.shared` |
| `apps/ios/Rendprop/Screens/SettingsView.swift:317` | The "Gear we recommend" `NavigationLink` row in the "Legal & support" section, guarded by `gearStore.isAvailable` |
| `apps/ios/Rendprop/RendpropApp.swift:1619` | `GearHomeLink()` added to `HomeDashboardView.body`, right after `partnersSection` |
| `services/edge/tour-host/public/_headers:52-59` | Cache-Control rule for `/gear.json` (5 min fresh, 1 h stale-while-revalidate — it's hand-edited in place, not fingerprinted) |
| `services/supabase/functions/events/schema.ts:73-78` | Registered `gear_opened` (`["source"]`) and `gear_item_tapped` (`["item"]`) in `EVENT_SCHEMA` — the server-side half of the same registration as `Analytics.swift` above. **This one is not optional**: `POST /events` 400s the **entire batch** on any unrecognized event name (`events/index.ts`), and the client's flush() puts a failed batch back at the front of the queue and retries it forever — so shipping the client vocabulary addition without this would have permanently jammed analytics for any device that ever opened Gear once the feature is live, not just the two new events. |
| `services/supabase/functions/events/events.test.ts:152-159` | Updated the hardcoded vocabulary assertion to include both new names (kept in sorted order — `deno test` was not run in this environment; re-run it before merging) |
| `docs/LAUNCH-CONTRACT.md:70-76` | Added `gear_opened`, `gear_item_tapped` to the documented event vocabulary |

Nothing in this feature touches `Purchases/`, `PaywallView.swift`,
`PaywallRouter`, or any StoreKit code — Gear reads no entitlement and gates
nothing behind a plan.
