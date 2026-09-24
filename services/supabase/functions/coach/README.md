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
  validation, two durable per-user rate limits, chain resolution, the
  provider call, parsing, best-effort cost logging.
- `prompt.ts` — pure. Space-type vocabulary (mirrors `Listing.SpaceType`),
  the system instruction (persona + onboarding step ladder + customer-service
  rules + hard rules), and the user-turn builder.
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
deno test --cached-only --deny-net --deny-env --deny-run services/supabase/functions/coach/
```

Pure and offline after the pinned test dependencies have been cached — no env,
network, live Supabase or provider call. `actions.ts`, `prompt.ts`
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

`coach.chat` is free on every plan (no entitlement check, no monthly quota —
only the two per-user rate limits). Migration 0023 seeds no `note='legacy'`
row, so a disabled AI router normally resolves this task to an empty chain.
When the resolved chain is empty, `index.ts`'s `chooseChain()` supplies a
built-in Anthropic → OpenAI fallback using the current source constants.
Recovery depends on both providers being configured and available. A nonempty
configured chain is used as returned, even if it contains only one provider;
the fallback is not an availability guarantee.

## What this function deliberately does NOT do

- No photo or video ever reaches it — `context.listings[]` is booleans and
  counts the client already has, never fetched from the DB here.
- No marketing copy, listing description or ad text — that stays behind the
  fair-housing-gated tools; the coach only points at them.
- No price, ever — `knowledge.ts` carries counts only; a slip past the
  prompt is caught by `actions.ts`'s server-side regex backstop.
- No message text is ever logged, in either direction.
