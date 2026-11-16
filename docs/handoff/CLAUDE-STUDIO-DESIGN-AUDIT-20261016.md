# Rendprop Studio — screen-by-screen design audit and proposal (2026-10-16)

Design lead lane (Claude). Reviewed the rendered desktop Studio at
studio.rendprop.com (signed in, read-only, 1372px) and the synthetic connected
fixture at 1440px and 390px in light and dark (`tests/design-screenshots.mjs`).
Benchmark: the Pilk AI marketing sites — large tightly-tracked system-sans
headlines, tiny numbered uppercase eyebrows, generous whitespace, quiet cards with
soft shadows, one violet accent, restrained settle-in motion. Rendprop purple stays.

## What the current Studio gets right

Solid information architecture (Create / My Listings / Media / Business, a
single "Working on" listing context, numbered listing tabs), light/dark tokens
already shared with the iPhone app, 44px controls, visible focus rings, honest
copy about what is optional, a mobile bottom tab bar, and reduced-motion handling.
None of that changes.

## Screen-by-screen findings

| Surface | What a realtor sees today | Why it reads as "a computer" | Proposal |
|---|---|---|---|
| Shell: sidebar / topbar | Flat sidebar, "YOUR STUDIO" label, device card with a paragraph, topbar with appearance `<select>`, text status, account pill | Chrome is opaque and heavy; three competing text sizes in the sidebar; the device card is a paragraph in a purple box | Translucent topbar and bottom tab bar (blur + saturate, solid fallback); quieter nav rows with a soft selected pill; device card becomes a one-line hint with its action; status becomes a dot + short label |
| Home (overview) | Full-width purple-to-indigo gradient hero, white CTA, then listing cards with placeholder house icons, then "All tools" accordion, orange leads banner, 3-step explainer | Two saturated gradients compete with the content; cards don't show the home; explainer is a wall | Hero becomes a surface card with a faint accent glow and one primary action; listing cards show the cover (when available) with a status chip; leads banner becomes a quiet row; explainer collapses to a compact 3-step strip |
| My Listings: header | Eyebrow + 2.5rem title + sentence + "+ New property" + "Working on" bar | Fine, slightly tall | Tighter display tracking, 28–32px title, the switcher reads as a toolbar |
| My Listings: "Finish this listing" | Large card: next-step purple box, 5-column checklist with Saved/Next/Optional/Review badges, tiny links | The checklist is the most useful thing on the page but has the least visual weight; two stacked boxes before any photo | Keep the card first; next-step row becomes a single line with the action on the right; checklist items become a compact row of status chips + labels; links become small secondary buttons |
| My Listings: tool cards | Four cards in orange→pink, teal→blue, violet, grey gradients with "AI" pills | The single loudest thing on the screen; the grey "Coming soon" card looks broken; colour has no meaning | One card style: surface, hairline, 36px tinted icon chip in the accent, title + one line; "AI" becomes a small neutral label; Aerial reads as a plain disabled card. Make a video and AI Photo Studio sit first |
| My Listings: tabs | Underlined tabs with numbered circles | Fine; numbers add clutter on phone (already hidden) | Segmented control look (pill track) so it reads like a native tab bar; numbers kept as small ordinals |
| Media tab: import + stats + grid | Purple "Bring the property into focus" panel, 0/0/0 stat strip, grid of cards each with "Property photo / Source photo / Open photo ↗ / Prepare for listing" and full-width buttons | Every card repeats five lines of the same text; the only differentiator (orientation) is a plain word; the grid is 4 identical buttons wide | Media tile: image with a top-left orientation chip (Landscape ▭ accent, Portrait ▯ neutral, Square, Unknown), top-right "n of N / Cover"; compact meta line; one primary action and the rest as small secondary controls; AI-altered badge as a chip on the image |
| Empty media state + fine print | Centered paragraph, then two paragraphs of storage/format rules | Walls of explanation | Empty state: glyph + one sentence + one button; rules become small print in a `details` the way "Photo tips" already works (markup proposal for Codex; CSS reduces size now) |
| Create & publish tab | Contact form, client preview card, green verification box, long "smooth workflow" numbered guide, Published tours with 7 same-weight buttons | Three competing boxes; every button looks like every other | Form in one card with a clear primary; verification becomes an inline status row; guide collapses; published tour actions become one primary (Open) + secondary row |
| Make a video | Property select, red-stripe error, "1. Choose your photos" with Select up to 100 / Clear, a `fieldset` with two giant native radios, Voice/Advanced disclosures, a detached consent checkbox, Create/Refresh buttons | Native radio circles are the largest things in the panel; consent checkbox floats above its label; "Listing video" vs "Social media" is not visually distinct (16:9 vs 9:16) | Format picker becomes two selectable cards with a 16:9 / 9:16 glyph, the selected one in accent tint with a check; consent as an aligned checkbox row; sticky bottom action bar on phone with the one primary action |
| Create (editor) header | "Make a video" / "Advanced desktop editor" toggle buttons, eyebrow "Photos → a finished video" | Toggle reads as two unrelated buttons | Segmented control; "Make a video" (simple) vs "Advanced" |
| AI Photo Studio (Creative) | Three nested tab rows (Property tools/Prompt library → 7 tools → Original/Decluttered/Staged/Saved), unstyled native file input, "2147483601 of 2147483647 photo edits remaining", 2-column giant edit buttons, paragraphs | Too many navigation levels at once; a raw `<input type=file>`; the allowance line leaks an integer sentinel | Top level = segmented control; tool row = pill chips; version row = small segmented; file input becomes a dashed drop zone with a button; edit choices become compact radio chips; the allowance sentinel is a copy defect for Codex (show "Unlimited" when the allowance is the sponsorship sentinel) |
| Listing chooser dialog | Centered dialog, list of listing buttons, heavy blur | Page scrolls behind it; current listing is absent from the list; buttons are full-width | Scrim + thinner blur; body scroll locked (one line in `FeatureGate` — proposal); list rows with chevrons; keep behaviour |
| Media (library) | Two-pane spaces list + media | OK; selected row is a purple block | Selected row becomes a soft pill; media grid tiles share the listing tile style |
| Business | Eyebrow "YOUR BUSINESS", "Leads" h1 after "Business" h1, pill tabs, filters, account cards | Two h1-sized titles; chips look like buttons | One title; segmented control; filter row as a toolbar |
| Phone (390) | Everything stacks; bottom tab bar; onboarding role picker above the page; cards keep desktop padding | Padding and type sizes are desktop sizes; checklist is a very long column | Phone spacing scale (16px gutter, 14px card padding), 15px body, sticky primary action, bottom bar as material |

## Visual system (what the implementation adds)

- **Type**: system SF stack; display 32/28/22 with −0.02em tracking, body 15px/1.5, small 13px, eyebrow 11px uppercase +0.08em. Same font; no new web fonts.
- **Spacing**: 4-point scale (4/8/12/16/20/24/32/40); 16px phone gutter.
- **Surfaces**: `--surface` cards with 1px hairline and a soft shadow; **materials** for the topbar, mobile tab bar and dialogs (blur 20px + saturate, 72% background, solid fallback, honours `prefers-reduced-transparency` and `prefers-contrast`).
- **Colour**: the existing purple accent only (`#7c3aed` light / `#9b6dff` dark). Status colours stay for status. Rainbow feature gradients removed.
- **Controls**: 36px default height on pointer devices, 44px on touch; primary (accent fill), secondary (surface + hairline), quiet (text); compact 32px chips; checkbox/radio 18px aligned to the first line.
- **Motion**: 160–220ms ease-out for hover/press, 0.98 press scale, 240ms fade for appearing panels; reduced motion → opacity only, no transforms.
- **Focus**: 2px accent ring with 2px offset everywhere.
- **Orientation**: landscape/portrait/square/unknown chips on every photo tile, using the existing `orientation` data from `video-framing.ts`; no new detection logic.

## Out of scope / proposals for Codex (behaviour, not styling)

1. Allowance sentinel copy in AI Photo Studio (`2147483601 of 2147483647`) → "Unlimited on your plan".
2. `FeatureGate` body scroll lock and including the current listing in the chooser list.
3. Move the media fine print (file limits) into a `details` like "Photo tips".
4. Published-tour actions: one primary "Open tour", the rest in a secondary row (markup order).
5. Make a video: when exactly one listing exists, preselect it (currently "Choose a property").
