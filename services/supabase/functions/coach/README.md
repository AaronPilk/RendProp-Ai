# coach

Rendprop's in-app COACH — a text-only chat assistant with two jobs: walk a
user through their first (or next) project one step at a time, and answer
customer-service questions from a fixed knowledge base. Full contract:
[COACH-CONTRACT.md](../../../../docs/COACH-CONTRACT.md).

This is the onboarding/support assistant. It is separate from Studio's
[chat editor and prompt enhancement](../../../../docs/studio/conversational-creation.md).
Deploying those optional endpoints does not change the Coach route or activate
Presenter generation.

## Files

- `index.ts` — the HTTP handler. Auth (owner JWT, like `ai-chapters`), body
  validation, two durable per-user rate limits, chain resolution, durable
  operation admission, funded provider-attempt reservations and result recovery.
  Uncertain provider outcomes retain their financial liability.
- `prompt.ts` — pure. Space-type vocabulary (mirrors `Listing.SpaceType`),
  the system instruction (persona + onboarding step ladder + customer-service
  rules + hard rules), and the user-turn builder.
- `context.ts` — selected-workspace authority and bounded account context:
  membership, plan/access, renewal state, usage and project/enquiry counts.
  Cloud rows must belong to that workspace. Native local route ids remain
  separate from server ids, and local drafts stay explicit device hints.
- `knowledge.ts` — pure. Every customer-service fact the model may state,
  each tagged with the doc it came from. No prices — ever.
- `actions.ts` — pure. The closed action enum, the model's JSON output
  contract, and the parser/sanitizer that turns raw model text into
  bounded actions that the client can validate and handle (drops anything out-of-enum or
  naming an unknown listing; never substitutes or guesses).
- `actions_test.ts` — JSON extraction, enum/id enforcement, clamping and the
  price backstop. `knowledge_test.ts` covers the account/support knowledge.

## Run the tests

```
deno test --cached-only --allow-read --deny-net --deny-env --deny-run --deny-write services/supabase/functions/coach/
```

Pure and offline after the pinned test dependencies have been cached — no env,
network, live Supabase or provider call. Source reads bind the handler, membership
lookup and native screen/industry vocabulary to production code. `actions.ts`, `prompt.ts`
and `knowledge.ts` also pass `deno check` standalone; `index.ts` type-checks
against the real `_shared/*` modules in the repository's edge-function CI job.

## Deployment contract

Keep `verify_jwt=true` and the handler's user authentication. The committed
migration history contains the Coach route seed and later provider updates;
do not reapply the original route seed to reset a production model selection.
Use targeted deployment from a reviewed Supabase CLI staging directory, as
explained in [the functions guide](../README.md). A local `_bridge` helper is
not a portable checked-in release command.

## The two jobs, briefly

1. **Onboarding.** One step, one action, at a time — never a plan dump. The
   step ladder in `prompt.ts`'s `systemInstruction()` picks the first
   applicable rung from the project's own state (`has_video`, `has_tour`,
   `photos`, `reels`, …), the same state `HomeDashboardView`'s gate already
   uses. The model never invents a project id — see `LISTING_ACTIONS` in
   `actions.ts`.
2. **Customer service — the higher priority of the two.** Answered ONLY from
   `knowledge.ts`. Outside that knowledge, the model is instructed to say so
   and offer `open_support` rather than guess.

## Why this function is careful about resilience

The [6 October launch candidate](../../../../docs/handoff/LAUNCH-READINESS-20261006.md)
has no monthly Coach feature-counter quota, but online provider attempts require
verified funding and a bounded reservation before dispatch. Unpriced attempts
are limited to explicitly sponsored internal QA; finite retail/review grants
refuse them. The two per-user rate limits and 600-message daily workspace safety
cap still apply. Deterministic on-device help is separate from paid provider access.
These changes are candidate source, not a deployment or funding receipt; no
retail, trial or App Review allocation is seeded by the migrations.

Workspace membership is resolved before paid work, and the server plan determines
routing; degraded plan reads route as `free`. `X-Org-Id` is required and checked
against membership before limits or providers. Clients without a selected workspace
receive `409 conflict` (selected workspace required) and use on-device help. The native model captures
the workspace/identity at chat creation, checks them across asynchronous hops, and
excludes local fallback bubbles from later online history. Cached full addresses
and remembered street-line variants are redacted again at the request boundary.
All 14 native screens are accepted; unknown text cannot enter ledger metadata.
The selected project is included before the 25-project context bound. Native
Needs attention help uses deterministic review actions before calling a provider:
access/details conflicts open Home for review; uploads/renders/publishing open
the affected tour. Raw job errors never enter context. Local recovery replies
are excluded from later online history. If an account read is unavailable,
Coach says it cannot verify that value and points to Plan & usage.
Migration 0023 seeds no `note='legacy'`
row, so a disabled AI router normally resolves this task to an empty chain.
When the resolved chain is empty, `index.ts`'s `chooseChain()` supplies a
built-in Anthropic → OpenAI fallback using the current source constants.
Recovery depends on both providers being configured and available. A nonempty
configured chain is used as returned, even if it contains only one provider;
the fallback is not an availability guarantee.

## What this function deliberately does NOT do

- No photo or video ever reaches it — `context.listings[]` carries bounded
  counts/device hints. Server context includes only authorized closed states
  and limited account/usage fields; no lead contents, addresses, receipt ids,
  provider keys or raw errors are loaded.
- No marketing copy, listing description or ad text — that stays behind the
  fair-housing-gated tools; the coach only points at them.
- No price, ever — `knowledge.ts` carries counts only; a slip past the
  prompt is caught by `actions.ts`'s server-side regex backstop.
- No message text is ever logged, in either direction.
