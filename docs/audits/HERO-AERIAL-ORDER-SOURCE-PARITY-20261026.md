# Listing-video hero and aerial-first source audit — October 26, 2026

This is a **read-only production check and source-only audit** from `8ad81714` on
`codex/hero-aerial-order-qa-20261026`. No media was generated, aerial result
accepted, form submitted, backend deployed, or App Store release started.

## What is live and working

The public 855 Central Ave active-listing URL returned HTTP 200 in a read-only
GET:

`https://rendprop.com/property/855-central-ave-1120-saint-petersburg-fl-united-states/3482b697c5f34c26a83b5d1b2b6f429a`

Its inline public configuration selected an eight-second, 1920×1080 unbranded
listing video. The home hero contains `#property-video` with that selected
master's poster, `preload="none"`, and an explicit play button. A separate
`Optional recorded walkthrough` action is present. This is evidence of the
current public page markup and server projection; it is **not** fresh proof
of playback on a physical device. The prior Build 123 physical-phone playback
receipt remains documented in `docs/handoff/CLAUDE-LUXURY-LANDING-PAGES-20261026.md`.

The source ordering path is also coherent up to the renderer. The selected
`property_video_compositions` row is projected by
`property_public_presentation` in the migration
`20261014162938_property_video_websites.sql`; the Tours API converts it to
`listing_video` through `_shared/property-public-presentation.ts`; the Tour
Host's `player.ts` chooses that typed master as its hero, with the recorded
walkthrough retained as a separate optional action. The selected video is a
finished landscape master; a loose aerial clip cannot directly become a hero.

## Source promotion blocker: checked-in CPU renderer is obsolete

The Supabase video worker's `engine.ts` sends an accepted `opening` with the
photo-motion compose task. Its typed `AerialOpeningReceipt` requires
`position: 0`; the database profile specifies `accepted-full-clip-first` and
the final receipt compares the saved opening and frame totals. The checked-in
`services/edge/property-video-render` code cannot execute that contract:

1. `src/controller.ts` builds compose GET capabilities only from `sources`,
   narration and music. It omits `opening.media`, so the container has no
   permission to fetch the accepted opening.
2. `container/renderer.py` rejects `opening`, `source_mode` and
   `producer_identity` as unknown compose keys (`closed_cpu_task`). It loops
   only the photo sources and emits no opening or Photo Motion identity in the
   finish receipt.
3. `container/compose.py` accepts only `steady-v2-cfr24` or no profile;
   `photo-motion-v2-opening-cfr24` raises
   `unsupported_composition_profile`. Its clip model is fixed at five seconds,
   while the current photo timeline includes 2/3/3-second clips.
4. `container/photo_motion.py` still caps a push-in at **2%** and makes
   five-second clips. This is the old behavior the owner rejected, rather
   than the current 12%/variable-duration Photo Motion implementation.

Local reproducible read-only probes returned:

```
opening_profile: unsupported_composition_profile
large-photo push-in: 1+0.020000000*min(1,on/119)
compose_with_opening: closed_cpu_task
compose_get_capabilities: [ 'https://media.example.test/private/clip?signature=a' ]
```

The production database gives the authoritative configured renderer identity
for both `photo_motion_renderer_v2` and
`photo_motion_renderer_v2_opening` (`enabled=true`):

```
image_uri: registry.cloudflare.com/9c332c75b96cc642621dad5d86d4bf18/rendprop-property-video-photo-motion@sha256:29f970ce4beca15f485ec421979c5c17eac8d0e6e243db2da6f94f1adb368186
controller_sha256: cf7a8a05bbebe9d60d6b366ed1fbe926380cefcdf258771ae59081a29e587d64
renderer_source_sha256: 9c4e21b2daa4b70a4725138a8ca21465e3eab433f094bd4f557e4f68b5ee83b9
```

This came from a read-only `public.app_config` SQL projection. It identifies
the configured production producer, but the SQL row alone does not prove the
contents of a running container. The checked-in `container/renderer.py` hashes
to `a82b133e13a83e835db7f432f147043680844266538a2e80d8d9144ccdc880bc`,
which does **not** match the authorized renderer-source hash. The exact OCI
image is the authoritative artifact to recover and compare. An unauthenticated
HEAD to its Cloudflare Registry manifest returned HTTP 401; the local Docker
daemon is unavailable, so no image layers or source were retrieved here.
The registry digest and the Cloudflare build/deployment history for
`rendprop-property-video-render` are the recovery starting points. Recover
the full image/source, verify all approved hashes and behavior, then test
the real first-shot composition before any renderer promotion. A narrow
`opening` patch to this old source would still leave the 2%/fixed-five-second
pipeline and invalid receipt, so this branch intentionally makes no partial
renderer edit.

## Verification and limits

- Tour Host `check-property-video.mjs`: 366 assertions plus five negative
  controls passed, using local synthetic media and closed routes.
- Tour Host `npm run typecheck`: passed.
- `check-property-video-browser.mjs` could not launch because this isolated
  worktree lacks the Playwright Chromium binary; this is test-environment
  absence, not a product assertion result.
- No accepted aerial-opening video was generated or reviewed in this audit.
  The existing owner-visible candidate remains unaccepted. The current live
  first-shot composition therefore still needs a bounded, real end-to-end
  validation after authoritative renderer source recovery.

**Release implication:** keep the live working listing hero separate from the
source-promotion claim. Do not build/deploy the checked-in
`property-video-render` until its source matches the production image and
the aerial-first, exact-timeline tests pass.
