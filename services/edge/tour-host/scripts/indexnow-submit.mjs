#!/usr/bin/env node
// indexnow-submit.mjs — tell IndexNow engines (Bing, Yandex, Seznam, Naver…)
// which rendprop.com URLs exist or just changed, so they recrawl in minutes
// instead of waiting for their next scheduled visit.
//
//   node scripts/indexnow-submit.mjs --all            every URL in the live sitemaps
//   node scripts/indexnow-submit.mjs --since <commit> only pages whose files changed
//                                                     since <commit> (post-deploy)
//   add --dry-run to print the payload without sending it
//
// The key is public by design: IndexNow proves ownership by fetching
// https://rendprop.com/<key>.txt and comparing its body to the key we send.
// Only pages that are in a sitemap are ever submitted, so a noindex customer
// tour or an unbranded /u/ twin can never be pushed through here.

import { execFileSync } from "node:child_process";
import { readdirSync } from "node:fs";

const HOST = "rendprop.com";
const ORIGIN = `https://${HOST}`;
const ENDPOINT = "https://api.indexnow.org/indexnow";
const UA = "Mozilla/5.0 (compatible; rendprop-indexnow/1.0; +https://rendprop.com)";

const keyFile = readdirSync(new URL("../public/", import.meta.url)).find((f) => /^[a-f0-9]{32}\.txt$/.test(f));
if (!keyFile) { console.error("STOP: no public/<32-hex>.txt IndexNow key file"); process.exit(1); }
const KEY = keyFile.slice(0, -4);

const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const sinceIdx = args.indexOf("--since");
const since = sinceIdx >= 0 ? args[sinceIdx + 1] : null;
if (!args.includes("--all") && !since) {
  console.error("usage: indexnow-submit.mjs --all | --since <commit> [--dry-run]");
  process.exit(2);
}

async function text(url) {
  const r = await fetch(url, { headers: { "User-Agent": UA } });
  if (!r.ok) throw new Error(`${url} answered ${r.status}`);
  return r.text();
}
const locs = (xml) => [...xml.matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/g)].map((m) => m[1].replace(/&amp;/g, "&"));

async function sitemapUrls() {
  const seen = new Set(), urls = new Set();
  const queue = [`${ORIGIN}/sitemap.xml`, `${ORIGIN}/sitemap-blog.xml`];
  while (queue.length) {
    const sm = queue.shift();
    if (seen.has(sm)) continue;
    seen.add(sm);
    const xml = await text(sm);
    if (xml.includes("<sitemapindex")) queue.push(...locs(xml));
    else for (const u of locs(xml)) urls.add(u);
  }
  return urls;
}

// public/foo/bar.html → /foo/bar ; public/index.html → / ; the Worker-rendered
// sitemap-site pages map from their source files.
function changedPaths(commit) {
  const out = execFileSync("git", ["diff", "--name-only", `${commit}..HEAD`, "--", "."], { encoding: "utf8" });
  const paths = new Set();
  for (const line of out.split("\n").map((l) => l.trim()).filter(Boolean)) {
    const m = line.match(/public\/(.+)\.html$/);
    if (m) paths.add(m[1] === "index" ? "/" : "/" + m[1].replace(/\/index$/, ""));
    if (/src\/legal\.ts$/.test(line)) { paths.add("/terms"); paths.add("/privacy"); }
    if (/src\/demo\.ts$/.test(line)) paths.add("/f/estate-demo");
  }
  return paths;
}

const all = await sitemapUrls();
let urlList;
if (since) {
  const wanted = changedPaths(since);
  urlList = [...all].filter((u) => wanted.has(new URL(u).pathname));
  if (wanted.size) urlList.push(`${ORIGIN}/sitemap.xml`);
} else {
  urlList = [...all];
}
urlList = [...new Set(urlList)].filter((u) => u.startsWith(ORIGIN + "/") && !/\/u\//.test(u));

if (!urlList.length) { console.log("indexnow: nothing changed, nothing sent"); process.exit(0); }

if (!dryRun) {
  const keyBody = (await text(`${ORIGIN}/${KEY}.txt`).catch(() => "")).trim();
  if (keyBody !== KEY) { console.error(`STOP: ${ORIGIN}/${KEY}.txt does not serve the key yet (deploy it first)`); process.exit(1); }
}

let sent = 0, failed = 0;
for (let i = 0; i < urlList.length; i += 10000) {
  const batch = urlList.slice(i, i + 10000);
  const body = { host: HOST, key: KEY, keyLocation: `${ORIGIN}/${KEY}.txt`, urlList: batch };
  if (dryRun) { console.log(JSON.stringify({ ...body, urlList: `${batch.length} urls`, sample: batch.slice(0, 5) }, null, 1)); continue; }
  const r = await fetch(ENDPOINT, { method: "POST", headers: { "Content-Type": "application/json; charset=utf-8", "User-Agent": UA }, body: JSON.stringify(body) });
  console.log(`indexnow: ${batch.length} urls → HTTP ${r.status}`);
  if (r.status === 200 || r.status === 202) sent += batch.length; else { failed += batch.length; console.log(await r.text()); }
}
console.log(dryRun ? `indexnow dry run: ${urlList.length} urls` : `indexnow: ${sent} accepted, ${failed} refused`);
process.exit(failed ? 1 : 0);
