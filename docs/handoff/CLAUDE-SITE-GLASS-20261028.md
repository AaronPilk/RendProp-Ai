# Claude handoff: rendprop.com glass redesign, SEO, blog and comparison pages

Date: 2026-10-28
Branch: `claude/site-glass-20261028`
Base: `origin/codex/release-qa-integration-20261026` at `3fbed331ea7c61b0c5b45e0f775a14bfe23af7b5`
Target PR base: `codex/release-qa-integration-20261026`
Scope: the marketing site only (`services/edge/tour-host/public/`, two new scripts, `content/`, `package.json` scripts, this note). No Worker source, routing, property-site, billing, app or App Store change.

Commits (oldest first):

- `dda50a69` rendprop.com: glass over photography design system (`public/assets/site.css`, `site.js`, five `scene-*.webp` room photographs)
- `72291dc9` rendprop.com: pages on the new shell (the five HTML pages)
- `25e16309` rendprop.com: structured data, Blog in navigation, comparison links
- `4c6915de` tour-host: blog engine and content lint (`scripts/build-blog.mjs`, `scripts/check-blog-content.mjs`, `package.json`)
- `1b913fcf` content: 432 blog posts and four comparison pages (`content/blog/*.json`, `content/compare/*.json`)
- `5023022a` rendprop.com: generated blog, topic, index and comparison pages (`public/blog.html`, `public/blog/**`, `public/compare/**`, `public/sitemap-blog.xml`)

## 00. What the owner asked for

Glass interface floating over the property's own photography (the look of the code.xr "Glassy Dashboard V5" post: frosted pill navigation, a floating icon rail, translucent cards, soft page transitions), applied to rendprop.com. Then: everything SEO-optimised with schema, hundreds of SEO and AI-SEO optimised blog posts, and a dedicated page per competitor.

## 01. Design

- One full-bleed room photograph sits behind every page (`.scene`, fixed). Sections carry `data-scene` and the room cross-fades as they reach the middle of the viewport; secondary rooms load when idle (`site.js`). Five rooms (AI-generated, from the existing Higgsfield set): living-ocean, dusk-lounge, kitchen, twilight-pool, lake-sunset, as 2400w and 1200w WebP.
- Panels: every `section > .wrap` and the footer is frosted glass (`--paper`, 22px blur, 16px on phones). Cards inside are translucent fills with no blur, so phones never stack blur on blur. `.band-dark` sections are smoked glass and carry dark tokens for everything inside (the inline SVG on Features reads them too).
- Navigation: three floating capsules (brand, page links, actions), 52px bar with 44px controls, selected page as a filled pill. Below 900px the links become an opaque sheet; opening it from the keyboard moves focus to the first link; Escape closes and returns focus. A section rail with tooltips shows on the Home and Features pages at 1340px and wider.
- Controls: one capsule system (filled, outlined, App Store) of the same height; press feedback on pointer-down; hover only on fine pointers. Dark theme fills use `--fill` (#7c3aed) so white text clears AA; the lighter `--accent` stays for icons and rings.
- Cross-document view transitions (`@view-transition { navigation: auto }`); the scene keeps its name so the room persists while panels cross-fade. `view-transition-name` on the nav was removed: in Chromium it made the opaque mobile sheet paint translucent.
- Reduced motion removes movement and keeps opacity cross-fades; reduced transparency and `prefers-contrast: more` make every surface opaque; forced colours drop the photograph; a `@supports not (backdrop-filter)` fallback raises panel opacity.
- The hash-pinned theme boot script is byte-identical on every page (CSP in `_headers` unchanged). No external resources, no inline handlers.

## 02. SEO and AI SEO

- Every page has one JSON-LD graph: Home adds a `WebPage` and `sameAs`; Features, Pricing, Compare and Support add a `WebPage` tied to the `WebSite` and their `BreadcrumbList`. Existing nodes (Organization, SoftwareApplication, FAQPage, ItemList, ContactPage, Article) unchanged.
- Blog posts: `WebPage`, `BreadcrumbList`, `BlogPosting` (headline, abstract, keywords, section, wordCount, dates, author and publisher Organization, isPartOf Blog) and `FAQPage`. Topic pages: `CollectionPage` + `ItemList`. Blog index: `CollectionPage`, `Blog` (first 50 posts), `ItemList` of topics. Comparison pages: `WebPage` with `about` both products, `Article`, `BreadcrumbList`, `FAQPage`.
- Every post opens with a quotable short answer (`tldr`, rendered as "Short answer"), uses question-shaped headings, and carries 3–5 FAQs; glossary posts open with a one-sentence definition.
- `robots.txt` adds `Sitemap: https://rendprop.com/sitemap-blog.xml` beside the Worker-served `/sitemap.xml` (check-routes still requires that line; it is kept). `llms.txt` lists the comparison pages and the blog topics and dates the update.
- Blog replaces the FAQ shortcut in the page links (FAQ stays on Home and Support) and is in the footer. Compare links to each full comparison page; Rendy's row shows its now-public per-listing pricing.

## 03. Blog engine

- Source of truth: `content/blog/<slug>.json` (slug, title, description, category, keywords, tldr, html, faq, related, published) and `content/compare/<slug>.json` (adds name, url, pricingUrl, table, checked).
- `npm run check:blog` (`scripts/check-blog-content.mjs`) refuses: launch prices, plan names, trials, allowance wording, 4K, drone, floor plans, guarantees about the app, an Aerial opening mention without its qualifiers, competitor names outside the comparison pages, invented statistics, a contact form on the unbranded page, scheduling claims, banned marketing phrases, exclamation marks, emoji, external links (comparison pages may link their subject once), missing related posts, wrong lengths. It runs in `predeploy`.
- `npm run build:blog` (`scripts/build-blog.mjs`) writes `public/blog.html`, `public/blog/<slug>.html`, `public/blog/topic/<topic>.html`, `public/compare/<slug>.html` and `public/sitemap-blog.xml`. The nav, footer and boot script are lifted from `public/index.html` at build time, so edit the nav there and rebuild. Set `BLOG_BUILD_DATE=YYYY-MM-DD` for a stable `lastmod`; a post's `published` is written back into its JSON on first build.
- Routing: `/blog`, `/blog/<slug>`, `/blog/topic/<topic>`, `/compare/<name>` and `/sitemap-blog.xml` reach Workers Static Assets through the existing fall-through in `src/index.ts` (verified with the build-src harness and an ASSETS stub emulating `auto-trailing-slash`). No Worker change.

## 04. Content

- 432 posts in 16 topics (27 each): photos, video, website, ai-trust, business, photographers, industries, howto, questions, seasonal, social, copy, openhouse, property-types, markets, glossary. Average 914 words, 706–1099. Written by sixteen writer passes and eight editorial passes against `BRIEF.md` (fact sheet from `llms.txt` and the launch contract, banned phrases, allowed links), then the lint. The brief, QA brief, competitor fact sheet and title plan are in the evidence folder.
- Product facts in posts are limited to what the site already publishes. Market rates are the "typical U.S. rates as of August 2026" figures already on the site. No statistics, studies, customers, quotes or competitor claims in posts. MLS and legal matters are phrased as "check your MLS's current rules / ask your broker".
- Comparison pages (AutoReel, Mirino, Arvaum Studio, Rendy): facts from their public sites in October 2026, dated and linked once; each credits the competitor's strengths and names when it is the better pick. AutoReel and Mirino prices are not quoted (client-rendered pricing pages); Arvaum and Rendy prices are quoted as seen, with "may have changed".
- Known soft spots to read before deploy: the three how-to posts the writers flagged as thin in the fact sheet (`teams-in-rendprop-inviting-people-and-what-they-can-see`, `how-to-use-rendprop-studio-on-the-web-alongside-the-iphone-app`, `how-to-delete-your-rendprop-account-and-what-happens-to-your-media`) stay deliberately outcome-level; the term "story section" for the property page's free-text block appears across the copy cluster (rename if the app calls it something else); a few posts use British spellings (enquiry, colour) consistent with the site.

## 05. Checks (local, Linux sandbox, Chromium headless)

- All 20 scripts in `npm test`, plus `check-property-seo`, `check-address-share-links`, `check-address-only-canonical`, `check-assets`, `check-blog-content`, and `tsc --noEmit`: all pass on the final tree (logs in the evidence folder).
- Rendered-pixel contrast sampling over every text element on the five pages (both themes, 390 and 1440) and on the blog index, a post and a comparison page: no failures (the only flagged items were paragraphs whose dominant pixels are a button, i.e. false positives).
- 44px targets, accessible names, landmarks, keyboard menu (open with Enter, Tab into the sheet, Escape closes and restores focus), one room showing at a time, rail tracking: all pass on all pages.
- Screenshots: before (live) and after (light and dark) at 390, 768, 1024, 1440 and 1920 for all five pages; section-by-section at 1440; menu open, reduced motion; blog index, post, topic and comparison pages.
- Not verified: Safari and iOS (no WebKit in the sandbox); the live Worker; real-device scrolling performance of backdrop-filter panels over the fixed photograph on older iPhones (if it stutters, lower `--blur` on phones in `site.css`).

## 06. Push and PR (Mac)

```
cd "/Users/pilksclaes/Rendprop AI/RendProp-Ai"
git log --oneline 3fbed331..claude/site-glass-20261028
git push -u origin claude/site-glass-20261028
gh pr create --base codex/release-qa-integration-20261026 --head claude/site-glass-20261028 --title "rendprop.com: glass redesign, structured data, blog and comparison pages" --body-file "/Users/pilksclaes/Rendprop AI/Claude outputs/site-glass-20261028/PR-BODY.md"
```

## 07. Deploy notes

- Deploy is the normal tour-host path (`npx wrangler deploy` from `services/edge/tour-host`, after `npm run predeploy`). Static assets gain ~11 MB of HTML (454 files); well inside Workers Static Assets limits.
- After deploy, fetch `/blog`, one post, one topic page, `/compare/rendy` and `/sitemap-blog.xml` on the live host; submit `sitemap-blog.xml` in Search Console alongside the existing sitemap.
- To add posts later: write `content/blog/<slug>.json`, run `npm run check:blog`, then `npm run build:blog`, commit both.
