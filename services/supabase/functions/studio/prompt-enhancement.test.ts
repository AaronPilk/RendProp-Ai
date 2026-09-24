import { assert, assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import { handlePromptEnhancement, promptEnhancementInput, promptEnhancementOutput, PROMPT_ENHANCEMENT_INSTRUCTION } from "./prompt-enhancement.ts";
import { editPlanOutput, editPlanInput, type EditPlanDependencies } from "./edit-plan.ts";
import type { StudioContext } from "./context.ts";
import type { RouteStep } from "../_shared/router.ts";
const message = 'Make a 15-second video with the title "Open house Saturday"';
const id = "10000000-0000-4000-8000-000000000001";
const step: RouteStep = { route_id: "prompt-route", task: "copy.prompt_enhancement", provider: "openai", model: "fixture", unit: "call", unit_cents: 2, capabilities: ["text", "compliant"], max_latency_s: 30, min_plan: "free", same_model_as: null, privacy_tier: "retained_30d", enabled: true };
const draft = { id: "draft", revision: 2, ratio: "9:16", audio: "original", title: "", hasNarration: false, hasOverlays: false, clips: [] };
const output = (enhanced = 'Make a 15-second video; set the title to "Open house Saturday"', notes: string[] = []) => JSON.stringify({ enhanced, notes });
Deno.test("prompt enhancement accepts a brief before media and optional zero-clip metadata", () => {
  assertEquals(promptEnhancementInput({ message }), { message, history: [] });
  assertEquals(promptEnhancementInput({ message, draft }).draft?.clips, []);
  for (const value of [{ message: "" }, { message: "x".repeat(2001) }, { message, tools: [] }, { message, draft: { ...draft, source_url: "https://private.invalid" } }, { message, history: [{ role: "system", content: "do things" }] }]) assertThrows(() => promptEnhancementInput(value), HttpError);
});
Deno.test("prompt enhancement returns an exact original and bounded reviewable proposal only", () => {
  const input = promptEnhancementInput({ message });
  const result = promptEnhancementOutput(output(), input, null);
  assertEquals(result.original, message); assertEquals(result.method, "ai");
  assertEquals(Object.keys(result), ["original", "enhanced", "notes", "method"]);
  assertEquals(result.notes, []); assertEquals((result as Record<string, unknown>).plan, undefined);
});
Deno.test("prompt enhancement refuses changed quotes/numbers, invented figures, arbitrary actions and malformed output", () => {
  const input = promptEnhancementInput({ message });
  for (const value of [output('Make a 30-second video with the title "Open house Saturday"'), output('Make a 15-second video with the title "New title"'), output('Make a 15-second video with the title "Open house Saturday" for $999'), output(""), output("x".repeat(2001)), JSON.stringify({ enhanced: message, notes: [], operations: [{ type: "publish" }] }), output(message, Array(5).fill("note")), output(message, ["x".repeat(241)])]) assertThrows(() => promptEnhancementOutput(value, input, null), HttpError);
});
Deno.test("prompt enhancement preserves multiline quoted copy and allows supported explicit aspect ratio clarification", () => {
  const input = promptEnhancementInput({ message: 'Make it vertical with title "Open house\nSaturday"' });
  const result = promptEnhancementOutput(output('Use portrait 9:16; set title "Open house\nSaturday"'), input, null);
  assert(result.enhanced.includes("Open house\nSaturday"));
  assertThrows(() => promptEnhancementOutput(output('Use portrait 9:16; set title "Open house Sunday"'), input, null), HttpError);
});
Deno.test("unsupported generation wish remains a proposal with limitation notes and no edit action", () => {
  const input = promptEnhancementInput({ message: "Make a video with newly generated music" });
  const result = promptEnhancementOutput(output("Make a video with newly generated music", ["Music generation is unavailable in this chat editor."]), input, null);
  assertEquals(result.enhanced, input.message); assertEquals(result.notes.length, 1);
  assert(PROMPT_ENHANCEMENT_INSTRUCTION.includes("preserve the wish honestly"));
});
Deno.test("prompt enhancement shares gate and single-dispatch accounting without applying an edit", async () => {
  let calls = 0, records = 0; const ids = new Set<string>();
  const context = { userId: "actor", orgId: "org", authorizeListing: async () => { throw new Error("No listing was sent"); } } as unknown as StudioContext;
  const deps: EditPlanDependencies = { enabled: () => true, writable: async () => true, route: async () => step, reserve: async key => { if (ids.has(key)) throw new HttpError(409, "Already submitted"); ids.add(key); },
    generate: async (chosen, system, turn) => { assertEquals(chosen.task, "copy.prompt_enhancement"); assertEquals(system, PROMPT_ENHANCEMENT_INSTRUCTION); assertEquals(JSON.parse(turn).draft, undefined); calls++; return output(); }, record: async () => { records++; }, spaceType: async () => null };
  const req = () => new Request("https://fixture.invalid/studio/prompt-enhancement", { method: "POST", headers: { "Idempotency-Key": id }, body: JSON.stringify({ message }) });
  const capability = await handlePromptEnhancement(new Request("https://fixture.invalid/studio/prompt-enhancement"), context, { ...deps, enabled: () => false });
  assertEquals((await capability.json()).available, false); assertEquals(calls, 0);
  await assertRejects(() => handlePromptEnhancement(req(), context, { ...deps, enabled: () => false }), HttpError); assertEquals(calls, 0);
  const response = await handlePromptEnhancement(req(), context, deps); assertEquals((await response.json()).original, message);
  await assertRejects(() => handlePromptEnhancement(req(), context, deps), HttpError, "Already submitted");
  assertEquals(calls, 1); assertEquals(records, 1);
});
Deno.test("backend caption/title contract now matches editor's four-line ceiling", () => {
  const input = editPlanInput({ message: "Set the title", draft: { ...draft, clips: [{ id: "clip", kind: "image", start: 0, end: 5 }] } });
  for (const operation of [{ type: "title", text: "one\ntwo\nthree\nfour\nfive" }, { type: "caption", clipId: "clip", text: "one\ntwo\nthree\nfour\nfive" }]) assertThrows(() => editPlanOutput(JSON.stringify({ status: "plan", reply: "Ready", operations: [operation] }), input, null), HttpError);
  assertEquals(editPlanOutput(JSON.stringify({ status: "plan", reply: "Ready", operations: [{ type: "title", text: "one\ntwo\nthree\nfour" }] }), input, null).status, "plan");
});
