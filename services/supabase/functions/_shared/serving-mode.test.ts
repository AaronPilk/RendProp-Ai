// Launch ceiling mode (2026-10-08, launch blockers 1/2/5): with
// app_config.serving_mode = {mode:'ceiling', free_published_listings:n} every
// paid attempt still reserves money BEFORE dispatch — priced from the route
// catalog the ledger bills against — and settles it afterwards; the operator
// photo chain is kept and helpers are not fenced because each step is admitted
// against the workspace envelope by serving_cost_reserve. Anything else
// (missing row, 'funded', an unreadable setting) keeps Codex's funded model,
// which fails closed. A purchase in ceiling mode records no funding row.
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

function routeStep(over: Partial<RouteStep> = {}): RouteStep {
  return {
    route_id: "synthetic", task: "photo.stage", provider: "gemini", model: "gemini-3.1-flash-image", unit: "image", unit_cents: 6.7,
    capabilities: [], max_latency_s: 30, min_plan: "starter", same_model_as: null, privacy_tier: "no_retention", enabled: true, ...over,
  } as RouteStep;
}
const step = routeStep();

function mode(value: unknown): void { answer = value; serving.resetServingModeCache(); }
type Call = { name: string; args: Record<string, unknown> };
function context(options: { reserveError?: string; sponsored?: boolean } = {}): { calls: Call[]; context: FundingContext } {
  const calls: Call[] = [];
  return { calls, context: { actorId: "a", orgId: "o", requestKey: "request-key-1", async rpc(name, args) {
    calls.push({ name, args });
    if (name === "org_has_internal_testing_grant" || name === "org_has_private_internal_testing") return { data: options.sponsored === true, error: null };
    if (name === "serving_cost_reserve") return options.reserveError ? { data: null, error: { message: options.reserveError } } : { data: { reserved: true, id: "r1", hold_cents: args.p_hold_cents, budget: "ceiling" }, error: null };
    if (name === "serving_cost_finish") return { data: { finished: true, state: args.p_state }, error: null };
    if (name === "serving_operation_no_dispatch") return { data: { aborted: true }, error: null };
    return { data: null, error: { message: "RP402: This workspace has no funded serving allowance" } };
  } } };
}

Deno.test("serving mode reads 'ceiling' exactly and otherwise fails closed to 'funded'", async () => {
  mode("ceiling"); assertEquals(await serving.servingMode(), "ceiling");
  mode("funded"); assertEquals(await serving.servingMode(), "funded");
  mode(null); assertEquals(await serving.servingMode(), "funded");
  mode("unreadable"); assertEquals(await serving.servingMode(), "funded");
  mode("CEILING"); assertEquals(await serving.servingMode(), "funded");
});

Deno.test("route catalog quotes price the hold the ledger bills: unit x units, conservative when the input is silent", () => {
  assertEquals(serving.routeCatalogQuote(step, { prompt: "x" }), { cents: 6.7, version: serving.ROUTE_CATALOG_TARIFF });
  assertEquals(serving.routeCatalogQuote(routeStep({ unit: "call", unit_cents: 2.1 }), {}), { cents: 2.1, version: serving.ROUTE_CATALOG_TARIFF });
  assertEquals(serving.routeCatalogQuote(routeStep({ unit: "second", unit_cents: 4.86 }), { seconds: 5 }), { cents: 24.3, version: serving.ROUTE_CATALOG_TARIFF });
  assertEquals(serving.routeCatalogQuote(routeStep({ unit: "second", unit_cents: 4.86 }), { seconds: "5" }), { cents: 58.32, version: serving.ROUTE_CATALOG_TARIFF });
  assertEquals(serving.routeCatalogQuote(routeStep({ unit: "minute", unit_cents: 0.6 }), { seconds: 90 }), { cents: 1.2, version: serving.ROUTE_CATALOG_TARIFF });
  assertEquals(serving.routeCatalogQuote(routeStep({ unit: "1k_chars", unit_cents: 22 }), { text: "x".repeat(2500) }), { cents: 66, version: serving.ROUTE_CATALOG_TARIFF });
  assertEquals(serving.routeCatalogQuote(routeStep({ unit: "1k_chars", unit_cents: 22 }), {}), { cents: 110, version: serving.ROUTE_CATALOG_TARIFF });
  assertEquals(serving.routeCatalogQuote(routeStep({ unit: "world", unit_cents: 120 }), {}), { cents: 120, version: serving.ROUTE_CATALOG_TARIFF });
  assertEquals(serving.routeCatalogQuote(routeStep({ unit: "parsec" }), {}), null);
  assertEquals(serving.routeCatalogQuote({ provider: "bria", model: "eraser" }, {}), null);
  assertEquals(serving.routeCatalogQuote(routeStep({ unit_cents: Number.NaN }), {}), null);
});

Deno.test("ceiling mode: an attempt reserves its catalog price before dispatch and settles after", async () => {
  mode("ceiling");
  const f = context();
  let dispatched = false;
  assertEquals(await serving.fundedAttempt(f.context, "photo.stage:0", step, { prompt: "x" }, null, async () => { dispatched = true; return "image"; }), "image");
  assert(dispatched);
  assertEquals(f.calls.map((call) => call.name), ["serving_cost_reserve", "serving_cost_finish"]);
  assertEquals(f.calls[0].args.p_hold_cents, 6.7);
  assertEquals(f.calls[0].args.p_tariff_version, serving.ROUTE_CATALOG_TARIFF);
  assertEquals(f.calls[0].args.p_stage, "photo.stage:0");
  assertEquals(f.calls[1].args.p_state, "succeeded");
  // The catalog price wins over the funded documentation bound in ceiling mode.
  const g = context();
  await serving.fundedAttempt(g.context, "photo.stage:0", step, { prompt: "x" }, { cents: 31.1296, version: "published-standard-20261006" }, async () => "image");
  assertEquals(g.calls[0].args.p_hold_cents, 6.7);
  // The route's own chain is kept and helpers are not fenced: each step pays its way.
  assertEquals(await serving.boundedPhotoChain(f.context, [step, step], { task: "photo.stage", prompt: "x" } as never), [step, step]);
  await serving.assertPhotoHelperSponsorship(f.context);
  // A bare transport Response is still not a validated receipt; the hold stays uncertain.
  const h = context();
  await assertRejects(() => serving.fundedAttempt(h.context, "photo.stage:1", step, {}, null, async () => new Response("ok") as never), HttpError);
  assertEquals(h.calls.map((call) => call.name), ["serving_cost_reserve", "serving_cost_finish"]);
  assertEquals(h.calls[1].args.p_state, "uncertain");
});

Deno.test("ceiling mode: the envelope refusal is quota the paywall can act on, and nothing is dispatched", async () => {
  mode("ceiling");
  for (const [message, expected] of [
    ["RP402: AI usage limit reached for this workspace (991 of 991 cents this month)", "This workspace has used its AI allowance for this period. Upgrade your plan or wait for the next period."],
    ["RP402: Free-trial AI limit reached for this month", "The free trial's AI allowance is used up for this month. Subscribe to keep going."],
  ] as const) {
    const f = context({ reserveError: message });
    f.context.operationBegun = true;
    let dispatched = false;
    const error = await assertRejects(() => serving.fundedAttempt(f.context, "photo.stage:0", step, {}, null, async () => { dispatched = true; return "image"; }), HttpError);
    assert(!dispatched);
    assertEquals(error.status, 402); assertEquals(error.code, "quota_exceeded"); assertEquals(error.message, expected);
    assertEquals(f.calls.map((call) => call.name), ["serving_cost_reserve", "serving_operation_no_dispatch"]);
  }
});

Deno.test("ceiling mode: a free catalog route runs without a hold; an unpriced step is refused unless privately sponsored", async () => {
  mode("ceiling");
  const f = context();
  assertEquals(await serving.fundedAttempt(f.context, "judge.fair_housing:0", routeStep({ provider: "rendprop", model: "fairhousing-regex", unit: "call", unit_cents: 0 }), {}, null, async () => "clean"), "clean");
  assertEquals(f.calls, []);
  const unpriced = context();
  let dispatched = false;
  const error = await assertRejects(() => serving.fundedAttempt(unpriced.context, "presenter.motion", { provider: "higgsfield", model: "motion-transfer" }, {}, null, async () => { dispatched = true; return "job"; }), HttpError);
  assert(!dispatched); assertEquals(error.status, 503);
  assert(!unpriced.calls.some((call) => call.name === "serving_cost_reserve"));
  const sponsored = context({ sponsored: true });
  assertEquals(await serving.fundedAttempt(sponsored.context, "presenter.motion", { provider: "higgsfield", model: "motion-transfer" }, {}, null, async () => "job"), "job");
  assertEquals(sponsored.calls.filter((call) => call.name === "serving_cost_reserve")[0].args.p_tariff_version, "unpriced-private-sponsorship");
  // A caller's own bounded quote still prices a step outside the catalog.
  const quoted = context();
  assertEquals(await serving.fundedAttempt(quoted.context, "voice.tts", { provider: "elevenlabs", model: "with-timestamps" }, { text: "hi" }, { cents: 2.2, version: "published-standard-20261006" }, async () => "audio"), "audio");
  assertEquals(quoted.calls[0].args.p_hold_cents, 2.2);
});

Deno.test("funded mode: the same attempt is refused before dispatch when nothing funds it", async () => {
  mode("funded");
  const f = context({ reserveError: "RP402: This workspace has no funded serving allowance" });
  let dispatched = false;
  const error = await assertRejects(() => serving.fundedAttempt(f.context, "photo.stage:0", step, {}, { cents: 1, version: "t" }, async () => { dispatched = true; return "image"; }), HttpError);
  assertEquals(error.status, 503);
  assert(!dispatched);
  assert(f.calls.some((call) => call.name === "serving_cost_reserve"));
  // Funded mode keeps the documentation bound, not the catalog price.
  const g = context();
  await serving.fundedAttempt(g.context, "photo.stage:0", step, {}, { cents: 31.1296, version: "published-standard-20261006" }, async () => "image");
  assertEquals(g.calls[0].args.p_hold_cents, 31.1296);
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
