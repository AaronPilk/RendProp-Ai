# Claude — integration CI repairs on f74e540 (2026-10-17)

Lane: Claude took over from Codex (Codex usage exhausted) at 08:53 EDT with the
takeover brief `CURRENT-CLAUDE-TAKEOVER-20261017.md`. The Mac shell was not
reachable from this session, so the work ran in a cloud worktree on branch
`feature/launch-checklist82-20261014`. Codex's local, unpushed commit
("Repair migration replay guard and preserve current delivery handoff") was
rebuilt in the cloud from the Mac's git object store with the identical tree
(`de562620…`); the cloud commit is `f80dac4` (it differs from the Mac's
`1065075` only because cloud git signs commits).

CI run 39029975919 at f74e540 finished 9 success / 6 failure. The six failures
are the five known items in the brief:

| CI job | Item | State after this lane |
|---|---|---|
| Supabase migrations (fresh replay + invariants) | 1 | fix in f80dac4 (Codex); verification below |
| Disposable PostgreSQL publication/invariant/deletion | 1 | same |
| Supabase edge functions (deno check + tests) | 2 | test-only fixes in f80dac4 (Codex); verification below |
| Studio contracts, build and property workflows | 3 | fixed in `4ea7625` (test-only) |
| Private property video CPU and actual background authority | 5 | fixed in `f135d29` (test-only harness) |
| Cloudflare Worker (tour-host) | 4 | see §4 |

## Item 3 — Studio `make-video-browser.mjs` (`4ea7625`)

Root cause: after returning to actor B while a held source reply for actor A
is released, the test asserted `toHaveCount(0)` on "Current property video".
B's scoped journal still references B's own cancelled job, and the component
correctly recovers it on remount; the assertion only passed when it ran before
that recovery. Local reproduction at f74e540: deterministic failure here
(`Expected: 0, Received: 1`), identical to CI line 7705.

Fix (test only): wait for B's load, then prove the region is B's cancelled job
(`cancelled · 0/1 photos complete`, not A's `1920×1080`), `jobs.length === 2`,
no POST added by switching accounts, exactly one held `/sources` request made
as A, exactly three source requests after the step (A's aborted load never
requests its second page; B loads two pages), and B's selection ("1 selected")
and Social format restored from B's journal. The receipt records the observed
state under `actorSwitch`.

Executed: suite passes (13 checks) — three consecutive runs; the twelve later
suites of the same CI step plus `check-migration-ledger.test.mjs` (4/4) and the
positive cases of the later control loops (consent, listing-selection,
gallery-copy, contact-navigation, listing-facts) all pass locally on this
head. A removed-guard negative control was tried and was NOT decisive (the
fixture's A/B data are too similar and timing varied), so no fault entry was
added; this is stated rather than claimed.

## Item 5 — `native_photo_family_selection_pg.py` (`f135d29`)

Root cause: line 64 froze the entire public function catalog captured right
after `20261016171912_native_photo_family_abandon_cover.sql` and required it
unchanged through all later migrations. Two later migrations legitimately
rewrite unrelated functions behind their own replay guards:
`remove_listing_gallery(...)` in `20261017110321_preserve_gallery_removal_projection_order.sql`
and `stamp_library_financial_liability()` in
`20261017110114_freeze_property_attempt_liability.sql`. None of the nine
native helpers changed (`grep native_gallery_selection` over the three later
migrations: no matches).

Fix (harness only): the end-to-end check now covers exactly the nine
introduced `native_gallery_selection*` signatures (definition + owner + ACL +
security + config), taken from the real catalog diff, with distinct
dropped/changed messages. The immediate full-catalog `preserves()` checks and
the full-catalog replay equality are unchanged. The receipt records
`owned_helper_authority` (signatures, later migrations, non-owned rewrites and
additions).

Executed on a disposable PostgreSQL 16 cluster (as user `claude`, evidence
under `/home/claude/native-pg-evidence/`): unmodified harness reproduces the CI
failure at the same line; repaired harness passes (fresh 44, repeated 44,
followup-fresh 32, followup-repeated 32; owned cluster stopped). Causal
controls with one synthetic 184th migration each: drop a helper → fails
"dropped an owned helper"; rewrite a helper body → fails "changed an owned
helper"; grant execute on a helper → fails "changed an owned helper".

## Item 1 — migration replay guard (Codex, f80dac4): verified

Executed on a disposable PostgreSQL 16.15 cluster as user `claude`, replicating
the `db-migrations` job step by step: bootstrap, all 183 migrations applied
(`LC_ALL=C` order, `ON_ERROR_STOP`), `stamp_library_financial_liability()`
md5 `73882a6e…` on the final schema, video_erase (51) / direct_bria (40) /
legacy_photo_fallback, erase-concurrency (43 checks), all 16 fixtures,
**invariants 270/270**; replay database with the 159 replayable migrations —
the immediate replay of `20261017110114` now exits 0 (CI got 3) with the hash
unchanged, 19 post-replay fixtures pass, **invariants 270/270 again**.
Guard controls on template copies: third application → 0; body changed by one
character → exit 3 "Review changed function…", body left untouched; pre-20261010
body (`8c7925c2…`) → exit 3; function dropped → exit 3 (refused by the
`::regprocedure` cast one line before the guard). The exact
`tools/audit/run_database_regression.py` runner: accepted, 183 applied, 159
replayed, five negative controls exit 3, cluster stopped. Of the 49 runners in
the later "Deletion, adoption, spatial, handler and upload transport
regressions" step, 45 pass here; `run_deletion_regression.py`,
`run_deletion_handler_regression.py` and `run_backend_billing_authority.py`
need git history that a snapshot lacks (CI uses fetch-depth 0) and were not run.

Pre-existing order-dependent gate found in the same step, unrelated to any
repair: `services/supabase/tests/launch_blockers_pg.py:134`
(`mixed-writer-envelope-race`) — exit 1, 1, 0, 1 across four runs. When the
photo writer wins, the losing `app_video_cost_reserve` refuses with
"RP402: Workspace monthly processing budget would be exceeded" (its own
pre-check) rather than the envelope's "RP402: AI usage limit reached", so the
`== 1` count is 0. CI never reached this step on f74e540. See §Flake below.

## Item 2 — edge test fixes (Codex, f80dac4) + one typing correction (`547fb7a`)

Deno 2.9.6 (CI's version) installed here. `property/attempt-receipt.test.ts`
passes (5/5): the 500-vs-200 failures are gone. The committed
`_shared/provider-liability-boundaries.test.ts` **failed CI's invocation at
type-check**: under `--node-modules-dir=auto` the npm imports pull @types/node,
whose last `setTimeout` overload makes `Parameters<typeof setTimeout>[0]`
resolve to `(args: void) => void`, so spreading `unknown[]` is TS2345 — the
job would have gone red before running a single test. One-token change on
line 71 (`handler:(...a:unknown[])=>void`) — no runtime behaviour change, no
assertion change. With it: both files 16/16 under type-check, and the whole
suite with CI's exact `deno test --allow-all --node-modules-dir=auto .` is
recorded in `edge-full-suite.log` (expected `2820 passed | 0 failed | 1 ignored`;
the verifier saw exactly that on a scratch copy with the same change).

## Item 4 — tour-host export-resume (no change; runner media stall)

The "Cloudflare Worker (tour-host)" job (`worker-edge`) also runs the Studio
media-export suite on macOS with Google Chrome for Testing. The red step is
`apps/studio/tests/export-resume-browser.mjs:276`, variant `cadence-baseline`,
`narrated=false` (8th attempt): expected `"done"`, received the product's
`refuseStall()` message "Original audio playback stalled during export…".

Smallest next proof, executed: the retained artifact
`studio-macos-media-export-1` was downloaded once and
`rendprop-export-resume-ipxrWT/receipt.json` inspected (copy in the evidence
folder). Of the eight attempts, only the failing one carries a `media.waiting`
event (at 9109.5 ms, sourceTime 1.366 s, immediately followed by
`media.playing`), and its two `original.audio.loss` readings are 0.487 s and
0.491 s against the 2/30 s limit, i.e. the 2× video genuinely lost ≈0.49 s of
media time on the runner. The seven passing attempts show no `media.waiting`
and losses ≤ 0.018 s; the same compiled cadence-baseline build passed
`narrated=true` seconds earlier. Classification: environmental runner playback
stall surfaced by a deliberately broken historical control before its own
oracle; the stall guard behaved exactly as designed, and the current exporter
variants (`fixed`, `late-frames`) were never reached. No product change,
threshold change or waiver is justified; the suite is left untouched and the
job is re-observed on the next run.

This suite cannot run in the Linux container (the open-source Chromium there
lacks H.264/AAC MediaRecorder and decode; a launch attempt also crashed with
SIGTRAP), so the next hosted run is the only proof. A test-only, evidence-gated
single retry for the two stall-guarded historical controls was drafted and
`git apply --check`s cleanly but is NOT applied
(`tour-host/PROPOSED-NOT-APPLIED-export-resume-control-refusal.diff` in the
evidence folder); apply it only if the owner prefers that over re-running.

## Flake — `launch_blockers_pg.py` mixed-writer race (`14f1a75`, test-only)

Diagnosis with SQL evidence: `library_serving_envelope_admit`
(`20261009192550_team_private_listing_libraries.sql:902-939`) raises
"RP402: AI usage limit reached"; `app_video_cost_reserve` (`:1099-1168`)
takes the same `org_month_spend` lock, then runs its deliberately retained
legacy COGS pre-check (`:1157-1160`, "RP402: Workspace monthly processing
budget would be exceeded"; `launch_round2.sql:211` "legacy entitlement check
stays; the envelope is admitted after it") before calling the envelope.
Whichever writer wins the lock, the loser inserts nothing (single-statement
transaction), exactly one reservation row remains and spent-after is 2027 ≤
2032 in every run — the money invariant holds; only the loser's text depends
on ordering. Clients map both to a 402 (`funded-serving.ts`, `http.ts`
`throwRpc`, `APIClient.swift` `isQuota`); the differing copy is a pre-existing
UX inconsistency, noted, not patched.

Harness change: accept exactly one of the two legitimate RP402 refusals, keep
the `[0, 3]` exit assertion, add the post-race state check (winner's hold is
the only row, spent-after exactly 2027 ≤ 2032), record winner/refusal in the
receipt. Executed as `claude`: unmodified harness 0,1,1,1,1,0; repaired 8/8
covering both orderings; controls fail as intended — ceiling that never binds
(both admitted → `[0,0]`), loser with an unknown RP402 text (5/5 fail), and a
dangling hold (`['1','1','2033']`).

Latent, not changed: the video pre-check counts the calendar month while the
envelope counts the Apple term; the fixture ledger row is `now() - 1 day`, so
on the first day of a month the pre-check would read 0 and admit the video
loser. Fixture tweak for the file's owner, not done here to keep the diff
narrow.

## Push and observation

Pushed as `feature/launch-checklist82-20261014` (see the commit list at the
top of this file). The Mac worktree holds the same first repair as local
commit `1065075` (identical tree); after the push it will show as diverged by
one commit with the same content. To align it without losing anything:

```
cd "/Users/pilksclaes/Rendprop AI/Rendprop Workspace/Worktrees/Active/build82-launch-checklist"
git fetch origin
git status   # expect: clean apart from the three intentional node_modules symlinks
git reset --hard origin/feature/launch-checklist82-20261014
```

## Run 39040282783 at `7130625` (all repairs + the owner's recovered Codex commits)

Observed to completion before any further push. Result: **14 green, 2 red** (audit-evidence gate and "All native audit
gates required" both success; run conclusion failure).

| Job | Result |
|---|---|
| Supabase migrations (fresh replay + invariants) | success (item 1 closed on the hosted runner) |
| Disposable PostgreSQL publication, invariant and deletion regression | success (item 1; includes the repaired `launch_blockers_pg.py` race, both orderings) |
| Supabase edge functions (deno check + tests) | success (item 2 closed) |
| Studio contracts, build and property workflows (offline) | success (item 3 closed) |
| UIKit exports, paid reel, reel-style, python workers, upload-gateway, secret scan, web parity, iOS static | success |
| Private property video CPU and actual background authority | **failure** — the `native_photo_family_selection_pg.py` repair (item 5) passed; the job then failed at Codex's new RentCast billing-binding step (`rentcast_billing_binding.fixture.ts` lines 43/73, TS2322 `Timeout` not assignable to `number` under Deno 2.9.6 with `--node-modules-dir=auto`). Fixed in `770e7ac` (`ReturnType<typeof setTimeout>`, two declarations, no behaviour change); the harness passes locally as `claude` (`/home/claude/rentcast-evidence/run1/receipt.json`). Hosted proof: next run. |
| Cloudflare Worker (tour-host) | **failure** — the previous export-resume stall (item 4) did NOT repeat: `export-resume-browser.mjs` passed including the current `fixed` and `late-frames` variants. The red step moved to `finishing-browser.mjs:118`: the product's `RecordingClock` refused with "Audio and picture timing drifted during export". See the analysis below. |

### Finishing refusal — analysis of the retained evidence (no change applied)

Full write-up: `FINISHING-TIMING-DRIFT-ANALYSIS.md` in the evidence folder
(246 lines, read-only; sources verified against the run's recorded
`sourceHashes`). Verdict: **environmental runner audio-sink stall**, not a
product defect and not the 8328dce origin change.

- All eight readings have `wall === timeline`, so the refusal happened in the
  photo segment whose timeline is the wall clock; the audio reading is
  `AudioContext.currentTime − segmentAudioStart`.
- The audio clock tracked wall within 1–5 ms until page time 8516 ms, then
  froze at exactly 5.738667 s absolute = 538 × 512 frames (an output-buffer
  boundary, not a graph boundary — narration, music and the original clip all
  start/end elsewhere) for ≥ 168 ms across five main-thread readings. The guard
  tolerated 0.041/0.050 and threw at 0.137/0.174.
- `outputTimestamp` froze at `performanceTime` 8554.6 with `contextTime`
  537 × 512 frames; the context closed at 8732.4 with no later sink callback.
  Main-thread read gaps were also late (36–88 ms vs ≤ 33 nominal): a CPU burst
  on the 3-vCPU arm64 runner.
- Origin change refuted: the three readings before the stall show 2.4/1.1/3.1 ms
  drift, not a constant offset.
- Had the guard not fired, the AAC track would have been ≈ 0.17 s short and the
  suite's own `avDurationGap ≤ 2/30` oracle (line 126) would have failed —
  the Build 60 failure mode the guard was written for.
- The passing `export-resume` receipt from the same run (36 s of readings) has
  max |wall − audio| 6.7 ms and no plateau ≥ 33 ms. The previous run's
  guard-isolated historical variant recorded the same frozen-`outputTimestamp`
  signature. Six of the last seven hosted tour-host runs hit a media/audio
  stall somewhere; none reproduced locally; only fecbfa0 (run 39022740808) was
  16/16 with editor source identical to HEAD.

Options, none of which weaken thresholds or skip controls: (i) re-observe
as-is and record a pass as "stall did not recur", not a repair; (ii) a
test-only, evidence-gated single retry in `finishing-browser.mjs` keyed on the
three-part stall signature (audio identical across ≥ 3 readings while wall
advances ≥ 2/30, `outputTimestamp.performanceTime` ≥ 100 ms older than the
refusal, first refusal kept in the receipt, every oracle unchanged on the
retry) — the owner declined the equivalent for item 4, so it is not applied;
(iii) a product pause-on-stall — rejected: it re-bases the origins the export
invariant forbids re-basing and changes what the 2/30 guard measures;
(iv) recommended instrumentation first: attach the existing CDP webaudio trace
observer (`export-startup-browser.mjs:21-134`) to the finishing export and
record the longest gap between `AudioDestination::RequestRender` spans, log
the runner's audio device and `hw.ncpu`, and record inter-read and
output-latency per reading in the finishing receipt. (iv) is test-only
instrumentation and can be done in this lane; it does not change the oracle.

Unknowns stated plainly: why the sink stalled (real device vs Chromium fake
sink, audio-service starvation); whether a user Mac can show it; the 500 ms
`dataavailable` slice near page time 8550 is a coincidence that was not ruled
out.

### CPU/background job — the steps CI has never reached on this branch

The RentCast step (added in f74e540) sits before 26 further harness steps in
`property-video-renderer` (ci.yml 1852–2030); no run on this branch has
executed them since the step was added. Rather than let the next push move the
red one step down, all 27 were mirrored locally as user `claude` on disposable
PostgreSQL 16.15 on this head (`/home/claude/cpu-tail-evidence/SUMMARY.txt`,
one evidence dir + log per harness). Result (15:04Z): **26 of 27 pass on first run**; the one failure,
`property_video_kie_scope_consent_pg.py` (exit 1 at line 90), is repaired
below. `api_cost_report_pg.py` ran at the end of the mirror with the repair
in place and passed; its unrepaired failure is the B-lane base control.

One pre-existing red found and repaired (`5515820`, harness only):
`tools/audit/api_cost_report_pg.py` seeded the RentCast *hit* by finishing the
attempt and then inserting its ledger row; the liability freeze
`20261017110114` (f74e540) refuses "RP409: Terminal provider attempt cannot
add a cost". The property handler (`functions/property/index.ts`, same commit)
writes the ledger row first, then finishes the attempt — the seed now follows
the product's order. Unmodified harness: fails at seed on `7130625` (B-lane
base control, identical file bytes); repaired: 25/25 assertions including
"priced hit links to its retained ledger row and supplier request id"
(`/home/claude/api-cost-evidence/repaired-run1/receipt.json`). No oracle
changed.

Second pre-existing red found and repaired (`57633d4`, harness only):
`services/supabase/tests/property_video_kie_scope_consent_pg.py:90` pinned
`len(MIGS) == 181` (from b84455d, 2026-10-16); the two later migrations in
f74e540/f80dac4 made it refuse before applying anything. The harness now
applies every current migration with 181 kept as a floor and records the
count; no oracle, control or regression changed. Repaired run as `claude`:
183 applied, 20/20 checks, v1/steady/jobs regressions, 36 closed handler
tests (`/home/claude/kie-scope-evidence/repaired-run1/receipt.json`). No other
Python harness pins a migration count (grep over `services/supabase/tests`
and `tools/audit`).

## B lane — pipeline hold/cost binding (Priority 2): proven, not integrated

Branch `claude/pipeline-hold-binding-20261017` (worktree
`/home/claude/rendprop-b-lane`), HEAD `071e4ed` = `7130625` + the sealed
`PARTIAL-CANDIDATE.patch` (fdff8fe9, WIP `f3d8c19`) + three commits:
`d40ceff` migration own-replay guard (own functions pinned by md5, owner,
language, volatility, security, search_path, ACL; relation pinned by column
list, constraints, indexes, RLS, ACL), `ad5fe4d` 18 cases + full-chronology
driver (predecessors → seeded ledger/hold history → first apply → immediate
replay no-op → 9 refused controls with catalog/history unchanged after each →
remaining migrations → cases → omission witness `8.0 != 4`), `071e4ed` driver
evidence size. Not pushed; `ci.yml` untouched; nothing deployed. Full report:
`/home/claude/b-lane-evidence/B-LANE-REPORT.md`; CI registration proposal
(one step before the `api_cost_report_pg` step, one line each in the api-cost
unittest step and the python-worker list): `CI-INTEGRATION-PROPOSAL.md`.

Executed: driver `{"passed": true, "caseCount": 18, "currentMigrationCount":
184}`; python suites 23 + 5 + 11 + 2 + 37 + 12 + 37 OK; exact mirror of the
`db-migrations` job with the new migration (270/270 invariants fresh and
replay, immediate double-apply no-op); `run_database_regression.py` PASS
(184 applied, 160 replayed, negative controls detected).

Owner / root decisions before integration (not routine, so not taken here):

1. With a binding present the ceiling counts the larger of the admitted bound
   and the modeled ledger cost **even for succeeded attempts** (the old settle
   trigger released the whole hold after success). Direction is conservative —
   less headroom, never a double charge; for `fal-ai/flux-pro/kontext` bound ==
   modeled so nothing changes; a Gemini image attempt keeps its ≈31.1¢ quote
   reserved instead of dropping to the modeled estimate after success. Accept
   as designed (the candidate's own comment states this intent) or narrow to
   uncertain/reserved attempts.
2. A multi-attempt `produce()` (two paid calls behind one result) stays
   unbound, so the old inflation persists there by design ("ambiguous
   aggregates").
3. Rollout order: SQL first. A new worker without the RPC would spool every
   pipeline ledger write (degraded, not lossy).

## Not done / honest limits

- No push happened until every affected proof above was in hand; the new CI
  run is the only hosted proof and its result is reported separately.
- Priority 2 (pipeline hold/cost binding) and Priority 3 (decoder
  dependencies / o12 VM) were not touched: their packets live only on the
  external volume, which this session cannot reach.
- Nothing was deployed, uploaded to Apple, generated with paid providers, or
  changed in production data.

## Run 39055656587 at `b57ba713` — final (completed 2026-10-17 19:21Z)

| Result | Jobs |
|---|---|
| success (14) | Offline audit evidence (105/105 steps, incl. `run-property-video-planner.py`: V3 fallback rotation compiled with `xcrun swiftc` on the macOS runner, 9 compiled negative controls), All native audit gates, UIKit photo exports, Paid reel recovery, Private property video CPU + background authority (all 27 renderer harnesses), Python workers, Supabase migrations, Supabase edge functions, Studio contracts, Web parity, Reel-style preservation, upload-gateway, iOS static, secret scan; dependency security run 39055653756 |
| failure (2) | Disposable PostgreSQL (job 117462974108): `run_listing_measurement_cas.py` expected the old first refusal; the pipeline cost binding legitimately moved it to line 1022 (`serving_ceiling_spent_cents`) — fixed in `f8b06420`, all later harnesses of that step pass locally. Tour-host (job 117462973869): cloud-editor agent export refused by the product RecordingClock guard after the audio render thread stopped ≥127 ms on a 3-vCPU, load-7.8 runner; unresolved hosted-runner reliability issue, instrumented in `102219ca` + `ee39ca95` (see `CLAUDE-INTEGRATED-AUDIT-20261017.md` §7.1) |

Next run: 39062185061 at `317b6a1e` (adds web1, E3/E7/E8 with renamed migrations, the harness fix, the instrumentation, proven rollbacks).
