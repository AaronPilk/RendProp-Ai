# HANDOFF — first-project guide + review prompts

Branch `feat/first-project-guide`, based on `launch` at `bc79e69`. Two new features, both
built as new files under `apps/ios/Rendprop/Guide/` and `apps/ios/Rendprop/Support/`. Every
edit to an existing (shared) file is listed below with its exact line numbers — nothing else
in any shared file was touched.

## New files

- `apps/ios/Rendprop/Guide/FirstProjectGuide.swift` — the five required steps + two next
  wins, per-industry titles/tips, and progress derivation. `FirstProjectGuide.progress(model:)`
  reads real state only (no flag the guide sets from a tap), except `Storage.hasAIPhotoEdit`
  — see note 1 below.
- `apps/ios/Rendprop/Guide/FirstProjectCard.swift` — the Home card.
- `apps/ios/Rendprop/Support/ReviewPrompter.swift` — `ReviewPrompter` (the review-prompt
  timing/log) and `ReviewLinks` (the two Settings review destinations).
- `apps/ios/RendpropUITests/GuideShot.swift` — `testGuideShot()`, launches with
  `-ui.guideState 2` and screenshots Home (`g01-guide-card`).

## Shared-file edits (file:line)

| File | Lines | What |
|---|---|---|
| `apps/ios/Rendprop/RendpropApp.swift` | 1600–1609 | The ONE hook: `if !FirstProjectGuide.isHiddenForever { FirstProjectCard { action in … } }` inserted into `HomeDashboardView.body`, right after `heroCard`, sharing its `Reveal(index: 0)`. The closure's three cases (`.startProject` / `.open` / `.share`) call straight into `HomeDashboardView`'s own existing private `open(_:)` / `go(_:_:)` — no new state added to the view. |
| `apps/ios/Rendprop/Screens/FlythroughDetailView.swift` | 1071 | `ReviewPrompter.shared.tourPublished()` — one line, inside `publishNow()`'s existing `await MainActor.run { … Haptics.success() }` success block. |
| `apps/ios/Rendprop/Screens/FlythroughDetailView.swift` | 2396 | `if !isSample { FirstProjectGuide.recordAIPhotoEditCompleted() }` — one line, inside the AI photo edit's existing `await MainActor.run { … Analytics.track("ai_photo_edit", …) }` success block. See note 1. |
| `apps/ios/Rendprop/Screens/SettingsView.swift` | 298–307 | Two new rows in the existing "Legal & support" `Section`: "Rate Rendprop" (always shown) and "Review us on Google" (shown only when `ReviewLinks.google != nil`). |
| `apps/ios/Rendprop/Config.swift` | 76–87 | `Config.uiTestGuideState`, reading `-ui.guideState <N>` the same way `uiTestSeedPhotoURLs` reads its own arg — added right beside it. |
| `apps/ios/Rendprop/Analytics/Analytics.swift` | 62–63 | Added `"guide_step_tapped"`, `"guide_completed"`, `"review_prompt_shown"` to `Analytics.vocabulary`. **Required**, not optional — `Analytics.track` silently drops (and, in DEBUG, asserts on) any event name not already in that set, so the three new events would have gone nowhere without this. |

That's 6 lines of shared-file surface area for the hooks themselves (RendpropApp.swift's is
one `if` + one view expression spanning 10 lines because of the trailing-closure switch, but
it's one insertion), plus the two SettingsView rows, plus the two small, self-contained
additions to Config.swift and Analytics.swift.

## Notes / judgment calls worth knowing about

1. **"AI photo edit done" has no existing persisted signal to read.** I checked: an
   AI-edited photo and a plain imported photo are saved through the exact same
   `enh-<id>.jpg` / `orig-<id>.jpg` convention (`EnhancedPhoto` in FlythroughDetailView.swift)
   — there's no on-disk marker distinguishing "went through Gemini" from "just auto-enhanced
   on import." So this next win is backed by one new UserDefaults flag
   (`FirstProjectGuide.Storage.hasAIPhotoEdit`), set by the one-line hook at the AI edit's
   real success point (line 2396) — not the file system. Reels have no such gap: they're
   detected by reading `Documents/reels/<listingID>-*.mp4` directly (same convention
   `ReelStudioView` already writes), so "a reel made" needed no new state at all.

2. **The two "next wins" are shown as a bonus row inside the still-visible card**, not
   gated behind finishing all five steps — because the spec has the card disappearing
   forever the moment step 5 is real, which would leave no window to ever show them if
   they were gated on full completion. They're visible (with their own real checkmarks)
   from the start, and disappear along with the rest of the card once the required five are
   done. If you intended them to show only *after* the five, that's a one-line change to
   `FirstProjectCard.cardBody`'s `if` guard around `winsSection`.

3. **1st/3rd publish vs. the 120-day cooldown can collide.** An agent who publishes three
   tours inside one busy week hits the "3rd publish" trigger before the 1st prompt's
   120-day cooldown clears, and that attempt is silently skipped (not queued/retried) —
   documented in `ReviewPrompter`'s header comment. Deliberate (better to under-ask than
   ask twice in a week), but worth knowing if the real prompt rate looks lower than 1st/3rd
   implies.

4. **App Store id** (`6808982413`) matches every other reference to it already in the repo
   (`docs/appstore/**`, `services/edge/tour-host/public/**`) — not newly invented here.

5. **`ReviewLinks.google` is `nil`** as specified; the Settings row simply doesn't render
   until the owner fills it in.

6. **Guide progress is "any real project," not one pinned listing.** Someone with three
   homes who filmed #1, tagged #2, and shared #3 sees steps 1/2/3/5 all checked off — the
   guide teaches the full loop once across the account, not per-listing. This also means a
   later-deleted listing can, in principle, un-check a step; the forever-hide latch
   (`Storage.dismissedForever`) is written the moment all five are true specifically so that
   graduating is permanent even if the qualifying listing is deleted afterwards.

7. **`ProjectFeature` has no dedicated "tag rooms" case.** Steps 2, 3 and 4 (film, tag,
   create) all resolve to `.open(ProjectRoute(listing:, feature: .tour))`, landing on
   `FlythroughDetailView`, which already has a "Tag rooms"/"Tag areas" toolbox button. No
   new `ProjectFeature` case was added.

## Things I could not verify by compiling (no Swift toolchain here)

- Everything was cross-checked against already-compiling patterns in this exact codebase
  (actor isolation via `@MainActor final class` mirroring `AIConsent`; `Task { @MainActor in
  … try? await Task.sleep(…) }` mirroring `Analytics.scheduleFlushLoop`; the window-scene
  lookup mirroring `PurchaseManager.activeWindowScene()`; the memberwise-init-with-trailing-
  closure shape mirroring `HomeDashboardView(goToListings:)` / `ProjectPickerSheet`; SF
  Symbols reused from tiles/rows already on screen elsewhere in the app). I'm confident in
  all of it, but flagging it plainly since none of it ran through a compiler.
- `.onChange(of: Bool) { done in … }` in `FirstProjectCard` uses the pre-iOS 17 single-
  parameter closure form deliberately (matches `RendpropApp.swift`'s and
  `SettingsView.swift`'s own existing `.onChange` calls) — it will emit an iOS-17-deprecation
  warning, not an error, and project.yml's deployment target is iOS 16.0.
