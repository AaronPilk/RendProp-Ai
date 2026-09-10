# WH-05 — customer HTML follows publication revocation

2026-09-10. Isolated branch `fix/public-host-revocation-cache-20260910`, based
on `b96896e`. This is a local source/test repair, **not deployed**. No iOS,
Apple, production data, provider, database or media changes were made.

## Defect and narrow repair

The prior `handleTour` and `handlePortfolio` returned `caches.default.match`
before fetching current publication state. A previously cached successful page
therefore overrode a later upstream 404, continuing to expose the rendered
customer address/media links. Changing only the new response TTL cannot repair
that branch because the cached response has already returned.

- `services/edge/tour-host/src/index.ts:288`: only the explicit synthetic demo
  slugs (`estate-demo`, `demo`) may access the tour Cache API. Customer tours,
  including MLS `/u/`, bypass old reads and new writes and return `no-store`.
- `services/edge/tour-host/src/index.ts:374`: customer portfolios no longer read
  or write cached HTML. A live portfolio can remain 200 while a newly removed
  tour card disappears. Fictional `meridian` / `demo` portfolios retain their
  existing browser-cache policy.
- Success and unavailable customer responses are `no-store`; renderers, branding,
  unbranded fail-closed checks, robots/CSP headers, upstream URL/auth construction
  and media playback are unchanged. `TOUR_CACHE_TTL` is now demo-only; its value,
  deployment bindings and compatibility date are unchanged.

Tradeoff: every customer page request reaching this Worker now incurs the existing
upstream publication lookup and render. There is no measured latency/load claim.
Version-bound caching with authoritative publication checks would be separate work.

## Actual offline verification

The existing actual-module route gate was extended in
`services/edge/tour-host/scripts/check-routes.mjs:63`. It transpiles the real source,
replaces upstream fetch with synthetic responses and supplies an in-memory Cache
API. Old successful HTML is deliberately primed and **not purged** before upstream
revocation. Tests assert upstream invocation, 404, `no-store`, absent stale customer
content and retained branded/MLS-neutral responses. Coverage includes GET/HEAD,
trailing slash/query variants, embed links, removed portfolio cards, unchanged
synthetic demo cache hits/TTL and fictional portfolio cache policy.

Evidence directory: `/tmp/rendprop-host-revocation.N6id1U` (ephemeral).

| Command from `services/edge/tour-host` | Actual result |
|---|---|
| Original gate: `env -i PATH="$PATH" node scripts/check-routes.mjs` | Exit 0, 361 assertions. |
| New revocation tests against unchanged source, same command | **Exit 1**, 68 failures across 541 assertions; `routes-before.log`. |
| Final same command after repair and an additional still-200 portfolio regression | Exit 0, **584 assertions**; `routes-final.log`. |
| `env -i PATH="$PATH" node scripts/check-unbranded.mjs` | Exit 0, **557 assertions over 15 renders + 12 gate self-tests**; `unbranded-final.log`. |
| `env -i PATH="$PATH" node node_modules/typescript/bin/tsc --noEmit` | Exit 0, no diagnostics; `typecheck-final.log`. |
| `git diff --check` | Exit 0. |
| `bash /tmp/rendprop-host-revocation.N6id1U/verify.sh` | Exit 0; symbol prerequisites, accumulated `FAIL` and explicit final exit. |

Counts differ before/after because each actual upstream call itself asserts its
path and disabled upstream cache settings; old cache hits skipped those calls.
The first red run preceded the additional still-200 portfolio test. No ignored or
skipped branch is represented as executed proof.

Node 25.9.0, TypeScript 5.9.3 and Workers types 5.20260907.1 were already installed.
Only TypeScript and Workers-types package directories are symlinked from the
worker-host audit worktree; generated check modules have their **own** 488 KiB
cache. No install, dependency upgrade, Wrangler command, server start, browser
run, cache purge or remote call was used for verification.

## Limits and rollout acceptance

This proves the actual Worker handler's decisions under synthetic upstream/cache
conditions, **not** deployed Cloudflare cache rules, browser cache behavior or a
real upstream publication transaction. The unchanged upstream fetch options remain
`cacheTtl: 0, cacheEverything: false`. Upstream enforcement and media authorization
must be verified separately in an owner-approved environment.

Previously browser/intermediary-cached HTML can remain usable until its old
freshness lifetime expires; old open pages, downloaded files, search copies and
already issued media URLs cannot be erased by an HTML header. No immediate global
erasure guarantee is made. Future deployment should check for any cache rules
outside this Worker that override customer no-store. Portfolio network/5xx errors
still map to the existing branded 404 (now no-store), an explicit WH-10 limitation.
No attempt was made to broaden this repair to that error classification or to
upstream resource limits.

## Reference basis

Cloudflare and Workers best-practice skills required API/reference retrieval before
editing. Their guidance led to bypassing old Cache API reads, not merely changing
new response headers. Installed type definitions were reused rather than installing
new packages. Supabase guidance was inspected because the existing upstream is an
Edge Function; its auth/route behavior was not changed or exercised live.

- [Cloudflare Cache API](https://developers.cloudflare.com/workers/runtime-apis/cache/):
  `match()` does not send an origin subrequest; response cache directives govern
  `put()`. Retrieved 2026-09-10.
- [Workers best practices](https://developers.cloudflare.com/workers/best-practices/workers-best-practices/):
  reviewed with the installed Cache / ExecutionContext types. Retrieved 2026-09-10.
