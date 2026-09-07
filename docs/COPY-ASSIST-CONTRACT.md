# Copy assist — contract v1 (2026-09-07)

AI prompting for people whose job is marketing, not prompt engineering. Two
routes on one edge function, `ai-copy`:

1. **`POST /ai-copy/script`** — the reel voiceover script, written as marketing
   copy: hook first, the facts that sell in the industry's own words, a close
   that asks for something, and a length that fits the video.
2. **`POST /ai-copy/edit-prompt`** — a rough photo-edit idea ("make the kitchen
   brighter") turned into a real edit instruction with the same density of
   direction a one-tap preset carries.

**The street address is never sent to either route.** There is no address field
in either body and there never will be — see §4.

## 0. Why this exists

The app's owner asked for *"AI prompting installed for like describing how to
change an image, describing a script for the reel so that way prompting is
perfect."*

Both halves are one complaint, and it is measurable in the code. `ai-photo`
builds a **preset** edit from about sixty words of engineered direction
(`RE_PROMPTS` + `STAGE_LOCK` + `RE_STAGE_STYLES`): what changes, what stays
identical, how the light and the materials must behave. It builds a **custom**
edit with `customPrompt()` — one sentence wrapped around whatever the user
typed. The user's raw words carry the whole semantic load, so the person who
tapped a button got a visibly better result than the person who described what
they actually wanted. `/ai-copy/edit-prompt` closes that asymmetry, and the reel
script is the same fix applied to the voiceover.

## 1. Endpoints

```
POST /ai-copy/script
POST /ai-copy/edit-prompt
Authorization: Bearer <user JWT>       (owner auth — same as /ai-photo, /ai-voice)
X-Org-Id: <uuid>                       (optional, same as everywhere else)
```

`marketing` is read-only and gets a `403`, the same role gate `ai-photo` and
`ai-voice` apply. Everything else about auth, CORS and the `{ error, code }`
error envelope is identical to the neighbouring functions.

### 1.1 `POST /ai-copy/script` — task `copy.reel_script`

```jsonc
{
  "listing_id": "uuid",          // optional. Org scoping + the AUTHORITATIVE space_type
  "space_type": "real_estate",   // real_estate | venue | restaurant | retail | fitness | other
  "facts": {
    "beds": 4, "baths": 3, "sqft": 2400,
    "price_label": "$1,500,000", // ALREADY FORMATTED by the client, never a raw number
    "tagline": "Water on three sides",
    "region": "Sausalito, CA",   // city/state ONLY — never a street address
    "details": { "Capacity": "220 seated" }   // the SpaceType.detailFields the owner filled in
  },
  "room_tags": ["Entry", "Kitchen", "Primary"],  // IN WALK ORDER — order is the value
  "photo_count": 6,
  "target_seconds": 30,          // 5 x clip count, so 10-45 in practice
  "tone": "warm"                 // warm | punchy | luxury. Unknown/absent -> warm
}
```

```jsonc
{
  "script": "…",                 // plain text, ready for POST /ai-voice/tts
  "characters": 288,             // script.length — the number ai-voice caps at 1000
  "estimated_seconds": 26.2,     // characters ÷ 11, one decimal
  "model": "claude-sonnet-5"     // whichever step of the chain actually answered
}
```

### 1.2 `POST /ai-copy/edit-prompt` — task `copy.photo_prompt`

```jsonc
{
  "listing_id": "uuid",          // optional, same meaning as above
  "space_type": "real_estate",
  "rough": "make the kitchen brighter",   // <= 300 chars, required
  "room_hint": "Kitchen"                  // optional, <= 60 chars
}
```

```jsonc
{
  "prompt": "…",                 // <= 400 chars, send it back as ai-photo edit:"custom"
  "model": "claude-sonnet-5"
}
```

The returned prompt is meant to be sent to `POST /ai-photo` as
`edit: "custom", prompt: <this>`. It deliberately does **not** carry the
architecture lock or the fair-housing guardrails: `ai-photo` appends
`guardrailsFor(edit)` and its own `LOCK` to every prompt server-side, canned or
free-text, and producing them here too would spend tokens writing text that is
about to be duplicated — a doubled instruction is a model that weights it twice
and starts refusing legitimate edits.

## 2. The character budget (length is a hard constraint)

The reel stitcher lets **video length win**: if the voiceover runs longer than
the stitched clips, the last video frame is **held** for the remainder rather
than truncating the speaker (`FlythroughDetailView.swift`,
`stitch(clips:renderSize:captions:voiceover:captionStyle:output:)`). So an
over-long script is not "a bit long" — it is a reel that ends on a frozen still
while a voice keeps talking.

The rate comes from a number this repo already committed to. `/ai-voice/tts`
refuses anything over 1,000 characters and says why: *"a 1,000-character script
is already about 90 seconds of speech."*

```
1000 chars ÷ 90 s = 11.1 chars/s   →   CHARS_PER_SECOND = 11
char_budget = min(1000, round(target_seconds × 11))
```

11 rather than 11.1 is deliberate: rounding the rate **down** asks for a slightly
shorter script, and short is free while long freezes a frame.

| `target_seconds` | clips | asked for | note |
|---:|---:|---:|---|
| 10 | 2 | 110 chars | the shortest reel the app makes |
| 30 | 6 | 330 chars | typical |
| 45 | 9 | 495 chars | the contract's longest |
| 90 | — | 990 chars | where the rate meets the ceiling |
| 91+ | — | **1000 chars** | the clamp, = `ai-voice`'s `MAX_TEXT_CHARS` |

`target_seconds` is itself clamped to 5-90 before the multiply, so the product
can never exceed 1,000; the clamp at 1,000 is belt-and-braces and is asserted
separately (`prompt_test.ts`). The **returned** script is trimmed to the same
budget — at the last sentence end inside it, else the last word boundary, never
mid-word and never with an ellipsis (a TTS engine reads "…" as a pause into
silence).

`characters` and `estimated_seconds` come back so the client can show the fit
against the reel's real length before the user pays for a voiceover.

## 3. Room tags are the spine

`room_tags` is sent **in walk order** and that order is the entire value: it is
what makes the narration match what is on screen. The server dedupes and bounds
the list (24 max, 40 chars each) but **never sorts it**.

An empty or absent `room_tags` degrades explicitly, not silently: the model is
told no walk order was captured and is instructed **not** to name specific rooms,
because it would be guessing at what is on screen. The user turn says
`(none captured)` rather than omitting the line.

## 4. The `{address}` rule — a privacy line, not a formatting choice

**The street address is never sent to this function.** There is no field for it.
This is the same line `ai-video`'s aerial route already holds: it accepts a
`region` ("Sausalito, CA"), `cleanRegion()` drops anything that starts like a
house number, and its `address` field is documented as accepted-and-ignored.

Instead the model is instructed to write the literal token **`{address}`**
wherever the property should be named, at most once. **The client substitutes it
on-device**, where the address already lives. The property gets named in the
finished voiceover and no vendor ever receives the address of somebody's home.

The client MUST replace `{address}` before sending the script to
`/ai-voice/tts`. If the listing has no address to substitute, delete the token
and the sentence around it rather than speaking it aloud.

Two server-side backstops:

* Near-misses are normalised to the exact token — `{{address}}`, `[address]`,
  `{Address}`, `{the address}`, `{property address}` all become `{address}`.
* Anything **shaped like** a street address in the model's answer is replaced by
  the token. The request contains nothing to copy an address from, so any street
  address in the output is invented, and an invented house number spoken over
  the owner's own footage is worse than none. Ordinary numbers ("2,400 square
  feet", "seats 220 guests", "2 full baths") are untouched.

`facts.region` is also refused if it starts like a house number, exactly as
`ai-video` does.

## 5. Fair housing — both directions, fail closed

| | Route | Function | When |
|---|---|---|---|
| **Input** | `/script` | `assertMarketingCopy()` | before a token is spent |
| **Input** | `/edit-prompt` | `assertFairHousing()` | before a token is spent |
| **Output** | both | the same function again | before the response is built |

Both gates are scoped by the **LISTING's** `space_type` (`listingSpaceType()`
with the caller's own RLS-bound client), never by the request's claim — a
request must not be able to loosen its own gate by claiming to be a bar. No
`listing_id`, or a row the caller cannot see, means `null`, and `null` is the
stricter housing gate: this fails closed.

**Input** refusals are `400 unsupported_edit` naming the phrase and how to
rephrase. That is the one refusal the user can act on — these are their own
words.

**Output** refusals are never shown to the user as their error. This is
`ai-chapters` principle 3: *"the offending text was written by a model, not by
the agent — there is nothing for them to fix."* `ai-chapters` drops an offending
chapter description and keeps the chapter; a script has no sub-part to drop, so
the equivalent here is:

1. the answer is checked; if it trips, it is discarded (never returned, never
   logged — only the rule **category** reaches the log, never the phrase);
2. the whole chain is run again, once, with a corrective line added that
   restates the rule and never quotes the rejected text;
3. if the second answer also trips, the request is refused with `502 upstream`
   and an honest message that does not blame the user and does not quote what
   the model wrote.

A provider failure is not a compliance failure and propagates untouched — a
`503` from an exhausted chain must not be re-labelled as something the user's
words caused.

## 6. Rate limits (burst only — no monthly meter, no plan gate)

`aicopy:<org>`, **60 requests / 5 minutes / org**, durable
(`_shared/ratelimit.ts`). Never refunded, because it is abuse protection rather
than a paid allowance.

There is **no monthly meter, no `plan_entitlements` column and no migration
against it**. This is the shape `ai-photo`'s helper modes already use
(`guardHelper`, `aiphotohelp:<org>`, 120 / 5 min, no monthly meter) and it is
the right shape for a sub-2¢ text call that generates no image and no video.
Copy assist is free on every plan; `min_plan: 'free'` on every seeded row
controls **routing** only.

The org's plan is still read (`entitlementFor()`, the non-throwing variant) for
one purpose: the router's policy, since starter routes cheapest and pro routes
best. A degraded plan lookup routes as `free` and never fails the request.

## 7. Cost / metering

Every success writes ONE org-scoped `cost_ledger` row via `recordRoutedAiCost()`
— `feature: "copy_assist"`, `job_id: NULL`, the provider/model/price of the step
that **actually ran**, and `meta: { kind, target_seconds, attempts }` where
`kind` is `reel_script | photo_prompt`.

`meta` lands in a durable row every member of the org can read under the
org-ledger RLS policy, so it carries only closed-vocabulary and bounded values —
never the brief, never the script (the same argument `coach/index.ts` makes about
`screen`).

**This is new visibility.** `ai-photo`'s existing helper modes (`suggest`,
`improve_prompt`) write **no ledger row at all** today, so their spend — small
per call, unbounded per month — is invisible to `GET /admin/spend` and to the
per-org COGS ceiling. `/ai-copy` is the first assist route that is visible. The
bigger hole in the same class was `/ai-voice/tts` (22¢ per 1k characters, no
ledger row); it is routed and metered in this same wave — see
`docs/VOICEOVER-CONTRACT.md` and `ai-voice/index.ts`'s COST VISIBILITY header.

**Known under-report:** a compliance retry (§5) runs the chain twice but records
one unit, because `unitsForStep()` returns a hardcoded `1` for unit `"call"`.
`meta.attempts` carries the truth so the gap is auditable rather than invisible;
faking it with `unitCentsOverride` would put a wrong **price** in
`unit_cost_cents`, which the admin provider inventory reads as one.

## 8. Routing

Migration `0027_copy_routes.sql` seeds both tasks as siblings of
`text.listing_copy` — the same shape (one bounded text answer, no image either
way), so the same three vetted providers, verbatim:

| position | provider  | model             | unit_cents |
|---------:|-----------|-------------------|-----------:|
| 1 | anthropic | `claude-sonnet-5` | 2.1 |
| 2 | openai    | `gpt-5.6-terra`   | 2.0 |
| 3 | gemini    | `gemini-3.8-flash`| 0.9 (estimated) |

Capabilities are `{text,compliant}` — `text.listing_copy`'s set **minus
`vision`**, because neither route ever sends an image and `ctx.needs` is a hard
AND: claiming a capability you do not use costs you your fallbacks.

**No `note='legacy'` row**, following `0023_coach_routes.sql` rather than the
`photo.*` rows: these are brand-new tasks with no shipped behaviour for a legacy
row to describe. So with the flag off `resolveRoute()` answers `[]`, and
`ai-copy/index.ts`'s `chooseChain()` substitutes a hardcoded **two-step**
fallback (anthropic then openai, byte-identical to positions 1 and 2) rather
than the single-step `resolveChain()` fallback — a brand-new feature must not be
left with no cross-provider failover precisely while the master flag is off,
which is all the time today. `runChain()` still drives it and still reports every
attempt to the circuit breaker.

## 9. Client notes (iOS)

* Substitute `{address}` before anything is spoken or displayed (§4).
* Show `characters` / `estimated_seconds` against the reel's real length. A
  script that estimates longer than the video will freeze the final frame (§2) —
  the user should trim rather than ship it.
* `POST /ai-voice/tts` still enforces its own 1,000-character cap. A script from
  this route is always inside it; a script the user has since edited may not be.
* `403` means the signed-in member's role is `marketing`. `429 rate_limited` is
  the burst limiter (§6). `400 unsupported_edit` names a phrase in **their own**
  brief (§5); `502 upstream` after a normal-looking brief is ours, not theirs.
* `/ai-photo` `edit:"improve_prompt"` still works unchanged for shipped builds
  and now shares this function's instruction. New clients should call
  `/ai-copy/edit-prompt`, which additionally meters, scopes by listing and
  writes a ledger row.

## 10. Files

| File | What |
|---|---|
| `services/supabase/functions/ai-copy/index.ts` | HTTP handler: auth, role, burst limiter, routing, provider calls, ledger. |
| `services/supabase/functions/ai-copy/prompt.ts` | **Pure, zero imports.** Vocabulary, both instructions, the budget arithmetic, JSON extraction, cleaning. Imported by `ai-photo`. |
| `services/supabase/functions/ai-copy/guard.ts` | Pure-ish. The input→generate→output→retry→refuse ordering (§5). |
| `services/supabase/functions/ai-copy/prompt_test.ts` | `deno test` — 33 cases. |
| `services/supabase/functions/ai-copy/guard_test.ts` | `deno test` — 12 cases. |
| `services/supabase/migrations/0027_copy_routes.sql` | Seeds both tasks into `ai_routes` (§8). |

Files edited, not created:

| File | Edit |
|---|---|
| `services/supabase/functions/ai-photo/index.ts` | `edit:"improve_prompt"` is now a thin forward to `editPromptInstruction()`; the caps re-export the shared constants. No client-visible change. |
| `services/supabase/functions/ai-voice/index.ts` | Routing + one `cost_ledger` row per voiceover (§7). No behaviour, limit or response change. |
| `docs/AI-ROUTER-CONTRACT.md` | §3 gains `copy.reel_script` and `copy.photo_prompt`. |

## 11. Deploy

Nothing in this change was deployed. Deploying it means applying
`services/supabase/migrations/0027_copy_routes.sql` and deploying three
functions: `ai-copy` (new), `ai-photo` and `ai-voice` (both edited).

`ai-photo` **must** be redeployed together with `ai-copy`, or at least after it:
it now imports `../ai-copy/prompt.ts`, and while that resolves at bundle time
exactly the way `../_shared/…` does, a deploy that does not include the file
would fail at bundle rather than at runtime — the loud failure `ai-chapters`'
static-import note asks for.

No new secrets. `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are already set;
`GEMINI_API_KEY` (also already set) is only used if an operator enables the
seeded gemini step.
