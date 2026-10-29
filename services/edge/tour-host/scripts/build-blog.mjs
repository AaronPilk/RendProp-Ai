#!/usr/bin/env node
// Renders content/blog/*.json and content/compare/*.json into static pages under public/,
// on the same shell as the hand-written marketing pages (nav, footer and room backdrop are
// lifted from public/index.html so there is one source of truth for them).
//   node scripts/build-blog.mjs          writes public/blog.html, public/blog/<slug>.html,
//                                        public/blog/topic/<topic>.html, public/compare/<slug>.html,
//                                        public/sitemap-blog.xml
import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
const ROOT = fileURLToPath(new URL("..", import.meta.url));
const PUB = join(ROOT, "public"), POSTS = join(ROOT, "content/blog"), COMPARE = join(ROOT, "content/compare");
const ORIGIN = "https://rendprop.com";
const BUILD_DATE = process.env.BLOG_BUILD_DATE || new Date().toISOString().slice(0, 10);
const TOPICS = {
  photos: ["Listing photos and AI edits", "kitchen"], video: ["Listing videos and social reels", "dusk"], website: ["Property websites, links and the MLS", "living"],
  "ai-trust": ["AI, disclosure and trust", "dusk"], business: ["Listing marketing, workflow and cost", "lake"], photographers: ["Photographers and media companies", "kitchen"],
  industries: ["Beyond homes: venues, restaurants, gyms, retail, offices", "twilight"], howto: ["Using Rendprop: how-tos and answers", "living"],
  questions: ["Questions agents ask", "living"], seasonal: ["Seasonal and situational listing marketing", "lake"], social: ["Social media for agents", "dusk"],
  copy: ["Listing descriptions, captions and copy", "kitchen"], openhouse: ["Open houses and showings", "twilight"], "property-types": ["Property types and special listings", "living"],
  markets: ["Market conditions and local strategy", "twilight"], glossary: ["Glossary: terms explained", "kitchen"]
};
const SCENES = { living: ["scene-living-ocean", 2400, 1340], dusk: ["scene-dusk-lounge", 2400, 1610], kitchen: ["scene-kitchen", 2400, 1340], twilight: ["scene-twilight-pool", 2400, 1340], lake: ["scene-lake-sunset", 2400, 1610] };
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const attr = esc;
const text = (h) => String(h).replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
const jsonld = (g) => `<script type="application/ld+json">\n${JSON.stringify({ "@context": "https://schema.org", "@graph": g }, null, 1)}\n</script>`;
const niceDate = (d) => new Date(d + "T12:00:00Z").toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric", timeZone: "UTC" });

// ---- shell pieces lifted from index.html ----
const index = readFileSync(join(PUB, "index.html"), "utf8");
const navHtml = index.match(/<header class="nav" id="nav">[\s\S]*?<\/header>/)[0];
const footerHtml = index.match(/<footer>[\s\S]*?<\/footer>/)[0];
const bootScript = index.match(/<script>\(function\(\)\{try\{[\s\S]*?<\/script>/)[0];
function nav(current) {
  return navHtml.replace(/ aria-current="page"/g, "").replace(`<a href="${current}">`, `<a href="${current}" aria-current="page">`);
}
function scene(key) {
  const [n, w, h] = SCENES[key];
  return `<div class="scene" aria-hidden="true">\n  <img class="is-on" data-scene="${key}" src="/assets/${n}.webp" srcset="/assets/${n}-1200.webp 1200w, /assets/${n}.webp 2400w" sizes="100vw" width="${w}" height="${h}" alt="" fetchpriority="high" decoding="async">\n</div>`;
}
function head({ title, description, path, type = "website", published, modified }) {
  const url = ORIGIN + path;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(title)}</title>
<meta name="description" content="${attr(description)}">
<link rel="canonical" href="${url}">
<meta name="theme-color" content="#0b0a10" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#e9e5df" media="(prefers-color-scheme: light)">
<meta name="robots" content="index, follow, max-image-preview:large">
<meta name="apple-itunes-app" content="app-id=6808982413">
<meta property="og:type" content="${type}">
<meta property="og:site_name" content="Rendprop">
<meta property="og:title" content="${attr(title)}">
<meta property="og:description" content="${attr(description)}">
<meta property="og:url" content="${url}">
<meta property="og:image" content="${ORIGIN}/assets/og.jpg">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Illustrative modern property at twilight">
${published ? `<meta property="article:published_time" content="${published}">\n<meta property="article:modified_time" content="${modified || published}">\n` : ""}<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${attr(title)}">
<meta name="twitter:description" content="${attr(description)}">
<meta name="twitter:image" content="${ORIGIN}/assets/og.jpg">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/assets/apple-touch-icon.png">
<link rel="stylesheet" href="/assets/site.css">
${bootScript}
<script src="/assets/site.js" defer></script>
`;
}
const crumbs = (items) => ({ "@type": "BreadcrumbList", "itemListElement": items.map(([name, path], i) => ({ "@type": "ListItem", position: i + 1, name, item: ORIGIN + path })) });
const faqNode = (faq) => ({ "@type": "FAQPage", mainEntity: faq.map((f) => ({ "@type": "Question", name: f.q, acceptedAnswer: { "@type": "Answer", text: f.a } })) });
const faqHtml = (faq, heading = "Questions on this topic") => `<section class="post-faq" aria-label="Questions" data-scene="dusk">
  <div class="wrap">
    <p class="eyebrow">FAQ</p>
    <h2>${esc(heading)}</h2>
    <div class="faq">
${faq.map((f) => `      <details>\n        <summary>${esc(f.q)}</summary>\n        <p>${esc(f.a)}</p>\n      </details>`).join("\n")}
    </div>
  </div>
</section>`;
const cta = `<section class="cta-band" aria-label="Get the app">
  <div class="wrap">
    <h2>Try it on your next listing.</h2>
    <p class="lede center">Free to download. Rendprop shows current plan features and included usage in the app; Apple shows purchase and offer terms before confirmation.</p>
    <p style="margin-top:28px;">
      <a class="app-badge" href="https://apps.apple.com/us/app/id6808982413?ct=site&amp;mt=8">
        <svg class="apple" width="22" height="22" viewBox="0 0 24 24" fill="none" aria-hidden="true"><rect x="6" y="2" width="12" height="20" rx="3" stroke="#fff" stroke-width="1.8"/><circle cx="12" cy="18.4" r="1.1" fill="#fff"/></svg>
        <span class="t"><small>Free on iPhone · iOS&nbsp;16+</small><b>Download on the App&nbsp;Store</b></span>
      </a>
      <a class="btn btn-ghost" href="/f/estate-demo" style="margin-left:10px;">Open the live demo listing</a>
    </p>
  </div>
</section>`;
const card = (p) => `      <a class="card" href="/blog/${p.slug}">
        <span class="card-kicker">${esc(TOPICS[p.category]?.[0] || p.category)}</span>
        <span class="card-title">${esc(p.title)}</span>
        <span class="card-desc">${esc(p.description)}</span>
        <span class="card-meta">${p.minutes} min read</span>
      </a>`;

// ---- load content ----
const posts = readdirSync(POSTS).filter((f) => f.endsWith(".json")).map((f) => {
  const p = JSON.parse(readFileSync(join(POSTS, f), "utf8"));
  if (!p.published) { p.published = BUILD_DATE; writeFileSync(join(POSTS, f), JSON.stringify(p, null, 2) + "\n"); }
  p.words = text(p.html).split(" ").length; p.minutes = Math.max(3, Math.round(p.words / 220));
  return p;
}).sort((a, b) => a.title.localeCompare(b.title));
const bySlug = Object.fromEntries(posts.map((p) => [p.slug, p]));
const byTopic = {}; for (const p of posts) (byTopic[p.category] ||= []).push(p);
for (const t of Object.keys(byTopic)) if (!TOPICS[t]) throw new Error("unknown topic " + t);
const compares = readdirSync(COMPARE).filter((f) => f.endsWith(".json")).map((f) => { const c = JSON.parse(readFileSync(join(COMPARE, f), "utf8")); if (!c.published) { c.published = BUILD_DATE; writeFileSync(join(COMPARE, f), JSON.stringify(c, null, 2) + "\n"); } return c; }).sort((a, b) => a.name.localeCompare(b.name));
mkdirSync(join(PUB, "blog/topic"), { recursive: true }); mkdirSync(join(PUB, "compare"), { recursive: true });
let written = 0;
const write = (rel, html) => { writeFileSync(join(PUB, rel), html); written++; };

// ---- posts ----
for (const p of posts) {
  const [topicLabel, sceneKey] = TOPICS[p.category];
  const related = (p.related || []).map((s) => bySlug[s]).filter(Boolean).slice(0, 4);
  const path = `/blog/${p.slug}`;
  const graph = [
    { "@type": "WebPage", "@id": ORIGIN + path + "#page", url: ORIGIN + path, name: p.title, description: p.description, isPartOf: { "@id": ORIGIN + "/#site" }, breadcrumb: { "@id": ORIGIN + path + "#crumbs" }, datePublished: p.published, dateModified: p.modified || p.published, inLanguage: "en-US" },
    { ...crumbs([["Rendprop", "/"], ["Blog", "/blog"], [topicLabel, `/blog/topic/${p.category}`], [p.title, path]]), "@id": ORIGIN + path + "#crumbs" },
    { "@type": "BlogPosting", "@id": ORIGIN + path + "#post", headline: p.title, description: p.description, abstract: p.tldr, keywords: (p.keywords || []).join(", "), articleSection: topicLabel, wordCount: p.words, datePublished: p.published, dateModified: p.modified || p.published, mainEntityOfPage: { "@id": ORIGIN + path + "#page" }, image: ORIGIN + "/assets/og.jpg", inLanguage: "en-US",
      author: { "@type": "Organization", name: "Rendprop", url: ORIGIN + "/" }, publisher: { "@type": "Organization", "@id": ORIGIN + "/#org", name: "Rendprop", logo: { "@type": "ImageObject", url: ORIGIN + "/assets/apple-touch-icon.png" } }, isPartOf: { "@type": "Blog", "@id": ORIGIN + "/blog#blog", name: "Rendprop blog" } },
    faqNode(p.faq)
  ];
  const html = `${head({ title: `${p.title} — Rendprop`, description: p.description, path, type: "article", published: p.published, modified: p.modified })}
${jsonld(graph)}
</head>
<body>

<a class="skip" href="#main">Skip to content</a>

${scene(sceneKey)}

${nav("/blog")}

<main id="main">

<section class="page-hero post-hero" data-scene="${sceneKey}" aria-label="Article intro">
  <div class="wrap">
    <nav class="crumbs" aria-label="Breadcrumb"><a href="/blog">Blog</a><span aria-hidden="true">/</span><a href="/blog/topic/${p.category}">${esc(topicLabel)}</a></nav>
    <h1>${esc(p.title)}</h1>
    <p class="lede">${esc(p.description)}</p>
    <p class="post-meta"><time datetime="${p.published}">${niceDate(p.published)}</time> · ${p.minutes} min read · by Rendprop</p>
  </div>
</section>

<section class="post-body" aria-label="Article">
  <div class="wrap">
    <article class="post">
      <p class="post-tldr"><strong>Short answer.</strong> ${esc(p.tldr)}</p>
${p.html.trim()}
    </article>
  </div>
</section>

${faqHtml(p.faq)}

<section class="post-related" aria-label="Related reading" data-scene="${sceneKey}">
  <div class="wrap">
    <p class="eyebrow">Keep reading</p>
    <h2>Related guides</h2>
    <div class="cards">
${related.map(card).join("\n")}
    </div>
    <p class="center" style="margin-top:28px;"><a class="btn btn-ghost" href="/blog/topic/${p.category}">All posts on ${esc(topicLabel.toLowerCase())}</a></p>
  </div>
</section>

${cta}

</main>

${footerHtml}

</body>
</html>
`;
  write(`blog/${p.slug}.html`, html);
}

// ---- topic pages ----
for (const [topic, [label, sceneKey]] of Object.entries(TOPICS)) {
  const list = byTopic[topic] || []; if (!list.length) continue;
  const path = `/blog/topic/${topic}`;
  const description = `${list.length} guides on ${label.toLowerCase()} from Rendprop: practical, specific and written for agents, photographers and business owners.`;
  const graph = [
    { "@type": "CollectionPage", "@id": ORIGIN + path + "#page", url: ORIGIN + path, name: label, description, isPartOf: { "@id": ORIGIN + "/#site" }, breadcrumb: { "@id": ORIGIN + path + "#crumbs" }, inLanguage: "en-US" },
    { ...crumbs([["Rendprop", "/"], ["Blog", "/blog"], [label, path]]), "@id": ORIGIN + path + "#crumbs" },
    { "@type": "ItemList", itemListElement: list.map((p, i) => ({ "@type": "ListItem", position: i + 1, name: p.title, url: ORIGIN + "/blog/" + p.slug })) }
  ];
  write(`blog/topic/${topic}.html`, `${head({ title: `${label} — Rendprop blog`, description, path })}
${jsonld(graph)}
</head>
<body>

<a class="skip" href="#main">Skip to content</a>

${scene(sceneKey)}

${nav("/blog")}

<main id="main">

<section class="page-hero" data-scene="${sceneKey}" aria-label="Topic intro">
  <div class="wrap">
    <nav class="crumbs" aria-label="Breadcrumb"><a href="/blog">Blog</a><span aria-hidden="true">/</span><span>${esc(label)}</span></nav>
    <h1>${esc(label)}</h1>
    <p class="lede">${esc(description)}</p>
  </div>
</section>

<section aria-label="Posts">
  <div class="wrap">
    <div class="cards cards-3">
${list.map(card).join("\n")}
    </div>
  </div>
</section>

${cta}

</main>

${footerHtml}

</body>
</html>
`);
}

// ---- blog index ----
{
  const path = "/blog";
  const description = `${posts.length} practical guides on listing photos, video, property websites, the MLS, AI disclosure and marketing for agents, photographers and businesses.`;
  const graph = [
    { "@type": "CollectionPage", "@id": ORIGIN + path + "#page", url: ORIGIN + path, name: "Rendprop blog", description, isPartOf: { "@id": ORIGIN + "/#site" }, breadcrumb: { "@id": ORIGIN + path + "#crumbs" }, inLanguage: "en-US" },
    { ...crumbs([["Rendprop", "/"], ["Blog", path]]), "@id": ORIGIN + path + "#crumbs" },
    { "@type": "Blog", "@id": ORIGIN + "/blog#blog", name: "Rendprop blog", url: ORIGIN + path, publisher: { "@id": ORIGIN + "/#org" }, blogPost: posts.slice(0, 50).map((p) => ({ "@type": "BlogPosting", headline: p.title, url: ORIGIN + "/blog/" + p.slug, datePublished: p.published })) },
    { "@type": "ItemList", name: "Topics", itemListElement: Object.entries(TOPICS).filter(([t]) => byTopic[t]).map(([t, [label]], i) => ({ "@type": "ListItem", position: i + 1, name: label, url: ORIGIN + "/blog/topic/" + t })) }
  ];
  const topicSections = Object.entries(TOPICS).filter(([t]) => byTopic[t]).map(([t, [label, sceneKey]], i) => `
<section id="${t}" data-scene="${sceneKey}" aria-label="${attr(label)}">
  <div class="wrap">
    <div class="topic-head">
      <div><p class="eyebrow">${byTopic[t].length} guides</p><h2>${esc(label)}</h2></div>
      <a class="btn btn-ghost" href="/blog/topic/${t}">See all</a>
    </div>
    <div class="cards cards-3">
${byTopic[t].slice(0, 6).map(card).join("\n")}
    </div>
  </div>
</section>`).join("\n");
  write("blog.html", `${head({ title: "Rendprop blog — listing photos, video, property websites and the MLS", description, path })}
${jsonld(graph)}
</head>
<body>

<a class="skip" href="#main">Skip to content</a>

${scene("living")}

${nav("/blog")}

<main id="main">

<section class="page-hero" data-scene="living" aria-label="Blog intro">
  <div class="wrap">
    <p class="eyebrow">The Rendprop blog</p>
    <h1>Listing marketing,<br><span class="grad-text">explained by people who do it.</span></h1>
    <p class="lede">${esc(description)} Start with a topic, or use the search on your browser.</p>
    <div class="chips" aria-label="Topics">
${Object.entries(TOPICS).filter(([t]) => byTopic[t]).map(([t, [label]]) => `      <a class="chip" href="#${t}">${esc(label)}</a>`).join("\n")}
    </div>
  </div>
</section>
${topicSections}

<section aria-label="Comparisons" data-scene="dusk">
  <div class="wrap">
    <p class="eyebrow">Honest comparisons</p>
    <h2>Rendprop against the other tools.</h2>
    <div class="cards cards-3">
${compares.map((c) => `      <a class="card" href="/compare/${c.slug}"><span class="card-kicker">Comparison</span><span class="card-title">${esc(c.title)}</span><span class="card-desc">${esc(c.description)}</span><span class="card-meta">Checked ${esc(c.checked)}</span></a>`).join("\n")}
    </div>
  </div>
</section>

${cta}

</main>

${footerHtml}

</body>
</html>
`);
}

// ---- comparison pages ----
for (const c of compares) {
  const path = `/compare/${c.slug}`;
  const graph = [
    { "@type": "WebPage", "@id": ORIGIN + path + "#page", url: ORIGIN + path, name: c.title, description: c.description, isPartOf: { "@id": ORIGIN + "/#site" }, breadcrumb: { "@id": ORIGIN + path + "#crumbs" }, datePublished: c.published, dateModified: c.modified || c.published, inLanguage: "en-US", about: [{ "@type": "SoftwareApplication", name: "Rendprop", url: ORIGIN + "/" }, { "@type": "SoftwareApplication", name: c.name, url: c.url }] },
    { ...crumbs([["Rendprop", "/"], ["Compare", "/compare"], [c.name, path]]), "@id": ORIGIN + path + "#crumbs" },
    { "@type": "Article", "@id": ORIGIN + path + "#article", headline: c.title, description: c.description, abstract: c.tldr, datePublished: c.published, dateModified: c.modified || c.published, mainEntityOfPage: { "@id": ORIGIN + path + "#page" }, image: ORIGIN + "/assets/og.jpg", inLanguage: "en-US", author: { "@type": "Organization", name: "Rendprop", url: ORIGIN + "/" }, publisher: { "@type": "Organization", "@id": ORIGIN + "/#org", name: "Rendprop", logo: { "@type": "ImageObject", url: ORIGIN + "/assets/apple-touch-icon.png" } } },
    faqNode(c.faq)
  ];
  write(`compare/${c.slug}.html`, `${head({ title: `${c.title} — Rendprop`, description: c.description, path, type: "article", published: c.published, modified: c.modified })}
${jsonld(graph)}
</head>
<body>

<a class="skip" href="#main">Skip to content</a>

${scene("living")}

${nav("/compare")}

<main id="main">

<section class="page-hero post-hero" data-scene="living" aria-label="Comparison intro">
  <div class="wrap">
    <nav class="crumbs" aria-label="Breadcrumb"><a href="/compare">Compare</a><span aria-hidden="true">/</span><span>${esc(c.name)}</span></nav>
    <p class="eyebrow">Honest comparison · checked ${esc(c.checked)}</p>
    <h1>${esc(c.title)}</h1>
    <p class="lede">${esc(c.description)}</p>
    <p class="post-meta">Facts about ${esc(c.name)} were taken from its public website in ${esc(c.checked)} and may have changed. <a href="${attr(c.pricingUrl || c.url)}" rel="nofollow noopener">Check ${esc(c.name)}'s site</a> for current details.</p>
  </div>
</section>

<section aria-label="Short answer">
  <div class="wrap">
    <article class="post">
      <p class="post-tldr"><strong>Short answer.</strong> ${esc(c.tldr)}</p>
    </article>
    <div class="tbl-wrap">
      <table class="cmp">
        <thead><tr><th scope="col">Capability</th><th scope="col" class="us">Rendprop</th><th scope="col">${esc(c.name)}</th></tr></thead>
        <tbody>
${c.table.map((r) => `          <tr><td>${esc(r.capability)}</td><td class="us">${esc(r.rendprop)}</td><td>${esc(r.them)}</td></tr>`).join("\n")}
        </tbody>
      </table>
    </div>
    <p class="tbl-note">Rendprop column reflects the current public app; launch plans and included usage are being finalized and the app shows current plan features. ${esc(c.name)} column from its public materials, ${esc(c.checked)}.</p>
  </div>
</section>

<section class="post-body" aria-label="Comparison" data-scene="kitchen">
  <div class="wrap">
    <article class="post">
${c.html.trim()}
    </article>
  </div>
</section>

${faqHtml(c.faq, `${c.name} or Rendprop: common questions`)}

<section aria-label="Other comparisons" data-scene="living">
  <div class="wrap">
    <p class="eyebrow">More comparisons</p>
    <h2>Rendprop against the other tools.</h2>
    <div class="cards cards-3">
${compares.filter((o) => o.slug !== c.slug).map((o) => `      <a class="card" href="/compare/${o.slug}"><span class="card-kicker">Comparison</span><span class="card-title">${esc(o.title)}</span><span class="card-desc">${esc(o.description)}</span><span class="card-meta">Checked ${esc(o.checked)}</span></a>`).join("\n")}
      <a class="card" href="/compare"><span class="card-kicker">Overview</span><span class="card-title">The full comparison table</span><span class="card-desc">Every tool side by side, with the fair profiles and the straight answer on who should pick what.</span><span class="card-meta">rendprop.com/compare</span></a>
    </div>
  </div>
</section>

${cta}

</main>

${footerHtml}

</body>
</html>
`);
}

// ---- sitemap ----
{
  const urls = [["/blog", BUILD_DATE], ...Object.keys(TOPICS).filter((t) => byTopic[t]).map((t) => [`/blog/topic/${t}`, BUILD_DATE]), ...posts.map((p) => [`/blog/${p.slug}`, p.modified || p.published]), ...compares.map((c) => [`/compare/${c.slug}`, c.modified || c.published])];
  write("sitemap-blog.xml", `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map(([u, d]) => `  <url><loc>${ORIGIN}${u}</loc><lastmod>${d}</lastmod></url>`).join("\n")}\n</urlset>\n`);
}
console.log(`build-blog: ${posts.length} posts, ${Object.keys(byTopic).length} topics, ${compares.length} comparisons → ${written} files written`);
