# Non-camera iOS visual review and focused repair

2026-09-10. Root reviewed all 28 PNG attachments exported from the fresh
Release run on source `7d0b0ca3ab7fb579348480e40c43f89d5c222e31`:
3 consent,16 reviewer,9 main. There are24 required attachments across3 exact
tests (21 distinct required names); the extra onboarding images are retained.
These numbers are deliberately different: exported screenshots are not tests.
All3 tests passed,0 skipped. Source/app/test hashes and exact commands:
`/tmp/rendprop-noncamera-ui-3hx5az4i/receipt.json`.

## Actual observations

- Purple accent, light backgrounds, rounded cards and primary actions remain
  consistent across onboarding, home, collection, studios, profile and settings.
- The repaired consent scroll selector reaches both decisions. Decline returns
  without granting; reopening and agreeing reaches the actual Photo Studio.
  Actions are fully contained/hittable after scrolling; the tab bar is hidden
  during disclosure. A mid-scroll screenshot alone is not an unreachable-action
  finding. The original processor copy is inaccurate; see
  `AI-CONSENT-DISCLOSURE.md` for the separate v2 correction and source evidence.
- **P2 reproduced:** the trailing Ask AI control truncates to `A…` beside the
  sample property's long navigation title. Actual before images are
  `reviewer-attachments/32F4F08D-AF83-43AB-A124-C56D553FD619.png` and
  `reviewer-attachments/DB8D867C-C0AD-4CE5-9805-D6717914C531.png` in that evidence
  directory. `apps/ios/Rendprop/Coach/AskAIButton.swift:163` did not preserve
  its label's intrinsic width. Its full accessibility label hid the visual
  problem from string-only tests.
- The sample player renders and seeks its bundled video. This is not a 3D
  reconstruction, an upload, or physical-camera proof.
- All five onboarding screens, both account-deletion confirmation states
  (cancel only), legal entry, settings and native purchase choices were seen.
  The owner console's trial counters/AI-ledger warning are mock data, not
  evidence of a production billing defect. Native IAP prices are not the old
  external-checkout pricing issue. No purchase or deletion was performed.

## Implemented narrow repair and verification boundary

AskAIButton reserves intrinsic horizontal label size and a minimum76-by44pt
hit region, preserving the existing purple capsule. WHY: navigation titles may
yield width, but the control that explains a confusing screen must stay named.
ReviewerWalk/testAskAILabelOnLongTitle opens the existing long-title sample,
asserts one enabled/hittable button with in-window geometry, captures it, and
opens the actual Coach screen without sending a message. Geometry and AX text
do not alone prove drawn text fits: inspect the rebuilt screenshot as well.

The new source guard failed against the old control, then passed after repair.
Combined consent/label portable checks:10 passed,0failed/0skipped, exit0.
These include24 actual Foundation preference assertions across3 processes,
not device-storage tests. Root reran them with:

```sh
node --test tests/phase1/ask-ai-label.test.mjs tests/phase1/consent-disclosure.test.mjs tests/phase1/consent-contract.test.mjs
```

`tools/audit/run_noncamera_ui.py --focus-only` now rebuilds from clean source
and requires the two exact consent/AskAI tests,0skips and5 required screen
attachments. Default still performs the full walks too; receipt counts are
derived from the selected tests. This scoped rerun does not claim the old
walkthroughs executed against the new disclosure.

**Fresh focused run passed on `50c95d3`:2 exact tests,0skips,5 required screen
attachments.** Release build, bundle/resource gate and unchanged source/artifact
checks also passed. Receipt:
`/tmp/rendprop-noncamera-ui-3_d1cfjd/receipt.json`.
Root inspected all5 required images: Ask AI is fully drawn next to the long
title, its tap opens Coach, all4 corrected processor cards are readable, and
both consent decisions remain reachable after scrolling. The two additional
sample/navigation attachments are not counted as5 more tests. Exact command:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tools/audit/run_noncamera_ui.py --focus-only --simulator D4BAC4B1-5F7D-4C4E-88A5-FC10746C152C --simulator-name 'Rendprop TestFlight Gate 20260910' --derived-data /tmp/rendprop-spatial-integration.sLQDuM/DerivedData
```

No TestFlight or App Store operation occurred. The installed build18 is still
the earlier source, not this corrected simulator binary.

## Still-open build warnings and limits

The baseline Release build passed with8 unique warnings, repeated by
architecture in `build.log`: RenderEngine.swift:592/594/599/604 non-Sendable
captures; RendpropApp.swift:1800/1818 redundant nonoptional coalescing;
NewListingView.swift:288 deprecated localized interpolation;
VoiceRecorder.swift:167 deprecated allowBluetooth. This unit does not fix them.
No large Dynamic Type, landscape, full device matrix, VoiceOver interaction,
physical AR capture, production API or real-room viewer result is claimed.
