#!/usr/bin/env node
// Lints the blog and comparison content under content/ before build-blog.mjs renders it.
// Fails on invented product claims, banned phrasing, bad links and malformed entries.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
const ROOT = fileURLToPath(new URL("..", import.meta.url));
const POSTS = join(ROOT, "content/blog"), COMPARE = join(ROOT, "content/compare");
const BANNED = ["unlock", "elevate", "seamless", "game-changer", "game changer", "revolutioniz", "revolutionis", "cutting-edge", "cutting edge", "in today's", "in today’s", "leverage", "delve", "harness", "supercharge", "effortless", "stunning", "transform your", "to the next level", "whether you're", "whether you’re", "look no further", "in conclusion", "it's important to note", "world of", "tapestry", "testament", "dive into", "navigate the", "unleash", "empower", "robust", "streamline", "synergy", "next-level", "say goodbye", "say hello", "imagine a world", "picture this", "at the end of the day", "the bottom line is"];
const CLAIMS = [
  [/\$\s?(49|99|249)(\.00)?\b/, "launch price"], [/\b(starter|pro|team) plan\b/i, "plan name"], [/free (trial|week|listing)/i, "free promise"],
  [/\b(rendprop|the app)\b[^.]{0,120}\bunlimited\b|\bunlimited\b[^.]{0,120}\b(rendprop|the app)\b/i, "unlimited"], [/\b4k\b/i, "4K claim"], [/drone[- ]smooth/i, "drone-smooth"],
  [/\bfloor ?plans?\b/i, "floor plan"], [/matterport/i, "matterport"], [/\bno hallucinations?\b/i, "no hallucinations"], [/\b(rendprop|the app)\b[^.]{0,120}\bguarantee|\bguarantee[^.]{0,120}\b(rendprop|the app)\b/i, "guarantee"],
  [/\b(autoreel|mirino|arvaum|rendy|cubicasa|boxbrownie|reel-e|heygen|capcut)\b/i, "competitor name"], [/\bstudies show|according to a study|research shows|\d{1,3}% of (agents|buyers|sellers|homes|listings)/i, "invented statistic"],
  [/unbranded (page|link|version|tour)[^.]{0,60}\b(has|with|carries|includes|keeps|shows|still has)\b (an? |the )?(enquiry|contact) form|\bfills? in the enquiry form[^.]*unbranded|enquir(y|ies) (from|through|via) the unbranded/i, "unbranded page has no form"], [/(scheduled?|auto-?post)[^.]{0,40}(from|in|with) rendprop/i, "scheduling claim"],
  [/tour renders?\b|reel clips?\b|aerial intros?\b/i, "metered-unit wording"], [/\b(coming soon|not yet available)\b[^.]{0,60}aerial/i, "obsolete aerial claim"]
];
const ALLOWED_PATH = /^(\/features(#[a-z-]+)?|\/pricing|\/compare(\/(autoreel|mirino|arvaum|rendy))?|\/support|\/f\/estate-demo|\/blog(\/[a-z0-9-]+)?|\/blog\/topic\/[a-z0-9-]+|\/terms|\/privacy)$/;
const TAGS = new Set(["p", "h2", "h3", "ul", "ol", "li", "strong", "em", "a"]);
const strip = (h) => h.replace(/<[^>]+>/g, " ");
let failures = [], count = 0;
const fail = (slug, msg) => failures.push(`${slug}: ${msg}`);
const slugs = new Set(readdirSync(POSTS).filter(f => f.endsWith(".json")).map(f => f.slice(0, -5)));
function lintCommon(d, slug, isCompare) {
  const text = [d.title, d.description, d.tldr, strip(d.html), ...(d.faq || []).flatMap(f => [f.q, f.a])].join("\n");
  const lower = text.toLowerCase();
  for (const b of BANNED) if (lower.includes(b)) fail(slug, `banned phrase "${b}"`);
  if (/[!]/.test(text.replace(/<[^>]*>/g, ""))) fail(slug, "exclamation mark");
  if (/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u.test(text)) fail(slug, "emoji");
  if (/\blandscape\b(?!\s+(video|videos|photo|photos|photograph|photographs|orientation|or portrait|format|frame|frames|version|listing|shot|shots|image|images|set|cut|export|clip|clips|mode|one|ones|side|photo-based))/i.test(text.replace(/landscape-or-portrait/g, ""))) fail(slug, "bare 'landscape'");
  for (const [re, label] of CLAIMS) {
    if (isCompare && (label === "competitor name" || label === "unlimited" || label === "launch price")) continue;
    const m = text.match(re); if (m) fail(slug, `${label}: "${m[0]}"`);
  }
  if (/ai aerial|aerial opening/i.test(text)) for (const para of (d.html.match(/<p>[\s\S]*?<\/p>/g) || []).concat((d.faq || []).map(f => f.a), [d.tldr])) {
    const t = strip(para);
    if (/ai aerial|aerial opening/i.test(t) && !/(allowance|capacity|processor permission|results vary|review)/i.test(t) && !/not a drone|generated/i.test(t)) fail(slug, "aerial mention without qualifiers: " + t.slice(0, 80));
  }
  if (!d.title || d.title.length > 66) fail(slug, "title length"); if (!d.description || d.description.length < 100 || d.description.length > 160) fail(slug, "description length");
  if (!d.tldr) fail(slug, "tldr missing");
  const tags = [...d.html.matchAll(/<\/?([a-z0-9]+)[^>]*>/gi)].map(m => m[1].toLowerCase());
  for (const t of new Set(tags)) if (!TAGS.has(t)) fail(slug, `tag <${t}>`);
  if (/style=|onclick|<script|<img|<table/i.test(d.html)) fail(slug, "disallowed markup");
  for (const m of d.html.matchAll(/href="([^"]*)"/g)) {
    const h = m[1];
    if (/^https?:/.test(h)) { if (!isCompare || !new RegExp("^" + (d.pricingUrl || d.url).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).test(h) && h !== d.url) fail(slug, `external link ${h}`); continue; }
    if (!ALLOWED_PATH.test(h)) fail(slug, `link not allowed ${h}`);
    const bm = h.match(/^\/blog\/([a-z0-9-]+)$/); if (bm && !slugs.has(bm[1])) fail(slug, `link to missing post ${bm[1]}`);
  }
  if (!Array.isArray(d.faq) || d.faq.length < 3 || d.faq.length > 6) fail(slug, "faq count");
  for (const f of d.faq || []) if (!f.q?.endsWith("?") || !f.a || f.a.length < 40) fail(slug, "faq shape");
}
for (const f of readdirSync(POSTS).filter(f => f.endsWith(".json"))) {
  count++; let d; const slug = f.slice(0, -5);
  try { d = JSON.parse(readFileSync(join(POSTS, f), "utf8")); } catch (e) { fail(slug, "invalid JSON"); continue; }
  if (d.slug !== slug) fail(slug, "slug mismatch");
  lintCommon(d, slug, false);
  const words = strip(d.html).split(/\s+/).filter(Boolean).length;
  if (words < 600 || words > 1250) fail(slug, `word count ${words}`);
  if (!d.category) fail(slug, "category"); if (!Array.isArray(d.keywords) || d.keywords.length < 2) fail(slug, "keywords");
  if (!Array.isArray(d.related) || d.related.length < 1) fail(slug, "related"); for (const r of d.related || []) if (!slugs.has(r)) fail(slug, `related missing ${r}`);
  const internal = [...d.html.matchAll(/href="(\/[^"]*)"/g)].length; if (internal < 1 || internal > 5) fail(slug, `internal links ${internal}`);
  if (/<h1/i.test(d.html)) fail(slug, "h1 in body");
}
for (const f of readdirSync(COMPARE).filter(f => f.endsWith(".json"))) {
  count++; let d; const slug = "compare/" + f.slice(0, -5);
  try { d = JSON.parse(readFileSync(join(COMPARE, f), "utf8")); } catch (e) { fail(slug, "invalid JSON"); continue; }
  lintCommon(d, slug, true);
  if (!Array.isArray(d.table) || d.table.length < 8) fail(slug, "table rows");
  for (const r of d.table || []) if (!r.capability || !r.rendprop || !r.them) fail(slug, "table cell");
  if (!d.checked || !d.url || !d.name) fail(slug, "missing meta");
}
if (failures.length) { console.error(`check-blog-content: ${failures.length} problem(s) in ${count} entries\n` + failures.join("\n")); process.exit(1); }
console.log(`check-blog-content: ${count} entries clean (${slugs.size} posts, ${readdirSync(COMPARE).length} comparison pages)`);
