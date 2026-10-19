import assert from "node:assert/strict";
import { test } from "node:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

// Execute the actual readback verifier with an isolated build and a closed
// transport. These controls never make requests to the deployment.
// RENDPROP_VERIFIER runs the same controls against another copy of the verifier
// (for example the previous revision); RENDPROP_RELEASE_DIST adds a closed-transport
// readback of a real built dist folder.
const verifierUrl = process.env.RENDPROP_VERIFIER ? pathToFileURL(resolve(process.env.RENDPROP_VERIFIER)) : new URL("../scripts/verify-deployed.mjs", import.meta.url);
const sha = (bytes: string | Buffer) => createHash("sha256").update(bytes).digest("hex");
const PROBES = ["/auth/callback?rendprop_route_probe=1", "/?rendprop_route_probe=1", "/workspace", "/assets/__rendprop_verify_missing__.js"];
const HEADERS: Record<string, string> = { "x-robots-tag": "noindex, nofollow", "cache-control": "no-store, no-transform", "x-content-type-options": "nosniff", "referrer-policy": "no-referrer", "content-security-policy": "script-src 'self'; frame-ancestors 'none'" };
const SAFE_OUTPUT = /^assets\/[A-Za-z0-9_.-]+\.(?:js|css)$/;
type Item = { file: string; css?: string[]; assets?: string[]; imports?: string[]; dynamicImports?: string[]; isEntry?: boolean; isDynamicEntry?: boolean; [field: string]: unknown };
type Build = { manifest: string; files: Record<string, string | Buffer>; links?: Record<string, string>; folders?: string[]; root?: string };
type Output = { status: string; GETRequests: number; inventory: Record<string, unknown>; files: { path: string; bytes: number; sha256: string; transformation: unknown }[]; warnings: string[]; [field: string]: unknown };

// Vite manifest from building a8390ac4 with the connected public configuration.
// All 36 served files of that build match the reviewed release hashes. The qrcode
// dependency key records this machine's node_modules location; keys are identifiers.
const ACTUAL_MANIFEST = readFileSync(new URL("./fixtures/studio-manifest-a8390ac4.json", import.meta.url), "utf8");
// Independent oracle: the 33 assets in the reviewed a8390ac4 release build.
const ACTUAL_ASSETS = [
  "assets/AdvancedPropertyReels-BDPt4X2i.js", "assets/AdvancedPropertyReels-Ce6ZKYAm.css", "assets/BusinessWorkspace-BclFGVZ8.js", "assets/CloudPlanner-BmZgTc_h.js",
  "assets/CloudPlanner-kODEfhvb.css", "assets/CreativeWorkspace-gkMUvrCK.css", "assets/CreativeWorkspace-wzV_vWBt.js", "assets/ListingWorkflow-Ccm9nJTn.js",
  "assets/ListingWorkflow-DaXRhfk3.css", "assets/MakeVideo--lzLD1VQ.css", "assets/MakeVideo-DGtD7sqC.js", "assets/PresenterPanel-B9Ya__Sb.css",
  "assets/PresenterPanel-pnPwVvUn.js", "assets/Projects-BDhZ78CV.css", "assets/Projects-DMLfzOVk.js", "assets/PromptLibrary-BMwVF3qQ.css",
  "assets/PromptLibrary-CX28wYOx.js", "assets/PropertyReels-CknEv8gZ.js", "assets/ProxyPanel-pEmY7pey.js", "assets/RealEstateRolePicker-BEJkLH_s.css",
  "assets/RealEstateRolePicker-HN1HCbDp.js", "assets/SyncStatus-h7VEvNez.js", "assets/api-CYT80BYD.js", "assets/cloud-media-4A0fbS_5.js",
  "assets/cloud-media-CskToBGL.css", "assets/delivery-kit-CFxAJ0Z2.js", "assets/documents-Brx7wgso.js", "assets/index-BEk682bz.js",
  "assets/index-DFgkfuA0.css", "assets/model-CwzsXYoU.js", "assets/qrcode-DtWdxa9d.js", "assets/uploads-CXtUxFlU.js",
  "assets/video-framing-CKKCRNgK.js",
];

const outputsOf = (item: Item) => [item.file, ...(item.css ?? []), ...(item.assets ?? [])];
const entryHtml = (entry: Item) => `<!doctype html><title>Isolated Studio build</title><link rel="icon" href="/rendprop-mark.svg"><script type="module" crossorigin src="/${entry.file}"></script>${(entry.css ?? []).map((file) => `<link rel="stylesheet" href="/${file}">`).join("")}`;
function buildFrom(manifest: string, extra: Record<string, string> = {}): Build {
  const items = JSON.parse(manifest) as Record<string, Item>;
  const files: Record<string, string | Buffer> = { "index.html": entryHtml(items["index.html"]), "robots.txt": "User-agent: *\nDisallow: /\n", "rendprop-mark.svg": "<svg/>" };
  // Only safe output paths become files; unsafe ones exist to be refused.
  for (const item of Object.values(items)) for (const file of outputsOf(item)) if (SAFE_OUTPUT.test(file)) files[file] = `/* ${file} */export default ${JSON.stringify(file)};`;
  return { manifest, files: { ...files, ...extra } };
}
function editedActual(edit: (items: Record<string, Item>) => void, extra: Record<string, string> = {}) {
  const items = JSON.parse(ACTUAL_MANIFEST) as Record<string, Item>;
  edit(items);
  return buildFrom(JSON.stringify(items, null, 2), extra);
}
// A Vite-shaped build: entry with CSS, a shared static chunk with a CSS-only key,
// lazy dynamic entries and a dynamic-only dependency whose key begins with ../.
function syntheticManifest(assetCount: number) {
  const lazy = Array.from({ length: assetCount - 5 }, (_, index) => `src/features/Lazy${index}.tsx`);
  const items: Record<string, Item> = {
    "index.html": { file: "assets/index-entry.js", name: "index", src: "index.html", isEntry: true, imports: ["_shared-a.js"], dynamicImports: lazy, css: ["assets/index-entry.css"] },
    "_shared-a.js": { file: "assets/shared-a.js", name: "shared", imports: ["index.html"], css: ["assets/shared-a.css"] },
    "_shared-a.css": { file: "assets/shared-a.css", src: "_shared-a.css" },
    "../../node_modules/dependency/index.mjs": { file: "assets/dependency.js", name: "dependency", src: "../../node_modules/dependency/index.mjs", isDynamicEntry: true },
  };
  lazy.forEach((key, index) => { items[key] = { file: `assets/Lazy${index}-chunk.js`, name: `Lazy${index}`, src: key, isDynamicEntry: true, imports: ["index.html", "_shared-a.js"], ...(index === lazy.length - 1 ? { dynamicImports: ["../../node_modules/dependency/index.mjs"] } : {}) }; });
  return JSON.stringify(items, null, 2);
}
// The dynamic-only dependency chunk: reachable solely through another chunk's dynamicImports.
const dynamicOnly = (manifest: string) => { const items = JSON.parse(manifest) as Record<string, Item>; return items[Object.keys(items).find((key) => key.startsWith("../"))!].file; };
// Headers the built _headers file assigns to every path (used for a real release dist).
function builtHeaders(root: string) {
  const headers: Record<string, string> = {};
  let all = false;
  for (const line of readFileSync(join(root, "_headers"), "utf8").split("\n")) {
    if (!line.startsWith(" ")) { all = line.trim() === "/*"; continue; }
    const at = line.indexOf(":");
    if (all && at > 0) headers[line.slice(0, at).trim().toLowerCase()] = line.slice(at + 1).trim();
  }
  return headers;
}

const HEADER_FAULTS: Record<string, [Record<string, string | null>, RegExp]> = {
  "noindex-missing": [{ "x-robots-tag": null }, /\/noindex\//],
  "noindex-changed": [{ "x-robots-tag": "index, follow" }, /\/noindex\//],
  "no-store-missing": [{ "cache-control": "no-transform" }, /\/no-store\//],
  "no-transform-missing": [{ "cache-control": "no-store" }, /\/no-transform\//],
  "nosniff-missing": [{ "x-content-type-options": null }, /null[\s\S]*'nosniff'/],
  "referrer-changed": [{ "referrer-policy": "strict-origin" }, /'strict-origin'[\s\S]*'no-referrer'/],
  "csp-missing": [{ "content-security-policy": null }, /Response CSP missing/],
  "csp-script-src-missing": [{ "content-security-policy": "default-src 'self'; frame-ancestors 'none'" }, /Response CSP missing/],
  "csp-frame-ancestors-missing": [{ "content-security-policy": "script-src 'self'" }, /Response CSP missing/],
};
const ROBOTS_TEST_PREFIX = "User-agent: *\nContent-Signal: search=yes,ai-train=no\nAllow: /\n\n";
let runs = 0;

async function runVerifier({ build = buildFrom(ACTUAL_MANIFEST), fault = null, args = [], patch }: { build?: Build; fault?: string | null; args?: string[]; patch?: [string, string] } = {}) {
  const folder = build.root ?? await mkdtemp(join(tmpdir(), "rendprop-served-routing-test-"));
  const requests: string[] = [];
  const savedFetch = globalThis.fetch, savedLog = console.log;
  let output: Output | undefined, error: unknown;
  try {
    if (!build.root) {
      await mkdir(join(folder, "assets")); await mkdir(join(folder, ".vite"));
      for (const name of build.folders ?? []) await mkdir(join(folder, name), { recursive: true });
      await writeFile(join(folder, ".vite/manifest.json"), build.manifest);
      for (const [file, bytes] of Object.entries(build.files)) await writeFile(join(folder, file), bytes);
      for (const [file, target] of Object.entries(build.links ?? {})) { await rm(join(folder, file), { force: true }); await symlink(target, join(folder, file)); }
    }
    const headers = build.root ? builtHeaders(folder) : HEADERS;
    const fixed = ["index.html", "robots.txt", "rendprop-mark.svg"];
    const content = (file: string) => build.root ? (fixed.includes(file) || /^assets\/[^/]+$/.test(file) ? readFileSync(join(folder, file)) : undefined) : build.files[file];
    const target = build.root ? undefined : (() => { try { return dynamicOnly(build.manifest); } catch { return undefined; } })();
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(String(input));
      assert.equal(url.origin, "https://studio.rendprop.com");
      assert.equal(init?.method ?? "GET", "GET"); assert.equal(init?.headers, undefined);
      assert.equal(init?.redirect, "manual"); assert.equal(init?.cache, "no-store");
      assert(init?.signal instanceof AbortSignal, "Every GET carries its bounded timeout");
      requests.push(url.pathname + url.search);
      const entry = content("index.html")!;
      if (url.pathname === "/auth/callback") {
        if (fault === "callback200") return new Response(entry, { headers });
        const location = fault === "foreign-redirect" ? "https://example.invalid/" : fault === "wrong-route" ? "/workspace" : fault === "lost-query" ? "/" : "/" + url.search;
        return new Response(fault === "redirect-body" ? "unexpected" : null, { status: 307, headers: { location } });
      }
      if (url.pathname === "/workspace" || url.pathname === "/assets/__rendprop_verify_missing__.js") return new Response(fault === url.pathname ? entry : "Not found", { status: fault === url.pathname ? 200 : 404, headers });
      const file = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
      const bytes = content(file);
      assert(bytes !== undefined, "Only exact retained build files can be read");
      if (fault === "root-mismatch" && url.search) return new Response(entry + "changed", { headers });
      if (file === "robots.txt" && fault?.startsWith("robots-")) {
        const body = fault === "robots-tail-changed" ? ROBOTS_TEST_PREFIX + String(bytes).replace("Disallow", "Allow") : (fault === "robots-unknown-prefix" ? "User-agent: *\nAllow: /\n" : ROBOTS_TEST_PREFIX) + String(bytes);
        return new Response(body, { headers });
      }
      if (file === target && fault === "dynamic-bytes") return new Response(String(bytes) + "/* changed */", { headers });
      if (file === target && fault === "dynamic-status") return new Response(bytes, { status: 203, headers });
      if (file === target && fault && HEADER_FAULTS[fault]) {
        const changed: Record<string, string> = { ...headers };
        for (const [name, value] of Object.entries(HEADER_FAULTS[fault][0])) { if (value === null) delete changed[name]; else changed[name] = value; }
        return new Response(bytes, { headers: changed });
      }
      return new Response(bytes, { headers });
    }) as typeof fetch;
    console.log = (value: string) => { output = JSON.parse(value); };
    let source = await readFile(verifierUrl, "utf8");
    const rootLine = "const root=path.resolve(import.meta.dirname,'../dist');", argsLine = "const args=process.argv.slice(2);";
    assert.equal(source.split(rootLine).length, 2);
    source = source.replace(rootLine, `const root=${JSON.stringify(folder)};`);
    if (source.includes(argsLine)) source = source.replace(argsLine, `const args=${JSON.stringify(args)};`);
    else assert.deepEqual(args, [], "This verifier revision takes no arguments");
    if (patch) { assert.equal(source.split(patch[0]).length, 2, "Patched verifier line must exist exactly once"); source = source.replace(patch[0], patch[1]); }
    await import(`data:text/javascript;base64,${Buffer.from(`${source}\n// run ${++runs}\n`).toString("base64")}`);
  } catch (failure) { error = failure; }
  finally { globalThis.fetch = savedFetch; console.log = savedLog; if (!build.root) await rm(folder, { recursive: true, force: true }); }
  return { output, error, requests };
}
const passed = (result: Awaited<ReturnType<typeof runVerifier>>) => {
  assert.equal(result.error, undefined, `Verifier refused after ${result.requests.length} GETs: ${String(result.error)}`);
  assert.equal(result.output?.status, "passed");
  return result.output!;
};
const pathOf = (file: string) => file === "index.html" ? "/" : `/${file}`;

for (const assetCount of [32, 33]) test(`valid ${assetCount}-asset build: ${assetCount + 3} exact files and ${assetCount + 7} bounded GETs`, async () => {
  const build = buildFrom(syntheticManifest(assetCount));
  const result = await runVerifier({ build });
  const output = passed(result);
  assert.deepEqual(result.requests.slice(0, -4).sort(), Object.keys(build.files).map(pathOf).sort());
  assert.deepEqual(result.requests.slice(-4), PROBES);
  assert.equal(output.GETRequests, assetCount + 7);
  assert.equal(output.spaFallback, false); assert.equal(output.oauthCallbackCanonicalRedirect307, true);
  assert.equal(output.oauthCallbackQueryPreserved, true); assert.equal(output.unknownRoutes404, true);
});

test("actual a8390ac4 manifest: 33 assets, 36 exact files and 40 GETs in a fixed order", async () => {
  const build = buildFrom(ACTUAL_MANIFEST);
  const result = await runVerifier({ build });
  const output = passed(result);
  const expected = ["index.html", "robots.txt", "rendprop-mark.svg", ...[...ACTUAL_ASSETS].sort()];
  // Every manifest-derived file exactly once (dynamic-only chunks included), then only the four probes.
  assert.deepEqual(result.requests, [...expected.map(pathOf), ...PROBES]);
  assert.equal(output.GETRequests, 40);
  assert.deepEqual(output.files.map((row) => [row.path, row.sha256]), expected.map((file) => [pathOf(file), sha(build.files[file])]));
  assert.deepEqual(output.inventory, { manifestSha256: sha(ACTUAL_MANIFEST), manifestEntries: 23, loadableEntries: 22, assets: 33, files: 36, routeProbes: 4, GETBudget: 40, sha256: sha(JSON.stringify(expected.map((file) => [file, sha(build.files[file])]))) });
  assert(result.requests.includes(`/${dynamicOnly(ACTUAL_MANIFEST)}`), "The dynamic-only qrcode chunk is read back");
  const local = await runVerifier({ build, args: ["--local-only"] });
  assert.equal(local.error, undefined); assert.equal(local.requests.length, 0);
  assert.equal(local.output?.network, false); assert.deepEqual(local.output?.inventory, output.inventory);
  assert.deepEqual((local.output?.files as { path: string }[]).map((row) => row.path), expected);
});

test("inventory faults stop before any GET", async () => {
  const actual = buildFrom(ACTUAL_MANIFEST);
  const qrcode = dynamicOnly(ACTUAL_MANIFEST);
  const withoutQrcode = { ...actual, files: Object.fromEntries(Object.entries(actual.files).filter(([file]) => file !== qrcode)) };
  const cases: [string, Build, RegExp][] = [
    ["33rd file absent from a 32-asset manifest", buildFrom(syntheticManifest(32), { "assets/isolated-extra.js": "export const extra=1;" }), /unmanifested: assets\/isolated-extra\.js/],
    ["declared dynamic-only asset missing", withoutQrcode, /missing: assets\/qrcode-DtWdxa9d\.js/],
    ["broken static dependency key", editedActual((items) => { items["_delivery-kit-CFxAJ0Z2.js"].imports!.push("_missing-chunk.js"); }), /imports missing _missing-chunk\.js/],
    ["broken dynamic dependency key", editedActual((items) => { items["index.html"].dynamicImports!.push("src/features/Missing.tsx"); }), /imports missing src\/features\/Missing\.tsx/],
    ["output path escapes assets", editedActual((items) => { items["_api-CYT80BYD.js"].file = "assets/../robots.txt"; }), /unsafe or unsupported output file/],
    ["CSS path outside assets", editedActual((items) => { items["_cloud-media-4A0fbS_5.js"].css = ["/assets/cloud-media-CskToBGL.css"]; }), /unsafe or unsupported output file/],
    ["unreviewed output type", editedActual((items) => { items["_model-CwzsXYoU.js"].assets = ["assets/model-weights.wasm"]; }), /unsafe or unsupported output file/],
    ["manifest-only chunk the entry can never load", editedActual((items) => { items["src/features/Orphan.tsx"] = { file: "assets/Orphan-x1.js", isDynamicEntry: true }; }), /emits assets\/Orphan-x1\.js, which index\.html can never load/],
    ["second build entry", editedActual((items) => { items["src/editor/ProxyPanel.tsx"].isEntry = true; }), /only build entry/],
    ["no build entry", editedActual((items) => { delete items["index.html"].isEntry; }), /only build entry/],
    ["manifest is not JSON", { ...actual, manifest: "{\"index.html\":" }, /not valid JSON/],
    ["manifest is not an object", { ...actual, manifest: "[]" }, /must be an object/],
    ["asset is a symlink", { ...withoutQrcode, links: { [qrcode]: "api-CYT80BYD.js" } }, /must be a regular file, not a link/],
    ["folder inside assets", { ...actual, folders: ["assets/nested"] }, /must be a regular file, not a link or folder/],
    ["entry HTML is a symlink", { ...actual, links: { "index.html": "robots.txt" } }, /index\.html must be a real file/],
    ["manifest is a symlink", { ...actual, links: { ".vite/manifest.json": "../robots.txt" } }, /manifest\.json must be a real file/],
    ["HTML loads a file outside the inventory", { ...actual, files: { ...actual.files, "index.html": String(actual.files["index.html"]) + `<script src="/assets/old-entry.js"></script>` } }, /loads \/assets\/old-entry\.js, which is outside the verified inventory/],
    ["HTML does not load the manifest entry", { ...actual, files: { ...actual.files, "index.html": "<!doctype html><title>Stale entry</title>" } }, /must load the manifest entry/],
  ];
  for (const [name, build, reason] of cases) {
    const result = await runVerifier({ build });
    assert(result.error, `Verifier must refuse: ${name}`); assert.match(String(result.error), reason, name);
    assert.equal(result.output, undefined, name); assert.equal(result.requests.length, 0, `${name} must stop before any GET`);
    const local = await runVerifier({ build, args: ["--local-only"] });
    assert.match(String(local.error), reason, `--local-only also refuses: ${name}`); assert.equal(local.requests.length, 0);
  }
});

test("changed bytes, status or required headers on a dynamic-only chunk are refused", async () => {
  const qrcode = `/${dynamicOnly(ACTUAL_MANIFEST)}`;
  const faults: [string, RegExp][] = [["dynamic-bytes", /Deployed \/assets\/qrcode-DtWdxa9d\.js differs from the verified build/], ["dynamic-status", /\/assets\/qrcode-DtWdxa9d\.js must serve successfully/], ...Object.entries(HEADER_FAULTS).map(([fault, [, reason]]): [string, RegExp] => [fault, reason])];
  for (const [fault, reason] of faults) {
    const result = await runVerifier({ fault });
    assert.match(String(result.error), reason, fault); assert.equal(result.output, undefined);
    assert.equal(result.requests.at(-1), qrcode, `${fault} stops at the dynamic-only chunk`);
  }
});

test("callback, redirect, query, body, entry-byte and 404-fallback controls are retained", async () => {
  const faults: [string, RegExp][] = [
    ["callback200", /Configured callback must use the exact canonical redirect/], ["foreign-redirect", /Callback must preserve the same-origin root and exact query/],
    ["wrong-route", /Callback must preserve the same-origin root and exact query/], ["lost-query", /Callback must preserve the same-origin root and exact query/],
    ["redirect-body", /Canonical redirect must have no application body/], ["root-mismatch", /Callback destination must serve the same entry/],
    ["/workspace", /\/workspace must retain the configured missing-route policy/], ["/assets/__rendprop_verify_missing__.js", /__rendprop_verify_missing__\.js must retain the configured missing-route policy/],
  ];
  for (const [fault, reason] of faults) {
    const result = await runVerifier({ fault });
    assert.match(String(result.error), reason, fault); assert.equal(result.output, undefined);
    assert(result.requests.length > 36 && result.requests.length <= 40, fault);
  }
});

test("managed robots: unknown prefix or changed origin tail is refused; the pinned prefix keeps its warning", async () => {
  for (const [fault, reason] of [["robots-unknown-prefix", /Unrecognized managed robots policy change/], ["robots-tail-changed", /Managed robots response must retain the exact origin file/]] as [string, RegExp][]) {
    const result = await runVerifier({ fault });
    assert.match(String(result.error), reason, fault); assert.equal(result.output, undefined);
    assert.equal(result.requests.at(-1), "/robots.txt");
  }
  // The real platform prefix bytes are not retained, so this control swaps the pin
  // for a synthetic prefix's hash to exercise the accepted branch; the shipped pin is unchanged.
  const pin = "const managedRobotsPrefixSha='842b34303164ead41bccb7c05d1707422e98d108753b397b6dcc19683eb02101';";
  const unchanged = await runVerifier({ fault: "robots-prefix" });
  assert.match(String(unchanged.error), /Unrecognized managed robots policy change/);
  const known: [string, string] = [pin, `const managedRobotsPrefixSha='${sha(ROBOTS_TEST_PREFIX)}';`];
  const tail = await runVerifier({ fault: "robots-tail-changed", patch: known });
  assert.match(String(tail.error), /Managed robots response must retain the exact origin file/);
  const output = passed(await runVerifier({ fault: "robots-prefix", patch: known }));
  assert.deepEqual(output.files.find((row) => row.path === "/robots.txt")?.transformation, { kind: "known-cloudflare-managed-robots-prefix", prefixSha256: sha(ROBOTS_TEST_PREFIX), originSha256: sha("User-agent: *\nDisallow: /\n") });
  assert.equal(output.robotsCrawlBlockingVerified, false); assert.match(output.warnings[0], /Crawl blocking is NOT verified/);
});

test("the exact budget refuses a skipped or substituted inventory file and any extra request", async () => {
  const qrcode = dynamicOnly(ACTUAL_MANIFEST);
  const loop = "  for(const file of files){";
  const skipped = await runVerifier({ patch: [loop, `  for(const file of files.filter(file=>file!==${JSON.stringify(qrcode)})){`] });
  assert.match(String(skipped.error), /\b39\b[\s\S]*\b40\b/, "Omitting a dynamic chunk's readback must fail the exact count"); assert.equal(skipped.output, undefined);
  assert(!skipped.requests.includes(`/${qrcode}`)); assert.equal(skipped.requests.length, 39);
  // Same count, wrong coverage: the entry read twice in place of the dynamic chunk.
  const substituted = await runVerifier({ patch: [loop, `  for(const file of files.map(file=>file===${JSON.stringify(qrcode)}?'index.html':file)){`] });
  assert.match(String(substituted.error), /each inventory file once, then only the route probes/); assert.equal(substituted.output, undefined);
  assert(!substituted.requests.includes(`/${qrcode}`)); assert.equal(substituted.requests.length, 40);
  const crawled = await runVerifier({ patch: ["for(const pathname of ['/workspace','/assets/__rendprop_verify_missing__.js'])", "for(const pathname of ['/workspace','/assets/__rendprop_verify_missing__.js','/extra-crawl'])"] });
  assert.match(String(crawled.error), /Exact readback request budget/); assert.equal(crawled.output, undefined);
  assert.equal(crawled.requests.length, 40, "The 41st GET is refused before it is sent");
});

if (process.env.RENDPROP_RELEASE_DIST) test("release dist through closed transport: manifest inventory, exact hashes and GET budget", async (t) => {
  const root = resolve(process.env.RENDPROP_RELEASE_DIST!);
  const build: Build = { manifest: "", files: {}, root };
  const result = await runVerifier({ build });
  const output = passed(result);
  const assets = (await readdir(join(root, "assets"))).map((name) => `assets/${name}`).sort();
  const expected = ["index.html", "robots.txt", "rendprop-mark.svg", ...assets];
  assert.deepEqual(result.requests, [...expected.map(pathOf), ...PROBES]);
  assert.equal(output.GETRequests, expected.length + PROBES.length);
  assert.deepEqual(output.files.map((row) => [row.path, row.sha256]), expected.map((file) => [pathOf(file), sha(readFileSync(join(root, file)))]));
  const local = await runVerifier({ build, args: ["--local-only"] });
  assert.equal(local.requests.length, 0); assert.deepEqual(local.output?.inventory, output.inventory);
  t.diagnostic(JSON.stringify({ inventory: output.inventory, GETRequests: output.GETRequests, files: output.files.map((row) => `${row.sha256}  ${row.path}`) }));
});
