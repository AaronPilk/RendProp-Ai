# docs/appstore — everything the App Store listing needs

Written 2026-09-05 against the `launch` branch. `docs/APP-STORE-CHECKLIST.md` is still the
in-order submission checklist; the files here are the **content** it tells you to paste, and
where they disagree with the checklist, **these files win** — several checklist answers were
written before subscriptions, first-party analytics, and SKAdNetwork existed.

| Path | What it is |
|---|---|
| `metadata/en-US/` | One file per App Store Connect field, each already inside Apple's limit. Paste the file, do not retype it. |
| `review-notes.md` | The App Review Information panel: sign-in answer, notes field, contact fields, and what deliberately stays out. |
| `privacy-labels.md` | Every App Privacy questionnaire answer, with the reason for each — including the ones that are now "Yes" and used to be "No". |
| `age-rating.md` | Every age-rating answer → 4+, including the three that need a sentence of reasoning. |
| `screenshots/README.md` | How the 6.9-inch set is captured and regenerated; the committed PNGs live in `screenshots/6.9/`. |
| `iap-review/README.md` | Why the subscription review screenshot needs a phone, and how to take it. |
| `ASC-API-PLAN.md` | Owned by another agent — the App Store Connect API automation plan. |

## Field lengths, measured

| Field | Chars | Apple's limit |
|---|---:|---:|
| `name.txt` | 8 | 30 |
| `subtitle.txt` | 29 | 30 |
| `promotional_text.txt` | 162 | 170 |
| `keywords.txt` | 94 | 100 |
| `description.txt` | 3519 | 4000 |
| `release_notes.txt` | 1032 | 4000 |

Promotional text is the one field you can change **without shipping a build** — use it for a
seasonal line and leave the description alone.

`keywords.txt` has 6 characters spare if you want to add a term. Keep the rules: no spaces
after the commas, no word repeated across terms, and never the app's own name (Apple already
indexes it).

## The three things in the metadata that must stay true

1. **The prices in `description.txt` are the prices in App Store Connect.** They match
   `apps/ios/Rendprop.storekit` and `docs/handoff/launch-P1.md` §5.3 today. If a price
   changes in App Store Connect, this file has to change with it — the app itself never
   hardcodes a price, but the listing does, because Apple requires it there.
2. **The allowances are the server's allowances.** 8 / 150 / 8 / 2, 25 / 300 / 20 / 6, and
   80 / 600 / 40 / 15 come from `plan_entitlements` via
   `apps/ios/Rendprop/Purchases/Products.swift`. Settings → Plan & usage shows the same
   numbers, so an inflated listing is contradicted by the app itself.
3. **No fair-housing copy, anywhere.** No people, no neighbourhoods, no schools, no
   demographics — not in the description, the keywords, the promotional text, the release
   notes, or text laid over a screenshot.

## Two things outside this directory that make the copy true or false

Both were found while writing these files. Neither is fixed here, because neither file is
this document's to edit.

**1. The marketing site sells a plan the App Store does not.**
`services/edge/tour-host/public/pricing.html` lists the $49 tier as **"Solo"**, marked
`schema.org/PreOrder`. The app, App Store Connect, and `Products.swift` all call it
**"Starter"**, and `docs/LAUNCH-CONTRACT.md` is explicit: *"`solo` is a legacy alias of
`starter` — never sell it."* A customer who follows a link from the app to that page sees a
plan name that does not exist in the store. The Terms page no longer points at
rendprop.com/pricing for exactly this reason (`services/edge/tour-host/src/legal.ts` §6 now
says the app is the source of truth), but the web page still needs renaming before launch,
and the `PreOrder` availability is wrong the moment the app ships.

**2. The privacy page promises a 180-day purge that a cron job has to perform.**
`https://rendprop.com/privacy` §4 now states that analytics events are deleted 180 days
after they are received. That is only true once the purge is scheduled — one `SELECT
cron.schedule(...)` in the Supabase SQL editor, written out in `docs/handoff/launch-P3.md`
§5.2. **Schedule it before the privacy page goes live**, or the policy says something the
system does not do.
