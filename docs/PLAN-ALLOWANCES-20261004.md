# Plan features and AI allowances — 4 October 2026

**Proposal for review, not deployed quantities.** The owner selected a minimum
margin of **75% after Apple's fee**, excluding advertising. Small Business
enrollment is approved, but its effective date has not been established. This
proposal uses 30% conservatively; the effective 15% rate should first increase
headroom. The Topaz correction is deployed separately in `ai-video` v50.

The existing prices can support a useful product only if every paid operation
shares a funded budget. Independent photo, clip, voice and chapter counters
cannot establish that budget. Neither the current code nor this proposal
establishes a complete 75% margin guarantee.

## Access should be simple

Keep capture/import, organization, ordinary editing, original and edited-photo
libraries, downloads, listing contact details, publication, links and lead
management available across paid plans. These are the everyday agent and
photographer workflow. Generation consumes the shared AI balance; saving,
comparing and downloading an already generated version should not consume
another generation credit. Hosting, delivery and service compute still need
finite funded allowances.

Use higher plans primarily for more AI usage and collaboration. Keep the
current one / one / two included seats for Starter / Pro / Team; Team's balance
belongs to the workspace, not to each seat. Manager/editor permissions still
apply. A brokerage needs its own collected-revenue quote and funded shared
pool; a signed contract or the historical $50/seat floor is insufficient.

Do not bundle unfinished or disabled spatial/presenter features as production
benefits. Expensive generation can have a quoted, separately funded purchase
without forcing someone to upgrade just to export their existing work.

## What the current plans actually grant

The 3 October live catalog and matching client/server rows grant the following
monthly counts. Annual Starter/Pro currently receive the same counts. All
quantities are shared per workspace.

| Plan | Server tour jobs | Photo edits | Reel/reflection clips | Aerials | Topaz requests | Additional voiceovers | Additional chapter analyses | Seats |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Starter | 4 | 100 | 6 | 2 | 0 | 6 | 4 | 1 |
| Pro | 10 | 200 | 12 | 4 | 0 | 12 | 10 | 1 |
| Team | 25 | 400 | 25 | 8 | 2 | 25 | 25 | 2 |

Server tour jobs are distinct from native/browser publishing. The reviewed
publish API excludes on-device publishing from that job quota and returns both
branded and MLS-unbranded links. This does not make storage or public delivery
free. Assistants, prompt helpers and paid quality checks also cost money outside
the visible count table. These paths still need shared financial admission.

Sources: [server plan matrix](../services/supabase/migrations/0044_plan_rework_and_industry_trial.sql),
[sold client products](../apps/ios/Rendprop/Purchases/Products.swift),
[voice guard](../services/supabase/functions/ai-voice/index.ts),
[chapter guard](../services/supabase/functions/ai-chapters/index.ts), and
[pricing audit](PRICING-AUDIT-20261003.md).

## Concrete allowance scenario

One customer credit would fund **up to five cents of admitted provider
liability**. The journal must retain exact cents internally. A job is quoted
in whole credits from its complete bounded cost, including paid stages and
attempts. This is a proposed denomination, not an existing customer wallet,
retail cash value or promise that every edit costs one credit.

The following pools assume recurring serving costs of **$2 / $4 / $10 per
workspace per month**. These are **unmeasured scenarios**, not actual invoices
or proven expense bounds. A proposed 80% operating target leaves room above
the owner's approved 75% floor; the owner has not selected 80% as a new floor.

| Proposed product | Current US price | Shared credits/month | Maximum provider pool | Assumed recurring cost | Scenario net margin at Apple 30% |
|---|---:|---:|---:|---:|---:|
| Starter monthly | $49 | 80 | $4.00 | $2.00 | 82.51% |
| Pro monthly | $99 | 180 | $9.00 | $4.00 | 81.24% |
| Team monthly | $249 | 480 | $24.00 | $10.00 | 80.49% |
| Starter annual, conservative option | $490/year | 66 | $3.30 | $2.00 | 81.46% |
| Pro annual, conservative option | $990/year | 150 | $7.50 | $4.00 | 80.09% |

Annual prices are one charge equal to ten monthly prices, funding twelve
service months. Whole credits round down; residual pennies remain held.
Team annual is not currently
sold. These pools are alternatives to the independent paid-generation bundles,
not extra credits on top of them, and must not silently reduce existing paid
commitments.

Keeping the same **80 / 180** monthly credits on annual Starter/Pro is another
possible choice. With the same assumed $2 / $4 serving costs it models
**79.01% / 77.49%** net margin at Apple 30%. That satisfies the approved 75%
target in this scenario but leaves less uncertainty headroom. It does not meet
the proposed 80% target. Do not imply that the owner approved reduced annual
usage or changed annual prices. Final quantities need measured costs and
reviewable customer terms first.

## Show one quote before each job

| Exact operation for illustration | Published provider cost | Proposed credit quote |
|---|---:|---:|
| FLUX Kontext, exactly one output image | $0.04 | 1 |
| Veo 3.1 Fast, 8 seconds, 720p/1080p, audio off | $0.80 | 17 |
| Seedance v1 Pro Fast, standard 1920×1080 or portrait equivalent, 24 fps, 5 seconds | Approximately $0.243 | 5, conditional on an enforced output bound |
| Topaz, currently accepted container contract | Conservative reservation $0.16/second | `ceil(3.2 × seconds)` |

Kontext and Veo quote weights retain one cent and five cents of provider-pool
headroom respectively. They are scenario choices, not reconciled invoice
prices. The Seedance token formula needs an enforced geometry/FPS bound;
today's auto-aspect handling does not establish that promise. Do not silently
swap the current photo/video models merely to fit these examples, or claim
that their quality is equivalent.

Primary tariffs checked 4 October: [Kontext](https://fal.ai/models/fal-ai/flux-pro/kontext),
[Veo](https://fal.ai/models/fal-ai/veo3.1/fast),
[Seedance](https://fal.ai/models/fal-ai/bytedance/seedance/v1/pro/fast/image-to-video),
and [Topaz](https://fal.ai/models/fal-ai/topaz/upscale/video).

An example Starter mix is **46 bounded Kontext edits plus two bounded Veo
clips**: `46 × 1 + 2 × 17 = 80` credits. A Pro mix is **80 such edits plus
five such clips**, leaving 15 credits. A Team mix is **200 such edits plus
15 such clips**, leaving 25 credits. These are choose-your-mix illustrations,
not additive included promises or counts for today's Gemini-first declutter
route. Declutter followed by staging creates two paid generations and two
saved results.

Gemini/OpenAI images, masked Fill, voice, chapters, assistants, quality checks
and presenter work must receive quotes from verified model/account tariffs
and maximum permitted tokens, pixels, characters, minutes, stages and
attempts. Cached flat per-image/per-call averages are insufficient. Unknown
pricing must refuse dispatch rather than consume a guessed weight.

A 300-second Topaz job currently reserves **$48**, or **960 proposed credits**.
It cannot be promised twice inside a 480-credit Team pool. Long jobs need a
separately collected, adequately priced funding allocation. At Apple's 30%
fee, $48 alone requires at least $274.29 of customer payment for a 75% net
margin, before other serving costs. That is a mathematical floor, not a
recommended retail price. Trusted decode or invoice reconciliation may support
lower costs later; the current release deliberately retains the conservative
reservation.

For the product UI, use plain copy such as “Declutter these photos · 12
credits,” show the remaining shared balance, and preserve a job's quote on
retry/reload. People should not need to understand provider models or billing
units. A policy refund of a visible credit cannot erase an incurred vendor
expense; goodwill must have its own funded reserve.

## What must be finished before these quantities become promises

1. Recognize actual paid proceeds over the purchased service interval, including
   effective Apple commission, offers, currency, refunds and annual allocation.
   A rolling/calendar reset must not grant thirteen budgets from one annual
   payment. An introductory trial or TestFlight purchase earns no real proceeds;
   finite owner-funded QA/trial grants must cover its real provider expense.
2. Put all paid app, Studio, worker, assistant and multi-stage requests through
   one workspace-serialized pre-call journal. Reserve every permitted attempt,
   retain uncertain accepted calls, and settle once. Bind the source, actor,
   payload and quote; switching workspaces or refunding a count cannot create
   another funded balance. Preserve existing access, deletion and consent rules.
3. Measure hosting, storage, public requests, service compute and serving
   support. Define finite prospective retention/delivery promises with exports
   and clear terms; do not delete existing originals or silently abandon
   published preservation promises. Fixed commitments at a small subscriber
   count can exceed the scenario reserve even before AI usage.
4. Reconcile bounded jobs and failed/ambiguous attempts against actual provider
   usage/invoices. Verify maximum-use mixtures, concurrent requests, annual
   renewal windows, upgrades, refunds and team seats. Advertise only quantities
   that fit the whole funded envelope, with headroom for uncertainty.

Implementation and existing-customer migration remain outstanding. No prices,
quotas, storage terms, Apple products or customer credits were changed by this
proposal. Supporting read-only analysis is retained locally under
`/Users/pilksclaes/LocalRendpropAudits/plan-allowances-20261004/`.
