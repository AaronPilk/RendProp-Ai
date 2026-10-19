# Provider dispatch and cost evidence — 4 October 2026

Prepared on isolated branch `fix/claude-audit-20261004`, based on the checkout
containing live Topaz guard `0b4a87b`. These provider changes are prepared for
commit and draft-PR review; they have not been deployed. No migration, function deployment, paid generation,
customer allowance debit, credential inspection or App Store action was
performed for this work.

## Findings and changes

The audit correctly identified lost allowances on definite provider refusal,
missing aggregate diagnostics, and FAL's completed-with-error polling shape.
The provider error boundary now distinguishes a definitive non-allocation from
an uncertain POST. Only the former can commit a rejection release before the
route attempts to refund its existing feature counters. Timeouts, 5xx, ambiguous
receipts and failed releases retain both hold and allowance, with no fallback
POST. Accepted receipts settle once; unavailable settlement keeps its hold and
still returns the receipt.

The new service-only rejection RPC stores immutable status/class tombstones,
rejects release after acceptance, and never frees the logical submission key.
Unresolved earlier-month holds continue to count until reconciled. Journal
identity, price and terminal receipts are pinned. Provider messages are generic;
diagnostics retain status/class without upstream bodies, prompts, keys or signed
URLs. Both FAL polling paths now report completed-with-error and failed result
responses as terminal failure instead of repeated processing/502.

The existing quota refund is best effort. It is ordered after durable hold
release, but is not transactionally coupled to that release. A failed counter
refund needs operational reconciliation. An asynchronously failed accepted job
does not automatically refund its original allowance or erase its cost receipt.

The maximum Topaz tariff reservation/booked estimate, output geometry checks,
single-POST invariant, shared reflection/ordinary cost ceiling, service-only
accounting and actor/workspace/deletion fences remain intact. No subscription
prices, feature quantities, credit wallet or 75% margin policy was changed.

## Provider cause remains unknown

Historical `provider_health` metadata does not establish a continuous 27-day
outage. The coordinator's read-only FAL dashboard check showed $25 balance and,
in the available 30-day view, two Topaz HTTP 503 rows and one Flux HTTP 422 row;
no Seedance failure was displayed. This is a limited dashboard observation, not
proof of access for every deployed key/model or complete request history.

The actual Seedance 1.0 Pro Fast adapter submits string durations and 1080p.
The aerial route uses 4/6/8 seconds, 16:9 or 9:16, and `camera_fixed: false`;
the reel route bounds duration to integers 2–12. These agree with the current
[official FAL endpoint schema](https://fal.ai/models/fal-ai/bytedance/seedance/v1/pro/fast/image-to-video/api),
which also accepts data URI inputs. No duration/resolution schema mismatch was
found. No paid canary was run, so the cause of any real fast rejection remains
unproven. The catalog probe now says authentication was checked and generation
was not verified. Do not label catalog success as generation-ready.

## Actual verification

| Verification | Result | Evidence |
|---|---|---|
| Focused provider/cost/probe/Topaz Deno suite on final provider source | 191 passed, 0 failed; source unchanged during run | `/tmp/rendprop-provider-audit-deno-source-bound-final.json` |
| Entire edge suite after all source-order fixes | 1,389 passed, 0 failed, 1 ignored | `/Users/pilksclaes/LocalRendpropAudits/claude-audit-20261004/edge-tests-final.log` |
| Separately executed ignored Presenter integration | 119 SQL checks and the actual controller Deno test passed | `build/pex-2jbc_4ni/receipt.json` and `controller.log` |
| New rejection SQL | 34 assertions on fresh apply and 34 on replay | `/tmp/rendprop-app-video-pg-i_11vrxc/receipt.json` |
| Preserved ordinary-video SQL | 101 assertions on fresh apply and 101 on replay | Same receipt |
| Preserved reflection SQL | 51 assertions; direct Bria: 37 assertions | Same receipt |
| Ordinary admission race | One $48 hold admitted and one refused against a $60 ceiling | Same receipt |
| Eight simultaneous settlements | One ledger ID; spend stays $48 while hold becomes booked cost | Same receipt |
| Ordinary/reflection overlap | One admitted; the other refused against their shared ceiling | Same receipt |
| Removed-lock negative control | Caught two $48 holds against a $60 ceiling | Same receipt |

An earlier full-suite run had one source-order assertion failure in
`_shared/paid-ai-auth.test.ts:163`; the successful later run above supersedes it.
The full run still records one ignored SQL-backed Presenter test. Its separate
run used an owned disposable PostgreSQL cluster and executed the actual
controller test successfully; this closes that omitted coverage without
rewriting the full suite's ignored count. The coordinator stopped and removed
the owned cluster data while retaining fixture logs and receipts.

FAL tests exercise the actual adapter, chain, reservation helper and extracted
legacy status handler with mocked 2xx/4xx/5xx/timeouts, no/malformed job IDs,
receipt-bearing refusals, local pre-dispatch failure, failed release and
completed-with-error. All three production submission route bodies are tested
for refund-after-release and no refund on uncertainty. Negative controls remove
definitive-rejection evidence and the terminal-error check and must fail.
The full-suite mock separates synthetic provider HTTP from synthetic telemetry;
it never calls a live Supabase or FAL endpoint.

The source hashes and log/receipt digests are recorded in
[`PROVIDER-DISPATCH-EVIDENCE-20261004.json`](PROVIDER-DISPATCH-EVIDENCE-20261004.json).
The final complete PostgreSQL run reapplied all current migrations; every one
of its 88 recorded migration/fixture/runner source hashes matches the reviewed
checkout. It records 125 commands including intentional admission and access
refusals. The earlier database receipt is retained as historical evidence and
is superseded by this final source binding. SQL receipts contain exact tested
migration/fixture hashes and command logs.
Hashes bind a result to its tested source; they do not attest a deployment or
provider output quality. Later source changes require fresh applicable tests.

## Deployment prerequisites

Apply `20261004215403_app_video_rejected_submission_release.sql` before deploying
the matching `ai-video` function. Read the existing deployment instructions and
verify that live function source still matches the intended base before any
replacement, preserving the live Topaz guard. Verify grants/RLS, release
tombstones and previous-month hold inclusion after migration. Read back deployed
function files and compare hashes; a local test receipt is not live evidence.

Uncertain existing jobs need provider/billing reconciliation. This change does
not retroactively classify old attempts or automatically release their budget.
No screenshot, catalog response or circuit-breaker timestamp substitutes for
that evidence.
