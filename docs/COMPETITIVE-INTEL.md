# Rendprop Competitive Intel — AutoReel & Mirino
*Researched 26 Aug 2026. All third-party facts sourced in the section notes; inferences flagged. Internal strategy doc.*

---

## The one-paragraph read

Both competitors are **photo→AI-video generators**: they animate still listing photos into short reels. Neither touches real footage, neither has a mobile app, neither has floor plans, hosted tours, or lead capture — the entire back half of Rendprop's product doesn't exist in their world. AutoReel is the disciplined incumbent (~5 people, bootstrapped, roughly $3–8M/yr inferred, an SEO machine, and a billing-trust problem). Mirino is a fast-shipping micro-startup (a rebrand of HomeReel.com, ~16 months old) with the best prompting UX in the category and near-zero distribution. Rendprop's wedge against both is the same sentence: **they generate motion that never happened; we film the real home — and turn it into everything the listing needs, from a phone, ending in a lead.**

---

## AutoReel (autoreelapp.com) — the incumbent

**What it is.** Web-only photo→video: each photo becomes a ~3-second AI-animated clip (push/orbit motions), stitched to a 60–75s reel with templates, captions, music, AI voiceover + voice cloning, avatars, VFX (day-to-twilight etc.), a real timeline editor ("Studio"), AI photo edits + virtual staging (with a built-in "virtually staged" disclaimer stamp), Realtor.com import, IG/FB scheduling, and an Enterprise-gated API. Max 1080p. Founded 2023, NYC; CEO Alok Gupta (ex-Facebook PM, ex-Snapchat eng); team ~2–10; no known funding.

**Scale (inferred, order-of-magnitude).** Public Stripe data shows ~7,900 annual-plan coupon redemptions in ~13 months → roughly **$2–6M in annual bookings**, consistent with their claimed 225K videos / 85K signups (signups ≠ customers; their own posts contradict each other 10K vs 85K). Treat as a real, profitable, margin-disciplined business — not a VC land-grab.

**Pricing (live, from their own billing catalog).** Free (watermark, 2/mo) → Essential $59/mo or $399/yr → Growth $139/mo or $1,199/yr → Pro $249/mo or $2,199/yr. Effective ~$11–20 per video. Hard caps everywhere: 20–25 photos/video, 60–75s max, 1080p ceiling, 3–7 VFX, 10–25MB uploads. **They just metered photo edits** (was "free unlimited in beta," now capped + $0.39–0.89 per extra) and raised annual prices ~11% — margin-repair mode.

**Strengths to respect.**
1. **SEO/AEO machine** — ~274 indexed pages, 14 FAQ clusters, competitor-comparison posts, and "Summarize with AI" buttons engineered to seed LLM citations. They own the search phrase "AI real estate video." Don't fight them there; own a different noun.
2. **Feature breadth** — Studio is a real editor; the photo-edit flow (auto-analysis → suggested edits → custom prompt → disclosure stamp) is thoughtful.
3. **Distribution flywheel** — 10% lifetime affiliate, two-sided referral, credits-for-testimonials (which is also why their 4.9★/381 Trustpilot is a solicited number; G2 has exactly 1 incentivized review).
4. Responsive founder who ships fast and answers 1-star reviews personally.

**Weaknesses to attack (ranked).**
1. **Stills in, hallucinations out.** Their own CEO's release notes admit invented ceiling fans/doors; even 5-star reviewers mention "weird things pop up." Structural — they can't fix it without abandoning the product.
2. **Billing trust is bleeding now.** Mid-2026 reviews: trial charges, annual lock-in with no refund clause, an "early activation bonus" that starts billing mid-trial, chatbot-first support. Multiple "complete scam" reviews. Rendprop counter: transparent billing, instant cancel, human support — put it on the pricing page, never name them.
3. **No mobile app** (verified: zero App Store presence). Capture happens on phones; they need a laptop.
4. **Nothing after the MP4** — no floor plans, no hosted tour, no lead capture, no CRM. They sell a file; Rendprop sells a listing outcome.
5. **COGS caps = our feature list.** Their 1080p/75s/25-photo walls are cost walls. Rendprop's real-footage + targeted-AI architecture makes unlimited length and 4K a wedge they can't follow.
6. **Photo-edit metering just angered their heaviest users** — the best switch-campaign window in their history, aimed at photographers.
7. Privacy policy is a 2023 template with zero AI-subprocessor disclosure — compliance is a brokerage-level buying criterion Rendprop can win cheaply (real subprocessor list, retention window, "never trained on your listings," staged-disclosure provenance). One thing to match, not attack: their clean "you own your videos" IP clause.

---

## Mirino (mirino.ai) — the fast-moving upstart

**What it is.** **HomeReel.com rebranded (~mid-2026)**; "Matsuno, Inc. DBA Mirino," Delaware; founder-run (names not public), ~16 months old, apparently bootstrapped, tiny audience (IG ~1.9K, YT ~221 subs). Web-only React SPA with a serious in-browser timeline editor (Remotion), Zillow/Realtor.com/any-URL photo import, virtual staging, character/avatar builder, FB/IG autoposting, and two verticals: real-estate reels + UGC/product ads. **Do not confuse with homereel.app** — a different Miami company whose "4,000+ users" claims get misattributed to Mirino.

**The pricing play: flat-rate unlimited.** Plus $49.99/mo = unlimited generations on their **self-hosted open models** (Wan 2.2, LTX-2.3, an in-house camera-trajectory model on Modal); Pro $109.99/mo adds pay-per-use premium models (Seedance 2.0, Kling v3 via fal, billed at cost × 1.3 — with a bring-your-own-fal-key option that removes the markup). Priority queues throttle heavy users instead of hard caps. This validates Rendprop's own cost architecture — cheap open models for volume, premium models metered.

**The prompting UX — the best in the category, and the thing to learn from:**
- A hardened **default prompt** that locks scene, lighting, framing, and limits motion to what's visible — anti-hallucination scaffolding baked into every generation. (Adopt this pattern for Rendprop's Veo/Kling/Seedance calls.)
- **One sentence → AI-expanded editable brief**, never a blank textarea.
- **Structured variance fields** for recurring content ("what changes each post / what stays the same").
- **Format gates** (aspect, duration, clip count) kept separate from the creative prompt and used as automated success checks.
- **Per-run spend caps in dollars** + cost-aware model routing with plain-language "best for" guidance per model. (Rendprop already has the spend cap; adopt the routing-guidance pattern.)
- **Scheduled agents**: describe a recurring idea → the system plans, generates, self-checks, queues for approval, and autoposts to FB/IG on a schedule. This is their retention loop.

**Weaknesses to attack.** Same structural ones as AutoReel — no real footage (they even published a "fix weird AI glitches" tutorial), no mobile app, no leads/tours/floor plans, ends at an MP4 — plus: zero SEO (client-rendered site), paid-Meta-ads-dependent acquisition at a $49.99 price floor, no community or reviews anywhere, rebrand-induced name confusion, and a free-replacement guarantee that quietly concedes quality variance.

**Strengths to respect.** Product velocity (founder-run, ships constantly), the agent/autoposting retention loop, and a copyable creator program ($50 flat per approved TikTok/Reel, scaling to $700 at 200K views; affiliates get 25% recurring for 12 months).

---

## Head-to-head: where Rendprop stands today

| Capability | AutoReel | Mirino | **Rendprop** |
|---|---|---|---|
| Real walkthrough video in | ✗ | ✗ | **✓ (core)** |
| Drone-style smooth tour | faked from stills | faked from stills | **✓ real footage + AI enhance (Topaz)** |
| Interactive scroll tour + hosted link | ✗ | ✗ | **✓** |
| Lead capture / CRM | ✗ | ✗ | **✓** |
| Floor plans (scan + blueprint) | ✗ | ✗ | **✓** |
| Mobile app | ✗ | ✗ | **✓ native iOS** |
| Photo→reel generation | ✓ mature | ✓ mature | ✓ (new) |
| AI photo edits / staging | ✓ (newly metered) | ✓ | ✓ (+ custom prompting) |
| Custom prompting | 250-char field | **best-in-class** | ✓ (adopt their guardrail patterns) |
| Voiceover / avatars | ✓ | partial | ✗ (needs ElevenLabs key) |
| Captions / music / templates | ✓ | ✓ | partial (reels lack music/captions) |
| Autoposting / scheduled content | IG/FB scheduling | **✓ agents + approvals** | ✗ |
| 4K | ✗ (1080p cap) | ✗ | **✓ (Topaz 4K tier)** |
| Multi-industry (venues/gyms/restaurants…) | ✗ | ✗ | **✓ unique** |
| SEO / content moat | **massive** | none | none yet |
| Referral / affiliate machinery | mature | creator bounties | ✗ not built |

---

## Strategy: the five moves

1. **Own a new noun.** Don't compete for "AI real estate video" (AutoReel owns it in search and LLM citations). Name and own the category Rendprop actually created: the **scroll tour / real walkthrough tour**. Every asset says: *AI guesses what's around the corner — we filmed it.*
2. **Sell the outcome, not the file.** Both rivals end at an MP4 download. Rendprop ends at a hosted tour link that captures a lead. Price and market around listings and leads, not videos.
3. **Build the distribution machine now, not at month twelve.** Their flywheels (lifetime affiliate %, two-sided referral, creator bounties) are why they have reviews and reach. Copy the mechanics day one — especially aimed at **photographers**, AutoReel's paying core, right as their photo-edit metering angers them.
4. **Make trust a feature.** Transparent monthly billing, instant cancel, human support, a real privacy page (AI subprocessors, retention, "never trained on your listings"), and staged-content disclosure everywhere. Cheap for us, expensive for AutoReel to match given their review bleed.
5. **Adopt Mirino's prompting pattern language** into our custom prompting and future scheduled-content feature: hardened default prompts, sentence→brief expansion, format gates as success checks, spend caps, cost-aware routing. Their agent+autoposting loop is the one feature idea worth scheduling next (a weekly auto-reel from the listing library + approval queue).

## Watch list
- AutoReel shipping anything mobile or any real-video ingestion (would signal a pivot at us).
- Mirino's admin-gated "agents" reaching GA + any traction spike from Meta ads.
- Both: pricing moves after our launch (AutoReel will defend margin; Mirino's unlimited tier limits their floor).

---

## Addendum (26 Aug 2026): Arvaum Studio & Rendy

**Arvaum Studio (arvaum.io).** Desktop-first (macOS/Windows + new browser app) AI *photo* editor by Marcus Martinez, a working RE photographer (Rancho Cucamonga). Virtual staging, twilight, declutter, "A&D lighting," custom prompts w/ AI enhancement, 4K photo output, local file storage, 5 concurrent lanes. Pricing: Starter $29/mo (90 cr), Crusher $49/mo (175), Pro $149/mo (600); packs $0.28–0.44/cr; ~$0.25–0.32/edit effective; explicit **no-refund policy**; referral = 50 cr both sides. Video "coming soon." **Cross-promotes Rendy** (invite link on their site — they're partners, not rivals to each other). No mobile app, no real-footage ingestion, no tours/floor plans/leads. Useful to us: their own ROI section anchors outsourced staging at **$5–15/photo**, twilight ~$5 — quote those anchors on our pricing page.

**Rendy (rendy.io).** ZERO21 MEDIA LLC. Photos→Reels for **photographers as an upsell** ("Add $75–150 per shoot"), apply-for-access gated, claims 3.4k+ photographer users. Camera moves (push/slide/parallax), 50+ VFX (day-to-night, helicopter reveal, animated water/fire), animated virtual staging, 6 reels per listing in one click, sales academy + marketing kits. Pricing not public. Positions on "**No hallucinations** — accurately represents the home," yet motion is still synthesized from stills — which validates our real-footage wedge. No mobile app, no hosted tour, no floor plans, no lead capture.

**Net:** all four competitors are photos-in→MP4-out, web/desktop only. The Rendprop wedge (real walkthrough footage, iOS-native capture, hosted scroll tour, floor plans, leads, multi-industry) holds against the entire field.
