# Integrated backend verification — September 22, 2026

The combined Studio/capture/reflection backend passes its offline software and
disposable PostgreSQL checks. This report records tested source, not a deployment
or a claim about physical capture, provider image quality or actual billing.

The release combines `0687a0f` (TestFlight 30, with audited call fixes) and
`1cac978` (the previously deployed Studio and native continuity work). Current
working-tree hashes in the receipts are authoritative while integration continues.

## Changes completed here

- Resolved the tour disclosure merge: reflection removal remains `AI video`,
  while ordinary Studio edits retain `Edited media`.
- Added `edit:<listing UUID>` documents while preserving legacy `edit`, `planner`,
  `creative:<UUID>` and `native:<UUID>` records. New scoped edits require the key,
  request `listing_id` and draft `payload.listingId` to match. Invalid requests
  stop before database access. Authorized saves retain caller/workspace and
  compare-and-swap revision predicates. No migration is needed for this key format.
- Added review-only verification and source-manifest runners under
  `tools/audit/complete-product-20260922/`. Neither deploys services.

## Executed results

| Check | Result |
|---|---|
| Entire combined edge suite, including Studio, photo fallback and reflection | **940 passed, 0 failed, 0 ignored**, 47 test files |
| All function entrypoints | **24 typechecks passed** |
| Scoped document contract | **7 tests passed**, included in the 940 |
| Reflection and Studio edited-output handlers | **22 tests passed**, included in the 940 |
| Actual tour renderer reflection disclosure and original video pair | **25 assertions passed** |
| Tour-host TypeScript and seven existing gates | **2,745 assertions passed**, including 693 unbranded assertions |
| Production tour-host dependency audit | **0 vulnerabilities** |
| Combined migrations, fresh repository order | **65 files applied**, then 0055/0056 replayed |
| Combined migrations, production-equivalent order | Through 0054, then eight Studio files, then 0055/0056; both new files replayed |
| Reflection SQL | **51 assertions before and after replay in each order** |
| Photo fallback SQL | Exact active route lookup, unchanged disabled rows, prices, models and enabled flags pass in both orders, before/after replay |
| Shared voice reservation SQL | Passes in both orders, before/after replay |
| Database invariants | **266 per order**, 265 pass and the existing exact-name agent-reel headroom invariant 155 remains red |
| Reflection/accounting concurrency | **46 parallel transactions, 43 checks**, all pass |
| Existing Studio PostgreSQL suites | Documents **8**, generated quality **10**, edited output **12**, gallery **16**, voice cleanup **20** check groups, all pass |

The final edge run inherited no service credentials and denied runtime network,
process and write access. Dependency preparation was a separate caching setup
step with downloads permitted. All PostgreSQL connections used newly initialized,
owned clusters with Unix sockets and no TCP listener. The clusters stopped after
the checks. No production deletion, provider request or App Store operation ran.

Exact source/log receipts retained outside Git:

- `/tmp/rendprop-complete-backend-bbw7ekh1/receipt.json`: final edge tests, all
  typechecks, source unchanged and per-file SHA-256 hashes.
- `/tmp/rendprop-complete-backend-0fy5hrd_/receipt.json`: both migration orders,
  idempotent 0055/0056 replays, existing invariant exception, concurrency and
  stopped-cluster confirmation.
- `/tmp/rendprop-complete-studio-sql-mtz95vpv/receipt.json`: five existing Studio
  SQL suites with exact script/log hashes.

An earlier initial edge run also passed 936 tests before the four new scoped-edit
tests were added. It is not substituted for the final 940-test result.

## Migration interaction and production prerequisites

The root task's September 22 read-only production inventory reports migrations
through 0054 plus all eight Studio migrations, but **not 0055 or 0056**. Studio's
applied timestamp versions differ from the repository filenames. Identify those
existing migrations by their recorded names/content; do not rerun them merely to
make timestamp strings match. Several Studio migrations intentionally use plain
`CREATE` and are not replay scripts.

0055 adds durable reflection batches/jobs, their scoped service RPCs, immutable
accepted provenance and outstanding-cost holds. It extends the existing
`org_month_spend_cents` function so other spend checks see unresolved holds. Its
14-cent-per-input-second rate and 240-cent batch ceiling are explicit existing
implementation values. It does not alter `ai_routes` or enable a provider.

0056 changes only the `note` fallback marker on six already-enabled eligible
Gemini photo rows. It does not change prices, models, enabled flags or disabled
rows. The actual SQL fixture recreates the preceding failed lookup, applies 0056
twice, compares all non-note fields and every disabled row, and proves that an
operator-disabled task remains unavailable. No Kie/Higgsfield route is enabled.

Both application orders passed the same reflection, photo-fallback, voice and
invariant fixtures. The existing Studio quality triggers and reflection
provenance protections coexist; neither migration replaces the other's trigger.
The surviving red invariant is inherited: the agent-reel visible-answer limit
equals its token ceiling. This work neither changes that limit nor hides the check.
Its exact values are `copy.shotlist: 2400 > 1600`,
`copy.reel_script: 1200 > 700`, and `copy.agent_reel: 700 == 700`.
Migration 0034, `ai-copy/index.ts` and the OpenAI request adapter are byte-identical
to Claude's `7bcc624` source. The existing incomplete-response tests reject an
exhausted-token answer. This is an inherited potential completion/headroom issue,
not a newly introduced deployment regression. Keep the named exception visible;
changing that provider budget is outside this integration and is not required to
ship the unrelated capture, sync and document fixes.

## Exact deployment candidate inventory

The [source manifest](COMPLETE-PRODUCT-BACKEND-MANIFEST-20260922.json) contains
current hashes, local dependency lists and the root task's saved live-source
comparison. All eleven candidate functions currently have `verify_jwt=true`;
preserve that setting. Public tour consumers already use the existing contract.

| Function | Live version before | Why this package differs |
|---|---:|---|
| `admin` | 24 | Reflection price inventory and shared ledger |
| `ai-chapters` | 20 | Shared ledger/router |
| `ai-copy` | 13 | Shared ledger/router/provider chain |
| `ai-enhance` | 29 | Shared ledger |
| `ai-photo` | 45 | Audited validation/refunds/fair-housing output checks and shared policy |
| `ai-video` | 41 | Durable reflection job endpoints plus shared policy |
| `ai-voice` | 29 | Shared ledger/router/provider chain; live voice handler already matches |
| `coach` | 15 | Shared ledger/router/provider chain |
| `property` | 10 | Shared ledger |
| `studio` | 6 | Per-property saved-edit document contract |
| `tours` | 38 | Combined reflection/ordinary-edit labeling |

The saved live `listings` v33 and `me` v39 packages match the integrated source;
there is no source-based reason to redeploy them. Other unchanged functions are
not claimed freshly deployed or freshly compared where a readback is absent.

Recommended sequence for the root release:

1. Reconfirm the live migration inventory and preserve a source snapshot of the
   eleven candidate function packages.
2. Apply only missing 0055, then 0056, each atomically. Verify their RPCs, grants,
   fallback markers and unchanged provider flags using read-only queries.
3. Deploy the tested tour host and `tours` package before accepting new reflection
   edits, so public disclosure retains the complete original/result pair.
4. Deploy the other named function packages with their exact dependency files and
   existing JWT settings. The updated `ai-video` requires 0055; photo fallback
   requires 0056. No global spatial flag or disabled route is part of this release.
5. Deploy the matching Studio build. Read back served assets and every updated
   function package; record new versions and exact hashes against the manifest.
6. Run bounded synthetic two-session listing/document/media checks, including
   separate property drafts and original-preserving edited output. These checks
   must not delete or mutate the owner's real account and must not submit paid jobs.

The old `services/supabase/deploy-functions.sh` omits seven current functions and
must not be used as proof that all 24 functions were updated. Studio's historical
four-function script also omits the newly changed reflection/photo packages and
their other shared-helper consumers. Keep durable job tables and accounting
receipts intact if code is rolled back; do not reverse 0055 by deleting job data.

## Reproduce

```sh
python3 tools/audit/complete-product-20260922/verify_backend.py edge
python3 tools/audit/complete-product-20260922/verify_backend.py postgres
python3 tools/audit/complete-product-20260922/deployment_manifest.py \
  --readbacks /path/to/saved/readbacks \
  --output docs/releases/COMPLETE-PRODUCT-BACKEND-MANIFEST-20260922.json
```

The PostgreSQL runner adds `auth.users.is_anonymous` to its isolated Supabase
bootstrap shape, as the existing Studio SQL suites do. It does not alter the
production Auth schema. Physical camera/ARKit/thermal testing remains the owner's
phone work. Real reflection quality, staged-property fidelity and 3D reconstruction
acceptance remain separate from these software checks.
