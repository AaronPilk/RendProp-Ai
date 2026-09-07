# coach

Rendprop's in-app COACH — a text-only chat assistant with two jobs: walk a
user through their first (or next) project one step at a time, and answer
customer-service questions from a fixed knowledge base. Full contract:
`docs/COACH-CONTRACT.md`.

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
  something the app can execute blindly (drops anything out-of-enum or
  naming an unknown listing; never substitutes or guesses).
- `actions_test.ts` — `deno test` coverage for `actions.ts` (23 cases: JSON
  extraction, enum/id enforcement, clamping, the price backstop).

## Run the tests

```
deno test services/supabase/functions/coach/actions_test.ts
```

Pure and offline — no env, no network, no Supabase. `actions.ts`, `prompt.ts`
and `knowledge.ts` also pass `deno check` standalone; `index.ts` type-checks
against the real `_shared/*` modules (see docs/COACH-CONTRACT.md's "Known
sandbox limitation" note about `_shared/providers/common.ts`, which is
pre-existing and unrelated to this function).

## Deploy

```
_bridge/tools/deploy-fn.sh - coach
```

plus applying migration `0023_coach_routes.sql` (seeds the `coach.chat` task
into `ai_routes` — anthropic primary, openai fallback, both reusing model ids
already live in `0018_ai_routes.sql`).

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
only the two per-user rate limits) and is asked, in the product brief, to
"never be dead." Migration 0023 seeds no `note='legacy'` row (there is no
prior shipped behaviour to preserve), so with the AI-router feature flag off
— today's default — `resolveRoute()` normally returns `[]` for a brand-new
task. Rather than accept single-provider risk during that (very common)
state, `index.ts`'s `chooseChain()` substitutes a hardcoded TWO-step
fallback (anthropic → openai, byte-identical to migration 0023's seeded
rows) so one vendor outage never takes the coach down, even before the
router flag is ever flipped on. Once the flag is on, the real seeded rows
are used exactly as `resolveRoute()` returns them (never re-filtered).

## What this function deliberately does NOT do

- No photo or video ever reaches it — `context.listings[]` is booleans and
  counts the client already has, never fetched from the DB here.
- No marketing copy, listing description or ad text — that stays behind the
  fair-housing-gated tools; the coach only points at them.
- No price, ever — `knowledge.ts` carries counts only; a slip past the
  prompt is caught by `actions.ts`'s server-side regex backstop.
- No message text is ever logged, in either direction.
