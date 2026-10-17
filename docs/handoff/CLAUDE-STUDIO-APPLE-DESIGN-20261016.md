# Claude → Codex handoff: Rendprop Studio Apple-inspired design (2026-10-16)

Lane: `claude/studio-apple-design-20261016`, based on
`160efdc68e25884170aecf9970a18e6bb432f036`. Cloud clone only; the shared
`build82-launch-checklist` checkout and Codex's uncommitted App.tsx / CI work
were not touched. Nothing was pushed, deployed, published or generated.

Audit and proposal: `docs/handoff/CLAUDE-STUDIO-DESIGN-AUDIT-20261016.md`.

## Patch series (`git format-patch 160efdc..HEAD`)

| # | Commit | Files | What |
|---|---|---|---|
| 1 | `1e50609` studio: Apple-inspired design layer | `apps/studio/src/design/studio.css` (new, ≈9.0 kB gzip after both passes), `src/main.tsx`, `tests/fixtures/{connected,appearance,branded}.tsx` (one import line each), `src/features/listings/GalleryPhotoCard.tsx` (one line) | One stylesheet loaded after `styles.css` that restyles every surface; orientation chip class + `data-orientation` on the existing span |
| 1b | studio: interaction pass ("the Apple feel") | `apps/studio/src/design/studio.css` only | Pointer-down press feedback on every pressable surface (nav rows, cards, tabs, format/preset cards, gate rows), dialogs and the phone "More tools" menu materialize in (opacity + scale + blur via `@starting-style`, origin anchored to the source), views settle in with a 6px rise, scroll-edge gradients instead of hard topbar/tab-bar dividers, vibrancy weight on text over materials, `touch-action: manipulation` and no tap highlight, thin overlay scrollbars, `text-wrap: balance/pretty`; reduced motion keeps 160ms cross-fades and removes every transform and blur |
| 2 | `140933b` studio tests: design review scripts | `apps/studio/tests/design-screenshots.mjs`, `apps/studio/tests/design-a11y-probe.mjs` (new) | Before/after screenshot rig and accessibility/responsive probe over the synthetic fixture; not wired into CI |
| 3 | docs | this file, the audit | — |

**App.tsx: no patch.** The design layer is imported from `main.tsx`, so no
App.tsx change was needed; Codex's uncommitted App.tsx work is unaffected.

Nothing in `services.ts`, server APIs, auth/authority, selection or ordering
rules, jobs/recovery, provider routing, consent, cost accounting, billing,
pricing ($25 premium website untouched), CI or deploy configuration changed.
No markup or copy changed apart from the one `className`/`data-orientation`
addition; the visible orientation text is identical, so existing locators
(`getByText('Landscape')`, `/^Source photo · (Landscape|…)$/`) still match.

## What the design layer does

- **Type**: system SF stack; display 32/28/22 at −0.02em, body 15px/1.5,
  small 13px, 11px uppercase eyebrows. No web fonts.
- **Spacing**: 4-point scale; 40px page gutter → 24px tablet → 16px phone.
- **Surfaces**: `--surface` cards with 1px hairline + soft shadow. Translucent
  materials (blur 20px + saturate 180%, 72–86% opaque, solid fallback) only on
  the topbar, phone tab bar and dialogs; `prefers-reduced-transparency`,
  `prefers-contrast: more` and `forced-colors` all fall back to solid.
- **Colour**: the existing purple (`--accent`) is the only accent; rainbow
  feature-card, hero and leads-banner gradients are replaced by surface cards
  with a tinted icon chip; status colours stay for status.
- **Controls**: 40px pointer / 44px touch, primary (accent fill), secondary
  (surface + hairline), quiet (text), 24px chips. Tabs, creative tabs and the
  simple/advanced editor toggle read as segmented controls. Make a video's
  format picker is two selectable cards with a 16:9 / 9:16 glyph; the consent
  checkbox is aligned to its label; the raw file input sits in a dashed zone.
- **Media tiles**: orientation chip top of the meta block (Landscape in the
  accent tint, Portrait/Square/Unknown neutral, glyph via `::before`), small
  secondary actions, compact meta.
- **Motion**: 140–260ms ease-out hover/press, 0.98 press scale; reduced motion
  removes every transform (verified below). 2px focus ring on all controls.
- **Phone**: material bottom tab bar, two-column media grid (one column ≤500),
  stacked format picker, 44px targets. Shell geometry mirrors the `styles.css`
  breakpoints (1150 / 800 / 500) so nothing overlaps.

Specificity note: feature chunk CSS (`listings.css`, `creative.css`,
`make-video.css`) loads after the main bundle, so every override for those
classes is scoped under `.studio-shell` (the existing App root class). The
touch block sits last in the file because media queries do not add
specificity.

## Executed checks (cloud clone, this lane)

| Check | Result |
|---|---|
| `npm run typecheck` | pass |
| `npm test` (`tsx --test tests/*.test.ts`) | 726 pass, 0 fail (same count as base) |
| `npx vite build` + `node scripts/check-dist.mjs` | passed; all-assets gzip **393,357 B** (base 385,885 B, +7,472 B) against the 400,000 budget; initial 147,560 / create 218,601 / with-large-video 224,877 (budgets 160,000 / 260,000). `connectedConfigVerified:false` is the usual no-env result, same as base. |
| Browser suites, this lane | pass: `theme-browser`, `browser-connected`, `listing-selection-browser`, `gallery-copy-browser`, `make-video-browser`, `make-video-consent-browser`, `listing-finish-browser`, `listing-workflow-browser`, `business-browser`, `creation-shell-browser`, `photo-preparation-browser` (11). fail: `creative-browser` (`Property accuracy review passed.` not found), `feature-entry-browser` (`Staging style › Scandinavian` button not found) |
| Same two suites at untouched base `160efdc` | fail with the **identical** locator errors → pre-existing, not caused by this lane (logs in evidence `browser-logs/base-*.log`) |
| `tests/design-a11y-probe.mjs`, this lane | passed: contrast light/dark 465 samples each, 0 below WCAG AA; focus 72 tab stops all with a ≥2px ring; 0 horizontal overflow at 390px across 6 views; 190 phone controls all ≥40px; reduced-motion hover: transition 0s, transform none |
| Same probe at base | failed: 128 light-mode samples below AA (80 below 3:1 — mostly white text on gradient cards, which the probe cannot credit because it reads `background-color` only; treat as "unmeasurable", not "1:1"); 11 phone controls <40px (36px text buttons, 20–32px disclosure summaries); feature card still translates −3px on hover under reduced motion |
| Materialize check | after `networkidle`, every view root reads opacity <1 mid-transition and 1 / `transform: none` 600ms later on desktop and phone; phone "More tools" menu 0.56 → 1 | 
| Screenshots | 32 before + 32 after (+ `after-phone-more-tools-open.png`) (8 views × desktop 1440 / phone 390 × light / dark), 0 page errors, 0 external requests |

Not executed: the remaining 39 browser suites (time-boxed; none touch styling
contracts beyond those above), a build with the connected config, the real
iPhone, Safari and Firefox, VoiceOver/NVDA, and the deployed site. The live
studio.rendprop.com was inspected read-only at desktop width only (Chrome
could not be resized to 390 here; phone views come from the fixture rig).

## Evidence

`_bridge/build88-claude-studio-apple-design/` on the Mac:
`patches/*.patch`, `shots/before-*.png`, `shots/after-*.png`,
`shots/*-index.json`, `a11y-before.json`, `a11y-after.json`,
`browser-logs/*.log`, `build.log`, `DELIVERY-RECEIPT.json`. The external
drive was not a connected folder, so nothing was written there.

## Codex integration steps

1. `git am patches/0001-*.patch patches/0002-*.patch` on top of `160efdc`
   (or cherry-pick `1e50609`, `140933b`). The docs commit can be dropped or kept.
2. Rebuild and re-run `node scripts/check-dist.mjs`; expect ≈392.6 kB total
   gzip. Headroom is now ~6.6 kB, so any later CSS should replace rather than add.
3. Re-run the two pre-existing failures after Codex's App.tsx work lands; they
   fail identically at base and look like fixture/copy drift, not styling.
4. Optional: run `STUDIO_BROWSER_EXECUTABLE=<chromium> node tests/design-a11y-probe.mjs --out=…`
   as a manual gate before release.

Interaction notes: CSS transitions animate from the presented value, so every
hover/press here is interruptible by construction. Studio has no drag gestures
(photo order moves through buttons), so no spring/velocity JS was added; if a
drag-to-reorder lands later, use Pointer Events with capture, a critically
damped spring (damping 1.0, response 0.3–0.4) and momentum projection per the
Apple fluid-interfaces guidance rather than CSS transitions.

## Behaviour proposals for Codex (not implemented here)

1. **AI Photo Studio allowance copy**: `2147483601 of 2147483647 photo edits remaining` leaks the sponsorship sentinel; show "Unlimited on your plan" when the allowance is the sentinel.
2. **FeatureGate (listing chooser)**: lock body scroll while open and include the current listing in the list.
3. **Media fine print**: move the storage/format rules under a `details` like "Photo tips" so the empty state is one sentence and one button.
4. **Published tours**: order the actions so one primary "Open tour" leads and the rest sit in a secondary row.
5. **Make a video**: preselect the listing when exactly one exists instead of "Choose a property".
6. **Business page**: two h1-level titles ("Business", then "Leads"); demote the second to h2 in markup.
7. **Editor header**: the "Make a video / Advanced desktop editor" pair uses `aria-pressed`; a `role="tablist"` would let assistive tech announce it as the segmented control it now looks like.

## Memory / owner notes

- Codex's uncommitted App.tsx pagination/authority fix and CI repair were not
  read, copied or replaced; this lane has no App.tsx diff.
- Paid generation stayed paused; no production data, credentials or private
  media entered the cloud clone (fixture accounts and synthetic listings only).
