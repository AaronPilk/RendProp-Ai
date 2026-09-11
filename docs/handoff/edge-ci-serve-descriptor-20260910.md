# Edge CI lazy-serve descriptor repair

Parent source: `46a2782c3eb8216374bd8b863a40a50a4613ffc1` (the timer-type
repair, integrated into hosted source `0051924`). No workflow or application
source changes are part of this follow-up.

## Actual failure and cause

[Hosted job 103096918248](https://github.com/AaronPilk/RendProp-Ai/actions/runs/34545436453/job/103096918248)
installed Deno 2.9.6, passed entrypoint checks and the test-program typecheck,
then reported **569 passed / 29 failed, exit 1**. All 29 failures were the actual
upload route fixtures failing at `Object.defineProperty(Deno, "serve", ...)`:
`Invalid property descriptor. Cannot both specify accessors and a value or writable attribute`.
This is a distinct failure from the preceding timer-type error.

The pinned [Deno 2.9.6 namespace source](https://github.com/denoland/deno/blob/v2.9.6/runtime/js/90_deno_ns.js#L269-L276)
defines `serve` with `propWritableLazyLoaded`; its lines 15–21 describe deferred
loading. An accessor descriptor contains get/set fields. The fixtures spread
that original descriptor and added value, which is an invalid accessor/data
mixture. The older installed local Deno 2.7.13 supplies a data property, hiding
the defect in its previous 598-test green runs.

Both interception sites now install explicit data descriptors with the original
configurable/enumerable flags, writable true and the stub value. No get/set fields
are copied. Stub installation is inside the existing try/finally so installation
errors also reach cleanup. Finally still restores the complete original descriptor,
fetch and synthetic environment; timeouts and all publication assertions remain.

Four new actual-route tests supply data/accessor descriptors and exercise successful
completion plus a deliberately thrown scenario error. They assert actual winner
bytes and upload state, then exact descriptor and fetch restoration. The accessor
setter throws if invoked; the supplied data property is deliberately non-writable.
Neither the real serve function nor any network service is called.

## Red/green evidence

Evidence: `/tmp/rendprop-edge-ci-rerun.JkPUou/`. Hosted log:
`/tmp/rendprop-edge-ci-failure.tCDHM0/second-ci-job.log`.

```sh
gh run view 34545436453 --job 103096918248 --log
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin \
  DENO_DIR=/Users/pilksclaes/Library/Caches/deno NO_COLOR=1 \
  deno test --cached-only --deny-net --deny-run --deny-write \
  --allow-env --allow-read \
  --filter 'actual route fixture restores accessor descriptor after success' \
  services/supabase/functions/uploads/publication_route.test.ts
```

Log retrieval exited 0 (not a CI success). After adding the regression but before
fixing either stub, the filtered command produced the exact hosted TypeError:
**0 passed / 1 failed / 31 filtered, exit 1**, saved as `accessor-before.log`.
The deliberate filter was only for the negative control, not the passing gates.

Using the same env and permission flags, without `--filter`:

- `deno test ... services/supabase/functions/uploads/`: **55 passed, 0 failed,
  0 skipped, exit 0**, `uploads-after.log`.
- `deno test ... services/supabase/functions/`: **602 passed, 0 failed,
  0 skipped, exit 0**, `all-after.log`.
- `git diff --check`: exit 0.

These typed local tests use Deno 2.7.13 / TypeScript 5.9.2 and cached dependencies.
The accessor-shape negative reproduces the specific hosted mechanism, not the
entire Deno 2.9.6 runtime. A fresh hosted run is still required; no passing hosted
result is claimed here. No installation, dependency download, live service,
deployment, Apple action or publication-logic change occurred. The unrelated
untracked Supabase CLI `.temp` directory was not read or staged.

## Later coordinating-agent hosted proof

Integrated as7b60ada and pushed. Actual GitHub run34546017429, edge job
103098683585, now passes602 tests and all21 entrypoint checks. Root read the
actual602passed/0failed footer. Same-source local receipt:
`/tmp/rendprop-edge-audit-lszgf9yw/receipt.json`. The full workflow still has the
separate database-headroom and scanner failures; see
`docs/audits/2026-09-10/HOSTED-CI-20260910.md`.
