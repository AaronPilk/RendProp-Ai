# Owner direction: a first-class Home 3D walkthrough feature

September11 request: the owner supplied the current Home feature-grid screenshot
and asked what is required to make spatial work and add it **there as a feature**.
This confirms the desired product entry, not a claim that the feature is built.

## Intended placement and experience

- Home first row: **Make a tour** and **3D walkthrough** as distinct cards.
- Proposed subtitle: **Scan rooms. Walk through them.**
- Keep **Make a floor plan** separate. A floor plan, cinematic video and
  navigable reconstruction are three different outputs.
- Reuse existing branded card typography, rounded shape, gradient, labelled
  icon, accessible button identity and press feedback. Do not add a generative
  AI pill implying the measured capture is invented video.
- Reuse the existing home selection behavior: create a home if none exists,
  use the only home automatically, otherwise ask which one. No mandatory
  identified-account gate and no sample-home destination.

The finished path is:

**Home → 3D walkthrough → choose home → scan rooms → automatic resumable upload
→ cloud reconstruction status → private review → walk in 3D → optional sharing.**

Generation must survive leaving/reopening the app, expose actionable failure and
retry states, and preserve captures. Review includes privacy handling before any
public tour. The owner and customers must not export to Files, operate a GPU,
run scripts or transfer SOG files to use the finished product. A private browser
walk is only the one-room engineering acceptance step, not the product workflow.

## Immediate owner action vs engineering work

The last exact Modal terminal result says the GPU reached its **billing-cycle
spend limit**. Modal documents a usage budget and a separate net-charge spend
limit. Both are on [Settings → Usage & Billing](https://modal.com/settings/usage).
Select the experiment workspace, check the reached spend limit and payment
status, and authorize only the headroom intended for the already-approved test.
No unlimited setting, subscription upgrade or new production budget is assumed.
The experiment still has aUSD25 total ceiling across attempts. Source:
[Modal budgets and spend limits](https://modal.com/docs/guide/budgets), checked
September11. The dashboard's actual configured value was not read in this turn.

Engineering still must repair the runner's incomplete failure diagnostics,
complete/review an actual room reconstruction, convert its output, and obtain
the owner's phone walkthrough acceptance. That acceptance precedes the later
capture guidance, hosted job lifecycle, upload/status integration, privacy
review, app viewer and flythrough binding work under the standing PhaseA gate.
Unblocking billing does not automatically deliver any of those missing pieces.

The newest153-frame capture is validated/prepared privately; the earlier256-frame
dataset remains intact. Confirm which capture the next paid attempt uses when
resuming. Do not silently replace the approval marker or begin another rental.
No new GPU allocation, account-setting change or feature code ran in this turn.

Once integrated source passes full app/non-camera UI checks, an internal
TestFlight build can deliver the native feature for phone testing **after owner
authorization of that Apple action**. The pending App Review submission remains
untouched. Production service deployment/ongoing spend is separate from the
one-roomUSD25 experiment authority.

## Verified source integration map for Claude

Paths and lines below refer to the current capture-intake base `2ef7542`, not a
combined release with the separately pushed recovery/RenderEngine branches:

- `apps/ios/Rendprop/RendpropApp.swift:2535`: explicit Home feature grid; insert
  a separate feature card next to tour.
- `RendpropApp.swift:3230`: add `ProjectFeature.spatial` and cover every metadata
  switch, including title, promise, symbol, gradient and badge policy.
- `RendpropApp.swift:2550`: existing `featureButton` supplies the style and
  accessibility identifier. Reuse it rather than a standalone differently styled
  button or an unlabelled icon.
- `RendpropApp.swift:2295`: existing `open` handles zero/one/many-home selection.
- `RendpropApp.swift:2360`: route to a new listing-scoped `SpatialTourView`; keep
  it outside the already large detail view and use durable listing/scene IDs.
- `apps/ios/Rendprop/Screens/PlayerWebView.swift:23,46`: existing hosted-page
  entry and WKWebView are the in-app viewer integration, not a second renderer.
- `apps/ios/Rendprop/Capture/SpatialCaptureLabView.swift:1,13`: current lab is
  compile-gated and explicitly capture/export-only. Connecting the finished
  **3D walkthrough** card here would not implement what the owner requested.
- `tools/spatial-spike/capture-ios/Sources/SpatialCaptureViewController.swift:72`:
  capture capability is checked separately. Viewing a completed tour must not
  be gated on LiDAR/RoomPlan availability.

This turn verified source wiring and official billing documentation only. No
UI implementation, compile, phone binary, deployment or end-to-end feature test
is claimed. Receipt-level capture and provider results remain in the linked
intake/readiness documents; they are not repeated as new test executions.
