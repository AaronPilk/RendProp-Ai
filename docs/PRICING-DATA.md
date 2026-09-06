# Rendprop — Pricing data (6 Sep 2026)

The numbers behind $49 / $99 / $249: what each billable action costs us with the AI
routing brain ON, what each plan can cost at full allowance use, the margin after
Apple's cut, and what competitors charge this week.

**How to read this.** Every provider price is the vendor's own published list price,
fetched on 6 Sep 2026 unless a row says otherwise; the URL and date sit in the Sources
table at the end. Where a price could not be fetched, the row says so and uses the
repo's number, marked **[REPO]**. All repo facts are cited as `file:line`. Nothing was
run or spent.

**Assumptions used everywhere**

| # | Assumption | Basis |
|---|---|---|
| A1 | The tour render itself costs $0 — the flythrough renders on the phone. Server cost of a tour is upload + storage + hosting only. | `apps/ios/Rendprop/Render/RenderEngine.swift:5-6` ("zero server cost"); API-COST-SHEET §3.0 A1 |
| A2 | The AI router is ON, so the chains in migration `0018_ai_routes.sql` run: photo edits on Gemini 3.1 Flash-Lite Image / Flash Image with Flux Kontext as fallback; reels and grounded aerials on fal Seedance 1.0 Pro Fast; aerials without a photo (and the aerial fallback) on Veo 3.1 Fast; upscales on Topaz via fal; voiceover on ElevenLabs; chapters on Gemini 3.6 Flash. Anthropic is worker-only and never runs from the app. | `0018_ai_routes.sql:266-463`; `_shared/providers/gemini.ts:12-49` pins 3.x image output to 1K |
| A3 | A reel clip is 5 s at 1080p (the app always sends `seconds: 5`); an aerial is 4/6/8 s, default 6, user-selectable; a drone-glide upscale runs on a 90 s tour (a 3-minute walk retimed 2×) unless stated. | `FlythroughDetailView.swift:2486,5574` (5 s); `:3481,3837-3840` (4/6/8 s picker); API-COST-SHEET A4 |
| A4 | **10% slack** is added to every paid provider call for spend we pay for but never count against an allowance: timeouts after generation, refunded failures, a fallback step that still bills. User re-runs are *inside* the allowance, so they are already counted. | `ai-video/index.ts` refund path; API-COST-SHEET §5 (client deadline abandons, fal still bills) |
| A5 | Photo edits are a 50/50 mix of cheap edits (sky, twilight, lawn → Flash-Lite Image) and fidelity edits (stage, custom, declutter → Flash Image). | `0018_ai_routes.sql:267-317`; `ai-photo/index.ts:410-414` |
| A6 | Voiceovers are metered against the reels allowance with their **own** counter, and room chapters against the renders allowance with their own counter — so a plan's real monthly ceiling is renders + edits + clips + aerials + upscales **+ as many voiceovers as clips + as many chapter runs as renders**. | `ai-voice/index.ts:81-86,240-256`; `docs/AI-CHAPTERS-CONTRACT.md:240-250` |
| A7 | Expected case = 35% of every allowance, at the *expected* route (6 s grounded aerial, 350-character voiceover, 4K30 upscale). Worst case = 100% of every allowance at the *dearest* route the user can reach (8 s Veo aerial, 1,000-character voiceover, 4K60 upscale). | stated assumption |
| A8 | Apple keeps 30% in a subscriber's first year, 15% after one paid year, or 15% from day one under the Small Business Program. US storefront; no VAT deduction. | developer.apple.com/app-store/subscriptions (fetched 6 Sep 2026) |
| A9 | One published tour puts ~1 GB in R2 (scrub master + poster + photos) and is kept indefinitely. | `docs/UPLOAD-AND-PUBLISH-CONTRACT.md:317-321` ("a few-hundred-MB" master; 70+ photos) |

---

## 1. Unit economics — cost per billable action (brain ON)

| Action | Route with the brain ON (fallback) | List price, live | Assumption | **Our cost per action** (incl. 10% slack) | Price source |
|---|---|---|---|---|---|
| **AI photo edit — sky / twilight / lawn** | Gemini `gemini-3.1-flash-lite-image` → `gemini-3.1-flash-image` → fal `flux-pro/kontext` | **$0.0336 per 1K image** (Lite); $0.067 per 1K (Flash); $0.04/image (Kontext pro) | 1K output pinned by the adapter; ~2,300 input tokens at $0.25–0.50/1M ≈ $0.001 | **3.8¢** | Gemini pricing page, 6 Sep 2026; fal Kontext page, 6 Sep 2026 |
| **AI photo edit — stage / custom / declutter** | Gemini `gemini-3.1-flash-image` → OpenAI `gpt-image-2` (4.1¢ [REPO seed]) → fal `flux-pro/kontext` | **$0.067 per 1K image**; Kontext $0.04 | as above | **7.5¢** | Gemini pricing page, 6 Sep 2026 |
| **AI photo edit — blended (A5)** | 50/50 of the two rows above | — | — | **5.65¢** (range 3.8–7.5¢) | — |
| **Reel clip** (one animated photo, 5 s, 1080p) | fal `bytedance/seedance/v1/pro/fast/image-to-video` → fal `minimax/hailuo-02/standard` (768p, 4.5¢/s) | **$0.243 per 1080p 5-second clip** ($1.00 per 1M video tokens) | 5 s, 1080p, 16:9 or 9:16 | **26.7¢** per clip → a 5-clip reel ≈ **$1.34** | fal Seedance page, 6 Sep 2026 |
| **Aerial intro — photo attached ("grounded")** | fal Seedance i2v → fal `veo3.1/fast/image-to-video` | $0.243 / 5 s = **4.86¢ per second** | 6 s default | **32.1¢** (8 s: 42.8¢) | fal Seedance page, 6 Sep 2026 |
| **Aerial intro — no photo, or Seedance down** | fal `veo3.1/fast` (t2v) / `veo3.1/fast/image-to-video` | **$0.10 per second** at 720p/1080p without audio ($0.15 with audio; $0.30 at 4K) | 6 s = $0.60; 8 s = $0.80; audio off | **66¢ (6 s) · 88¢ (8 s) — the worst-case aerial** | fal Veo 3.1 Fast pages, 6 Sep 2026 |
| **Drone-glide upscale** (Team only, 2/mo; trial/free 1/mo) | fal `topaz/upscale/video`, model Proteus | **$0.01/s ≤720p · $0.02/s 720p–1080p · $0.08/s above 1080p; ×2 at 60 fps** | 90 s tour | **1080p60 $3.96 · 4K30 $7.92 · 4K60 $15.84**. Tail: a 300 s tour at 4K60 = **$48.00** per tap — there is no duration guard on `/ai-video/drone` (`ai-video/index.ts:515-600`: the route checks the 4K resolution ceiling, never the duration) | fal Topaz page + API schema, 6 Sep 2026 |
| **AI voiceover** (ElevenLabs, ≤1,000 characters) | elevenlabs `with-timestamps` (only vendor with per-character alignment; no fallback) | Creator plan **$22/mo for 121k credits = 18.2¢ per 1k characters** (1 credit = 1 character on Multilingual v2/v3; Flash v2.5 is 0.5). Pro plan $99/600k = 16.5¢ | 1,000 chars worst; ~350 chars (a 25-second script) expected | **20¢ worst · 7¢ expected**. Note the $22 plan is a fixed cost: the first ~121 max-length voiceovers a month are inside it | elevenlabs.io/pricing, 6 Sep 2026; credit ratio from texttolab.com (May 2026, third party). The repo's 22¢ (`0018:376`) predates the 121k allotment |
| **Room chapters** (auto room labels, one run per tour) | Gemini `gemini-3.6-flash` low-res 1 fps → `gemini-3.1-flash-lite` | Gemini 3.6 Flash **$0.75 in / $3.75 out per 1M tokens** through 31 Dec 2026, then $1.50 / $7.50 | ~1.4¢ per 2-minute tour [REPO seed `0018:442`]; 0.0117¢/s legacy (`ai-chapters/index.ts:109`) | **1.5¢** (a 20-minute video, the ceiling, ≈ 15¢) | Gemini pricing page, 6 Sep 2026 |
| **Tour render — server side only** | Render on device ($0). Upload to R2, host from a Cloudflare Worker + Supabase edge fn | R2 **$0.015/GB-month**, Class A **$4.50/M**, Class B **$0.36/M**, **egress free**; Workers Paid $5/mo incl. 10M req, +$0.30/M | 1 GB stored, ~70 Class A ops, 1,000 views (~10 range GETs + 1 Worker request each) | **1.9¢ in month one**, then **1.5¢ per tour per month for as long as it is kept** (see §2.4) | Cloudflare R2 + Workers pricing, 6 Sep 2026 |
| Fair-housing gate, captions (Apple Speech), floor plan (RoomPlan) | regex / on-device | $0 | — | **$0** | `0018:390-401,420-422,461-463` |

Not routed from the app, so not in the tables: Anthropic QC judge (worker only, `services/pipeline/providers/anthropic_qc.py`), Bria video eraser (no iOS call site, no committed price), Flux Fill masked declutter (the shipped app sends no mask, so the declutter chain runs as a prompt edit).

### 1.1 Fixed platform costs (not per plan)

| Item | Monthly | Source |
|---|---|---|
| Supabase Pro | $25.00 | supabase.com/pricing (API-COST-SHEET §2.2) |
| Cloudflare Workers Paid | $5.00 | developers.cloudflare.com/workers/platform/pricing, 6 Sep 2026 |
| ElevenLabs Creator (121k credits) | $22.00 | elevenlabs.io/pricing, 6 Sep 2026 |
| Apple Developer Program | $8.25 ($99/yr) | developer.apple.com |
| Cloudflare R2 | $0 until 10 GB-month, then per §1 | developers.cloudflare.com/r2/pricing, 6 Sep 2026 |
| **Total** | **≈ $60/mo** — covered by about two Starter subscribers at expected use | |

---

## 2. Per-plan economics

Allowances are copied from `apps/ios/Rendprop/Purchases/Products.swift:101-103` (= `plan_entitlements`, `0010:69-75`).

| Plan | Price | Tour renders | AI photo edits | Reel clips | Aerial intros | Drone-glide upscales | Seats | + voiceovers (A6) | + chapter runs (A6) |
|---|---|---|---|---|---|---|---|---|---|
| Starter | $49/mo · $490/yr | 8 | 150 | 8 | 2 | 0 | 1 | 8 | 8 |
| Pro | $99/mo · $990/yr | 25 | 300 | 20 | 6 | 0 | 1 | 20 | 25 |
| Team | $249/mo (yearly not sold at launch) | 80 | 600 | 40 | 15 | 2 | 3 | 40 | 80 |

**Seats.** Team's 3 seats share one allowance: every monthly meter is keyed by workspace (`reelmo:<org>`, `aerialmo:<org>`, `dronemo:<org>` in `ai-video/index.ts:119,178`; same pattern in `ai-photo`, `ai-voice`, `ai-chapters`), never by user. Three people on Team draw down the same 600 edits. Team is therefore $83 per seat with a per-seat cost ceiling of one third of the numbers below. No invite UI ships in 1.0; seats are a server-side membership count.

### 2.1 Worst case — 100% of every allowance, dearest route

| Monthly cost line | Starter | Pro | Team |
|---|---|---|---|
| AI photo edits × 5.65¢ | $8.48 | $16.95 | $33.90 |
| Reel clips × 26.7¢ | $2.14 | $5.35 | $10.69 |
| Aerial intros × 88¢ (8 s Veo) | $1.76 | $5.28 | $13.20 |
| Drone-glide upscales × $15.84 (90 s, 4K60) | — | — | $31.68 |
| AI voiceovers × 20¢ (1,000 chars) | $1.60 | $4.00 | $8.00 |
| Room chapters × 1.5¢ | $0.12 | $0.39 | $1.23 |
| Tour upload + hosting × 1.9¢ | $0.15 | $0.48 | $1.54 |
| **Provider cost at 100%** | **$14.25** | **$32.45** | **$100.24** |
| Repo's own ceiling (`cogs_ceiling_cents`, `0010:69-75`) | $15.00 | $32.00 | $82.00 |

The ceiling is only enforced on the worker path (`log_job_cost`, `0010:181-191`); the app's AI functions write ledger rows but nothing stops them at the ceiling (`_shared/entitlements.ts:18-20`). So the worst case above is real, and Team's exceeds its own ceiling by $18 — entirely because of the two 4K60 upscales.

**Margin, monthly plans, worst case**

| | Starter @30% | Starter @15% | Pro @30% | Pro @15% | Team @30% | Team @15% |
|---|---|---|---|---|---|---|
| List price | $49.00 | $49.00 | $99.00 | $99.00 | $249.00 | $249.00 |
| Apple's cut | $14.70 | $7.35 | $29.70 | $14.85 | $74.70 | $37.35 |
| Net revenue | $34.30 | $41.65 | $69.30 | $84.15 | $174.30 | $211.65 |
| Provider cost at 100% | $14.25 | $14.25 | $32.45 | $32.45 | $100.24 | $100.24 |
| **Gross profit** | **$20.05** | **$27.40** | **$36.85** | **$51.70** | **$74.06** | **$111.41** |
| **Gross margin (of net)** | **58%** | **66%** | **53%** | **61%** | **42%** | **53%** |
| Gross margin (of list) | 41% | 56% | 37% | 52% | 30% | 45% |
| Cost as % of net | 42% | 34% | 47% | 39% | 58% | 47% |
| **Break-even utilisation** | **241%** | 292% | **214%** | 259% | **174%** | 211% |

Break-even utilisation is the multiple of the allowance a subscriber would have to consume — at the dearest route — before provider cost equals net revenue. Every plan is above 100%, which means **no plan can lose money on provider cost inside its own allowances**, even before the Small Business Program.

### 2.2 Expected case — 35% utilisation, expected route

| Monthly cost line | Starter | Pro | Team |
|---|---|---|---|
| AI photo edits × 5.65¢ | $8.48 | $16.95 | $33.90 |
| Reel clips × 26.7¢ | $2.14 | $5.35 | $10.69 |
| Aerial intros × 32.1¢ (6 s Seedance) | $0.64 | $1.92 | $4.81 |
| Drone-glide upscales × $7.92 (90 s, 4K30) | — | — | $15.84 |
| AI voiceovers × 7¢ (350 chars) | $0.56 | $1.40 | $2.80 |
| Room chapters × 1.5¢ | $0.12 | $0.39 | $1.23 |
| Tour upload + hosting × 1.9¢ | $0.15 | $0.48 | $1.54 |
| Cost at 100% on the expected route | $12.09 | $26.49 | $70.81 |
| **Expected provider cost (× 0.35)** | **$4.23** | **$9.27** | **$24.78** |

| | Starter @30% | Starter @15% | Pro @30% | Pro @15% | Team @30% | Team @15% |
|---|---|---|---|---|---|---|
| Net revenue | $34.30 | $41.65 | $69.30 | $84.15 | $174.30 | $211.65 |
| Expected cost | $4.23 | $4.23 | $9.27 | $9.27 | $24.78 | $24.78 |
| **Gross profit** | **$30.07** | **$37.42** | **$60.03** | **$74.88** | **$149.52** | **$186.87** |
| **Gross margin (of net)** | **88%** | **90%** | **87%** | **89%** | **86%** | **88%** |
| Gross margin (of list) | 61% | 76% | 61% | 76% | 60% | 75% |
| Break-even utilisation (expected route) | 284% | 345% | 262% | 318% | 246% | 299% |

### 2.3 Yearly plans — annual = 10 months' price (Starter $490, Pro $990; Team yearly is not on sale, `Products.swift:200-205`)

Per month of service the yearly plan nets 16.7% less; Apple pays the whole year's proceeds up front.

| | Starter yearly @30% | Starter yearly @15% | Pro yearly @30% | Pro yearly @15% |
|---|---|---|---|---|
| Price per month of service | $40.83 | $40.83 | $82.50 | $82.50 |
| Apple's cut | $12.25 | $6.13 | $24.75 | $12.38 |
| Net revenue | $28.58 | $34.71 | $57.75 | $70.13 |
| Worst-case cost (§2.1) | $14.25 | $14.25 | $32.45 | $32.45 |
| **Worst-case gross profit / margin** | **$14.33 · 50%** | **$20.46 · 59%** | **$25.30 · 44%** | **$37.68 · 54%** |
| Expected cost (§2.2) | $4.23 | $4.23 | $9.27 | $9.27 |
| **Expected gross profit / margin** | **$24.35 · 85%** | **$30.48 · 88%** | **$48.48 · 84%** | **$60.86 · 87%** |
| Break-even utilisation (worst route) | 201% | 244% | 178% | 216% |

### 2.4 Two costs that are not in the monthly tables

- **Storage accrues.** Tours are kept after a plan lapses (pricing FAQ, `pricing.html:302-304`), so R2 grows by ~1 GB per published tour, forever. A Pro subscriber publishing 25 tours a month is paying $4.50/mo in storage by month 12 (300 GB × $0.015); at 35% use, $1.57. Team at 100%: $14.40/mo by month 12. Small, but it is the only cost that keeps growing after revenue stops. A retention rule for lapsed workspaces (e.g. archive masters after 12 months unpaid) is worth a line in the roadmap.
- **Trial and lapsed ("free") workspaces spend money at $0 revenue.** `trial` and `free` both carry 10 edits, 1 clip, **2 aerials and 1 drone-glide upscale** a month (`0013:28-32`; `tests/invariants.sql:182-183` asserts it). Worst case per workspace: **$18.68/mo** ($15.84 of it the upscale), expected-route $9.51, and $2.84 with the upscale removed. The server-side trial starts at sign-in with no card (`0010:226-240`); only Apple's introductory offer requires one. Every sign-up that never buys keeps this allowance every month.

### 2.5 Apple's cut and the Small Business Program

- **Standard:** 70% to us in a subscriber's first year, 85% after one accumulated year of paid service (developer.apple.com/app-store/subscriptions, 6 Sep 2026).
- **Small Business Program:** 85% "at each billing cycle … regardless of whether or not the subscription has accumulated one year of paid service".
- **Requirements** (developer.apple.com/app-store/small-business-program, 6 Sep 2026): be the Account Holder; you and any Associated Developer Accounts earned ≤ $1M in proceeds across all apps in the previous calendar year and ≤ $1M so far this year; accept the latest Paid Apps agreement (Schedule 2) in App Store Connect; list any Associated Developer Accounts. "Developers new to the App Store can qualify."
- **Does Rendprop qualify in year one?** Yes, on the published rules: it is a new app, and the account owning it earned nothing from the App Store last year. The only thing that could disqualify it is an *associated* developer account (one Aaron owns or controls, or that controls his) with over $1M in 2025 proceeds. Confirm none exists, then enrol.
- **Timing matters:** "Your proceeds will be adjusted fifteen (15) days after the end of the fiscal calendar month in which your enrollment is approved." Approved in September → the 15% rate applies from mid-October. Sales before that pay 30%. Every month of delay costs 15 points of every dollar: **$735 per 100 Starter subscribers, $1,485 per 100 Pro, $3,735 per 100 Team.**
- **Enrol:** https://developer.apple.com/app-store/small-business-program/enroll/
- Aside: on 13 Aug 2026 Apple proposed to the US court 15% (standard) / 5% (Small Business Program) on purchases made through external links; it is pending judicial review (MacRumors, 13 Aug 2026). Nothing to act on before launch.

---

## 3. Competitor prices — refreshed 6 Sep 2026

| Competitor | What it is | Price today | Free tier | Checked |
|---|---|---|---|---|
| **Aryeo** (Zillow) | Photographer delivery/ordering platform; the Zillow Showcase capture partner | Lite **$0**; Pro **from $49/mo**; add-ons SMS $19/mo, branded app $179/mo; Enterprise custom | Yes — Lite, free forever | aryeo.com/pricing, 6 Sep 2026 |
| **Zillow Showcase** | Premium listing placement on Zillow with floor plan + tour; photos not included | Not published by Zillow. Third-party reports: **~$400/mo incl. 1 listing, $300–1,150 per extra listing** by price band; or **$1 to start + $400–950 at close**; "$30–80 per-listing effective" in competitive markets | No | sofabrain.com (1 May 2026, reviewed 20 May 2026); amplifiles.ai (26 May 2026) |
| **Zillow 3D Home** | Free phone app: 360° tours + interactive floor plans, syndicated via MLS | **$0** — "upload tours to as many listings as you want — it costs nothing" | Entirely free | zillow.com/3d-home, 6 Sep 2026 |
| **Momenzo** | iPhone app: guided phone walkthrough → listing video, templates, teleprompter, speed ramps, new AI image-to-video | **$33/mo**, $59/3 mo, **$169–199/yr**; one-off Starter $19 / Pro $39 / Premium $69 | Download free; no free videos listed | App Store IAP list, 6 Sep 2026 |
| **CubiCasa** | Phone scan → floor plan, 24–48 h turnaround | First 2D plan **free**; Standard / Plus / Plus 3D priced per plan (prices load per country — not in the page HTML). Third-party: **Plus ~$15, Plus 3D ~$35 per plan** (Aug 2025); G2 listed $22.99 / $29.99 per scan (Oct 2024) | Yes — first 2D plan | cubi.casa/pricing, 6 Sep 2026; matthewmetros.substack.com (12 Aug 2025); g2.com (9 Oct 2024) |
| **Matterport** | 3D capture (phone or Pro3 camera), hosting billed by active spaces | Free (1 active space) · **Starter ~$9.99–14/mo (5 spaces)** · **Professional $69/mo (25 spaces)** · Business $309/mo (100); floor plans +$50/space; prices rose ~10–15% in May 2025 | Yes — 1 active space | matterport.com/plans (tiers; prices render client-side), 6 Sep 2026; thefuture3d.com (1 Mar 2026); sofabrain.com (20 May 2026); 3dtourmaker.com (Jun 2026) |
| **BoxBrownie** | Human photo editing, 24–48 h | Per image: enhancement **$2**, day-to-dusk **$5**, item removal **$5–10**, **virtual staging $30** | No (pay per image) | boxbrownie.com/pricing, 6 Sep 2026 |
| **Virtual Staging AI** | AI staging, seconds | **$16/mo (6 photos) · $19 (20) · $39 (60) · $79 (150)**; annual $192 / $228 / $468 / $948 | "Try for free" | virtualstagingai.app/pricing, 6 Sep 2026 |
| **Collov AI** | AI staging / redesign | **$19/mo (60 credits) · $49 (150) · $79 (263) · $127 (526)**; $0.24 per extra photo on Enterprise | 5 watermarked images | collov.ai/pricing, 6 Sep 2026 |
| **Styldod** | Human editing + staging, 24–48 h | Virtual staging **$16–23/image** (bulk vs standard), rush +$6/+$12; day-to-dusk from $4; object removal from $8; enhancement from $1.50; single-property video from $30 | First image free | styldod.com/virtual-staging, 6 Sep 2026 |
| **PhotoUp** | Human editing + AI staging, credits | **$1.50/credit** on demand (edit = 1 credit, AI staging = 3+); Starter **$49/mo (50 credits)**, Pro $129 (130), Growth $399 (400); packs $1.10–1.30/credit | 5 free credits | photoup.net/pricing, 6 Sep 2026 |
| **Reel-E** | Photos → listing reels, 4 formats per listing | Essential **$59/mo** ($44 annual, 3 listings) · Growth **$129** ($97, 10) · Pro **$599** ($449, 50, 4K) | 7-day trial | reel-e.ai/pricing, 6 Sep 2026 |
| **AutoReel** | Photos → AI-animated reels, web only | Page is client-rendered (no prices in HTML; FAQ confirms "3 fully watermark-free videos" trial and **$0.49–0.89 per extra photo edit**). **[REPO, 26 Aug 2026]** Free (watermark, 2/mo) · Essential $59/mo or $399/yr · Growth $139 or $1,199 · Pro $249 or $2,199 | Yes, watermarked | autoreelapp.com/pricing, 6 Sep 2026 (FAQ only); `docs/COMPETITIVE-INTEL.md:18` |
| **Mirino** | Photos → reels on self-hosted open models, flat rate | **[REPO, 26 Aug 2026]** Plus $49.99/mo unlimited · Pro $109.99 + premium models at cost × 1.3. Page is client-rendered; not re-verifiable today | Not listed | mirino.ai/pricing, 6 Sep 2026 (no data); `COMPETITIVE-INTEL.md:41` |
| **Nodalview** | Phone app: photos, video, 360 tours, floor plans (EU-centric) | Credit-based: photo 1 credit, **video 15 credits**, floor plan 15; "as little as €0.60 per credit" → a video ≈ €9; annual −10% | 14-day trial | nodalview.com/pricing, 6 Sep 2026 |
| **Arvaum Studio** | Desktop AI photo editor by a working RE photographer | **$29/mo (90 credits) · $49 (175) · $149 (600)**; packs from $22; "~$0.30 per edit" | 5 free generations; 30-day trial on Starter | arvaum.io, 6 Sep 2026 |

**What this says about $49 / $99 / $249.** No competitor bundles the whole chain. Priced à la carte at these rates, Starter's 150 AI edits alone are $49–79 a month at Collov or Virtual Staging AI, or $750+ at BoxBrownie; Pro at $99 sits below Reel-E Growth ($129 for 10 listings of reels) and AutoReel Growth ($139) while adding the tour, the photo studio and hosting; Team at $249 is AutoReel Pro's price with three seats, tours, floor plans and leads on top. The two direct "phone video → listing video" apps (Momenzo $33/mo, Nodalview ≈ €9 per video) are cheaper but stop at the MP4: no hosted tour, no leads, no AI photo studio, no floor plan.

---

## 4. Sanity check

**Is $49 / $99 / $249 defensible?** Yes. At a 30% Apple cut and *100%* allowance use on the dearest routes, the plans keep 58% / 53% / 42% of net revenue; at the expected 35% use they keep 86–88%. Break-even sits at 1.7–2.4× the allowance on every plan, so provider cost cannot sink a plan from inside its own limits. Against the market, Starter is the underpriced one — it carries $49–79 a month of à-la-carte AI staging plus the tour and hosting — and Team is the tightest.

**Where the margin is thin.**
1. **Team, because of the drone-glide upscale.** Two 90-second 4K60 upscales are $31.68 — a third of Team's worst-case cost and 18% of its net revenue — and one tap on a 300-second tour is $48 with no server-side duration guard. Team's worst-case margin is 42% (30% cut) / 53% (15% cut); without Topaz it would be 61% / 68%.
2. **Aerial intros**, per unit: the dearest single action after Topaz (88¢ at 8 s on Veo, 3× a reel clip). At 2 / 6 / 15 a month the dollar exposure is small ($1.76 / $5.28 / $13.20), so this is a per-unit thin margin, not a plan problem.
3. **Reels**, by expectation rather than cost: a 5-clip reel is $1.34, fine — but the allowance is **8 clips**, and rendprop.com/pricing sells it as "**8 reels** with your voiceover" (`pricing.html:141`; the app's paywall correctly says "8 reel clips", `Products.swift:128`). If Starter delivered 8 five-clip reels its worst case would be $22.80 and the margin 34%. Fix the wording, not the allowance.
4. **Yearly Pro at the 30% cut** is the thinnest priced row (44% worst case) — acceptable, and it becomes 54% under the Small Business Program.

**Which allowance is the risk.** Two, in this order:
- **`topaz_per_month` on `trial`/`free` = 1** (`0013:28-32`). A workspace that never pays can spend up to $18.68 a month, $15.84 of it on one upscale, with no card on file. Cost-wise this is the only revenue-free allowance in the product.
- **Team's 2 upscales with no duration ceiling** — the single largest swing in any paid plan.
Photo edits are the biggest *line* (59% of Starter's worst case) but the cheapest *unit*, bounded by the counter, and the Gemini route is already pinned to 1K output; they are not the risk.

**Recommendations (numbered, concrete).**
1. **Enrol in the App Store Small Business Program before the first sale** — https://developer.apple.com/app-store/small-business-program/enroll/ — accept Schedule 2 in App Store Connect, declare associated accounts. Rendprop qualifies as a new developer; the 15% rate starts 15 days after the end of the fiscal month the enrolment is approved, so approval in September means October sales at 15%. It lifts worst-case margin by 8–11 points on every plan and is worth $1,485 a month per 100 Pro subscribers.
2. **After launch, in the first server patch (no app change):** (a) add a duration guard on `/ai-video/drone` — refuse or double-charge above 180 s, which caps a 4K60 tap at $28.80 instead of $48; (b) set `topaz_per_month = 0` on `free` (leave `trial` alone — App Review lands on `trial`, `0013:12-18`) and update `tests/invariants.sql:182-183` in the same commit. Both are row/function edits behind the app's stable contract.
3. **When Apple grants the extended price points, relaunch Team once:** Team yearly at $2,490 (already defined, `RendpropProducts.notSoldAtLaunch`) and Team monthly at **$299** — worst-case margin goes from 42% to 52% (30% cut) or 53% to 61% (15% cut), and $299 is still under AutoReel Pro ($249) plus one Matterport Professional. Do it as one lineup change, not two.
4. **Copy fix on rendprop.com/pricing** (marketing site, not the binary): "8 reels" → "8 reel clips" on all three tiers so the page matches the paywall and the server. Do this before the first paying customer to avoid refund disputes.

**What NOT to change before launch.** The three prices; the allowance numbers (they live in four places that must move together — `Products.swift`, `plan_entitlements`, `pricing.html`, `tests/invariants.sql`); the product ids and the single `rendprop_plans` subscription group; the 7-day introductory offer; the `trial` row (its allowances are the App Review 3.1.1 mitigation); the router's "best" policy on Pro and Team (switching them to "cheapest" saves about $5 a month at 100% use and costs the quality that justifies the price); and the ai_routes prices — the ledger records what actually ran, so they only order the cheapest policy. One thing to *verify* rather than change: the router flag must be ON in production (or `GEMINI_IMAGE_MODEL` moved off `gemini-2.5-flash-image`) before **2 Oct 2026**, when the legacy image model shuts down (`0018:469-471`; API-COST-SHEET §2.6).

---

## Sources

| Source | Used for | Date checked |
|---|---|---|
| https://ai.google.dev/gemini-api/docs/pricing | Gemini 3.1 Flash Image ($60/1M image tokens; $0.067 per 1K image), Flash-Lite Image ($30/1M; $0.0336 per 1K), Gemini 3.6 Flash text ($0.75/$3.75 per 1M through 31 Dec 2026) | 6 Sep 2026 |
| https://fal.ai/models/fal-ai/bytedance/seedance/v1/pro/fast/image-to-video | "Each 1080p 5 second video costs roughly $0.243"; $1.00 per 1M video tokens | 6 Sep 2026 |
| https://fal.ai/models/fal-ai/veo3.1/fast/image-to-video and https://fal.ai/models/fal-ai/veo3.1/fast | $0.10/s without audio, $0.15 with, at 720p/1080p; $0.30/$0.35 at 4K | 6 Sep 2026 |
| https://fal.ai/models/fal-ai/flux-pro/kontext | FLUX.1 Kontext [pro] $0.04 per image | 6 Sep 2026 |
| https://fal.ai/models/fal-ai/topaz/upscale/video (+ `/api` schema) | $0.01/$0.02/$0.08 per second by output band, ×2 at 60 fps; "Proteus" still the default model enum | 6 Sep 2026 |
| https://elevenlabs.io/pricing | Creator $22/mo, 121k credits; Pro $99/mo, 600k | 6 Sep 2026 |
| https://texttolab.com/blog/elevenlabs-pricing | 1 credit = 1 character (Multilingual v2/v3), 0.5 on Flash/Turbo — third party | updated 20 May 2026 |
| https://developers.cloudflare.com/r2/pricing/ | $0.015/GB-month, Class A $4.50/M, Class B $0.36/M, egress free, free tier 10 GB / 1M / 10M | 6 Sep 2026 |
| https://developers.cloudflare.com/workers/platform/pricing/ | Paid $5/mo, 10M requests included, +$0.30/M | 6 Sep 2026 |
| https://developer.apple.com/app-store/subscriptions/ | 70% first year, 85% after one paid year; 85% at every cycle under the Small Business Program | 6 Sep 2026 |
| https://developer.apple.com/app-store/small-business-program/ · /enroll/ | eligibility, $1M threshold, associated accounts, 15-days-after-fiscal-month timing | 6 Sep 2026 |
| https://www.macrumors.com/2026/08/13/app-store-fees-apple-link-outs/ | proposed 15% / 5% external-link commission, pending court review | 13 Aug 2026 |
| https://www.aryeo.com/pricing | Lite $0, Pro from $49/mo, add-ons | 6 Sep 2026 |
| https://sofabrain.com/learn/zillow-showcase-cost/ · https://www.amplifiles.ai/blog/zillow-showcase | Zillow Showcase price reports (Zillow publishes none) | May 2026 |
| https://www.zillow.com/3d-home/ | Zillow 3D Home is free | 6 Sep 2026 |
| https://apps.apple.com/us/app/momenzo-real-estate-videos/id1465399598 | Momenzo in-app purchase prices | 6 Sep 2026 |
| https://www.cubi.casa/pricing/ · https://matthewmetros.substack.com/p/how-to-create-professional-3d-floor · https://www.g2.com/products/cubicasa/pricing | CubiCasa tiers (free first 2D plan); third-party per-plan prices | 6 Sep 2026 / 12 Aug 2025 / 9 Oct 2024 |
| https://matterport.com/plans · https://www.thefuture3d.com/blog/matterport-pricing-guide-2026/ · https://sofabrain.com/learn/matterport-pricing/ · https://3dtourmaker.com/matterport-pricing | Matterport tiers and active spaces (official); dollar prices (third party) | 6 Sep 2026 / 1 Mar 2026 / 20 May 2026 / Jun 2026 |
| https://www.boxbrownie.com/pricing | per-image prices | 6 Sep 2026 |
| https://www.virtualstagingai.app/pricing | plan prices | 6 Sep 2026 |
| https://collov.ai/pricing | plan prices | 6 Sep 2026 |
| https://www.styldod.com/virtual-staging | per-image prices | 6 Sep 2026 |
| https://www.photoup.net/pricing | credit prices and plans | 6 Sep 2026 |
| https://www.reel-e.ai/pricing | plan prices | 6 Sep 2026 |
| https://www.autoreelapp.com/pricing | FAQ only (client-rendered); plan prices from `docs/COMPETITIVE-INTEL.md` (26 Aug 2026) | 6 Sep 2026 |
| https://mirino.ai/pricing | client-rendered, no data; prices from `docs/COMPETITIVE-INTEL.md` (26 Aug 2026) | 6 Sep 2026 |
| https://nodalview.com/pricing | credit prices | 6 Sep 2026 |
| https://arvaum.io/ | plan prices | 6 Sep 2026 |
| Repo: `apps/ios/Rendprop/Purchases/Products.swift`, `services/supabase/migrations/0010_*.sql`, `0013_*.sql`, `0018_ai_routes.sql`, `services/supabase/functions/{ai-photo,ai-video,ai-voice,ai-chapters}/index.ts`, `_shared/{ledger,entitlements,router}.ts`, `_shared/providers/gemini.ts`, `services/edge/tour-host/public/pricing.html`, `services/supabase/tests/invariants.sql`, `docs/{LAUNCH-CONTRACT,AI-COST-MODEL,AI-ROUTER-CONTRACT,AI-CHAPTERS-CONTRACT,VOICEOVER-CONTRACT,UPLOAD-AND-PUBLISH-CONTRACT,COMPETITIVE-INTEL,MARKET-DOMINATION}.md`, `/home/claude/out/API-COST-SHEET.md` | allowances, routes, metering, repo prices | branch `launch`, 6 Sep 2026 |

*Compiled 6 Sep 2026 from branch `launch`. No command that spends money was run; no credential was read.*
