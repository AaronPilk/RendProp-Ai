# Claude handoff: Rendprop luxury property landing pages

Date: 2026-10-26. Work from the GitHub branch `codex/claude-landing-handoff-20261026` in `AaronPilk/RendProp-Ai`. The repository's default `main` is older than the current TestFlight and property-site source. Do not silently switch to it.

## Owner brief

The included Classic property website currently feels better finished than the paid designs. Redesign the paid **Signature Estate** and **Coastal Luxe** property landing pages so they visibly justify a luxury upgrade. Use the owner's reference as a quality benchmark: <https://647-victoria-lane.kelsieblevinsrealestate.com/>. Inspect it yourself and use the owner's custom Claude design skills. This task is for the public property landing pages, not a redesign of the native app or its video editor.

The entire Rendprop product follows a modern Apple aesthetic: system-like typography and hierarchy, generous spacing, rounded capsule controls, tasteful adaptive glass/material, consistent Rendprop accent colors, subtle purposeful motion, and accessible contrast, touch targets, Reduce Motion/Transparency behavior. Avoid desktop-like dropdowns and generic template cards. Preserve the distinct editorial character of each paid design; they should not look like recolored Classic.

The listing video is the main website hero when one is selected. The visitor must be able to play it, browse the gallery, and choose a separate recorded walkthrough if available. Aerial opening, when owner-accepted, is the first clip of a new listing video; do not fabricate or auto-accept an aerial result. The site also needs location, public agent card, and a buyer inquiry path. MLS/unbranded pages must stay separate from branded luxury pages.

## Source and observed state

The short native, Worker, and database source SHAs below are provenance from separate local release lineages. They are not commits reachable from this GitHub branch. Use the branch's files as the current collaboration source; do not try to fetch or cherry-pick those historical SHAs.

The full native source history is also published on [`source/native-ios-20261026-a7f661c`](https://github.com/AaronPilk/RendProp-Ai/tree/source/native-ios-20261026-a7f661c). The iOS files here are a source snapshot. Backend video function entrypoints in this handoff still differ from the deployed service; this branch is not a complete live-backend snapshot. Keep the luxury-site work in the Tour Host presentation layer.

- Native **TestFlight Build 123** is installed on the owner's physical iPhone 15 Pro, iOS 18.7.3. Its tested source commit is `0c03af0`. The Build 122 crash when opening listings was fixed and the formerly failing listings opened on Build 123. Physical acceptance is partial; Build 123 is **not** a launch approval.
- Native commits after Build 123 include paywall copy `e1733c7` and website StoreKit no-charge recovery `a7f661c`. They are included in this handoff's source tree but have **not** been delivered or verified in TestFlight.
- The deployed Tour Host Worker version last verified for the public property site is `f70ff6d5-2a18-435c-95b2-d611121e3930`, from source base `8a45658`. The newer duplicate-address URL code (`261ec56` Worker and `635b8f47` DB/Tours candidate) is in this handoff as **source-only**. It has not been deployed or checked on a production phone. The live 38-photo listing preview is <https://rendprop.com/property/855-central-ave-1120-saint-petersburg-fl-united-states/3482b697c5f34c26a83b5d1b2b6f429a>.
- On Build 123, the active 855 Central Ave #1120 listing showed 38 photos and its selected eight-second, 1920×1080 listing video. Tapping “Watch on property website” opened the public site on the physical phone; the video played to completion. The public Contact section showed the saved agent card and an inquiry form. No synthetic lead was submitted, so fresh lead notification delivery is still unverified.
- The owner requires multiple agents to publish the same address, including relists and agent changes. A listing's full address stays in the URL, with a stable unique suffix on duplicates; old links must keep resolving to their original listing. Never reassign the old sold listing's plain address URL to the newer listing. Do not let site design work undo this route isolation.
- The seven-day intro trial is currently limited to one listing and five photo edits, with no free video or aerial generation. General retail credits, top-ups, pricing, and StoreKit sandbox acceptance remain unresolved. Floor plans and 3D tours are outside the first release.
- App Store submission is explicitly **on hold** until broader QA and the owner's TestFlight review. Do not submit or mark the app release-ready.

Primary web source: `services/edge/tour-host/src/property-design.ts` for the paid designs, `property-site.ts` for Classic, `player.ts` and `property-video.ts` for the shared hero/video composition, plus shared assets/styles. Inspect `services/edge/tour-host` tests and run the relevant web checks. Native design tokens live in `apps/ios/Rendprop/DesignSystem`; use them as product context, not as a reason to rebuild native views.

For the premium browser check, use a full clone, run `npm ci` in `services/edge/tour-host`, install Playwright Chromium if needed with `npx playwright install chromium` (or set `STUDIO_BROWSER_EXECUTABLE`), and have `ffmpeg` and `ffprobe` on `PATH`. Then run `node scripts/check-premium-luxury.mjs --evidence=/tmp/rendprop-luxury-proof`. Its Classic/MLS comparison uses the pushed parent of the initial handoff commit, `6fc7485a1aae7b8354fd7c21ff2a01e71c3e1376`.

## Claude deliverable

Implement polished, responsive luxury landing pages for Signature Estate and Coastal Luxe in a new branch from `codex/claude-landing-handoff-20261026`. Keep Classic available, preserve property video, gallery, walkthrough, contact and MLS behavior, and avoid changing billing or generation. Test the pages at iPhone and desktop widths, keyboard/VoiceOver-equivalent navigation, reduced motion, and image/video loading. Provide before/after screenshots or a preview, the commit/PR link, a short explanation of the design choices, and the checks that passed. Do not deploy to production or submit to the App Store until the owner reviews the design and release QA is complete.

Claude should check the latest branch head and this file before editing; the branch may advance as URL and release QA fixes are integrated.
