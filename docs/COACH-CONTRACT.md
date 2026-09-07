# Coach — contract v1 (2026-09-07)

Rendprop's in-app chat assistant. Two jobs, in priority order:

1. **Onboarding.** Guide a user through their first (or next) project one step
   at a time — never a plan dump. Exactly one next step, exactly one action.
2. **Customer service — the higher priority of the two.** Answer questions
   about publishing, the unbranded MLS link, AI disclosure, what each tool
   does, filming tips, account deletion, and managing a subscription. Must
   never be dead, never fabricate, and is free on every plan.

TEXT ONLY. No photo or video is ever part of a request in either direction.

## 1. Endpoint

```
POST /coach
Authorization: Bearer <user JWT>       (owner auth — same as /ai-chapters)
```

Request:

```jsonc
{
  "messages": [ { "role": "user" | "assistant", "content": "…" }, … ],
  "space_type": "real_estate" | "venue" | "restaurant" | "retail" | "fitness" | "other",
  "context": {
    "listings": [
      {
        "id": "…",            // this phone's own listing id — round-trips as listing_id
        "title": "123 Main St",
        "has_video": false, "room_tags": 0, "has_tour": false, "published": false,
        "photos": 0, "edits": 0, "reels": 0
      }
    ],
    "plan": "free" | "trial" | "starter" | "solo" | "pro" | "team",
    "screen": "home" | "settings" | null   // a hint only, never load-bearing
  }
}
```

Response:

```jsonc
{
  "reply": "…",                 // ≤ 700 chars, plain text
  "actions": [ { "type": "open_tour", "label": "Open the tour", "listing_id": "…" } ], // 0 or 1
  "suggested_replies": [ "…" ], // 0-4 short reply chips
  "model": "claude-sonnet-5"    // whichever step of the chain actually answered
}
```

Auth failure is a plain `401` (signed-out) — the app's own offline knowledge
answers instead of showing an error; see §5.

`context.listings[]` is the CLIENT's own report of its own on-device state
(`AppModel`), never looked up server-side by id. A stale or wrong id costs
nothing but a slightly-off suggestion; it can never leak another org's data,
because nothing is ever fetched with it.

## 2. The closed action enum

Exactly these ten values. The model never invents an eleventh — this is
enforced server-side (dropped, not coerced) and re-checked client-side
(dropped again if somehow malformed):

| `type`             | Needs `listing_id` | Maps to (iOS)                                          |
|---------------------|:---:|----------------------------------------------------------|
| `start_project`      | no  | `StartProjectSheet` (`gate = .start(.tour)`)             |
| `open_tour`          | yes | `ProjectRoute(listing:, feature: .tour)`                 |
| `open_photos`        | yes | `ProjectRoute(listing:, feature: .photos)`               |
| `open_reel`          | yes | `ProjectRoute(listing:, feature: .reel)`                 |
| `open_floor_plan`    | yes | `ProjectRoute(listing:, feature: .floorPlan)`            |
| `open_aerial`        | yes | `AerialIntroSheet` via `gate = .aerial(listing)` (a sheet, not a push) |
| `share_tour`         | yes | same as `open_tour` — the finished tour's own Share sheet |
| `open_plan_usage`    | no  | Settings tab (Plan & usage section)                      |
| `open_support`       | no  | mailto: `SettingsView.supportMailURL(subject:)`          |
| `open_home`          | no  | Home tab                                                 |

A listing action's `listing_id` MUST be one of the ids the CALLER sent in
`context.listings` for THIS request — never invented, never guessed, never
substituted for a different one. Both server (`coach/actions.ts`,
`sanitizeCoachOutput`) and client (`CoachModel.route(for:action:)`) drop the
whole action rather than guess when this fails.

At most **one** action per reply — "exactly one primary next step, never a
menu" — enforced, not just requested.

Three independent copies of this enum exist by necessity (server/iOS/docs
can't share a source file) and must be changed together:
- `services/supabase/functions/coach/actions.ts` → `ACTION_TYPES`
- `apps/ios/Rendprop/Coach/CoachAPI.swift` → `CoachActionType`
- this document

## 3. Rate limits (durable, per user — abuse protection, not a plan quota)

- **12 messages / 5 minutes**
- **60 messages / day**

No entitlement check, no monthly allowance, no plan gate — coach is free on
every plan by product decision. A limit hit is a `429` with a plain-language
message; the app shows it as an assistant bubble, not an error dialog.

## 4. Never a price

Every dollar figure is deliberately absent from `coach/knowledge.ts` — only
COUNTS (renders/edits/reels/aerials per plan). Prices exist only via
StoreKit (`Product.displayPrice`), which can differ by region and change
without a docs update. Defense in depth, same posture as this codebase's own
fair-housing re-check (`ai-chapters/postprocess.ts`) — never trust one
instruction alone:

1. `knowledge.ts` states counts only, never a number with a currency.
2. `prompt.ts`'s system instruction explicitly forbids stating a price and
   says to use `open_plan_usage` instead.
3. `actions.ts`'s `sanitizeCoachOutput` runs a regex backstop
   (`/\$\s?\d|\bUSD\b|\bdollars?\b|\bcents?\b/i`) over the model's own reply;
   a hit discards the reply and substitutes a safe canned one plus a forced
   `open_plan_usage` action.

## 5. Never dead

- **Signed out, or the request throws for any reason** (network, timeout,
  rate limit, a bad response): `CoachModel` (iOS) answers from
  `CoachOffline` — a small on-device mirror of the customer-service
  knowledge, plus the SAME onboarding step ladder run locally over state the
  phone already has (no network needed for that half at all). The chat is
  never blank and never shows a raw error.
- **The AI-router feature flag is off** (today's default) and the DB has no
  seeded route for `coach.chat` yet, or `resolveRoute()` throws:
  `coach/index.ts`'s `chooseChain()` substitutes a hardcoded two-step
  fallback (anthropic → openai) byte-identical to migration 0023's seeded
  rows, so one vendor outage never takes the feature down even before the
  router is ever turned on for it.
- **The model's own output is unusable** (empty, unparseable, not JSON):
  `actions.ts`'s `parseCoachOutput` falls back to a fixed, friendly
  `FALLBACK_REPLY` with `open_support` — never a thrown error, never a blank
  reply.

## 6. Knowledge base

`coach/knowledge.ts` states ONLY facts drawn from six sources (each entry is
tagged with which one):

- `docs/appstore/metadata/en-US/description.txt`
- `docs/appstore/metadata/en-US/review_notes.txt`
- `docs/INDUSTRY-LOGIC.md`
- `docs/UPLOAD-AND-PUBLISH-CONTRACT.md`
- `docs/LAUNCH-CONTRACT.md`
- `services/edge/tour-host/public/support.html`
- `services/edge/tour-host/public/features.html`

Outside that knowledge, the model is instructed to say so plainly and offer
`open_support` — never guess, never invent a feature, screen, policy or
number.

iOS keeps an independent, deliberately smaller mirror of the same facts —
`CoachOffline` in `apps/ios/Rendprop/Coach/CoachModel.swift` — for the
offline path (§5). The two are separate files by necessity; a fact that
changes on one side should be considered on the other.

## 7. Privacy

- No photo or video is ever sent, in either direction — `context.listings[]`
  is booleans and counts the client already has (`has_video`, `room_tags`
  count — never the tag text, `photos`, `edits`, `reels`), never the media
  itself and never a room-tag label.
- Message text is never logged, on either the server or the client. Only
  ids, counts, provider/model names, error classes, and (client-side) a
  message-length bucket and an action's closed-enum type reach `Analytics`.
- No marketing copy, listing description, or ad text is ever generated by
  this endpoint — that stays behind the fair-housing-gated tools (AI Photo
  Studio, Reels); the coach only points at them with an action.
- The fair-housing gate itself is untouched and stays server-side in the
  tools that already have it — coach never re-implements or bypasses it.

## 8. Cost / metering

No entitlement check and no monthly allowance (§3 already covers abuse).
Every answered request still calls `recordRoutedAiCost` (feature `"coach"`,
task `coach.chat`) — best-effort, after the reply is already computed, and
never turns a good reply into an error if the org lookup or ledger write
fails.

## 9. Deploy

```
_bridge/tools/deploy-fn.sh - coach
```

plus applying `services/supabase/migrations/0023_coach_routes.sql`, which
seeds the `coach.chat` task into `ai_routes`:

| position | provider  | model            | unit_cents |
|----------|-----------|------------------|-----------:|
| 1        | anthropic | `claude-sonnet-5`  | 2.1 |
| 2        | openai    | `gpt-5.6-terra`    | 2.0 |

Both model ids are already live in `0018_ai_routes.sql` for other tasks —
this migration reuses them, it does not mint new ones. No new
`plan_routing_policy` row: 0018 already covers all six plans, and coach's
own chain is `min_plan: 'free'` on both steps regardless.

> **Not verified in this checkout.** `_bridge/tools/deploy-fn.sh` was not
> found anywhere in this repository (searched the whole tree and every doc
> that mentions it) — it is presumably infra tooling that lives outside this
> checkout. The command above is written exactly as instructed; whoever
> deploys this should confirm the script's actual location/flags before
> running it.

## 10. Files

| File | What |
|---|---|
| `services/supabase/functions/coach/index.ts` | HTTP handler: auth, rate limits, chain, provider call, parse, ledger. |
| `services/supabase/functions/coach/prompt.ts` | Pure. Space vocabulary, system instruction, user-turn builder. |
| `services/supabase/functions/coach/knowledge.ts` | Pure. The customer-service facts (§6) + plan allowance counts. |
| `services/supabase/functions/coach/actions.ts` | Pure. The closed enum (§2), JSON parser/sanitizer, price backstop (§4). |
| `services/supabase/functions/coach/actions_test.ts` | `deno test` — 23 cases. |
| `services/supabase/functions/coach/README.md` | Same material as this file, function-local. |
| `services/supabase/migrations/0023_coach_routes.sql` | Seeds `coach.chat` into `ai_routes` (§9). |
| `apps/ios/Rendprop/Coach/CoachAPI.swift` | Wire types + the closed enum's iOS mirror. |
| `apps/ios/Rendprop/Coach/CoachModel.swift` | Chat state, context-building, offline fallback (§5-6), action routing. |
| `apps/ios/Rendprop/Coach/CoachView.swift` | The chat screen. |
| `apps/ios/RendpropUITests/CoachShot.swift` | UI smoke test + screenshots, both entry points. |

Shared files touched (never created) — see `docs/handoff/coach.md` for every
edit at file:line.

## 11. Known sandbox limitation (not a defect in this change)

`deno check services/supabase/functions/coach/index.ts` reports two
pre-existing errors in `_shared/providers/common.ts` (`TS2315: Type
'Uint8Array' is not generic`, lines 372 and 388) — a TypeScript-lib version
mismatch between this sandbox's pinned Deno (2.1.4 / TS 5.6.2, which predates
generic typed arrays) and whatever the real deploy toolchain uses. This is
NOT introduced by coach: `git status` shows `common.ts` untouched, and
`deno check services/supabase/functions/ai-photo/index.ts` — an already-
shipped function that imports the same provider adapters — fails with the
identical two errors at the identical lines. `coach/index.ts` itself
produces zero errors beyond those two; so do `prompt.ts`, `actions.ts` and
`knowledge.ts` standalone.
