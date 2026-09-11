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

## Remaining work — do not erase these from the handoff

- Diagnose and improve real-room reconstruction quality with measured evidence;
  do not claim the current blurred model is an acceptable market-ready tour.
- Finish separate spatial same-asset renewal and multipart Pause regression.
  General recovery peer review found Pause cancels dispatched parts, and
  expired v2 foreground photo journals lack an explicit restart UI. No silent
  reallocation is an acceptable substitute for user-confirmed recovery.
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
