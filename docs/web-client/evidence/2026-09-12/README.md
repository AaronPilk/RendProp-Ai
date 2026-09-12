# Studio verification receipts — 2026-09-12

These receipts are actual test output copied from the test-created temporary
directories. They contain synthetic-media metadata and hashes, no customer media,
account session, provider credential, or signed customer URL. Do not infer live
sign-in, production database integration or social publishing from local tests.

- `editor-browser.json`: final audio-clock-fix build; 13 grouped checks and seven
  real downloaded encodings. Full dist manifest and observed served-asset hashes.
- `workspace-browser.json`: independent local workspace/planner/recovery and mobile
  navigation checks. The entry hash identifies the exact build used by that run.
- `marketing-browser.json`: 179 assertions, seven public pages at four viewports;
  original branding and actual source hashes. Separate from the Studio app build.
- `editor-browser-prior-build.json`: historical earlier passing single-clip suite.
  It does NOT cover the final photo→video audio-clock fix. Retained for provenance,
  not counted as an additional release gate or represented as current coverage.

Raw screenshots and synthetic video exports remain at the paths written in each
receipt. Temporary files can be evicted by macOS; durable hashes and measurements
are here. Reproduce from the source runners instead of treating a missing `/tmp`
artifact as a fresh passing test. Browser tests use Chromium; Safari, Firefox and
physical-device codec behavior are not verified by these receipts.

Public-site noindex and account-workspace noindex are different: the marketing
pages are intended to be crawlable, while the Studio workspace is excluded. That
exclusion is a crawler directive, not access control.
