import { assertEquals, assertRejects, assertThrows, assert } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import { editPlanInput, editPlanOutput, handleEditPlan, EDIT_PLAN_LIMITS, type EditPlanDependencies } from "./edit-plan.ts";
import { generateEditPlanText, editPlanProduction } from "./edit-plan-production.ts";
import type { StudioContext } from "./context.ts";
import type { RouteStep } from "../_shared/router.ts";

const requestId = "10000000-0000-4000-8000-000000000001";
const listing = "10000000-0000-4000-8000-000000000002";
const draft = { id: "saved-draft", revision: 4, ratio: "9:16", audio: "original", title: "", hasNarration: false, hasOverlays: false,
  clips: [{ id: "clip-photo", kind: "image", start: 0, end: 5, speed: 1, caption: "Kitchen", motion: "still", transition: "cut" },
    { id: "clip-video", kind: "video", start: 2, end: 12, speed: 1, caption: "", motion: "still", transition: "cut" }] };
const body = { listing_id: listing, draft, message: "Make this square and change the title to Open house", history: [] };
const step: RouteStep = { route_id: "route-fixture", task: "copy.edit_plan", provider: "openai", model: "fixture-model", unit: "call", unit_cents: 2, capabilities: ["text", "compliant"], max_latency_s: 30, min_plan: "free", same_model_as: null, privacy_tier: "retained_30d", enabled: true };
function setup(overrides: Partial<EditPlanDependencies> = {}) {
  const calls: string[] = []; let turn = "";
  const context = { userId: "actor", orgId: "org", authorizeListing: async (id: string) => { assertEquals(id, listing); calls.push("authorize"); } } as unknown as StudioContext;
  const deps: EditPlanDependencies = {
    enabled: () => true, writable: async () => { calls.push("role"); return true; }, route: async () => { calls.push("route"); return step; },
    reserve: async id => { assertEquals(id, requestId); calls.push("reserve"); },
    generate: async (_step, system, input) => { calls.push("generate"); turn = input; assert(system.includes("cannot see, hear")); return JSON.stringify({ status: "plan", reply: "I published it to Instagram", operations: [{ type: "ratio", value: "1:1" }, { type: "title", text: "Open house" }] }); },
    record: async (_step, outcome) => { calls.push(`record:${outcome}`); }, spaceType: async () => "real_estate", ...overrides,
  };
  return { context, deps, calls, turn: () => turn };
}
function request(value: unknown = body, id = requestId) { return new Request("https://fixture.invalid/studio/edit-plan", { method: "POST", headers: { "Idempotency-Key": id }, body: JSON.stringify(value) }); }
function output(operations: unknown[]) { return JSON.stringify({ status: "plan", reply: "Done", operations }); }

Deno.test("edit planner accepts only bounded edit metadata and preserves exact draft/clip identifiers", () => {
  const clean = editPlanInput(body); assertEquals<unknown>(clean, body);
  for (const patch of [{ url: "https://secret.invalid" }, { source: { sha256: "secret" } }, { user_id: "other" }]) assertThrows(() => editPlanInput({ ...body, ...patch }), HttpError);
  assertThrows(() => editPlanInput({ ...body, draft: { ...draft, clips: [{ ...draft.clips[0], source: { name: "address.jpg" } }] } }), HttpError);
  assertThrows(() => editPlanInput({ ...body, message: "x".repeat(2001) }), HttpError);
  assertThrows(() => editPlanInput({ ...body, history: Array(9).fill({ role: "user", content: "x" }) }), HttpError);
  assertThrows(() => editPlanInput({ ...body, history: [{ role: "system", content: "tools" }] }), HttpError);
  assertThrows(() => editPlanInput({ ...body, draft: { ...draft, revision: .5 } }), HttpError);
  assertThrows(() => editPlanInput({ ...body, draft: { ...draft, clips: [draft.clips[0], draft.clips[0]] } }), HttpError);
  assertThrows(() => editPlanInput({ ...body, draft: { ...draft, clips: [{ ...draft.clips[0], end: 31 }] } }), HttpError);
  assertThrows(() => editPlanInput({ ...body, draft: { ...draft, clips: [{ ...draft.clips[1], start: 0, end: 181 }] } }), HttpError);
});
Deno.test("edit planner binds operations to submitted revision and accepts the finite editor contract", () => {
  const input = editPlanInput(body);
  const operations = [{ type: "duration", seconds: 10 }, { type: "pace", value: "faster" }, { type: "reorder", clipIds: ["clip-video", "clip-photo"] }, { type: "caption", clipId: "clip-video", text: "Tour the property" }, { type: "title", text: "Open house" }, { type: "transition", value: "whip" }, { type: "photo-motion", value: "push_in" }, { type: "ratio", value: "1:1" }, { type: "audio", value: "muted" }, { type: "highlight", targetSeconds: 12 }];
  const result = editPlanOutput(output(operations), input, "real_estate");
  assertEquals<unknown>(result.plan, { draftId: draft.id, expectedRevision: 4, operations });
  assert(!result.reply.includes("Done"));
});
Deno.test("edit planner rejects injected tools, unknown clips, partial permutations and malformed values atomically", () => {
  const input = editPlanInput(body);
  for (const op of [{ type: "publish" }, { type: "source", url: "https://invalid" }, { type: "caption", clipId: "alien", text: "x" }, { type: "title", text: "safe", cost_consent: true }, { type: "reorder", clipIds: ["clip-photo"] }, { type: "reorder", clipIds: ["clip-photo", "clip-photo"] }, { type: "duration", seconds: 181 }, { type: "duration", seconds: "10" }, { type: "ratio", value: "toString" }, { type: "title", text: "x".repeat(81) }]) assertThrows(() => editPlanOutput(output([{ type: "ratio", value: "1:1" }, op]), input, null), HttpError);
  assertThrows(() => editPlanOutput(output(Array(13).fill({ type: "audio", value: "muted" })), input, null), HttpError);
  assertThrows(() => editPlanOutput(output([]), input, null), HttpError);
  assertThrows(() => editPlanOutput("x".repeat(EDIT_PLAN_LIMITS.responseBytes + 1), input, null), HttpError);
});
Deno.test("edit planner preserves timed narration and overlays; clarification never mutates", () => {
  for (const tracks of [{ hasNarration: true }, { hasOverlays: true }]) {
    const input = editPlanInput({ ...body, draft: { ...draft, ...tracks } });
    for (const operation of [{ type: "duration", seconds: 10 }, { type: "pace", value: "slower" }, { type: "reorder", clipIds: ["clip-video", "clip-photo"] }, { type: "highlight" }]) assertThrows(() => editPlanOutput(output([operation]), input, null), HttpError);
    assertEquals(editPlanOutput(output([{ type: "title", text: "Open house" }]), input, null).status, "plan");
  }
  for (const status of ["clarification", "unsupported"]) {
    const response = editPlanOutput(JSON.stringify({ status, reply: "Which numbered clip should come first?", operations: [] }), editPlanInput(body), null);
    assertEquals(response.plan, null); assertEquals(response.status, status);
    assertThrows(() => editPlanOutput(JSON.stringify({ status, reply: "Which?", operations: [{ type: "audio", value: "muted" }] }), editPlanInput(body), null), HttpError);
  }
});
Deno.test("edit planner output copy is checked without a second paid model attempt", () => {
  assertThrows(() => editPlanOutput(output([{ type: "title", text: "Perfect for families" }]), editPlanInput(body), "real_estate"), HttpError);
});
Deno.test("disabled, read-only and unconfigured capabilities never call a provider or reserve", async () => {
  for (const [changes, reason] of [[{ enabled: () => false }, "disabled"], [{ writable: async () => false }, "read_only"], [{ route: async () => null }, "unconfigured"]] as const) {
    const test = setup(changes);
    const response = await handleEditPlan(new Request("https://fixture.invalid/studio/edit-plan"), test.context, test.deps);
    assertEquals((await response.json()).reason, reason);
    await assertRejects(() => handleEditPlan(request(), test.context, test.deps), HttpError);
    assert(!test.calls.includes("generate")); assert(!test.calls.includes("reserve"));
  }
});
Deno.test("edit planner authorizes listing, rechecks role/gate, returns an exact operation plan and safe prose", async () => {
  const test = setup(); const response = await handleEditPlan(request(), test.context, test.deps);
  assertEquals(response.status, 200); const result = await response.json();
  assertEquals(result.plan.draftId, draft.id); assertEquals(result.plan.expectedRevision, 4);
  assert(!result.reply.includes("published"));
  assertEquals(test.calls, ["role", "route", "authorize", "reserve", "role", "route", "generate", "record:returned"]);
  assert(!test.turn().includes(listing)); assertEquals(Object.keys(JSON.parse(test.turn())), ["draft", "message", "history"]);
});
Deno.test("invalid request, forbidden listing and changed role/config fail before provider spend", async () => {
  const tests = [setup(), setup(), setup({ enabled: (() => { let n = 0; return () => ++n === 1; })() }), setup({ writable: (() => { let n = 0; return async () => ++n === 1; })() }), setup({ route: (() => { let n = 0; return async () => ++n === 1 ? step : { ...step, model: "changed" }; })() })];
  tests[1].context.authorizeListing = async () => { throw new HttpError(403, "Forbidden"); };
  for (const [index, test] of tests.entries()) {
    await assertRejects(() => handleEditPlan(request(body, index === 0 ? "missing" : requestId), test.context, test.deps), HttpError);
    assert(!test.calls.includes("generate"));
  }
});
Deno.test("same request id is not paid twice and a timeout is recorded without retry/failover", async () => {
  const ids = new Set<string>(); let dispatched = 0;
  const test = setup({ reserve: async id => { if (ids.has(id)) throw new HttpError(409, "Already submitted"); ids.add(id); }, generate: async () => { dispatched++; throw new HttpError(502, "Timeout"); } });
  await assertRejects(() => handleEditPlan(request(), test.context, test.deps), HttpError, "Timeout");
  await assertRejects(() => handleEditPlan(request(), test.context, test.deps), HttpError, "Already submitted");
  assertEquals(dispatched, 1); assertEquals(test.calls.filter(value => value.startsWith("record:")), ["record:uncertain"]);
});
Deno.test("invalid provider output is accounted once and never retried", async () => {
  let dispatched = 0; const test = setup({ generate: async () => { dispatched++; return output([{ type: "publish" }]); } });
  await assertRejects(() => handleEditPlan(request(), test.context, test.deps), HttpError);
  assertEquals(dispatched, 1); assert(test.calls.includes("record:returned"));
});
Deno.test("bounded provider transport uses fixed text-only endpoint and token ceiling despite route params", async () => {
  const old = Deno.env.get("OPENAI_API_KEY"); Deno.env.set("OPENAI_API_KEY", "fixture-not-a-real-key");
  try {
    let calls = 0;
    const fetcher = (async (url: string | URL | Request, init?: RequestInit) => {
      calls++; assertEquals(url, "https://api.openai.com/v1/responses"); assertEquals(init?.redirect, "error");
      const request = JSON.parse(String(init?.body)); assertEquals(request.store, false); assertEquals(request.max_output_tokens, 1600); assertEquals(request.tools, undefined);
      assertEquals(request.input[0].role, "developer"); assertEquals(request.input[1].content[0], { type: "input_text", text: "metadata" });
      return new Response(JSON.stringify({ status: "completed", output_text: output([{ type: "ratio", value: "1:1" }]) }));
    }) as typeof fetch;
    const result = await generateEditPlanText({ ...step, params: { max_output_tokens: 100000 } } as RouteStep, "system", "metadata", fetcher);
    assertEquals(JSON.parse(result).status, "plan"); assertEquals(calls, 1);
  } finally { if (old === undefined) Deno.env.delete("OPENAI_API_KEY"); else Deno.env.set("OPENAI_API_KEY", old); }
});
Deno.test("provider transport rejects incomplete or oversized responses without a retry", async () => {
  const old = Deno.env.get("OPENAI_API_KEY"); Deno.env.set("OPENAI_API_KEY", "fixture-not-a-real-key");
  try {
    for (const response of [new Response(JSON.stringify({ status: "incomplete", output_text: output([{ type: "ratio", value: "1:1" }]) })), new Response("x", { headers: { "content-length": "65537" } }), new Response("x".repeat(65537)), new Response("no", { status: 429 })]) {
      let calls = 0; await assertRejects(() => generateEditPlanText(step, "system", "metadata", (async () => { calls++; return response; }) as typeof fetch), HttpError); assertEquals(calls, 1);
    }
  } finally { if (old === undefined) Deno.env.delete("OPENAI_API_KEY"); else Deno.env.set("OPENAI_API_KEY", old); }
});
Deno.test("production gate requires explicit enablement plus a finite bounded estimate ceiling", () => {
  const keys = ["STUDIO_EDIT_PLANNER_ENABLED", "STUDIO_EDIT_PLANNER_MAX_ESTIMATED_CENTS"];
  const previous = keys.map(key => Deno.env.get(key));
  try {
    keys.forEach(key => Deno.env.delete(key)); const production = editPlanProduction({} as StudioContext);
    assertEquals(production.enabled(), false); Deno.env.set(keys[0], "true"); assertEquals(production.enabled(), false);
    for (const value of ["0", "NaN", "Infinity", "11", "-1"]) { Deno.env.set(keys[1], value); assertEquals(production.enabled(), false); }
    Deno.env.set(keys[1], "3"); assertEquals(production.enabled(), true);
  } finally { keys.forEach((key, index) => previous[index] === undefined ? Deno.env.delete(key) : Deno.env.set(key, previous[index]!)); }
});
Deno.test("optional music and speech metadata survive planning without exposing private audio or transcript contents", () => {
  const input = editPlanInput({ ...body, draft: { ...draft, hasMusic: true, hasSpeech: true } });
  assertEquals(input.draft.hasMusic, true); assertEquals(input.draft.hasSpeech, true);
  assertEquals(editPlanOutput(output([{ type: "duration", seconds: 8 }]), input, null).status, "plan");
  assertThrows(() => editPlanInput({ ...body, draft: { ...draft, hasSpeech: "true" } }), HttpError);
  assertThrows(() => editPlanInput({ ...body, draft: { ...draft, speech: [{ words: [] }] } }), HttpError);
});
Deno.test("planner honors cancellation before dispatch and passes request signal to the single paid call", async () => {
  const early = new AbortController(); early.abort(); const first = setup();
  await assertRejects(() => handleEditPlan(new Request(request(), { signal: early.signal }), first.context, first.deps));
  assert(!first.calls.includes("generate")); assert(!first.calls.includes("reserve"));
  const controller = new AbortController();
  const second = setup({ generate: async (_step, _system, _turn, signal) => { assert(signal); controller.abort(); signal.throwIfAborted(); return ""; } });
  await assertRejects(() => handleEditPlan(new Request(request(), { signal: controller.signal }), second.context, second.deps));
  assert(second.calls.includes("record:uncertain"));
});
