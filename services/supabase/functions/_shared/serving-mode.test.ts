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

Deno.test("ceiling mode: an attempt reserves its DOCUMENTED bound (never below the catalog price) before dispatch and settles after", async () => {
  mode("ceiling");
  const f = context();
  let dispatched = false;
  assertEquals(await serving.fundedAttempt(f.context, "photo.stage:0", step, { prompt: "x" }, null, async () => { dispatched = true; return "image"; }), "image");
  assert(dispatched);
  assertEquals(f.calls.map((call) => call.name), ["serving_cost_reserve", "serving_cost_finish"]);
  // Gemini 3.1 Flash Image: 8,192 input tokens x $0.50/M + 4,096 text tokens x $3/M + one 1K image (1,120 tokens x $60/M).
  assertEquals(f.calls[0].args.p_hold_cents, 8.3584);
  assertEquals(f.calls[0].args.p_tariff_version, "documented-bound-20261008");
  assertEquals(f.calls[0].args.p_stage, "photo.stage:0");
  assertEquals(f.calls[1].args.p_state, "succeeded");
  // The documented bound replaces the funded model's whole-window bound (31.1296c) for this model…
  const g = context();
  await serving.fundedAttempt(g.context, "photo.stage:0", step, { prompt: "x" }, { cents: 31.1296, version: "published-standard-20261006" }, async () => "image");
  assertEquals(g.calls[0].args.p_hold_cents, 8.3584);
  // …but never drops below the catalog price the ledger bills.
  const pricey = context();
  await serving.fundedAttempt(pricey.context, "photo.stage:0", routeStep({ unit_cents: 9.5 }), { prompt: "x" }, null, async () => "image");
  assertEquals(pricey.calls[0].args.p_hold_cents, 9.5);
  // The route's own chain is kept and helpers are not fenced: each step pays its way.
  assertEquals(await serving.boundedPhotoChain(f.context, [step, step], { task: "photo.stage", prompt: "x" } as never), [step, step]);
  await serving.assertPhotoHelperSponsorship(f.context);
  // A bare transport Response is still not a validated receipt; the hold stays uncertain.
  const h = context();
  await assertRejects(() => serving.fundedAttempt(h.context, "photo.stage:1", step, {}, null, async () => new Response("ok") as never), HttpError);
  assertEquals(h.calls.map((call) => call.name), ["serving_cost_reserve", "serving_cost_finish"]);
  assertEquals(h.calls[1].args.p_state, "uncertain");
});

Deno.test("documented bounds: gpt-image-2, FLUX fill per rounded-up megapixel, Kontext per image, lite image; others keep the caller's quote", () => {
  const tiny = "data:image/png;base64," + btoa(String.fromCharCode(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0x08, 0x00, 0, 0, 0x06, 0x00, 8, 2, 0, 0, 0) + "x".repeat(80));
  assertEquals(serving.imagePixelsFromBase64(tiny), 2048 * 1536);
  assertEquals(serving.ceilingVerifiedQuote(routeStep({ provider: "openai", model: "gpt-image-2" }), {}, null), { cents: 11.3056, version: "documented-bound-20261008" });
  assertEquals(serving.ceilingVerifiedQuote(routeStep({ provider: "fal", model: "flux-pro/v1/fill" }), { image_url: tiny }, null), { cents: 20, version: "documented-bound-20261008" });
  assertEquals(serving.ceilingVerifiedQuote(routeStep({ provider: "fal", model: "fal-ai/flux-pro/v1/fill" }), {}, null), { cents: 25, version: "documented-bound-20261008" });
  assertEquals(serving.ceilingVerifiedQuote(routeStep({ provider: "fal", model: "flux-pro/kontext" }), {}, null), { cents: 4, version: "documented-bound-20261008" });
  assertEquals(serving.ceilingVerifiedQuote(routeStep({ provider: "gemini", model: "gemini-3.1-flash-lite-image" }), {}, null), { cents: 4.1792, version: "documented-bound-20261008" });
  assertEquals(serving.ceilingVerifiedQuote({ provider: "elevenlabs", model: "with-timestamps" }, {}, { cents: 2.2, version: "t" }), { cents: 2.2, version: "t" });
  assertEquals(serving.ceilingVerifiedQuote({ provider: "higgsfield", model: "motion-transfer" }, {}, null), null);
  // Vision / video input bounds come from documented per-image and per-second token counts.
  assertEquals(serving.visionInputTokenBound(4, 2000), 4 * 2048 + 1000 + 1024);
  assertEquals(serving.videoInputTokenBound(60, 500), 15780 + 250 + 1024);
  const judge = serving.textAttemptQuote(routeStep({ provider: "anthropic", model: "claude-sonnet-5", unit: "call", unit_cents: 1.3 }), "rubric", "", 1024, true, serving.visionInputTokenBound(4, 6));
  assert(judge && judge.cents < 3, `judge bound ${judge?.cents} should be a few cents, not a context window`);
  const chapters = serving.textAttemptQuote(routeStep({ provider: "gemini", model: "gemini-3.1-flash-lite", unit: "call", unit_cents: 0.6 }), "s", "p", 4096, true, serving.videoInputTokenBound(120, 100));
  assert(chapters && chapters.cents < 2, `chapters bound ${chapters?.cents}`);
  assertEquals(serving.textAttemptQuote(routeStep({ provider: "openai", model: "gpt-5.6-luna", unit: "call", unit_cents: 0.12 }), "r", "", 512, true), null);
  assert(serving.textAttemptQuote(routeStep({ provider: "openai", model: "gpt-5.6-luna", unit: "call", unit_cents: 0.12 }), "r", "", 512, true, 9216) !== null);
  assert(serving.textAttemptQuote(routeStep({ provider: "gemini", model: "gemini-3.8-flash", unit: "call", unit_cents: 0.9 }), "s", "t", 2048) !== null);
});

Deno.test("ceiling mode: refusals are quota the paywall can act on, name their kind, and dispatch nothing", async () => {
  mode("ceiling");
  for (const [message, expected] of [
    ["RP402: AI usage limit reached [kind=retail] (991 of 991 cents this period)", "This workspace has used its AI allowance for the current billing period. It resets with the next period, or upgrade for more."],
    ["RP402: AI usage limit reached [kind=free] (300 of 300 cents this lifetime)", "Your free AI sample is used up. Subscribe to keep using AI tools."],
    ["RP402: AI usage limit reached [kind=trial] (500 of 500 cents this period)", "Your trial's AI allowance is used up. Your plan's full allowance starts with the paid period."],
    ["RP402: AI usage limit reached [kind=grace] (10 of 991 cents this period)", "AI tools are paused while Apple retries your subscription payment. They resume as soon as the renewal goes through."],
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

Deno.test("shared trial capacity refusal stops dispatch and emits availability instead of an upgrade quota", async () => {
  mode("ceiling");
  for (const pool of ["cap", "closed"]) {
    const f = context({ reserveError: `RP402: Free-trial AI limit reached [pool=${pool}]` });
    f.context.operationBegun = true;
    let dispatched = false;
    const error = await assertRejects(() => serving.fundedAttempt(f.context, "photo.stage:0", step, {}, null, async () => { dispatched = true; return "image"; }), HttpError);
    assert(!dispatched);
    assertEquals(error.status, 402);
    assertEquals(error.code, "trial_capacity_unavailable");
    assertEquals(error.message, "Trial AI is temporarily unavailable. Nothing was charged. Please try again later or contact support.");
    assertEquals(f.calls.map(call => call.name), ["serving_cost_reserve", "serving_operation_no_dispatch"]);
  }
});

Deno.test("ceiling mode: a free catalog route runs without a hold; a step with no documented bound is refused unless privately sponsored", async () => {
  mode("ceiling");
  const f = context();
  assertEquals(await serving.fundedAttempt(f.context, "judge.fair_housing:0", routeStep({ provider: "rendprop", model: "fairhousing-regex", unit: "call", unit_cents: 0 }), {}, null, async () => "clean"), "clean");
  assertEquals(f.calls, []);
  const unpriced = context();
  let dispatched = false;
  const error = await assertRejects(() => serving.fundedAttempt(unpriced.context, "presenter.motion", { provider: "higgsfield", model: "motion-transfer" }, {}, null, async () => { dispatched = true; return "job"; }), HttpError);
  assert(!dispatched); assertEquals(error.status, 503);
  assert(!unpriced.calls.some((call) => call.name === "serving_cost_reserve"));
  // A catalog price alone is an estimate, not a documented bound: still refused.
  const catalogOnly = context();
  await assertRejects(() => serving.fundedAttempt(catalogOnly.context, "video.reel_clip", routeStep({ provider: "fal", model: "some/new/model", unit: "second", unit_cents: 3 }), { seconds: 5 }, null, async () => "job"), HttpError);
  assert(!catalogOnly.calls.some((call) => call.name === "serving_cost_reserve"));
  const sponsored = context({ sponsored: true });
  assertEquals(await serving.fundedAttempt(sponsored.context, "presenter.motion", { provider: "higgsfield", model: "motion-transfer" }, {}, null, async () => "job"), "job");
  assertEquals(sponsored.calls.filter((call) => call.name === "serving_cost_reserve")[0].args.p_tariff_version, "unpriced-private-sponsorship");
  // A caller's own bounded quote still prices a step outside the documented table.
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
