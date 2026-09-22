# Phone readiness — September 11, 2026

Fresh check: 14:24 UTC / 10:24 AM Eastern. This is a status receipt, not a
deployment, whole-app pass, or a claim that work continued unattended overnight.

## What the owner can actually use

The latest **recorded** installed TestFlight source is 1.0(18), `ed0131b`.
The owner confirmed room capture/export works on iPhone 15 Pro. That build does
not reconstruct the capture or expose a navigable model. No new phone binary
was built or uploaded in this block. Apple state has not been freshly queried.

The requested real-room browser walkthrough is **not ready**. There is no
collected PLY, SOG, held-out render, or phone performance receipt from the GPU
attempt. A synthetic viewer fixture is not a substitute for the owner's room.
The closest next spatial acceptance is a private real-room browser walkthrough;
hosted reconstruction/queue, app delivery, review and publishing remain separate
product work, not features proved by that experiment.

## Actual GPU outcome

Source `add556eb62dbe5ec138392096c08f6c116519d2c`, dedicated Modal experiment,
third allocated host. Command from this branch:

```sh
/Users/pilksclaes/.local/bin/uv tool run --from modal==1.5.3 python \
  tools/spatial-spike/training/modal_room.py run \
  --dataset /Users/pilksclaes/LocalSpatialExperiments/capture-handoff.sXFKTV/dataset \
  --state /Users/pilksclaes/LocalSpatialExperiments/modal-room-20260910-04
```

The original terminal session is no longer available; its shell exit code was
not recovered. The durable receipt records **outcome failed**, `ValueError`:

- Allocated 01:48:06 UTC; setup and network-policy changes completed.
- All 260 approved adapter files transferred. No other media transfer is claimed.
- Wrapper dispatch recorded `training_started` at 01:59:07; that event does
  **not** prove optimizer steps ran. The local wrapper log is zero bytes.
- Failure at 02:03:04, termination at 02:03:06. About 15 minutes allocated.
- Exact remote-path deletion returned `SandboxFilesystemError`, **not success**.
  `Sandbox.terminate(wait=True)` returned 137 and separate `poll()` returned 137.
  Explicit file deletion therefore remains unconfirmed, distinct from container
  termination; do not rewrite this as successful remote-path cleanup.
- A fresh exact-application provider query at 14:24:02 UTC returned **zero active
  sandboxes** and **USD 1.09974939** cumulative provider-reported usage for the
  01:00–04:00 UTC experiment interval. This is actual metering, not a resource-rate
  estimate or a finalized invoice. The USD 25 total approval remains the ceiling.

**Terminal cause confirmed at 14:27:38 UTC:** a read-only lookup/poll of this
exact Sandbox returned exit137 and the provider terminal result:
`Container terminated due to reaching billing cycle spend limit`.
The root independently reproduced this result with Modal SDK1.5.3 after the
investigating agent. This is the account's billing-cycle limit, not the USD25
experiment ceiling (reported experiment usage is aboutUSD1.10). No account limit
was changed. Do not label this as a camera, dataset, OOM or trainer defect.

The runner obscured that cause by recording only `ValueError`, not the numeric
stage exit or provider terminal reason; failed diagnostic-copy exceptions are
also discarded. Repair that evidence path before another attempt. Resolving an
account-wide billing setting needs owner direction; blindly retrying will not
produce a phone-testable room.

Private evidence: `LocalSpatialExperiments/modal-room-20260910-04/` contains
`provider-receipt.json`, `setup.log`, and empty `wrapper.log`. No `download/`
or failed-diagnostic artifacts were found. No new allocation was started during
this status check.

## Tested source is not the installed app

Fresh `git ls-remote` confirmed all these exact heads on their own branches:

| Unit | Remote commit | What is proved / remaining |
|---|---|---|
| Upload transport | `b8162c62491ec699d5dd5353da4596bc29c05c7d` | Report records 647 overlapping Edge tests, 6 native Worker/R2 scenarios and 20 local PostgreSQL cases; no production gateway rollout or real-phone upload proof |
| Adoption receipt/recovery | `16a04cece7a97980bd8bacddb4a8ec7170eb522c` | Durable source/destination recovery and server receipt tests; must ship with local-binding follow-up |
| Adoption local bindings | `8429ee073044b0915ab331692b7b38bb6cdb432d` | Local ID restoration and unreadable-library protection; 65 recovery and 73 model/storage assertions, copied-source negative controls; no whole-app/device run |
| RenderEngine | `c44f3f18c3ec4c5d6983257ab944ad60359d511b` | Four baseline concurrency diagnostics reproduced and repaired; actual synthetic AV encode/cancel checks; no full iOS build or phone/HDR quality verdict |
| Privacy disclosures | `a2d89350f179ba4382c723f09dda3ef6ca0e7c0c` | Actual generated-page tests and responsive browser checks; source not published, legal/owner approval remains |
| AI measurement/fixtures | `d997dc440ef0155859922241b9a300e51d226a0e` | Model-output shape measured offline and two synthetic fixtures clarified; owner budget/contract choice still pending |

These branches have not been combined into a tested release build. The deletion
transaction unit remains **uncommitted work in progress** in
`deletion-intent-20260911`; its expanded SQL fixture had an ambiguous-column
harness failure. Do not label that unit complete from the earlier smaller pass.

The latest completed integrated CI record remains 7 passing / 3 failing jobs.
The two AI headroom jobs and historical scanner finding are not made green by
these branch-level tests. The historical credential value is not in this report.

## Next delivery boundary

1. Diagnose the failed GPU orchestration and preserve failure/cleanup evidence.
   Do not claim image quality, a model, or a phone walk from a dispatch event.
2. Complete the bounded real-room proof and private browser test if a justified
   correction stays within the existing experiment authority; do not launch
   another allocation automatically or tune a completed bad reconstruction.
3. Integrate the tested source units and run an actual full app build and
   non-camera UI walk before representing a new native build as testable.
4. A new internal TestFlight upload needs explicit direction superseding this
   block's **no Apple action** instruction. Leave the App Review submission
   untouched. No production deployment is authorized by this status question.

Phone-only HDR, accessibility, real persistence and spatial performance remain
unverified. Photo trust-field boundaries, workspace selection, worker artifact
recovery, full browser role parity and style quality gates remain open too.
