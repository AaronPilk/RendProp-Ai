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

## Not done / honest limits

- No push happened until every affected proof above was in hand; the new CI
  run is the only hosted proof and its result is reported separately.
- Priority 2 (pipeline hold/cost binding) and Priority 3 (decoder
  dependencies / o12 VM) were not touched: their packets live only on the
  external volume, which this session cannot reach.
- Nothing was deployed, uploaded to Apple, generated with paid providers, or
  changed in production data.
