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

## Cross-cutting next phase (🔜)
1. **Tour end-card lead form** should render the per-type extra fields + deep-link CTA (currently the in-app detail screen deep-links; the shared HTML tour only adapts the CTA *label*). Needs form-field injection + JS in `player/index.html`.
2. **Live Open/Closed** from `hours` (restaurant/retail/gym) — a small parser + status pill.
3. **Signature features** per type above (packages, promo banner, product highlights, capacity notes, aisle guide) — all offline-safe, mostly additive data on existing models.
4. **Backend** turns tour + portfolio links into hosted URLs and captures leads server-side.

Competitor benchmarks that shaped this: Peerspace/Tagvenue (venues), Resy/OpenTable + Google Business Profile (restaurants), Google Business Profile + Instagram Shopping (retail), Mindbody/Glofox/ClassPass (fitness).
