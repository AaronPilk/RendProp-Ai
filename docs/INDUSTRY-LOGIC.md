# Rendprop — Per-Industry Logic (locked spec)

Rendprop adapts to the selected **business type** (`SpaceType`). Real estate keeps
its dedicated beds/baths/sqft/price. Every other type is **data-driven** from
`SpaceType.detailFields` → stored in `Listing.details [String:String]` → rendered
dynamically in New Listing (`DetailFieldsEditor`) and on the detail screen.

Field input types (`FieldInputType`): `text, number, price, priceRange, hours,
multilineText, toggle, url, singleSelect[…], multiSelect[…]`.

Primary CTA logic: if the type's `actionURLKey` field is set, the tour/detail
deep-links there (reservations / booking / online store / website); otherwise it
falls back to the lead form. Real estate uses the Zillow field.

Status legend: ✅ shipped · 🔜 next phase (specced, not built).

---

## Real estate (default)
- **Owner fields:** beds, baths, sqft, price (dedicated model fields). ✅
- **Customer info:** beds/baths/sqft · price · map · Zillow link. ✅
- **CTA:** "Book a showing" (lead form). Zillow deep-link secondary. ✅
- **Area tags:** Exterior, Entry, Living Room, Kitchen, Dining, Primary, Bedroom, Bath, Office, Garage, Backyard. ✅
- 🔜 Lead form extras: preferred showing date/time.

## Event venue
- **Owner fields** ✅: capacitySeated (number), capacityStanding (number), startingPrice (price), eventTypes (multiSelect), catering (singleSelect), spaceSetting (singleSelect), amenities (multiSelect), bookingUrl (url).
- **Customer info order:** starting price · capacity ("Seats 180 · 300 standing") · event types · indoor/outdoor · catering · amenities · map.
- **CTA:** "Plan your event" → bookingUrl if set, else lead form. ✅ (deep-link on detail)
- **Area tags** ✅: Entrance, Main Hall, Stage, Bar, Lounge, Patio, Garden, Kitchen, Restrooms, Green Room.
- 🔜 Lead form extras: eventDate, guestCount, eventType (from owner's eventTypes).
- 🔜 Signature: per-area **capacity notes** on tags ("Main Hall — seats 150 banquet"); **package tiers** (Silver/Gold/Platinum); **date-aware inquiry** (local blockedDates compare).

## Restaurant / Bar
- **Owner fields** ✅: cuisineType (multiSelect), priceRange (priceRange), hours (hours), reservationUrl (url), menuUrl (url), amenities (multiSelect), phone (text).
- **Customer info order:** cuisine + price ("Italian · Wine Bar · $$$") · open/closed status · amenities · map · Menu button · tap-to-call.
- **CTA:** "Book a table" → **deep-link to reservationUrl (Resy/OpenTable/Tock)** if set, else lead form. ✅ (deep-link on detail; menuUrl shows as a secondary link)
- **Area tags** ✅: Entrance, Dining, Bar, Patio, Private Room, Kitchen, Restrooms.
- 🔜 Lead form extras: partySize, date, time (30-min slots from hours), occasion, notes.
- 🔜 Signature: live **Open/Closed** computed from `hours`; persistent **Menu** button on the tour; smart reserve deep-link.

## Retail / Grocery
- **Owner fields** ✅: storeCategory (singleSelect), hours (hours), phone (text), onlineStoreUrl (url), weeklySpecial (multilineText), shoppingOptions (multiSelect), departments (multiSelect).
- **Customer info order:** name + category · open/closed · **weekly special banner** · shopping options · directions · departments · full hours · parking/access · tap-to-call.
- **CTA logic:** if onlineStoreUrl + online/delivery shopping → "Shop online"; else "Get directions" (Maps). "Get directions" always available as secondary. Lead form replaced by optional **email-only** promo opt-in (owner toggle, default OFF). ✅ (onlineStoreUrl deep-link on detail)
- **Area tags** ✅: Entrance, Front, Aisles, Produce, Deli, Checkout, Backroom.
- 🔜 Signature: **"find it in the store" aisle guide** (tags mapped to departments); **promo banner** with promoEndDate auto-expire; **product-highlight photos** (mark 2–4 photos as featured w/ caption + price).

## Gym / Studio
- **Owner fields** ✅: facilityType (singleSelect), membershipPrice (price), dayPassPrice (price), is247 (toggle), hours (hours), amenities (multiSelect), freeTrialOffer (text), bookingUrl (url).
- **Customer info order:** facility type · **free-trial banner** (if set) · pricing (membership + day pass) · 24/7 badge or hours · amenities · class schedule link · map.
- **CTA logic:** if freeTrialOffer → "Start free trial"; else class-based facility → "Book a class"; else "Book a session". If bookingUrl set, form → then open bookingUrl (capture lead AND hand off to Mindbody/Glofox). ✅ (bookingUrl deep-link on detail)
- **Area tags** ✅: Entrance, Reception, Main Floor, Weights, Studio, Cardio, Locker Room, Showers.
- 🔜 Lead form extras: fitnessGoal, preferredTime, interestedClass (prefill from tapped Studio tag).
- 🔜 Signature: **free-trial capture** flow (tags lead `trial_intent`); **amenity checklist** overlay; zone-guide tags.

## Other business
- **Owner fields** ✅: hours, phone, website.
- **CTA:** "Get in touch" → website if set, else lead form. ✅

---

## Cross-cutting — what is real-estate-only, by design ✅
Shipped 2026-09-06 from the per-industry review (`docs/qa/industry-review.md`, "Fixed"):
- **Fair-housing gate scoped by the listing's `space_type`** (`_shared/fairhousing.ts`). Real estate
  (and any missing/unknown type) keeps the full HUD rule set and wording. The five other types keep
  the general safety layer only — no people/pets/cultural objects added to an AI image, nothing that
  singles people out by race, origin or disability — and every refusal is worded as Rendprop's rule.
  `ai-photo`, `ai-video` and `ai-voice` read the type from the listing row (`listing_id`), falling back
  to the request's `space_type`, then to housing.
- **MLS unbranded link card + warning** — real estate only (`Listing.serverUnbrandedURL` is nil off
  real estate; the `/u/` route still publishes for everyone).
- **California AB 723 banner, "Email my broker the audit", broker wording** — real estate only; the
  AI-disclosure rows, "Download originals" and the audit export stay on every type.
- **Paywall plan taglines** speak the industry (venue / restaurant or bar / store / gym or studio /
  business); real-estate copy unchanged.
- **Home "More from us"** shows only Pilk.ai off real estate (mortgage + Tract are real-estate products).
- **Sample tour**: every type plays the hosted demo (`rendprop.com/f/estate-demo`) on Home and on the
  sample's detail — no "Sample video unavailable" on first run. Real estate keeps its bundled sample
  player on the detail screen and the full "Demo listing page".
- **Room tagger** says "area(s)" off real estate (`SpaceType.areaNoun`); shared screens use the
  listing's own type where one is in hand (`ReviewSubmitView`, `RenderStatusView`, `LeadsView`,
  `AIPhotoEditRequest.spaceType`).

## Cross-cutting next phase (🔜)
1. **Tour end-card lead form** should render the per-type extra fields + deep-link CTA (currently the in-app detail screen deep-links; the shared HTML tour only adapts the CTA *label*). Needs form-field injection + JS in `player/index.html`.
2. **Live Open/Closed** from `hours` (restaurant/retail/gym) — a small parser + status pill.
3. **Signature features** per type above (packages, promo banner, product highlights, capacity notes, aisle guide) — all offline-safe, mostly additive data on existing models.
4. **Backend** turns tour + portfolio links into hosted URLs and captures leads server-side.
5. **Per-industry demo tour** — a venue / restaurant / store / gym / other slug on the Worker
   (`tour-host/src/demo.ts` serves only `estate-demo` today), so "See it in action" shows the owner's
   own kind of space instead of a house.
6. **`ai-chapters` gate scope** — `postprocess.ts` still runs the full housing script gate on AI room
   descriptions for every type (its warning says "fair-housing rules"); thread `space_type` through
   `passesFairHousing` the way the other three functions do.
7. **Reel-clip `space_type`** — the app sends `listing_id` but no `space_type` for reel clips, so the
   server prompt (not the gate — that now reads the listing row) defaults to the real-estate reel
   prompt off real estate.
8. **In-app CTA labels vs hosted (`P2-1`)** — `SpaceType.ctaTitle` says "Visit us" / "Book a session";
   the hosted page publishes "Shop online" / "Get directions" and "Start free trial" / "Book a class".
9. **Onboarding card 2** still reads "virtual staging — pro listing photos" before a type is picked.

Competitor benchmarks that shaped this: Peerspace/Tagvenue (venues), Resy/OpenTable + Google Business Profile (restaurants), Google Business Profile + Instagram Shopping (retail), Mindbody/Glofox/ClassPass (fitness).
