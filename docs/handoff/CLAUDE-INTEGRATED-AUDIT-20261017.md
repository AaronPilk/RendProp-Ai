# Claude — audit of the integrated launch source (2026-10-17)

Scope: branch `feature/launch-checklist82-20261014` as it is, not as any
handoff describes it. Base for this audit: `f74e540` (last Codex push before
the takeover). Every statement below is either read from the source, executed
here (disposable PostgreSQL 16.15 / Deno 2.9.6 / Node as user `claude`), or
observed on a hosted CI run with its run id. Anything else is marked
**unexecuted**.

## 1. Commits since f74e540, by kind

| Commit | Kind | Product paths touched | Hosted proof |
|---|---|---|---|
| `f80dac4` Repair migration replay guard (Codex, rebuilt from the Mac object store, identical tree `de562620`) | product (migration guard) + test | `migrations/20261017110114_freeze_property_attempt_liability.sql` (guard admits predecessor `3976c4aa` and own `73882a6e` body), `functions/property/attempt-receipt.test.ts` | run 39040282783: migrations + disposable PG green |
| `4ea7625` make-video actor-switch ownership proof | test only | — | run 39040282783: Studio green |
| `f135d29` native_photo_family harness scoped to nine owned helpers | test only | — | run 39040282783: step green |
| `547fb7a` Deno 2.9.6 setTimeout typing (one token) | test only | — | run 39040282783: edge green (2820 tests) |
| `14f1a75` launch_blockers mixed-writer race: accept either legitimate RP402 + state check | test only | — | run 39040282783: disposable PG green |
| `7164e07` CI-repair handoff | docs | — | — |
| `b9d698f`, `61a547c` (Codex, recovered by the owner after a reset) | docs/handoff | — | — |
| `7130625` launch_blockers fixture `now() - 1 minute` | test only | — | run 39040282783: green |
| `770e7ac` RentCast fixture timers `ReturnType<typeof setTimeout>` | test only | — | **unexecuted on hosted CI** (local harness + driver pass) |
| `e020d6d` checklist reconciliation | docs | — | — |
| `b0a3642` run results + finishing-refusal analysis | docs | — | — |
| `5515820` api_cost_report_pg seed order (ledger row before attempt finish) | test only | — | **unexecuted on hosted CI** (local 25/25) |
| `57633d4` Kie scope consent harness applies the whole current catalog (181 floor) | test only | — | **unexecuted on hosted CI** (local 20/20) |

Net product change since f74e540: **one** (the replay guard in f80dac4). No
pricing, grant, selector, route, provider, Apple or onboarding change. No
deploy, no upload, no paid provider call, no production data change.

## 2. Hosted CI, exact

- Run **39040282783** at `7130625`: 13 success, 2 failure, audit-evidence gate
  — see §2.1. Failures: tour-host (`finishing-browser.mjs:118`, product clock
  guard refused a runner audio-sink stall; environmental, analysed in
  `CLAUDE-CI-REPAIRS-20261017.md`), CPU/background (`rentcast_billing_binding_pg`
  TS2322, fixed in `770e7ac`).
- The previous export-resume stall (run 39029975919) did not repeat; the
  `fixed` and `late-frames` variants ran and passed on the hosted runner.

### 2.1 Audit-evidence gate on 39040282783

(recorded when the run concluded — see the handoff's run table)

### 2.2 Next run

Pushed after 39040282783 concluded: `770e7ac`, `e020d6d`, `b0a3642`,
`5515820`, `57633d4` (+ this file and the handoff update). The run id and result are recorded in
`CLAUDE-CI-REPAIRS-20261017.md` once observed. Until then the branch is
**red** on hosted CI and no green claim is made.

## 3. Tests executed here on the integrated head (not on hosted CI)

| Proof | Result |
|---|---|
| `db-migrations` job mirror (bootstrap, 183 migrations, fixtures, erase-concurrency, invariants, replay DB, invariants) | 270/270 twice; immediate replay of 20261017110114 exit 0 |
| `run_database_regression.py` | accepted; 183 applied, 159 replayed, 5 negative controls exit 3 |
| Edge suite with CI's invocation (`deno test --allow-all --node-modules-dir=auto .`) | 2820 passed, 0 failed, 1 ignored |
| Studio: `make-video-browser` ×3, the 12 later suites, ledger test 4/4, positive control loops | pass |
| `native_photo_family_selection_pg.py` fresh/repeated/followup + 3 causal controls | 44/44/32/32; controls fail as intended |
| `launch_blockers_pg.py` ×8 (both orderings) + 3 controls | 8/8; controls fail as intended |
| `rentcast_billing_binding_pg.py` + driver unit tests | pass (12 positive / 14 identity refusals / 13 receipt refusals); driver 6/6 |
| `api_cost_report_pg.py` | unmodified: fails at seed (RP409) on 7130625; repaired: 25/25 |
| property-video-renderer tail (27 steps never reached by hosted CI since f74e540) | `/home/claude/cpu-tail-evidence/SUMMARY.txt` — see §3.1 |

### 3.1 Property-video-renderer tail

Mirror of ci.yml 1852–2030 on this head, 14:54–15:04Z, one disposable cluster
per harness: 26 of 27 exit 0 on the first run. The failure,
`property_video_kie_scope_consent_pg.py` (migration-count pin 181 vs 183),
is repaired in `57633d4` and passes (183 applied, 20/20 checks). Hosted proof
of all 27 is still **unexecuted** until the next run.

## 4. Unresolved defects and known-red items

| Item | Class | State |
|---|---|---|
| Hosted macOS runner audio/media stalls (export-resume run 39029975919; finishing run 39040282783) | environmental; product guards refuse correctly | 6 of the last 7 hosted tour-host runs hit one; never locally. Instrumentation proposal (CDP webaudio trace in the finishing suite) **not applied** — cannot be exercised outside macOS CI. No threshold, control or oracle weakened. |
| `tools/audit/api_cost_report_pg.py` seed order vs liability freeze | harness | fixed `5515820`; hosted proof pending |
| Latent UX copy inconsistency: video loser at the ceiling shows "Workspace monthly processing budget would be exceeded" vs "AI usage limit reached" | product copy, pre-existing | noted, not patched |
| B lane review item: ceiling counts max(bound, modeled) even for succeeded attempts | product semantics, owner decision | on `claude/pipeline-hold-binding-20261017`, unpushed |
| o12 external VM resume stalled in Lima's boot-scripts phase (`/run/lima-boot-done` never written in 79 s; first boot ≤ 10 s) | environment, undiagnosed step | read-only extraction of the guest's cloud-init logs from the raw root disk is the next proof (`O12-VM-STARTUP-DIAGNOSIS.md` §4.1, exact commands); no recreate/resize/prune |
| Checklist partials V18, O04, O09, O12, R01; not started R03–R08 | engineering / owner gates | `CHECKLIST-RECONCILIATION-20261017.md` |

## 5. Deployment-ready vs not

- **Nothing in this series needs deployment.** The only product change
  (`f80dac4` guard) affects migration replay behaviour; the delivered
  Supabase record `20261017113856` already carries the reviewed `73882a6e`
  trigger body per `RENTCAST-FROZEN-PAYER-20261017.md`. Re-applying the
  migration against the live project is not needed and was not done.
- **B lane** (`claude/pipeline-hold-binding-20261017` @ `071e4ed`): proven on
  disposable PG; integration needs the three owner decisions in the repair
  handoff, then CI registration per `CI-INTEGRATION-PROPOSAL.md`, then SQL
  rollout before the worker. Not pushed.
- **o12 decoder dependencies**: no candidate image exists; nothing to deploy.
  The nine FFmpeg 5.1.10 debs can be built offline on an x86_64 host from
  inputs already on the drive (feasibility in the diagnosis §5), but the
  4452-overlay oracles still need the Mac's container runtime.
- **Rendprop 1.0.5 (88)**: already VALID / IN_BETA_TESTING on the internal
  TestFlight group. Not rebuilt, not re-exported, not re-uploaded, not
  submitted.

## 6. Unexecuted, stated plainly

- Hosted proof of `770e7ac` and `5515820` (next run).
- The 26 property-video-renderer harnesses on the hosted runner (local mirror
  only — §3.1).
- Any tour-host suite outside macOS CI.
- The o12 §4.1 read-only extraction and the §4.2 start proof (Mac + external
  drive; owner authorisation for §4.2).
- The three regression runners that need git history (`run_deletion_regression`,
  `run_deletion_handler_regression`, `run_backend_billing_authority`).
- A verified source backup — scheduled for the first coherent green checkpoint
  (Phase 5), not before.
