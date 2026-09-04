# HANDOFF-PF — project-first Home (nothing blocking)

Owner of `apps/ios/Rendprop/Screens/FlythroughDetailView.swift`: I did **not** touch your file.
Two optional notes, no action required for the field test.

## 1. Copy alignment (nice-to-have)
Home's feature tiles now use one clear verb each, and the listing toolbox says something
different for the same destination. When you next edit the toolbox, consider matching:

| Home tile (new)        | Toolbox today          | Same destination                          |
|------------------------|------------------------|-------------------------------------------|
| Take photos            | Photos & AI edits      | `PhotoStudioView(listing:)`                |
| Make a reel            | Make a reel            | `PhotoStudioView(listing:, intent: .reel)` |
| Make a floor plan      | Floor plan             | `FloorPlanView(listing:)`                  |
| Make an aerial shot    | Aerial intro           | `AerialIntroSheet(listing:)`               |

## 2. No deeplink was needed
Home's "Which home?" gate pushes `PhotoStudioView(listing:)` / `FloorPlanView(listing:)`
directly inside Home's own `NavigationStack`, and presents `AerialIntroSheet(listing:)`
as a sheet — the same initializers your toolbox uses. So there is no new intent/deeplink
parameter on `FlythroughDetailView`, and nothing for you to add. If you ever add one,
`HomeDashboardView.routeDestination` (RendpropApp.swift) is the single place to switch to it.

## 3. What was deleted
`AIPhotoStudioView` (the standalone, listing-less photo studio) is gone from
`SettingsView.swift`, along with its Settings "AI tools" row and Home tile. Nothing
references it any more. `AIPhotoEditRequest` / `api.aiPhotoEdit` are untouched — your
per-listing studio is now the only caller.
