import assert from "node:assert/strict";
import { readFile, readdir, stat } from "node:fs/promises";
import { gzipSync } from "node:zlib";
import path from "node:path";
const root = path.resolve(import.meta.dirname, "..");
const read = async (name) => readFile(path.join(root, "dist", name), "utf8");
const html = await read("index.html");
assert.match(
  html,
  /<meta name="robots" content="noindex, nofollow, noarchive"/,
);
assert.match(html, /<meta name="referrer" content="no-referrer"/);
assert.match(html, /<title>Rendprop Studio/);
assert(!html.includes("/src/"), "Built HTML cannot still reference source.");
const urls = [...html.matchAll(/(?:src|href)="(\/[^"#]+)"/g)].map((m) => m[1]);
assert(urls.some((url) => url.endsWith(".js")));
for (const url of urls)
  assert((await stat(path.join(root, "dist", url))).isFile());
const files = await readdir(path.join(root, "dist/assets"));
let compressed = 0;
assert(files.some((file) => file.endsWith(".js")));
for (const name of files) {
  assert(
    !/\.(map|ts|tsx|env)$/.test(name),
    "No source maps, server files or env files in deployment.",
  );
  const bytes = await readFile(path.join(root, "dist/assets", name));
  compressed += gzipSync(bytes).length;
}
assert(
  compressed < 300_000,
  `Studio assets exceed 300kB gzip (${compressed}).`,
);
assert.equal(
  await read("rendprop-mark.svg"),
  await readFile(path.join(root, "../../docs/brand/rendprop-mark.svg"), "utf8"),
  "Original brand mark must be byte-identical.",
);
const headers = await read("_headers");
for (const required of [
  "X-Robots-Tag: noindex",
  "Cache-Control: no-store",
  "script-src 'self'",
  "frame-ancestors 'none'",
  "object-src 'none'",
  "Referrer-Policy: no-referrer",
])
  assert(headers.includes(required));
assert(!headers.includes("script-src 'self' 'unsafe-inline'"));
assert.equal(await read("robots.txt"), "User-agent: *\nDisallow: /\n");
console.log(
  JSON.stringify({
    gate: "studio-built-assets",
    status: "passed",
    htmlAssets: urls.length,
    builtFiles: files.length,
    gzipBytes: compressed,
    brandIdentical: true,
    privateNoindex: true,
  }),
);
