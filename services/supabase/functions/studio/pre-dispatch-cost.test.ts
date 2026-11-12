// Actual handlers and production funding/provider/accounting paths; only the
// independent route/source gates and closed DB/provider transports are fixtures.
import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import type { RouteStep } from "../_shared/router.ts";
import type { StudioContext } from "./context.ts";
import { handleEditPlan } from "./edit-plan.ts";
import { handlePromptEnhancement } from "./prompt-enhancement.ts";
import { handleMediaAnalysis } from "./media-analysis.ts";
// Bind module-level clients to this closed transport before importing them.
for (const [key, value] of Object.entries({ SUPABASE_URL: "https://cost-dispatch-fixture.invalid", SUPABASE_SERVICE_ROLE_KEY: "synthetic-service", SUPABASE_ANON_KEY: "synthetic-public" })) Deno.env.set(key, value);
const { resetServingModeCache } = await import("../_shared/funded-serving.ts");
const { editPlanProduction } = await import("./edit-plan-production.ts");
const { mediaAnalysisProduction } = await import("./media-analysis-production.ts");

type Endpoint = "edit-plan" | "prompt-enhancement" | "media-analysis";
type Scenario = "funding-refused" | "operation-refused" | "late-abort" | "late-key-loss" | "lost-reply" | "invalid-answer" | "success";
const org = "10000000-0000-4000-8000-000000000001", user = "10000000-0000-4000-8000-000000000002";
const listing = "10000000-0000-4000-8000-000000000003", requestId = "10000000-0000-4000-8000-000000000004", sourceId = "10000000-0000-4000-8000-000000000005";
const draft = { id: "saved", revision: 1, ratio: "9:16", audio: "original", title: "", hasNarration: false, hasOverlays: false,
  clips: [{ id: "photo", kind: "image", start: 0, end: 5, speed: 1, caption: "", motion: "still", transition: "cut" }] };
function box(tag: string, body: Uint8Array) {
  const result = new Uint8Array(8 + body.length); new DataView(result.buffer).setUint32(0, result.length);
  result.set(new TextEncoder().encode(tag), 4); result.set(body, 8); return result;
}
function join(...parts: Uint8Array[]) {
  const result = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0)); let offset = 0;
  for (const part of parts) { result.set(part, offset); offset += part.length; } return result;
}
function movie() {
  const header = new Uint8Array(20), view = new DataView(header.buffer); view.setUint32(12, 1000); view.setUint32(16, 10000);
  const handler = new Uint8Array(12); handler.set(new TextEncoder().encode("soun"), 8);
  const timing = new Uint8Array(16), times = new DataView(timing.buffer); times.setUint32(4, 1); times.setUint32(8, 10000); times.setUint32(12, 1);
  const reference = new Uint8Array(4); new DataView(reference.buffer).setUint32(0, 1);
  const entries = new Uint8Array(8); new DataView(entries.buffer).setUint32(4, 1);
  const info = box("minf", join(box("dinf", box("dref", join(entries, box("url ", reference)))), box("stbl", box("stts", timing))));
  return join(box("ftyp", new TextEncoder().encode("isom0000")), box("mdat", new Uint8Array([1])),
    box("moov", join(box("mvhd", header), box("trak", box("mdia", join(box("mdhd", header), box("hdlr", handler), info))))));
}
async function fixture(endpoint: Endpoint, scenario: Scenario, run: (value: {
  call(): Promise<Response>; ledger: Record<string, unknown>[]; supplierCalls(): number; finishes: string[]; rpcCalls: string[];
}) => Promise<void>) {
  const priorFetch = globalThis.fetch, priorKey = Deno.env.get("OPENAI_API_KEY");
  Deno.env.set("OPENAI_API_KEY", "synthetic-provider-key"); resetServingModeCache();
  const controller = new AbortController(), ledger: Record<string, unknown>[] = [], finishes: string[] = [], rpcCalls: string[] = [];
  const rateKeys = new Set<string>(), unexpectedTransports: string[] = []; let supplierCalls = 0;
  const admin = {
    rpc: async (name: string, args: Record<string, unknown>) => {
      rpcCalls.push(name);
      if (name === "bump_rate") {
        const key = String(args.p_key); const duplicate = key.includes(":request:") && rateKeys.has(key); rateKeys.add(key);
        return { data: !duplicate, error: null };
      }
      if (name === "serving_operation_begin") return scenario === "operation-refused"
        ? { data: null, error: { message: "RP403: Scope unavailable" } } : { data: { begun: true }, error: null };
      if (name === "serving_operation_no_dispatch") return { data: { closed: true }, error: null };
      if (name === "serving_cost_reserve") {
        if (scenario === "late-abort") controller.abort();
        if (scenario === "late-key-loss") Deno.env.delete("OPENAI_API_KEY");
        return scenario === "funding-refused" ? { data: null, error: { message: "RP402: Shared serving allowance exhausted" } }
          : { data: { reserved: true }, error: null };
      }
      if (name === "serving_cost_finish") { finishes.push(String(args.p_state)); return { data: { finished: true }, error: null }; }
      throw new Error(`Unexpected closed RPC ${name}`);
    },
    from: (table: string) => {
      assertEquals(table, "cost_ledger");
      return { insert: (row: Record<string, unknown>) => { ledger.push(row); return Promise.resolve({ error: null }); } };
    },
  };
  globalThis.fetch = async (input, init) => {
    const req = new Request(input, init), url = new URL(req.url);
    if (url.origin === "https://cost-dispatch-fixture.invalid" && req.method === "POST") {
      if (url.pathname === "/rest/v1/rpc/serving_mode") return new Response(JSON.stringify("funded"));
      if (url.pathname === "/rest/v1/rpc/report_provider_outcome") return new Response("null");
    }
    if (url.origin !== "https://api.openai.com") unexpectedTransports.push("unexpected transport");
    assertEquals(url.origin, "https://api.openai.com"); assertEquals(req.method, "POST");
    assertEquals(url.pathname, endpoint === "media-analysis" ? "/v1/audio/transcriptions" : "/v1/responses");
    assert(!req.signal.aborted); supplierCalls++;
    if (scenario === "lost-reply") throw new TypeError("Closed fixture lost supplier reply");
    const answer: Record<string, unknown> = endpoint === "media-analysis" ? { duration: 10, words: [] }
      : { status: "completed", output_text: JSON.stringify(endpoint === "prompt-enhancement"
        ? { enhanced: "Make this square", notes: [] }
        : { status: "plan", reply: "Review", operations: [{ type: "ratio", value: "1:1" }] }) };
    // A transport-valid provider result can still be refused by the handler.
    if (scenario === "invalid-answer") {
      if (endpoint === "media-analysis") answer.duration = 20;
      else answer.output_text = JSON.stringify({ status: "plan", reply: "Review", operations: [{ type: "publish" }] });
    }
    return new Response(JSON.stringify(answer), { headers: { "content-type": "application/json" } });
  };
  const context = { admin, userId: user, orgId: org, authorizeListing: async (id: string) => { assertEquals(id, listing); } } as unknown as StudioContext;
  const media = endpoint === "media-analysis", task = media ? "stt.captions" : endpoint === "prompt-enhancement" ? "copy.prompt_enhancement" : "copy.edit_plan";
  const step: RouteStep = { route_id: "closed-route", task, provider: "openai", model: media ? "whisper-1" : "gpt-5.6-terra", unit: media ? "minute" : "call", unit_cents: media ? .6 : 2,
    capabilities: media ? ["stt", "word_timestamps"] : ["text", "compliant"], max_latency_s: 90, min_plan: "free", same_model_as: null, privacy_tier: "retained_30d", enabled: true };
  const common = { enabled: () => true, writable: async () => true, route: async () => step };
  const mediaInput = { listing_id: listing, source_id: sourceId, source_kind: "asset" as const };
  const payload = media ? mediaInput : endpoint === "prompt-enhancement" ? { message: "Make this square" } : { listing_id: listing, draft, message: "Make this square", history: [] };
  const call = () => {
    // Each incoming request gets its own real production dependency closure.
    const editDeps = { ...editPlanProduction(context, endpoint === "prompt-enhancement" ? "copy.prompt_enhancement" : "copy.edit_plan"), ...common, spaceType: async () => "real_estate" };
    const mediaDeps = { ...mediaAnalysisProduction(context), ...common,
      resolve: async () => ({ ...mediaInput, key: "uploads/closed/video.mp4", bucket: "uploads" as const, duration: 10 }), authorize: async () => {}, load: async () => ({ bytes: movie(), duration: 10 }) };
    const req = new Request(`https://fixture.invalid/studio/${endpoint}`, { method: "POST", headers: { "Idempotency-Key": requestId }, body: JSON.stringify(payload), signal: controller.signal });
    return media ? handleMediaAnalysis(req, context, mediaDeps)
      : endpoint === "prompt-enhancement" ? handlePromptEnhancement(req, context, editDeps) : handleEditPlan(req, context, editDeps);
  };
  try { await run({ call, ledger, supplierCalls: () => supplierCalls, finishes, rpcCalls }); assertEquals(unexpectedTransports, []); }
  finally { globalThis.fetch = priorFetch; if (priorKey === undefined) Deno.env.delete("OPENAI_API_KEY"); else Deno.env.set("OPENAI_API_KEY", priorKey); resetServingModeCache(); }
}
for (const endpoint of ["edit-plan", "prompt-enhancement", "media-analysis"] as const) {
  for (const scenario of ["funding-refused", "operation-refused", "late-abort", "late-key-loss"] as const) Deno.test(`${endpoint}: ${scenario} before supplier fetch records no estimated cost`, async () => {
    await fixture(endpoint, scenario, async f => {
      await assertRejects(f.call); assertEquals(f.supplierCalls(), 0); assertEquals(f.ledger, []);
      assert(f.rpcCalls.includes(scenario === "operation-refused" ? "serving_operation_begin" : "serving_cost_reserve"));
      assertEquals(f.finishes, scenario === "late-abort" || scenario === "late-key-loss" ? ["uncertain"] : []);
    });
  });
  Deno.test(`${endpoint}: invoked fetch lost reply retains one uncertain estimate and duplicate409`, async () => {
    await fixture(endpoint, "lost-reply", async f => {
      await assertRejects(f.call, HttpError, "No automatic retry");
      await assertRejects(f.call, HttpError, "already submitted");
      assertEquals(f.supplierCalls(), 1); assertEquals(f.ledger.length, 1); assertEquals(f.finishes, ["uncertain"]);
      assertEquals(f.ledger[0].meta && (f.ledger[0].meta as Record<string, unknown>).outcome, "uncertain");
    });
  });
  Deno.test(`${endpoint}: handler-refused returned answer still records one returned estimate`, async () => {
    await fixture(endpoint, "invalid-answer", async f => {
      await assertRejects(f.call, HttpError); assertEquals(f.supplierCalls(), 1); assertEquals(f.ledger.length, 1); assertEquals(f.finishes, ["succeeded"]);
      assertEquals((f.ledger[0].meta as Record<string, unknown>).outcome, "returned");
    });
  });
  Deno.test(`${endpoint}: successful answer retains exactly one configured estimate`, async () => {
    await fixture(endpoint, "success", async f => {
      assertEquals((await f.call()).status, 200); assertEquals(f.supplierCalls(), 1); assertEquals(f.ledger.length, 1); assertEquals(f.finishes, ["succeeded"]);
      assertEquals(f.ledger[0].total_cents, endpoint === "media-analysis" ? .1 : 2);
      assertEquals((f.ledger[0].meta as Record<string, unknown>).outcome, "returned");
    });
  });
}
