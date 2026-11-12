import assert from "node:assert/strict";
import { readFile, readdir, stat } from "node:fs/promises";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import path from "node:path";
import { connectedProductionConfig, verifyConnectedBundle, releaseAssetGroups, DIST_BUDGETS } from "./dist-policy.mjs";
const args = process.argv.slice(2);
assert(args.every((arg) => arg === "--require-connected") && args.length <= 1, "Only --require-connected is supported.");
const requireConnected = args.includes("--require-connected");
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
const gzipByFile = new Map(), jsChunks = [];
assert(files.some((file) => file.endsWith(".js")));
for (const name of files) {
  assert(
    !/\.(map|ts|tsx|env)$/.test(name),
    "No source maps, server files or env files in deployment.",
  );
  const bytes = await readFile(path.join(root, "dist/assets", name));
  assert(!bytes.includes(Buffer.from("studioFixture")), "Connected test fixture must not ship.");
  assert(!bytes.includes(Buffer.from("ISOLATED_FIXTURE_NOT_REAL")), "Fixture account config must not ship.");
  const gzipBytes = gzipSync(bytes).length;
  compressed += gzipBytes;
  gzipByFile.set(`assets/${name}`, gzipBytes);
  if (name.endsWith(".js")) jsChunks.push(bytes.toString("utf8"));
}
// Measured 2026-09-24: initial 135,545 B; signed-in Create 215,519 B;
// all routes/tools ~317 kB. The prior 300 kB summed every lazy workspace.
// Named projects, licensed audio/captions and explicit 720p copies justify a
// 350 kB total cap, paired with tighter 160/260 kB actual workflow budgets.
const manifest = JSON.parse(await read(".vite/manifest.json"));
const groups = releaseAssetGroups(manifest);
const groupSize = (files) => files.reduce((total, file) => {
  assert(gzipByFile.has(file), `Manifest asset missing from dist: ${file}.`);
  return total + gzipByFile.get(file);
}, 0);
const workflowGzip = Object.fromEntries(Object.entries(groups).map(([name, assets]) => [name, groupSize(assets)]));
assert(workflowGzip.initial < DIST_BUDGETS.initial, `Initial load exceeds ${DIST_BUDGETS.initial} B gzip (${workflowGzip.initial}).`);
assert(workflowGzip.create < DIST_BUDGETS.create, `Signed-in Create exceeds ${DIST_BUDGETS.create} B gzip (${workflowGzip.create}).`);
assert(compressed < DIST_BUDGETS.total, `All Studio assets exceed ${DIST_BUDGETS.total} B gzip (${compressed}).`);
if (requireConnected) {
  const fileText = await readFile(path.join(root, ".env.production.local"), "utf8").catch((error) => { if (error.code === "ENOENT") return ""; throw error; });
  const expected = connectedProductionConfig(fileText, process.env);
  verifyConnectedBundle(jsChunks, expected);
}
assert.equal(
  await read("rendprop-mark.svg"),
  await readFile(path.join(root, "../../docs/brand/rendprop-mark.svg"), "utf8"),
  "Original brand mark must be byte-identical.",
);
const headers = await read("_headers");
for (const required of [
  "X-Robots-Tag: noindex",
  "Cache-Control: no-store, no-transform",
  "script-src 'self'",
  "frame-ancestors 'none'",
  "object-src 'none'",
  "Referrer-Policy: no-referrer",
])
  assert(headers.includes(required));
assert(!headers.includes("script-src 'self' 'unsafe-inline'"));
const cspLine = headers.split("\n").find((line) => line.trimStart().startsWith("Content-Security-Policy:"));
assert(cspLine, "Built Studio must include its content security policy.");
const cspDirectives = new Map(cspLine.slice(cspLine.indexOf(":") + 1).split(";").map((directive) => {
  const [name, ...sources] = directive.trim().split(/\s+/);
  return [name, sources];
}));
for (const name of ["img-src", "media-src", "connect-src"]) {
  const sources = cspDirectives.get(name) ?? [];
  assert(sources.includes("https://rendprop.com"), `${name} must allow the authenticated Rendprop media gateway.`);
  assert(!sources.includes("*") && !sources.includes("https:") && !sources.includes("https://*.rendprop.com"), `${name} cannot replace the exact media gateway with a broader origin.`);
}
assert.equal(await read("robots.txt"), "User-agent: *\nDisallow: /\n");
assert(!(await readdir(path.join(root, "dist"))).includes("tests"), "No test entrypoints may be deployed.");
// The executable dependency and its exact unmodified source travel together.
// Source archives are fetched only from the notices link, never by the app.
const sourceManifest = JSON.parse(await read("licenses/mediabunny-source-manifest.json"));
const dependencyRoot = path.join(root, "node_modules/mediabunny");
const dependencyPackage = JSON.parse(await readFile(path.join(dependencyRoot, "package.json"), "utf8"));
assert.equal(sourceManifest.name, dependencyPackage.name);
assert.equal(sourceManifest.version, dependencyPackage.version);
assert.equal(sourceManifest.license, "MPL-2.0");
assert.equal(sourceManifest.sourceUnmodified, true);
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const sourceMembers = [];
async function dependencyMembers(directory, prefix = "") {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    assert(!entry.isSymbolicLink(), "Dependency source cannot change through a symlink.");
    const name = prefix + entry.name;
    if (entry.isDirectory()) await dependencyMembers(path.join(directory, entry.name), name + "/");
    else if (entry.isFile()) sourceMembers.push([name, digest(await readFile(path.join(directory, entry.name)))]);
  }
}
await dependencyMembers(dependencyRoot);
sourceMembers.sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
assert.equal(sourceMembers.length, sourceManifest.packageFiles);
assert.equal(digest(sourceMembers.map(([name, hash]) => `${name}\t${hash}\n`).join("")), sourceManifest.packageTreeSha256, "Distributed source must match the installed dependency.");
for (const name of [sourceManifest.sourceArchive, sourceManifest.licenseFile])
  assert(typeof name === "string" && /^[A-Za-z0-9_.-]+$/.test(name), "Unsafe source-distribution path.");
const sourceArchive = await readFile(path.join(root, "dist/licenses", sourceManifest.sourceArchive));
assert.equal(sourceArchive.length, sourceManifest.sourceArchiveBytes);
assert.equal(digest(sourceArchive), sourceManifest.sourceArchiveSha256);
const dependencyLicense = await readFile(path.join(dependencyRoot, "LICENSE"));
assert.equal(await read(`licenses/${sourceManifest.licenseFile}`), dependencyLicense.toString("utf8"));
assert.equal(digest(dependencyLicense), sourceManifest.licenseFileSha256);
const thirdPartyNotice = await read("THIRD-PARTY-NOTICES.txt");
assert(thirdPartyNotice.includes(`Mediabunny ${dependencyPackage.version}`));
assert(thirdPartyNotice.includes(`/licenses/${sourceManifest.sourceArchive}`));
assert(jsChunks.some((chunk) => chunk.includes("/THIRD-PARTY-NOTICES.txt")), "The source notice must be reachable from Studio.");

console.log(
  JSON.stringify({
    gate: "studio-built-assets",
    status: "passed",
    htmlAssets: urls.length,
    builtFiles: files.length,
    gzipBytes: compressed,
    workflowGzip,
    gzipBudgets: DIST_BUDGETS,
    connectedConfigVerified: requireConnected,
    brandIdentical: true,
    privateNoindex: true,
  }),
);
