# Funded serving and App Review authority — 2026-10-06

This change adds a durable money fence before paid provider dispatch. It does **not** establish a complete 75% business margin or activate unverified retail/trial allowances. No live migration, funding allocation, provider request or deployment was performed by the pricing audit agent.

## Money model

`20261006164721_funded_serving_and_app_review_authority.sql` creates service-owned allocations, anchored service slices, attempt liabilities and operation/result journals. Normal clients cannot provision money or mutate the journals.

For a paid collection, total serving authority is `floor(verified_net_proceeds_cents / 4)`. The sum of seven integer-cent reserves (`storage`, `delivery`, `compute`, `email`, `support`, `retention`, `uncertainty`) is removed **before** providers can spend. Every feature uses the same remaining balance. Successful, reserved and uncertain attempts retain their entire conservative quote. Only definitive non-allocation releases an attempt hold. A quota refund does not erase a bill, and expiry does not delete the financial journal.

Annual proceeds are allocated into exactly 12 purchase-anchored intervals, including exact integer-cent remainder distribution. Calendar-month rollover cannot create a thirteenth allowance. Refunds close new admission while keeping incurred/uncertain and retention debt. A newer, accepted Apple `REFUND_REVERSED` can restore only the remaining original retail allocation; it cannot replenish prior spending or restore an operator-revoked grant.

The current official USA catalog proceeds evidence is held privately by the launch owner. It yields these **maximum total envelopes before all serving reserves**, not provider-only allowances:

| Product | Customer price | Catalog net evidence | Inclusive quarter |
|---|---:|---:|---:|
| Starter monthly | $49 | $41.65 | $10.41 |
| Starter annual | $490 | $416.50 | $104.12 across 12 slices |
| Pro monthly | $99 | $84.15 | $21.03 |
| Pro annual | $990 | $841.50 | $210.37 across 12 slices |
| Team monthly | $249 | $211.65 | $52.91 |

Catalog proceeds are evidence for an attested conservative schedule, not a cash settlement. The old $12/$24/$60 provider ceilings do not prove a 75% margin after Apple.

## Provisioning contract

Retail automation runs only after verified Apple JWS and accepted subscription chronology. `fund_verified_apple_transaction` binds org, original chain, exact latest transaction/product/purchase/signature dates, Production environment, USA storefront and USD milliunit price. Missing/unsupported payment facts, stale/expired/grace receipts and an absent attestation produce no allocation. Historical expired receipts do not receive carry-in funds. Current launch evidence shows no active paid carry-in subscriptions.

An authorized operator must publish an `apple_serving_schedules` row with the exact product/price, conservative after-tax/commission/FX proceeds floor, 1 or 12 service months, effective interval (at most 31 days), all seven validated reserve categories and an evidence SHA256. The evidence must identify the actual hard serving limits and their tariff/fixed/support/refund/tax assumptions. A number chosen to fit the quarter is insufficient. Schedules are append-only to service clients and **remain unseeded in this migration**. Only exact attested USA/USD paid prices currently fund automatically; other paid discounts require a verified schedule.

Zero-price introductions require verified introductory `FREE_TRIAL` facts and an explicitly funded, finite sponsor pool. A schedule selects the pool, per-chain total cash, duration and all seven reserves. The pool is locked across chains and counts every prior commitment, including revoked trials. A restore cannot double the chain or recycle sponsor cash. No launch pool or trial schedule is seeded; trial sponsorship remains an owner decision. Sponsored trial acquisition expense is distinct from a proof of retail or lifetime business margin.

For App Review, `provision_serving_funding` accepts a dedicated named owner/org, source `app_review`, unique collection reference, zero retail proceeds, at most 500 sponsored cents **total inclusive**, at most seven days, all seven reserve categories and evidence SHA256. It rejects anonymous/deleting owners, shared orgs, existing unlimited QA orgs, active Production subscriptions and a second lifetime review grant. Effective plan and entitlement expose Pro, one seat and one Topaz allowance; all providers still share the finite cash authority. Sandbox restore journals only test receipts and cannot mint a Production entitlement. Existing owner/family unlimited private QA remains separate.

For newly funded retail/intro periods, `retention_ends_at` is fixed at paid/intro expiry plus 90 UTC days. Hosting reserve must cover that liability. App Review ends at its explicit grant end. New prospective hosting authority is identifiable by a retail/trial funding row; the absence of such a row preserves prior tester policy. Renewals extend the org's maximum funded retention date. Runtime notices/download enforcement are implemented separately by the retention owner; a refund does not delete this retained obligation.

## Dispatch and recovery coverage

The shared quote/reservation wrapper is used by photo generation/suggestions/prompt polish; all copy routes and their corrective retries; Coach; voice; chapter analysis and each fallback; video generation/Topaz; both drift-QC stages; reflection stages; Studio edit planner/transcription/presenter submission. The Python pipeline/VM provider fence is owned by the launch owner and uses the same reservation/finish RPCs. Disabled `ai-enhance` and unpriced private enterprise routes cannot become finite paid fallbacks.

Logical operation admission precedes paid helper chains. A financial authority error stops fallback. A zero-attempt refusal becomes retryable only when actual SQL proves **no reservation row exists**. Admitted, known-rejected, reserved, succeeded and uncertain stages retain permanent replay protection. No timeout authorizes another dispatch.

Bounded helper/Coach/chapter JSON results are privately journaled and reauthorized against current org/editor/deletion state before replay. Result content cascades on auth/org deletion; financial tombstones remain. Photo results persist to immutable owned R2 objects with the router both on and off. Photo replay reads only exact current journal identity and fresh bounded private GETs; it stores no signed capabilities/base64 in the operation result. Voice/history and video/status retain owned recovery. If photo generation completed but no owned object was ever committed, the request remains fenced with a clear saved-result error; it cannot silently regenerate.

## Tariff authority and limitations

Quotes use explicit configured output bounds for known OpenAI/Claude text models, a byte upper bound for text inputs, and conservative whole-context bounds for media. For Gemini 3.1 Flash Image, Google's legacy GenerateContent guide explicitly documents `max_output_tokens` as an infrastructure hard cutoff across thoughts and output. Its field reference links to the actual REST `GenerationConfig.maxOutputTokens` contract. The existing 4096-token, one-candidate, IMAGE/1K configuration is unchanged; the quote now reads the same generation configuration sent by the adapter and charges every combined output token at the highest published $60/M image tariff. It retains the full 131072-token published input window because no trusted input token/pixel authority exists. Larger supported configured caps increase the hold; missing caps, multiple candidates or unpriced generation shapes fail closed. This proves a documented bound, not paid-account acceptance, quality or invoice reconciliation. Candidate/output/frame/aspect settings are pinned in the actual adapter payloads. Unknown models, tools, enterprise prices or unbounded inputs fail closed for finite customers; explicitly unlimited private sponsorship stays functional and is labeled unpriced sponsor expense.

| Path | Conservative quote |
|---|---|
| Gemini 3.1 Flash Image | 131072 input at $0.50/M +4096 combined thoughts/output at $60/M =31.1296 cents |
| Gemini 3.6 Flash vision/video text | 1048576 input at $1.50/M +65536 output at $7.50/M =206.4384 cents |
| fal Kontext, one image/no mask | 4 cents |
| Seedance fast 1080p | Bounded geometry × explicit `(24×seconds+1)` frames /1024 at $1/M video tokens; 5s hold24.5025 cents |
| Topaz | At least16 cents per billable second, with existing decoder-proven/frame-scaled higher holds preserved |
| Veo 3.1 fast/no audio | 10 cents/s at720/1080p;30 cents/s at4K |
| fal Bria erase | 14 cents per probed second |
| ElevenLabs known pinned models | At most $0.08/1000 script characters, excluding unverified account/tax overhead |
| Whisper transcription | $0.006 per measured minute |

Primary references checked on 2026-10-06: [Google pricing](https://ai.google.dev/gemini-api/docs/pricing), [legacy combined token cutoff](https://ai.google.dev/gemini-api/docs/generate-content/thinking#token-limits), [REST GenerationConfig](https://ai.google.dev/api/generate-content#v1beta.GenerationConfig), [legacy image thinking modes](https://ai.google.dev/gemini-api/docs/generate-content/image-generation#thinking-process), [image token limits](https://ai.google.dev/gemini-api/docs/models/gemini-3.1-flash-image), [OpenAI pricing](https://developers.openai.com/api/docs/pricing), [Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing), [Seedance](https://fal.ai/models/fal-ai/bytedance/seedance/v1/pro/fast/image-to-video), [Topaz](https://fal.ai/models/fal-ai/topaz/upscale/video), [Kontext](https://fal.ai/models/fal-ai/flux-pro/kontext), [Veo](https://fal.ai/models/fal-ai/veo3.1/fast/image-to-video), [Bria erase](https://fal.ai/models/bria/video/erase/prompt), [ElevenLabs API pricing](https://elevenlabs.io/pricing/api). No paid billing canary was run by this agent. Thinking is not disabled; 3.1 Flash Image supports minimal/high thinking and minimal is not a zero-token guarantee. The combined cutoff already bounds both modes, so no thinking setting was changed.

Outstanding inclusive-margin proof gaps: attested recurring/fixed/support/tax/refund reserve amounts; enforced storage/delivery/request/compute/email bounds; repeated direct R2 S3 presigned GETs during their TTL; and actual provider acceptance/billing evidence. A TTL alone does not limit ClassB requests. The 31.1296-cent photo hold still cannot fund the advertised 100 Starter photos inside its inclusive quarter, even before other serving reserves. Finite hosting policy is now approved, but its notice/enforcement deployment must be verified. No arbitrarily lowered provider quota, typical-use average or catalog quote closes those gaps. Finite users cannot be advertised as fully functional paid AI subscribers before schedules and supported-purchase disclosures are activated and tested.

## Verification

The owned PostgreSQL runner uses a fresh private Unix socket, drops inherited credentials, replays every migration, runs the SQL fixture fresh and after this migration replay, races two different features against one shared budget, races one logical operation, and proves a deliberately removed locking guard admits an overspend. It never contacts a hosted database or provider. The latest fixture has 63 assertions, including payment chronology, annual slices, trial pool/refund/replay, finite reviewer UI RPCs and private-result deletion. Required CI jobs run both the fixture and concurrency runner.

The meaningful Deno cases execute actual shared admission/chain code, actual media/cost handlers, Apple signature/chronology bridges and Studio/Coach handlers with isolated transport/DB boundaries. Full-suite and source-bound receipts are saved privately in `LocalRendpropAudits/launch-20261006/pricing`. Final deployment/TestFlight verification remains the launch owner's responsibility. This is a mapped-path audit, not a claim that every historical code line or live provider path was exhaustively proved.
