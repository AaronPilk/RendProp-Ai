# Rendprop SEO setup

What is in place for rendprop.com search and crawler visibility, as of
2026-11-12. The site and blog are served by the `rendprop-tour-host` Worker
(`services/edge/tour-host`). Static pages are in `public/`, and the sitemaps
and customer pages are built in `src/`.

## Accounts (set up 2026-11-12)

- **Google Search Console.** Domain property `rendprop.com` under
  aaron@pilk.ai, verified with a DNS TXT record on the Cloudflare zone. A
  Domain property covers http/https and every subdomain. Leave the TXT record
  in place, because removing it unverifies the property.
- **Sitemaps submitted in Search Console.** `https://rendprop.com/sitemap.xml`
  and `https://rendprop.com/sitemap-blog.xml`. Both show "Success", and the
  blog sitemap has 453 URLs discovered.
- **Bing Webmaster Tools.** Under aaron@pilk.ai, verified with a CNAME record
  on the zone. Leave that record in place too.
- **IndexNow.** Key `11b64868544c2d10c2c069b399f9e160`, served at
  `https://rendprop.com/11b64868544c2d10c2c069b399f9e160.txt`. The file body
  is the key and nothing else (no newline). Bing, Yandex, Seznam, Naver and
  the other IndexNow engines share submissions, so one ping reaches all of them.
  Google does not use IndexNow. It reads the sitemaps.

## Sitemaps

| URL | What it lists | Built by |
| --- | --- | --- |
| `/sitemap.xml` | Index. Points at the three below. | `src/sitemap.ts` `sitemapIndexXml` |
| `/sitemap-site.xml` | Marketing, product and legal pages plus the demo tour `/f/estate-demo` (11 URLs) | `src/sitemap.ts` `SITE_PAGES`, `DEMO_PAGES` |
| `/sitemap-blog.xml` | Blog posts, topic pages and `/compare/*` pages (453 URLs) | static file, written by `scripts/build-blog.mjs` |
| `/sitemap-properties.xml?cursor=…` | Customer listings whose owner opted into indexing, 200 per page | `src/sitemap.ts` `propertySitemapXml`, fed by `/tours/index` |

Rules the tests enforce (`scripts/check-routes.mjs`,
`scripts/check-property-seo.mjs`):

- No `/u/` URL in any sitemap, ever.
- Every `/f/` or `/a/` URL in the site sitemap has to render without noindex.
  That is why the demo portfolio `/a/meridian` was taken out on 2026-11-12:
  every `/a/` page is noindex, and listing one gets flagged as "Submitted URL
  marked noindex". The page still serves. It is just not submitted.
- A customer listing goes into the property sitemap only if
  `allow_indexing` is true.
- Every marketing page listed in the site sitemap has to exist as a file in
  `public/` (the assets binding serves `public/<name>.html` at `/<name>`).

When you change a marketing page, bump its `lastmod` in `SITE_PAGES`. When
you add or edit blog posts, run `npm run build:blog` to rewrite
`sitemap-blog.xml`.

## IndexNow

Run these from `services/edge/tour-host`, after the deploy is live:

```bash
npm run indexnow -- --all              # every URL in the live sitemaps
npm run indexnow -- --since <commit>   # only pages whose source changed since <commit>
npm run indexnow -- --all --dry-run    # show what would go out, send nothing
```

The script reads the live sitemaps, so it can only submit URLs that are
already listed in one. It stops if the live key file does not answer with the
key, which is what happens if you run it before the deploy. Use `--all` after
a big change and `--since` after a small one. Don't run it on a loop, because
resubmitting unchanged URLs gains nothing.

## robots.txt

`public/robots.txt`. The policy in short:

- **Marketing site** (`/`, `/features`, `/pricing`, `/compare`, `/support`,
  `/terms`, `/privacy`, `/blog`, `/llms.txt`): open to everyone. That covers
  ordinary search engines, AI answer bots (OAI-SearchBot, ChatGPT-User,
  Claude-SearchBot, Claude-User, PerplexityBot, Perplexity-User) and AI
  training bots (GPTBot, ClaudeBot, anthropic-ai, Google-Extended,
  Applebot-Extended, CCBot, Bytespider, meta-externalagent). This is
  deliberate. We want Rendprop described accurately in AI answers.
- **Customer pages** (`/f/`, `/u/`, `/a/`, `/property/`): closed to every AI
  crawler listed above, by design. These pages carry agents' and business
  owners' names and phone numbers. The demo tour (`/f/estate-demo`,
  `/property/estate-demo`) is the one exception.
- **Ordinary search engines** are not blocked from customer pages in
  robots.txt. Each page decides for itself with a noindex meta tag or header,
  based on the owner's opt-in. A robots.txt Disallow would stop the crawler
  from ever seeing that tag.
- Both sitemaps are named at the bottom of the file.

## Product pages and the keyword plan

`docs/seo/keywords-20261112.md` is the first keyword list: 39 target
searches grouped by intent, the page that should rank for each, and the first
five new pages. Three of those were built on 2026-11-12:

| Page | Title |
| --- | --- |
| `/listing-video-from-photos` | Listing Video From Photos: Real Estate Video App |
| `/single-property-website` | Single Property Websites for Real Estate Agents |
| `/real-estate-photo-editing-app` | Real Estate Photo Editing & Virtual Staging App |

They are plain static files in `public/`, on the same shell as `/pricing`
(head, nav, footer, theme boot script, analytics snippet). Every price, plan,
trial detail and feature claim on them comes from `pricing.html`,
`index.html`, `features.html`, `compare.html`, `support.html` or `llms.txt`.
When pricing or a feature changes, update these pages along with those. Each
has a visible FAQ that matches its FAQPage JSON-LD, so edit both together.

They are linked from `/` (under the feature grid), `/features` (the listing
site, photo studio and video sections), `/pricing` (under "Every plan
includes"), `/compare` ("Who should pick what"), three blog posts and
`llms.txt`. Blog content may link to them: `check-blog-content.mjs` allows the
three paths.

Still to build: `/tampa-bay-real-estate-photography` (blocked until the owner
supplies real jobs, photos, packages, prices, booking and the towns served;
without those it would be a doorway page) and `/for-real-estate-photographers`.

## Website analytics

The marketing pages use **Cloudflare Web Analytics** (site tag
`aee78d818cb24eebace4f3e851895a0e`, a public value). Set up 2026-11-12.

- **Manual snippet, not automatic injection.** The Cloudflare site is in
  manual snippet mode. Automatic injection put the beacon on every page,
  customer property sites included, and every CSP blocked it, so it counted
  nothing. Leave it in manual mode.
- **Where the snippet is.** In the `<head>` of every static page in `public/`:
  the five hand-written pages, the three product pages, and every blog, topic
  and `/compare/*` page. `scripts/build-blog.mjs` copies it from `index.html`
  the same way it copies the nav and footer, so new blog posts get it on the
  next build.
- **Where it is not.** Anything the Worker renders: `/f/`, `/u/`, `/a/`,
  `/property/`, the spatial viewer, `/join/`, error pages and the legal pages
  (`/terms`, `/privacy` use their own template). Those pages carry agents'
  names, numbers and addresses.
- **CSP.** `public/_headers` adds `https://static.cloudflareinsights.com` to
  `script-src` and `https://cloudflareinsights.com` to `connect-src`, and
  nothing else. The beacon is an external module, so the inline-script hash is
  unchanged. Worker-rendered pages keep their own CSP in `src/index.ts`.
- **Test.** `scripts/check-web-analytics.mjs` (in `npm test`) fails if a static
  page lacks the snippet or has it twice, if the static CSP differs from the
  expected string, if any `src/` template mentions the beacon, or if a
  Worker-rendered customer, legal or error route carries it.
- **Privacy policy.** Section 4 of `/privacy` describes it (no cookies, local
  storage or fingerprinting; aggregate page views, referrer, country, browser
  and device type, load speed; not on agents' published pages, not in the
  app), and Cloudflare's row in section 3 includes it. Effective date
  November 12, 2026.

## llms.txt

`public/llms.txt` is a plain summary for AI assistants: what Rendprop is,
prices, what is and isn't available, key pages, the blog and accuracy notes.
Update it whenever pricing or features change, and keep it in line with
`/pricing` and the App Store listing.

## Changes made 2026-11-12 (branch `claude/seo-sop-20261112`)

- The sitemap index now lists `/sitemap-blog.xml`, and `/a/meridian` is out
  of the site sitemap. Page `lastmod` dates are updated.
- `/pricing` title is now "Rendprop Pricing: Plans from $29.99/mo, 7-Day Free
  Trial" (it was "Rendprop Subscription Information"). The og and twitter
  titles match.
- `/compare` title is now "Rendprop vs AutoReel, Mirino, Arvaum & Rendy (2026
  Comparison)", with a new 146-character description.
- IndexNow key file, plus `scripts/indexnow-submit.mjs` (`npm run indexnow`).
- The keyword plan and three product pages (see "Product pages and the
  keyword plan" above), linked from the home, features, pricing and compare
  pages and three blog posts, and listed in the site sitemap.
- Cloudflare Web Analytics on the marketing pages, the static CSP for it, and
  the privacy policy paragraph (see "Website analytics" above).

Any later tour-host deploy from a different branch has to include this
branch, or it will put the old sitemap and titles back, drop the product pages
and remove the analytics snippet.

## Known follow-ups

1. **Dated property URLs redirect.** The property sitemap lists
   `/property/<address>/<date.slug>` URLs, and when the address is unique,
   those 308 to the address-only canonical `/property/<address>`. Search
   Console files those under "Page with redirect" instead of indexing the
   URL that was submitted, and each one wastes a crawl. To fix it, `/tours/index`
   has to say whether each address is unique, so the sitemap can list the
   canonical URL directly. That is a backend change, deliberately not done
   here. IndexNow `--all` submits these URLs as they are.
2. **Long blog titles.** 190 of the 452 blog and comparison page titles run
   past about 65 characters, and Google cuts them off in results. They were
   left as they are.
3. **Organization `sameAs`.** The home page JSON-LD lists only the App Store.
   Add Instagram, LinkedIn and the rest once the handles are confirmed.
4. **Request indexing** for `/pricing`, `/compare` and the three product pages
   in Search Console (URL Inspection, then Request indexing) after this deploy,
   so they get picked up sooner.
5. **Cloudflare dashboard settings** (AI Crawl Control, managed robots.txt,
   Crawler Hints) are handled in the dashboard, not in this repo. If managed
   robots.txt is turned on, it adds rules ahead of `public/robots.txt`. Check
   that the live `/robots.txt` still matches the policy above afterwards.
6. **Check Web Analytics is counting.** A day after the deploy, the Cloudflare
   Web Analytics dashboard for rendprop.com should show page views. If it shows
   none, check the browser console on `/` for a CSP error.
7. **Tampa Bay service page** needs the owner's real jobs and photos first
   (see the keyword plan).
