# iOS non-camera UX and brand audit — 2026-09-10

## Scope and evidence

Reviewed integration base `de4b0b1` on isolated branch
`audit/ios-noncamera-ux-20260910`. Read the standing brief and
`docs/brand/README.md`, current UI-walk code, consent, Studio, theme, navigation,
Coach and session-gate source. This is an evidence-based audit plus one narrow
consent patch, **not a declaration that all UX or accessibility passes**.

Visually inspected all **23 exported non-camera images** from
`/tmp/rendprop-spatial-release18.pVLudX/verification-3`: nine Main and fourteen
Reviewer attachments, mapped through their `manifest.json` files. These are
historical build-18, light-mode, synthetic-data screenshots. The receipt binds
them to `ed0131b03e83f01ba60c55f209bd960bb9278dfc`, Release, simulator
`D4BAC4B1-5F7D-4C4E-88A5-FC10746C152C`; it is not evidence of the new patch.
The previously reported five-test/22-required-screen gate is historical and
includes three spatial non-AR tests. Required screenshots are a subset of
exported attachments, not an image count or quality score.

Before this patch, `git diff ed0131b --` for `RendpropApp.swift`,
`FlythroughDetailView.swift`, `Theme.swift` and `ReviewerWalk.swift` was empty.
The consent overlap therefore predates this audit and is not a new capture
integration regression. No camera suite was rerun.

## Prioritized findings

### P1 — Consent actions obscured by the native tab bar (patch prepared; UI retest pending)

The historical `r11-ai-consent` image
(`reviewer-attachments/09C59DAC-D666-4649-9703-00C92F42DE53.png`) visibly places the
floating tab bar over most of **Agree and continue**. The overlay previously
left that bar active (`apps/ios/Rendprop/RendpropApp.swift:3029`); the disclosure
is a `ScrollView` (`:3066` after this patch). **One screenshot does not establish
that scrolling could never expose the button. No actual pre-fix reachability
failure was measured in this audit.**

The bounded patch hides the tab bar only while consent is asking (`:3043`),
restores automatic navigation after the decision, labels the disclosure and its
actions with stable accessibility IDs, and gives Not now a minimum 44-point
height. It does not change processors, consent persistence, provider calls or
which features require consent.

`apps/ios/RendpropUITests/ReviewerWalk.swift:507` now requires the bar absent,
scrolls the actual disclosure viewport, checks each action's full containment
and hit testing, declines and verifies Home, reopens and requires consent again,
then agrees and verifies idle AI Photo Studio. The test never starts an edit.
`r11` is retained; `r11b-consent-actions` and `r11c-consent-granted` are additional
diagnostic screenshots. Missing controls fail; there is no coordinate tap or
skip fallback. These assertions are **authored, not yet executed**.

### P1 — Offline Coach incorrectly says publishing requires sign-in (open)

`apps/ios/Rendprop/Coach/CoachModel.swift:349` answers an account/guest question
with “Signing in is needed only to publish a tour to the web.” That contradicts
the standing invariant and actual anonymous-session publication entry at
`apps/ios/Rendprop/Screens/FlythroughDetailView.swift:1567` and `:32`.

Concrete source path: deny cloud consent or make Coach fall back offline, then
ask whether an account is needed. The topic matcher at `CoachModel.swift:361`
returns that stale statement. No live call was made here. Correct the local
answer and test the actual offline response in its own unit; do not add a
sign-in gate to make the copy true.

### P1 — Leads' missing-session state directs users to Apple sign-in (open)

`apps/ios/Rendprop/Screens/SettingsView.swift:1028` defines `needsSignIn` as a
missing session, not a missing Apple identity. At `:1096` that branch says
“Sign in to see your leads” and offers only Sign in with Apple. Thus an
anonymous-session bootstrap/refresh problem becomes an apparent identity
requirement. Source repro: `Config.enableAuth == true`, `auth.isSignedIn == false`,
non-sample Leads. Healthy anonymous sessions do not take this branch.

Add a scoped anonymous reconnect/retry state, retaining genuine cross-device
identity actions separately. The historical walk cannot prove this branch:
`apps/ios/Rendprop/Auth/AuthStore.swift:189` and `:193` force both session and
identified flags true for ordinary UI mocks. No production/auth data was touched.

### P2 — Normal secondary text is too faint; dark filled buttons need their own token (open)

Exact source-token alpha composition gives these ratios, not screenshot estimates:

| Foreground and surface | Contrast |
| --- | ---: |
| Light `Theme.inkDim` over `Theme.bg` | 3.814:1 |
| Light `Theme.inkDim` over white card | 3.860:1 |
| Dark `Theme.inkDim` over dark bg/card | 6.552:1 / 6.279:1 |
| White over dark-mode accent `#9B6DFF` | 3.485:1 |
| White over light-mode accent `#7C3AED` | 5.699:1 |

Sources: `apps/ios/Rendprop/DesignSystem/Theme.swift:27`, `:41`, `:45`;
`DesignSystem/Components.swift:22`–`:26`. The light secondary token is used for
normal-size disclosure, explanatory and billing text, below a 4.5:1 target.
The dark accent works as text against a dark surface but is not interchangeable
with a white-text filled-button background. Keep the brand hue; adjust the
secondary text token and introduce a suitable filled-action role in a separate
change, then visually check both appearances. Ratios alone do not establish
VoiceOver, Dynamic Type or complete accessibility compliance.

### P2 — “Ask AI” truncates to “A…” on a long listing title (open)

Visible in both historical `r04-sample-detail` and `r05-sample-player`. The
worded help action loses its word exactly where it should remain discoverable.
`apps/ios/Rendprop/Coach/AskAIButton.swift:160` supplies the capsule in the
trailing toolbar; the long listing title competes for width. Its accessibility
label at `:177` remains descriptive, but that does not fix visible truncation.
Reserve label width or shorten the visible title presentation; test the real
long-title screen at standard and accessibility text sizes before claiming closure.

### P2 — Reel photo-order promise and planning fallback disagree with execution (open)

The visible photo instruction says “Tap them in the order you want them. 2 to 8”
(`apps/ios/Rendprop/Screens/FlythroughDetailView.swift:7329`), while `:8896`
reorders selected photos according to an optional plan. `planShots` catches
every error and returns an empty list (`:9297`–`:9317`); generation continues
without a visible fallback notice, and only analytics records planning failure
(`:8883`). This is not proof that a specific customer job failed. It is a
demonstrated state/copy mismatch in the code path.

Decide whether user order is binding or suggested, say that before generation,
and disclose a degraded unplanned result. Keep valid clips recoverable and do
not change the immutable agent-reel EDL contract. No Studio source was edited
in this audit; its large file requires a separately coordinated unit.

### P2 — Staging copy promises preserved structure without a demonstrated result check (open)

The AI Photo Studio screenshot says walls and windows “stay as they are,”
matching `apps/ios/Rendprop/Screens/FlythroughDetailView.swift:3322`. A request or
prompt constraint is not proof of actual image preservation. The screenshot
contains no generated result. Qualify this as the requested edit and require
the agent to review structural accuracy before use. No generation or quality
evaluation was performed. The processor disclosure also needs a separately
owned current routing/processor review; its list was deliberately not changed
as part of this layout patch.

## Brand, labels and observed states

- `Theme.accent` light is the documented violet `#7C3AED`; dark `#9B6DFF` is an
  existing adaptive variant. White/indigo app surfaces differ from social-avatar
  paper/ink, which by itself is not a defect. No logo or palette redesign is justified.
- All five onboarding screens have visible worded forward actions; page three
  explicitly limits scanning to LiDAR iPhones. The default-size screenshots do
  not show a blocked forward action. They do not test maximum text size.
- Home and Homes are both worded but differ by one letter and use similar house
  glyphs (`RendpropApp.swift:1999`). Treat dashboard-versus-library naming as a
  discoverability question; no spontaneous rename was made across six industries.
- New Home explains why video choices are disabled until an address is entered.
  Photo Studio shows two synthetic photos ready; Reel Studio shows the selected
  fixtures and My voice setup, **not a successful recording or generated reel**.
- Samples are explicitly labeled in list, detail and player. Profile has a
  labeled Set up card action. Settings exposes appearance and legal/support
  routes. Paywall shows pricing, renewal explanation, Restore purchases and
  Close; no purchase, entitlement or current-price verification is claimed.
- Owner console explicitly says its spend total is incomplete and shows failed
  synthetic health results. These numbers are mock fixtures, not live vendor
  health. Its displayed Cheapest/Best routing explanation is not proof that the
  server applies that policy; the standing brief already identifies that gap.
- `r08`/`r09` show destructive controls and their warning. The existing test only
  cancels the confirmation; never use delete-account, local clear, uninstall or
  account reset for a UX test.

## Verification and next gate

Completed locally, without builds, simulator launches, installations or network:

1. Parsed both historical attachment manifests and bound them to the receipt;
   visually inspected all 23 non-camera images.
2. Before editing, a source assertion requiring the consent toolbar policy
   exited **1**. After editing, policy presence and four unique IDs passed.
   This proves a source change landed, **not an interaction before/after test**.
3. `swiftc -frontend -parse apps/ios/Rendprop/RendpropApp.swift apps/ios/RendpropUITests/ReviewerWalk.swift`
   exited **0**, empty diagnostics. This is syntax parsing, not SDK typechecking,
   linking, app execution or a passing XCTest.
4. `git diff --check` exited **0**. Only the app's consent section, ReviewerWalk
   and this audit document changed.

The integrator's next single non-camera gate should build the final combined
source and run `ReviewerWalk/testReviewerWalk` plus `RendpropUITests/testWalk`
with existing synthetic fixtures. Require both exact tests passed, no failures
or skips, existing required screenshots plus `r11b`/`r11c`, then inspect consent
actions, decline return, reopened prompt and accepted idle studio. There is no
reason to run the spatial simulator suite to validate this patch.

Do not substitute the legacy bridge scripts for that gate:
`apps/ios/RendpropUITests/bridge-cmd-reviewerwalk.sh:70` uninstalls the app;
the onboarding and industry bridge scripts also have uninstall paths. The old
UI-test README's “steps skip rather than fail” description is stale: current
`note` helpers call `XCTFail`, and the walks assert required screenshots. Use
the inspected current test source and an owned synthetic simulator without
uninstall, erase or data clearing.

Remaining visual/interaction gaps: fixed consent not yet run; old CTA reachability
after scrolling not measured; dark mode and maximum Dynamic Type; compact-screen
and landscape layouts; VoiceOver focus/order and hidden-underlay behavior;
reduced-motion and contrast settings; absent/expired anonymous session; real
network failure and paid-work recovery. Do not claim “fully accessible” or
“everything tested” until those particular conditions are exercised safely.
