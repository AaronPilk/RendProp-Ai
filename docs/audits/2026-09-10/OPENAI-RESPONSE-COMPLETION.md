# OpenAI Responses completion gate — bounded implementation handoff

Base: `e2acf95f274b3931a5c185f0a76eb87a224f0812` (`audit/full-regression-20260910`). Work branch: `fix/openai-incomplete-response-20260910`. Date: 2026-09-10. This is a local adapter correction, not a deployment or proof of live provider reliability.

## Confirmed defect and reproduction

Before this change, `services/supabase/functions/_shared/providers/openai.ts:210` returned a nonempty `output_text` immediately; lines 211–216 also returned the first nested output content text. Neither branch inspected the Responses object's `status`, `error`, or `incomplete_details`.

Consequently a synthetic HTTP 200 containing either of these envelopes was accepted as a successful generation:

```json
{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output_text":"unfinished fixture text"}
```

```json
{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\"flag\":false,\"reason\":\"partial verdict\"}"}]}]}
```

The second fixture passes JSON parsing. The previous `openaiJudge()` returned its false flag despite an explicitly unfinished envelope. This proves an adapter-level acceptance bug, not that a live fair-housing route was bypassed or that every partial reel is otherwise valid.

The actual AI-copy path calls this adapter at `services/supabase/functions/ai-copy/index.ts:383`. Agent-reel generation reaches that call through `runChain()` at `ai-copy/index.ts:831`. A returned string is treated as a successful chain attempt at `_shared/providers/chain.ts:82`. Downstream syntax, EDL, and compliance validation may reject some prefixes, but those checks cannot prove that an explicitly incomplete provider response actually finished.

OpenAI documents that the output-token ceiling includes reasoning and visible output and can produce an incomplete response when exhausted. This is why text presence alone cannot be the success condition. [Official reasoning guide](https://developers.openai.com/api/docs/guides/reasoning#allocating-space-for-reasoning) (checked 2026-09-10).

## Implemented correction

- `_shared/providers/openai.ts:210–229`: immediately after the existing bounded HTTP request, require `status === "completed"`, no non-null `error`, and no non-null `incomplete_details` before either text-extraction path.
- Incomplete, failed, cancelled, error, pending, missing-status, unknown-status, and contradictory completed/error envelopes become `ProviderError("openai", "upstream", ...)`. No raw error body or partial customer text is included in these new messages.
- A `content_filter` incomplete reason becomes the existing terminal `nsfw` error class. `_shared/providers/chain.ts:90` already prevents this class from being retried with another provider. Other upstream failures follow the existing chain behavior; this patch adds no retry loop, route, or provider.
- `_shared/providers/providers_test.ts:628`: the existing request-shape fixture now supplies `status: "completed"`. It previously lacked the actual Responses success state. Its request-body assertions are unchanged, including the legacy 300-token default and route-param precedence.
- `_shared/providers/openai_responses_test.ts:11`: synthetic fetch wraps the actual `openaiChat()` / `openaiJudge()` functions. Each test asserts exactly one request, the exact Responses endpoint, POST, and the preserved timeout signal. The original fetch and test-only key are restored in `finally`.
- `_shared/providers/openai_responses_test.ts:105`: twelve rejection envelopes are checked against both text extraction formats (24 tests), plus two successful text formats, completed-without-text rejection, incomplete-JSON judge rejection, and successful completed judge parsing (5 tests).

### Deliberately unchanged

No migrations, `ai_routes`, model selections, token ceilings, request payloads, billing logic, prompts, or Apple distribution files were changed. The new gate makes failure honest; it does not make a too-small budget sufficient.

The separately reported agent-reel headroom tension remains: migration `0034_agent_reel_and_video_ladder.sql:71` supplies `effort: "low"` and `max_output_tokens: 700`; `ai-copy/index.ts:220` supplies a 700-token caller ceiling. The strict database headroom invariant must remain failing until an authorized product/cost decision resolves that contract. Do not raise the budget or weaken the test just to obtain a green result.

## Verification and exact results

Commands below ran from `services/supabase/functions` in the isolated worktree, with a cleared environment, a fixture-only key installed by the test, cached dependencies, and network denied. No production DB, vendor, deployment, or Xcode command ran.

```sh
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin HOME=/Users/pilksclaes \
  /opt/homebrew/bin/deno test --cached-only --no-check --allow-env --deny-net \
  _shared/providers/openai_responses_test.ts
```

Before the production edit: **4 passed, 25 failed, exit 1**. Each rejection fixture failed because the function returned instead of rejecting. Completed successes and the existing no-text rejection passed. After the edit: **29 passed, 0 failed, exit 0**. None ignored or disabled.

Full affected suites, with TypeScript checking enabled (no `--no-check`):

```sh
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin HOME=/Users/pilksclaes \
  /opt/homebrew/bin/deno test --cached-only --allow-env \
  --allow-read=../migrations/0030_route_params.sql,ai-video/motion.ts --deny-net \
  --junit-path=/tmp/rendprop-openai-completion.MLnVNn/combined.xml \
  _shared/providers/ ai-copy/
```

Result: **180 passed, 0 failed, exit 0** (69 provider tests, including 29 new completion tests; 111 AI-copy tests). The JUnit report was independently parsed and asserted to contain exactly 180 test cases, zero errors, zero failures, zero skipped nodes, and zero disabled tests. A separate supported type-check-only command also exited 0:

```sh
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin HOME=/Users/pilksclaes \
  /opt/homebrew/bin/deno test --cached-only --no-run --allow-env --deny-net \
  _shared/providers/openai_responses_test.ts
```

Harness corrections, not hidden passes: the first broader runs without `--allow-read` failed on existing migration-text and motion-file checks (68 pass/1 fail and 78 pass/1 module error). Only the two named source reads were allowed for the successful reruns; no source was changed to waive these checks. An initial `deno check --cached-only` invocation exited 1 because this installed CLI does not support that flag for `check`; the supported `deno test --cached-only --no-run` above performed the actual successful check.

Evidence retained locally in `/tmp/rendprop-openai-completion.MLnVNn/`: `before.log`, `after.log`, initial `providers.log` and `ai-copy.log`, scoped-read reruns, `typecheck.log`, `typecheck-supported.log`, `combined-checked.log`, and `combined.xml`. Temporary logs are not a durable deployment receipt. The committed regression file is the reproducible proof mechanism. `git diff --check` passed.

## Integration and remaining limits

Cherry-pick this bounded commit into the integration branch and rerun the combined command. The new file matches normal Deno `*_test.ts` discovery. Any separate success fixture for Responses must represent `status: "completed"`; do not relax the production gate to accommodate incomplete test data.

No live completion-rate, latency, billing, fallback-route availability, or current deployed revision is established by this run. Existing `reportOutcome()` tests tolerate missing Supabase credentials and therefore do not establish successful production telemetry writes. The new completion tests invoke no telemetry or DB path. No API key was displayed and no paid request was made.
