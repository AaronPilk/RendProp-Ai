# Agent-reel output headroom and synthetic Apple fixtures

Measurement base: `2750953ced2f03702f6e101d3e23c50ae90e526b`. This unit changes
only offline measurement tools and two tests. **No route, model, token budget,
pricing, invariant, provider request, deployment or Apple operation changed.**

## Decision in plain language

The current700-token setting is not demonstrated sufficient. A normal full
12-window UUID example takes521 `o200k_base` tokens; other legal inputs need
997–3509 before reasoning. Those are exact counts for the named encoding,
**not verified Astra tokens**. The public pinned tokenizer does not map
`gpt-6-astra`, and no local measurement can establish its hidden reasoning use.

The strict database headroom gate remains unchanged and red. A successful
measurement command means the measurements and negative controls executed;
it does not mean the current700-token gate passed.

## Actual contract and methodology

- `ai-copy/agentreel.ts:105–117`:180-second clip,200 transcript phrases,200
  code units per phrase,12 windows. The fixture reaches all maxima through
  the real `cleanTranscript` and `planWindows`, with20 distinct offered photos.
- `ai-copy/shotlist.ts:244–276`: each photo ID can contain64 arbitrary cleaned
  UTF-16 code units. `shotlist.ts:150,219–224`: retained captions allow28 code
  units; a US-facing UI does not restrict that wire format to ASCII.
- `ai-copy/agentreel.ts:363`: the **generated** object contains only
  `window_id`, `photo_id`, and `on_screen_text` assignments.
- `ai-copy/agentreel.ts:453–484`: the server adds times, motion, room labels
  and coverage; `ai-copy/index.ts:864–872` returns the enriched HTTP response.
  Charging the model for that entire returned HTTP EDL would be wrong.
- `_shared/providers/openai.ts:175–176,201–203`: row parameters win, with
  `json_object` mode rather than a strict bounded schema. Lines215–228 reject
  incomplete Responses envelopes. Long samples here demonstrate demand,
  **not** that the provider can generate beyond its configured cap.

The harness imports those actual planner/parser/prompt functions. Every row
must parse into12 windows and preserve the expected assignments/captions;
server fallback is not counted as a successful full assignment. Before/after
hashes bind ten production/test files, including the unchanged migration and
invariant. It never calls an AI endpoint.

Tokenizer: official `tiktoken==0.14.0`, `o200k_base`,199998 mergeable ranks,
all256 byte fallback tokens verified. Its model resolver raises `KeyError`
for Astra. Version and cache hashes are in the JSON receipt. The public BPE
asset SHA-256 is
`446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d`.
See [official release](https://github.com/openai/tiktoken/releases/tag/0.14.0)
and [pinned model mapping](https://github.com/openai/tiktoken/blob/4e71bbe0c078468e00fefbf94b39849389f346e5/tiktoken/model.py).

## Measured results

All rows use the actual180s/200-phrase/12-window planner. Input counts measure
the actual two prompt strings with synthetic facts/room hints, not complete
provider framing or a proved maximum over every permissible input field.

| Synthetic output shape | Model UTF-8 bytes | Model proxy tokens | HTTP proxy tokens | Prompt-text proxy tokens |
|---|---:|---:|---:|---:|
|12 short IDs, empty captions|666|209|506|2158|
|One assignment accepted; other11 remain face|47|16|451|2158|
|12 UUID IDs,28-character captions|1432|521|818|2478|
|12 random ASCII64 IDs,28-character captions|1756|997|1294|2989|
|12 BMP64 IDs,28 BMP-letter captions|3916|3437|3734|5858|
|12 quote-heavy64 IDs|2500|1229|1526|2458|
|12 control-character64 IDs,28 BMP captions|6268|3509|3806|2797|
|Same BMP EDL +100 whitespace pairs|4116|3487|3734|5858|
|Same BMP EDL +1000 whitespace pairs|5916|3937|3734|5858|
|Same BMP EDL +10000 whitespace pairs|23916|8437|3734|5858|
|Same BMP EDL + ignored10000-character field|13929|13440|3734|5858|

The16-token sparse reply is an accepted example, **not** the instructed full
12-assignment response and not a proved absolute minimum.3509 is the largest
measured canonical sample, **not** a proved maximum over all BPE strings.

For a canonical JSON serialization containing exactly those bounded fields,
the exact maximum is6268 bytes:

```text
14 wrapper +11 commas
+12*(50 fixed field/object bytes +64*6 escaped ID bytes +28*3 caption bytes)
+9*2+3*3 window-ID bytes =6268
```

A real accepted fixture reaches this bound. The byte-fallback tokenizer gives
a conservative canonical bound of at most6268 tokens in this encoding, not an
exact count. This does **not** bound raw generation: JSON whitespace, alternate
escapes, extra fields and untrimmed strings are not limited by the parser's
canonical form. The padding fixtures return byte-identical parsed HTTP EDLs.
The700 generation cap limits the actual request; the shape supplies no smaller
guaranteed completion bound. Reasoning is separate and remains unmeasured.

## Owner options — proposals only

**A. Empirical larger ceiling:4096 total output tokens.** Named allocation:
3509 largest measured canonical sample +512 provisional reasoning allowance
+75 formatting/rounding margin. This is an engineering trial ceiling, **not**
a worst-case completion guarantee: Astra's encoding is unmapped, the sample
is not the exact token maximum, raw formatting is not bounded, and512 is not
a measured reasoning maximum. Validate complete live outcomes/usage before
calling it production-proof. No such live experiment ran in this unit.

**B. Prefer a smaller visible contract, keeping the current budget pending
owner approval and quality checks.** Preserve stable window IDs, map assets
server-side, and select from deterministic caption candidates:

```json
{"w1":[20,99],"w2":[20,99],"w3":[20,99],"w4":[20,99],"w5":[20,99],"w6":[20,99],"w7":[20,99],"w8":[20,99],"w9":[20,99],"w10":[20,99],"w11":[20,99],"w12":[20,99]}
```

Each value is `[photo_index,caption_index]`: integers0..20 and0..99;
0 means face/no caption. A strict schema must permit only offered window
keys, reject unknown keys/out-of-range values, and retain current by-window
matching, motion planning and compliance checks. Build a bounded caption
catalog from reviewed facts/hints; this removes model-authored free text and
requires a quality/product decision. Do not silently replace IDs with an
order-only array. The canonical maximum is160 ASCII bytes, measured85 proxy
tokens; every canonical string fits within160 byte-fallback tokens. Raw JSON
formatting and reasoning still require separate completion/usage validation.
The current production parser does **not** accept this proposed format.

### Cents per provider attempt

The [official Astra model page](https://developers.openai.com/api/docs/models/gpt-6-astra)
lists standard input$10/M and output$50/M:0.001c/input token and0.005c/output
token. The [Responses reference](https://developers.openai.com/api/reference/cli/resources/responses/methods/create)
includes visible and reasoning tokens in `max_output_tokens`. These standard
rates match0034's assumptions; no discrepancy was found. No cache, batch,
long-context or fast-mode discount/premium is assumed here.

`0034_agent_reel_and_video_ladder.sql:69–75` stores **modelled**3.7c per call,
based on1200 input +500 total output. Its4.7c ceiling statement assumes the
same1200 input and700 output; it is not a universal input-cost ceiling.

| Proposed cap | Output ceiling | Delta from700 | Total with original1200-input assumption |
|---|---:|---:|---:|
|Current700|3.500c|0|4.700c|
|OptionA4096|20.480c|+16.980c|21.680c|
|OptionB keep700 with compact contract|3.500c|0|4.700c before its changed prompt is measured|

The selected largest-output fixture has2797 prompt-text proxy tokens, giving
23.277c at4096 output using proxy arithmetic. Another measured input has5858
proxy tokens, giving26.338c. Neither is an actual billed amount or a proved
full input maximum. Compact visible payload alone would be0.425c at85 proxy
tokens, **not** its total call cost. Any approved ceiling change must reconcile
the modelled ledger and failover exposure, not merely update the token field.

## Exact verification and reproduction

Evidence retained outside Git: `/tmp/rendprop-edl-headroom.cRPHXg/`.
The directory contains only synthetic measurement/test evidence and isolated
public tokenizer dependencies/cache. These temporary receipts are not durable
after reboot; the committed harness recreates them.

Setup used an isolated venv, binary wheels only, `tiktoken==0.14.0`, a pip
install JSON receipt, and the public `o200k_base` BPE download. The complete
resolved pins are `tools/audit/requirements-headroom.txt`. To reproduce with a
fresh temporary venv/cache (choose your own private temporary directory):

```sh
python3 -m venv /YOUR/TEMP/venv
/YOUR/TEMP/venv/bin/python -m pip install --only-binary=:all: -r tools/audit/requirements-headroom.txt
TIKTOKEN_CACHE_DIR=/YOUR/TEMP/cache /YOUR/TEMP/venv/bin/python -c 'import tiktoken; print(tiktoken.get_encoding("o200k_base").name)'
TIKTOKEN_CACHE_DIR=/YOUR/TEMP/cache /YOUR/TEMP/venv/bin/python tools/audit/measure_agent_reel_headroom.py
TIKTOKEN_CACHE_DIR=/YOUR/TEMP/cache /YOUR/TEMP/venv/bin/python tools/audit/measure_agent_reel_headroom.py --assert-current-ceiling
```

The final command **must exit1** for this source. Actual results:

- Measurement: exit0,11 scenarios,72 fixture assertions +103 measurement
  assertions,0 skips,0 provider calls. `measurement.json` binds source hashes.
- Current-ceiling negative gate: exit1 after104 measurement assertions;
  rejects the3509-token legal canonical example against700.
- `deno check --no-config --no-lock --node-modules-dir=manual
  tools/audit/agent_reel_headroom_fixture.ts`: exit0.
- Existing `ai-copy/agentreel_test.ts`:31 passed,0 failed. Run from repo root
  with `deno test --cached-only --no-config --no-lock
  --node-modules-dir=manual --allow-read=. --allow-env --deny-net --deny-run
  --deny-write services/supabase/functions/ai-copy/agentreel_test.ts`.

## Two fixture cleanups, no broad scanner exemption

`_shared/applejws.test.ts:922–937` and
`apple-subscriptions/notify.test.ts:292–321` now each use one named
`SYNTHETIC_APP_ACCOUNT_TOKEN` with the obviously synthetic UUID
`00000000-0000-4000-8000-000000000001`. Decode input/assertion are bound to the
same constant; notification summary asserts neither the value nor field name
is retained. Generated certificates, PEM cases and JWT-shaped sanitizer
fixtures are unchanged. No scanner allowlist, baseline, history rewrite or
classification of the historical curl credential was performed by this unit.

From `services/supabase/functions`, this command ran both before and after:

```sh
deno test --cached-only --no-config --no-lock --node-modules-dir=manual \
  --allow-env --allow-read=. --deny-net --deny-run --deny-write \
  _shared/applejws.test.ts apple-subscriptions/notify.test.ts
```

Both runs:53 passed,0 failed. Six exact source-contract checks failed before
the fixture rename/binding and passed after; that proves fixture clarity,
not a production vulnerability fix. An in-memory mutant of the **actual**
stored-summary test added the synthetic token back to its serialized result:
one selected test executed,0 skips, exit1 at `no appAccountToken value`.
No repository source was mutated for this negative run. Evidence files:
`apple-fixtures-before.log`, `apple-fixtures-after.log`,
`fixture-binding-before.log`, `fixture-binding-after.log`, and
`negative-summary-token.log`.
