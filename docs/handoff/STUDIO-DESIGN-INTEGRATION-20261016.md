# Studio design integration

The five delivered Claude design patches are integrated with the existing native
iPhone/shared-backend architecture intact. Studio uses the new typography,
materials, cards, press feedback and reduced-motion behavior. No PWA migration.

Integrated checks found and repaired real touch-size deficits: the chooser/login
close controls, ordinary mobile text inputs, three video disclosure rows and the
Planner's two backup buttons. Touch targets keep a compact appearance while their
interactive area reaches44px. Photo tips now explicitly say to use0.5× whenever
needed to fit the whole room, with landscape prioritized for listing websites.

The actual component fixtures now import the shipping design CSS. The strict
probe checks normal-text4.5:1 and large-text3:1 contrast where computed solid
backgrounds can be measured, full hit areas, keyboard dialog paths, opener
restoration, light/dark views and reduced motion. Gradients, imagery and material
backdrops are explicitly unmeasured; this is not full WCAG certification.

One test boundary needed accurate browser handling: a native modal can send focus
to browser chrome. The probe allows that only when the document has lost focus,
BODY is not focused/focusable, and the same connected native modal remains open;
one further same-direction key must reenter that exact modal. Background page
controls still fail. The custom sign-in dialog has no such exception. Underlying
page hit areas are measured with the real nonmodal More tools popover closed;
its open state has separate target and keyboard checks.

## Executed local checks

- Accessibility probe:466 checks,411 target measurements, including381 enabled
  controls with44px geometry and all five hit points. Thirty disabled controls
  are recorded separately, not counted as passing touch targets.
- Eight styled workflow suites:85 checks covering Library, video, processor
  permission, listing selection/completion, Business, entry points and Creative.
- Existing units:726 pass,0 fail/cancel/skip; typecheck and connected build pass.
- Built assets:393,303/400,000 bytes gzip; initial147,756, creation218,770 and
  large-video224,957 within their existing limits. Same brand, private noindex
  and connected configuration checks pass.
- Four retained defect controls refuse the old small close/input targets,
  missing focus indicators and insufficient normal-text contrast. They are
  identified as prior scoped executions, not final-source reruns.

All462 source inputs and31 tool hashes remained stable through the final serial
run. Root inspected retained chooser, sign-in, menu, video, Creative and listing
screenshots. Independent source/proof/build review is GO. The Creative review
assertion remains unchanged and passed; an earlier supplier failure was not
reproduced and is not claimed fixed by these cosmetic changes.

Evidence: `/Volumes/Rendprop Files/Builds/Active/build88-claude-design-integration-review/runtime-attempt7/REVIEW-READY.json`
SHA-256 `60405d92ceacd729e2b8df599ffbde69ba2000b722955c755a3d73a920701075`;
independent review `ee5a7b85c1661450373b47bcef9884cab5073e57ac1ed4193ac35a46e5bdf7ea`.

These are local Chromium/fixture results. Current full CI, hosted delivery,
Safari/phone/assistive-technology acceptance and real-account end-to-end checks
remain separate. Component mobile screenshots do not all emulate coarse input;
the strict actual-App probe does. The39-file build is frozen, not yet deployed.
