# Privacy/Terms factual source repair — not publication approval

Branch: `fix/privacy-flow-disclosures-20260910`, based on2750953.
This source-only unit implements the factual corrections proposed in
[PRIVACY-POLICY-RECONCILIATION.md](PRIVACY-POLICY-RECONCILIATION.md).
**Not deployed. No Apple action. No provider agreement, retention setting,
effective date, consent record or customer data changed.**

## What changed

`services/edge/tour-host/src/legal.ts` now describes guest sessions; selected
whole-video and text/chat/script inputs; OpenAI and ElevenLabs; conditional
Apple server speech recognition; API transit through Supabase; conditional
CRM sync and its actual field subset; and shared-workspace/pending-cleanup
qualifications. Existing consent, content-ownership, subscription, liability,
retention and provider-purpose commitments remain, except the specifically
identified inaccurate operational recipient/deletion claims. The source date
is deliberately unchanged pending approved publication/notice.

Code evidence and source bases for each flow remain in the reconciliation
document. This unit also directly re-read the lead `pushToGHL` payload and
insert/call site, the speech fallback and recognition request, and the full
account deletion path. These are supported paths, not claims that every
provider is active or that production cleanup scheduling is healthy.

The browser exposed an additional defect: the provider table made a320px
viewport scroll to385px wide. Fixed-width wrapping removed overflow but made
the columns unpleasantly narrow. Final CSS presents vertically readable,
purple-accent provider cards below540px and a table above it. Explicit table,
row/cell roles and visually clipped column headers preserve the relationships;
they are not removed with `display:none`. This is not a physical VoiceOver test.

## Executed evidence

From `services/edge/tour-host`:

```sh
node scripts/check-legal.mjs
node node_modules/typescript/bin/tsc --noEmit
npm test
```

- The first command on unchanged legal source executed53 assertions,33 failures,
  exit1,0 skipped: `/tmp/rendprop-legal-before-20260910.log`.
- Final legal gate:57 assertions,0 failures/skips, exit0, actual generated
  Privacy/Terms HTML. Four later assertions cover the responsive table roles.
  `/tmp/rendprop-legal-after-20260910.log`.
- Full host gate re-executes because public-page source/package test wiring
  changed:557 unbranded +584 route +707 upstream +418 form +57 legal assertions,
  plus12 existing gate self-tests. No provider calls in the new legal gate.
  `/tmp/rendprop-legal-host-final-20260910.log`.
- Typecheck uses the already-installed pinned project TypeScript and Workers
  types through local ignored dependency links; no fresh-install claim.
  `/tmp/rendprop-legal-typecheck-20260910.log`. Initial `npm run typecheck`
  exited127 because this deliberately partial borrowed installation lacked
  `.bin/tsc`; the explicit installed compiler command above was then used.
  That first command did not execute tests and is not counted as a pass.

Actual browser: Codex's in-app browser against a loopback-only Node server
importing the actual `privacyPage()`/`termsPage()` functions. No production
website mutation or visit was needed. The requested agent-browser CLI was
unavailable(exit127); its visual verification workflow was followed using the
available browser controls instead. Cloudflare/Supabase guidance informed
source review; browser-verification guidance required an actual rendered check.

Before: `if (document.documentElement.scrollWidth > innerWidth) throw ...`
failed with385 >320. One immediate recheck still failed because the temporary
preview had cached its old module; the preview was restarted with source
mtime-based reload before the corrected result was accepted.

Final browser checks:24 assertions passed across mobile-card roles, both pages
at320/390/768/1440px, and return navigation. Page scroll widths were respectively
305/375/753/1425px (the browser's scrollbar accounts for15px). The actual
Privacy→Terms→Privacy links worked. Error/warning log readback was empty.
The mobile provider-card screenshot was visually inspected in the tool output:
provider names, labels and paragraphs are readable and unclipped. Browser
screenshots remain conversation evidence, not invented local image receipts.

## Gates that remain

Owner/legal must approve wording, effective date and change notification before
publication. Vendor contracts/retention/training settings, purge/sweep operation,
backup/log retention, App Store privacy labels and remaining app deletion copy
still require the evidence listed in the reconciliation report. This source
repair does not validate those promises. Light-mode visual contrast, real-phone
accessibility, full VoiceOver navigation and the production responses were not
tested here. No app binary, authenticated browser workflow, camera or real AI
output was exercised by these public-page checks. No whole-app GO is claimed.
