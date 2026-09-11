# Next authorized block — September10 evening

Continue from `STATUS.md`, not the historical July context. Base source is
`2750953`; latest earlier tested application code is `a9b13b1`. The previous
seven-pass/three-fail hosted result remains historical, not verification of this
new block. No production or Apple changes are authorized by this block.

## Owner decisions and exact experiment authority

The owner authorized one prepared 256-frame room on one mainstream on-demand
NVIDIA GPU of at least24GB class, **USD25 total across all attempts**, with
**provider-enforced maximum lifetime two hours configured before work starts**.
Only the adapter-produced dataset may leave the private local path for that
experiment. No original sidecars or other customers' media; no data in Git.
Delete the remote experiment and confirm API termination even on failure.
Record actual charge separately from a resource-rate estimate. PhaseB–E stays
gated until the owner walks through this real room and reviews the result.

Selected provider was announced before any allocation: **Modal**, one L4,
US region, CPU(request=limit=4), memory(request=limit=32768MiB), timeout7200.
No persistent volume, snapshot, public port or app deployment. The dedicated
`rendprop-room-experiment` CLI profile authenticated successfully. Token values
were not printed or copied into this repository. SDK1.5.3 is pinned locally.

Published September10 full-lifetime compute arithmetic:
`7200 * (0.000222 + 4*0.00003942 + 32*0.00000667) * 1.15 = $4.9110336`.
These are the **Sandbox** CPU/RAM rates, including broad-US region premium.
This is not a measured charge or a guarantee from a billing receipt. September
egress is uncharged per current provider documentation; do not reuse that
assumption after September. No Team subscription upgrade is authorized.

Sources: [lifetime and termination](https://modal.com/docs/guide/sandboxes),
[resource limits](https://modal.com/docs/guide/resources),
[rates](https://modal.com/pricing),
[region premium](https://modal.com/docs/guide/region-selection),
[egress start date](https://modal.com/docs/guide/network-egress-billing),
[billing reports and delayed availability](https://modal.com/docs/guide/billing).

The new runner reserves this whole approval in one private allocation marker
before the provider request. It will not automatically rent again under a new
output path. A lost creation reply uses the exact unique Sandbox name for
lookup/cleanup; it does not allocate another GPU. The provider lifetime, not
that local marker or a process timeout, bounds an orphaned running container.
Public dependencies are installed before media; outbound networking is denied
before the explicitly enumerated adapter files transfer. Cleanup always attempts
both exact-path removal and `Sandbox.terminate(wait=True)` with `poll` readback.

No allocation or training has been reported successful in this checkpoint.
The room runner still needs its preflight tests, paid execution, dependency/GPU
receipt, held-out visual review, pinned SOG conversion and real-phone evidence.
Neither the GUI checkbox nor a local filename proves a real-room/device test.

Pre-rental execution:17 initial offline tests passed; changing the actual
creation request's timeout7200→86400 made the lifetime test fail, exit1.
Independent review of frozen2765324 and installed Modal1.5.3 confirmed the
provider lifetime, empty-list outbound-deny mode, stream-copy parent creation,
and termination/readback semantics. It found a local-interruption cleanup gap:
KeyboardInterrupt during remote deletion could skip the following terminate.
The hardened version nests termination in cleanup's finally, defers repeated
signals during cleanup, records source commit/file hashes, and does not let
stalled log-drain threads postpone reaching termination.21 offline tests now
pass, including interrupted cleanup and the actual collection contract. Tests
use synthetic data and SDK doubles; no provider or real room execution is
inferred. Logs: `/tmp/rendprop-modal-preflight.18BbOI/`.

The actual prepared dataset was rehashed read-only:260 approved adapter files,
147,134,678 bytes. The provenance file and original sidecars are excluded.
The billing-report API was queried read-only and is accessible with the
experiment profile; historical workspace rows were deliberately not emitted.

The first real CLI invocation on c875d2e exited1 before `Sandbox.create`:
Modal App exposes `app_id`, not `object_id`. The original permissive Mock
invented the latter attribute. No GPU was allocated and no dataset transferred;
an exact-application provider `Sandbox.list` readback returned0 active entries.
The original private allocation marker/state are retained as failed-preflight
evidence, not erased or counted as a successful room run. The strict App-shaped
double reproduced3 orchestration errors before the correction;22 tests pass
afterward. An independent pinned-SDK1.5.3 contract check passed4 assertions
without provider calls. Namespace lookup now occurs inside the recorded failure
boundary so even this pre-allocation failure leaves a receipt. Only after that
readback is the unused reservation released for the corrected first allocation.
Logs: `negative-sdk-app.log` and `positive-sdk-app.log` in the preflight path.

### First allocated host — failed setup, no room transfer

Source c6b181747b4872ec3ddc12529eeebc92a058a44c; command:
`uv tool run --from modal==1.5.3 python tools/spatial-spike/training/modal_room.py run
--dataset <private prepared dataset> --state <private modal-room-20260910-02>`.
Exit1. Allocated01:24:17UTC, setup began01:24:29, failed01:28:14,
terminated01:28:16. **Zero dataset files transferred; trainer never ran.**
The CUDA extension compiler failed because the shallow clone did not initialize
the pinned GLM submodule (`glm/gtc/type_ptr.hpp` missing). This is an experiment
setup defect, not evidence about room quality. Both exact-path remote deletion
and `Sandbox.terminate(wait=True)` succeeded; terminate returned137 and separate
poll returned137. A later exact-app list returned0 active sandboxes.

Billing API for01:00–02:00UTC returned one exact-app row:
**USD0.15374134 provider-metered usage**, read before01:33:05UTC. This is an
actual provider report, not a rate-times-minutes estimate; the current partial
hour/invoice can still finalize later. Private receipt and setup compiler log
remain in `LocalSpatialExperiments/modal-room-20260910-02/`, outside Git.

Corrective setup initializes the parent's pinned GLM gitlink and explicitly
checks33b4a621a697a305bc3a7610d290677b96beb181 plus the required header before
compilation. Public-only recursive checkout reproduced that exact header/commit
locally; no CUDA execution on the Mac is inferred. A failure EXIT trap now saves
resolved package and GPU diagnostics as well as successful setup. A second
allocation may proceed only after preserving/reconciling the first marker;
two full provider-lifetime compute bounds totalUSD9.8220672000, belowUSD25.
There is no automatic retry or permission to keep tuning a completed bad room.

### Second allocated host — setup passed, network-policy transition rejected

Source a254e1f, private state `modal-room-20260910-03`; CLI exited1. The pinned
GLM fix worked: CUDA compilation, pip check, actual trainer help, LPIPS weight
cache and GPU check all completed. The recorded device is NVIDIA L4,23034MiB,
driver580.95.05; Torch2.7.1+cu128. The subsequent provider policy call raised
ConflictError **before any room transfer**. Modal's current networking guide
requires each allowlist type to be specified at Sandbox creation before it can
be updated dynamically. The original call omitted both. SDK method existence
and a local mock did not establish that runtime prerequisite.

Corrective request initializes both types, then exercises deny→reopen BEFORE
dependency setup, then denies again before any room transfer. An actual-request
negative test fails on the prior source;24 offline tests pass after correction,
including refusal before setup/transfer if the provider rejects policy changes.
See [provider dynamic-policy limitations](https://modal.com/docs/guide/sandbox-networking).

Remote experiment removal succeeded; terminate and separate poll both returned
137; exact-app provider list returned0 active. At01:46:44UTC the provider
reported **USD0.49112346 cumulative metered usage for both hosts**, not an
estimate and not a finalized invoice. Their markers/receipts stay preserved.
A third bounded setup attempt remains withinUSD25 even reserving three full
two-hour compute lifetimes (USD14.7331008000). No reconstruction has executed
or been quality-tuned; further retries still require explicit reconciliation.

## Parallel ownership

| Lane | Isolated branch | Scope |
|---|---|---|
| Root | `experiment/room-proof-next-block-20260910` | One-room experiment and integration context |
| Upload/cost | `fix/upload-transport-budget-20260910` | One-use bounded transport, durable reservation/settlement and candidate cleanup; migration0037 reserved |
| Adoption | `fix/anonymous-adoption-recovery-20260911` | Source/destination-bound persisted recovery and transaction replay receipt; migration0038 reserved |
| AI/fixtures | Separate measured-headroom branch, agent to report | Measure model-output shape, propose budget alternatives, two synthetic UUID fixture cleanups only |

Worker artifact recovery follows the upload reservation unit. Photo trust-field
write boundaries follow adoption, then explicit workspace/refresh transport.
Privacy/Terms, RenderEngine warnings, device evidence, real browser parity and
style rendering/blind evaluation remain open; none is implied complete by these
parallel units. No simulator camera attempts. Only2.4GiB free was observed, so
avoid duplicate large dependency/build artifacts; do not delete shared evidence.

## Owner decisions still required, not silently made

- **AI budget:** measure the actual model JSON separately from server-enriched
  EDL, state tokenizer/model limitations and cents per call, then let the owner
  choose a ceiling increase or a smaller provable contract. No budget or strict
  invariant comparison change is authorized yet.
- **Historical curl finding:** scanner reports `docs/handoff/launch-P2.md:517`
  in commit `bcba8040bfa10eb0f199e83aa2787fe0f15d5ba9`. That is the start of the
  multiline curl match; a structure-only check locates a **Bearer Authorization
  header on518**. Current line517 is not that header. Value, issuance and validity
  remain unreported/unverified. Owner inspects privately and rotates if real.
  No allowlist, baseline, history rewrite or broad fixture exemption.
- Five other scanner hits retain their prior classifications. Only the two
  `appAccountToken` fixtures are being made unmistakably synthetic, with one
  named value bound to inputs/assertions. PEM and JWT-shaped sanitizer tests stay.

The shared audit worktree had two owner/other-session edits in `STATUS.md` when
this block began. They were not overwritten or committed. This lane uses a new
isolated worktree at `room-proof-next-block-20260910`.
