# Real photo comparison — preservation failure remains open

Eight real Gemini requests completed on September 19, 2026 using the actual
assembled prompts from `8d32f85` and `7bcc624`, a fixed public repository demo
image, and the current enabled `gemini-3.1-flash-image` model. There were no
retries, production data mutations or customer media uploads. Prompt assembly
used the real historical handlers; the paid calls used the real Gemini adapter.

**Both prompt versions fail preservation in two of three staging outputs on
this fixture.** The first new output removes the large foreground pillar and
changes the framing; a repeated new output adds hanging ceiling fixtures. The
two repeated baseline outputs add cove/hanging lighting and recessed downlights,
respectively. The original has none of those ceiling fixtures. This small
sample does not establish a CONDITION_LOCK regression or an improvement. It
does establish that neither prompt reliably preserves permanent details here.
Do not remove CONDITION_LOCK to make one sample look better.

| Operation | Prompt revision | Result | Provider seconds | Input / output tokens |
|---|---|---|---:|---:|
| Declutter | `8d32f85` | Person remains visible; major architecture retained | 9.365 | 420 / 1,535 |
| Declutter | `7bcc624` | Person removed; major architecture and foreground pillar retained | 8.040 | 673 / 1,459 |
| Stage, modern | `8d32f85` | Furniture replaced; foreground pillar/framing retained | 8.590 | 469 / 1,532 |
| Stage, modern | `7bcc624` | **Fails:** foreground pillar removed and view recomposed | 10.248 | 670 / 1,683 |
| Stage, repeat 1 | `8d32f85` | **Fails:** adds cove lighting and a hanging ceiling fixture | 10.536 | 469 / 1,594 |
| Stage, repeat 1 | `7bcc624` | **Fails:** adds hanging ceiling fixtures | 10.058 | 670 / 1,575 |
| Stage, repeat 2 | `7bcc624` | Foreground pillar, framing and visible fixed ceiling details retained | 9.246 | 670 / 1,503 |
| Stage, repeat 2 | `8d32f85` | **Fails:** adds recessed ceiling downlights | 9.739 | 469 / 1,690 |

All responses were HTTP 200 with image output, all 1,203 × 880 pixels from the
1,400 × 1,024 input. Visual inspection covered all eight full images. The four
follow-up calls used identical model/input/prompts and alternated pair order;
there was no prompt tuning or retry-until-pass selection. The reported failure
count checks the foreground pillar/framing and fixed ceiling lighting; it is
not a claim that all other details in the passing examples were pixel-identical.
This demo
is not a labeled building-defect dataset; it cannot prove preservation of
cracks, damage or wear. It is also not a repeated quality benchmark across all
enabled photo models.

The configured route unit cost was 6.7¢ per image, giving **53.6¢ configured
cost for eight calls**. Actual invoiced cost was not available and is explicitly
null in each receipt. Provider response IDs and token usage are retained.

## Evidence and reproduction

Private local evidence is retained outside Git at
`/Users/pilksclaes/LocalRendpropAudits/call-20260919/photo-quality/`:
`receipt.json`, `prompts.json`, `sha256.json`, `original.webp`, and the four
revision-labeled JPEG outputs. No keys are included.
The four repeated staging outputs and their separate receipts/prompts/hashes
are in the neighboring `photo-quality-stage-repeat/` directory.

- [Original](/Users/pilksclaes/LocalRendpropAudits/call-20260919/photo-quality/original.webp)
- [Baseline staging](/Users/pilksclaes/LocalRendpropAudits/call-20260919/photo-quality/stage-8d32f85.jpg)
- [New staging — failed preservation](/Users/pilksclaes/LocalRendpropAudits/call-20260919/photo-quality/stage-7bcc624.jpg)
- [Baseline declutter](/Users/pilksclaes/LocalRendpropAudits/call-20260919/photo-quality/declutter-8d32f85.jpg)
- [New declutter](/Users/pilksclaes/LocalRendpropAudits/call-20260919/photo-quality/declutter-7bcc624.jpg)

The executable comparison uses
`tools/audit/call-20260919/web/quality-prompts.mjs` and
`tools/audit/call-20260919/reflection/photo-quality.ts`. The latter is an
explicit manual paid experiment, never a CI test. Each invocation makes at most
four planned requests, records unsuccessful responses as well as successful
ones, and does not retry. A durable start marker prevents resubmitting a partial
experiment. Set only the selected provider key in the subprocess environment;
never print the project's environment file.

## Verified reflection-removal price

The authenticated fal pricing API returned **USD 0.14 per second** for
`bria/video/erase/prompt` at `2026-09-19T21:36:27.329995Z`. This matches the
[model pricing page](https://fal.ai/models/bria/video/erase/prompt).
The selected provider is fal; direct Bria pricing is not interchangeable.

Receipt: `/Users/pilksclaes/LocalRendpropAudits/call-20260919/bria-price.json`.
This verifies a rate, not a particular job's invoice. At this rate a 4.8-second
clip costs 67.2¢, and a $2.40 batch budget permits at most 17.14 seconds before
rounding. The old 24¢-per-reel estimate must not price this feature.
