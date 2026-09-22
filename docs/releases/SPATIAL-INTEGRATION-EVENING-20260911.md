# Spatial delivery — independently verified evening checkpoint

September 11, 2026. Integration branch `feat/spatial-release-integration-20260911`.
Read this before older STATUS entries. **Not a whole-app GO or a new phone build.**

## Actual outcomes

1. **Live upload/publication proof passed.** Three synthetic files traversed
   Supabase35 → upload gateway → R2 → complete. Native Foundation replay also
   passed. Three tickets, 5,711 write-budget bytes spent, zero held; publication
   replay yielded one job/render. Both hosted variants returned200. See
   [the complete proof and receipts](LIVE-UPLOAD-PROOF-20260911.md).
2. **The owner's real153-frame room trained.** The new allocation succeeded,
   so the old billing-limit termination is not a current allocation refusal.
   Retrieved PLY and20 held-out renders; GPU-side room removal and termination
   were confirmed. This did not enable the production queue.
3. **Visual quality is not acceptable yet.** The retrieved room renders with
   substantial blur/smearing. A successful trainer exit is not product success.
   No new capture, provider allocation or automatic paid retry is implied.
4. **A disabled cloud worker is deployed and its actual remote entry passed.**
   Source guard false, no schedule, no secrets, no GPU configured on controller.
   It cannot consume production jobs. The real-room experiment was separate.
5. **Deletion and upload recovery fixes are integrated and locally tested.**
   The paired0039 handler/migration and0041 provider journal are NOT deployed by
   this work. New same-ticket renewal is NOT yet in live uploads35. Do not ship
   the corresponding client before its handler.
6. **No Apple operation occurred.** This work does not change the pending
   submission, build attachment, TestFlight availability or installed phone app.

## Real-room evidence and quality result

Private experiment source: `88066a3887852d3d6e4c021ac901783cea05d133`, clean before
allocation. Sandbox `sb-2fqSw5zWu2dFlWhRAsmq2z`, under the existing single-room
USD25 total authority. One L4, bounded CPU/memory, hard7200s TTL. No secrets,
ports or volumes in GPU sandbox; network denied before capture transfer.

The previousUSD1.09974939 receipt remains counted. This attempt's full-lifetime
compute bound wasUSD4.9110336, cumulative boundUSD6.01078299. Those are ceilings,
not invoices. The first incomplete-hour usage readback wasUSD0.57381695 for this
new interval; final billing remains a separate readback, not a timer estimate.

- Allocation accepted21:12:48.138521UTC; public dependency setup exit0.
- Network denied21:21:25.139223UTC, then157 dataset files transferred.
- Input153 frames /9,226 seeds. Actual3000-step trainer exit0, elapsed209.441s.
- Output29,733 Gaussians; PLY7,018,464bytes. The500,000 value was a ceiling,
  **not a target reached by training**.
- Held-out metrics: PSNR19.6598568, SSIM0.81097144, LPIPS0.55676222.
- Root visually inspected held-out0000 and0010: the source photograph is
  substantially sharper than the predicted render. Blur is already present
  before SOG conversion. Do not blame phone rendering or compression alone.
- Explicit remote room-directory removal succeeded; terminate/wait and final
  poll returned137 at21:26:53.721114UTC after successful trainer exit0. Here137
  is the intentionally stopped sandbox, **not** failed training. Readback at
  21:27:53UTC found zero active sandboxes in this experiment app.

Private artifacts, not in Git:

`/Users/pilksclaes/LocalSpatialExperiments/modal-room-20260911-01/`

PLY: `download/result/ply/point_cloud_2999.ply`; held-out images under
`download/result/renders/`; actual dependencies in`download/resolved-setup.txt`.
Source capture and original failed-run receipts remain preserved.

Pinned SplatTransform3.4.2 CPU conversion of this PLY completed in53.704s:
`room.sog`,776,804bytes, SHA256
`031cb387a94818349b7998eec77345ad4f68016b4b46c4942ec6e496f24220ee`.
This conversion incurred no new GPU allocation.

## Actual browser verification

The browser CLI named by the verification skill was unavailable. Used the
connected Chromium browser instead; no browser impersonation or synthetic room
substitution. Generic spike viewer decoded all29,733 splats with no captured
warning/error console entries. Its fit-to-whole-AABB starting view put the
small room far away, so that generic framing is not an in-room acceptance test.

Added local-only acceptance tooling:

- `tools/audit/prepare_room_preview.py` reuses the production
  `navigation_manifest` and real capture adapter, computes exact SOG bytes/hash,
  and writes only a new private manifest outside Git.
- `tools/audit/preview_spatial_room.ts` reuses production `spatialPage`,
  `spatialModule`, decoder and SOG guard. It listens on127.0.0.1 only; no public
  host, room upload, service credentials or database state. Its two fixture
  substitutions are a local-only page credential and the same SRI-verified
  PlayCanvas2.22.1 engine served locally instead of CDN. The viewer itself is
  unchanged. This server must never be deployed as production authorization.

Real production viewer on that fixture passed size/digest/SOG checks and showed
the room from the capture-derived starting position. Its actual canvas-draw
gate changed status to "Private preview — not published." Forward controls
and drag were exercised and the rendered viewpoint changed. Top-down toggled
visibly and rendered the room structure from above. Images remained visibly
blurry/smeared. No physical-phone performance or real backend viewer auth test
is claimed by this local fixture. Privacy review remains false.

Starting-view reset visibly cleared top-down mode; Close removed the viewer
and displayed its closed state. No captured warning/error console entries
appeared during the walkthrough. Both temporary loopback servers were stopped
after testing; room files were retained privately. A wrong-model negative
control failed before listening, and three HTTP checks verified401 without
the local capability,403 for another Origin and405 for POST. Explicit Python
guards also remain active under optimized Python; no `assert`-only cap is used
by the preview preparation tool.

The independent, source-and-data-bound quality review is
[`ROOM-QUALITY-DIAGNOSIS-2026-09-11.md`](../audits/2026-09-10/ROOM-QUALITY-DIAGNOSIS-2026-09-11.md).
It verifies all153 pose inversions and all20 original image halves, records
growth/seed/motion evidence, and qualifies the metrics: validation images were
excluded from training loss, but some initialization colors came from them.
These are loss-held-out metrics, not a fully image-disjoint benchmark.

## Cloud deployment: failures retained, then remote proof

Pinned Modal1.5.3, profile`rendprop-room-experiment`, environment`main`.
All attempts read standing brief sections1/2, checked added symbols and ran
worker tests before deployment. No production key was attached.

1. Initial explicit`ephemeral_disk=8192` failed provider validation, exit1.
   Minimum configurable value is524288MiB. Fixed by removing the override,
   **not** requesting512GiB and its associated resource reservation. App
   `ap-LvGo1dmshLq7IWHNS3OlGK` read back stopped/tasks0.
2. Next deploy exited0, but the real remote invocation failed importing
   `/root/app.py`: `parents[2]` assumed the local repository layout. This is a
   real failure missed by mocked local tests. Stopped only this disabled CPU
   app`ap-dtIZuIP8rr7jbw3BekY0Dt`; readback confirmed stopped/tasks0.
3. Commit`22ad794` includes explicit remote`/workspace` layout and avoids
   rebuilding local file mounts during container import. A regression executes
   the module with`__file__=/root/app.py`;40 worker tests passed. Deploy exit0,
   tag22ad794, app`ap-3wHUEY2SsmWC9wsyqhfJ6e` at21:25:34UTC.
4. Actual remote`process_next` invocation
   `fc-01M295TRMGEMFVY2WNYNTH84X8` returned exactly`{"status":"disabled"}`,
   asserted with45-second result timeout. Exit0. A CLI deployment success alone
   was not accepted as proof. Two local probe-launch errors (missing assumed
   Python path; default Python3.9 incompatible with Modal) occurred before this
   successful invocation and allocated no room GPU.

Command:

```sh
MODAL_PROFILE=rendprop-room-experiment uv tool run --from modal==1.5.3 \
  modal deploy --tag 22ad794 services/spatial-worker/app.py
```

Later integration changes are not automatically part of this deployed tag.
The enabled scheduler, real queue polling and queued-job end-to-end processing
have not been activated or proven.

**Final disabled deployment supersedes tag22ad794:** clean source
`2063d1ce1978b0984b557f0274739e1388dc6f9c`, tag2063d1c, deployment command exit0
after41 worker tests. App remains`ap-3wHUEY2SsmWC9wsyqhfJ6e`. Real remote call
`fc-01M296VCPS4NHJXT2RNHVE6PC6` returned exactly`{"status":"disabled"}`,
asserted/exit0. This version includes the no-allocation receipt fix.
The worker's explicit source-inventory fingerprint is
`b53de07d41f00c0f2e1b2c5bd6a31ad59ab12e297815397602e5cfc5553e36fc`.
Subsequent documentation-only changes do not alter those uploaded sources.

## Root's combined test runs

From the integration worktree, not merely another agent's assertion:

| Command | Actual result | Receipt |
| --- | --- | --- |
| `python3 tools/audit/run_deletion_regression.py --provider-commit 88066a3887852d3d6e4c021ac901783cea05d133` | exit0;62 SQL assertions, replay/restored green, old behavior and two mutants rejected,6 lock races | `/tmp/rendprop-deletion-db-rsrlyf9c/receipt.json` |
| `python3 tools/audit/run_deletion_handler_regression.py` | exit0;41 actual handler/logic tests; stale handler rejected | `/tmp/rendprop-deletion-handler-sif7188b/receipt.json` |
| `python3 tools/audit/run_upload_recovery.py` | exit0;46 native assertions,5 compiled mutants rejected, restored green | `/tmp/rendprop-upload-recovery-lnx27hho/receipt.json` |
| `deno test` on uploads renewal/transport/publication/completion-race fixtures |51 passed,0 failed | command output this run |
| pinned Python worker unittest discovery at22ad794 |40 passed | command output this run |
| viewer`npm ci --ignore-scripts --no-audit --no-fund` and`npm test` | exit0;21 passed,0 skipped | command output this run |
| `deno check --unstable-sloppy-imports tools/audit/preview_spatial_room.ts` | exit0 | command output this run |

DB tests used owned socket-only PostgreSQL17 clusters, stopped afterward. No
production account deletion, customer-ticket cancellation or bulk abort ran.
The agent's full generic iOS simulator build of`ebdeb53` passed; it is compile
evidence, not a new archive, UI walk or iPhone background-handover test.

### Additional integrated checks after provider/spatial-renewal changes

- 41 worker unit tests and26 spatial Edge tests passed with network denied.
- Provider0041:23 SQL assertions, replay/restored and dispatch mutant checks;
  `/tmp/rendprop-provider-db-0x62ynii/receipt.json`, accepted/cluster_stopped true.
- Deletion0039 rerun paired with exact provider commit
  `98ee202d2a63cef31899e41d2213f36881b7199f`:62 assertions and6 lock races passed;
  `/tmp/rendprop-deletion-db-00laxkga/receipt.json`. An earlier launch with an
  abbreviated commit was correctly refused before any DB started.
- Spatial0040:69 assertions and3 observed lock races passed; its own suite
  tests0040 in isolation from0041. Receipt
  `/tmp/rendprop-spatial-db-qrkbzyqn/receipt.json`; owned cluster stopped.
- Spatial client:75 native assertions and6 compiled mutants passed/rejected as
  intended; `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-client-tcibj_66/receipt.json`.
- The old Edge regression wrapper expected25 tests and failed when the new
  provider-journal test raised that to26. Fixed its exact count and zero-ignore
  parsing; rerun passed26 with its copied-source digest-check mutant rejected.
  `/tmp/rendprop-spatial-edge-27b54nxi/receipt.json`. Network/run/write are denied.

Pre-provider download/validation failure now journals `not_created` atomically
without granting dispatch or overwriting an older ambiguous allocation. That
source fix and spatial same-asset renewal are integrated. These later changes
are covered by the final2063d1c disabled cloud receipt above, not the earlier
22ad794 receipt. The Supabase0039/0041/handler rollout remains separate.

### Final iOS combination

- Actual general uploader harness: **69 assertions,7 compiled mutants caught**,
  restore green; `/tmp/rendprop-upload-recovery-l6lfdwti/receipt.json`,17 commands.
- Spatial native harness: **75 assertions,6 compiled mutants caught**, restore
  green; `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-spatial-client-g_yv1yeq/receipt.json`,15 commands.
- These receipts both assert`accepted:true`. The actual multipart manager is
  now instantiated and its four-part Pause→settle→Resume behavior exercised,
  not merely compiled or decoded as a state model.
- Full generic simulator build on agent commit
  `00ede93e63448b8b83433b7a4c5406d25f9a9b77` exited0; root read the completed
  log`/tmp/rendprop-upload-rollout-spatial-pause-final-20260911.log` and verified
  **zero diff for all `apps/ios` against that commit** after integration.
  This establishes identical built app source; it is not another full UI walk.
- Detailed source/tests/remaining caller gaps:
  [`UPLOAD-PAUSE-RELIABILITY.md`](../audits/2026-09-11/UPLOAD-PAUSE-RELIABILITY.md)
  and[`SPATIAL-UPLOAD-RENEWAL.md`](../audits/2026-09-11/SPATIAL-UPLOAD-RENEWAL.md).

### Plain-language delivery status for Claude

| Item | State |
| --- | --- |
| Controlled live v2 transfer/complete/publication | PASS, three synthetic fixtures; no customer tickets touched |
| Outstanding ticket recovery | PARTIAL: same-ticket/legacy/general Pause fixed in source; expired-photo Restart and spatial Cancel→Resume still open |
| Bounded Modal worker | DEPLOYED DISABLED; actual cloud entry passes; no schedule/service secret/production queue activation |
| Old Modal billing refusal | NOT CURRENT: fresh allocation and training completed; no account limit change |
| Owner's room | TRAINED and browser-rendered; **visual acceptance FAILED** because of blur/smearing |
| Spatial/account deletion | Known transactional/spatial omissions fixed and tested in source; paired deployment and historical cleanup still pending |
| Production generation budget | OFF; activation still requires explicit owner approval |
| TestFlight/App Review | UNCHANGED by this work |

All application fixes and this context are pushed on
`feat/spatial-release-integration-20260911`; no merge/force-push to shared main
or release branches. No room imagery, model or credentials were committed.

## Remaining work — do not erase these from the handoff

- Diagnose and improve real-room reconstruction quality with measured evidence;
  do not claim the current blurred model is an acceptable market-ready tour.
- Spatial same-asset renewal and general multipart Pause are now implemented
  and tested. General Pause stops scheduling while dispatched parts settle;
  the full simulator build passed. Distribution remains outstanding.
  Expired v2 foreground photo journals still lack an explicit restart UI, and
  several photo callers discard their errors with `try?`. Separately, spatial
  cloud-job Cancel still cancels frame transfers: Cancel→Resume during an
  uncertain write is not proven recoverable. No silent reallocation is an
  acceptable substitute for user-confirmed recovery.
- Deploy paired0039/me and0041/spatial with a coordinated old-handler/sweep
  drain. Applying0039 alone changes write grants and breaks the old handler.
  Existing ambiguous old worker/multipart identities can require assisted
  cleanup; do not erase them to produce`cleanup_complete:true`.
- Durable provider intent/identity/cleanup is implemented; crash/orphan cleanup
  and no-allocation early failures still need complete operational coverage.
- Deploy same-ticket`/uploads/:id/renew` before its client; test real device
  relaunch, background completion, cellular/Wi-Fi handover and partial progress.
- Privacy region processing remains incomplete. Whole-room exclusion/review
  does not prove requested region blurs were rendered into a derived artifact.
- Activate production scheduler, credentials and budgets only with explicit
  owner approval after real-room acceptance and deployment readiness.
- Full frozen-source UI walks, source-bound internal TestFlight delivery and
  on-phone acceptance remain. Leave pending App Review unchanged.
- Historical header at`bcba804:docs/handoff/launch-P2.md:518` is a literal
  five-byte placeholder, not a JWT; bounded surrounding scan found no JWT.
  No token value was printed or used. This does not certify unrelated key
  rotation. Agent-reel token-headroom decision remains with owner.
