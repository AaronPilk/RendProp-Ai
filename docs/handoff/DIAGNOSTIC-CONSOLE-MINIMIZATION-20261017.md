# Diagnostic console minimization — October 17, 2026

The source review found three concrete paths that could put freeform upstream data in hosted console logs. The reviewed fixes remove that data while retaining useful failure classifications. No historical credential or customer-data exposure has been established. The selective production rollout below is verified; no privacy-questionnaire change follows from these tests.

| Source | Local change | Actual verification |
| --- | --- | --- |
| `services/supabase/functions/ai-chapters/gemini.ts` | Replace response-body, deletion-handle and caught-message logging with a closed event, phase, HTTP status and allowlisted exception name. Provider requests/results, client errors and cleanup behavior remain unchanged. | New helper tests: old source 4 pass/8 fail; candidate 12 pass. Existing chapter regressions: 31 pass. Three separately restored logging defects fail the specific privacy assertion. |
| `services/supabase/functions/me/index.ts` | Replace the Apple-code catch's raw Error with a closed event and allowlisted exception name. Actual token exchange, authenticated profile storage and fixed client envelope remain unchanged. | Covered by the 17 new tests below, using the actual handler and Apple helper with an ephemeral synthetic signing key and intercepted transports. |
| `services/supabase/functions/_shared/ledger.ts` | Remove raw database/transport messages and the structured message field. Retain intentional hold correlation and valid SQLSTATE/PostgREST codes; unknown codes stay unknown. Exact rows, cents, outcomes, returned reasons and retry behavior remain unchanged. | Apple/ledger tests: old source 7 pass/10 fail; candidate 17 pass. Existing regressions: 42 unchanged account tests plus 4 ledger cases pass. Only three diagnostic expectations in the old ledger tests change. Five restored logging defects fail the intended privacy assertions. |

Tests use cached dependencies, denied network access and synthetic inputs. They intercept all console arguments and check both privacy and unchanged functional contracts. The current recursive Edge Function CI command automatically discovers the three new test files; the actual current5b9 Edge CI job succeeds in run39019520895. The overall run has two unrelated media failures; it is not whole-app clearance.

A normally checked current-source recursive run now proves all106 named cases in the nine relevant modules together:31 chapter regressions,29 direct privacy tests and46 account/ledger regressions. Root verified each recorded case against the original stdout and the current source/snapshot pins. This supersedes the earlier stale31-test combination limit. The overall run remains incomplete:2,770 cases passed, six fixture/setup units failed and one existing Postgres case was unexecuted. Completion-only follow-ups now bring the retained composed total to2,778 passing cases plus32/32 normal route checks, without repeating earlier passes. The existing Postgres case remains unexecuted. Root verifies161final proofs in external `build88-o07-backend-remaining-completion-preparation-v6/execution-once` (d248d558); preserved setup refusals remain visible. Local Deno2.7.13 is distinct from CI2.9.6; this local suite alone does not establish deployment or whole-CI acceptance. Receipt `aa2ffbfb` in external `build88-o07-current-backend-dev-types-snapshot-v3/execution-once`.

The source-only deployment impact map covers all32 entrypoints and240 local inputs. Fourteen functions include the ledger module, and the independently changed `me` handler brings the prospective rollout to15 functions. Deploying only `me` and `ai-chapters` would leave13 ledger consumers on their earlier code. This is an impact plan, not permission to overlay current sources: fresh per-function deployed source, mixed JWT settings, full32 metadata and unchanged environment/schema policy must be bound before a selective rollout. Packet `53a689cd`, plan `059ef5af`; no new migration or provider request belongs to this logging change.

The exact external receipts are:

- `/Volumes/Rendprop Files/Builds/Active/build88-o07-other-diagnostics-inventory/FINAL-REVIEW-READY.json`, SHA `83549495`; root integration `332eea4c`.
- `/Volumes/Rendprop Files/Builds/Active/build88-o07-apple-ledger-diagnostics/REVIEW-READY.json`, SHA `7918e50b`; root integration `d5a74b7b`.

## Verified selective production rollout

All15 affected functions were deployed once and read back on October17,09:44–09:47UTC. Before rollout, actual mixed deployed packages passed29 privacy cases, four existing ledger cases and15 normal entry checks. A source-proven historical type-support file repaired an external verification fixture;17 support files and four tests were excluded from every deployment. Original setup refusals and composed-run boundaries are retained.

Fresh capture matched all32 complete metadata records and604 original source-file instances. The approved payloads changed only16 logging instances and preserved588 others. After15 deploy calls,15 immediate source readbacks and one final32-function metadata read, each selected version advanced exactly once. Function IDs, JWT/import-map policy and all17 unselected metadata records were preserved. Root independently compared every returned source body against its approved argument and all32 metadata records against the fresh baseline. There was no invocation, provider call, migration, authentication/secret change, user-data write, notice publication, Kie activation, retry or rollback.

Current selected versions include admin43, me71, studio40, ai-video89, property-video-jobs14 and property-video-worker14. The full15-version list and private code receipts are external:

- `build88-o07-logging-fresh-payload-review-20261017T093915Z/FINAL-SELECTIVE-LOGGING-ROLLOUT-RECEIPT.json`, SHA `2eea69c8350c9345a0b45d55be2def87fe629d7cc3c08499f6212b088af0c928`.
- Root review `ROOT-SELECTIVE-ROLLOUT-ACCEPTED.json`:124 retained proofs plus independent604-source/32-metadata comparison.
- Mixed-package proof `build88-o07-selective-mixed-package-verification-preparation-v2-remaining-type-support/FINAL-MIXED-VERIFICATION-AND-ROLLOUT-READY.json`, SHA `3e3cb39f543b7e4a9e17d16494997cb8a6a6404af4ad0c1b0b708ae58b1715f6`.

## Privacy evidence and limits

Native diagnostic events carry device/session identifiers; the server adds the signed-in user/org. Hosted invocation metadata may also support linkage. These console fixes do not anonymize logs or remove intentional audit/financial identity. Customer narration is a separate uploaded media path, not diagnostic telemetry.

Source shows a local queue limit of 2,000 events/seven days and a SQL purge function with a 180-day default. That is not proof that the hosted schedule currently runs. Platform/vendor log retention remains unknown; current account settings and the full authenticated App Store Connect questionnaire still need review. Other Diagnostic Data remains open.

The routine MetricKit payload callback currently sends no launch histogram or median launch time. Internal rationale and native comments were corrected; parsed privacy-manifest declarations are unchanged. The existing public legal example mentioning median launch time remains a tracked notice correction. The separate processor-consent notice stays held, and paid Kie activation remains off.

No public notice, App Store answer, manifest declaration, provider permission, financial record or user media was changed by this work.
