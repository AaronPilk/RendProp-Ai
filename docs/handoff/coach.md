# HANDOFF-COACH — in-app Coach (new files + minimal shared-file edits)

Full contract: `docs/COACH-CONTRACT.md`. This note lists every EXISTING file
touched, at file:line, so a reviewer never has to diff a whole file to find
what changed. Nothing pre-existing was removed or restructured — every edit
below is a small, additive insertion.

## New files (nothing here is "shared" — safe to ignore in a merge)

```
services/supabase/functions/coach/index.ts
services/supabase/functions/coach/prompt.ts
services/supabase/functions/coach/knowledge.ts
services/supabase/functions/coach/actions.ts
services/supabase/functions/coach/actions_test.ts
services/supabase/functions/coach/README.md
services/supabase/migrations/0023_coach_routes.sql
apps/ios/Rendprop/Coach/CoachAPI.swift
apps/ios/Rendprop/Coach/CoachModel.swift
apps/ios/Rendprop/Coach/CoachView.swift
apps/ios/RendpropUITests/CoachShot.swift
docs/COACH-CONTRACT.md
docs/handoff/coach.md   (this file)
```

## Shared-file edits, at file:line

### `apps/ios/Rendprop/RendpropApp.swift`

1. **`AppModel` — one new published property**, `RendpropApp.swift:66`
   (just before `let api: APIClient = Config.makeAPIClient()`):
   ```swift
   @Published var coachRoute: CoachRoute?
   ```
   Deliberately outside the `didSet { persist() }` group above it — this is
   a one-shot navigation signal, never state to restore on relaunch.

2. **`RootTabView.body` — one new `.onChange`**, `RendpropApp.swift:1531-1542`
   (appended after the existing `.onChange(of: spaceTypeRaw)`, still inside
   `body`). Handles the tab-switch half of every Coach action, and is the
   ONE place that clears `coachRoute` back to `nil` — deferred one runloop
   turn (`DispatchQueue.main.async`) so `HomeDashboardView`'s own handler
   (below) has already seen the same value first; see the comment at that
   line for why a synchronous clear would be a race.

3. **`HomeDashboardView` — one new `@State`**, `RendpropApp.swift:1578`
   (next to `showRoute`): `@State private var showCoach = false`.

4. **`HomeDashboardView.body` — toolbar**, `RendpropApp.swift:1656`: the
   existing single-item `.toolbar { }` gained a second `ToolbarItem`
   (`.navigationBarTrailing`) for `askCoachButton`.

5. **`HomeDashboardView.body` — one new `.sheet` + one new `.onChange`**,
   `RendpropApp.swift:1665-1682` (appended right after the existing
   `.sheet(item: $gate, …)`, still inside `body`):
   ```swift
   .sheet(isPresented: $showCoach) {
       CoachView(model: model, originScreen: "home")
   }
   .onChange(of: model.coachRoute) { route in
       switch route {
       case .project(let listingID, let feature):
           guard let listing = model.listings.first(where: { $0.id == listingID }) else { return }
           go(listing, feature)          // existing private func — unchanged
       case .startProject:
           gate = .start(.tour)          // existing @State — unchanged
       case nil, .planUsage, .support, .home:
           break                          // RootTabView owns these (#2 above)
       }
   }
   ```
   This handler only ever READS `coachRoute` and calls the ALREADY-EXISTING
   `go(_:_:)` / sets the ALREADY-EXISTING `gate` — no gate/route/sheet logic
   was changed, only invoked.

6. **`HomeDashboardView` — one new computed property**,
   `RendpropApp.swift:1717-1730` (`askCoachButton`, placed right after the
   existing `businessTypeMenu`): the round sparkles button, identifier
   `home.askCoach`.

### `apps/ios/Rendprop/Screens/SettingsView.swift`

1. **One new `@State`**, `SettingsView.swift:59` (next to
   `showDataCleared`): `@State private var showCoach = false`.

2. **One new row**, `SettingsView.swift:305-310`, inside the EXISTING
   "Legal & support" `Section`, directly above the existing "Contact
   support" `Link`:
   ```swift
   Button {
       showCoach = true
   } label: {
       Label("Coach & help", systemImage: "sparkles")
   }
   .accessibilityIdentifier("settings.coachAndHelp")
   ```

3. **One new `.sheet`**, `SettingsView.swift:338-340` (appended to the
   Form's existing modifier chain, right after `.refreshable { … }`):
   ```swift
   .sheet(isPresented: $showCoach) {
       CoachView(model: model, originScreen: "settings")
   }
   ```

### `apps/ios/Rendprop/Networking/APIClient.swift`

**One new protocol method**, `APIClient.swift:702-710` (appended right after
the existing `aiChapters(...)` declaration, before `// MARK: Admin console`):
```swift
func coach(_ request: CoachRequest) async throws -> CoachResponse
```

### `apps/ios/Rendprop/Networking/LiveAPIClient.swift`

**One new method**, `LiveAPIClient.swift:863-893` (appended right after the
existing `aiChapters(...)` implementation, before `// MARK: - Account /
usage / leads`) — hand-builds the `[String: Any]` body the same way every
other call in this file does (no `Encodable`/`JSONEncoder` involved), then
`execute(makeRequest(...))` + `decode(...)`, identical shape to every other
short-lived POST in this file (e.g. `updateBrand`).

### `apps/ios/Rendprop/Networking/MockAPIClient.swift`

**One new method**, `MockAPIClient.swift:1113-1134` (appended right after the
existing `aiChapters(...)` mock, before the fair-housing offline-echo
comment) — a deterministic reply with exactly one action chip, so
`CoachShot.swift` has something stable to find.

## What was deliberately NOT touched

- `ProjectFeature`, `ProjectRoute`, `ProjectGateSheet`, `go(_:_:)`, `open(_:)`,
  `gateSheet(_:)`, `routeDestination`, `tourDestination(_:)` — all reused
  exactly as they already stood. Coach never gained its own navigation; it
  only feeds the SAME gate every Home tile already uses.
- `Listing.swift` — no new stored property. `photos`/`edits` in
  `CoachModel.contextListings(from:)` are computed by calling the ALREADY
  existing `EnhancedPhoto.loadAll(listingID:)` (FlythroughDetailView.swift);
  `reels` re-implements that file's own (private) `reelFiles(for:)` glob
  locally in `CoachModel.swift` rather than exposing it.
- `Analytics.swift` — no new API; `coach_opened` / `coach_message_sent` /
  `coach_action_tapped` are plain `Analytics.track(_:_:)` calls made from
  inside the new `Coach/CoachModel.swift` only.
- `apps/ios/project.yml` — not edited. Both `Rendprop` and `RendpropUITests`
  targets already declare folder-based `sources: [{ path: … }]`, so the new
  `Coach/` directory and `CoachShot.swift` are picked up automatically the
  next time `xcodegen generate` runs (the existing `bridge-cmd-*.sh` scripts
  already call it before building).
