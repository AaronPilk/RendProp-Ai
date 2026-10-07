import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Execute the actual readback verifier with an isolated build and a closed
// transport. These controls never make requests to the deployment.
async function runVerifier(fault: string | null = null) {
  const folder = await mkdtemp(join(tmpdir(), "rendprop-served-routing-test-"));
  const entry = "<!doctype html><title>Isolated Studio build</title>";
  const files: Record<string, string> = { "index.html": entry, "robots.txt": "User-agent: *\nDisallow: /\n", "rendprop-mark.svg": "<svg/>" };
  for (let i = 0; i < (fault === "extra-asset" ? 29 : 28); i++) files[`assets/isolated-${i}.js`] = `export const asset=${i};`;
  await mkdir(join(folder, "assets"));
  for (const [file, bytes] of Object.entries(files)) await writeFile(join(folder, file), bytes);
  const headers = { "x-robots-tag": "noindex, nofollow", "cache-control": "no-store, no-transform", "x-content-type-options": "nosniff", "referrer-policy": "no-referrer", "content-security-policy": "script-src 'self'; frame-ancestors 'none'" };
  const requests: { path: string; redirect: string | undefined }[] = [];
  const savedFetch = globalThis.fetch, savedLog = console.log;
  let output: Record<string, unknown> | undefined, error: unknown;
  try {
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(String(input));
      assert.equal(url.origin, "https://studio.rendprop.com");
      assert.equal(init?.method ?? "GET", "GET"); assert.equal(init?.headers, undefined);
      assert.equal(init?.redirect, "manual"); assert.equal(init?.cache, "no-store");
      requests.push({ path: url.pathname + url.search, redirect: init?.redirect });
      assert(requests.length <= 35);
      if (url.pathname === "/auth/callback") {
        if (fault === "callback200") return new Response(entry, { headers });
        const location = fault === "foreign-redirect" ? "https://example.invalid/" : fault === "wrong-route" ? "/workspace" : fault === "lost-query" ? "/" : "/" + url.search;
        return new Response(fault === "redirect-body" ? "unexpected" : null, { status: 307, headers: { location } });
      }
      if (url.pathname === "/workspace" || url.pathname === "/assets/__rendprop_verify_missing__.js") return new Response(fault === url.pathname ? entry : "Not found", { status: fault === url.pathname ? 200 : 404, headers });
      const file = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
      assert(Object.hasOwn(files, file), "Only exact retained build files can be read");
      return new Response(fault === "root-mismatch" && url.search ? entry + "changed" : files[file], { headers });
    }) as typeof fetch;
    console.log = (value: string) => { output = JSON.parse(value); };
    const source = await readFile(new URL("../scripts/verify-deployed.mjs", import.meta.url), "utf8");
    const rootLine = "const root=path.resolve(import.meta.dirname,'../dist');";
    assert.equal(source.split(rootLine).length, 2);
    const isolated = source.replace(rootLine, `const root=${JSON.stringify(folder)};`);
    await import(`data:text/javascript;base64,${Buffer.from(isolated).toString("base64")}`);
  } catch (failure) { error = failure; }
  finally { globalThis.fetch = savedFetch; console.log = savedLog; await rm(folder, { recursive: true, force: true }); }
  return { output, error, requests };
}

test("actual served verifier proves only the exact callback canonicalization and 35 bounded GETs", async () => {
  const result = await runVerifier();
  assert.equal(result.error, undefined);
  assert.equal(result.output?.status, "passed"); assert.equal(result.output?.GETRequests, 35);
  assert.equal(result.output?.spaFallback, false); assert.equal(result.output?.oauthCallbackCanonicalRedirect307, true);
  assert.equal(result.output?.oauthCallbackQueryPreserved, true); assert.equal(result.output?.unknownRoutes404, true);
  assert.equal(result.requests.length, 35);
  assert.deepEqual(result.requests.slice(-4).map(row => row.path), ["/auth/callback?rendprop_route_probe=1", "/?rendprop_route_probe=1", "/workspace", "/assets/__rendprop_verify_missing__.js"]);
});
test("actual served verifier refuses foreign, broad, changed-byte and missing-route fallback proofs", async () => {
  for (const fault of ["callback200", "foreign-redirect", "wrong-route", "lost-query", "redirect-body", "root-mismatch", "/workspace", "/assets/__rendprop_verify_missing__.js", "extra-asset"]) {
    const result = await runVerifier(fault);
    assert(result.error, `Verifier must reject ${fault}`); assert.equal(result.output, undefined);
    assert(result.requests.length <= 35);
    if (fault === "extra-asset") assert.equal(result.requests.length, 0);
  }
});
