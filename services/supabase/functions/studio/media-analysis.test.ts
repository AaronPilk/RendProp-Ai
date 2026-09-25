import { assert, assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import type { RouteStep } from "../_shared/router.ts";
import type { StudioContext } from "./context.ts";
import { analysisOutput, handleMediaAnalysis, mediaAnalysisInput, speechHighlights, speechSegments, validatedWords, type AnalysisSource, type MediaAnalysisDependencies } from "./media-analysis.ts";
import { analysisMovieDuration, mediaAnalysisProduction, readAnalysisBytes, transcribeAnalysis, resolveAnalysisProject, loadAnalysisProject, sameAnalysisProject } from "./media-analysis-production.ts";
import type { ProjectMediaRow } from "./project-media.ts";

const listing = "10000000-0000-4000-8000-000000000001", sourceId = "10000000-0000-4000-8000-000000000002", requestId = "10000000-0000-4000-8000-000000000003";
const input = { listing_id: listing, source_id: sourceId, source_kind: "asset" as const };
const source: AnalysisSource = { ...input, key: `uploads/org/${listing}/video.mp4`, bucket: "uploads", duration: 10 };
const step: RouteStep = { route_id: "speech-route", task: "stt.captions", provider: "openai", model: "whisper-1", unit: "minute", unit_cents: .6, capabilities: ["stt", "word_timestamps"], max_latency_s: 90, min_plan: "free", same_model_as: null, privacy_tier: "retained_30d", enabled: true };
const words = [{ word: "See", start: 0, end: .4 }, { word: "the", start: .4, end: .6 }, { word: "large", start: .6, end: 1 }, { word: "kitchen.", start: 1, end: 2 }];
const provider = { duration: 10, words };
const hex = "a".repeat(64);
function fixture(change: Partial<MediaAnalysisDependencies> = {}) {
  const calls: string[] = [];
  const context = { authorizeListing: async (id: string) => { assertEquals(id, listing); calls.push("listing"); } } as StudioContext;
  const deps: MediaAnalysisDependencies = {
    enabled: () => true, writable: async () => { calls.push("role"); return true; }, route: async () => { calls.push("route"); return step; },
    resolve: async value => { assertEquals(value, input); calls.push("resolve"); return source; }, authorize: async () => { calls.push("source"); },
    load: async () => { calls.push("load"); return { bytes: new Uint8Array([1, 2, 3]), duration: 10 }; }, reserve: async () => { calls.push("reserve"); },
    transcribe: async () => { calls.push("transcribe"); return provider; }, record: async (_step, seconds, outcome) => { calls.push(`record:${seconds}:${outcome}`); }, ...change,
  };
  return { context, deps, calls };
}
function request(payload: unknown = input, signal?: AbortSignal) { return new Request("https://fixture.invalid/studio/media-analysis", { method: "POST", headers: { "Idempotency-Key": requestId }, body: JSON.stringify(payload), signal }); }

Deno.test("analysis accepts only canonical source IDs, never client URLs, arbitrary transcript or storage keys", () => {
  assertEquals(mediaAnalysisInput(input), input);
  for (const patch of [{ url: "https://private.invalid/file" }, { key: source.key }, { words }, { source_id: "not-a-uuid" }, { source_kind: "photo" }, { listing_id: "../other" }]) assertThrows(() => mediaAnalysisInput({ ...input, ...patch }), HttpError);
});
Deno.test("analysis word timing is source bounded and atomic, never sorted, clamped or fabricated", () => {
  assertEquals(validatedWords(words, 10)[3], { text: "kitchen.", start: 1, end: 2 });
  for (const bad of [words.toReversed(), [...words, { word: "overlap", start: 1.9, end: 3 }], [{ word: "oops", start: 0, end: 11 }], [{ word: "bad\ntext", start: 0, end: 1 }], [{ word: "zero", start: 1, end: 1 }], [{ word: "x".repeat(81), start: 1, end: 2 }], Array(1501).fill(words[0])]) assertThrows(() => validatedWords(bad, 10), HttpError);
});
Deno.test("speech segments and highlight suggestions contain only actual source word ranges", () => {
  const clean = validatedWords([...words, { word: "Welcome", start: 4, end: 4.5 }, { word: "inside!", start: 4.5, end: 5 }], 10);
  const segments = speechSegments(clean);
  assertEquals(segments, [{ id: "speech-1", start: 0, end: 2, text: "See the large kitchen." }, { id: "speech-2", start: 4, end: 5, text: "Welcome inside!" }]);
  const [highlight] = speechHighlights(segments); assertEquals(highlight.segmentIds, ["speech-1"]); assertEquals([highlight.start, highlight.end], [0, 2]);
  assert(highlight.reason.includes("See the large kitchen.")); assert(highlight.reason.includes("Review the picture"));
  assertEquals(speechHighlights([]), []);
});
Deno.test("transcript response requires fingerprint, matching duration, and explicit review; silence is no change", () => {
  const output = analysisOutput(provider, source, hex, 10);
  assertEquals(output.sourceFingerprint, hex); assertEquals(output.reviewRequired, true); assertEquals(output.method, "speech");
  assert(!JSON.stringify(output).includes(source.key)); assertEquals(output.words.length, 4);
  assertEquals(analysisOutput({ duration: 10, words: [] }, source, hex, 10).words, []);
  for (const raw of [{ duration: 99, words }, { duration: "10", words }, { duration: 10, words: null }]) assertThrows(() => analysisOutput(raw, source, hex, 10), HttpError);
  assertThrows(() => analysisOutput(provider, source, "false-fingerprint", 10), HttpError);
});
Deno.test("disabled, read-only and unconfigured analysis perform zero media fetches, reservations or provider calls", async () => {
  for (const [change, reason] of [[{ enabled: () => false }, "disabled"], [{ writable: async () => false }, "read_only"], [{ route: async () => null }, "unconfigured"]] as const) {
    const f = fixture(change); const result = await handleMediaAnalysis(new Request("https://fixture.invalid/studio/media-analysis"), f.context, f.deps);
    assertEquals((await result.json()).reason, reason);
    await assertRejects(() => handleMediaAnalysis(request(), f.context, f.deps), HttpError);
    assert(!f.calls.includes("load")); assert(!f.calls.includes("reserve")); assert(!f.calls.includes("transcribe"));
  }
});
Deno.test("analysis verifies source before and after dispatch and fingerprints exact downloaded bytes", async () => {
  const f = fixture(); const response = await handleMediaAnalysis(request(), f.context, f.deps), result = await response.json();
  assertEquals(response.headers.get("cache-control"), "private, no-store");
  assertEquals(result.sourceFingerprint, "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81");
  assertEquals(f.calls, ["role", "route", "listing", "resolve", "source", "reserve", "load", "listing", "source", "role", "route", "transcribe", "listing", "source", "role", "record:10:returned"]);
});
Deno.test("revoked source, wrong binding, changed route and oversized source all fail before paid dispatch", async () => {
  for (const change of [
    { authorize: async () => { throw new HttpError(404, "Revoked"); } },
    { resolve: async () => ({ ...source, source_id: requestId }) },
    { load: async () => ({ bytes: new Uint8Array(24_000_001), duration: 10 }) },
    { route: (() => { let count = 0; return async () => ++count === 1 ? step : { ...step, unit_cents: 2 }; })() },
  ]) { const f = fixture(change); await assertRejects(() => handleMediaAnalysis(request(), f.context, f.deps), HttpError); assert(!f.calls.includes("transcribe")); assert(!f.calls.some(c => c.startsWith("record:"))); }
});
Deno.test("post-provider revocation discards transcript and records the single paid attempt", async () => {
  let n = 0; const f = fixture({ authorize: async () => { if (++n === 3) throw new HttpError(404, "Revoked"); } });
  await assertRejects(() => handleMediaAnalysis(request(), f.context, f.deps), HttpError, "Revoked");
  assertEquals(f.calls.filter(c => c.startsWith("record:")), ["record:10:returned"]);
});
Deno.test("uncertain provider outcome is recorded once and duplicate ID never dispatches twice", async () => {
  const ids = new Set<string>(); let calls = 0;
  const f = fixture({ reserve: async id => { if (ids.has(id)) throw new HttpError(409, "Already submitted"); ids.add(id); }, transcribe: async () => { calls++; throw new HttpError(502, "Unknown provider outcome"); } });
  await assertRejects(() => handleMediaAnalysis(request(), f.context, f.deps), HttpError);
  await assertRejects(() => handleMediaAnalysis(request(), f.context, f.deps), HttpError, "Already submitted");
  assertEquals(calls, 1); assertEquals(f.calls.filter(c => c.startsWith("record:")), ["record:10:uncertain"]);
});
Deno.test("cancellation before dispatch spends nothing; cancellation during provider attempt retains uncertain charge", async () => {
  const early = new AbortController(); early.abort(); const f = fixture();
  await assertRejects(() => handleMediaAnalysis(request(input, early.signal), f.context, f.deps));
  assert(!f.calls.includes("load")); assert(!f.calls.includes("transcribe"));
  const during = new AbortController(); const g = fixture({ transcribe: async (_s, _b, signal) => { during.abort(); signal.throwIfAborted(); return provider; } });
  await assertRejects(() => handleMediaAnalysis(request(input, during.signal), g.context, g.deps));
  assertEquals(g.calls.filter(c => c.startsWith("record:")), ["record:10:uncertain"]);
});

function bytesJoin(...parts: Uint8Array[]): Uint8Array { const all = new Uint8Array(parts.reduce((sum, p) => sum + p.length, 0)); let off = 0; for (const p of parts) { all.set(p, off); off += p.length; } return all; }
function box(tag: string, body: Uint8Array = new Uint8Array()) { const b = new Uint8Array(8 + body.length); new DataView(b.buffer).setUint32(0, b.length); b.set(new TextEncoder().encode(tag), 4); b.set(body, 8); return b; }
function movie(seconds = 10, audio = true, fragmented = false, version = 0, audioSeconds = seconds, samplesSeconds = audioSeconds, external = false) {
  const header = new Uint8Array(version === 1 ? 32 : 20), h = new DataView(header.buffer); header[0] = version;
  const scale = version === 1 ? 20 : 12; h.setUint32(scale, 1000); if (version === 1) h.setBigUint64(scale + 4, BigInt(seconds * 1000)); else h.setUint32(scale + 4, seconds * 1000);
  const handler = new Uint8Array(12); handler.set(new TextEncoder().encode(audio ? "soun" : "vide"), 8);
  const mediaHeader = header.slice(), m = new DataView(mediaHeader.buffer);
  if (version === 1) m.setBigUint64(scale + 4, BigInt(audioSeconds * 1000)); else m.setUint32(scale + 4, audioSeconds * 1000);
  const stts = new Uint8Array(16), st = new DataView(stts.buffer); st.setUint32(4, 1); st.setUint32(8, samplesSeconds * 1000); st.setUint32(12, 1);
  const reference = new Uint8Array(4); new DataView(reference.buffer).setUint32(0, external ? 0 : 1);
  const dref = new Uint8Array(8); new DataView(dref.buffer).setUint32(4, 1);
  const mediaInfo = box("minf", bytesJoin(box("dinf", box("dref", bytesJoin(dref, box("url ", reference)))), box("stbl", box("stts", stts))));
  const track = box("trak", box("mdia", bytesJoin(box("mdhd", mediaHeader), box("hdlr", handler), mediaInfo)));
  return bytesJoin(box("ftyp", new TextEncoder().encode("isom0000")), box("mdat", new Uint8Array([1])), box("moov", bytesJoin(box("mvhd", header), track, ...(fragmented ? [box("mvex")] : []))));
}
Deno.test("movie parser reads both duration header versions and refuses silent, fragmented, oversized-duration or corrupt inputs", () => {
  assertEquals(analysisMovieDuration(movie()), 10); assertEquals(analysisMovieDuration(movie(20, true, false, 1)), 20);
  for (const invalid of [movie(301), movie(10, false), movie(10, true, true), movie().subarray(0, 30), new Uint8Array(100), movie(10, true, false, 2)]) assertThrows(() => analysisMovieDuration(invalid), HttpError);
});
Deno.test("movie duration cannot hide longer audio samples or external audio references", () => {
  for (const invalid of [movie(10, true, false, 0, 300), movie(10, true, false, 0, 10, 301), movie(10, true, false, 0, 10, 20), movie(10, true, false, 0, 10, 10, true)]) assertThrows(() => analysisMovieDuration(invalid), HttpError);
  assertEquals(analysisMovieDuration(movie(10, true, false, 0, 10.05, 10.05)), 10);
});
Deno.test("bounded streaming reader refuses dishonest or missing Content-Length without unbounded accumulation", async () => {
  assertEquals(await readAnalysisBytes(new Response("abc"), 3, "Too large"), new TextEncoder().encode("abc"));
  for (const response of [new Response("x", { headers: { "content-length": "4" } }), new Response("abcd", { headers: { "content-length": "1" } }), new Response("abcd")]) await assertRejects(() => readAnalysisBytes(response, 3, "Too large"), HttpError);
});
Deno.test("transcription uses fixed endpoint and bounded multipart contract without user prompt or signed URL", async () => {
  const before = Deno.env.get("OPENAI_API_KEY"); Deno.env.set("OPENAI_API_KEY", "synthetic");
  try {
    let calls = 0;
    const fetcher = (async (url: unknown, init: RequestInit) => {
      calls++; assertEquals(url, "https://api.openai.com/v1/audio/transcriptions"); assertEquals(init.redirect, "error");
      const form = init.body as FormData; assertEquals([...form.keys()], ["file", "model", "response_format", "timestamp_granularities[]"]);
      assertEquals(form.get("model"), "whisper-1"); assertEquals(form.get("response_format"), "verbose_json"); assertEquals(form.get("timestamp_granularities[]"), "word");
      assertEquals((form.get("file") as File).name, "source.mp4"); return new Response(JSON.stringify(provider));
    }) as typeof fetch;
    assertEquals(await transcribeAnalysis(step, movie(), new AbortController().signal, fetcher), provider); assertEquals(calls, 1);
    let failures = 0; await assertRejects(() => transcribeAnalysis(step, movie(), new AbortController().signal, (async () => { failures++; return new Response("no", { status: 429 }); }) as typeof fetch), HttpError); assertEquals(failures, 1);
  } finally { before === undefined ? Deno.env.delete("OPENAI_API_KEY") : Deno.env.set("OPENAI_API_KEY", before); }
});
Deno.test("production speech gate requires explicit flag and a finite capped price allowance", () => {
  const keys = ["STUDIO_MEDIA_ANALYSIS_ENABLED", "STUDIO_MEDIA_ANALYSIS_MAX_ESTIMATED_CENTS"], previous = keys.map(k => Deno.env.get(k));
  try {
    const deps = mediaAnalysisProduction({} as StudioContext); Deno.env.set(keys[0], "true");
    for (const value of ["0", "NaN", "Infinity", "-1", "11"]) { Deno.env.set(keys[1], value); assertEquals(deps.enabled(), false); }
    Deno.env.set(keys[1], "3"); assertEquals(deps.enabled(), true); Deno.env.set(keys[0], "false"); assertEquals(deps.enabled(), false);
  } finally { keys.forEach((key, i) => previous[i] === undefined ? Deno.env.delete(key) : Deno.env.set(key, previous[i]!)); }
});

const projectInput = { source_id: sourceId, source_kind: "project_media" as const };
async function projectOriginal(bytes = movie()): Promise<ProjectMediaRow> {
  const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource))].map(b => b.toString(16).padStart(2, "0")).join("");
  return { id: sourceId, actor_id: "actor", org_id: "org", sha256: hash, bytes: bytes.length, mime: "video/mp4", filename: "private original.mp4", modified: 1, parts: 1, write_deadline: "2020-01-01T00:00:00Z", receipts: { "0": { sha256: hash, bytes: bytes.length, state: "complete" } } };
}
Deno.test("project speech input is a strict disjoint union, without a fake property or client URLs", () => {
  assertEquals(mediaAnalysisInput(projectInput), projectInput);
  for (const extra of [{ listing_id: listing }, { listing_id: null }, { url: "https://example.invalid/video" }, { sha256: hex }, { actor_id: "another" }, { source_id: "bad" }]) assertThrows(() => mediaAnalysisInput({ ...projectInput, ...extra }), HttpError);
});
Deno.test("project speech source reads exact actor/org ownership and rejects foreign same-hash, incomplete or revoked media", async () => {
  const original = await projectOriginal(); let row: unknown = original, error: unknown = null;
  const context = { userId: "actor", orgId: "org", admin: { rpc: async (name: string, args: unknown) => {
    assertEquals(name, "studio_project_media_write"); assertEquals(args, { p_actor: "actor", p_org: "org", p_id: sourceId, p_action: "read", p_data: {} }); return { data: row, error };
  } } } as unknown as StudioContext;
  assertEquals(await resolveAnalysisProject(context, sourceId), original);
  for (const invalid of [null, { ...original, actor_id: "foreign" }, { ...original, org_id: "other" }, { ...original, id: requestId }, { ...original, bytes: 24_000_001 }, { ...original, mime: "audio/mpeg" }, { ...original, receipts: {} }]) { row = invalid; await assertRejects(() => resolveAnalysisProject(context, sourceId), HttpError); }
  row = original; error = { message: "RP403: Workspace cannot access media" };
  await assertRejects(() => resolveAnalysisProject(context, sourceId), HttpError, "unavailable to your account");
  assert(sameAnalysisProject(original, structuredClone(original)));
  for (const patch of [{ sha256: hex }, { actor_id: "foreign" }, { mime: "video/quicktime" }, { receipts: { "0": { ...original.receipts["0"], sha256: hex } } }]) assertEquals(sameAnalysisProject(original, { ...original, ...patch }), false);
});
Deno.test("project speech assembles only server-owned keys and verifies exact chunk plus full-source bytes before dispatch", async () => {
  const bytes = movie(), original = await projectOriginal(bytes), keys: string[] = [];
  const io = { sign: async (_bucket: string, key: string, expires: number) => { keys.push(key); assertEquals(expires, 120); return "https://fixture.invalid/signed"; }, fetcher: (async (url: unknown, options: RequestInit) => { assertEquals(url, "https://fixture.invalid/signed"); assertEquals(options.redirect, "error"); return new Response(bytes as BodyInit); }) as typeof fetch };
  assertEquals(await loadAnalysisProject(original, new AbortController().signal, io), bytes);
  assertEquals(keys, [`studio-project/org/actor/${sourceId}/0`]);
  await assertRejects(() => loadAnalysisProject({ ...original, sha256: hex }, new AbortController().signal, io), HttpError, "original failed its integrity");
  await assertRejects(() => loadAnalysisProject({ ...original, receipts: { "0": { ...original.receipts["0"], sha256: hex } } }, new AbortController().signal, io), HttpError, "part failed its integrity");
  for (const length of [bytes.length - 1, bytes.length + 1]) await assertRejects(() => loadAnalysisProject(original, new AbortController().signal, { ...io, fetcher: (async () => new Response(new Uint8Array(length))) as typeof fetch }), HttpError);
  const cancel = new AbortController(); cancel.abort(); const n = keys.length;
  await assertRejects(() => loadAnalysisProject(original, cancel.signal, io)); assertEquals(keys.length, n);
});
Deno.test("private project transcription never invents listing authorization and rechecks access around the one provider call", async () => {
  const bytes = movie(), original = await projectOriginal(bytes), projectSource: AnalysisSource = { ...projectInput, media: original, duration: 0 };
  const make = () => fixture({ resolve: async value => { assertEquals(value, projectInput); return projectSource; }, load: async () => ({ bytes, duration: analysisMovieDuration(bytes) }) });
  const f = make(), result = await (await handleMediaAnalysis(request(projectInput), f.context, f.deps)).json();
  assertEquals(result.sourceKind, "project_media"); assertEquals(result.sourceFingerprint, original.sha256);
  assertEquals(f.calls.filter(c => c === "listing"), []); assertEquals(f.calls.filter(c => c === "source").length, 3); assertEquals(f.calls.filter(c => c === "transcribe").length, 1);
  const wrong = make(); wrong.deps.resolve = async () => ({ ...projectSource, media: { ...original, sha256: hex } });
  await assertRejects(() => handleMediaAnalysis(request(projectInput), wrong.context, wrong.deps), HttpError, "integrity"); assert(!wrong.calls.includes("transcribe"));
  const revoked = make(); let checks = 0; revoked.deps.authorize = async () => { if (++checks === 3) throw new HttpError(403, "Membership revoked"); };
  await assertRejects(() => handleMediaAnalysis(request(projectInput), revoked.context, revoked.deps), HttpError, "Membership revoked"); assertEquals(revoked.calls.filter(c => c.startsWith("record:")), ["record:10:returned"]);
  const cancelled = make(), abort = new AbortController(); cancelled.deps.load = async () => { abort.abort(); return { bytes, duration: 10 }; };
  await assertRejects(() => handleMediaAnalysis(request(projectInput, abort.signal), cancelled.context, cancelled.deps)); assert(!cancelled.calls.includes("transcribe"));
});
Deno.test("multi-part project analysis preserves chunk order and rejects a substituted later chunk", async () => {
  const bytes = new Uint8Array(8 * 1024 * 1024 + 3); bytes.fill(9); bytes.set([1, 2, 3], bytes.length - 3);
  const original = await projectOriginal(bytes), first = bytes.slice(0, -3), last = bytes.slice(-3);
  const hash = async (part: Uint8Array) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", part as BufferSource))].map(b => b.toString(16).padStart(2, "0")).join("");
  original.parts = 2; original.receipts = { "0": { sha256: await hash(first), bytes: first.length, state: "complete" }, "1": { sha256: await hash(last), bytes: last.length, state: "complete" } };
  const keys: string[] = []; let corrupt = false;
  const io = { sign: async (_bucket: string, key: string) => { keys.push(key); return `https://fixture.invalid/${key}`; }, fetcher: (async (url: unknown) => new Response(String(url).endsWith("/0") ? first : corrupt ? new Uint8Array([3, 2, 1]) : last)) as typeof fetch };
  assertEquals(await loadAnalysisProject(original, new AbortController().signal, io), bytes);
  assertEquals(keys.map(k => k.slice(-1)), ["0", "1"]); corrupt = true;
  await assertRejects(() => loadAnalysisProject(original, new AbortController().signal, io), HttpError, "integrity");
});
Deno.test("actual named-project browser source request matches strict backend input and excludes media metadata", async () => {
  const { buildProjectAnalysisRequest } = await import(new URL("../../../../apps/studio/src/features/projects/project-analysis-request.ts", import.meta.url).href);
  const original = await projectOriginal(), clip = { source: { kind: "video", sha256: original.sha256, size: original.bytes, duration: 10 } };
  const sent = buildProjectAnalysisRequest(clip, { media: { ...original, complete: true } });
  assertEquals(mediaAnalysisInput(sent), projectInput); assertEquals(Object.keys(sent).sort(), ["source_id", "source_kind"]);
});
