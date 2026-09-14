import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

// A red child process is necessary, not sufficient. Prove the deliberate
// source mutant reached the browser assertion instead of failing to build/start.
const outcome = await new Promise((resolve, reject) => {
  const child = spawn(process.execPath, [fileURLToPath(new URL("./browser-connected.mjs", import.meta.url)), "--mutate-clear-on-refresh"], { stdio: ["ignore", "pipe", "pipe"] });
  let output = "", bytes = 0;
  const timer = setTimeout(() => { child.kill("SIGTERM"); reject(new Error("Negative control exceeded 60 seconds")); }, 60_000);
  child.stdout.on("data", (data) => {
    bytes += data.length;
    if (bytes > 1_000_000) { child.kill("SIGTERM"); reject(new Error("Unexpected control output size")); }
    else output += data.toString();
  });
  child.stderr.on("data", () => {});
  child.on("error", reject);
  child.on("exit", (code) => { clearTimeout(timer); resolve({ code, output }); });
});
assert.equal(outcome.code, 1, "Deliberately broken App must exit exactly 1");
const receipt = JSON.parse(outcome.output);
assert.equal(receipt.status, "failed");
assert.equal(receipt.mutation, true);
assert.equal(receipt.checks.length, 1, "Mutant must reach the first real browser check before failing");
assert.match(receipt.failure, /REFRESH_BINDING_REGRESSION/);
assert.deepEqual(receipt.errors, []);
assert.deepEqual(receipt.externalRequests, []);
console.log(JSON.stringify({ status: "passed", control: "actual App refresh mutation failed at expected browser assertion", childReceipt: `${receipt.artifacts}/receipt.json` }));
