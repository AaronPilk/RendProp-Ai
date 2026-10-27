# Claude handoff: Signature Estate and Coastal Luxe redesign (2026-10-26)

Branch `claude/luxury-sites-20261026` from `codex/claude-landing-handoff-20261026`
(`a924dce2`). Source-only: nothing deployed, no App Store action, no backend,
URL, billing or generation change. Owner contact: Aaron@pilk.ai.

## What changed

| File | Change |
| --- | --- |
| `services/edge/tour-host/src/property-design.ts` | `PROPERTY_DESIGN_CSS` rewritten: shared paid material system plus the two designs. The preview banner/watermark and Classic-facing rules at the top of the sheet are unchanged. |
| `services/edge/tour-host/scripts/check-property-site-browser.mjs` | Paid designs: film frame contained in its stage; identity on the poster below the play target (phones) or on/beside the media (desktop); reduced motion stills the poster backdrop. Classic assertions unchanged. |
| `services/edge/tour-host/scripts/check-property-video-browser.mjs` | Paid designs: contained frame instead of a 16:9 stage box; a full-bleed desktop opening is allowed only while the contained 16:9 frame fits the viewport height. |

Untouched: `player.ts`, `property-site.ts`, `property-video.ts` (byte-exact to
the handoff parent), routing, entitlement, lead form, video attach/beacon,
MLS/unbranded pages, dated-address URLs.

## Design

Both designs share one quiet system so they read as the same product:
system faces only (SF/Segoe body; a serif display per design), one floating
glass capsule navigation with 44px targets and an opaque fallback under
Reduce Transparency, hairline section rules instead of cards, capsule
controls (48px) with press feedback, a serif figure strip for the overview,
an editorial story spread, large photographs in published order, the agent
panel beside the enquiry form, and short opacity/transform-only motion that
is removed under Reduce Motion. Colour contrast is at or above 4.5:1 on
every checked text element.

**Signature Estate** — an architectural opening: the property's own poster
(or cover photo) fills the first screen under the navigation; the identity is
centred low with a pale-brass price; ivory editorial sections, sharp corners,
Iowan/Palatino display. Gallery sits on a deeper ivory band.

**Coastal Luxe** — sunlit and open: the identity beside a framed 16:9 panel
on sand, sea-glass accents, rounded materials (24–32px), Hoefler/Baskerville
display. On phones the framed panel comes first, then the identity.

**The film.** The selected listing video leads the site. It is explicit-play,
`preload="none"`, uncropped (`object-fit: contain`) with native controls,
exactly as before. Before Play the paid openings show the poster as a display
image (cropped like a photo opening); after Play the complete frame plays over
a softened still of itself, and on Signature phones the opening becomes a true
16:9 band with the identity below it. The optional recorded walkthrough stays
a separate action in the hero and the navigation.

Native-pixel note: the film's own frame is never cropped; only the poster
(a display image) is cropped before Play. Classic keeps its 16:9 stage.

## Checks run (LOCAL, Linux sandbox, Chromium headless shell 1243)

- `check-premium-luxury.mjs`: 134 checks passed — Classic/MLS markup, scripts
  and shared CSS byte-exact against `6fc7485a`; both paid designs at 390 and
  1497 with the actual 855 Central Ave retained home (38 photos, recorded-only)
  and the synthetic Listing film; identity/price/actions in the first screen;
  capsule targets; explicit Play loads the exact local master and plays with
  native controls; recorded walkthrough separate; reduced transparency opaque;
  no external API or telemetry fetch. Published R2/rendprop.com images may
  still load remotely; this check does not assert an entirely offline page.
- `npm test` (tour-host): all suites pass.
- `check-property-site-browser.mjs`, `check-property-video-browser.mjs`,
  `check-property-video-controls.mjs`: pass (the two layout contracts updated
  as described above; every other assertion unchanged).
- `tsc --noEmit`: clean.

Not run here: the live Worker, a physical phone, Safari. The owner should
view the preview on the iPhone (Build 123) before any deploy.

## Evidence

Before/after and playing-state screenshots were captured from the local
preview server (`scripts/preview-premium-luxury.mjs`) at 390×844 and
1440×900 for both designs, the 855 photo opening and the synthetic film, and
are attached to the PR. Regenerate with
`node scripts/check-premium-luxury.mjs --evidence=<dir>`.

## Integration QA update (2026-10-27, source only)

The integrated release branch adds a one-line listing-player navigation offset
correction and paid-site responsive fixes. The premium check still compares
Classic and MLS against `6fc7485a` after allowing only that exact offset line.
It now covers compact phone and intermediate tablet geometry that the original
390px check missed. Local Chromium results: 150 premium checks, 792 property-site
browser assertions, 83 property-video browser assertions, five injected video
controls, Tour Host tests, and TypeScript all passed. This is not Safari or
physical-iPhone acceptance. No Tour Host deployment or App Store release
occurred as part of this update. The retained 855 Central Ave cover/poster is
a bathroom; choose a suitable cover before showing the paid site to clients.
