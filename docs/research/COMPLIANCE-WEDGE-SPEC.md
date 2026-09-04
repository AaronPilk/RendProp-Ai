# WAVE 2 — the compliance wedge + dual output

Repo: `/home/claude/rendprop` (branch on the Mac: `feature/compliance-wedge`, off `main` which now
contains the fix wave). Read `/home/claude/audit/BRIEF.md` for the product and the HARD RULES —
they all still apply (Optional persisted fields, destination-based navigation, no digital-goods
prices in the iOS binary, no new .swift files, Aaron@pilk.ai, enforced == published entitlements).

## Why we are building this (evidence, from `/home/claude/research/competitive-brief.md`)
1. **The lead-capture tour page cannot legally be attached to the MLS.** Unbranded virtual-tour
   rules explicitly ban "comment or contact forms, ratings … or social media profiles" and any
   agent/broker identification. The unbranded field is what syndicates to Zillow/Realtor.com.
   So today, the version buyers actually see is the one that cannot exist. Fines are real
   (RI Statewide MLS: $50 first branded-photo offense, escalating).
2. **AI disclosure is statutory and live.** California **AB 723, in force 1 Jan 2026**: disclosure
   of digitally altered listing imagery *and* access to the original unaltered versions;
   **up to $2,500 per violation** plus license risk. **NorthstarMLS (10 Jul 2026)**: altered images
   must be identified in caption/filename or on the photo, AND every altered room needs at least one
   unaltered "Before" image. **Wisconsin Act 69** extends to generated video 1 Jan 2027.
   HousingWire's disclosure test names simulated camera movement specifically — that is our aerial;
   its recommended language is *"Drone-style movement is simulated. No drone footage was captured."*
3. **Fair housing:** never render people, never render religious or cultural objects, never generate
   neighborhood/occupant narration (HUD guidance on AI in housing advertising).
4. This is the **only durable moat** the research found. Every competitor has the same exposure and
   none of them solve it well. It is sold to compliance officers and brokers, not only to agents.

## Vocabulary (use these exact terms in code and copy)
- **Branded link** — `https://rendprop.com/f/<slug>`. The agent's own link: agent card, CTA, lead
  form, socials. For email, social, texts, open-house QR. NEVER for an MLS unbranded field.
- **Unbranded link** — `https://rendprop.com/u/<slug>`. MLS-safe: the property and nothing else.
- **Altered media** — any asset an AI model changed or generated: photo edits (twilight, sky, lawn,
  declutter, staging, custom), reel clips, aerial intros.
- **Provenance record** — the row that ties an altered asset to its original + the model + when.

---

## W2-A — tour-host Worker (`services/edge/tour-host/**`) — OWNER: agent A

### A1. `/u/<slug>` — the unbranded, MLS-safe render
Route it next to `/f/<slug>` in `src/index.ts` (same `safeDecode` + 404 handling + caching).
Render with the SAME tour payload, but the page MUST NOT contain, anywhere in the HTML:
- the agent card, agent name, photo, phone, email, website, brokerage or socials
- any lead form, contact form, "Book a showing"/CTA button, deep link, or secondary link
- the Rendprop wordmark/logo, "Made with Rendprop", or any link to rendprop.com
- Zillow or any external link, share buttons, favicon wordmark, or portfolio link
It MUST contain: the property media (scroll-scrub player, chapters, gallery, floor plan),
the address/title, factual property details, and the **AI disclosure block** (disclosure is
property information and is required — it stays).
Also: `<meta name="robots" content="noindex">` on `/u/` (the branded page is the canonical one),
no beacon lead events (view metering may stay — see A4), and a self-check.

**Write a hard test for this.** Add `scripts/check-unbranded.mjs` that renders the unbranded page
for a synthetic tour whose agent card, CTA, socials and Zillow URL are all populated with unique
sentinel strings, then FAILS if any sentinel, or any of `rendprop.com`, `mailto:`, `tel:`,
`<form`, `<input`, `Book a showing`, appears in the output. Wire it into `npm run typecheck`'s
sibling script (`npm test`) and into `.github/workflows/ci.yml`.

### A2. AI disclosure block (both pages)
Render a `<section id="disclosure">` when the tour has altered media, containing:
- the existing staging sentence when `staged`
- **per-asset lines** from a new `tour.altered_media[]` (shape in W2-B): each with its label
  ("Living room — virtually staged", "Aerial intro — AI generated"), the model family in plain
  words ("AI image edit" / "AI video"), and a **"View original"** link to `original_url` when present
- for any aerial: the exact sentence **"Drone-style movement is simulated. No drone footage was
  captured."**
- a "Before / after" pair rendered side by side when both urls exist (NorthstarMLS requirement)
The block is visible on BOTH `/f/` and `/u/`, above the footer, collapsed by default on mobile with
a always-visible one-line summary. Keep the existing `#staged` chip.

### A3. Floor plan gets promoted (evidence: floor plans 57% "very useful" vs virtual tours 38%)
When `tour.floorplan_url` exists, render it in a `<section id="plan">` ABOVE the gallery on both
pages, with the room chapter names listed beside it; clicking a room name seeks the player to that
chapter (reuse the existing chapter-rail seek function). No new dependency.

### A4. Beacon/metering
`/u/` should still count a view (the agent's analytics need it) but must send `unbranded: true` so
we can report branded vs unbranded traffic separately. Do not fire lead events from `/u/`.

### A5. `X-Robots-Tag: noindex` header on `/u/`, canonical `<link rel="canonical">` on `/f/`
pointing at itself. Sitemap unchanged (never list `/u/`).

---

## W2-B — Supabase (`services/supabase/**`) — OWNER: agent B

### B1. Migration `0012_provenance_and_unbranded.sql` (idempotent, same style as 0011)
- `create table if not exists public.media_provenance (`
  `id uuid pk default gen_random_uuid(), org_id uuid not null references orgs(id) on delete cascade,`
  `listing_id uuid references listings(id) on delete cascade,`
  `render_id uuid references renders(id) on delete set null,`
  `kind text not null check (kind in ('photo_edit','virtual_stage','declutter','aerial','reel','other')),`
  `label text,                      -- "Living room", "Aerial intro"`
  `model_id text,                   -- fal/gemini model string`
  `edit text,                       -- twilight|sky|lawn|declutter|stage|custom`
  `style text,`
  `prompt_summary text,             -- short, no PII`
  `original_key text,               -- R2 key of the UNALTERED source, when we have it`
  `altered_key text,                -- R2 key of the result, when published`
  `disclosure text not null,        -- the sentence shown publicly`
  `created_at timestamptz not null default now())`
- RLS: members of the org may select; writes are service-role/definer only.
- Index `(listing_id, created_at)` and `(org_id, created_at)`.
- RPC `record_provenance(...)` SECURITY DEFINER with the same role gate the other RPCs use
  (owner/admin/agent), so the edge functions can write it as the caller.
- `renders.unbranded_url` is NOT needed — the Worker derives `/u/<slug>` from the slug.

### B2. `tours/index.ts` returns `altered_media[]` and `floorplan_url`
`altered_media`: `[{ label, kind, disclosure, original_url, altered_url }]` built from
`media_provenance` for the render's listing (public read is fine — it is disclosure), newest first,
capped at 40. `original_url`/`altered_url` via `publicR2Url()`; null when the key is private.
Also return `unbranded_url` alongside `share_url` so the app doesn't have to build it.
The demo tour gets a representative `altered_media` entry so the demo shows the feature.

### B3. Write provenance on every generation
- `ai-photo/index.ts`: after a successful edit, `record_provenance` with kind
  (`stage`→`virtual_stage`, `declutter`→`declutter`, else `photo_edit`), the edit, style, model,
  and the disclosure sentence. **Also add explicit fair-housing guardrails to every prompt**:
  append "Do not add or alter people, pets, religious or cultural objects, flags, or signage.
  Do not change the exterior, the view out of windows, or any permanent feature." to each edit
  prompt, and REFUSE (400, code `unsupported_edit`) a custom prompt matching a small denylist
  (people/person/family/child/kid/couple/religious/church/cross/flag/neighborhood/school district).
- `ai-video/index.ts`: same for `aerial` (disclosure = the HousingWire sentence) and `reel`.
- Add `POST /me/compliance-report?from=&to=` (or `GET /me/compliance` — your call, document it)
  returning every provenance row for the org, member-gated, with a `format=csv` option — this is
  the broker-exportable audit log.

### B4. `uploads` accepts `role:"original"`
So the app can publish the untouched original of an altered photo to the PUBLIC renders bucket
(key `renders/<org>/<listing>/original-<asset>.jpg`) and CA AB 723's "access to the original"
requirement is satisfiable by a public link. Same verification path as the poster.

---

## W2-C — iOS (`apps/ios/Rendprop/**`) — OWNER: agent C
File ownership inside iOS: agent C owns `Screens/FlythroughDetailView.swift`,
`Screens/SettingsView.swift`, `Models/*.swift`, `Networking/*.swift`, `Upload/*.swift`,
`RendpropApp.swift`. Do not touch tour-host or supabase.

### C1. Both links, everywhere sharing happens
`Listing` gains `var unbrandedShareURL: String?` (Optional, decodeIfPresent, from `unbranded_url`
on publish). The share sheet and the detail screen present **two clearly-labelled links**:
- "Your link — agent card + lead capture. Email, social, texts, QR."
- "MLS link — unbranded. Safe for the MLS virtual-tour field."
with a copy button each, and a one-line warning under the MLS one: "Never put your branded link in
an MLS unbranded field — most MLSs fine for that." QR generation offers both.

### C2. Compliance card on the listing detail
A `COMPLIANCE` section listing every altered asset for the listing (from a new
`api.provenance(listingServerID:)`), each row: label, what was changed, "View original" when
available, and a green/amber state. Plus a "Download originals" action (writes them to Photos) and
"Email my broker the audit" (share sheet with the CSV from B3). If the listing is in California
(the geocode's `administrativeArea == "CA"`) show a stronger banner: "California requires disclosure
and access to originals for altered listing media (AB 723)."

### C3. Before / after is captured, not reconstructed
The photo studio already keeps the original. When an AI edit succeeds, upload the ORIGINAL too
(`role:"original"` per B4) so `original_url` is real, and pair them. Never delete an original that
backs a published altered asset — `wipeLocalData` may, but `remove(listing:)` must warn.

### C4. Aerial + staging disclosure in-app
The aerial result view shows the exact simulated-movement sentence and it is included in the
share text. The Photo Studio shows "This edit will be disclosed on your tour" next to the AI actions.

---

## W2-D — verification (owner: agent D, after A–C land)
1. `npm run typecheck` + the new `npm test` (unbranded sentinel check) in tour-host.
2. `deno check` every changed edge function.
3. A SQL invariant added to `services/supabase/tests/invariants.sql` asserting
   `media_provenance` RLS is enabled and the RPC is not executable by `anon`.
4. Render both `/f/` and `/u/` for a synthetic tour and diff them: the unbranded output must be a
   strict subset (no sentinels), the branded one must still contain the agent card and form.

---

## Reporting
Each agent writes `/home/claude/wave2/report-<letter>.md`: what changed (file:line), what you
deliberately did not do, anything another owner must apply, and a self-review checklist.
Do not edit files outside your ownership; write cross-cutting needs into the report.
