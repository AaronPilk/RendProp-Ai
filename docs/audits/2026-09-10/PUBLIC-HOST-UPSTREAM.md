# WH-10 — bounded upstream reads and honest public-host failures

2026-09-10. Branch `fix/public-host-upstream-bounds-20260910`, based on
`7933f75`. Local source/tests only; **not deployed**. No iOS, Apple, database,
provider, public page, live API or customer media was changed or accessed.

## Implemented scope

`services/edge/tour-host/src/upstream.ts` is shared by actual `/f/`, `/u/` and
`/a/` handlers. It attaches a real AbortController, races the whole asynchronous
headers/body operation against one 8,000 ms timer, and clears the timer on every
completed path. Fetch and body cancellation are attempted on failure, but a
non-settling cancellation cannot hold the public request open. If a nonconforming
fetch resolves after abort, the late body is cancelled and never parsed/rendered.
Requests use the existing upstream URL/auth/cache options, no retries, and manual
redirect handling so authorization is not forwarded to an upstream-selected URL.

The decoded response stream is counted **before** copying each chunk into a
bounded, geometrically grown buffer. The 4 MiB ceiling does not trust the upstream
Content-Length, which may be false or describe compressed transfer bytes. It does
not retain an array of arbitrarily many chunks. More than 64 consecutive empty
chunks is refused: a byte cap alone cannot stop an immediately-ready, non-progressing
stream from starving an asynchronous timer. JSON parsing happens only after bounded
complete bytes have been decoded as strict UTF-8.

The host checks the minimum renderer object/collection shape and catches malformed
nested fields at rendering. This is **not** a replacement for full upstream schemas.

| Upstream condition | Public response |
|---|---|
| Actual 404 | Existing unavailable 404 |
| Transport/read error, deadline, 429 or 5xx | 503 |
| Bad JSON/UTF-8/renderer shape, over cap, no progress, other non-2xx | 502 |
| Valid payload within budget | Normal rendered 200 |

All customer responses retain `no-store`. `/u/` failures stay MLS-neutral with
noindex; `/f/` and `/a/` keep branded error pages. Raw upstream text, exception
messages, hostnames and auth values are not rendered into errors. Synthetic demo
paths still return locally without invoking this helper; their caching is unchanged.

## Why these limits, and what they do not prove

The upstream contract is JSON metadata/URLs, not binary media. Source at this base:

- `services/supabase/functions/tours/index.ts:79` limits provenance rows via
  `MAX_ALTERED_MEDIA` (40); `:104` / `:132` cap gallery URLs at 40.
- Tour response construction at `:394` returns metadata, chapters and media URLs.
- `services/supabase/functions/portfolio/index.ts:60` reads active listings and
  `:93` constructs one published card per listing. It has no total portfolio cap;
  tour details/brand fields also are not globally byte-bounded here.

Thus **4 MiB is an explicit conservative host operating ceiling**, not an assertion
that every possible existing customer record fits. Synthetic full demo payloads,
including valid JSON whitespace-padded to exactly 4 MiB, pass. Over-limit inputs
fail instead of silently dropping cards/fields. No production payload sizes,
normal latency, provider SLA or capacity figures were measured. The 8-second budget
is a deliberate waiting limit, not a measured threshold.

The cap bounds retained response bytes, not the runtime's individual incoming
chunk allocation, decompressor internals, parsed object graph, HTML size or total
RSS. Timers cannot preempt synchronous JavaScript parsing/rendering. Platform CPU,
concurrency and upstream database limits remain separate. No compressed network
response was fetched in the offline gate; its streams represent bytes exposed by
Fetch to application readers.

## Actual verification

`scripts/check-upstream.mjs` imports/transpiles the real Worker and supplies synthetic
fetch responses, actual Web Streams and AbortControllers. It asserts the source
schedules one **8,000 ms** timer, but executes that timer after **5 ms in the test
process only**. An independent native 1-second watchdog fails noncompletion.
This is cancellation/control-flow proof, not a measured eight-second network run.

The 75 cases cover three route families: valid content, authoritative absence,
429/500/503, transport/body errors, redirect refusal, invalid JSON/UTF-8/shapes,
null collection entries, missing body, exact-cap success, over-cap failure with
false Content-Length, multibyte and cumulative chunk accounting, empty-chunk
progress, stalled headers/body, non-settling cancel and late-response cleanup.
The test checks an exact case count, expected status, no-store, timer cleanup,
abort/cancel effects and safe branding; failures set a nonzero exit status.

Evidence directory: `/tmp/rendprop-host-upstream.eL9E3C` (ephemeral).

| Command from `services/edge/tour-host` | Actual result |
|---|---|
| New upstream tests against unchanged `7933f75`, `env -i PATH="$PATH" node scripts/check-upstream.mjs` | **Exit 1**, 133 failures / 362 assertions / initial 57 cases; `before.log`. Stalls hit the independent test watchdog. |
| Final same command after repair and additional boundary cases | Exit 0, **707 assertions / 75 cases / 0 skipped**; `after.log`. |
| `env -i PATH="$PATH" node scripts/check-routes.mjs` | Exit 0, **584 assertions**; `routes.log`. |
| `env -i PATH="$PATH" node scripts/check-unbranded.mjs` | Exit 0, **557 assertions / 15 renders + 12 gate self-tests**; `unbranded.log`. |
| `env -i PATH="$PATH" node node_modules/typescript/bin/tsc --noEmit` | Exit 0, no diagnostics; `typecheck.log`. |
| `git diff --check` | Exit 0. |

The original red run preceded added redirects, collection-entry, fragmented-body,
empty-chunk and late-response regressions. Existing upstream-500/network route
assertions deliberately now expect 503 instead of 502. `npm test` includes the new
gate after both existing gates with `&&`, preserving nonzero failure propagation.

Reused already-installed Node 25.9.0, TypeScript 5.9.3 and Workers types
5.20260907.1; no installs, Wrangler/server/browser commands or deployment. Final
verification uses symbol prerequisites plus an accumulated FAIL and explicit exit
in `/tmp/rendprop-host-upstream.eL9E3C/verify.sh`.

## Still outside this unit

No actual Cloudflare execution, compressed HTTP integration, backend publication
transaction, browser lead submission, phone interaction or deployed cache policy
was proven. WH-05's old-browser-cache and already-issued-media limitations remain.
The later WH-10 browser lead-form timeout/strict-success unit is now implemented
and tested locally in `PUBLIC-LEAD-FORM.md`, including actual emitted-handler
deadline, retry and confirmation tests. It remains a separate, undeployed
change; this upstream-reader unit alone did not establish that behavior.
No public response or prompt claims the complete hosting stack is verified.

Cloudflare/Workers skills guided retrieval and streaming/cancellation semantics:

- [Request cancellation](https://developers.cloudflare.com/workers/runtime-apis/request/):
  supplied AbortSignal cancels a request; manual redirects avoid forwarding auth.
- [ReadableStream API](https://developers.cloudflare.com/workers/runtime-apis/streams/readablestream/):
  reader locking and cancellation semantics.
- [Fetch compression](https://developers.cloudflare.com/workers/runtime-apis/fetch/):
  compressed passthrough depends on not reading the body; application reads consume
  decoded content. Real compressed-network behavior remains untested here.

Primary docs and installed type signatures were checked on 2026-09-10. No API
configuration or compatibility-date upgrade was necessary for these APIs.
