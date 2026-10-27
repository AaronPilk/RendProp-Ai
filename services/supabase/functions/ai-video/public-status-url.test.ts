import { assert, assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { assertPublicSupabaseOrigin, decodeJobToken, extractJobToken, routerStatusUrl } from "../_shared/providers/jobtoken.ts";
import { recoverVideoOperation } from "./operation-recovery.ts";

const origin = "https://aaaaaaaaaaaaaaaaaaaa.supabase.co";
const actor = "10000000-0000-4000-8000-000000000001", org = "20000000-0000-4000-8000-000000000001";
const listing = "30000000-0000-4000-8000-000000000001", operation = "40000000-0000-4000-8000-000000000001";
const ref = { provider: "fal", model: "bytedance/seedance/v1/pro/fast/image-to-video", id: "original-accepted-request",
  poll_url: "https://queue.fal.run/fal-ai/bytedance/requests/original-accepted-request/status", submitted_at: "2026-10-15T20:22:15.949Z" };
const owner = { orgId: org, userId: actor, listingId: listing, admissionKey: operation };
Deno.env.set("JOB_TOKEN_SIGNING_SECRET", "synthetic-public-origin-test-only");

const internalRequest = (route: string) => new Request(`http://internal-edge.invalid/ai-video/${route}`, {
  headers: { "Idempotency-Key": operation, "Forwarded": "proto=http;host=foreign.invalid", "X-Forwarded-Host": "foreign.invalid", "X-Forwarded-Proto": "http" },
});
// Execute the actual POST envelope and lookup signer expression. The main
// handler's unrelated Auth/database/provider boundaries stay outside this test.
async function entrypoints(dropOrigin = false) {
  let source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  if (dropOrigin) source = source.replaceAll(', Deno.env.get("SUPABASE_URL"))', ')');
  const start = source.indexOf("async function assertVideoReceiptSigningReady()");
  const end = source.indexOf("// ── Space-type vocabulary", start);
  const sign = source.match(/sign: (\(request, ref, owner\) => routerStatusUrl\([^\n]+)\,\n/);
  assert(start > 0 && end > start && sign);
  const program = `
    import {HttpError} from ${JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)};
    import {requiredIdempotencyKey} from ${JSON.stringify(new URL("../_shared/idempotency.ts", import.meta.url).href)};
    import {routerStatusUrl,assertPublicSupabaseOrigin,assertJobTokenSigningReady,type JobTokenOwner} from ${JSON.stringify(new URL("../_shared/providers/jobtoken.ts", import.meta.url).href)};
    import type {JobRef} from ${JSON.stringify(new URL("../_shared/providers/types.ts", import.meta.url).href)};
    ${source.slice(start, end)}
    const sign: (request:Request,ref:JobRef,owner:JobTokenOwner)=>Promise<string> = ${sign[1]};
    export {submitEnvelope,assertVideoReceiptSigningReady,sign};`;
  return await import("data:application/typescript;base64," + btoa(program));
}
async function inspect(value: string) {
  const url = new URL(value);
  assertEquals(url.origin, origin); assertEquals(url.pathname, "/functions/v1/ai-video/status");
  assertEquals(url.protocol, "https:"); assertEquals(url.username, ""); assertEquals(url.password, "");
  const raw = extractJobToken(url.searchParams); assert(raw);
  const token = await decodeJobToken(raw); assert(token);
  assertEquals([token.p, token.m, token.i, token.u, token.t, token.k, token.o, token.usr, token.l, token.a],
    [ref.provider, ref.model, ref.id, ref.poll_url, ref.submitted_at, "video.reel_clip", org, actor, listing, operation]);
  assert(token.exp > Date.now() / 1000);
  return raw;
}

Deno.test("real signer corrects stripped internal HTTP base and ignores forwarded headers without changing receipt claims", async () => {
  const req = internalRequest("reel-clip");
  const raw = await inspect(await routerStatusUrl(req, "ai-video", "video.reel_clip", ref, owner, origin));
  const prior = new URL(await routerStatusUrl(req, "ai-video", "video.reel_clip", ref, owner));
  const priorRaw = extractJobToken(prior.searchParams);
  assert(priorRaw);
  const publicToken = await decodeJobToken(raw), internalToken = await decodeJobToken(priorRaw);
  assert(publicToken && internalToken); // Both MACs verify independently.
  const { exp: publicExpiry, ...publicClaims } = publicToken;
  const { exp: internalExpiry, ...internalClaims } = internalToken;
  assertEquals(internalClaims, publicClaims); // URL base cannot change receipt identity.
  assert(publicExpiry > Date.now() / 1000 && internalExpiry > Date.now() / 1000); // Fresh signs can cross a second.
  assertEquals(prior.origin, "http://internal-edge.invalid"); // Other callers keep existing opt-in behavior.
});

Deno.test("lost202 operation lookup uses the real signer and emits the exact HTTPS shape accepted by native", async () => {
  Deno.env.set("SUPABASE_URL", origin);
  const actual = await entrypoints();
  const req = internalRequest(`operation?operation_id=${operation}&listing_id=${listing}`);
  let reads = 0;
  const response = await recoverVideoOperation(req, actor, {
    preferredOrg: () => org, contentOrg: async () => { reads++; return org; },
    rpc: async () => ({ error: null, data: { actor_id: actor, org_id: org, listing_id: listing, operation_id: operation, status: "accepted", receipt: ref } }),
    paidReceiptMatches: async () => true,
    sign: actual.sign,
  });
  const body = await response.json(); assertEquals(response.status, 200); assertEquals(reads, 3);
  assertEquals(body.status_url, body.response_url); await inspect(body.status_url);
});

Deno.test("actual paid POST and operation lookup entrypoints bind canonical server config, with omission controls", async () => {
  Deno.env.set("SUPABASE_URL", origin);
  const actual = await entrypoints();
  await actual.assertVideoReceiptSigningReady();
  const post = await actual.submitEnvelope(internalRequest("reel-clip"), true, "video.reel_clip", ref, owner);
  assertEquals(post.request_id, ref.id); assertEquals(post.status_url, post.response_url); await inspect(post.status_url);
  await inspect(await actual.sign(internalRequest("operation"), ref, owner));
  const mutant = await entrypoints(true);
  await assertRejects(async () => inspect((await mutant.submitEnvelope(internalRequest("reel-clip"), true, "video.reel_clip", ref, owner)).status_url));
  await assertRejects(async () => inspect(await mutant.sign(internalRequest("operation"), ref, owner)));
});

for (const bad of [undefined, "", "http://aaaaaaaaaaaaaaaaaaaa.supabase.co", origin + "/functions/v1", origin + "?next=x", origin + "#secret", origin.replace("https://", "https://user:pass@"), origin + ":8443", "https://foreign.invalid", origin + ".foreign.invalid", " " + origin, origin + "\n", "https://AAAAAAAAAAAAAAAAAAAA.supabase.co"]) {
  Deno.test(`public status origin refuses noncanonical config ${JSON.stringify(bad)}`, async () => {
    assertThrows(() => assertPublicSupabaseOrigin(bad));
    if (bad !== undefined) await assertRejects(() => routerStatusUrl(internalRequest("reel-clip"), "ai-video", "video.reel_clip", ref, owner, bad));
  });
}

Deno.test("only an origin with optional root slash and a closed function name may form the public URL", async () => {
  assertEquals(assertPublicSupabaseOrigin(origin + "/"), origin);
  await inspect(await routerStatusUrl(internalRequest("reel-clip"), "ai-video", "video.reel_clip", ref, owner, origin + "/"));
  await assertRejects(() => routerStatusUrl(internalRequest("reel-clip"), "../foreign", "video.reel_clip", ref, owner, origin));
});
