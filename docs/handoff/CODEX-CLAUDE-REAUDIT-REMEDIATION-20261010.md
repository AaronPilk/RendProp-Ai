# Build 56 — Claude re-audit remediation

This supersedes the build-55 handoff for the new findings in Claude's 2026-10-10 re-audit. The original build-55 audit, failed runs, signed artifacts and receipts remain preserved. **TestFlight 1.0.4 (56) is VALID, APP_STORE_ELIGIBLE and IN_BETA_TESTING for internal testers. No App Store submission was made.** Submission remains pending the independent final verdict and the acceptance work below.

## Release binding

- Release branch: `fix/build56-final-reaudit-20261010`; final product/source checkpoint `6d320d623d800fdb42b1e56dce51756cd45fad9f`. The prior `audit/launch-alignment-20261008` branch is preserved at317309a so its existing long CI run is not cancelled. No shared history was rewritten.
- Archive/export/upload source: `362693653060070ed42feb7cf5875d9b60960e43`. Product remediation was committed in `a114710`; `3626936` advances a test-only historical replay pointer.
- Apple build ID: `4c8413bc-1a73-4ccb-aeee-3c9e3286571f`. External state is `READY_FOR_BETA_SUBMISSION`.
- IPA SHA256: `d90670982499286bfd2ac86c9300669e7f66fa4bff64f535cdf4e396de845a15`; archived binary SHA256: `3687f863daf6d560c195d2f49882c59dbc49ca5fca53f0dd996991c5b47048e9`.
- Independent signature/profile verification confirms production APNs, App Store distribution and no debug entitlement in the exported IPA. The pre-export archive is correctly development-signed. Archive/export/dSYM arm64 UUID: `5AC13992-2087-3E56-9650-458A80B20589`. Privacy manifest equals committed source. All 135 tracked compiled Swift inputs match the archive checkpoint, plus one generated asset-symbol input.
- Later changes include the server-only legacy notification migration, its tests/replay drivers, audit fixtures, documentation and an exact historical checksum exception in `.gitleaksignore`; they do not enter the IPA. The 197 tracked native/ASC files in the manifest inventory remain byte-identical to the archive. The portable manifest distinguishes the completed hosted run from final server SQL verified locally and deployed afterward.
- The approved Home UI, listing toolbox, spatial runtime, funding, allowances, commission schedule, credentials, repository visibility and John Apple are unchanged. Settings changes are deletion/wipe lifecycle calls, with no design change. No paid generation, real purchase, buyer lead or physical camera test was performed during this remediation.

## Both new blockers

| Finding | Final behavior | Executed evidence |
| --- | --- | --- |
| B1: Apple adoption hides never-synced guest drafts | The exact verified adoption journal authorizes all its production local IDs, including unsynced drafts. Custody transfers to the destination account and receipt library; server identities, local edits and files stay intact. Foreign, sample and unjournaled drafts remain fenced. Completed build-55 receipts can repair source-owned offline drafts during actual reload without reverting later destination-owned metadata. Persistence failure rolls back memory and journal. Outgoing library context is read under the outgoing owner. | Original code fails four of 98 assertions. Final actual AppModel/PersistentStore extraction passes 124 assertions plus nine compiled semantic faults; optimized build passes 124; production-library checks pass 16. Tests reproduce the real source-before-session ordering and verify visibility, sync eligibility and durable reload. |
| B2: terminal push cleanup strands every subsequent account | Expired/forbidden outgoing credentials (`401`, `403`, `RP401`) retire only the captured cleanup entry. Network/5xx/incomplete acknowledgments remain retryable barriers. Signed-out startup retries cleanup. A readable corrupt queue can recover only after secure removal is verified; a locked Keychain still fences registration. Confirmed server account deletion skips queuing a dead credential. Explicit local wipe removes the captured queue and sticky flag. Failed writes and a second account change during awaited deletion cannot cross the cleanup barrier. | Actual native methods: 67 assertions plus ten compiled defects. Actual account-deletion methods: 144 assertions plus nine defects, including a dead-session-queue mutation. Server takeover/late registration/deletion races are independently tested. OS, Keychain and HTTP are synthetic here; actual APNs delivery is not claimed. |

The server token takeover fix complements terminal cleanup: replacement registration retires the displaced session under the canonical token lock. Late old-session POST is refused; old-session DELETE cannot remove the new registration. A profile/deletion lock conflict returns a retryable refusal before changing device rows. Previously delivered OS banners cannot be recalled.

A followup inspection found all three existing device rows lacked a stored session ID. The initial modern-session fix could not fence these legacy rows. An actual disposable SQL reproducer demonstrated that a delayed old-account registration could reclaim its token; a second reproducer showed the same gap through the caller's opposite environment. The appended migration now records a private cutoff before legacy takeover **and successful legacy unregister**, checks Auth session creation time and ownership for genuine new sign-in, and applies both cutoff and modern tombstone checks across environments for the canonical token. The exact already-current binding remains usable. Missing, undated, other-user and old session evidence is refused. No existing device/Auth rows were rewritten.

Final synthetic SQL coverage: legacy recovery **23**, modern takeover **10**, canonical session fencing **29**, each at fresh/replayed/restored boundaries; eight compiled-function faults are rejected and two unknown predecessors refuse migration. The prior 9/27-case fixtures remain byte-for-byte historical evidence; their opposite-environment success oracle is explicitly superseded, not silently reused.

## Concrete re-audit followups closed

- **Team selection:** non-switchers cannot explicitly select another owned library and enter the `active != own` state. Implicit stale selection resolves to the authorized own library. Adoption retains an already-bound live private Team library. First-time invite acceptance uses the same actor/profile/org lock order as account deletion.
- **Deleted Team-child video settlement:** the exact durable reservation identity binds a late ledger row even after its child org was deleted. Immutable parent liability remains counted once. Forged, mismatched and live-org metadata cannot settle or release the surviving hold; this does not necessarily reject the ledger row itself.
- **Photo requests:** preserve/negation clauses no longer exempt hidden defects or compound permanent changes. Fixed fixtures, defects and material substitutions named in the audit are covered. Benign preservation and furniture requests remain accepted; staging refusal choices concern furniture. Both original and polished requests are checked before photo dispatch. This is intent protection, not proof that a provider will obey every lock.
- **APNs privacy:** the final serializer permits only validated route IDs and slug. Raw name, address, email, phone and nested-fact fields are dropped, even through a caller that bypasses the first filter. Actual emitted JSON and recipient routing are tested; removing the final whitelist fails the privacy assertion. This is a field whitelist with trusted route producers, not semantic screening of every permitted slug string.
- **Public copy/contracts:** the unsupported payment-estimate promise and automatic original-publication claim are removed. The lead handler header documents the actual acceptance contract. The late-body lead fixture uses the real successful receipt. Earlier original five blocker fixes remain present.

## Deployment and readback

Repository migration: `services/supabase/migrations/20261010030225_reaudit_library_session_settlement.sql`, SHA256 `eca6c6354bd2c9a0f4b0bbf3e96ab6078f9d14799ada0fa401f7d0edd21ef5ba`. Supabase MCP recorded the applied migration as **`20261010031507 reaudit_library_session_settlement`**. These timestamps differ; the six final bodies and ACLs are read back and match the tested source. No existing migration was rewritten or historic customer content moved.

| Function | Live body MD5 |
| --- | --- |
| `accept_org_invite(uuid,text)` | `09979c64b6c436674113a1de271dfe6a` |
| `adopt_anonymous_org(uuid,uuid,uuid,uuid)` | `f386a4f2a7d578ceb1cbbdbee8a69349` |
| `workspace_directory(uuid,uuid)` | `746cc680332190d8338147f67308ce22` |
| `select_workspace(uuid,uuid)` | `922f967fa624cc026dbe6f60ad922a0e` |
| `cost_ledger_settle_serving_hold()` | `b02d5dc9f5a6196e9c658ab236c90475` |
| `notification_register_device_session(uuid,uuid,text,text,text,text,text)` | `1864eeb90382f6e43ecb140ae2b29fed` (superseded below) |
| `notification_unregister_device(uuid,uuid,text,text)` | `a3c0fcb96cc119bb0130aa4449a77430` (appended migration) |

The first migration's registration body was `496ab4845be208fa8e59ed40100d3d70`; the table above reports the current replacement. Repository migration `20261010042000_legacy_notification_session_retirement.sql` was applied as **`20261010040603 legacy_notification_session_retirement`**. Both current notification RPC bodies/ACLs were independently read back. The added `notification_legacy_device_retirements` table has RLS, zero policies and no direct PUBLIC/anon/authenticated/service-role access. Its definer owner can read the required Auth session timestamp. All listed functions retain security-definer/empty search-path settings and deny PUBLIC/anon/authenticated execution, preserving existing service authority. Advisors show no new WARN/ERROR. The table has intentional deny-all RLS. Existing warnings are not claimed fixed.

- **ai-photo 68:** all 36 returned files match prepared source; JWT verification remains on.
- **ai-copy 35:** all 25 returned runtime files match; the compiler elides the type-only `providers/types.ts`; JWT verification remains on.
- **notify 24:** all 14 returned files match; existing handler authentication/JWT configuration is preserved.
- **leads 48:** all 13 returned files match; its only new source change is the contract header. Existing public-handler authentication/JWT configuration is preserved.
- **Tour host:** worker `721537d4-9327-4d0c-b572-66a8876861ff`; full predeploy passed. `/features`, `/terms`, `/privacy`, `/support` return 200 and match repository-emitted output after removing exactly one known 938-byte Cloudflare JSD insertion. Only its dynamic ray/timestamp fields may vary; altered platform code and unrelated scripts are not stripped. Raw responses are not byte-identical. Original default-UA 403 evidence is retained.
- **Studio:** worker `ebce398f-5cf5-4b86-8caa-c9f9ced4a084`; verify passes 478 tests/typecheck/build, deployed readback verifies all 31 assets and route checks. Authenticated login is still a separate acceptance check. Gzip 349,053 bytes is below the unchanged 350,000-byte ceiling.

## Apple draft preparation

Exact iOS **1.0.4** version `39ff74df-71d4-4bf1-92f4-9c709e7f4366` now links **build56**. The same existing draft review `ecf0a17a-6fdd-40c9-8e0b-39f345b1b830` contains this app version plus the three corrected monthly subscription versions. Readback confirms `READY_FOR_REVIEW`, with no submission requested. The only two writes were attaching the exact eligible build and adding this version to the draft; there was no review-submit action.

The prior read-only Apple snapshot separately verifies annual products off sale, USA monthly $49/$99/$249 prices and one-week trial configuration, corrected staged allowance copy and seven complete screenshots. Approved predecessor subscription descriptions remain historical/live until Apple approves their corrected versions. No price or entitlement changes were made to address that history.

## Automated proofs and CI

Private evidence root: `/Users/pilksclaes/LocalRendpropAudits/claude-reaudit-remediation-20261010/`. Unmounted private receipts are missing independent evidence; do not treat this prose as a substitute for executing or reading accessible hosted tests.

- Full local edge suite: **1,885 passed, zero failed, one ignored**. Focused prompt/actual-handler checks: 59. Notify/APNs privacy handlers: 37.
- New database driver: historical 41 assertions and the exact 9-case device fixture at the first migration boundary; final 42 assertions at fresh/replayed/restored boundaries; four real connection races; six unknown-predecessor guards; three restored-old-function controls. The superseded first migration refuses an attempted final-schema overwrite atomically. Final legacy notification driver adds the 23/10/29-case suites and eight compiled controls described above. Final account safety passes 77 at each boundary (historical75 retained); final selection28 plus35 handlers, Team154 and private-testing historical81/final82 also pass against the final canonical migration, retaining their original controls/races. All five final driver receipts match current source hashes. Existing relevant settlement/funded suites passed; final invariants are 270/270.
- Local Phase1: 35/35, none skipped. Required-account fixture: 50 assertions plus 12 faults. Apple-code/session fixture: 29 plus five faults. Both fixture templates now accept the real defaulted cleanup parameter; no assertions or product code were removed.
- Hosted run `38020036391` failed a generic-key heuristic on an already-committed migration-file checksum. The checksum was recomputed against its source, then only the exact historical commit/file/rule/line fingerprint was excepted. Initial full667-commit history scans with the pinned Gitleaks release found no leaks; a synthetic unused key negative control still fails the generic-key rule. The final code history at6d320d6 also passes669 commits. No broad exclusion or credential change was made.
- Hosted run `38020286893` failed three jobs. The native stub mismatch is corrected with the evidence above. The personal-card migration driver now applies its unchanged exact three-addition oracle at the historical migration boundary, then proves replay cannot replace the current reviewed adoption definition. Its card/adoption/base assertions, five mutated-function controls, CAS and adoption/deletion races pass; 19 later commands hidden by that CI stop also passed locally. The retained hosted sequential-original refusal, trace-only diagnostic repair, unchanged local pass and pending CI state are recorded in the portable release manifest; its trigger remains unproven.

Hosted run38021265572 is still in progress at317309a with11 jobs green; native step49 is compiling unchanged floor-measurement controls. No full hosted success is claimed yet. Full CI was explicitly dispatched as **38023826741** on the release branch at **740438fc8d8b5fad8ff067af02734bc4697f1804**, preserving the earlier run. Its workflow/test/product source equals6d320d6; it is still in progress, not a completed success. Subsequent commits change only this handoff, prompt and portable manifest. The workflow has a main-only push trigger; no gates were removed or skipped.

The portable manifest records hosted CI at its exact source checkpoint and the separately source-bound final SQL receipts. Run38023826741 and every step must be inspected before claiming full hosted success on the final product/test/workflow source. Later documentation-only commits do not change that tested source. Failed, canceled, local-only and successful hosted results remain distinct; native byte equivalence does not make later SQL a hosted-tested change.

## Remaining acceptance and limitations

These are not relabeled as completed by the new tests:

- Physical phone: offline 1.0.3 guest draft → upgrade → Apple sign-in; account deletion → replacement Apple sign-in/push registration; fresh sign-in; real Team invite/removal and owner library access; StoreKit eligibility/purchase/cancel/restore/Ask-to-Buy; camera framing/interruption; Files/Photos delivery; Maps/tel/mailto; iOS 16 push; Safari video sound/Turnstile; authenticated Studio login. A simulator cannot prove them.
- Ordinary non-sponsored photo/reel/aerial calls, successful settled hold IDs, actual output quality, provider prompt/truncation behavior and supplier invoices remain unverified in this remediation. The 75% net-margin calculation is still a catalog-bound model until supplier receipts and the Apple payout confirm it. Funding and the scheduled commission change were not enlarged or overridden.
- A native manual photo retry after a lost response still uses a new operation UUID. Durable photo retry recovery and reconciliation of genuinely uncertain/non-winning historical liabilities remain deferred; no missing ledger was invented or silently released.
- Multiple preexisting content-bearing owned libraries and a paid subscription on the nonselected library still need a deliberate grouping/billing solution. This patch preserves content and fixes authority/selection; it does not merge libraries or move entitlement rows. Legacy binding/backfill preference review remains separate.
- Signed price/offer/currency persistence, dormant Python cost accounting, legacy invited Studio/brokerage contract rows, old-owner hidden local caches and media proxy amplification remain the prior documented followups.

## Next independent pass

Read this handoff and `docs/releases/TESTFLIGHT-56-CLAUDE-REAUDIT-REMEDIATION-20261010.json` in full. Bind the final source, exact completed hosted CI steps/artifacts, production definitions/bundles and immutable build 56. Reproduce B1/B2 through the real extracted paths and the selection, invite/deletion, token takeover, settlement, prompt and APNs controls. Give GO/NO-GO with exact evidence/reproducers, and separate automated closure from phone/model/invoice acceptance. Do not edit, deploy, change credentials/visibility/funding, make paid calls, touch John Apple or submit to Apple during that review.
