# HANDOFF — area H (public web tour-host) → iOS and Supabase owners

Written closing the P1/P2 backlog for `services/edge/tour-host/` (findings
F-H-03 … F-H-20, branch `p12-H`). Everything below is a change **outside**
`services/edge/tour-host/`, so this wave did not make it. Each item says
exactly what to change and why the web side needs it.

Ordered by user impact.

---

## 1. `agentcard.ts`: let the org-level promo and indexing switches through — F-H-17 / F-H-19

**File:** `services/supabase/functions/_shared/agentcard.ts`

The tour page now honours four owner preferences. Three of them already work
through `listings.details` (which `tours/index.ts` forwards untouched, and the
app already writes with `PATCH /listings/:id { details }`), but the *org-level*
form of the same switch is silently dropped, because `buildAgentCard()`
allow-lists the brand-kit fields it copies into `agent_card`.

Add these five keys to `AGENT_CARD_FIELDS`:

```ts
const AGENT_CARD_FIELDS = [
  "title", "brokerage", "phone", "email", "website",
  "avatar_url", "headshot_url", "instagram", "linkedin", "tiktok", "accent",
  // audit F-H-17 / F-H-19 — read by services/edge/tour-host/src/player.ts
  "show_partners", "show_financing", "lender_name", "lender_url", "allow_indexing",
] as const;
```

`services/supabase/functions/me/index.ts` (`BRAND_FIELDS`, the `PATCH /me/brand`
allow-list) needs the same five, with:

- `show_partners`, `show_financing`, `allow_indexing` — booleans;
- `lender_name` — string, ≤ 80 chars;
- `lender_url` — string, must parse as `https:` (the Worker scheme-checks it
  again with `safeUrl`, but a 400 at write time is a better error).

What each one does on the public page (`src/player.ts`, `promoPrefs()` /
`allowsIndexing()`), read listing-`details`-first then brand kit:

| key | default | effect |
|---|---|---|
| `show_financing` | **off** | shows the "Get pre-approved" lender CTA under the payment estimate. Off because it names a specific mortgage company on the agent's own listing page — RESPA §8 exposure is theirs, and most brokerages have an affiliated lender. The neutral monthly estimate always renders either way. |
| `lender_name` + `lender_url` | unset | the owner's OWN lender. Setting both turns the block on automatically and relabels it "Lender chosen by the listing owner". |
| `show_partners` | on | the Pilk.ai / Wholesale Mortgage / Tract cards in the footer. Now labelled "Promoted by Rendprop … not endorsements by the owner of this listing". |
| `allow_indexing` | **off** | `/f/<slug>` is `noindex, nofollow` until the owner opts in. |

**iOS:** two toggles in the Agent/Business card editor — "Show Rendprop's
partners on my tour pages" and "Let search engines index my tour pages" — plus
an optional lender name + URL pair. Both are one-line `PATCH /me/brand` calls
once the allow-lists above exist. Until then the switches are only reachable
per listing via `details`, which no screen writes.

---

## 2. iOS: upload the headshot — F-H-05

The Worker side is done: `extractAgent()` reads `headshot_url` and `logo_url`
(and refuses to print anything that looks like an email address as a name), and
`tours`/`portfolio` no longer fall back to `orgs.name`. But the headshot still
never leaves the phone — `AgentCard.saveHeadshot` writes it locally and
`SettingsView`'s brand sync sends name/brokerage/phone/email/website/socials
only — so the public card is initials for every real user.

In `AgentCardEditorView`:

1. `POST /uploads/batch` with `kind: "photo"` into the **public** bucket;
2. `PATCH /me/brand { headshot_url: <public R2 URL> }`;
3. also send `title` and `accent` — the server already allow-lists both and the
   page already renders `title` under the name and `accent` as the page accent.

Marketing copy that claimed "your face on every tour" has been removed from the
site in the meantime, so nothing is over-promising while this is open.

---

## 3. iOS: write the microsite data the listing page reads — F-H-03

For non-real-estate listings the page is now complete: `renderIndustrySection()`
renders the exact camelCase keys `SpaceType.detailFields` collects (capacity,
event types, catering, cuisine, price range, hours, menu, weekly special,
membership/day-pass price, free-trial offer, departments, shopping options,
amenities, booking/reservation/store URLs). Nothing is dropped any more.

For **real estate** the app still collects no details at all
(`Listing.swift: case .realEstate: return []`), so a real RE tour renders the
overview tiles, the chapter chips, the agent card and the form — and nothing
else. The page reads all of these when present:

| key in `listings.details` | shape | source tool |
|---|---|---|
| `gallery` | `[{ url, label }]` (public R2 URLs) | Listing photos |
| `floorplan_url` | string | Floor plan (RoomPlan export) |
| `reel_url`, `reel_poster` | string | Reels |
| `story` | string, blank-line-separated paragraphs | a "Listing page" editor, or AI-drafted |
| `features` | `{ "Group name": ["item", …] }` | same editor |
| `neighborhood` | `{ blurb, commute: [{ time, label }] }` | same editor |
| `year_built`, `acres`, `lot`, `garage`, `frontage`, `hoa` | string | listing form |

The marketing copy has been softened to "sections appear when you've filled
them in and hide when you haven't", so the site is honest today — but the
"single-property website" is only fully real for RE once these are written.

---

## 4. Demo media belongs in R2, not in Static Assets — F-H-10

`public/assets/demo-tour.mp4` and `demo-reel.mp4` are not in git (they sit just
under the 25 MiB Workers Static Assets per-file cap), so a fresh clone deploys a
demo with no video. This wave added `npm run check:assets` (wired into
`npm run predeploy`) so the deploy now fails loudly instead of silently, and the
player already degrades to "This tour's video isn't available right now" rather
than a black stage.

The real fix is to host the demo like a real tour: put the all-intra 1080p
master in the **public R2 bucket**, point `src/demo.ts` at absolute URLs, and
keep only posters/stills in `public/assets`. That also removes the 1.4 Mbps /
642p compromise the size cap forced, and lets the demo exercise the `hls_url`
fallback path. Needs whoever holds the master file plus the R2 bucket
credentials; the `demo.ts` change is one line per URL.

---

## 5. Player engine: one source, not three — F-H-20

`src/player.ts` now declares itself the canonical engine in its header comment,
and the iOS copy (`apps/ios/Rendprop/Resources/player/index.html`) has caught
up on the fixes that mattered (decaying jank watchdog, `Math.max(1, …)`,
`readyState > 0`, rail clamp) and now has `VIRTUALLY_STAGED` injected from Swift
(`PlayerWebView.swift:288`). Two things are still owed:

- **`apps/web/player/`** is a dead prototype referenced only by READMEs. It
  still carries the naive watchdog and crashes on an empty `CHAPTERS` array.
  Delete it, or move it to `docs/archive/`.
- **The sync is still manual.** Extract the engine into one source file under
  `services/edge/tour-host/src/engine/`, build it into `ENGINE_JS`, and copy it
  into the iOS resource from an xcodegen pre-build step (or a `make
  sync-player`). Until then the two will drift again — that is exactly how the
  hosted copy ended up behind the iOS one.
- The iOS preview also does not render the per-industry `lead_fields`, so the
  in-app preview does not look like the published page.

---

## 6. Smaller Supabase items

- **`tours/cta.ts`, retail (F-H-12):** the retail email opt-in is returned
  unconditionally as `lead_fields: ["email"]`. The spec calls for an owner
  toggle defaulting OFF — add `promoOptIn` to the retail `detailFields` in
  `Listing.swift` and return `lead_fields: []` when it is off. (The *mislabelled*
  half of this finding is fixed: the Worker's `formCopy()` now renders the
  email-only form as "Get deals and updates" regardless of `cta.label`, so the
  "Get directions" heading on a sign-up form is gone.)
- **`orgs.handle` (F-H-02, out of this wave's range but still open):**
  `PATCH /me/brand` accepts and validates `handle` and `me` returns
  `portfolio_url`, but no iOS screen sets it, so every `/a/<handle>` is still
  the branded "No portfolio here yet" page. The Worker route, renderer and
  function are all ready. All portfolio claims have been removed from the
  marketing site in the meantime.
- **Lead notification (F-H-04):** delivery is real end to end now — `POST
  /leads` → `leads` row → RLS `"org leads"` select → `GET /leads` →
  `LeadsView` (Home banner, Settings, and per-listing). There is still no push
  or email when a lead lands, so the agent only sees it when they open the app.
  The in-app banner says "email alerts are coming" and the public page no longer
  promises a reply, so nothing is lying — but an email from `leads/index.ts` to
  `brand_kit.email ?? profile.email` is the obvious next step.

---

## 7. Deliberately NOT changed in this wave

- **`wrangler.toml` `compatibility_date = "2024-09-23"`** (F-H-21). Bumping it
  changes Workers runtime semantics, and this wave shipped compliance-critical
  changes to the same Worker. It should be bumped and deployed on its own, with
  a `/f/estate-demo` + `/u/<slug>` smoke test against the preview, not folded in
  here. Nothing in the current code depends on a newer date.
- **The R2 bucket question behind F-H-01** (which bucket
  `pub-70303ef2…r2.dev` is bound to). Still unanswered from the web side; the
  player's "video unavailable" state means a dead object no longer produces a
  black page with a recorded view, but the underlying 404 is a backend fix.
- **The demo agent card routes to Pilk** (`aaron@pilk.ai`,
  `instagram.com/pilk.ai` under the fictional "Alexandra Reyes / Meridian
  Estates"). Left as-is because it is deliberate on Rendprop's own demo, but it
  is a product decision worth confirming — a buyer emailing the demo agent is
  emailing Pilk.
