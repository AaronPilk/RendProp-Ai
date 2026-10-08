// Launch ceiling mode (2026-10-08): with app_config.serving_mode.mode =
// 'ceiling' the funded-serving layer is inert — no hold is reserved or
// settled, the operator photo chain is kept, helpers are not fenced, and a
// purchase records no funding. Anything else (missing row, 'funded', an
// unreadable setting) keeps Codex's funded model, which fails closed.
//
// The module reads env at import time and caches its admin client, so the
// fixture installs env + a fetch stub BEFORE the dynamic import and flips the
// answer through a mutable variable.
import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "./http.ts";
import type { RouteStep } from "./router.ts";
import type { FundingContext } from "./funded-serving.ts";

let answer: unknown = "ceiling";
const realFetch = globalThis.fetch;
Deno.env.set("SUPABASE_URL", "https://serving-mode-fixture.invalid");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service-role-fixture");
globalThis.fetch = ((input: Request | URL | string, init?: RequestInit) => {
  const url = String(input instanceof Request ? input.url : input);
  if (url.endsWith("/rest/v1/rpc/serving_mode")) {
    if (answer === "unreadable") return Promise.resolve(new Response("boom", { status: 500 }));
    return Promise.resolve(new Response(JSON.stringify(answer), { status: 200, headers: { "content-type": "application/json" } }));
  }
  return realFetch(input as never, init);
}) as typeof fetch;
const serving = await import("./funded-serving.ts");
const { fundVerifiedAppleTransaction } = await import("./apple-funding.ts");

const step: RouteStep = {
  route_id: "synthetic", task: "photo.stage", provider: "openai", model: "gpt-image-2", unit: "call", unit_cents: 2,
  capabilities: [], max_latency_s: 30, min_plan: "starter", same_model_as: null, params: {}, priority: 1, enabled: true,
} as unknown as RouteStep;

function mode(value: unknown): void { answer = value; serving.resetServingModeCache(); }
function context(): { calls: string[]; context: FundingContext } {
  const calls: string[] = [];
  return { calls, context: { actorId: "a", orgId: "o", requestKey: "k", async rpc(name) { calls.push(name); return { data: null, error: { message: "RP402: This workspace has no funded serving allowance" } }; } } };
}

Deno.test("serving mode reads 'ceiling' exactly and otherwise fails closed to 'funded'", async () => {
  mode("ceiling"); assertEquals(await serving.servingMode(), "ceiling");
  mode("funded"); assertEquals(await serving.servingMode(), "funded");
  mode(null); assertEquals(await serving.servingMode(), "funded");
  mode("unreadable"); assertEquals(await serving.servingMode(), "funded");
  mode("CEILING"); assertEquals(await serving.servingMode(), "funded");
});

Deno.test("ceiling mode: an attempt runs with no hold, no settlement, and the route's own chain", async () => {
  mode("ceiling");
  const f = context();
  assertEquals(await serving.fundedAttempt(f.context, "photo.stage:0", step, { prompt: "x" }, null, async () => "image"), "image");
  assertEquals(f.calls, []);
  assertEquals(await serving.boundedPhotoChain(f.context, [step, step], { task: "photo.stage", prompt: "x" } as never), [step, step]);
  await serving.assertPhotoHelperSponsorship(f.context);
  assertEquals(f.calls, []);
  // A bare transport Response is still not a validated receipt.
  await assertRejects(() => serving.fundedAttempt(f.context, "s", step, {}, null, async () => new Response("ok") as never), HttpError);
});

Deno.test("funded mode: the same attempt is refused before dispatch when nothing funds it", async () => {
  mode("funded");
  const f = context();
  let dispatched = false;
  const error = await assertRejects(() => serving.fundedAttempt(f.context, "photo.stage:0", step, {}, { cents: 1, version: "t" }, async () => { dispatched = true; return "image"; }), HttpError);
  assertEquals(error.status, 503);
  assert(!dispatched);
  assert(f.calls.includes("serving_cost_reserve"));
});

Deno.test("ceiling mode: a Production purchase records no funding row and reports available service", async () => {
  mode("ceiling");
  const calls: string[] = [];
  const result = await fundVerifiedAppleTransaction(async (name) => { calls.push(name); return { data: null, error: null }; }, "o", {
    environment: "Production", originalTransactionId: "1", transactionId: "2", productId: "com.rendprop.app.starter.monthly",
    priceMilliunits: 49000, currency: "USD", storefront: "USA", offerType: null, offerDiscountType: null,
    purchaseDate: new Date().toISOString(), expiresDate: new Date(Date.now() + 86400000).toISOString(), signedDate: new Date().toISOString(), appAccountToken: "a",
  } as never);
  assertEquals(result, { funded: false, available: true, reason: "ceiling_mode" });
  assertEquals(calls, []);
  mode("funded");
  await fundVerifiedAppleTransaction(async (name) => { calls.push(name); return { data: { funded: false }, error: null }; }, "o", {
    environment: "Production", originalTransactionId: "1", transactionId: "2", productId: "com.rendprop.app.starter.monthly",
    priceMilliunits: 49000, currency: "USD", storefront: "USA", offerType: null, offerDiscountType: null,
    purchaseDate: new Date().toISOString(), expiresDate: new Date(Date.now() + 86400000).toISOString(), signedDate: new Date().toISOString(), appAccountToken: "a",
  } as never);
  assertEquals(calls, ["fund_verified_retail_apple_transaction"]);
});
