# Core readiness and subscription activation — 1 October 2026

## Release status

Release prepared on isolated branch `audit/core-readiness-20261001`, based on
`f3c1f7ba4c1d1c40a1fa379c7ff9a16c5570795c` (delivered TestFlight 33).
This report is a source/test record until deployment receipts are added below.
Claude's checkout and shared branches have not been overwritten or force-pushed.

The owner asked for a full core debugging pass before introducing independent
agents and teams, and for subscription confirmation before starting a seven-day
trial. Spatial capture remains a separate phone experiment. No camera result,
GPU experiment, or paid media generation is part of this audit.

## Changes

- New accounts start free. A seven-day subscription trial requires confirmation
  with Apple and a verified transaction accepted by Rendprop. Existing signup
  trial grants, paid plans, manual grants and contracted access are preserved.
- Onboarding offers **See plans** and **Explore app first**. Opening or exploring
  the app does not begin a trial. Trial wording requires the actual StoreKit
  offer to be a seven-day free introductory period and the customer to be eligible.
- **Settings → Plan & usage** always offers viewing/changing plans, managing or
  canceling with Apple, and restoring purchases. Paying customers keep these
  routes. The Home plan banner also opens plans. Prices come from StoreKit.
- Purchase preflight checks billing permission and the intended workspace before
  opening Apple's purchase sheet. A verified transaction remains unfinished
  until the server accepts it. Restore must not announce success for a rejected
  receipt. An existing subscription cannot silently be upgraded for another workspace.
- Guest-to-Apple account adoption now preserves local production clips and plans
  through the verified transfer receipt. Purchase restoration accepts the
  original guest token only with that exact, still-valid adoption receipt.
- Delayed authentication refreshes and retries cannot substitute a new account
  for an old request. Explicit workspace selection pins new drafts and requests
  to their chosen workspace; switching does not reassign properties or uploads.
- Native workspace selection separates personal and team work, plan context and
  branding. Complete authorized cloud snapshots remain available to sync; UI
  filtering must never turn another legitimate workspace's rows into deletions.
- Team invite enqueue used a nonexistent profile column and falsely reported
  email success. It now reads `profiles.name` and distinguishes a queued email
  from a valid invite code whose email was not queued. Queue acceptance is not
  proof of inbox delivery.
- Studio retains the current editor when creating/copying a project is explicitly
  rejected. Lost-response reconciliation remains supported. An untouched empty
  editor no longer creates phantom recovery prompts or cloud drafts on navigation.

## Evidence

- Apple read-only inventory at **15:03:38 UTC**: Starter monthly/yearly, Pro
  monthly/yearly and Team monthly are approved in USA. Each has an active
  `FREE_TRIAL`, `ONE_WEEK`, one-period offer starting 5 September, without an
  end date. Team yearly remains unavailable and excluded from sale. No Apple
  pricing, territory, offer or review state was changed by this check.
- Studio: **416 unit tests and 25 browser suites** passed. Actual synthetic MP4
  encoding/decoding, narration/music/captions, interrupted export recovery,
  project restoration and permissions were checked. Tour-host gates passed.
- Production Studio baseline: all **30 deployed files** matched the prior
  connected release. The existing synthetic QA project restored from the owner
  session and exported a nine-second H.264/AAC MP4. This proves session reuse and
  project/export behavior, not a fresh Apple sign-in or a camera workflow.
- Isolated backend tests: **34 team SQL assertions**, **26 subscription SQL
  assertions**, **28 workspace SQL assertions**, handler tests, real overlapping
  invitation/selection races and deliberately defective negative controls passed.
  A contracted 100-seat brokerage and standard two-seat Team workspace were
  tested separately. Existing grant snapshots remained byte-identical.
- Full database inventory: **265/266 pass**, with only the previously retained
  Astra agent-reel token-headroom assertion (#155) red. The known exception was
  not weakened or hidden and provider budgets were not enlarged.
- Full backend offline run: **1,127 passed, zero failed, one previously ignored**
  PostgreSQL-only Presenter test. All **25 function entrypoints** typecheck. The
  stock aggregate runner remains false because it requires zero ignored tests;
  this exception is not reported as an entirely green suite.
- Native production-code checks: **85** AppModel/persistence, **13** shared request
  identity, **8** TeamAPI identity, **16** workspace store/context, **312**
  subscription policy/binding, and **15** branding/portfolio checks passed, with
  defective negative controls detected. Normal Release device build passed.
- **Two non-purchase iOS UI tests passed** for Home → plans and Settings → plans,
  restore and Apple subscription management. Screenshots were inspected. The
  purchase bar names the selected plan so a card above the scroll fold cannot
  be mistaken for the plan being purchased.
- Local StoreKit UI transaction runs failed on the installed iOS 26.4.1 simulator
  with `SKInternalErrorDomain Code=3` while saving the test configuration. A signed
  retry failed too. These are **not passing purchase tests**. The fixture now
  refuses to continue if the local configuration was not accepted. Apple's
  [iOS 26.5 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26_5-release-notes)
  list a fix for SKTestSession failing to use its selected configuration. This
  source corroborates the environment issue; it does not prove this app's
  transaction path succeeds on a real phone.

Private logs, simulator results, source-bound receipts and synthetic media:
`/Users/pilksclaes/LocalRendpropAudits/core-readiness-20261001`.
Do not commit owner account data, credentials, Apple signing material, room media,
or the complete private evidence directory to the public repository.

## Deployment sequence

1. Apply migrations `20261001142823_team_invite_delivery_confirmation`,
   `20261001143615_subscription_confirmed_trial_start`, and
   `20261001145730_workspace_selection`.
2. Deploy `team`, `me`, `coach`, and `listings` with existing JWT verification.
   Include new `me/billing.ts` and `_shared/workspaces.ts` dependencies.
3. Publish the connected Studio and existing tour-host Worker; preserve their
   current domains, bindings, secrets, and security headers. Read back deployed
   source/assets and the migrated schema.
4. Deliver a new internal TestFlight build. Build 33 does not include this audit.
   Keep the existing guided capture lab available for the owner's separate test.
   No App Store review submission is part of this release.

Older app builds retain their old no-header active-workspace behavior. The new
workspace intent guarantees require the new native build. Do not advertise them
as a server-only upgrade for clients that cannot send their original intent.

## Owner acceptance before a broad rollout

Use two real test accounts (an independent agent and a team manager/member) on
the new build. Confirm trial purchase, price/renewal disclosure, cancellation,
restore after relaunch and Apple sign-in, and plan changes in TestFlight's sandbox.
Confirm personal/team switching preserves the expected property owner, agent
card and plan on both phone and Studio. Check one invitation's actual inbox
delivery. Physical capture and camera interruption tests stay on the owner's phone.

Studio editing currently supports 12 clips, 128 MiB per source, 512 MiB combined
and three-minute edits. Supported large files can be converted to editing copies.
Export runs in the browser and needs the tab open. Saving an edit is distinct
from publishing a property tour. These limits are not an unrestricted agency
production acceptance certificate.

Higgsfield generation remains disabled. Spatial runtime and its $25 experiment
ceiling are unchanged. The previously recorded spend remains $22.11834445.
