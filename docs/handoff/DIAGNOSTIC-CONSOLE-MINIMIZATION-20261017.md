# Diagnostic console minimization — October 17, 2026

The source review found three concrete paths that could put freeform upstream data in hosted console logs. These local fixes remove that data while retaining useful failure classifications. No historical credential or customer-data exposure has been established. No deployment or privacy-questionnaire change follows from these tests.

| Source | Local change | Actual verification |
| --- | --- | --- |
| `services/supabase/functions/ai-chapters/gemini.ts` | Replace response-body, deletion-handle and caught-message logging with a closed event, phase, HTTP status and allowlisted exception name. Provider requests/results, client errors and cleanup behavior remain unchanged. | New helper tests: old source 4 pass/8 fail; candidate 12 pass. Existing chapter regressions: 31 pass. Three separately restored logging defects fail the specific privacy assertion. |
| `services/supabase/functions/me/index.ts` | Replace the Apple-code catch's raw Error with a closed event and allowlisted exception name. Actual token exchange, authenticated profile storage and fixed client envelope remain unchanged. | Covered by the 17 new tests below, using the actual handler and Apple helper with an ephemeral synthetic signing key and intercepted transports. |
| `services/supabase/functions/_shared/ledger.ts` | Remove raw database/transport messages and the structured message field. Retain intentional hold correlation and valid SQLSTATE/PostgREST codes; unknown codes stay unknown. Exact rows, cents, outcomes, returned reasons and retry behavior remain unchanged. | Apple/ledger tests: old source 7 pass/10 fail; candidate 17 pass. Existing regressions: 42 unchanged account tests plus 4 ledger cases pass. Only three diagnostic expectations in the old ledger tests change. Five restored logging defects fail the intended privacy assertions. |

Tests use cached dependencies, denied network access and synthetic inputs. They intercept all console arguments and check both privacy and unchanged functional contracts. The current recursive Edge Function CI command automatically discovers the three new test files; no hosted CI result is claimed for this new source yet.

The exact external receipts are:

- `/Volumes/Rendprop Files/Builds/Active/build88-o07-other-diagnostics-inventory/FINAL-REVIEW-READY.json`, SHA `83549495`; root integration `332eea4c`.
- `/Volumes/Rendprop Files/Builds/Active/build88-o07-apple-ledger-diagnostics/REVIEW-READY.json`, SHA `7918e50b`; root integration `d5a74b7b`.

## Privacy evidence and limits

Native diagnostic events carry device/session identifiers; the server adds the signed-in user/org. Hosted invocation metadata may also support linkage. These console fixes do not anonymize logs or remove intentional audit/financial identity. Customer narration is a separate uploaded media path, not diagnostic telemetry.

Source shows a local queue limit of 2,000 events/seven days and a SQL purge function with a 180-day default. That is not proof that the hosted schedule currently runs. Platform/vendor log retention remains unknown; current account settings and the full authenticated App Store Connect questionnaire still need review. Other Diagnostic Data remains open.

The routine MetricKit payload callback currently sends no launch histogram or median launch time. Internal rationale and native comments were corrected; parsed privacy-manifest declarations are unchanged. The existing public legal example mentioning median launch time remains a tracked notice correction. The separate processor-consent notice stays held, and paid Kie activation remains off.

No public notice, App Store answer, manifest declaration, provider permission, financial record or user media was changed by this work.
