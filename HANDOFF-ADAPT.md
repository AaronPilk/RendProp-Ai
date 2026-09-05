# HANDOFF-ADAPT — provider adapters + the two AI edge functions (agent ADAPT)

Shipped on `ai-router`. **Nothing is deployed and no vendor call has ever been
made from this code** — there are no Kie/Higgsfield/OpenAI/fal credentials in
the build environment. What is verified is what we *build and parse*, offline.

| file | lines | what |
|---|---|---|
| `_shared/providers/types.ts` | 75 | contract §2 verbatim + `ErrorClass` / `DoneState` aliases |
| `_shared/providers/common.ts` | 542 | budgets, `ProviderError`, SSRF-guarded fetch, semaphore, poll loop, R2 persist, signed-URL redaction |
| `_shared/providers/fal.ts` | 348 | queue submit/poll; **byte-identical shipped payloads**; 24 h object lifecycle |
| `_shared/providers/kie.ts` | 337 | market API + legacy Veo; `resultJson` string parsing; substitution check |
| `_shared/providers/higgsfield.ts` | 285 | Seedance proxy + DoP turbo; `nsfw` terminal state; motions map; concurrency 3 |
| `_shared/providers/openai.ts` | 280 | images/edits (no `input_fidelity`), tts-1, whisper word timings, `reasoning.effort:"none"` |
| `_shared/providers/anthropic.ts` | 221 | `/v1/messages`, Sonnet-5 `effort:"low"`, `judge()`, Covered-Model refusal |
| `_shared/providers/gemini.ts` | 144 | shipped payload + `imageConfig.imageSize:"1K"` on 3.x |
| `_shared/providers/elevenlabs.ts` | 98 | with-timestamps TTS, payload unchanged |
| `_shared/providers/chain.ts` | 110 | `resolveChain` + `runChain` (failover rules, `asHttpError`) |
| `_shared/providers/jobtoken.ts` | 88 | the opaque status token that makes one poll route serve every provider |
| `_shared/providers/index.ts` | 52 | `adapterFor()` registry |
| `_shared/providers/providers_test.ts` | 525 | 29 offline tests |
| `_shared/ledger.ts` | +88 | ADDITIVE `recordRoutedAiCost()` / `unitsForStep()` |
| `ai-photo/index.ts`, `ai-video/index.ts` | +573/−118 | wired through the router, flag-gated |
| `set-secrets.sh` | +11 | `HIGGSFIELD_API_KEY_ID` / `_SECRET` names (`KIE_API_KEY` was already listed) |

`deploy-functions.sh` is unchanged: this work adds no function.

---

## 1. Deviations worth knowing

**One header is added on the flag-off path.** Every fal submit now carries
`X-Fal-Object-Lifecycle-Preference: {"expiration_duration_seconds": 86400}`.
The BODY is byte-identical (asserted by four tests); the header is new, on
purpose — fal keeps result objects indefinitely by default and these are
photographs of other people's homes.

**`needs` is never over-constrained.** A capability the caller cannot satisfy
empties the chain, and an empty chain is a 503 on a request that works today:
- `photo.declutter` asks for `mask` only when a `mask_b64` was actually sent
  (the shipped app sends none); otherwise it asks for `prompt-edit`, which is
  what reaches the Gemini step the app relies on.
- video duration is required only when the table advertises it
  (`ADVERTISED_SECONDS`): a 12 s reel asks for `i2v` + `1080p` and no duration.

**A chain of one surfaces the provider's own error.** With the flag off there is
one step, and wrapping its failure in a new 503 would change the status and code
the shipped app already handles. Multi-step exhaustion still throws
`503 "All providers for <task> are unavailable right now."`

**Ledger meta grew.** Routed rows carry `route_id`, `task` and `unit` in
`meta` alongside what was there before. Provider, model, units and unit price
are unchanged on the flag-off path.

**Topaz keeps a price override.** `video.upscale_4k` is one row at 8¢/s, but
Topaz bills per output pixel-frame, so 4K60 is 16¢/s. The drone route passes
`unitCentsOverride: DRONE_TIER_CENTS[tier]` for topaz models so the flag-on
ledger does not under-bill by half. **DB: a second row (or a per-tier task)
would let the override go away.**

**Video declutter (Bria) is deliberately NOT routed** — §3 defines no task and
the repo has no committed price. That path is untouched and stays hardcoded.

## 2. How the async video path stays compatible

`ai-video` submits and returns 202; the app polls `GET /ai-video/status` with
the `status_url` / `response_url` it was handed, verbatim. So:

- **flag OFF, fal step** → those two fields are fal's own URLs, unchanged.
- **flag ON (any provider)** → both fields carry an opaque token addressed to
  our own `/ai-video/status`. `LiveAPIClient` percent-encodes and returns them
  without inspection, so **no iOS change is required**. The status route polls
  through the adapter, `persist()`s the result into our R2, and answers
  `{status:"completed", video_url:<our R2 URL>}`.

The token holds provider, model, vendor job id, vendor poll URL, submit time and
task — no credential, no signed URL, no org id (the org is re-derived from the
caller's JWT). Every adapter re-validates the poll URL against its own host
allowlist before spending our key on it.

## 3. Cross-file needs (not mine to change)

1. **`_shared/r2.ts` should own `presignGet`.** It is now duplicated in
   `ai-voice/index.ts` and `providers/common.ts` for the same reason: r2.ts was
   owned by another agent this cycle.
2. **`ai-voice` should move onto `providers/elevenlabs.ts`** — the adapter
   reproduces its call exactly and `tts.captioned` / `tts.plain` are seeded, but
   `ai-voice/index.ts` is not my file, so it still calls ElevenLabs directly.
3. **Bria video erase needs a committed price** in `APP_AI_UNIT_CENTS` + the
   admin inventory before `video.declutter` can become a route.
4. **`ai-photo` still hard-requires `GEMINI_API_KEY` at the top of the handler.**
   With the router on and a step that is not Gemini, that check would still
   503 a working request on an org with no Gemini key. It is untouched shipped
   code; moving it into the Gemini adapter is a one-line follow-up.
5. **Higgsfield motion uuids are `null` placeholders.** `GET /v1/motions` must
   be called once with real keys and the results pasted into
   `HF_MOTION_FALLBACK`. They are never invented; an unresolved motion is a
   `validation` refusal.

## 4. What is NOT verified

Every vendor HTTP call is unexercised: no fal, Kie, Higgsfield, OpenAI,
Anthropic, Gemini or ElevenLabs request in this branch has been sent to a real
API. Also unexercised: `persist()` against real R2, `resolveChain`'s
database-outage fallback, and the 202 → status → persist round trip end to end.
The 29 tests cover request construction, response parsing, failover rules,
the token, and redaction — all offline.
