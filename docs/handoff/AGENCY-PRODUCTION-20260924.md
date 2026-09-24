# Agency production workflow — 24 September 2026

## Branch and coexistence with spatial work

Worktree: `/Users/pilksclaes/Rendprop AI/agency-production-studio-20260924`
Branch: `feat/agency-production-studio-20260924`
Base: `4bde0c686a111a8e9e10b57fcbff4a9579846057` (fresh origin/main when this work began).

The user's current instruction was to build the phone/Studio editing workflow while Claude continues spatial capture. The spatial handoffs were read first. No spatial implementation, capture recorder, GPU configuration, existing migration, App Store Connect setting, signing setup or build version was changed. The shared Claude checkout was not edited or force-pushed.

The Xcode project diff only adds references for new production files/tests. Merge those references with Claude's current project file; do not replace his project file wholesale.

## Implemented

- Shared property capture-plan schema (`production:<listing UUID>`) for iOS and Studio: three formats, target duration, presentation, checklist, source links and editor notes.
- Safe local recovery plus revision-checked phone autosync. A durable pending write distinguishes a lost response from a competing device's edit. Newer typing survives confirmation of the older write.
- Phone multi-video import into a separate persistent original-file library. Uses the existing sequential upload engine, receipts and Wi-Fi setting. Does not replace the property's main walkthrough.
- Guided listing-highlight, agent-tour and market-update drafts; simple view by default, optional professional controls, speed-aware splitting, undo/redo, unique source-byte accounting. Existing AI plans and exports remain on the same draft model.
- Workspace review queue, exact-version original-media/narration preview, timestamped comments and approval invalidation on edit.
- Immutable submitted versions and frozen capture briefs. Explicit copy/restore makes a new private edit, preserves any replaced saved draft and checks the target revision. Local controls are locked while a copy is unresolved.
- Scoped narration reuse for agency copies without generation or provider cost. Real account-deletion tests cover shared audio retention and eventual deduplicated cleanup.
- A small pre-existing Debug crash fix: photo-first property creation emitted an undeclared analytics event. It now uses the existing `home_created` event with `source: photos`.

## Backend and rollout

New migration: `services/supabase/migrations/20260924153826_studio_production_reviews.sql`.

Deploy order: migration → `studio` edge function → Studio → matching iOS release after merging/reviewing Claude's work. These changes have not been applied to production by this implementation task. No new paid editing provider was enabled or purchased.

Endpoints:

- Existing `GET/POST /studio/documents` accepts validated production plans.
- `GET/POST /studio/production-review`, with separate source-document and review revisions.
- `GET /studio/production-review-queue`, pages of 50.
- `POST /studio/production-review/narration`, only the completed voice selected in the current submitted revision.
- `GET /studio/production-review/versions` and `/version` for authorized immutable history.
- `POST /studio/production-review/copy`, atomically preserving the target and making an author-private working copy.

Review/version RPCs are service-only. The HTTP handlers use the authenticated actor, active workspace and listing authorization. Private replacement snapshots stay author-only; submitted history is shared with eligible current members. Marketing remains read-only for these new operations.

## Verification and limits

The local database runner creates its own socket-only Postgres cluster; it never reads a configured production database. The browser fixtures block external requests and use generated media. Swift writer tests compile the actual production writer with test-only identity/network doubles. Completed local checks: 327 Studio tests plus production build/asset checks; 93 Studio backend tests; 69 real Postgres checks; 49 Swift plan/cache/link checks; 11 actual writer checks; 21 existing Phase 1 checks; four browser regression suites; one camera-free UI test. Final unsigned simulator build succeeded.

Local evidence:

- `/tmp/rendprop-agency-studio-final.log`
- `/tmp/rendprop-agency-edge-tests.log`
- `build/pr-lmjun66h/receipt.json` (independent root database rerun)
- `/tmp/rendprop-production-ios-freeze-build.log`
- `/tmp/rendprop-production-ui-reviewed2-20260924.xcresult`
- `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-production-RBsmN2/receipt.json`
- `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-cloud-editor-vdrM6G/receipt.json`

Independent review fixes included preserving capture-plan saves on property switches, restoring required-shot flags after changing formats back, keeping desktop clip removals authoritative on phone reload, and fencing overlapping/deleted-property imports. No physical-device or live production acceptance is claimed.

Core commands:

```sh
cd apps/studio
npm run verify
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node tests/production-browser.mjs
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node tests/editor-recipes-browser.mjs
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node tests/cloud-editor-browser.mjs
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node tests/property-reels-browser.mjs
```

From the repository root:

```sh
python3 services/supabase/tests/production_review.py
bash apps/ios/tests/run-production-writer.sh
node --test tests/phase1/*.test.mjs
```

The editor still has its documented browser limits (12 sequence clips, 128 MiB per file, 512 MiB unique sources, 3-minute timeline). Recipes are deterministic editable starting points. They do not supply music mixing, automatic speech/beat analysis or a verified replica of Four Horsemen Media's style. Palmier/Runway are not integrated by this change.

Do not claim that simulator compilation, camera-free UI tests or synthetic MP4 tests prove real camera capture, real-property coverage or agency-level editorial quality. The user must test the actual phone/media workflow. The workflow and acceptance guide is `docs/studio/agency-production-workflow.md`.
