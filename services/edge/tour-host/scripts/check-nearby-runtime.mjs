#!/usr/bin/env node
// Isolated actual workerd/R2 admission proof. All provider data is closed;
// storage is ephemeral local R2, never the configured production bucket.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { unstable_startWorker } from "wrangler";

const root = resolve(fileURLToPath(import.meta.url), "../..");
const arg = process.argv.indexOf("--evidence-dir");
const out = arg >= 0 ? resolve(process.argv[arg + 1]) : null;
const sourcePath = resolve(root, "src/nearby-places.ts");
const sourceHash = createHash("sha256").update(await readFile(sourcePath)).digest("hex");
const worker = await unstable_startWorker({
  name: "rendprop-nearby-local-proof",
  entrypoint: resolve(root, "scripts/nearby-runtime-probe-worker.ts"),
  compatibilityDate: "2026-09-07",
  dev: { remote: false, server: { hostname: "127.0.0.1", port: 0 }, inspector: false, logLevel: "error", persist: false },
  bindings: { MEDIA_RENDERS: { type: "r2_bucket", bucket_name: "rendprop-nearby-local-fixture" } },
});
let receipt = { passed: false, checked_at: new Date().toISOString(), source_path: sourcePath, source_sha256: sourceHash };
try {
  await worker.ready;
  const response = await worker.fetch("https://local-proof.invalid/run");
  const result = await response.json();
  receipt = { ...receipt, ...result };
  assert.equal(response.status, 200, result.error || "actual workerd probe must succeed");
  assert.equal(result.passed, true);
  assert.equal(result.assertions, 16);
  receipt.source_binding_matches = createHash("sha256").update(await readFile(sourcePath)).digest("hex") === sourceHash;
  assert.equal(receipt.source_binding_matches, true, "source changed during runtime proof");
  console.log("check-nearby-runtime: 16 actual workerd/R2 assertions passed; area stampede 1/20 and daily cap 1/15; closed provider only");
} catch (error) {
  receipt = { ...receipt, passed: false, error: error instanceof Error ? error.message : String(error) };
  console.error("check-nearby-runtime FAILED:", receipt.error);
  process.exitCode = 1;
} finally {
  await worker.dispose().catch(() => {});
  if (out) { await mkdir(out, { recursive: true }); await writeFile(resolve(out, "receipt.json"), JSON.stringify(receipt, null, 2) + "\n"); }
}
