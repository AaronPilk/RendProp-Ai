# Desktop Studio glass release — 4 November 2026

Deployed only the real-estate Studio design to https://studio.rendprop.com on 4 November 2026. Product commit `608589321803f50423abd8b4f48eaf9207931f25`, isolated branch `codex/studio-glass-release-20261104`.

The release starts from `aadf8b35` (Studio runtime identical to `31141686`, with the verified robots-prefix readback pin). Rebuilding that baseline with the existing live public configuration reproduced all 35 files in the previous verified live inventory exactly.

## Scope

The five-file product/policy change adds scoped glass styling, the decorative backdrop, appearance pills, expandable desktop navigation, and Home first in the primary navigation. Startup remains below 160 KB; Create remains below 260 KB. The previously approved measured total budget is 410 KB; this build measures 402,672 bytes gzip. Planner retains its existing eager loading.

Auth/data clients, workspace switching handlers, saving and photo recovery logic are unchanged. No native iOS/App Store release, restaurant feature deployment, backend deployment, database migration, payment change, DNS change, or auth configuration change was made. The uploaded version’s runtime configuration, headers, callback routing and empty binding list match the previous live version exactly.

## Verification

- 817 Studio unit tests pass; focused deployment-tooling tests 21/21 also pass.
- Typecheck, connected production build, size gate, strict Wrangler dry run and independent source review pass.
- 64 grouped browser checks: 13 Chromium visual/navigation, 12 WebKit visual/navigation, 39 account/save/listing/photo-recovery behavior checks.
- 112 full desktop layout samples across Chromium/WebKit, plus 8 focused repeats. Includes light/dark, keyboard, resized desktop windows and 200% text.
- WebKit’s first account-dialog test expected Tab to remain in page content. A direct baseline comparison showed the same browser-chrome focus step in the old version. The corrected test only permits inside-dialog focus or BODY with document.hasFocus=false, while retaining background-inert and focus-return assertions. No product workaround was added.
- Served-byte readback passed for 35 application files and 4 routing probes (39 GETs); the new backdrop was separately byte-verified (1 additional GET). Existing noindex and security policies remain; Cloudflare’s existing managed robots prefix does not prove crawl blocking.
- Live signed-in Home, Listings (including saved photo media), Business/lead inbox, dark/system appearance, and expanded/collapsed navigation were verified in the existing browser session with no reported browser warnings/errors. The saved System appearance was restored. Checks are recorded separately in the sibling evidence directory. Write flows were tested with synthetic local services; no customer records were edited for verification.

## Deployed version and rollback

Worker `rendprop-studio`, version 69: `e5c025a2-1b51-45d5-bfa9-34400c98b6d5`, 100% traffic. Previous version 68 remains available: `d23ca858-e371-4ff6-aaf2-77dd701f1ea1`.

From this checkout’s `apps/studio` directory, rollback if a regression requires it:

```sh
node node_modules/wrangler/bin/wrangler.js rollback d23ca858-e371-4ff6-aaf2-77dd701f1ea1 --name rendprop-studio --message 'Restore pre-glass Studio release' --yes
```

Evidence is retained at `/Users/pilksclaes/Rendprop AI/studio-glass-release-20261104/evidence/`. This source is isolated from the unreleased restaurant integration branch and the native release chat. Carry the focused product commit into the normal release branch before the next Studio deployment so this design is preserved.
