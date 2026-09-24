import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { editPlanInput, EDIT_PLAN_LIMITS } from "./edit-plan.ts";
import { promptEnhancementInput } from "./prompt-enhancement.ts";

// Execute the real browser helper. Its imports are type-only and checked by the
// app's tsc pass; a runtime URL keeps Deno from imposing extension rules on that
// separately compiled browser module graph.
const { buildEditPlanRequest } = await import(new URL("../../../../apps/studio/src/features/sync/edit-plan-request.ts", import.meta.url).href);

const draft = { schema: 1, id: "contract-draft", revision: 7, ratio: "9:16", audio: "original", title: "Tour", clips: [{
  id: "clip-1", source: { name: "private-address-original.png", kind: "image", sha256: "a".repeat(64), size: 1024, width: 1000, height: 1000, lastModified: 123456, duration: 0 },
  start: 0, end: 5, caption: "", focusX: .5, focusY: .5,
}] };
function history(text: string, count = 8) { return Array.from({ length: count }, (_, index) => ({ id: String(index), role: index % 2 ? "assistant" : "user", text, revision: null })); }

Deno.test("actual browser request builder and backend agree on long current prompts and capped history", () => {
  const message = "x".repeat(2000);
  const request = buildEditPlanRequest(draft, message, history(message, 10), "10000000-0000-4000-8000-000000000001");
  const input = editPlanInput(request);
  assertEquals(input.message, message);
  assertEquals(input.history.length, 8);
  assert(input.history.every(turn => turn.content.length === 1200));
  assertEquals(input.draft.id, draft.id); assertEquals(input.draft.revision, draft.revision);
});

Deno.test("actual browser request builder removes private source metadata and stays within byte cap for Unicode history", () => {
  const request = buildEditPlanRequest(draft, "🔥".repeat(1000), history("房".repeat(2000)));
  const encoded = JSON.stringify(request);
  assert(new TextEncoder().encode(encoded).byteLength <= EDIT_PLAN_LIMITS.requestBytes);
  const input = editPlanInput(request); assert(input.history.length < 8);
  assertEquals(input.message, "🔥".repeat(1000));
  for (const privateValue of [draft.clips[0].source.name, draft.clips[0].source.sha256, "lastModified", "focusX", "source", "size"]) assert(!encoded.includes(privateValue), privateValue);
  assertEquals(Object.keys(input.draft.clips[0]), ["id", "kind", "start", "end", "speed", "caption", "motion", "transition"]);
});

Deno.test("actual browser request builder also satisfies enhancement contract before media with full brief", () => {
  const message = "x".repeat(2000);
  const request = buildEditPlanRequest({ ...draft, clips: [] }, message, history("房".repeat(2000)));
  const input = promptEnhancementInput(request);
  assertEquals(input.draft?.clips, []); assertEquals(input.message, message);
  assert(input.history.length <= 8 && input.history.every(turn => turn.content.length <= 1200));
  assert(new TextEncoder().encode(JSON.stringify(request)).byteLength <= EDIT_PLAN_LIMITS.requestBytes);
});
