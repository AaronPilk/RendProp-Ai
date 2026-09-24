// The actual deployed Studio handler, with only Auth/PostgREST/provider transport
// substituted. Every unexpected request fails; no socket or real media is used.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
const org = "10000000-0000-4000-8000-000000000001", user = "10000000-0000-4000-8000-000000000002", listing = "10000000-0000-4000-8000-000000000003", requestId = "10000000-0000-4000-8000-000000000004";
for (const [key, value] of Object.entries({ SUPABASE_URL: "https://edit-plan-fixture.invalid", SUPABASE_ANON_KEY: "synthetic-public", SUPABASE_SERVICE_ROLE_KEY: "synthetic-service", OPENAI_API_KEY: "synthetic-provider-key" })) Deno.env.set(key, value);
const descriptor = Object.getOwnPropertyDescriptor(Deno, "serve")!;
Object.defineProperty(Deno, "serve", { configurable: true, writable: true, value: () => ({}) });
let handleStudio: typeof import("./index.ts").handleStudio;
try { ({ handleStudio } = await import("./index.ts")); }
finally { Object.defineProperty(Deno, "serve", descriptor); }
const { resetRouterCache } = await import("../_shared/router.ts");
const body = { listing_id: listing, draft: { id: "draft", revision: 2, ratio: "9:16", audio: "original", title: "", hasNarration: false, hasOverlays: false, clips: [{ id: "clip", kind: "image", start: 0, end: 5, speed: 1, caption: "", motion: "still", transition: "cut" }] }, message: "Make this square", history: [] };
const response = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
type Options = { endpoint?: "edit-plan" | "prompt-enhancement"; providerText?: string; enabled?: boolean; role?: string; anonymous?: boolean; deleting?: boolean; member?: boolean; active?: boolean; routeEnabled?: boolean; legacy?: boolean; minPlan?: string; retired?: boolean; capabilities?: string[]; providerFails?: boolean };
async function fixture(options: Options, run: (call: (method: "GET" | "POST", auth?: boolean, payload?: unknown) => Promise<Response>) => Promise<void>) {
  const endpoint = options.endpoint ?? "edit-plan", task = endpoint === "prompt-enhancement" ? "copy.prompt_enhancement" : "copy.edit_plan";
  const oldFetch = globalThis.fetch; resetRouterCache();
  Deno.env.set("STUDIO_EDIT_PLANNER_ENABLED", options.enabled ? "true" : "false"); Deno.env.set("STUDIO_EDIT_PLANNER_MAX_ESTIMATED_CENTS", "3");
  const seenRequests = new Set<string>(); let providerCalls = 0; const ledger: Record<string, unknown>[] = [], limits: Record<string, unknown>[] = [];
  globalThis.fetch = async (input, init) => {
    const req = new Request(input, init), url = new URL(req.url);
    if (url.origin === "https://api.openai.com") {
      assertEquals(url.pathname, "/v1/responses"); providerCalls++;
      const sent = await req.json(); const text = JSON.stringify(sent); assert(!text.includes(listing)); assert(!text.includes("sha256")); assertEquals(sent.tools, undefined);
      return options.providerFails ? response({ error: "synthetic failure" }, 503) : response({ status: "completed", output_text: options.providerText ?? JSON.stringify(endpoint === "prompt-enhancement" ? { enhanced: "Make this square", notes: [] } : { status: "plan", reply: "Done", operations: [{ type: "ratio", value: "1:1" }] }) });
    }
    assertEquals(url.hostname, "edit-plan-fixture.invalid");
    if (url.pathname === "/auth/v1/user") return response({ id: user, is_anonymous: options.anonymous ?? false, email: "fixture@example.invalid" });
    const table = url.pathname.split("/").pop();
    if (table === "memberships") { assertEquals(url.searchParams.get("user_id"), `eq.${user}`); assertEquals(url.searchParams.get("org_id"), `eq.${org}`); return response(options.member === false ? null : { org_id: org, role: options.role ?? "owner" }); }
    if (table === "orgs") return response(options.active === false ? null : { id: org });
    if (table === "deletion_requests") return response(options.deleting ? [{ id: "deletion", user_id: user }] : url.searchParams.get("select") === "id" ? null : []);
    if (table === "listings") return response({ id: listing, org_id: org, space_type: "real_estate" });
    if (table === "bump_rate") {
      const args = await req.json(); limits.push(args);
      if (args.p_key.startsWith("edit-plan:request:")) { const duplicate = seenRequests.has(args.p_key); seenRequests.add(args.p_key); return response(!duplicate); }
      return response(true);
    }
    if (table === "org_entitlement") return response({ plan: "free", renders_per_month: 0, photo_edits_per_month: 0, reels_per_month: 0, aerials_per_month: 0, topaz_per_month: 0, seats: 1, cogs_ceiling_cents: 0, price_cents: 0 });
    if (table === "app_config") return response({ value: { enabled: !options.legacy } });
    if (table === "plan_routing_policy" || table === "provider_health") return response([]);
    if (table === "ai_routes") {
      assertEquals(url.searchParams.get("task"), `eq.${task}`);
      const route = { id: "route", task, position: 1, provider: "openai", model: "fixture", unit: "call", unit_cents: 2, capabilities: options.capabilities ?? ["text", "compliant"], max_latency_s: 30, min_plan: options.minPlan ?? "free", same_model_as: null, privacy_tier: "retained_30d", enabled: options.routeEnabled !== false, retire_after: options.retired ? "2020-01-01" : null, note: options.legacy ? "legacy" : "fixture", params: null };
      return response(url.searchParams.has("id") ? options.routeEnabled === false ? null : { id: "route" } : [route]);
    }
    if (table === "report_provider_outcome") return response(null);
    if (table === "cost_ledger") { ledger.push(await req.json()); return new Response(null, { status: 201 }); }
    throw new Error(`Unexpected fixture request ${url.pathname}`);
  };
  const call = (method: "GET" | "POST", auth = true, payload: unknown = endpoint === "prompt-enhancement" ? { message: "Make this square" } : body) => handleStudio(new Request(`https://fixture.invalid/studio/${endpoint}`, { method, headers: { ...(auth ? { authorization: "Bearer synthetic-owner" } : {}), "X-Org-Id": org, "Idempotency-Key": requestId }, ...(method === "POST" ? { body: JSON.stringify(payload) } : {}) }));
  try { await run(call); return { providerCalls, ledger, limits }; }
  finally { globalThis.fetch = oldFetch; Deno.env.delete("STUDIO_EDIT_PLANNER_ENABLED"); Deno.env.delete("STUDIO_EDIT_PLANNER_MAX_ESTIMATED_CENTS"); resetRouterCache(); }
}
Deno.test("actual Studio edit-plan rejects unauthenticated, anonymous, removed, deleting and inactive accounts", async () => {
  for (const [options, expected] of [[{}, 401], [{ anonymous: true }, 403], [{ member: false }, 403], [{ deleting: true }, 409], [{ active: false }, 403]] as [Options, number][]) {
    const r = await fixture({ ...options, enabled: true }, async call => assertEquals((await call("POST", expected !== 401)).status, expected));
    assertEquals(r.providerCalls, 0); assertEquals(r.ledger, []);
  }
});
Deno.test("actual Studio capability reports disabled/read-only without provider calls", async () => {
  for (const [options, reason] of [[{}, "disabled"], [{ enabled: true, role: "marketing" }, "read_only"]] as [Options, string][]) {
    const r = await fixture(options, async call => { const result = await call("GET"); assertEquals(result.status, 200); assertEquals((await result.json()).reason, reason); });
    assertEquals(r.providerCalls, 0); assertEquals(r.ledger, []);
  }
});
Deno.test("actual Studio planner executes one mocked text call and rejects replay before another charge", async () => {
  const r = await fixture({ enabled: true }, async call => {
    const capability = await call("GET"); assertEquals((await capability.json()).available, true);
    const first = await call("POST"); assertEquals(first.status, 200); const result = await first.json();
    assertEquals(result.plan, { draftId: "draft", expectedRevision: 2, operations: [{ type: "ratio", value: "1:1" }] });
    assertEquals((await call("POST")).status, 409);
  });
  assertEquals(r.providerCalls, 1); assertEquals(r.ledger.length, 1);
  assertEquals(r.ledger[0].org_id, org); assertEquals(r.ledger[0].feature, "copy_assist");
  assertEquals((r.ledger[0].meta as Record<string, unknown>).price_estimated, true);
  assert(r.limits.some(item => item.p_key === `edit-plan:request:${org}:${user}:${requestId}` && item.p_max === 1));
});
Deno.test("actual Studio planner never bypasses inactive, retired, wrong-capability or high-plan legacy routes", async () => {
  for (const options of [{ routeEnabled: false }, { legacy: true, routeEnabled: false }, { legacy: true, minPlan: "team" }, { legacy: true, retired: true }, { legacy: true, capabilities: ["text"] }]) {
    const r = await fixture({ enabled: true, ...options }, async call => { const result = await call("GET"); assertEquals((await result.json()).available, false); assertEquals((await call("POST")).status, 503); });
    assertEquals(r.providerCalls, 0); assertEquals(r.ledger, []);
  }
});
Deno.test("actual Studio provider failure keeps one uncertain estimate and never fails over or replays", async () => {
  const r = await fixture({ enabled: true, providerFails: true }, async call => { assertEquals((await call("POST")).status, 502); assertEquals((await call("POST")).status, 409); });
  assertEquals(r.providerCalls, 1); assertEquals(r.ledger.length, 1); assertEquals((r.ledger[0].meta as Record<string, unknown>).outcome, "uncertain");
});
Deno.test("actual Studio prompt enhancement shares account gates and disabled zero-provider capability", async () => {
  for (const [options, expected] of [[{}, 401], [{ anonymous: true }, 403], [{ member: false }, 403], [{ deleting: true }, 409], [{ active: false }, 403], [{ role: "marketing" }, 403]] as [Options, number][]) {
    const r = await fixture({ ...options, endpoint: "prompt-enhancement", enabled: true }, async call => assertEquals((await call("POST", expected !== 401)).status, expected));
    assertEquals(r.providerCalls, 0); assertEquals(r.ledger, []);
  }
  const disabled = await fixture({ endpoint: "prompt-enhancement" }, async call => { assertEquals((await (await call("GET")).json()).available, false); assertEquals((await call("POST")).status, 503); });
  assertEquals(disabled.providerCalls, 0);
});
Deno.test("actual Studio prompt enhancement returns review-only text before media and never dispatches twice", async () => {
  const r = await fixture({ endpoint: "prompt-enhancement", enabled: true }, async call => {
    const first = await call("POST"); assertEquals(first.status, 200);
    assertEquals(await first.json(), { original: "Make this square", enhanced: "Make this square", notes: [], method: "ai" });
    assertEquals((await call("POST")).status, 409);
  });
  assertEquals(r.providerCalls, 1); assertEquals(r.ledger.length, 1);
  assertEquals((r.ledger[0].meta as Record<string, unknown>).kind, "prompt_enhancement");
  assertEquals((r.ledger[0].meta as Record<string, unknown>).task, "copy.prompt_enhancement");
});
Deno.test("actual Studio prompt enhancement refuses oversized or unsafe input before spend and rejects invented output", async () => {
  for (const payload of [{ message: "x".repeat(2001) }, { message: "Perfect for families" }, { message: "Make it square", tools: [{ publish: true }] }]) {
    const r = await fixture({ endpoint: "prompt-enhancement", enabled: true }, async call => assertEquals((await call("POST", true, payload)).status, 400));
    assertEquals(r.providerCalls, 0); assertEquals(r.ledger, []);
  }
  for (const providerText of [JSON.stringify({ enhanced: "", notes: [] }), JSON.stringify({ enhanced: "Make this square with 12 bedrooms", notes: [] }), JSON.stringify({ enhanced: "x".repeat(2001), notes: [] }), JSON.stringify({ enhanced: "Make this square", notes: [], action: "publish" })]) {
    const r = await fixture({ endpoint: "prompt-enhancement", enabled: true, providerText }, async call => assertEquals((await call("POST")).status, 502));
    assertEquals(r.providerCalls, 1); assertEquals(r.ledger.length, 1);
  }
});
