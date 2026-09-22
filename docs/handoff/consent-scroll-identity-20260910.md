# Consent scroll identity repair — 2026-09-10

Base: `6b7fa4ad7db9ac09e08701cddaa4511b6940329b`, resolved once from the integration audit worktree before editing. Branch: `fix/consent-scroll-identity-20260910`.

## Observed failure, not a visual-success claim

The actual reviewer run against `d05bbec` failed with **1 failed, 0 passed, 0 skipped**: “Consent scroll view is missing” at `ReviewerWalk.swift:556`. The relevant app and test source is unchanged between that failed source and this repair's base.

Local evidence: `/tmp/rendprop-noncamera-ui-jxozgi3w/Reviewer.xcresult`; exported hierarchy `reviewer-attachments/8C7332FD-AF08-47FF-8AC2-F8964FF96C45.txt` and screenshot `reviewer-attachments/50E6A584-0F00-4E22-92A4-09A0403D0452.png` in the same evidence directory. These artifacts are not copied into the repository.

The hierarchy's consent ScrollView has identifier **`aiConsent.root`**, not `aiConsent.scroll`. Its descendants include `aiConsent.agree` and `aiConsent.decline`. The underlying Photo Studio has a separate, unidentified ScrollView. The source assigned `aiConsent.scroll` to the consent scroll and `aiConsent.root` to its enclosing ZStack; the latter is the identifier actually exposed on the scroll. This proves the selector mismatch. The pre-fix screenshot shows the disclosure and a partially below-viewport decline button; it does not prove post-fix scrolling or either decision.

## Narrow repair and runtime gate

- Give the actual consent ScrollView one canonical identifier, `aiConsent.root`, and remove the competing ancestor identifier. No contents, consent persistence, processing gate, toolbar policy, or accessibility grouping is changed.
- Query exactly one ScrollView with that identifier and scope both decision buttons to it. Preserve enabled/hittable checks, nonzero dimensions, **full viewport containment**, at most eight swipes, the decline target-height check, and failing assertions. There is no coordinate fallback or generic-scroll fallback.
- Add `ReviewerWalk.testAIConsentDecisions()`, which reuses the full walk's existing r11 helper. Only this focused launch bypasses unrelated onboarding through the existing `-hasOnboarded YES` argument. It requires all three consent-state screenshot attachments, decline returning Home and restoring tabs, consent appearing again on reopen, and agree keeping the actual Photo Studio open with the disclosure removed. It does not start an AI operation, camera capture, or deletion flow.

Parent's next rebuilt simulator gate: **`RendpropUITests/ReviewerWalk/testAIConsentDecisions`**, followed by the existing `RendpropUITests/ReviewerWalk/testReviewerWalk`. These are pending runtime gates, not passes established here.

## Portable checks and limitations

Evidence directory: `/tmp/rendprop-consent-selector.BDOXft`.

```sh
node --test tests/phase1/consent-contract.test.mjs
swiftc -frontend -parse apps/ios/Rendprop/RendpropApp.swift apps/ios/RendpropUITests/ReviewerWalk.swift
git diff --check
```

The new source-contract tests were run before the repair: **1 passed, 3 failed, 0 skipped, exit 1** (`before.log`). After repair: **4 passed, 0 failed, 0 skipped, exit 0** (`after.log`). They guard the single identifier's modifier location, typed/scoped selector, mandatory reachability conditions, and focused reuse; they are deliberately static source checks, not SwiftUI rendering or XCTest execution. Swift frontend parsing returned **0** without diagnostics (`swift-parse.log`); this is not SDK typechecking, linking, or an app build. `git diff --check` returned **0**.

No Xcode build, simulator operation, device operation, account/provider call, AI generation, or live deletion was performed for this unit. Only a subsequent rebuilt UI run can establish actual scrolling, decision behavior, and rendered reachability.
