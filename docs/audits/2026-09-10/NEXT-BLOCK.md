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
