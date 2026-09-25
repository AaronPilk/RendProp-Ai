import test from "node:test";
import assert from "node:assert/strict";
import type { StudioServices } from "../src/data";
import type { EditClip } from "../src/editor/model";
import { buildProjectAnalysisRequest, requestProjectAnalysis } from "../src/features/projects/project-analysis-request";

const id = "11111111-1111-4111-8111-111111111111", hash = "a".repeat(64);
const clip: EditClip = { id: "clip", source: { kind: "video", name: "private-room.mp4", sha256: hash, size: 1000, duration: 10, width: 1280, height: 720, lastModified: 1 }, start: 0, end: 10, caption: "", focusX: .5, focusY: .5 };
const media = { id, sha256: hash, bytes: 1000, mime: "video/mp4", complete: true };
test("project captions require an explicit saved account project and bounded video without automatic upload", async () => {
  let calls = 0; const services = { api: async () => { calls++; } } as unknown as StudioServices;
  await assert.rejects(() => requestProjectAnalysis(services, "org", clip, false, new AbortController().signal), /Save this project to your account first/);
  await assert.rejects(() => requestProjectAnalysis(services, "org", { ...clip, source: { ...clip.source, size: 24_000_001 } }, true, new AbortController().signal), /24 MB/);
  assert.equal(calls, 0);
});
test("project analysis refuses incomplete, mismatched, unsupported and unavailable originals before dispatch", () => {
  assert.deepEqual(buildProjectAnalysisRequest(clip, { media }), { source_id: id, source_kind: "project_media" });
  for (const patch of [{ id: "bad" }, { sha256: "b".repeat(64) }, { bytes: 1001 }, { complete: false }, { mime: "video/webm" }]) assert.throws(() => buildProjectAnalysisRequest(clip, { media: { ...media, ...patch } }));
  assert.throws(() => buildProjectAnalysisRequest(clip, { media: null }));
});
test("project caption request resolves own cloud ID and sends a single strict source identity without retries", async () => {
  const calls: { path: string; options: Record<string, unknown> }[] = [];
  const services = { api: async (path: string, options: Record<string, unknown>) => {
    calls.push({ path, options });
    if (options.method === "POST") throw new Error("Uncertain result");
    return path.includes("project-media") ? { media } : { available: true };
  } } as unknown as StudioServices;
  await assert.rejects(() => requestProjectAnalysis(services, "org", clip, true, new AbortController().signal), /Uncertain result/);
  assert.equal(calls.length, 3); assert.equal(calls[1].path, `/functions/v1/studio/project-media?sha256=${hash}`);
  assert.deepEqual(calls[2].options.body, { source_id: id, source_kind: "project_media" });
  assert.match(calls[2].options.idempotencyKey as string, /^[a-f0-9-]{36}$/);
  assert.equal(JSON.stringify(calls[2]).includes("listing"), false); assert.equal(JSON.stringify(calls[2]).includes(clip.source.name), false);
});
test("disabled captions and cancellation never submit a saved project to the provider", async () => {
  let calls = 0; const disabled = { api: async () => { calls++; return { available: false }; } } as unknown as StudioServices;
  await assert.rejects(() => requestProjectAnalysis(disabled, "org", clip, true, new AbortController().signal), /SRT or WebVTT/); assert.equal(calls, 1);
  const cancel = new AbortController(); calls = 0;
  const services = { api: async (path: string) => { calls++; if (path.includes("project-media")) { cancel.abort(); return { media }; } return { available: true }; } } as unknown as StudioServices;
  await assert.rejects(() => requestProjectAnalysis(services, "org", clip, true, cancel.signal)); assert.equal(calls, 2);
});
