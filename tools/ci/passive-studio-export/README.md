# One hosted passive export diagnostic

Payload destination on the isolated diagnostic branch: `tools/ci/passive-studio-export/`.

This portable version does not edit shipping source. Original local helpers, manifest and local-run-1 remain unchanged.

## Workflow invocation

Checkout shipping source at `1c561d7b91d9b75bd7ba29aa081fcba959089fee`. Obtain this payload separately from the dispatch branch, for example a second sparse checkout at `_diagnostic-payload`. Install locked npm dependencies in shipping `apps/studio`; verify the same browser/tools as failed CI.

```sh
python3 "$GITHUB_WORKSPACE/_diagnostic-payload/tools/ci/passive-studio-export/prepare_diagnostic_copy.py" \
  --studio-root "$GITHUB_WORKSPACE/apps/studio" \
  --base-dir "$RUNNER_TEMP/rendprop-passive-diagnostic"
node --test "$RUNNER_TEMP/rendprop-passive-diagnostic/passive-export-diagnostics.test.mjs"
```

Run unchanged bounded runner readiness after preparation/version checks/closed controls. Then invoke once:

```sh
python3 "$RUNNER_TEMP/rendprop-passive-diagnostic/run_diagnostic.py" \
  --browser "$STUDIO_BROWSER_EXECUTABLE"
```

Retain all `$RUNNER_TEMP/rendprop-passive-diagnostic/` on success or failure. `run-1` is created exclusively. Driver never retries and verifies input hashes before/after. A refused export stays failed with zero-download evidence.

## Scope

- Exact shipping commit, 13 Studio hashes and four repository hashes are pinned in `shipping-inputs.json`; tracked modifications are refused.
- First narrated export only: original H264/AAC, duration, decoded narration and dissolve/whip assertions remain. Stop before Save/reconciliation/continuous-agent flows. Success explicitly says `diagnostic-case-passed`, `partialSuite: true`.
- First 120 actual native requestFrame calls per export, maximum four exports per page, with native before/after time and clip/local/timeline metadata. Native receiver/arguments/results/exceptions remain unchanged.
- First 16 encoded samples and nine around a refusal: ordinal/timescale/start/end/duration only. Existing recorder calls/events/dataavailable bytes/timecodes and pre/post-export load remain.
- No new timers, workers, audio resumes, decoders or trace sessions. Bounded synchronous observation adds overhead.
- Default-device audio matches failed CI: no silent-audio option. Driver checks the receipt.

## Dependencies

Actual harness execution: Node 24.22.2; locked Vite 8.3.5 and Playwright/Test 1.63.0; Chromium revision 1243 / Google Chrome for Testing 153.0.8010.12; FFmpeg/FFprobe 9.0.2; default native audio output. Preparation uses Python 3 and Git. Driver requires and records exact runtime versions. No installer is embedded.

The copied harness imports existing JS native-trace/scheduling modules. The later code invoking Swift trace helpers is removed at the stop point: no Swift trace binary is needed.

The previous cache belongs to another run/workflow. Workflow owner may freshly install and verify locked native tools before readiness, retaining original signature/version checks. This diagnostic does not replace mandatory CI. No live accounts/provider jobs, quality weakening, epoch reset or padding is introduced.
