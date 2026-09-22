# Copy assist — contract v2 (2026-09-07)

AI prompting for people whose job is marketing, not prompt engineering. Three
routes on one edge function, `ai-copy`:

1. **`POST /ai-copy/script`** — the reel voiceover script, written as marketing
   copy: hook first, the facts that sell in the industry's own words, a close
   that asks for something, and a length that fits the video.
2. **`POST /ai-copy/shotlist`** — the whole reel as one decision: which photo
   plays where, how the camera moves on each one, how long it holds, the caption
   burned across it, and the line of narration that runs under it (§4).
3. **`POST /ai-copy/edit-prompt`** — a rough photo-edit idea ("make the kitchen
   brighter") turned into a real edit instruction with the same density of
   direction a one-tap preset carries.

**The street address is never sent to either route.** There is no address field
in any of the three bodies and there never will be — see §5.

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
POST /ai-copy/shotlist
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

### 1.2 `POST /ai-copy/shotlist` — task `copy.shotlist`

```jsonc
{
  "listing_id": "uuid",          // optional. Org scoping + the AUTHORITATIVE space_type
  "space_type": "real_estate",
  "facts": { /* the SAME AICopyFacts shape as /script, §1.1 */ },
  "photos": [                    // IN THE ORDER THE USER PICKED THEM
    { "id": "asset-uuid",        // required, unique. The ONLY key the answer is matched on
      "room": "Primary Bath",    // optional, <= 40 chars. The label the app already shows
      "caption_hint": "twilight, lights on" }  // optional, <= 120 chars, the photographer's note
  ],
  "target_seconds": 45,          // optional. Default 5 x photos.length. Clamped — see §4.3
  "tone": "warm"                 // warm | punchy | luxury. Unknown/absent -> warm
}
```

```jsonc
{
  "shots": [
    { "photo_id": "asset-uuid",
      "order": 1,                     // 1-based, the order the clips are stitched in
      "motion": "push_in",            // ai-video/motion.ts REEL_MOTIONS — see §4.2
      "room": "Front Exterior",       // the caller's own label, echoed ("" if none was sent)
      "on_screen_text": "5 BED · 3.5 BATH",  // burned into the clip. "" is normal — §4.4
      "seconds": 6,                   // integer, 2..12, sums to the reel length — §4.3
      "voice_line": "Water on three sides." }
  ],
  "script": "…",                 // the voice lines joined — same rules as /script
  "characters": 288,             // script.length
  "estimated_seconds": 26.2,     // characters ÷ 11 — SPEECH, not video (see below)
  "model": "claude-sonnet-5"
}
```

`characters` and `estimated_seconds` mean exactly what they mean on `/script`:
how long the **spoken** script is. The **reel's** own length is
`sum(shots[].seconds)`, which always equals the clamped `target_seconds`. The
client shows one against the other — a script that estimates longer than the
video is the frozen last frame of §2 again.

At most **20 shots**; more is a `400` naming the limit rather than a reel
silently missing the photos the user picked. A photo with no `id`, or a repeated
`id`, is dropped: it could never be matched to a line, and every planned
`photo_id` is echoed in the response so a client can see what happened.

### 1.3 `POST /ai-copy/edit-prompt` — task `copy.photo_prompt`

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

## 4. The shot list (`/shotlist`)

A reel today is: tap N photos → each becomes a five-second clip under ONE fixed
server prompt (`ai-video/index.ts` `reelPrompt()`, "one slow, subtle, grounded
push-in") → stitch in tap order → lay a separately-written voiceover over the
top. Every clip moves identically, the order is whichever order a thumb moved
in, and the narration was written without knowing what is on screen when it
plays.

`/shotlist` decides all of it at once, and the split is the design:

* **The server owns the structure** — order, camera move, seconds. Those are
  editorial rules; they must be deterministic, they must be renderable, and a
  model that hallucinates a `photo_id` must never be able to reorder somebody's
  reel or ask for a 7.5-second clip.
* **The model owns the words** — the caption and the narration, written against
  a shot list it can see. That is the whole reason this is one call and not
  three.

Everything below is pure and lives in
`services/supabase/functions/ai-copy/shotlist.ts`, asserted in
`shotlist_test.ts`. **The plan is computed before a token is spent**, so an
unrenderable request is clamped up front rather than discovered by the provider
after the user has paid.

### 4.1 The order is a decision

Each `room` label is classified into one beat class (first pattern wins, so
"Primary **Bath**" is a bathroom, not the primary suite). Every class has exactly
one **tour rank** — the order a listing video actually walks a property, public
to private:

```
exterior_front 10 · entry 20 · hero_living 30 · kitchen 40 · dining 50
primary 60 · bath 70 · bed 80 · work 90 · detail 95 · exterior_rear 100
```

One rank per class is the point: a kitchen and a great room are both "position
two" candidates and only one can have it. Then:

1. **The opener** is the best establishing shot available — the front exterior,
   else the great room, else the kitchen. The opening *frame* has to earn the
   next two seconds, which is the rule §1.1's instruction already states for the
   opening *line*.
2. **The closer** is the best CTA frame available — the yard or pool, else a
   second exterior, else the primary suite or the great room. The end card sits
   over it, so it wants to be wide and calm; a bathroom detail is not a close.
3. **The middle** is tour rank, then the user's own tap order inside a rank.

Tap order as the tiebreak is deliberate: where the rules are indifferent the
user's sequence wins, so the plan is deterministic **and** still recognisably the
reel they laid out. Photos with no `room` at all keep tap order entirely — the
server has no opinion it can defend, so it does not invent one.

### 4.2 The motion belongs to the shot

`motion` is one of the eight moves in **`ai-video/motion.ts` `REEL_MOTIONS`**,
which owns the render contract: `push_in`, `pull_back`, `tilt_up`, `tilt_down`,
`orbit_left`, `orbit_right`, `rack_focus`, `static_parallax`. `ai-copy` mirrors
that list and `shotlist_test.ts` asserts the two are the same set (and the same
move *families*) by importing the module — a move `ai-video` cannot render is a
clip that silently falls back to the fixed push-in, which is the bug this route
exists to fix. The aerial-only spellings (`orbit`, `rise_reveal`) are **not**
returned here, so the `motion` in the response is always the move that was
rendered rather than one aliased on the way in.

Each beat class has an ordered preference (an exterior arrives with a `push_in`,
a great room `orbit_left`s to prove it is a real volume, a detail gets the
`rack_focus` that exists for it, the closer `pull_back`s). Then a forward repair
guarantees the invariant:

> **No two consecutive shots share a move family** — and therefore never share a
> move.

Families are `ai-video`'s own grouping by what physically moves (dolly /
vertical / lateral / optical). "Not the same move" would allow `orbit_left`
followed by `orbit_right`, which is two arcs back to back and reads exactly as
monotonous as two push-ins. The repair only ever changes the *later* shot, so
shot 1 — the one that sets the reel up — is never disturbed by a decision made
about shot 7.

**Unlabelled photos get a rotation, not a preference.** `detail` is the absence
of a room, not a kind of one, so if every unlabelled shot drew from one list a
reel of untagged photos — the common case — would alternate two moves forever:
the family rule satisfied, and still a slideshow with a longer period. Detail
shots therefore take their preference from a four-entry rotation walked by shot
index, each entry starting in a different family, which is the mechanism
`ai-video/motion.ts` `chooseReelMotion()` uses for the same problem. An
eight-shot unlabelled reel reaches all four families.

### 4.3 Pacing

`seconds` is per shot, and shots do not want to be equal: a hero room needs a
beat to land, a detail cut is over before you have finished looking at it. But
every value has to be something the provider will actually take — the Seedance
duration enum is the strings `"2".."12"`, and `/ai-video/reel-clip` already
clamps to it — and the total has to be the reel that was asked for.

```
weights   open 1.15 · hero 1.15 · detail 0.8 · close 1.35
seconds   = apportion(target, weights, min 2, max 12)   // integers, sums EXACTLY
```

`apportion()` is largest-remainder (Hamilton) apportionment, bounded at both
ends and stable on index, so the answer never depends on a sort order.

**`target_seconds` is clamped, not refused.** With `n` shots the only reels that
exist are `2n .. 12n` seconds, so a 3-photo/60-second request becomes 36 seconds
rather than a `400` the user cannot act on. The default is `5 × photos.length`,
the reel the app makes today. `sum(shots[].seconds)` always equals the clamped
target.

The **character** budget is apportioned the same way, in proportion to those
seconds, so a six-second hero gets three times the words of a two-second cut and
the lines sum to the script budget *by construction* — the join can never push
the script over and cost the closing CTA its last words to a trim. A shot
budgeted under 25 characters is told it is a quick cut and that an empty line is
the right answer; the reel plays fine under the previous line.

### 4.4 On-screen text

The realtor-reel idiom, and it has real rules: burned into the clip, read at
arm's length in about a second, usually muted. **At most five words and 28
characters, upper case, no sentence and no terminal punctuation** —
"5 BED · 3.5 BATH", "CHEF'S KITCHEN", "$1.5M", "2,400 SQ FT". Separators (`·`)
are punctuation, not words, so the canonical caption is four words and fits.
Markdown, emoji and anything outside the idiom's own character set are dropped
rather than transliterated.

**`""` is a normal answer.** A caption on every clip is noise; the shots that
carry a fact get one. And a caption **never names the address**: an invented
street address burned across a frame is worse than a spoken one (legible, and
held for the whole shot), and scrubbing one would leave a caption reading
"ADDRESS", so a caption containing an address *or* the `{address}` token is
dropped entirely. The narration still names the property (§5).

### 4.5 The words match the picture

Shots in the model's answer are matched to the plan **by `photo_id`, never by
position**. If a model renumbers, reorders or drops an entry, position matching
would slide every line one picture to the left and the reel would confidently
narrate the wrong rooms. An `id` we never sent is dropped; a shot the answer
never mentions keeps its planned picture and plays silent.

An answer with no narration at all is **unusable**, not a refusal: it takes the
retry and then `EMPTY_REFUSAL`, because a shot list with no script is not this
route's deliverable.

## 5. The `{address}` rule — a privacy line, not a formatting choice

**The street address is never sent to this function.** There is no field for it
on any of the three routes.
This is the same line `ai-video`'s aerial route already holds: it accepts a
`region` ("Sausalito, CA"), `cleanRegion()` drops anything that starts like a
house number, and its `address` field is documented as accepted-and-ignored.

Instead the model is instructed to write the literal token **`{address}`**
wherever the property should be named, at most once. **The client substitutes it
on-device**, where the address already lives. The property gets named in the
finished voiceover and no vendor ever receives the address of somebody's home.

On `/shotlist` the token appears in a `voice_line` (and therefore in `script`)
and **never in an `on_screen_text`** — §4.4. The instruction asks for it at most
once in a reel; the client substitutes **every** occurrence, so a model that
writes it twice names the property twice.

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

## 6. Fair housing — both directions, fail closed

| | Route | Function | When |
|---|---|---|---|
| **Input** | `/script` | `assertMarketingCopy()` | before a token is spent |
| **Input** | `/shotlist` | `assertMarketingCopy()` | before a token is spent |
| **Input** | `/edit-prompt` | `assertFairHousing()` | before a token is spent |
| **Output** | all three | the same function again | before the response is built |

On `/shotlist` the **input** the gate reads is the facts *plus every room label
and photographer's note* — those are the caller's own words and they go straight
into the prompt, so they are part of the brief.

The **output** gate reads a single *compliance surface*: the script joined with
**every `on_screen_text`**. A caption is model-authored copy that gets published
over the video, so it is checked exactly as the narration is — one poisoned
caption costs the whole attempt, takes the one retry, and is then refused. The
join uses `·` rather than whitespace, deliberately: every rule in
`_shared/fairhousing.ts` joins its words with `\s+`, and `\s` matches a newline,
so a whitespace separator could *manufacture* a violation across a seam that
exists in neither half. Nothing inside a line is altered, so nothing can hide in
one either.

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

## 7. Rate limits (burst only — no monthly meter, no plan gate)

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

## 8. Cost / metering

Every success writes ONE org-scoped `cost_ledger` row via `recordRoutedAiCost()`
— `feature: "copy_assist"`, `job_id: NULL`, the provider/model/price of the step
that **actually ran**, and `meta: { kind, target_seconds, attempts }` where
`kind` is `reel_script | shotlist | photo_prompt`. The `shotlist` row carries one
extra bounded integer, `shots`.

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

**Known under-report:** a compliance retry (§6) runs the chain twice but records
one unit, because `unitsForStep()` returns a hardcoded `1` for unit `"call"`.
`meta.attempts` carries the truth so the gap is auditable rather than invisible;
faking it with `unitCentsOverride` would put a wrong **price** in
`unit_cost_cents`, which the admin provider inventory reads as one.

## 9. Routing

Migrations `0027_copy_routes.sql` (`copy.reel_script`, `copy.photo_prompt`) and
`0028_shotlist_route.sql` (`copy.shotlist`) seed all three tasks as siblings of
`text.listing_copy` — the same shape (one bounded text answer, no image either
way; `/shotlist` sends ids, room labels and typed facts, never a photo), so the
same three vetted providers, verbatim:

| position | provider  | model             | unit_cents |
|---------:|-----------|-------------------|-----------:|
| 1 | anthropic | `claude-sonnet-5` | 2.1 |
| 2 | openai    | `gpt-5.6-terra`   | 2.0 |
| 3 | gemini    | `gemini-3.8-flash`| 0.9 (estimated) |

Capabilities are `{text,compliant}` — `text.listing_copy`'s set **minus
`vision`**, because neither route ever sends an image and `ctx.needs` is a hard
AND: claiming a capability you do not use costs you your fallbacks.

`copy.shotlist` gets its own task rather than a flag on `copy.reel_script`
because an operator would want to price or fail it over separately: its answer is
one caption plus one line per shot (bounded at ~1,600 output tokens against ~700
for a script), so it is the largest reply this function produces. **The prices
above are inherited from a shorter reply and are therefore a floor, not a
measurement** — `unit = 'call'`, and 0028 writes that caveat onto the rows
themselves rather than leaving it in a commit message. Confirm against real
provider bills before `copy.shotlist` is used to set a COGS ceiling.

**No `note='legacy'` row** for any of the three, following
`0023_coach_routes.sql` rather than the
`photo.*` rows: these are brand-new tasks with no shipped behaviour for a legacy
row to describe. So with the flag off `resolveRoute()` answers `[]`, and
`ai-copy/index.ts`'s `chooseChain()` substitutes a hardcoded **two-step**
fallback (anthropic then openai, byte-identical to positions 1 and 2) rather
than the single-step `resolveChain()` fallback — a brand-new feature must not be
left with no cross-provider failover precisely while the master flag is off,
which is all the time today. `runChain()` still drives it and still reports every
attempt to the circuit breaker.

## 10. Client notes (iOS)

* Substitute `{address}` before anything is spoken or displayed (§5).
* Show `characters` / `estimated_seconds` against the reel's real length. A
  script that estimates longer than the video will freeze the final frame (§2) —
  the user should trim rather than ship it.
* `POST /ai-voice/tts` still enforces its own 1,000-character cap. A script from
  this route is always inside it; a script the user has since edited may not be.
* `403` means the signed-in member's role is `marketing`. `429 rate_limited` is
  the burst limiter (§7). `400 unsupported_edit` names a phrase in **their own**
  brief (§6); `502 upstream` after a normal-looking brief is ours, not theirs.
* `/shotlist`: send the photos **in tap order** — the server reorders them and
  `shots[].order` is the order to stitch. Render `shots[].on_screen_text` burned
  into the clip (skip the empty ones), and pass `shots[].motion` and
  `shots[].seconds` straight to `POST /ai-video/reel-clip`. `ai-video`'s
  `REEL_MOTION_LABEL` is the human caption for a move, so the app never needs its
  own copy of the enum.
* `/shotlist` returns a reel whose length is `sum(shots[].seconds)`. That is the
  clamped length, which may not be the `target_seconds` that was asked for (§4.3)
  — show what came back, not what was requested.
* `/ai-photo` `edit:"improve_prompt"` still works unchanged for shipped builds
  and now shares this function's instruction. New clients should call
  `/ai-copy/edit-prompt`, which additionally meters, scopes by listing and
  writes a ledger row.

## 11. Files

| File | What |
|---|---|
| `services/supabase/functions/ai-copy/index.ts` | HTTP handler: auth, role, burst limiter, routing, provider calls, ledger. |
| `services/supabase/functions/ai-copy/prompt.ts` | **Pure, zero imports.** Vocabulary, both instructions, the budget arithmetic, JSON extraction, cleaning. Imported by `ai-photo`. |
| `services/supabase/functions/ai-copy/guard.ts` | Pure-ish. The input→generate→output→retry→refuse ordering (§6). |
| `services/supabase/functions/ai-copy/shotlist.ts` | **Pure**, imports only `prompt.ts`. The planner: rooms → beats → order, motion, pacing; the caption clamp; the instruction; the answer parser (§4). |
| `services/supabase/functions/ai-copy/prompt_test.ts` | `deno test` — 33 cases. |
| `services/supabase/functions/ai-copy/guard_test.ts` | `deno test` — 14 cases. |
| `services/supabase/functions/ai-copy/shotlist_test.ts` | `deno test` — 33 cases, two of which assert parity with `ai-video/motion.ts`. |
| `services/supabase/migrations/0027_copy_routes.sql` | Seeds `copy.reel_script` + `copy.photo_prompt` into `ai_routes` (§9). |
| `services/supabase/migrations/0028_shotlist_route.sql` | Seeds `copy.shotlist` into `ai_routes` (§9). |

Files edited, not created:

| File | Edit |
|---|---|
| `services/supabase/functions/ai-photo/index.ts` | `edit:"improve_prompt"` is now a thin forward to `editPromptInstruction()`; the caps re-export the shared constants. No client-visible change. |
| `services/supabase/functions/ai-voice/index.ts` | Routing + one `cost_ledger` row per voiceover (§8). No behaviour, limit or response change. |
| `docs/AI-ROUTER-CONTRACT.md` | §3 gains `copy.reel_script` and `copy.photo_prompt`. |

**Outstanding, and deliberately not done here:** `docs/AI-ROUTER-CONTRACT.md` §3
does not yet list `copy.shotlist`. That file is owned elsewhere and was left
untouched rather than edited across a boundary while another change was in
flight; the task is seeded, routed and documented in §9 above, and §3 of the
router contract needs the one-line entry to match.

`ai-copy/shotlist.ts` **reads** `ai-video/motion.ts` only in its tests, and only
to assert the move vocabulary agrees; there is no import between the two
functions at runtime, so neither deploy depends on the other.

## 12. Deploy

Nothing in this change was deployed. Deploying it means applying
`services/supabase/migrations/0027_copy_routes.sql` **and**
`services/supabase/migrations/0028_shotlist_route.sql`, and deploying three
functions: `ai-copy` (new), `ai-photo` and `ai-voice` (both edited).

`/ai-copy/shotlist` returns `motion` values that only mean something to a
version of `ai-video` that knows `REEL_MOTIONS` — deploy `ai-video` first, or
together with `ai-copy`. Deployed the other way round, a shot list would name
moves the reel route would `400` on. The parity test catches a divergence in the
source; it cannot catch one in a deploy order.

`ai-photo` **must** be redeployed together with `ai-copy`, or at least after it:
it now imports `../ai-copy/prompt.ts`, and while that resolves at bundle time
exactly the way `../_shared/…` does, a deploy that does not include the file
would fail at bundle rather than at runtime — the loud failure `ai-chapters`'
static-import note asks for.

No new secrets. `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are already set;
`GEMINI_API_KEY` (also already set) is only used if an operator enables the
seeded gemini step.
