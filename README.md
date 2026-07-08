# Rendprop

**Walk it. Upload it. Fly through it.** Turn any phone walkthrough into a scroll-through cinematic flythrough.

An iOS-first product: an agent records a continuous walkthrough of a property with their iPhone, Rendprop renders it into a drone-style cinematic glide, and the output is a shareable link where viewers scroll to fly through the home. Full product spec lives in [`docs/MASTER-BUILD-PROMPT.md`](docs/MASTER-BUILD-PROMPT.md) — that document is the single source of truth.

## Repo layout

```
apps/
  ios/            Native Swift/SwiftUI capture app (Part 4)
  web/
    player/       Scroll-scrub flythrough share player (Part 5) — WORKING DEMO
    dashboard/    Agent dashboard (Part 13)
services/
  api/            Backend services + Postgres schema (Part 8)
  pipeline/       GPU render pipeline: stabilize → interpolate → grade → encode (Part 6)
infra/            IaC — Cloudflare R2/Stream, Modal, envs (Part 16)
docs/             Master build prompt, architecture notes, roadmap
```

## Current status

**Phase 0 → Phase 1.** The scroll-scrub player (the product's face, and the hardest already-proven piece) has a working demo in `apps/web/player/`. Open `index.html` on an iPhone or desktop to feel the scrub.

Build order (Part 21):
1. **Phase 1 MVP** — capture app + deterministic pipeline + mobile-perfect player + IAP duration-band pricing
2. **Phase 2** — 4K, Cinematic AI hero clips, analytics, CRM, hosting subscriptions
3. **Phase 3** — MLS/RESO, white-label, verticals

## The three decisions that define the economics

1. **Cloudflare Stream** for delivery — per-minute billing, 4K = 1080p cost
2. **Cloudflare R2** for storage — zero egress
3. **Duration-band pricing + streamed-minute caps** — never flat-price a render

## Non-negotiables (Part 38)

No full-length generative video. No canvas scrubbing for long/4K. No Mux for entry tiers. No flat pricing. No web-checkout CTAs inside the iOS app. Mobile perfect, deterministic-first, cost-aware, honest.
