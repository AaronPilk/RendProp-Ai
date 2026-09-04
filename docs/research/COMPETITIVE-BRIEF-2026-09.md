# Rendprop — Competitive & Market Reality Brief

**Prepared:** September 2026
**Scope:** iOS app that turns a continuous agent-filmed phone walkthrough into a scroll-scrubbed cinematic tour at a shareable link, plus AI photo edits, AI aerial intro, social reels, LiDAR floor plan, and lead capture. Pricing today: $49 Solo / $99 Pro / $249 Team per month.
**Method:** ~45 web searches and ~40 primary-source fetches. Company pricing pages, NAR research, MLS policy documents, SEC/earnings transcripts, G2/Capterra review text, and state statutes were preferred over secondary blog content. Where a number could not be verified from a primary source, it is flagged.

---

## 0. Bottom line up front

**This is not a low-competition gold mine. It is one of the most crowded, most commoditized, lowest-willingness-to-pay categories in proptech, and the two largest portals are actively absorbing every feature on your list — for free.**

Five facts that should reframe the whole plan:

1. **Zillow gives away the core.** Zillow 3D Home is free, produces a 3D tour *and* an interactive floor plan from an iPhone 7 or newer, and Zillow reports interactive-floor-plan listings get 60% more views and 79% more saves ([Zillow 3D Home](https://www.zillow.com/3d-home/)).
2. **Zillow already shipped your AI aerial intro.** SkyTour (launched 22 July 2025) is a Gaussian-splat interactive aerial exterior tour, included at no extra cost on Showcase listings ([Zillow](https://www.zillow.com/news/take-home-listings-to-new-heights-with-skytour/)). Realtor.com shipped FlyAround on 30 October 2025 ([PR Newswire](https://www.prnewswire.com/news-releases/realtorcom-introduces-flyaround-a-new-360-satellite-view-to-help-home-shoppers-see-the-bigger-picture-302599955.html)).
3. **Zillow already owns your virtual staging.** Zillow acquired Virtual Staging AI in October 2024 and launched buyer-facing AI Virtual Staging inside Showcase on 10 September 2025 ([Zillow IR](https://investors.zillowgroup.com/news-and-events/news/news-details/2025/Zillow-brings-AI-powered-Virtual-Staging-to-Showcase-listings/default.aspx)).
4. **Zillow is about to kill your floor plan.** On the Q2 2026 earnings call (13 August 2026) management said Zillow plans to "launch smartphone-based instant floor plans" later in 2026 "to reduce friction and lower costs" ([Motley Fool transcript](https://www.fool.com/earnings/call-transcripts/2026/08/13/zillow-zg-q2-2026-earnings-call-transcript/)).
5. **Buyers rank virtual tours *below* floor plans.** NAR's 2025 Profile of Home Buyers and Sellers (transactions July 2024–June 2025): photos "very useful" **81%**, detailed property info **77%**, floor plans **57%**, virtual tours **38%**, interactive maps **34%** ([NAR, via RI Realtors PDF](https://www.rirealtors.org/clientuploads/documents/NAR/Homebuyers_and_sellers_trend_2025.pdf)).

**The scroll-scrub interaction does appear to be genuinely unclaimed in real estate.** I could not find a single real-estate product marketing it. But it is a UI pattern — a frame-sliced video plus a scroll listener — with abundant prior art in general web design (Apple product pages, [Maglr's "scrub on scroll"](https://www.maglr.com/updates/introducing-scrub-on-scroll-for-video-slideshows-lottie-and-more), Framer/GSAP/Scrollsequence tooling). It is a two-week clone for anyone who sees it work. **Novelty is not a moat here.**

---

## 1. Competitive landscape

### 1a. Portal-native (the existential tier)

| Product | What it does | Price | Traction / signal |
|---|---|---|---|
| **Zillow 3D Home** | 360 capture on iPhone 7+/Android/Ricoh Theta/Insta360 → 3D tour **plus interactive floor plan** | **Free, unlimited** | Zillow: interactive-floor-plan listings get 60% more views, 72% more shares, 79% more saves. Con per HousingWire (12 Nov 2025): lower quality than Matterport, Zillow branding cannot be removed, Zillow agents only. |
| **Zillow Showcase** | Premium listing treatment: large media, interactive floor plan, virtual tour, SkyTour aerial, AI virtual staging, priority placement | ~**$400/mo** base incl. 1 listing; extra listings **$300–$1,150** each scaled to home price; or pay-at-closing **$1 up front + $400–$950 at closing** ([SofaBrain, 2026](https://sofabrain.com/learn/zillow-showcase-cost/)) | **On ~5% of all new US listings, up from 2.5% a year prior** (Q2 2026 call). In top-10 markets **30% of new for-sale listings have 3D Home tours**; rich-media listings are **11%** of for-sale listings. 50+ brokerages adopted (Sept 2025); custom discounted deal with Baird & Warner (Aug 2026). |
| **Zillow SkyTour** | Interactive **Gaussian-splat aerial exterior** tour — your "AI aerial intro," but real geometry | **Included** with Showcase when drone is booked via Zillow Media Experts | Launched 22 July 2025 |
| **Zillow AI Virtual Staging** | Buyer taps a room photo, picks a style (modern, Scandi, industrial, coastal…), swipes original↔staged, or de-furnishes | **Included** in Showcase | Launched 10 Sept 2025; built on Virtual Staging AI, which Zillow **acquired Oct 2024** |
| **Aryeo (Zillow)** | Media delivery, branded delivery pages, scheduling, invoicing, Virtual Staging AI, Zillow 3D integration | Lite **free**; Pro **from $49/mo**; tiers **$49 / $99 / $179**; SMS +$19/mo; branded app +$179/mo ([aryeo.com/pricing](https://www.aryeo.com/pricing)) | Acquired by Zillow 2 Aug 2023; had 1,500+ media companies. **Aryeo Pro is priced identically to Rendprop Solo and Pro and is owned by the portal.** |
| **Realtor.com FlyAround** | 360° satellite/3D exterior view | Free to shoppers | Launched 30 Oct 2025 |
| **Homes.com Listing Boost (CoStar)** | Placement + retargeting + **free Matterport 3D model and interactive floor plan** in select markets | Boost per-listing or annual membership (price not published) | CoStar bundles the tour as a giveaway to sell placement |

**Read this row carefully:** Aryeo Pro at $49/mo — owned by Zillow, integrated with Zillow 3D and Virtual Staging AI — is your Solo tier's price with the portal's distribution behind it.

### 1b. Capture-and-host incumbents

| Product | Model | Price (verified) | Traction |
|---|---|---|---|
| **Matterport (CoStar)** | Camera + subscription by "active spaces" | Free (1 space) / Starter **$14–56**/mo / Professional **$69–429**/mo / Business **$355–870**/mo; prices up ~10–15% May 2025; Pro3 camera **$5,995**; floor-plan add-ons ~$14.99–39.99; MatterPak $49–59 | **FY2024: revenue $169.7M (+8%), subscription revenue $99.6M (+14%), ARR $104.2M, 1.2M subscribers (+23%), 14.1M spaces, 50.7B sq ft** ([Matterport, 26 Feb 2025](https://matterport.com/news/matterport-announces-fourth-quarter-2024-financial-results-with-over-50)). Acquired by CoStar for **$1.6B**, closed Feb/Mar 2025. |
| **CubiCasa (Clear Capital)** | Phone scan → floor plan, mostly per-order | **First 2D floor plan free**; Lite/Standard/Plus/Plus 3D tiers; 24h standard, 48h for 3D; add-ons for 6h turnaround, ANSI GLA report, CAD, 3D video render | **Floor plans on 1 in 3 US listings, up from 2% in early 2022 — 15× in ~3 years. 4M+ scans. 100+ MLS partnerships covering "over half of all U.S. agents." Partners: Redfin, NextHome, FBS** ([CubiCasa, 7 Oct 2025](https://www.cubi.casa/1-in-3-listings-cubicasa-floor-plans/)) |
| **iGUIDE** | **Pay-per-project, explicitly anti-subscription** | iGUIDE Instant **$7.99 USD/project**; Radix $6.99 CAD; Standard from $48 CAD; Premium from $66 CAD; PLANIX R1 camera sold separately | Marketing copy: "Subscription platforms often charge you even when you're not scanning… There are no monthly fees, no storage limits, and no penalties." ([goiguide.com/pricing](https://goiguide.com/pricing)) |
| **EyeSpy360** | PAYG or thin subscription | **$1 per 360 image** (15 min) **or** Plus 1 **$12.99**/mo, Plus 3 **$35.99**/mo, Plus 5 **$54.99**/mo — includes auto floor plans, 3D models, **social media videos**, live viewings | [EyeSpy360 KB](https://eyespy360.freshdesk.com/support/solutions/articles/19000121332-how-much-does-eyespy360-cost-/) |
| **RICOH360 Tours** | Camera-tied subscription, unlimited tours | **$39–$59/mo** (HousingWire, Nov 2025); customer testimonial cites "$45/month for unlimited listings" | Claims **40,000+ users, 13M+ tours, 100+ countries**. Has an **AI Video Maker** that auto-generates a walkthrough video from tour images, plus virtual staging (beta) and floor plans. |
| **CloudPano** | 360 tours, live video chat, white-label | **Free–$49/mo** | **Capterra 4.9/5 (61 reviews)** — repeatedly praised for being cheap and easy: "So simple and above all, the cost is fantastic compared to all of the other options." |
| **Asteroom** | Phone + rotator kit → 3D tours | **From $19.99/mo**, free version + trial | Capterra 5.0 but only 2 reviews — thin signal. Reviewers: "Best pricing period," "a fraction of the price." |
| **Giraffe360** | Robotic camera + subscription, done-for-you processing | **Could not verify 2026 US pricing** — pricing page blocks automated fetch (robots.txt). Raised $4.5M in 2020 (Hoxton Ventures, LAUNCHub). Treat pricing as unknown. |

### 1c. Phone-video → immersive tour (your actual technical peer group)

This is the category you are entering, and **it already exists with better technology than scroll-scrubbed video**.

- **Gaussian splatting from phone video** is a live commercial category. **Splat Tour** takes a smartphone video walkthrough, processes in under 2 hours, and gives a browser-native tour where the viewer **moves freely through the space** — not along a fixed path. Pricing: free 40 credits, **Starter €19/mo (~2–3 tours), Pro €29/mo, Studio €89/mo** ([splattour.com](https://splattour.com/en)). **Splat Labs** and **Real Horizons** are competing in the same lane; Splat Labs' 15 March 2026 analysis frames it explicitly as displacing Matterport, citing $6,000+ cameras vs a smartphone.
- **Zillow's SkyTour uses Gaussian splatting.** The portal has the same tech in production.
- **Walkly** — video walkthroughs filmed on a phone, auto-cut into social versions *plus an interactive web version*; viewer navigates by clicking left/right on the video. Freemium; iOS, Android, web. Claims "hundreds of real estate professionals" ([walkly.app](https://www.walkly.app/en)). **This is the closest existing product to your interaction model.**
- **Realsee** — mobile 3D virtual tour capture, targeting agents and brokerages directly.

**Why this matters:** a scroll-scrubbed video is a *rail*. A splat is a *space*. If a buyer can wander freely in a competitor's tour and can only slide forward and back in yours, you lose the demo.

### 1d. Phone-video / photo → marketing video (your pricing peer group)

| Product | What | Price | Traction |
|---|---|---|---|
| **Momenzo** | **Film on your phone with in-app guidance → automatic edit, branding, publish.** Mobile-first, iOS + Android | **$33/mo, $59/3mo, $169/yr** (~$14/mo); in-app tiers Starter $19 / Pro $39 / Premium $69 | **App Store 4.8★, 1.3K ratings.** Claims 1M+ videos, **7,500+ active users**, used at Century 21, Sotheby's, KW, eXp. Updated 3 days before check — actively maintained. |
| **Trolto** | AI virtual staging → **cinematic fly-through videos + automated Instagram Reels** | **$59–$249/mo** | HousingWire's stated con: "Fly-through videos are **non-interactive**" — the one gap your scroll-scrub fills |
| **Editora AI** | Enter an address → pulls photos → auto video with AI narration, captions, branding, music, "under two minutes." iPhone app | First video free; tier pricing not published | Claims agents across **200+ brokerages**; logos: Coldwell Banker, Corcoran, Sotheby's, Compass, KW, RE/MAX |
| **Roomvu** | AI video content, avatars, voice cloning, auto-posting, lite CRM, ads | **$89.99 / $199.99 / $399.99 per month** | Claims **438,906 REALTORS** on platform. Launched an automated recruiting-video tool in Aug 2026. |
| **HeyGen for Real Estate** | AI-avatar market updates, listing spotlights, **hosted home tours** | Not published | **Launched August 2026.** A well-funded general AI-video company has now aimed a product at your exact buyer. |
| **CapCut / Canva** | Free real-estate video template libraries | **Free** | The actual default. Any paid tool must beat "free template + 20 minutes." |

**Momenzo is the most instructive datapoint in this brief.** It does almost exactly your core workflow — agent films on phone, app auto-edits — has been shipping for years, has 1.3K App Store ratings, and prices at **$169/year**. Your Solo tier is **$588/year**. You are asking 3.5× for a product a competitor sells cheap and a portal gives away.

### 1e. AI photo editing (fully commoditized)

| Provider | Price |
|---|---|
| BoxBrownie (human) | Virtual staging **$30/image** (48h); image enhancement **$2**; day-to-dusk **$5**; item removal/virtual cleaning **$5–10**; floor plans **$30–45**; virtual renovation **$30–220**; 360 staging **$60** |
| Virtual Staging AI | $16/mo (6 photos) → $79/mo (150 photos) = **$0.53–$2.67 per photo** |
| REimagineHome | **$19–$119/mo** for 30–1,200 images (~$0.64/image at top tier) |
| Collov AI | **$16–$225/mo** for 60–1,000 images (**~$0.23/image**) |
| Styldod | **$16/image** (human designed); $25/hotspot for Matterport |
| AI HomeDesign | $19–$69/mo (30–200 images); human staging $13.99/image |

Twilight sky, declutter, and virtual staging are **sub-$1-per-image utilities**. They are table stakes, not a revenue line. And Zillow now performs staging inside its own consumer app for free.

### 1f. Adjacent / commoditized components

- **LiDAR floor plans**: Apple's **RoomPlan API is free to any iOS developer**. Polycam, magicplan, RoomScan Pro, CubiCasa, and dozens of App Store entrants already ship it. CubiCasa gives the first plan away. Zillow plans to ship free smartphone floor plans later in 2026. **Do not treat your LiDAR floor plan as a differentiator.**
- **Single-property websites with lead capture**: a mature, cheap, crowded category (Luxury Presence, ListingFlare, mysinglepropertywebsites, dozens more). Not a differentiator on its own — and see §5 for why lead capture cannot be attached to the MLS.

### 1g. Does anyone do scroll-scrub property tours? — direct answer

**No product I could find markets scroll-to-scrub as a property-tour format.** Searches across product names, Product Hunt-style phrasing, real-estate video app roundups, and virtual-tour comparison articles surfaced only generic web tooling (Maglr, Framer, Scrollsequence, GSAP tutorials) and one adjacent product (Walkly, click-to-navigate). **The interaction appears unclaimed in this vertical.**

Caveats you must hold:
- Unclaimed ≠ defensible. Scroll-video-scrubbing is a documented, widely taught web technique with heavy prior art.
- It may be unclaimed because it has been tried and doesn't convert. Scroll-scrub burns bandwidth (you ship every frame), breaks on slow connections, is awkward on desktop, and gives the viewer *less* freedom than a splat or a 360 tour.
- **Test this before you build on it.** Instrument completion rate and time-in-tour against a plain autoplay video and a 360 tour on the same 50 listings. If scroll-scrub doesn't beat both, it's a demo trick, not a product.

---

## 2. Market size, honestly

### The pool is shrinking, and the transactions are at a 30-year low

| Metric | Value | Source |
|---|---|---|
| NAR members, 14 June 2026 | **1,438,569** | [NAR](https://www.nar.realtor/news/real-estate-news/nar-leaders-share-strategic-plan-momentum-membership-count-above-budget-forecast) |
| NAR members, same date 2025 | **1,463,352** → **−24,783 YoY (−1.7%)** | same |
| Peak membership | **~1.60M, October 2022** → **down ~10% from peak** | [HousingWire](https://www.housingwire.com/articles/overblown-rumors-of-demise-nar-has-lost-only-45k-members-since-december/) |
| NAR's own internal budget assumption | **1.2 million members** | NAR, June 2026 |
| Active US real estate licenses | **~3 million** (ARELLO, via HomeLight); a separate vendor compilation claims 2,130,616 — **treat the licensee count as ±30%** | [HomeLight](https://www.homelight.com/blog/how-many-realtors-in-the-us/) |
| Existing-home sales 2025 | **4.061M** (2024: 4.062M) — **lowest annual total since 1995** | [Inman, 14 Jan 2026](https://www.inman.com/2026/01/14/2025-existing-home-sales-miss-2024-pace-by-razor-thin-1k-margin/) |
| Home turnover, first 9 months 2025 | **28 per 1,000 homes (2.8%)** — lowest in 30+ years; −37.7% vs 2021 | [Redfin](https://www.redfin.com/news/home-turnover-report-2025/) |
| NAR 2026 forecast | Existing-home sales **+14% in 2026**, prices +4%, mortgage ~6% | [NAR, 14 Nov 2025](https://www.nar.realtor/newsroom/nar-forecast-home-sales-expected-to-jump-14-in-2026) |

### Agent economics (NAR 2026 Member Profile, published 25 June 2026)

- Median **9 transaction sides** in 2025 (individual specialists); median sales volume **$2.7M**
- Median gross income **$59,200** (2024: $58,100); agents with ≤2 years experience: **$8,000**
- **Median total business expenses: $9,530/year** (2024: $8,010). Largest single line item: **vehicle, $1,580.**
- Median 13 years experience — the industry is aging into experienced full-timers
- 21% work on teams; 86% are independent contractors

**Read the expense number again: the median REALTOR spends $9,530 on their entire business for a year.** Your Pro tier at $99/mo is $1,188 — **12.5% of the median member's total annual business spend, for one marketing tool.** Your Team tier at $249/mo is $2,988 — **31%.** That is not a plausible allocation for the median member.

### How many agents actually transact

Two irreconcilable datasets, and you need both:

- **Consumer Federation of America** (n=2,000 randomly sampled from five major firms, published Jan 2024): **70% sold 5 or fewer homes; 49% sold 1 or 0; median agent did 2 sales/year.** "The residential real estate industry is clearly a part-time industry." Also cited: top 20% of agents handle 80–90% of transactions.
- **NAR self-reported** (2025 Member Profile): median 10 deals; **only 5% of residential-specialist members reported zero transactions.**
- The viral "70% of agents sold zero homes in 2025" claim is **false as stated** — it traces to a Redfin executive's conference remark and conflates all active MLS licenses with practicing agents ([Yahoo Finance fact-check](https://finance.yahoo.com/news/did-70-real-estate-agents-173943894.html)).

**Reconciliation:** NAR's number is survey-response-biased toward successful full-timers; CFA's is a random sample of licensees. The truth is closer to CFA's. Assume roughly **300,000–500,000 US agents who list enough property to plausibly need listing-media software every month.**

### TAM / SAM / SOM

| Layer | Definition | Size | Annual revenue at $49–99 |
|---|---|---|---|
| **Fantasy TAM** | All US license holders | ~3.0M | ~$1.8B–3.6B |
| **Nominal TAM** | NAR members | 1.44M | ~$850M–1.7B |
| **Honest SAM** | Agents who take **6+ listings/year**, therefore have recurring listing-media need. Applying CFA's distribution to NAR membership: roughly the top 25–30% | **~350,000–430,000** | ~$205M–510M |
| **Realistic SAM** | Of those, the share who (a) will pay for a *standalone* media tool rather than use free Zillow 3D / brokerage-bundled tools, and (b) film their own video rather than hire a photographer. Zillow's own data says rich-media listings are only **11% of for-sale listings**, and Showcase — the paid tier — is on **5%** | **~50,000–90,000** | **~$30M–$105M** |
| **Credible 3-year SOM** for a self-funded new entrant with no MLS or brokerage channel | 1–3% of realistic SAM | **~1,000–2,500 paying accounts** | **~$600K–$2.5M ARR** |

That last row is the honest planning number. It is a real business. It is not a gold mine, and it will not be won by product quality alone.

**Non-real-estate verticals (venues, restaurants, retail, gyms):** these have *no MLS rules* — a genuine advantage — but far lower willingness to pay, no annual renewal event, no listing-media budget line, and Google Street View trusted-photographer programs plus CloudPano/Panoee at $0–49/mo already serve them. **The stronger non-MLS wedges are new-construction builders, multifamily leasing/property management, and short-term-rental operators** — all have real, recurring media budgets and no MLS branding restrictions. Restaurants and gyms are a distraction; they buy media once and never again.

---

## 3. What agents actually complain about, and what actually wins

### The single most important buying criterion is not price

Zillow's agent survey (report dated **19 February 2026**): **"ease of use is agents' top priority when choosing new tech tools, above both cost and time savings."** Agents use only **2–4 tools weekly**. The stated pain is **cognitive load from fragmented workflows** ([Barchart summary](https://www.barchart.com/story/news/302216/zillow-report-agents-want-tech-that-saves-brainpower)).

**Implication:** your seven-feature product (scroll tour + photo edits + aerial + reels + floor plan + lead capture + multi-industry) is *the thing agents are complaining about*. Every feature you add makes the sale harder, not easier.

### What agents are cancelling in 2026

Per [MyStateMLS](https://www.mystatemls.com/blog/client_resources/tools-real-estate-agents-will-stop-paying-for.html), agents are cutting: single-purpose lead-gen platforms ("the cost often outweighs the results"), standalone social schedulers (now built into platforms), basic website builders (pretty but don't produce business), outdated CRMs, premium design subscriptions ("AI and templates now enable quick creation… without expensive subscriptions"), redundant email tools, and duplicate transaction tools.

**The pattern: anything that duplicates what's already bundled, or can't show it produced business, gets cut.** Rendprop is vulnerable on both counts — it duplicates Zillow 3D/Showcase and Aryeo, and (today) cannot show attributable business.

### What incumbent users complain about — verbatim

**Matterport (G2, 4.1/5, 96 reviews):**
- "Use any other platform available. The annual carrying fees are wild!"
- "Customer service is nonexistent"; "absolute garbage"
- "Closed ecosystem significantly restricts flexibility"
- One user reported a billing system that "attempted to charge my card over 200 times"

**CloudPano (Capterra, 4.9/5, 61 reviews) — what praise looks like:**
- "So simple and above all, the cost is fantastic compared to all of the other options available."
- "Once you are all set up… you will be able to get in and out of a house in under one hour!"

Note the shape of both: **agents reward cheap + fast + in-and-out. They punish lock-in and recurring cost detached from usage.** iGUIDE has built its entire marketing on this: "Subscription platforms often charge you even when you're not scanning."

### On video specifically

Momenzo's own content lists agent objections: **camera anxiety** ("uncomfortable on camera"), low engagement and weak conversion, no content strategy, generic output (drone shot / walkthrough / stock music), and giving up before results compound.

### Is video-tour ROI real or vanity? — the honest answer

**Mostly unproven, and the industry's headline statistics are laundered.**

- The ubiquitous **"403% more inquiries"** figure originates with **REA Group (realestate.com.au)** — an Australian portal's own study. It is routinely re-attributed in US content as "NAR, 2024," including in [Reel-E's own statistics roundup](https://www.reel-e.ai/blog/real-estate-marketing-statistics). That attribution is wrong. Momenzo markets it as "403% More Listing Inquiries."
- "Video listings sell up to 32% faster" — **Zillow internal data**, vendor-supplied, with "up to."
- "Homes with video sell 6% above asking" — **Realtor.com**, vendor-supplied.
- Reel-E, which sells video software, nonetheless concedes: **"Correlation is not causation — video-using agents may be more marketing-savvy overall."**
- Zillow Showcase's claims are vendor claims too, but they are the best-instrumented ones available: **79% more page views, 76% more saves, 91% more shares, 10% more likely to go pending within 14 days, ~2% higher sale price (~$7–9K)**, and **agents using Showcase on the majority of their listings win 30% more listings** (Zillow marketing) / **35% more** (Q2 2026 earnings call).
- The most credible independent buyer-side number remains NAR's: **38% of buyers found virtual tours "very useful"** — behind photos (81%), property detail (77%), and floor plans (57%).

**The defensible ROI story is not "video sells the house." It is "media wins the listing."** Zillow's own 30–35% listing-win claim is the only large number in this space with a plausible causal mechanism: sellers pick agents who show up with better marketing. NAR 2025 confirms **marketing assistance is sellers' #1 stated ask of an agent (23%)**. Sell that.

---

## 4. Distribution reality

### How real-estate SaaS actually gets adopted — the three proven motions

**1. Free tier + MLS integration + portal/brokerage partnerships (CubiCasa — the playbook to copy).**
CubiCasa gives away the first floor plan, integrated with **100+ MLS partnerships covering "over half of all U.S. agents,"** plus Redfin, NextHome and FBS, and went from **2% of US listings in early 2022 to 1 in 3 listings by October 2025** on 4M+ scans. No direct-to-agent subscription sales motion at the core.

**2. Hardware + photographer channel + enterprise (Matterport).**
Sell the camera to the pro, let the pro sell the agent. Result: 1.2M subscribers, $99.6M subscription revenue, $1.6B exit. Slow, capital-intensive, and now owned by a portal.

**3. Get acquired by the portal (Aryeo, Virtual Staging AI, VRX Studios).**
Aryeo grew to 1,500+ media companies on $3.5M raised and sold to Zillow on 2 August 2023. Virtual Staging AI sold to Zillow October 2024. **This is a legitimate and probably the most likely good outcome for Rendprop — but it requires being the obvious buy, which means owning a distribution asset (agent base, MLS integrations, or a format), not a feature.**

**Brokerage bundling is now the dominant new-vendor channel:**
- Keller Williams × **Rejig.AI** (31 Aug 2026) — AI marketing assistant generating agent-branded posts, **videos**, and market reports at every listing stage, bundled at brokerage level
- Zillow: **100+ brokerage partnerships** for Preview; **50+ brokerages** adopted Showcase (30 Sept 2025); custom discounted Showcase deal with Baird & Warner (Aug 2026)
- eXp's Nexus; Roomvu's Coldwell Banker / Compass / KW relationships

**The uncomfortable read:** every one of these channels ends with the brokerage or portal owning the agent relationship and squeezing the vendor's price. Direct-to-agent subscription at $49–249 is the one motion nobody successful has used.

### Unit economics you must plan against

PropTech SaaS benchmarks ([Qubit Capital](https://qubit.capital/blog/proptech-saas-kpi-benchmarks)):

| Metric | Individual agents | Small brokerages |
|---|---|---|
| CAC | **$50–$200** | $300–$800 |
| LTV | **$800–$2,000** | $3,000–$8,000 |
| Monthly churn | **5–8%** (1–10 seats) | 3–5% |
| Month-1 churn | **~10%**, falling to ~4% by month 3 | — |
| Target LTV:CAC | 4:1–8:1 | — |
| CAC payback | 8–12 months | — |

**Do the arithmetic on your own pricing.** At 6% monthly churn, average tenure is ~17 months. At $49/mo that is **~$830 lifetime revenue**. To hit 4:1 you need **CAC under ~$200** — which rules out paid search (real-estate paid search averages **~$480 per lead**, and internet leads convert at **2–3%**, per [The Close](https://theclose.com/real-estate-lead-generation-statistics/)). Paid acquisition of individual agents for this product **does not work at $49/mo**. It only works at brokerage/MLS scale or through zero-CAC channels (free tier virality, photographer referral, listing-page backlink loops).

There is one more churn hazard specific to you: **the median agent takes 9 listings a year.** A per-listing tool sold monthly is idle most months. That is exactly the resentment iGUIDE monetizes against subscriptions. **Expect churn at the high end of the 5–8% band unless you offer a per-listing or credit-based option.**

---

## 5. Compliance and platform constraints — read this before you ship

### The lead-capture page cannot be attached to the MLS

This is the most concrete product problem in the brief. MLS rules for **unbranded** virtual tour links prohibit, explicitly:

> "Agent, broker, or other branding. Videos and virtual tours must be 'unbranded.'"
> "Contact or other information identifying the listing broker, agent, or any other entity."
> **"Comment or contact forms, ratings (such as 'like,' 'favorite,' or 'vote' options), or social media profiles."**
> "Advertising of any kind, including links to additional content or external sites not related to the specific property."
> Tours must be "presented in a clean and straightforward manner, containing only information about the specific property."
> — [REsearch / Hawaii Information Service MLS knowledge base](https://www.help.hiinfo.com/virtual-tour-links/)

The same source notes YouTube, Dropbox, Google Drive, and agent/broker websites **cannot host compliant tours** because they can't strip branding and extraneous links.

**Consequence:** Rendprop's shareable page with lead capture is a **branded** asset. Most MLSs have two fields (CRMLS, for example, validates both `VirtualTourURLBranded` and `VirtualTourURLUnbranded`), but **the branded field is generally not what syndicates to portals** — the unbranded one is. So the version buyers see on Zillow/Realtor.com is the one that cannot capture leads. **You must ship a dual-output product on day one: one clean unbranded URL for the MLS field, one branded URL with lead capture for the agent's own channels.**

Branding violations are fined. Rhode Island Statewide MLS's schedule (last updated 20 March 2026) charges **$50 for a first branded-photo offense, $100 for the second, escalating $50 each time**, and $2,500 for inappropriate uploads ([RI Realtors PDF](https://www.rirealtors.org/clientuploads/documents/mls/MLS-Fines.pdf)).

### Portal specs

- **Zillow Showcase video:** unbranded clip **up to 120 seconds**, uploaded **via Aryeo by the photographer** — no logos, watermarks, or advertising. Direct listing video upload on standard listings is reported but undocumented (16:9 MP4, ~250MB cap). MLS Virtual Tour field URLs are pulled but "typically display as a Virtual Tour link rather than in the carousel, varying by MLS."
- **Realtor.com:** accepts unbranded tour links via the MLS feed; Zillow Showcase listings are now also syndicated to Realtor.com (per Zillow Q2 2026 call).
- **Redfin:** whitelists hosts. For 3D specifically Redfin states **"we can only display virtual walkthroughs that have a my.matterport.com URL."** Guided video tours are supported only in select markets (Chicago, Minneapolis–St. Paul, DC area, Southern California). **You are not currently a supported host on Redfin, and getting there requires a business-development conversation, not an integration.**

### AI imagery and video disclosure — this is now statutory

| Jurisdiction | Rule | Effective | Penalty |
|---|---|---|---|
| **California AB 723** | Must disclose digitally altered images and **provide access to the original unaltered versions**. Covers AI adding/removing/changing furniture, appliances, flooring, landscaping, views. Basic lighting/crop/color OK. | **1 Jan 2026** | **Up to $2,500 per violation**, plus possible license suspension/revocation |
| **Wisconsin 2025 Act 69** | Disclosure when advertising uses AI "in a way that creates a false or misleading impression"; scope explicitly includes **reels, animations, and generated video** | **1 Jan 2027** | Not specified |
| **New York S9584 (pending)** | Would require disclosure for digital representations including video and immersive media | pending | Existing RPL 441-c: up to **$2,000** for dishonest advertising |
| **NorthstarMLS** | Altered images must be identified **in the caption/filename or on the photo**, AND every staged/AI-enhanced room must include **at least one unaltered "Before" image**. Prohibited: anything depicting permanent features or structural changes that don't exist. | **10 July 2026** | Not specified |
| **NAR Code of Ethics Art. 2 & 12** | Nationwide baseline against misleading advertising | always | Ethics complaint |

**Two Rendprop features are directly in the blast radius:**

1. **The AI "aerial intro" generated from an exterior photo.** HousingWire's disclosure test asks: *"Does the video show movement/perspective never actually captured?"* — and its recommended disclosure language is literally **"Drone-style movement is simulated. No drone footage was captured."** ([HousingWire](https://www.housingwire.com/articles/ai-listing-video-disclosure-test/)). If your AI hallucinates a side of the house it has never seen, in California that is a $2,500-per-violation exposure for your customer.
2. **Virtual staging and declutter.** You must retain and surface originals (CA), and under NorthstarMLS-style rules you must supply a "before" image per altered room.

### Fair housing

HUD issued Fair Housing Act guidance on algorithms and AI in **housing-related advertising and tenant screening (May 2024)**. The live risks in AI-generated listing media are: generated people implying a neighborhood's demographic character; AI-inserted lifestyle cues that function as steering; and neighborhood/lifestyle voiceover copy that describes a preferred *occupant* rather than the *property*. Practical rule for your generator: **never render people, never render religious or cultural objects, never generate neighborhood narration.**

### Consumer backlash is real

Reporting in 2026 documented AI-altered UK listings with hedges morphing into walls and a mangled house number (418 vs 1026) on a Zillow listing; a first-time buyer quoted: **"Using AI in listing photos should be illegal."** A University of Reading surveying academic warned such practices could breach the Property Misdescriptions Act. **The AI-edit category has a trust problem, and it is arriving fast.**

---

## 6. The honest verdict

### Where is the moat? Ranked by durability.

**1. Compliance infrastructure — the only genuinely defensible asset on the list.** Per-MLS rule encoding, automatic branded/unbranded dual output, burned-in and caption-level AI disclosures, retained originals, "before" images, and an audit log the broker can pull. This is boring, expensive, requires ongoing relationship work with hundreds of MLSs, and is exactly what a fast-follower will not build. It also converts your two biggest liabilities (AI edits, AI aerial) into the reason to buy. **Nobody in the AI-listing-media space is doing this well.**

**2. MLS and brokerage integrations.** CubiCasa's 100+ MLS partnerships covering half of US agents took years and cannot be cloned by a better UI. Every integration is a permanent switching cost.

**3. The listing-page as a data asset.** Per-viewer, per-room dwell time, pushed into the agent's CRM and into the seller's weekly report. This is the "silent buyers" gap Inman named on 13 January 2026 — sophisticated tours show *that* someone looked, never *what they were evaluating*. It's sticky because the history lives with you.

**4. Portal-neutrality, temporarily.** CoStar declined to renew Matterport's API agreement with Zillow and changed its ToS on 29 September 2025; **Zillow removed Matterport tours from listings on 20 October 2025**; CoStar issued an open letter on 28 January 2026 clarifying that directly-purchased Matterport media "may post them anywhere." Zillow told agents to replace their tours with alternatives. **There is a live opening for a vendor whose tours work on Zillow, Realtor.com, Homes.com and Redfin without anyone's permission.** Treat this as a 12–24 month window, not a moat.

**Not moats:** the scroll-scrub interaction (clonable in weeks), AI photo edits (sub-$1 commodity, portal-owned), LiDAR floor plans (free Apple API, CubiCasa free tier, Zillow shipping free version in 2026), AI aerial (Zillow SkyTour and Realtor.com FlyAround already shipped), social reels (CapCut/Canva free), lead capture (mature category, and MLS-prohibited in the unbranded field).

### What would make this defensible vs. "a feature Zillow ships in a quarter"?

Be honest: **Zillow has already shipped four of your seven features.** The only structural defenses are:

- **Own the format across all portals**, so agents choose you *because* you're not Zillow — leverage the CoStar/Zillow feud directly and explicitly in positioning.
- **Own compliance**, so the brokerage's legal and compliance officer mandates you. Portals will never optimize for protecting the *agent* from disclosure liability; that's not their P&L.
- **Own the seller relationship**, via a seller-facing weekly marketing report. Portals optimize for the buyer. Nobody is building for the seller, and the seller is who signs the listing agreement.

### The single most likely reason this fails

**Direct-to-agent subscription pricing at $49–$249/month against a free portal alternative, in a market where the median member's total annual business spend is $9,530 and monthly churn for single-agent SaaS runs 5–8%.**

Concretely: you will acquire agents at a CAC you can't sustain (paid search is ~$480/lead in real estate), they will use the product for 9 listings a year and resent paying for 12 months, a competitor at $169/year (Momenzo) or free (Zillow 3D Home) will anchor them, and you will churn out at 6%+ monthly before ever reaching the brokerage or MLS conversations that would have made the business work. You will be dead of unit economics long before anyone copies your scroll interaction.

**Second most likely:** you build seven features for five verticals, none of them best-in-class, and lose every head-to-head demo — against Splat Tour on immersion, Momenzo on price, Zillow on distribution, CubiCasa on floor plans, BoxBrownie on staging quality.

### The strongest realistic wedge

**"Listing media that is legally safe and works on every portal — win the listing, prove it to the seller."**

Specifically:
- **Buyer:** listing-side agents and small teams taking **12+ listings a year** — the top ~25% of NAR members, ~350K people, of whom perhaps 60–90K are addressable.
- **Trigger:** the **listing appointment**, not the listing itself. Zillow's own strongest claim is a 30–35% lift in *listings won*. Sellers' #1 ask is marketing help (23%, NAR 2025).
- **Hero asset:** the **interactive floor plan with video anchored to it** — floor plans rate 57% "very useful" to buyers vs 38% for virtual tours, and the scroll-scrub tour becomes the *navigation layer* on top of the thing buyers actually want.
- **Insurance policy:** built-in AI disclosure and originals-retention, because CA AB 723 went live 1 January 2026 at $2,500 per violation and Wisconsin follows in 2027.
- **Channel:** free unbranded tour for every listing (zero-CAC, seeds MLS fields and portal pages with your player), monetize the branded lead-capture page, the seller report, and team/brokerage seats. Then convert usage into MLS and brokerage deals — CubiCasa's exact path.
- **Pricing:** add a per-listing credit option. A $29–39 per-listing SKU alongside the subscription will materially cut churn among the 9-listings-a-year median agent.

---

## 7. Top 10 things to build next, ranked

**1. Dual-output MLS compliance engine (branded + unbranded), with per-MLS rule checking.**
*Evidence:* MLS unbranded rules explicitly ban "comment or contact forms" and any contact information; CRMLS validates separate `VirtualTourURLBranded` and `VirtualTourURLUnbranded` fields; RI Statewide MLS fines $50/$100 escalating for branded media. **Without this, your product's flagship asset cannot legally be attached to the listing where 100% of the buyer traffic is.** This is not a feature, it's a prerequisite. Ship one clean URL for the MLS field and one branded lead-capture URL for the agent's own channels, generated from the same take.

**2. AI disclosure and provenance layer on every generated asset.**
*Evidence:* California AB 723 effective 1 Jan 2026, **up to $2,500/violation** plus license risk, requires disclosure *and* access to originals. NorthstarMLS (10 July 2026) requires identification in caption/filename or on the photo, plus **an unaltered "Before" image for every altered room**. Wisconsin Act 69 covers generated video from 1 Jan 2027. HousingWire's disclosure test flags simulated camera movement explicitly — which is your AI aerial intro. Build: auto-generated caption text, optional burned-in label, permanent original retention with a public "view original" link, per-room before/after pairing, and a broker-exportable audit log. **This is your only durable moat and your best sales weapon — sell it to compliance officers, not just agents.**

**3. Floor plan as the hero, with the video anchored to it.**
*Evidence:* NAR 2025 buyer survey — floor plans **57%** "very useful," virtual tours **38%**. Zillow: interactive-floor-plan listings get 60% more views, 72% more shares, 79% more saves. CubiCasa went from 2% to **1 in 3 US listings** in three years on floor plans alone. Build: click a room on the plan → the scroll-scrub video jumps and scrubs to that room; a dot tracks position on the plan as the viewer scrolls. **This is the defensible version of scroll-scrub** — it fuses the asset buyers rate highest with the interaction nobody else has. Nobody ships this today. Do it before Zillow's free smartphone floor plans land later in 2026.

**4. Seller-facing weekly listing report.**
*Evidence:* Zillow's strongest and most causally plausible claim is that Showcase-heavy agents win **30–35% more listings**; sellers' #1 stated ask of an agent is marketing help (23%, NAR 2025). Build: an auto-emailed branded weekly report showing views, where viewers came from, which rooms they lingered in, and shares — addressed to the seller, signed by the agent. **The purchase trigger is the listing appointment, and the renewal trigger is the seller asking "can I get that report again?"** This also creates the referral loop: every seller sees your product working, and sellers become buyers who become sellers.

**5. Per-viewer, per-room engagement analytics with CRM push.**
*Evidence:* Inman, 13 Jan 2026 — "the more buyers can see, the less agents know about what they're thinking"; standard tours show only views and time-on-page. Internet leads convert at 2–3%, so agents need triage, not volume. Build: identified-viewer dwell heatmap by room, repeat-visit alerts, and native push into Follow Up Boss / kvCORE / Sierra / LionDesk. **This is the retention hook — the history lives with you and leaving costs the agent their data.**

**6. Free unbranded tier + a per-listing credit SKU.**
*Evidence:* Zillow 3D Home is free; CubiCasa's first plan is free and it now touches a third of US listings; iGUIDE markets explicitly against subscriptions ("charge you even when you're not scanning"); EyeSpy360 sells at $1/image PAYG; Momenzo sells at $169/year; median NAR member's **total annual business spend is $9,530** and takes **9 listings/year**; single-agent SaaS churns **5–8% monthly** with ~10% in month 1. Build: unlimited free unbranded tours (zero-CAC distribution into MLS fields and portal pages, every one carrying your player), plus a **$29–39 per-listing** credit option alongside subscriptions. Keep the subscription for teams. **This single change probably does more for the business than the next five features combined.**

**7. Portal-neutral distribution kit.**
*Evidence:* CoStar declined to renew Matterport's Zillow API agreement (ToS changed 29 Sept 2025); **Zillow removed Matterport tours on 20 Oct 2025** and told agents to find alternatives; CoStar's 28 Jan 2026 open letter did not fully resolve it; Redfin only displays 3D walkthroughs at `my.matterport.com` URLs. Build: guaranteed-compliant unbranded URLs, tested rendering on Zillow/Realtor.com/Homes.com, an MP4 export at Showcase spec (**unbranded, ≤120 s, 16:9**), an oEmbed/iframe embed, and an active push to get whitelisted by Redfin. **Then market it as the headline: "works everywhere, owned by nobody."**

**8. One-take multi-output: reels, stills and tour from the same walkthrough.**
*Evidence:* Agents' #1 tech criterion is **ease of use, above cost and time savings** (Zillow, Feb 2026) and they only keep 2–4 tools; 49% of brokerages already use AI for social (Delta Media, Dec 2025); Trolto, Editora, Momenzo, Roomvu and RICOH360 all monetize auto-reels; CapCut and Canva give templates away. Build: one film session → scroll tour + 3 vertical reels with captions and licensed audio + 20 auto-extracted still frames good enough for the MLS photo set. **The still-frame extraction is the sleeper feature** — photos are the single asset buyers rate highest (81%), and "your video also gave you your photos" is a concrete cost-replacement argument against a $200–400 photo shoot.

**9. Brokerage/MLS distribution product: white-label, seats, SSO, admin compliance dashboard.**
*Evidence:* CubiCasa: **100+ MLS partnerships covering over half of US agents**. Zillow: **100+ brokerage partnerships**, 50+ brokerages on Showcase, a bespoke Baird & Warner deal (Aug 2026). KW × Rejig.AI (31 Aug 2026) bundles AI marketing video at the brokerage level. Agent CAC is $50–200 and paid search runs ~$480/lead — **direct paid acquisition cannot work; channel is the only path.** Build the boring enterprise surface (SSO, seat management, brand kits, a compliance dashboard showing which listings have proper AI disclosures) so a brokerage can say yes.

**10. Test scroll-scrub against alternatives, and be willing to kill it.**
*Evidence:* Splat Tour delivers **free-roam** phone-video tours from **€19/mo**; Zillow's SkyTour uses Gaussian splatting in production; HousingWire's stated criticism of Trolto is precisely that its flythroughs are "non-interactive" — meaning interactivity is the axis competitors are already being judged on, and a scroll rail is the *weakest* form of it. Instrument completion rate, time-in-tour, and lead-form conversion for scroll-scrub vs. plain autoplay video vs. a 360 tour across ≥50 real listings. **If scroll-scrub doesn't measurably beat both, demote it to a presentation format and put the engineering into #1–#5.** Do not let the founding idea outrank the data.

---

## 8. What I could not verify

- **Giraffe360's 2026 US pricing.** Its pricing page blocks automated fetch (robots.txt). Treat all secondhand figures as unreliable.
- **Zillow Showcase's exact market-share cap.** Zillow states Showcase listings are "less than 1% of listings on Zillow" overall and Q2 2026 puts it at ~5% of *new* listings; multiple secondary sources reference market-level scarcity, but I could not retrieve the official Showcase Product Terms (HTTP 429) to confirm any specific per-market percentage cap. **Verify directly before building a competitive claim on it.**
- **Trolto's published tier pricing.** HousingWire lists $59–$249/mo; PropToolFinder lists "custom." Unconfirmed at source.
- **Editora AI, HeyGen for Real Estate pricing** — not published.
- **Exact US licensee count.** ARELLO-sourced "~3 million" (via HomeLight) vs a vendor-compiled 2,130,616. These differ by 40%. Do not build a TAM slide on either without a primary ARELLO citation.
- **Reddit and Facebook agent-group sentiment.** Domain-restricted searches to reddit.com were rejected by the search proxy, and the one Facebook group thread found was robots-blocked. Agent sentiment in this brief comes from G2/Capterra review text, App Store reviews, the Zillow agent survey, Delta Media/RPR surveys, and vendor-published objection lists. **Go read r/realtors yourself, and — more usefully — call 30 listing agents who take 12+ listings a year.** No desk research substitutes for that before you commit to pricing.
- **Whether scroll-scrub actually converts.** No published data exists on this interaction in a property context, by anyone. That is your cheapest and highest-value experiment.

---

## Source index

**NAR / market:** [2026 Member Profile release](https://www.nar.realtor/newsroom/experienced-realtors-anchor-the-industry-as-housing-affordability-remains-top-hurdle-new-nar-report) · [NAR membership count, June 2026](https://www.nar.realtor/news/real-estate-news/nar-leaders-share-strategic-plan-momentum-membership-count-above-budget-forecast) · [HousingWire on 2026 profile](https://www.housingwire.com/articles/nar-2026-member-profile-experience/) · [NAR membership history](https://www.housingwire.com/articles/overblown-rumors-of-demise-nar-has-lost-only-45k-members-since-december/) · [NAR 2026 forecast](https://www.nar.realtor/newsroom/nar-forecast-home-sales-expected-to-jump-14-in-2026) · [2025 existing-home sales total](https://www.inman.com/2026/01/14/2025-existing-home-sales-miss-2024-pace-by-razor-thin-1k-margin/) · [Redfin turnover report](https://www.redfin.com/news/home-turnover-report-2025/) · [CFA agent-productivity study](https://www.housingwire.com/articles/datadigest-study-shows-agents-are-aplenty-most-with-few-or-no-sales/) · [70%-zero-sales fact check](https://finance.yahoo.com/news/did-70-real-estate-agents-173943894.html) · [NAR 2025 Profile of Home Buyers and Sellers](https://www.rirealtors.org/clientuploads/documents/NAR/Homebuyers_and_sellers_trend_2025.pdf) · [HomeLight agent counts](https://www.homelight.com/blog/how-many-realtors-in-the-us/)

**Zillow / portals:** [Zillow 3D Home](https://www.zillow.com/3d-home/) · [Showcase fast facts](https://www.zillow.com/agents/showcase-facts/) · [Showcase cost analysis](https://sofabrain.com/learn/zillow-showcase-cost/) · [Zillow Q2 2026 earnings call](https://www.fool.com/earnings/call-transcripts/2026/08/13/zillow-zg-q2-2026-earnings-call-transcript/) · [Zillow Q2 2026 results coverage](https://www.housingwire.com/articles/zillow-q2-2026-earnings/) · [SkyTour launch](https://www.zillow.com/news/take-home-listings-to-new-heights-with-skytour/) · [Zillow AI Virtual Staging](https://investors.zillowgroup.com/news-and-events/news/news-details/2025/Zillow-brings-AI-powered-Virtual-Staging-to-Showcase-listings/default.aspx) · [Aryeo acquisition](https://www.inman.com/2023/08/02/empowered-with-great-products-zillow-acquires-aryeo/) · [Aryeo pricing](https://www.aryeo.com/pricing) · [Realtor.com FlyAround](https://www.prnewswire.com/news-releases/realtorcom-introduces-flyaround-a-new-360-satellite-view-to-help-home-shoppers-see-the-bigger-picture-302599955.html) · [Homes.com Listing Boost](https://www.homes.com/solutions/boost/agents) · [Zillow agent tech survey](https://www.barchart.com/story/news/302216/zillow-report-agents-want-tech-that-saves-brainpower) · [Adding video to Zillow](https://www.amplifiles.ai/blog/how-to-add-video-to-zillow-listing) · [Redfin tour submission](https://www.redfin.com/news/real-estate-agents-post-virtual-tours-to-redfin/)

**Competitors:** [Matterport plans](https://matterport.com/plans) · [Matterport FY2024 results](https://matterport.com/news/matterport-announces-fourth-quarter-2024-financial-results-with-over-50) · [Matterport 2026 pricing analysis](https://3dtourmaker.com/matterport-pricing) · [Matterport G2 reviews](https://www.g2.com/products/matterport/reviews) · [Matterport honest assessment](https://centexmarketing.com/blog/matterport-in-2026/) · [CubiCasa 1-in-3 milestone](https://www.cubi.casa/1-in-3-listings-cubicasa-floor-plans/) · [CubiCasa pricing](https://www.cubi.casa/pricing/) · [CubiCasa free tier](https://www.cubi.casa/free-services/) · [iGUIDE pricing](https://goiguide.com/pricing) · [EyeSpy360 pricing](https://eyespy360.freshdesk.com/support/solutions/articles/19000121332-how-much-does-eyespy360-cost-/) · [RICOH360 Tours](https://www.ricoh360.com/tours/) · [HousingWire virtual tour software roundup](https://www.housingwire.com/articles/virtual-tour-software/) · [HousingWire virtual staging roundup](https://www.housingwire.com/articles/virtual-staging-companies-apps/) · [BoxBrownie pricing](https://www.boxbrownie.com/virtual-staging) · [Virtual Staging AI pricing](https://www.virtualstagingai.app/prices) · [Momenzo](https://www.momenzo.com/) · [Momenzo App Store](https://apps.apple.com/us/app/momenzo-real-estate-videos/id1465399598) · [Walkly](https://www.walkly.app/en) · [Editora AI](https://www.editora.ai/) · [Roomvu pricing](https://www.roomvu.com/pricing) · [HeyGen for Real Estate](https://www.startuphub.ai/ai-news/ai-video/2026/heygen-targets-real-estate-agents-with-new-ai-video-tools) · [Splat Tour](https://splattour.com/en) · [Splat Labs on Gaussian splatting](https://www.splatlabs.ai/blog/virtual-tours-real-estate-gaussian-splatting) · [CloudPano Capterra reviews](https://www.capterra.com/p/186477/CloudPano/reviews/) · [Asteroom Capterra](https://www.capterra.com/p/206409/Asteroom/)

**Compliance:** [MLS virtual tour link rules](https://www.help.hiinfo.com/virtual-tour-links/) · [CRMLS virtual tour URL field rules](https://devdocs.crmls.org/update/rules/rule-definitions/property-rules/virtual-tour-urlbranded/) · [NorthstarMLS AI/virtual staging guidelines](https://northstarmls.com/insights/guidelines-for-virtual-staging-and-ai-enhanced-listing-photos/) · [AI listing video disclosure test](https://www.housingwire.com/articles/ai-listing-video-disclosure-test/) · [State AI photo disclosure map](https://tryreelestate.com/blog/ai-photo-disclosure-map-2026) · [RI Statewide MLS fine schedule](https://www.rirealtors.org/clientuploads/documents/mls/MLS-Fines.pdf) · [AI compliance for realtors](https://aiandrealtors.com/ai-compliance) · [HUD AI guidance](https://archives.hud.gov/news/2024/pr24-098.cfm) · [AI listing image backlash](https://www.yahoo.com/news/articles/realtors-using-ai-images-homes-121554256.html)

**Distribution / economics:** [PropTech SaaS KPI benchmarks](https://qubit.capital/blog/proptech-saas-kpi-benchmarks) · [Lead generation statistics](https://theclose.com/real-estate-lead-generation-statistics/) · [Tools agents are cutting in 2026](https://www.mystatemls.com/blog/client_resources/tools-real-estate-agents-will-stop-paying-for.html) · [KW × Rejig.AI](https://www.realestatenews.com/2026/08/31/kw-partnership-adds-new-ai-tools-for-agents-exps-nexus-expands) · [Inman AI adoption](https://www.inman.com/2026/06/25/ai-adoption-among-real-estate-agents/) · [Delta Media AI survey](https://www.inman.com/2026/01/29/so-pretty-much-everyone-in-real-estate-is-using-ai-now/) · [Inman AI holdouts, Aug 2026](https://www.inman.com/2026/08/05/tech-roundup-ai-holdouts/) · [Zillow/CoStar Matterport dispute](https://www.housingwire.com/articles/zillow-removes-matterports-from-listings/) · [Propmodo on the feud](https://propmodo.com/costar-and-zillows-feud-is-starting-to-hurt-everyone/) · [CoStar open letter](https://www.costargroup.com/press-room/2026/open-letter-our-matterport-customers) · [Inman "Silent Buyers"](https://www.inman.com/2026/01/13/silent-buyers-the-data-gap-hiding-inside-every-virtual-tour/) · [Video ROI, honest read](https://www.reel-e.ai/blog/do-video-listings-sell-faster) · [Photography pricing](https://www.luxurypresence.com/blogs/real-estate-photography-pricing/) · [Agent expense budget](https://www.luxurypresence.com/blogs/real-estate-agent-expenses-budget/)
