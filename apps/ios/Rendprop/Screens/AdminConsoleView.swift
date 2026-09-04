// `AdminConsoleView` lives in Screens/SettingsView.swift so it is always in the
// Xcode target without re-running xcodegen (see the repo's new-file-not-in-target
// rule: docs/context/RENDPROP-FABLE5-BRIEF.md §1.2 and docs/handoff/A-detail.md §5,
// "New Swift files are still unsafe in this repo"). This file is intentionally
// left empty — do not add `struct AdminConsoleView` here or it will collide with
// the copy in SettingsView.swift.
//
// WHY, concretely: `apps/ios/Rendprop.xcodeproj/project.pbxproj` is COMMITTED and
// lists its 37 `.swift` sources individually. `project.yml`'s `sources: - path:
// Rendprop` glob WOULD pick up a new file — but only after someone runs
// `xcodegen generate` on the Mac. When that step is skipped the new file is
// silently dropped from the target and the build fails with "Cannot find
// AdminConsoleView in scope", taking the whole app down, not just this screen.
// That has happened twice in this repo. Once the project is regenerated as a
// matter of course, the console can be lifted out of SettingsView.swift into
// this file unchanged.
//
// WHAT LIVES WHERE (all in the same module, so nothing needs importing):
//   • Screens/SettingsView.swift — `AdminConsoleView` (the screen) and
//     `AdminMoney` (currency/percent formatting), plus the Settings entry point
//     and the server-driven admin gate (`resolveAdminAccess`).
//   • Networking/APIClient.swift — the wire models (`AdminSpendReport`,
//     `AdminProvidersReport`, `AdminUsageReport`, `AdminHealthReport` and their
//     nested types), `AdminSpendWindow`, `AdminTimestamp`, `AdminText`, and the
//     four `APIClient` protocol requirements.
//   • Networking/LiveAPIClient.swift — the four GETs under /functions/v1/admin.
//   • Networking/MockAPIClient.swift — offline sample data for every state.
//
// Contract: docs/ADMIN-CONSOLE-CONTRACT.md (version 1, 2026-09-04).
//
// Two invariants the screen exists to hold, repeated here so they survive a
// future move of the code:
//   1. `total_cents` is the ledger's number, NOT the invoice. In-app AI photo
//      and AI video spend never writes a cost_ledger row today, so the total is
//      a floor. The `coverage` object says so and is rendered next to the
//      number on every load; a MISSING coverage object is treated as "unknown",
//      never as completeness.
//   2. A credential value — or prefix, or suffix, or length — is never sent by
//      the server and must never be rendered. Only environment variable NAMES
//      and booleans.
