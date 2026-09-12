# Studio public marketing and search handoff — 2026-09-12

## What this unit changes

Worktree: `web-studio-20260912`, starting at `81fa6d21c17b559297fc03e6e548f70d7ce33bad`.
Public marketing only. No Worker runtime, iOS, subscription, provider, App Store or production change is part of this unit.

- `/studio`: static, crawlable browser-editor preview page. Describes local import, trim/reorder, aspect ratios, text overlays, playback, browser-supported export and local content planning. It separates local drafts from connected workspace access, and makes format/support/rollout limits explicit.
- `/industries`: one substantive guide, with five separately linked sections for real estate, event venues, restaurants, retail and fitness. Each has an actual capture → create → share workflow and relevant practical cautions. This is not five near-duplicate keyword landing pages.
- Existing pages: add Studio and Industries to primary/footer navigation, preserve the existing mark and light/dark violet design system, broaden the homepage story beyond real estate and link the preview.
- Correct old homepage/support/LLM-summary text claiming Apple sign-in is required to publish. The iPhone product permits anonymous capture/edit/publish within plan limits; sign-in is for cross-device continuity and membership.
- Remove the homepage's old “waiting for Apple approval” wording. Parent's read-only App Store observation at 2026-09-12 13:36 UTC returned version 1.0/build16 `READY_FOR_SALE` / `READY_FOR_DISTRIBUTION`. This is **not** a claim that this newer source is the shipped iOS binary.
- Replace the illustrative agent card's numerical “tours/enquiries/sold” statistics with content labels, and keep its mockup disclosure.
- Add the two canonical URLs to the public sitemap. Customer-tour crawler policy is unchanged; only the comment's marketing inventory changed.
- Update `llms.txt` as a convenience summary, not as a ranking trick. Clarify reel **clips**, unchanged plans, preview status, and the distinction between experimental spatial reconstruction and supported floor-plan capture.

The actual SVG `public/assets/rendprop-mark.svg` and `site.js` are unchanged. CSS additions use existing tokens (`--accent`, `--panel`, `--ink`, `--dim`) rather than a parallel theme. The existing pricing page changed navigation only: Starter **$49/month or $490/year**, Pro **$99/month or $990/year**, Team **$249/month**. No Team annual sale or new web checkout is introduced.

## Availability contract — do not turn a preview into a false launch

The planned product host is `https://studio.rendprop.com`. Parent's latest instruction was to avoid shipping a dead CTA until that host is ready, superseding the initial request for active Sign in/Open Studio links.

Accordingly all public Studio buttons currently link to the real `/studio` informational page. The planned hostname is text, not an active sign-in destination. The page offers a support email for preview access. It does not claim generally available browser sign-in, cloud draft sync, paid AI generation, production-quality 3D, auto-posting, social connections or web purchases.

When the parent actually verifies the product host and approved rollout:

1. Read back the deployed Studio origin over HTTPS and confirm the editor source/build receipt. Local tests alone do not prove the URL exists.
2. Verify the browser sign-in configuration and the workspace read-service route against the approved account/organization contract. Do not label local-only projects “synced”.
3. Update the **visible** availability copy and its matching FAQ JSON-LD together, plus the summary in `llms.txt`.
4. Replace selected `/studio` information CTAs with `https://studio.rendprop.com` only after the destination works. Update `no-unreleased-studio-cta` and its deliberately failing fixture to a new explicit allowed-origin/availability contract; do not simply remove the assertion.
5. Keep the public informational page canonical at `https://rendprop.com/studio`. Private workspace routes must not be added to the marketing sitemap.

No declaration on this marketing page replaces an editor feature test. Root/peer agents own the editor and connected-account implementation.

## Search decisions, checked against current Google primary guidance

Reviewed 2026-09-12:

- Descriptive titles, readable primary content and ordinary internal links are standard search fundamentals. The two pages render their entire useful text in the HTML response rather than relying on an application shell. [Google SEO Starter Guide](https://developers.google.com/search/docs/fundamentals/seo-starter-guide).
- Google says its AI search features use the same underlying eligibility/best practices; there is no special AI schema or required AI text file. We use clear content and accurate metadata, without promising rankings or answer citations. [AI features and your website](https://developers.google.com/search/docs/appearance/ai-features).
- Structured data must agree with what people can read. New FAQ answers are checked for exact normalized agreement with visible `<details>` answers; no reviews, ratings, fabricated customers or implied testimonials are introduced. [Structured data guidelines](https://developers.google.com/search/docs/appearance/structured-data/sd-policies).
- **Important current change:** Google's September-2026 documentation history says FAQ rich results stopped appearing May 7, 2026, with their documentation removed June 15. The same June entry explicitly says `llms.txt` does not positively or negatively affect Google visibility/rankings. Our FAQ markup is descriptive structured content, not a promise of a rich result or an “AI SEO” advantage. [Google documentation updates](https://developers.google.com/search/updates).
- The sitemap lists the canonical public URLs; `lastmod` changed only for pages changed by this unit. Submitting a sitemap is not an indexing guarantee. [Sitemap guidance](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap).

FAQ answers remain useful to people even without search-result decoration. Industry sections are workflow advice, not claims of measured customer outcomes. Existing dated competitor comparisons elsewhere on the site were not newly researched or certified by this unit.

## Reproducible verification

From `services/edge/tour-host`:

```sh
node --check scripts/check-marketing.mjs
node scripts/check-marketing.mjs
```

Actual static result: **917 assertions**, **7 HTML pages**, **10 new FAQ answers**, **5 industry sections**, **5 unchanged offers**, exit **0**. Each run also requires all **12** deliberately broken in-memory cases to fail for its intended reason:

1. Wrong canonical.
2. Invalid JSON-LD.
3. Visible FAQ/schema mismatch.
4. Removed industry section/anchor.
5. Changed Starter price.
6. Missing industry navigation.
7. Premature Studio-host CTA.
8. Missing local page target.
9. Wrong logo asset.
10. Invalid executable link scheme.
11. Removed sitemap URL.
12. Missing HTML page bytes.

The script reads the actual public files, validates clean-URL/fragment references against that inventory, and emits per-source SHA-256 hashes. It exits nonzero on a missing file, bad fixture, skipped expected failure, or unexpected browser error. There is no silent `--skip` option. The ordinary static check uses Node built-ins and no network.

An independent CLI failure control also ran: `node scripts/check-marketing.mjs --public-dir /definitely-missing-rendprop-marketing-fixture` exited **1** with `MARKETING_CHECK_FAILED: ENOENT`; an absent source tree does not produce an empty green report.

Browser verification uses an **already installed** Playwright module, never a package download. `agent-browser` was not installed on this machine, so the browser skill's fallback was the bundled isolated Playwright/Chromium runtime:

```sh
node scripts/check-marketing.mjs --browser-module /Users/pilksclaes/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright/index.mjs
```

The first completed browser walk passed **179 assertions** across **28 page/viewport combinations**: all seven pages at 360/light, 390/dark, 1024/light and 1440/dark. It checks HTTP200, headings, actual document width, navigation control bounds, mobile open/Escape-close, Studio/Industries link visibility, theme transitions, visible FAQ expansion and click-through Studio navigation. **218 loopback requests; console, page, HTTP and unexpected-origin errors all empty.** The browser and exact owned server close in `finally`.

Two initial test assumptions were rejected rather than “fixed” in production code:

- Existing decorative orbs extend the body's paint bounds but are clipped; `body.scrollWidth=520` on a 360px viewport did **not** mean the document could scroll horizontally (`documentElement=360`). The gate now checks the actual scrolling element, requires body clipping when its paint width is wider, and separately checks visible nav bounds.
- The theme has three states, not two: auto → light → dark → auto. Returning to auto intentionally removes `data-theme`; the gate now requires the exact next state and matching accessible button label.

Final rerun completed at **2026-09-12T15:25:36.791Z** on **Node v25.9.0**, exit **0**, with the same **917 static + 179 browser assertions**, all **12 negative controls caught**, **28 page/viewport combinations**, **218 loopback requests**, and **zero errors**. Source CSS/HTML did not change to accommodate the test corrections.

Private local receipt: `/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-marketing-browser-aukC6E/receipt.json`. It includes all source hashes and four screenshot paths/hashes. The script SHA-256 is `43b6b99c6001b85fbb8607420feeec242d9c2075ff4974d3cf0ff508ff56af51`. Screenshots were taken at scroll position zero and include phone/light, phone/dark, tablet/light and desktop/dark. These temporary artifacts are not deployment receipts and may not survive OS cleanup; this document and the rerunnable source command are the durable handoff.

### Limits and integration

- Chromium layout proof is **not** Safari/WebKit, a physical iPhone, editor export, authentication or deployed-host proof.
- The optional server is a loopback source-static harness, not the Cloudflare runtime and not a proof of production response/CSP headers.
- New pages use the same exact pre-paint theme script as the existing pages. `_headers` is unchanged; deployment should still verify its hash/CSP behavior on served assets.
- No indexing, Search Console, ranking, conversion or enterprise adoption outcome is claimed.
- `package.json` is outside this agent's ownership. Parent should add `node scripts/check-marketing.mjs` to the normal `predeploy`/CI verification path after integration review, without hiding the existing gates.
- `git diff --check` passed during this unit. Other agents' `apps/studio` and Supabase `studio` source changes are not part of this marketing receipt.
