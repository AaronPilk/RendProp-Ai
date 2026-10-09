# Home design — 2026-10-09

The owner's instruction is **Home only** for the visual refresh. It supersedes
broader screen suggestions in the supplied PDF. The separately requested Team
permission change is documented in `CODEX-TEAM-PRIVATE-LIBRARIES-20261009.md`.

## Final presentation

- Adaptive white light canvas and dark canvas; new installs default to System and
  follow iPhone settings. Explicit saved Light/Dark preferences remain supported.
- Approved “List it. Launch it. Sell it.” hero and property photograph at the top.
  Get started is Home's creation entry.
- Photo shortcuts use native Liquid Glass on iOS 26, material on earlier systems,
  and a readable opaque fallback with Reduce Transparency. A faint dark-purple
  0.75-point edge and five-point soft glow adapt to light/dark appearance.
- Two columns at normal text sizes; one at accessibility sizes. Icon left, title
  and subtitle stacked beside it, chevron right, photo below. Social media uses
  the Just Listed phone artwork.
- No outer outlined toolbox shell, My Listings section, duplicate Add a home
  action or first-home-five-steps card. The Home toolbar hides its extra shared
  glass capsule to avoid the double-bubble effect.
- The original colored Listing toolbox, other screen styling, shared Theme,
  Typography, Components and native tab bar keep their pre-refresh design.

All visual helpers are private Home types in `RendpropApp.swift`. The Home asset
images are promotional artwork, not fabricated user listings. Unavailable tools
retain Coming soon and do not receive interactive glass.

## Verification

The actual iOS simulator SDK build and four final UI test executions passed:
Home layout/approved copy (two tests), System/dark/override persistence (one),
and maximum accessibility text layout (one). Earlier System tests also passed
against both light and dark simulator settings. Current actual captures show
both appearances, the photo cards and purple glow.

Private logs and result bundles:
`/Users/pilksclaes/LocalRendpropAudits/design-refresh-20261009/appearance-and-individual/`
(`team-and-glow-build-repair1.log`, `team-and-glow-home.xcresult`,
`team-and-glow-dark.xcresult`, `team-and-glow-large.xcresult`, plus earlier
`os-light.xcresult` and `os-dark.xcresult`).

Manual previews must omit the whole `-appearance` launch pair. Even
`-appearance system` overrides Settings writes for that process. The preview
simulator has been installed with the current SDK build, without that pair.

These checks use the closed mock API and generated synthetic fixture photos.
They do not establish real-camera, Apple purchase, paid-generation or production
acceptance. A simulator install does not mean TestFlight upload or App Store
submission. The old build 53 lacks this refresh and the new Team model.
