# Studio release evidence — September 14, 2026

> **Historical evidence: 14 September 2026.** This report preserves the behavior,
> versions, test counts and open checks observed at that release. For the current
> Create-first navigation, property edit/chat sync, prompt library and deployment
> state, read [the 24 September production record](../../handoff/CODEX-STUDIO-LIVE-20260924.md). Guided prompt
> enhancement is live; optional LLM enhancement and Presenter generation remain
> disabled. Older screenshots, TestFlight references and local-only boundaries
> below are not a current release checklist.

The expanded workspace is deployed at <https://studio.rendprop.com>. The homepage
links to it, and `rendprop.com/studio` redirects there. Native version **1.0.3 (27)**
is processed and available for internal TestFlight testing.

See [the feature and handoff report](../STUDIO_RELEASE_20260914.md) for the supported
phone-to-office workflow and its boundaries.

| Validation | Result and evidence |
| --- | --- |
| Web unit tests, TypeScript, production build | 253 tests passed, no skips; [log](web-tests-and-build.txt) |
| Backend TypeScript and tests | 86 tests passed; [tests](backend-tests.txt), [typecheck](backend-typecheck.txt) |
| Connected application | 8 browser groups; [receipt](connected-browser.json) |
| Properties and publishing controls | 12 browser groups; [receipt](listing-browser.json) |
| Shared editor and real video exports | 13 browser groups, decoded video frames and audio; [receipt](editor-browser.json) |
| Creative workflows | 8 browser groups; [report](creative-parity.md) |
| Business operations | 7 browser groups; [receipt](business-browser.json) |
| Planner recovery | 4 browser groups; [receipt](planner-browser.json) |
| PostgreSQL roles and documents | 8 checks; [receipt](document-schema.json) |
| PostgreSQL gallery transactions | 16 groups; [receipt](gallery-schema.json) |
| PostgreSQL edited-output disclosure | 12 groups; [receipt](creative-edit-output-sql.json) |
| PostgreSQL voice reservations and cleanup | 20 groups; [receipt](voice-cleanup-schema.json) |
| Native sync and upload recovery | 55 sync assertions, 139 upload assertions, 7 rejected mutation controls; [receipt](native-validation.json) |
| Deployed integration | 12 groups with two real sessions, PNG and MP4 byte read-back; [receipt](live-sync.json) |
| Production UI | Existing Apple account restored; read-only workflow navigation; [receipt](production-browser.json) |
| Production assets | Every served asset matches the tested build; [receipt](deployed-assets.json) |

The deployed integration found an ordering defect in the original media read
query. The save transaction was correct, but the read still sorted by UUID. The
final query uses the saved gallery order before pagination and suppresses capture
aliases across pages. Regression coverage includes 53 gallery photos and their
capture aliases. The [original failed run](live-sync-ordering-regression.json) is
retained; the final 12-group run passes unchanged ordering assertions. Production
UI verification also found and fixed the empty-name Apple account button.

[Web deployment](web-deployment.json), [backend source manifest](backend-deployment.json)
and [live function versions](edge-function-versions.json) identify the release.
All staged backend source hashes match the checkout. JWT verification stays enabled.
The [security advisor review](security-advisors.json) records the intentional private
tables and the caller-bound boolean account check; it does not claim all existing
project advisories were resolved. Text test logs have repository whitespace normalized.

No customer record, invitation, public tour or paid generation was used in the
production integration fixture. Its synthetic accounts were removed through the
normal account-deletion route. Storage remains in the existing leased cleanup
queue until upload/voice write deadlines drain; the [five-minute cleanup job](cleanup-schedule.json)
was verified and these receipts do not claim pending bytes are already deleted.

These results are not a physical iPhone acceptance pass or a live paid-provider
quality test. Install build 27, use the same Apple account and workspace, upload
phone media, and use **Save setup** for the phone editor handoff. Local capture,
LiDAR and unsupported local-only timeline content retain their native workflow.
