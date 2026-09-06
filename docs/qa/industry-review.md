# Per-industry static review — what differs, what leaks, what is unfinished

**Date:** 2026-09-06 · **Branch:** `launch` · **Scope:** every code path that branches on
`SpaceType` / `spaceTypeRaw` / `space_type` in `apps/ios/Rendprop` and the edge functions it
calls, read against the locked spec in `docs/INDUSTRY-LOGIC.md`.

**Companion:** `apps/ios/RendpropUITests/IndustryWalk.swift` + `bridge-cmd-industrywalk.sh`
walk every one of these screens per industry on the simulator and write `CHECK PASS` /
`CHECK FAIL` lines to `~/Rendprop AI/_bridge/out/industrywalk/checks.txt`. Every P1 below that
is reachable under `-uiTesting` shows up there as a `CHECK FAIL … no real-estate-only
vocabulary on <screen>` line quoting the label. The ones marked *device / live only* do not.

Severity: **P0** would ship a wrong or unlawful thing to a paying non-real-estate customer ·
**P1** a non-real-estate customer sees real-estate product on a money or legal screen ·
**P2** a wrong word on a working screen, or spec/code drift · **P3** cosmetic.

---

## 1. What actually differs per industry today (the good news)

Everything below is data-driven from `SpaceType` in `apps/ios/Rendprop/Models/Listing.swift`
and holds up on every screen the walk reaches.

| Surface | Real estate | Venue | Restaurant / Bar | Retail / Grocery | Gym / Studio | Other | Source |
|---|---|---|---|---|---|---|---|
| Second tab / collection title | Homes · My Homes | Venues · My Venues | Places · My Places | Stores · My Stores | Studios · My Studios | Spaces · My Spaces | `Listing.swift:349-372`, `RendpropApp.swift:1496` |
| Hero headline (Home) | Win the listing. / Skip the film crew. | Book the date before / they ever visit. | Fill the room before / they see the menu. | Get them in the door / from their couch. | Sell the feeling / before the first class. | Show your space / like a film. | `Listing.swift:508-517`, `RendpropApp.swift:1752` |
| Hero subline names the audience | buyers | planners | guests | shoppers | (the space) | customers | `Listing.swift:520-535` |
| Customer noun (steps, footers, leads copy) | buyers | planners | guests | shoppers | members | customers | `Listing.swift:493-502` |
| Tour CTA (in-app) | Book a showing | Plan your event | Book a table | Visit us | Book a session | Get in touch | `Listing.swift:381-390` |
| New-listing form | address + Bedrooms/Bathrooms/Square feet/Asking price | name/address + Description + 8 fields (capacity, price, event types, catering, indoor/outdoor, amenities, booking link) | + 7 fields (cuisine, price range, hours, reservations, menu, features, phone) | + 7 fields (store type, hours, phone, online store, weekly special, how to shop, departments) | + 8 fields (facility, membership, day pass, 24/7, hours, amenities, free trial, booking) | + 3 fields (hours, phone, website) | `Listing.swift:411-482`, `NewListingView.swift:96-101, 140-195` |
| Sample listing | 1247 Hillcrest Drive · 88 Marina Vista #501 | The Grand Atrium | Bella Notte | Fresh Market | Iron & Oak Strength Co. | The Workshop | `Listing.swift:597-660` |
| Card chips | beds/baths/sqft + price | Seats 220 · From $3,500 · Wedding | Italian · $$$ · Tue–Sun 5–11pm | Grocery · Daily 7am–9pm · ★ special | $49/mo · Open 24/7 · Free trial | hours | `Listing.swift:220-249` |
| Detail screen DETAILS card | hidden (facts in the info line) | the filled fields, URL fields as links titled with the CTA | same | same | same | same | `FlythroughDetailView.swift:164-178, 959-986` |
| Area / room tags | Exterior, Entry, Living Room, Kitchen … | Entrance, Main Hall, Stage, Bar … | Entrance, Dining, Bar, Patio … | Entrance, Front, Aisles, Produce … | Entrance, Reception, Main Floor, Weights … | Entrance, Main Area, Front … | `Listing.swift:663-683`, `RoomTag.swift:22` |
| "Tag rooms" vs "Tag areas" | rooms | areas | areas | areas | areas | areas | `FlythroughDetailView.swift:541, 617`, `ReviewSubmitView.swift:142-171, 464` |
| Archive verb | Sold / sold | Archived / archived | … | … | … | … | `Listing.swift:393-394`, `HomeListingsView.swift:267, 333`, `FlythroughDetailView.swift:807` |
| Zillow field + link | shown | hidden | hidden | hidden | hidden | hidden | `FlythroughDetailView.swift:816-819`, `PlayerWebView.swift:389-392` |
| Profile card | Agent card · Full name · Brokerage · Headshot | Business card · Business name · Owner or manager (optional) · Logo or photo | same | same | same | same | `Listing.swift:487-490`, `SettingsView.swift:1444-1455, 1513, 1572` |
| Photo studio one-tap edits | twilight, sky, **lawn**, tidy, **Add furniture**, animate | twilight, sky, tidy, **Furnish it**, animate, **Ask for anything** | same | same | same | same | `FlythroughDetailView.swift:1863-1874, 2121-2131, 2742-2753` |
| Staging disclosure label | "Virtual staging" | "Furnish & style" | same | same | same | same | `FlythroughDetailView.swift:1926, 2379-2392` |
| Server-side AI prompts | proven RE prompt set | per-industry profile (stage = tables/linens/uplighting) | per-industry | per-industry | per-industry (racks, mats) | commercial-space profile | `services/supabase/functions/ai-photo/index.ts:170-260, 512-524` |
| Aerial subject / declutter prompt | residential home | event venue building | restaurant building with signage | retail storefront | fitness studio / gym building | commercial building | `services/supabase/functions/ai-video/index.ts:299-340` |
| In-app tour preview (`PlayerWebView`) | demo agent + "Book a showing" | business identity, CTA label, form sub-line swapped | same | same | same | same | `PlayerWebView.swift:302-306, 365-384, 452-472` |
| Hosted tour CTA (`/f/<slug>`) | lead form + Zillow secondary | Plan your event → bookingUrl deep link, else form with event fields | Book a table → reservationUrl, menu + call secondaries | **Shop online** / **Get directions**, email-only opt-in | **Start free trial** / **Book a class** / Book a session, form → handoff | Get in touch → website | `services/supabase/functions/tours/cta.ts:66-158`, `tour-host/src/player.ts:584-600, 700-740` |
| Listings filtered by type; samples reseeded on switch | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | `Listing.swift:152-154`, `RendpropApp.swift:188-192, 1514-1516`, `HomeListingsView.swift:18-33` |
| Detail screen pops when the type changes underneath it | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | `FlythroughDetailView.swift:247-251` |

---

## 2. Findings — ranked

### P1 — a bar / gym / store owner meets real-estate product on a money, legal or first-run screen

**P1-1 · The fair-housing gate fires for every industry, with housing copy, and blocks hospitality vocabulary.**
`services/supabase/functions/_shared/fairhousing.ts:191-211` (`assertFairHousing`) and `:214-` (`assertMarketingCopy`) never look at `space_type`, and every caller passes none:
`ai-photo/index.ts:501, 521` (custom edit, improve_prompt), `ai-video/index.ts:625, 690, 691, 823` (erase, aerial style/region, reel clip prompt), `ai-voice/index.ts:525` (voiceover script — the function accepts `listing_id` at `:476` but never reads the listing's type).
Consequences for a non-housing customer:
- The contextual people rule (`fairhousing.ts:147`) blocks **guest(s), diner(s), shopper(s), crowd(s)** behind an ADD verb — i.e. "seat diners at the tables", "show shoppers in the aisle", "fill the bar with a crowd" are refused. Those are the customers of three of the six industries. (Not generating people is a defensible product rule everywhere; the *wording* is not.)
- The refusal says *"Fair-housing rules (HUD guidance on AI in housing advertising) mean Rendprop never generates people … in listing media"* (`fairhousing.ts:205-207`) to a restaurant.
- The voiceover script rules (`fairhousing.ts:376-420`) refuse **"adults only"** (a bar's legal reality), **"perfect for couples"** / **"great for families"** (normal restaurant and venue marketing), **"ideal for students"** (a campus gym), **"made for professionals"** (a coworking "Other business") — each with a *"describes the residents…"* explanation. The file itself documents that "the family gathering space SEATS twelve" is refused (`fairhousing.ts:290-294`), which is a venue sentence.
**Fix shape:** pass `space_type` (the listing's, not `SpaceType.current`) into both gates; keep the always-blocked steering/protected-class tier for everyone, scope the people/audience tiers and the HUD wording to `real_estate`. *Live backend only — not visible in the walk.*

**P1-2 · The MLS link card and its "most MLSs fine for that" warning are shown to every industry after publish.**
`apps/ios/Rendprop/Screens/FlythroughDetailView.swift:348-360` (`if let mls = currentListing.serverUnbrandedURL` — no type gate) and `RenderStatusView.swift:322-346` (`mlsLinkRow`, same). `Listing.serverUnbrandedURL` (`Listing.swift:110-122`) derives a `/u/` link for any published listing, so a bar gets **"MLS link — unbranded · Safe for the MLS virtual-tour field"**, **"Share MLS link"** and **"Never put your branded link in an MLS unbranded field — most MLSs fine for that."** The branded card next to it says **"Agent card + lead capture"** (`:342`) and its QR caption is **"flyers, sign riders, open-house sheets"** (`:346`). *Live backend only.*

**P1-3 · The paywall sells to "an agent listing a few homes" on every industry.**
`apps/ios/Rendprop/Purchases/Products.swift:41-42`: Starter *"For one agent listing a few homes a month."*, Pro *"For a busy agent shooting every week."* — the plan-card tagline on the only purchase screen. `PaywallView` has no `SpaceType` branch at all. *Visible in the walk when the StoreKit test session comes up:* `CHECK FAIL … no real-estate-only vocabulary on Paywall (plan cards)` for venue/restaurant/retail/fitness/other.

**P1-4 · Home's "More from us" is real-estate cross-promotion on every industry.**
`apps/ios/Rendprop/RendpropApp.swift:2100-2103`: **"Wholesale Mortgage Lending — Get your buyers pre-approved fast"** and **"Tract — The real estate system we built"** sit on every Home dashboard. A gym owner's first screen advertises mortgages. *Visible in the walk:* `CHECK FAIL … on Home` quoting both rows.

**P1-5 · The California AB 723 banner fires for any California business.**
`FlythroughDetailView.swift:672-682`: `if currentListing.isCalifornia` — AB 723 is a real-estate-listing statute (digitally altered *listing* imagery), but a Sausalito wine bar that AI-edits a photo gets *"California requires disclosure and access to originals for altered listing media (AB 723)."* in amber. The compliance rows themselves are fine for everyone; the statutory claim is not. Same card: **"Email my broker the audit"** (`:717`), *"disclosure is property information, so it stays on the unbranded page"* (`:701`), and the delete message *"…if your broker needs them on file"* (`:849-850`). *Live backend only (needs `serverID` + provenance rows).*

**P1-6 · Non-real-estate industries get a "Sample video unavailable" demo on Home and on every sample detail.**
`RendpropApp.swift:1568-1575, 2006-2010`: real estate plays the hosted `rendprop.com/f/estate-demo`; every other type plays `PlayerWebView(listing: demo)`, which needs `Resources/player/demo.mp4` (`PlayerWebView.swift:124-130`) — an untracked file that is not in the build (`apps/web/player/README.md`). So the first thing a venue owner sees under "See it in action" is the explicit unavailable state, and the same again on the sample's detail. Even with the file present it is one house walkthrough with "Main Hall / Stage / Bar" chapter dots painted over it. *Visible in the walk:* `<type>-02-home-demo.png` and `<type>-04-sample-detail.png`.

### P2 — a wrong word on a working screen, or the spec and the code disagree

**P2-1 · The in-app CTA preview does not match the hosted tour's CTA for retail and fitness.**
`Listing.swift:381-390` hard-codes **"Visit us"** (retail) and **"Book a session"** (fitness); the server (`tours/cta.ts:93-108, 111-129`) publishes **"Shop online" / "Get directions"** and **"Start free trial" / "Book a class" / "Book a session"** per `INDUSTRY-LOGIC.md:45, 52`. Those in-app labels drive the Settings › Business type preview (**"YOUR TOUR'S BUTTON — Visit us"**, `SettingsView.swift:1974-1982`), the DETAILS deep-link label (`FlythroughDetailView.swift:176-178`), the card-editor footer (`SettingsView.swift:1472`) and the in-app player (`PlayerWebView.swift:469`). The owner is shown one button and publishes another.

**P2-2 · The in-app tour preview never shows the per-industry lead fields the hosted page renders.**
`PlayerWebView.swift:452-472` swaps only the CTA label and one sub-line; the hosted player renders event date / guest count / party size / fitness goal fields, a retail email-only opt-in, and the fitness form-then-handoff (`tour-host/src/player.ts:524-560, 700-740`). `INDUSTRY-LOGIC.md:31, 39, 45, 54` still lists these as 🔜 although the hosted side ships them — the doc is stale and the in-app preview is behind it.

**P2-3 · The room tagger speaks "rooms" to every industry while its own title says "Tag areas".**
`ReviewSubmitView.swift:464` branches the title; `:528` *"Scrub to where a room begins"*, `:562` *"Suggest room names"*, `:647` *"Custom room name"*, `:653`, `:664` *"No rooms tagged yet."*, `:882`, `:890`, `:963-964` do not. *Device only (needs a video).*

**P2-4 · Real-estate vocabulary on shared screens** — each one a `CHECK FAIL` in the walk for the five non-RE types:
- Home tile promise **"Twilight · blue sky · staging"** — `RendpropApp.swift:2573` (`ProjectFeature.photos.promise`).
- Onboarding card 2: *"Twilight skies, decluttered rooms, virtual staging — pro listing photos…"* — `OnboardingView.swift:17` (shown before the type is picked, so every industry reads it; ReviewerWalk's `r01-onboarding-2`).
- AI consent sheet: *"Gemini edits your listing photos."* — `RendpropApp.swift:2307` (a Guideline 5.1.2(i) disclosure shown verbatim in Settings too, `SettingsView.swift:75` is fine).
- Aerial format line *"Widescreen — for the top of a listing video or YouTube."* — `FlythroughDetailView.swift:3812`; kicker **"THE PROPERTY"** — `:3675`.
- Floor plan: *"…export it as an image for a listing or a flyer."* — `FlythroughDetailView.swift:6133`.
- Photo delete confirmation: *"…links buyers to the original — … if your broker needs them on file."* — `FlythroughDetailView.swift:2146`.
- Settings: sign-out message *"Your listings, videos and tours stay on this phone."* — `SettingsView.swift:347`; clear-data alert *"Removes every listing, video, tour and card…"* — `:388-389` (and `:284`); Business type screen *"Your listings for every type are kept"* — `:1891`.

**P2-5 · Screens that read `SpaceType.current` instead of the listing's own type.**
`ReviewSubmitView.swift:36`, `RenderStatusView.swift:55, 525`, `ReviewSubmitView.swift:464` (tagger title), `LeadsView` (`SettingsView.swift:975-999`), `LiveAPIClient.swift:480, 576, 608` (`space_type` sent on photo edits / suggestions is the *current* type, not the listing's). `FlythroughDetailView` (`:67-69`) and `PhotoStudioView` (`:1922`) do it right. A type switch while a render or review is on screen re-labels a house as a venue (and prompts the AI for the wrong industry).

**P2-6 · Retail spec says the lead form becomes an email-only promo opt-in; the in-app preview still asks for name + required phone.**
`INDUSTRY-LOGIC.md:45`; in-app form `Resources/player/index.html:270-272` is unchanged for retail (`PlayerWebView.adaptCopy` only rewrites the sub-line to *"Get deals and updates in your inbox."*, `PlayerWebView.swift:459`). The hosted page does it right (`cta.ts:100-107`, `lead_fields: ["email"]`).

**P2-7 · The photo-studio empty state tells a gym to "stage it".**
`FlythroughDetailView.swift:2737` *"Then tap one button to fix the sky, clean the room, or stage it."* — the chip below it correctly says "Furnish it".

### P3 — cosmetic

- Toolbox photo-studio subtitle **"Sky · tidy · furniture"** on every type — `FlythroughDetailView.swift:598`.
- Settings shooting tip **"Lights on, blinds open"** — `SettingsView.swift:190`.
- Portfolio export `<title>` falls back to **"My Listings"** — `SettingsView.swift:1810`.
- Retail sample repeats its hours in both the tagline and the Hours row — `Listing.swift:634-636`; fitness sample has `is247` but no `hours`, so its DETAILS card shows no hours line at all — `Listing.swift:643-652` (fine, but the walk's screenshot will look thinner than the others).
- `DesignStyle.systemImage` for as-is is `house` on every type — `Render.swift:34` (unused by the tour flow).
- `AgentCard` stores the org under a field named `brokerage` for every type — internal naming only, the UI labels are right (`SettingsView.swift:1202, 1221-1223`).

### Not a bug, worth knowing

- `SpaceType.current` reads `UserDefaults` on every access (`Listing.swift:322-324`); `-space.type` in the launch arguments therefore *overrides* every switch the UI makes (NSArgumentDomain wins) — which is why `IndustryWalk` selects the type through the Home menu and only pins `-space.type` as a fallback.
- Cards are namespaced per industry (`SettingsView.swift:1221-1223`) but only the org's *primary* type reaches the hosted brand kit (`:1243-1293`); the footers say so (`:421-427, 1496, 1508-1510`).
- Samples carry deterministic ids per type (`Listing.swift:561-591`) and are never persisted; the walk's cross-type isolation checks (`Walk Test Venue` never listed under Places, etc.) pass on that design.

---

## 3. Coverage: what the simulator walk proves and what it cannot

| Area | In `IndustryWalk` (simulator, `-uiTesting`) | Needs a device and/or the live backend |
|---|---|---|
| Business-type switcher (Home menu) | ✓ driven for real, hero re-theme checked | — |
| Home hero / sections / partners | ✓ + vocabulary scan | — |
| Collection tab, sample card, search prompt, cross-type isolation | ✓ | — |
| Sample detail: player kicker, toolbox dimmed, DETAILS rows, LEADS sample stats | ✓ | player video itself (`demo.mp4` is untracked) |
| New-listing form: per-type fields, placeholders, no beds/baths off real estate | ✓ (details disclosure expanded) | video pick / record |
| "Which home?" gate → AI Photo Studio: chips per type, reel card disabled | ✓ (creates one project per type) | adding photos, any AI edit, Reel Studio, motion clips |
| Own project: Add-video card, MANAGE (archive verb, Zillow only on RE), edit sheet | ✓ | Mark as sold/archived round-trip to the server |
| Aerial intro sheet (form state) | ✓ | generation |
| Floor plan | ✓ upload path only | RoomPlan scan (LiDAR) |
| Leads (empty) | ✓ | real leads |
| Profile + card editor labels/footers | ✓ | hosted brand-kit sync |
| Settings: Business type preview (tags, detail chips, CTA), Plan & usage, paywall open/close, Legal, delete-account confirm → Cancel | ✓ | purchase, actual deletion |
| Publish, share cards, MLS card, COMPLIANCE card, hosted tour page + per-industry lead form | — | ✓ device + live backend |
| Fair-housing gate behaviour per industry (P1-1) | — | ✓ live backend (`curl` the edge functions with `space_type` and a hospitality prompt) |
| Onboarding intro + type picker | — (`-hasOnboarded YES` is in the argument domain) | ReviewerWalk / device |
| Capture coaching, area quick-tags during recording | — | ✓ device |

## 4. Suggested order of fixes

1. P1-1 — thread `space_type` into `assertFairHousing` / `assertMarketingCopy` and scope the people/audience tiers + the HUD copy to real estate (one shared module, three edge functions).
2. P1-2 + P1-5 — gate `shareSection`'s MLS card, `mlsLinkRow` and the AB 723 banner on `space == .realEstate`; re-word "Agent card + lead capture", the QR caption and "Email my broker" via `SpaceType` (`profileCardName`, a new `complianceContactNoun`).
3. P1-3 — give `RendpropPlan.tagline` a `SpaceType` parameter (or make it audience-neutral: "For one person shooting a few tours a month.").
4. P1-4 — hide the mortgage and Tract rows, or the whole "More from us" section, off real estate.
5. P1-6 — either bundle a per-type demo clip or hide the "See it in action" section and the sample player when `demo.mp4` is absent off real estate (the sample detail could show the DETAILS card first).
6. P2-1 / P2-2 — move the CTA label logic to one place (mirror `cta.ts` in `SpaceType.ctaTitle(for listing:)`) and update `INDUSTRY-LOGIC.md` to match what the hosted page already does.
7. P2-3 / P2-4 / P2-5 — the word list above, then a grep gate in CI: no literal `listing`, `agent`, `broker`, `MLS`, `buyers`, `staging` in a `Text(...)`/`Label(...)` outside an `if space == .realEstate` branch.

---

## 5. Fixed — 2026-09-06 (agent F, branch `launch`, working tree)

Real-estate behaviour and copy are unchanged on every screen and route below; each fix branches on
the listing's type (or `SpaceType.current` where no listing is in hand) and only the five other
industries see the new path. `swiftc -parse` passes on every touched Swift file; `Listing.swift`,
`Money.swift` and `Products.swift` also type-check on Linux. `deno check` passes on the four edited
functions and `deno test` runs 128/128 (13 new). Nothing was committed.

| Finding | What changed | Where |
|---|---|---|
| **P1-1** fair-housing gate | `assertFairHousing` / `checkFairHousing` / `assertMarketingCopy` / `checkMarketingCopy` take an optional `spaceType`. `isHousingSpace()` treats real estate, null, empty and unknown as housing (fail-safe: the full HUD rule set and wording, byte-for-byte). The five non-housing types skip every rule tagged `housingOnly` (steering, schools, neighborhood, familial status, religion, sex, places of worship) and the HUD/§3604 wording, keep the general safety layer — tier B (no people / minors / pets / flags / cultural items ADDED to an image), "a type of people", "the right crowd", "racial(ly)", the race-qualifies-people and "no foreigners" script rules, every disability exclusion — and are refused in Rendprop's own words. Non-housing scripts do not run the ADD-verb people tier ("seats 220 guests" passes). New `listingSpaceType()` reads `listings.space_type` through the caller's RLS client. Callers: ai-photo `custom` / `improve_prompt` (listing row → body `space_type` → housing); ai-video `declutter` (asset's listing), `aerial` (listing row → body), `reel-clip` (asset's listing → listing row → body); ai-voice `tts` (listing row → housing). ai-chapters is unchanged (still the full housing gate — listed 🔜 in INDUSTRY-LOGIC). | `services/supabase/functions/_shared/fairhousing.ts:75-120` (SCOPE + `isHousingSpace`), `:158-192` (tagged tier A), `:224-320` (`checkDenylist`, `assertFairHousing`, `nonHousingRefusal`), `:419-425, 489-668` (tagged script rules), `:680-782` (`checkMarketingCopy`, `assertMarketingCopy`); `_shared/supabase.ts:116-140` (`listingSpaceType`); `ai-photo/index.ts:56-63, 477-483, 511, 531`; `ai-video/index.ts:56-62, 634-635, 696-700, 833-838`; `ai-voice/index.ts:67-74, 529-534`. Tests: `_shared/fairhousing.test.ts` (13 cases: housing unchanged incl. the documented "seats twelve" false positive; non-housing passes hospitality vocabulary, still refuses added people and exclusions, never says HUD/housing/listing). Docs: `docs/VOICEOVER-CONTRACT.md:138-143`. |
| **P1-2** MLS link card | `Listing.serverUnbrandedURL` is nil off real estate, so the MLS card in SHARE and `mlsLinkRow` on the render screen never render for a bar / venue / store / gym; the `/u/` server route is untouched. "Agent card + lead capture" → `space.profileCardName` ("Business card + lead capture…" off real estate, identical on real estate); QR caption "flyers, sign riders, open-house sheets" → "flyers, counter cards, the front window" off real estate. | `Models/Listing.swift:110-117`; `Screens/FlythroughDetailView.swift:339-362`; `Screens/RenderStatusView.swift:317-325` (comment) |
| **P1-3** paywall taglines | `RendpropPlan.tagline` branches on `SpaceType.current`: real estate keeps both reviewed lines; others read "For one venue / restaurant or bar / store / gym or studio / business shooting a few tours a month." and "For a busy … shooting every week." (≤ 55 chars). New `SpaceType.businessNoun`. No other paywall string touched. | `Purchases/Products.swift:38-56`; `Models/Listing.swift:367-378` |
| **P1-4** "More from us" | Wholesale Mortgage Lending and Tract rows only on real estate; Pilk.ai stays for everyone; the section is byte-identical on real estate. | `RendpropApp.swift:2103-2118` |
| **P1-5** AB 723 / broker wording | The AB 723 banner needs `space == .realEstate` as well as California. Off real estate: "These sentences are published with your tour — every AI-altered photo or clip is labelled wherever the link goes.", "Export the audit log" (same CSV export), delete copy "…if you want to keep them on file." Photo-delete confirmation in the studio: "links buyers to the original… your broker" → the type's `customerNoun` / "keep them on file". Disclosure rows, "Download originals" and the audit export stay on every type. | `Screens/FlythroughDetailView.swift:688-694, 720-724, 739-741, 872-876, 2171-2174` |
| **P1-6** sample video | Every type plays the hosted demo (`rendprop.com/f/estate-demo?embed=1`) on Home; "Watch the sample tour" opens the full "Demo listing page" on real estate (unchanged) and the hosted flythrough titled "Sample tour" elsewhere. A non-real-estate sample's detail plays the hosted embed instead of the bundled player, so no industry meets "Sample video unavailable"; real estate's sample detail is unchanged. URLs live in `PlayerWebView.hostedDemoURL` / `hostedDemoEmbedURL` (optional, never force-unwrapped). One house tour for launch — per-industry slug listed 🔜. | `RendpropApp.swift:1564-1582, 2012-2018, 2035-2044`; `Screens/PlayerWebView.swift:112-120`; `Screens/FlythroughDetailView.swift:307-321` |
| **P2-3** tagger "rooms" | `SpaceType.areaNoun` / `areaNounPlural` ("room"/"area"); the tagger title, hint, "Suggest … names", "Custom … name", "No … tagged yet.", the two AI notes and the AI banner all use it. Real estate reads exactly as before. | `Models/Listing.swift:380-384`; `Screens/ReviewSubmitView.swift:453-457, 473, 537, 571, 656, 662, 673, 891, 899, 969-974` |
| **P2-4** shared-screen vocabulary | Home tile "Twilight · blue sky · staging" → "… furnish it" off real estate; aerial kicker "THE PROPERTY" → "THE VENUE / PLACE / STORE / STUDIO / SPACE"; aerial format line "…top of a listing video…" → "…top of your tour…"; floor-plan hint "…for a listing or a flyer" → "…for your website or a flyer"; studio empty state "clean the room, or stage it" → "tidy the space, or furnish it" (P2-7); Settings sign-out / clear-data "listing" → the type's noun (`localItemNoun`), Business-type screen "Your listings for every type are kept" → "Everything you've made under every type is kept". Not done (design call / shared before the type is picked): onboarding card 2, the AI consent sheet (5.1.2(i) disclosure — left verbatim), the P3 items. | `RendpropApp.swift:2582-2588`; `Screens/FlythroughDetailView.swift:2765-2769, 3706-3707, 3843-3846, 6167-6169`; `Screens/SettingsView.swift:61-67, 292, 355, 396-397, 1904-1906` |
| **P2-5** `SpaceType.current` vs the listing's type | `ReviewSubmitView.space`, `RenderStatusView.noun` and `LeadsView.noun` read the listing's own type; `AIPhotoEditRequest.spaceType` carries the listing's type and `LiveAPIClient.aiPhotoEdit` sends it (falling back to `SpaceType.current`). The tagger, `aiPhotoSuggest` / `aiImprovePrompt` and the reel-clip call have no listing in hand and are unchanged (reel-clip listed 🔜 — the server gate now reads the listing row anyway). | `Screens/ReviewSubmitView.swift:36-39`; `Screens/RenderStatusView.swift:55-57`; `Screens/SettingsView.swift:930-933, 983-984, 1006-1007`; `Networking/APIClient.swift:215-218`; `Networking/LiveAPIClient.swift:478-481`; `Screens/FlythroughDetailView.swift:2328, 2351` |

Not verified here (no simulator / device / live backend in this container): the SwiftUI files were parsed, not
type-checked; the `IndustryWalk` vocabulary scan and the four hosted/live-only checks (P1-1 with `curl`,
P1-2, P1-5 with provenance rows, the hosted embed full-screen on a phone) still need the device run.
Edge functions to redeploy: `ai-photo`, `ai-video`, `ai-voice` (`_shared` changes ship with each).
