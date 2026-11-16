import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { featureFor } from "../src/features/home/features";

// Execute the actual component handler body against closed API/media boundaries.
// Public card/entry semantics are also exercised by the existing browser gates.
const source = readFileSync(new URL("../src/features/creative/CreativeWorkspace.tsx", import.meta.url), "utf8");
const start = source.indexOf("  async function generateVideo() {");
const end = source.indexOf("  async function reviewVideo(", start);
assert.ok(start >= 0 && end > start);
const body = source.slice(start, end).replace(/^\s*async function generateVideo\(\) \{/, "").replace(/\}\s*$/, "");
const guard = 'if (videoKind === "aerial") throw new Error("Aerial intros are Coming soon.");';
assert.ok(body.includes(guard));
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
function run(kind: string, code = body) {
  const calls: unknown[][] = [];
  const generate = new AsyncFunction("videoKind", "videoAsset", "ensureOriginal", "listingId", "listing", "room", "tier", "prompt", "seconds", "motion", "record", "api", "setResults", "decodeResult", "workspace", "orgId", "setNotice", code);
  const result = generate(kind, "saved-video", async () => { calls.push(["source"]); return "reviewed-photo"; }, "listing", {spaceType:"real_estate"}, "", "1080p60", "", 5, "push_in", (x: unknown) => x,
    async (...args: unknown[]) => { calls.push(["api", ...args]); return {result:{id:"result"}}; }, () => {}, (x: unknown) => x, {user:{id:"owner"}}, "org", () => {});
  return {result, calls};
}
test("Aerial is Coming soon without an active AI benefit", () => {
  const aerial = featureFor("aerial");
  assert.equal(aerial.comingSoon, true);
  assert.match(aerial.description, /Coming soon.*not included in any plan/);
  assert.notEqual(aerial.ai, true);
});
test("stale Aerial editor state refuses before source preparation or API dispatch", async () => {
  const {result, calls} = run("aerial");
  await assert.rejects(result, /^Error: Aerial intros are Coming soon\.$/);
  assert.deepEqual(calls, []);
});
test("available photo motion still uses the reviewed source and existing route", async () => {
  const {result, calls} = run("reel"); await result;
  assert.equal(calls[0][0], "source");
  assert.equal(calls[1][1], "studio/video");
  assert.deepEqual(calls[1][2], {listing_id:"listing",kind:"reel",asset_id:"reviewed-photo",space_type:"real_estate",label:"Property motion clip",seconds:5,motion:"push_in",room:"",prompt:undefined});
});
test("removing the Aerial refusal exposes a dispatch and is rejected by the safety oracle", async () => {
  const mutant = run("aerial", body.replace(guard, "")); await mutant.result;
  assert.equal(mutant.calls[0][0], "api");
  assert.throws(() => assert.deepEqual(mutant.calls, []), /AssertionError/);
});
