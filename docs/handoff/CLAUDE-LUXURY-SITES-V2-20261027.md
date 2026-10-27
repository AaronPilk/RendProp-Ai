# Claude handoff: paid property sites v2 (Signature Estate, Coastal Luxe)

Date: 2026-10-27
Branch: `claude/luxury-sites-v2-20261027`
Base: `origin/codex/release-qa-integration-20261026` at `3fbed331ea7c61b0c5b45e0f775a14bfe23af7b5`
Target PR base: `codex/release-qa-integration-20261026`

Commits (oldest first):

- `ed8b89d6` Paid property sites v2: one control system, finished pages (`services/edge/tour-host/src/property-design.ts`)
- `49a33460` tour-host: premium-only markup for the finished paid pages (`services/edge/tour-host/src/player.ts`)

Everything here is presentation. No routing, entitlement, billing, lead-form, generation, URL, Supabase or native change. Classic and the unbranded MLS page are byte-identical to the base (proved by `check-premium-luxury.mjs`, exact against `6fc7485a`).

## 00. Why a v2

The first redesign (`CLAUDE-LUXURY-SITES-20261026.md`) replaced the opening and materials but left the rest of the page on the Classic skeleton. On the preview the owner pointed at the top bar ("looks just off and not aesthetically pleasing") and at "button layouts and spacing" generally, and set the bar at the kind of bespoke single-property site a photographer sells for real money. v2 finishes the whole page: one control system, every page, every breakpoint, with the listing's own data only.

## 01. What changed, by area

Navigation (`#listing-nav`, paid designs only)
- One rhythm at every width: 58px bar, 44px controls, 7px frame, 6px gaps, one type size. Pages on the left, the street name centred on screens 1180px and wider (brand link to Home, premium markup only), the film as the single filled control, every other action an outlined capsule of the same height. Back-to-top is the quiet variant.
- Glass over the opening (`--premium-glass`, .86 + blur); opaque under `prefers-reduced-transparency`, `prefers-contrast: more` and forced colours.
- 900px and below: page links hide and the existing page menu shows (markup unchanged). 600px and below: Share is icon-only (44px). Phones hide the brand.
- The accessible name "Play property video" is untouched; the walkthrough disclosure stays a separate control.

Hero controls
- Identical 50px capsules with balanced widths (`min-width:168px`); phones stack them 50%/100%. Signature labels white on the photograph, Coastal ink on sand. 320px-wide Signature gets a taller opening and higher play target so nothing collides.

Gallery (flat galleries only)
- `#gallery .lp-wrap > .lp-gal` is a six-track editorial grid: lead photograph full width (16:9), then a repeating cycle of three photographs (span 2, 4:3) and two wider (span 3, 3:2). Short last rows widen so the grid closes. Tablets (760–1023) two columns; Coastal phones two, Signature phones one. Room-grouped galleries keep the existing two-column rules. All 38 photographs render in published order; the viewer opens the complete photograph.
- The Gallery page head carries a photograph count (premium markup only).
- Viewer: one dark stage, serif single-line title, capsule prev/next/close, serif counter, 44px targets.

Overview figures
- Hairline grid (`box-shadow` hairlines, container `overflow:hidden`) that closes for any count: four across on tablets, three across on phones when there are exactly three, odd last item spans the row.

Location
- Address card beside a contour-line panel with a static pin (no infinite animation; `getAnimations().finished` must resolve). Two columns at 760px and up, stacked below. Nearby list restyled. Sub-page heads no longer repeat the display title.

Contact
- Without a form: a single 720px column. With a form: agent panel beside the enquiry. Name and phone share a row, 52px fields, full-width capsule submit. The presented-by agent panel labels each published fact (Title, Brokerage, Phone); Email stays in `.social` because the browser check requires `.agent .social a[href^='mailto:']`.

Closing
- Colophon band (premium, not embed, not unbranded) over the property's cover photograph with a dark gradient: address, price, page links with `aria-current`, the public listing contact. Everything in it is listing data already on the page. Compact app band; attribution footer as a hairline grid.

Breakpoints tuned: 320, 390, 430, 601–900 (Coastal split: balanced columns, 4:3 panel, smaller title), 768, 1024–1199 heading size, 1440, 1600+ widths.

## 02. Checks (local, Linux sandbox, Chromium headless)

- `node scripts/check-premium-luxury.mjs --evidence=…`: 173 passed (Classic/MLS exact vs `6fc7485a`; 855 Central Ave retained home and synthetic film at 390/1497; compact layouts 320/360/601/768/900/844×390; first-screen geometry; explicit play; separate walkthrough; reduced transparency; no external requests).
- `node scripts/check-property-site-browser.mjs`: OK (792+ assertions: contrast, 44px targets, viewer, room grids, no-JS, reduced motion).
- `node scripts/check-property-video-browser.mjs`: OK. `node scripts/check-property-video-controls.mjs`: OK.
- `npm test`: rc=0. `npx tsc --noEmit -p tsconfig.json`: clean.
- No check script was changed in this branch.

Chromium screenshots (both designs, Home/Gallery/Location/Contact, full page and first screen) at 390, 430, 768, 1024, 1440, 1920, plus the film playing and the viewer open at phone/tablet/desktop, and the live "before" captures, are in `Claude outputs/luxury-sites-v2-20261027/`.

## 03. Safari and the phone (honest status)

- Safari (macOS, WebKit): only the Signature Estate Home first screen was opened and looked at, from a static render of the real listing markup (`safari-pages/`). It rendered correctly (capsule bar, full-bleed opening, serif title, capsule actions). Gallery, Location, Contact, Coastal Luxe, scrolling, the film and the viewer were NOT looked at in Safari. The remaining static pages are in the same folder for the owner to open.
- iPhone: not verified. Reduce Motion, Reduce Transparency, VoiceOver, landscape and the film in Safari on the device remain owner items.
- The live Worker was not touched. The before screenshots came from the live preview; the after screenshots come from the Worker rendered locally from this branch.

## 04. Decisions for the owner

1. The 855 Central Ave cover photograph is a bathroom. The colophon and the opening both use it because it is the listing's selected cover. Change the cover in the app, not the layout.
2. Signature phones show the gallery one column (editorial), Coastal two. Say if you want them the same.
3. The nav brand (street name) appears at 1180px and up only. It can be lowered to tablets if the page menu is moved; not done here to keep the compact bar to two groups.

## 05. How to push and open the PR (Mac, has credentials)

```
cd "/Users/pilksclaes/Rendprop AI/RendProp-Ai"
git log --oneline 3fbed331..claude/luxury-sites-v2-20261027
git push -u origin claude/luxury-sites-v2-20261027
gh pr create --base codex/release-qa-integration-20261026 --head claude/luxury-sites-v2-20261027 --title "Paid property sites v2: finished Signature Estate and Coastal Luxe" --body-file "/Users/pilksclaes/Rendprop AI/Claude outputs/luxury-sites-v2-20261027/PR-BODY.md"
```

## 06. Re-verify in a full clone

```
cd services/edge/tour-host
npm ci
npx tsc --noEmit -p tsconfig.json
node scripts/check-premium-luxury.mjs --evidence=/tmp/rendprop-luxury-v2-proof
node scripts/check-property-site-browser.mjs
node scripts/check-property-video-browser.mjs
node scripts/check-property-video-controls.mjs
npm test
```

Expected: premium check 173 passed; all suites green.
