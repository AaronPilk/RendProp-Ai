// deno test --allow-env --allow-read --allow-net _shared/providers/kie_property_profile_test.ts
//
// The Kie property-video profile (kie-kling3-4k-steady-v1) and the createTask /
// recordInfo money boundary, OFFLINE: fetch is stubbed (any host but the stubbed
// api.kie.ai throws) and the key is a synthetic fixture string, so nothing here
// has reached Kie. Every oracle runs against the real adapter AND against
// compiled defects — copies of kie.ts with one unique anchor mutated, loaded from
// a data: URL — and must fail on each defect for the reason it names, so no
// assertion below is vacuous.

import { assert, assertEquals, assertMatch, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import * as realKie from "./kie.ts";
import { ProviderError, snippet } from "./common.ts";
import { asHttpError } from "./chain.ts";
import { HttpError } from "../http.ts";
import { KIE_PROPERTY_PROFILE, KIE_PROPERTY_ROUTE_ID } from "../property-video-kie.ts";
import { submitReservedVideo, VideoDispatchUnconfirmed } from "../../ai-video/cost-reservation.ts";
import { buildSteadyPropertyReelPrompt } from "../../ai-video/reel-framing.ts";
import type { RouteStep } from "../router.ts";
import type { ErrorClass, GenerateInput, JobRef, JobState } from "./types.ts";

type KieModule = typeof import("./kie.ts");
type Oracle = (kie: KieModule) => Promise<void>;
type Control = [needle: string, replacement: string, reason: RegExp];

// ── Compiled defects ─────────────────────────────────────────────────────────

const KIE_MODULE = new URL("./kie.ts", import.meta.url);
const KIE_SOURCE = await Deno.readTextFile(KIE_MODULE);

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

/** kie.ts with exactly one unique anchor replaced; relative imports made absolute. */
async function defect(needle: string, replacement: string): Promise<KieModule> {
  assertEquals(KIE_SOURCE.split(needle).length, 2, `Defect anchor must occur exactly once in kie.ts: ${needle}`);
  const source = KIE_SOURCE.replace(needle, () => replacement)
    .replace(/from "(\.\.?\/[^"]+)"/g, (_all, path: string) => `from ${JSON.stringify(new URL(path, KIE_MODULE).href)}`);
  return await import(`data:application/typescript;base64,${base64(new TextEncoder().encode(source))}`);
}

/** The oracle passes on the real adapter, then fails on every defect, for its reason. */
async function proves(name: string, oracle: Oracle, controls: Control[]): Promise<void> {
  await oracle(realKie);
  for (const [needle, replacement, reason] of controls) {
    const broken = await defect(needle, replacement);
    const error = await assertRejects(() => oracle(broken), Error, undefined, `${name}: defect not detected (${needle})`);
    assertMatch(error.message, reason, `${name}: defect detected for an unrelated reason (${needle})`);
  }
  console.log(`KIE_PROPERTY_COMPILED_CONTROLS[${name}]=${controls.length}`);
}

// ── Offline transport ────────────────────────────────────────────────────────

interface Wire { url: string; method: string; authorization: string | null; contentType: string | null; body: string | null }
type Responder = (call: Wire) => Response | Promise<Response>;

const FIXTURE_KEY = "offline-fixture-key-not-a-credential";
const CREATE_TASK = "https://api.kie.ai/api/v1/jobs/createTask";
const RECORD_INFO = "https://api.kie.ai/api/v1/jobs/recordInfo";
const VEO_GENERATE = "https://api.kie.ai/api/v1/veo/generate";
const VEO_RECORD = "https://api.kie.ai/api/v1/veo/record-info";
const NO_HTTP: Responder = () => {
  throw new Error("No HTTP request is permitted here");
};

/** Run `work` with fetch stubbed and KIE_API_KEY set to a fixture (or unset when null). */
async function offline<T>(respond: Responder, work: (calls: Wire[]) => Promise<T>, key: string | null = FIXTURE_KEY): Promise<T> {
  const previousFetch = globalThis.fetch, previousKey = Deno.env.get("KIE_API_KEY");
  const calls: Wire[] = [];
  if (key === null) Deno.env.delete("KIE_API_KEY");
  else Deno.env.set("KIE_API_KEY", key);
  globalThis.fetch = (async (resource: string | URL | Request, init?: RequestInit) => {
    const url = resource instanceof Request ? resource.url : String(resource);
    const headers = new Headers(init?.headers);
    calls.push({
      url, method: init?.method ?? "GET", authorization: headers.get("authorization"),
      contentType: headers.get("content-type"), body: typeof init?.body === "string" ? init.body : null,
    });
    if (new URL(url).hostname !== "api.kie.ai") throw new Error("Only the stubbed Kie host may be addressed");
    return await respond(calls[calls.length - 1]);
  }) as typeof fetch;
  try {
    return await work(calls);
  } finally {
    globalThis.fetch = previousFetch;
    if (previousKey === undefined) Deno.env.delete("KIE_API_KEY");
    else Deno.env.set("KIE_API_KEY", previousKey);
  }
}

function kieJson(body: unknown, status = 200): Response {
  return new Response(typeof body === "string" ? body : JSON.stringify(body), {
    status, headers: { "content-type": "application/json" },
  });
}
const acceptedWith = (taskId: string): Responder => () => kieJson({ code: 200, msg: "success", data: { taskId } });

// ── Fixtures ─────────────────────────────────────────────────────────────────

/** Shaped like the 7200 s presigned GET of an owned source; never fetched here. */
const SOURCE = "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/rendprop-uploads/uploads/org/listing/photo%20one.jpg" +
  "?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=fixture%2F20261016%2Fauto%2Fs3%2Faws4_request" +
  "&X-Amz-Date=20261016T120000Z&X-Amz-Expires=7200&X-Amz-SignedHeaders=host&X-Amz-Signature=" + "0".repeat(64);
// The property path sends only the exact reviewed steady prompt the frozen
// identity pins (kie_property_guards_test.ts covers every motion, noun and canvas).
const PROMPT = buildSteadyPropertyReelPrompt("home", "push_in", "16:9");

const propertyStep: RouteStep = {
  route_id: KIE_PROPERTY_ROUTE_ID, task: "video.reel_clip", provider: "kie", model: "kling-3.0/video",
  unit: "second", unit_cents: 33.5, capabilities: ["i2v", "1080p", "5s", "native4k", "preserve_photo"],
  max_latency_s: 1800, min_plan: "free", same_model_as: "kling_3_pro", privacy_tier: "trains_by_default", enabled: true,
};

function propertyInput(aspect: "16:9" | "9:16" = "16:9", change: Partial<GenerateInput> = {}, extra: Record<string, unknown> = {}): GenerateInput {
  return {
    task: "video.reel_clip", prompt: PROMPT, image_url: SOURCE, seconds: 5, resolution: "1080p", aspect,
    framing: "preserve_photo", ...change,
    extra: {
      kie_mode: "4K", sound: false, property_video_target_aspect: aspect,
      property_video_quality_profile: KIE_PROPERTY_PROFILE, ...extra,
    },
  };
}

/** Independent literal oracle for the property wire (not derived from the identity). */
function propertyWire(prompt = PROMPT, source = SOURCE): string {
  return `{"model":"kling-3.0/video","input":{"prompt":${JSON.stringify(prompt)},"image_urls":[${JSON.stringify(source)}],` +
    `"sound":false,"duration":"5","mode":"4K","multi_shots":false}}`;
}

// Existing owner-QA / Seedance / Veo fixtures, as in ai-video/reel-framing.test.ts
// and ai-video/kie-qa-price-payload.test.ts.
const ownerStep: RouteStep = {
  route_id: "closed-owner-kling", task: "video.reel_clip", provider: "kie", model: "kling-3.0/video", unit: "second",
  unit_cents: 9, capabilities: ["i2v", "1080p", "5s"], max_latency_s: 900, min_plan: "free", same_model_as: "kling_3_pro",
  privacy_tier: "trains_by_default", enabled: true,
};
const OWNER_PROMPT = "Exact full photo. Physical shallow camera track, fixed lens.";
const OWNER_SOURCE = "https://owned-fixture.invalid/full-photo.jpg";
const ownerInput = (aspect: "16:9" | "9:16", extra: Record<string, unknown>): GenerateInput => ({
  task: "video.reel_clip", prompt: OWNER_PROMPT, image_url: OWNER_SOURCE, seconds: 5, resolution: "1080p", aspect,
  framing: "preserve_photo", extra,
});
const ownerWire = (mode: "pro" | "4K", aspectRatio?: "16:9" | "9:16") =>
  `{"model":"kling-3.0/video","input":{"prompt":${JSON.stringify(OWNER_PROMPT)},"image_urls":[${JSON.stringify(OWNER_SOURCE)}],` +
  `"sound":false,"duration":"5","mode":"${mode}","multi_shots":false${aspectRatio ? `,"aspect_ratio":"${aspectRatio}"` : ""}}}`;
const seedanceStep: RouteStep = {
  route_id: "owner-qa-fixture", task: "video.reel_clip", provider: "kie", model: "bytedance/v1-pro-fast-image-to-video",
  unit: "second", unit_cents: 3.6, capabilities: ["i2v", "1080p", "5s"], max_latency_s: 900, min_plan: "free",
  same_model_as: "seedance_v1_pro_fast", privacy_tier: "trains_by_default", enabled: true,
};
const seedanceInput: GenerateInput = {
  task: "video.reel_clip", prompt: "Guarded fixture camera movement.",
  image_url: "https://owned-fixture.invalid/byte-exact-source.jpg", seconds: 5, resolution: "1080p", aspect: "9:16",
};
const veoStep: RouteStep = { ...seedanceStep, route_id: "legacy-veo-fixture", model: "veo3_fast", unit: "call" };
const veoInput: GenerateInput = {
  task: "video.aerial", prompt: "Legacy aerial fixture.", image_url: "https://owned-fixture.invalid/aerial.jpg",
  seconds: 8, aspect: "16:9", resolution: "1080p",
};

const RESULT = "https://tempfile.aiquickdraw.com/k/property-4k-fixture.mp4";
const pollRef = (id: string): JobRef => ({
  provider: "kie", model: "kling-3.0/video", id, poll_url: `${RECORD_INFO}?taskId=${encodeURIComponent(id)}`,
  submitted_at: "2026-10-16T12:00:00.000Z",
});
const veoRef = (id: string): JobRef => ({
  provider: "kie", model: "veo3_fast", id, poll_url: `${VEO_RECORD}?taskId=${encodeURIComponent(id)}`,
  submitted_at: "2026-10-16T12:00:00.000Z",
});

/** A market recordInfo `success` record; `echo` is Kie's copy of our input. */
function successRecord(taskId: string, fields: Record<string, unknown> = {}, echo: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    taskId, model: "kling-3.0/video", state: "success",
    param: JSON.stringify({
      model: "kling-3.0/video",
      input: { prompt: "echo", image_urls: ["https://echo.invalid/x.jpg"], sound: false, duration: "5", mode: "4K", multi_shots: false, ...echo },
    }),
    resultJson: JSON.stringify({ resultUrls: [RESULT] }), creditsConsumed: 335, costTime: 61000, ...fields,
  };
}
const successWith = (taskId: string, fields: Record<string, unknown> = {}, echo: Record<string, unknown> = {}): Responder => () =>
  kieJson({ code: 200, msg: "success", data: successRecord(taskId, fields, echo) });

function doneMeta(state: JobState, tag: string): Record<string, unknown> {
  assertEquals(state.status, "done", `${tag}: expected a result`);
  return state.status === "done" ? state.meta ?? {} : {};
}

// ── 1. The exact property wire ───────────────────────────────────────────────

const propertyWireOracle: Oracle = async (kie) => {
  const bodies: string[] = [];
  for (const aspect of ["16:9", "9:16"] as const) {
    const taskId = `kie-property-${aspect.replace(":", "x")}`;
    await offline(acceptedWith(taskId), async (calls) => {
      const job = await kie.kieAdapter.submit(propertyStep, propertyInput(aspect));
      assertEquals(calls.map((c) => [c.url, c.method, c.authorization, c.contentType]),
        [[CREATE_TASK, "POST", `Bearer ${FIXTURE_KEY}`, "application/json"]], `PROPERTY_WIRE ${aspect}: one authenticated POST`);
      const body = calls[0].body ?? "";
      assertEquals(body, propertyWire(), `PROPERTY_WIRE ${aspect}: exact bytes`);
      const parsed = JSON.parse(body);
      assertEquals(Object.keys(parsed), ["model", "input"], `PROPERTY_WIRE ${aspect}: top-level key set`);
      assertEquals(Object.keys(parsed.input), ["prompt", "image_urls", "sound", "duration", "mode", "multi_shots"],
        `PROPERTY_WIRE ${aspect}: input key set`);
      assertEquals([parsed.input.image_urls, parsed.input.sound, parsed.input.duration, parsed.input.mode, parsed.input.multi_shots],
        [[SOURCE], false, "5", "4K", false], `PROPERTY_WIRE ${aspect}: values, source byte-identical`);
      for (const absent of ["aspect_ratio", "callBackUrl", "kling_elements", "negative_prompt", "resolution", "nsfw_checker"]) {
        assert(!body.includes(absent), `PROPERTY_WIRE ${aspect}: ${absent} is never sent`);
      }
      assertEquals(job, {
        provider: "kie", model: "kling-3.0/video", id: taskId, poll_url: `${RECORD_INFO}?taskId=${taskId}`,
        submitted_at: job.submitted_at,
      }, `PROPERTY_WIRE ${aspect}: receipt`);
      assert(!Number.isNaN(Date.parse(job.submitted_at)), `PROPERTY_WIRE ${aspect}: submitted_at`);
      bodies.push(body);
    });
  }
  assertEquals(bodies[0], bodies[1], "PROPERTY_WIRE: the server canvas never reaches the wire");
  // The closed builder's length bound is unchanged (2500 accepted, 2501 refused
  // below); an arbitrary 2500-character text is still never SENT, because only
  // the pinned reviewed prompt passes submit, before the key or any request.
  const longest = "p".repeat(2500);
  assertEquals(JSON.stringify(kie.kiePropertyRequest(propertyStep, propertyInput("9:16", { prompt: longest }))), propertyWire(longest),
    "PROPERTY_WIRE: a 2500-character prompt is built unchanged");
  await offline(acceptedWith("kie-property-longest-prompt"), async (calls) => {
    const error = await assertRejects(() => kie.kieAdapter.submit(propertyStep, propertyInput("9:16", { prompt: longest })), ProviderError);
    assertEquals([error.error_class, error.status, error.dispatch_rejected, calls.length], ["validation", 400, true, 0],
      "PROPERTY_WIRE: an unpinned prompt is a definite refusal with zero HTTP");
  });
  assertEquals(JSON.stringify(kie.kiePropertyRequest(propertyStep, propertyInput("16:9"))), propertyWire(),
    "PROPERTY_WIRE: the exported builder is the same closed request");
};

Deno.test("property profile sends the exact closed Kie 4K wire for 16:9 and 9:16, with no aspect_ratio", async () => {
  await proves("property wire", propertyWireOracle, [
    ["multi_shots: KIE_PROPERTY_IDENTITY.multi_shots,", "multi_shots: KIE_PROPERTY_IDENTITY.multi_shots, aspect_ratio: input.aspect,", /PROPERTY_WIRE/],
    ["mode: KIE_PROPERTY_MODE,", 'mode: "pro",', /PROPERTY_WIRE/],
    ["body: JSON.stringify(request) }", 'body: JSON.stringify({ ...request, callBackUrl: "https://callback.invalid/kie" }) }', /PROPERTY_WIRE/],
  ]);
});

// ── 2. Owner QA, Seedance and Veo wires stay byte-identical ──────────────────

const UNCHANGED: [string, RouteStep, GenerateInput, string, string][] = [
  ["Kling Pro 9:16", ownerStep, ownerInput("9:16", { kie_mode: "pro", sound: false }), CREATE_TASK, ownerWire("pro")],
  ["Kling Pro 16:9", ownerStep, ownerInput("16:9", { kie_mode: "pro", sound: false }), CREATE_TASK, ownerWire("pro")],
  ["Kling 4K owner QA", { ...ownerStep, unit_cents: 33.5 }, ownerInput("9:16", { kie_mode: "4K", sound: false }), CREATE_TASK, ownerWire("4K")],
  ["Kling Pro server canvas", ownerStep, ownerInput("16:9", { kie_mode: "pro", sound: false, property_video_target_aspect: "16:9" }),
    CREATE_TASK, ownerWire("pro", "16:9")],
  // A FAL profile value riding on an owner-QA Kie request is not the Kie profile.
  ["Kling 4K server canvas with a FAL profile", { ...ownerStep, unit_cents: 33.5 },
    ownerInput("9:16", { kie_mode: "4K", sound: false, property_video_target_aspect: "9:16", property_video_quality_profile: "fal-kling3-4k-steady-v2" }),
    CREATE_TASK, ownerWire("4K", "9:16")],
  ["Seedance owner QA", seedanceStep, seedanceInput, CREATE_TASK,
    `{"model":"bytedance/v1-pro-fast-image-to-video","input":{"prompt":"Guarded fixture camera movement.",` +
    `"image_url":"https://owned-fixture.invalid/byte-exact-source.jpg","resolution":"1080p","duration":"5","nsfw_checker":true}}`],
  ["legacy Veo", veoStep, veoInput, VEO_GENERATE,
    `{"prompt":"Legacy aerial fixture.","imageUrls":["https://owned-fixture.invalid/aerial.jpg"],"model":"veo3_fast",` +
    `"aspect_ratio":"16:9","duration":8,"resolution":"1080p"}`],
];

const unchangedWiresOracle: Oracle = async (kie) => {
  for (const [label, step, input, url, wire] of UNCHANGED) {
    const taskId = `unchanged-${label.replace(/[^a-z0-9]+/gi, "-")}`;
    await offline(acceptedWith(taskId), async (calls) => {
      const job = await kie.kieAdapter.submit(step, input);
      assertEquals(calls.map((c) => [c.url, c.method, c.body]), [[url, "POST", wire]], `OWNER_QA_WIRE ${label}: byte-identical`);
      assertEquals([job.id, job.model, job.poll_url], [taskId, step.model, `${url === VEO_GENERATE ? VEO_RECORD : RECORD_INFO}?taskId=${taskId}`],
        `OWNER_QA_WIRE ${label}: receipt`);
    });
  }
};

Deno.test("owner-QA Kling Pro/4K, Seedance and legacy Veo wires are byte-identical; only the exact profile selects the new wire", async () => {
  await proves("unchanged wires", unchangedWiresOracle, [
    ["if (input.extra?.property_video_quality_profile === KIE_PROPERTY_PROFILE) {", "if (step.model === KIE_PROPERTY_MODEL) {", /refused before dispatch/],
    ["jobInput.nsfw_checker = true;", "jobInput.nsfw_checker = false;", /OWNER_QA_WIRE/],
    ["jobInput.aspect_ratio=input.extra.property_video_target_aspect;", "", /OWNER_QA_WIRE/],
  ]);
});

// ── 3. Every refusal happens before the key is read or any HTTP ─────────────

const REFUSALS: [string, RouteStep, GenerateInput][] = [
  ["provider fal", { ...propertyStep, provider: "fal" }, propertyInput()],
  ["FAL 4K route", { ...propertyStep, provider: "fal", model: "fal-ai/kling-video/v3/4k/image-to-video" }, propertyInput()],
  ["model Kling 2.6", { ...propertyStep, model: "kling-2.6/video" }, propertyInput()],
  ["model Seedance", { ...propertyStep, model: "bytedance/v1-pro-fast-image-to-video" }, propertyInput()],
  ["task", propertyStep, propertyInput("16:9", { task: "video.aerial" })],
  ["framing missing", propertyStep, propertyInput("16:9", { framing: undefined })],
  ["seconds 6", propertyStep, propertyInput("16:9", { seconds: 6 })],
  ["seconds 4.6 (would round to 5)", propertyStep, propertyInput("16:9", { seconds: 4.6 })],
  ["seconds 10", propertyStep, propertyInput("9:16", { seconds: 10 })],
  ["seconds missing", propertyStep, propertyInput("16:9", { seconds: undefined })],
  ["resolution 720p", propertyStep, propertyInput("16:9", { resolution: "720p" })],
  ["resolution 4k", propertyStep, propertyInput("16:9", { resolution: "4k" })],
  ["resolution missing", propertyStep, propertyInput("16:9", { resolution: undefined })],
  ["mode pro", propertyStep, propertyInput("16:9", {}, { kie_mode: "pro" })],
  ["mode 4k lowercase", propertyStep, propertyInput("16:9", {}, { kie_mode: "4k" })],
  ["mode std", propertyStep, propertyInput("16:9", {}, { kie_mode: "std" })],
  ["mode missing", propertyStep, propertyInput("16:9", {}, { kie_mode: undefined })],
  ["sound true", propertyStep, propertyInput("16:9", {}, { sound: true })],
  ["sound as a string", propertyStep, propertyInput("16:9", {}, { sound: "false" })],
  ["sound missing", propertyStep, propertyInput("16:9", {}, { sound: undefined })],
  ["aspect 1:1", propertyStep, propertyInput("16:9", { aspect: "1:1" }, { property_video_target_aspect: "1:1" })],
  ["aspect missing", propertyStep, propertyInput("16:9", { aspect: undefined })],
  ["target canvas mismatch", propertyStep, propertyInput("16:9", {}, { property_video_target_aspect: "9:16" })],
  ["target canvas missing", propertyStep, propertyInput("9:16", {}, { property_video_target_aspect: undefined })],
  ["data URL source", propertyStep, propertyInput("16:9", { image_url: "data:image/jpeg;base64,c291cmNl" })],
  ["http source", propertyStep, propertyInput("16:9", { image_url: "http://owned.invalid/photo.jpg" })],
  ["uppercase scheme", propertyStep, propertyInput("16:9", { image_url: "HTTPS://owned.invalid/photo.jpg" })],
  ["leading whitespace", propertyStep, propertyInput("16:9", { image_url: " " + SOURCE })],
  ["trailing whitespace", propertyStep, propertyInput("16:9", { image_url: SOURCE + " " })],
  ["userinfo in source", propertyStep, propertyInput("16:9", { image_url: "https://user:secret@owned.invalid/photo.jpg" })],
  ["non-ASCII source", propertyStep, propertyInput("16:9", { image_url: "https://owned.invalid/phöto.jpg" })],
  ["javascript source", propertyStep, propertyInput("16:9", { image_url: "javascript:alert(1)" })],
  ["empty source", propertyStep, propertyInput("16:9", { image_url: "" })],
  ["missing source", propertyStep, propertyInput("16:9", { image_url: undefined })],
  ["inline base64 beside an https source", propertyStep, propertyInput("16:9", { image_b64: "c291cmNl" })],
  ["inline base64 only", propertyStep, propertyInput("16:9", { image_url: undefined, image_b64: "c291cmNl" })],
  ["missing prompt", propertyStep, propertyInput("16:9", { prompt: undefined })],
  ["empty prompt", propertyStep, propertyInput("16:9", { prompt: "" })],
  ["blank prompt", propertyStep, propertyInput("16:9", { prompt: " \n\t " })],
  ["2501-character prompt", propertyStep, propertyInput("16:9", { prompt: "p".repeat(2501) })],
  ["non-string prompt", propertyStep, propertyInput("16:9", { prompt: 123 as unknown as string })],
];

const refusalOracle: Oracle = async (kie) => {
  await offline(NO_HTTP, async (calls) => {
    for (const [label, step, input] of REFUSALS) {
      const error = await assertRejects(() => kie.kieAdapter.submit(step, input), ProviderError, undefined, `REFUSAL ${label}: must be refused`);
      assertEquals([error.error_class, error.status, error.dispatch_rejected, error.provider], ["validation", 400, true, "kie"],
        `REFUSAL ${label}: definitive validation before any HTTP`);
      assertMatch(error.message, /^Kie property video refused before dispatch: /, `REFUSAL ${label}: refused by the profile, never by staging`);
      assert(!error.message.includes(SOURCE) && !error.message.includes(PROMPT), `REFUSAL ${label}: no input is echoed`);
      // The exported closed builder refuses the same input on its own (the
      // prompt pin in submit is an additional layer, not a replacement).
      const built = assertThrows(() => kie.kiePropertyRequest(step, input), ProviderError, undefined, `REFUSAL ${label}: the closed builder refuses it too`);
      assertEquals([built.error_class, built.status, built.dispatch_rejected], ["validation", 400, true], `REFUSAL ${label}: builder refusal is definitive`);
    }
    assertEquals(calls.length, 0, "REFUSAL: zero HTTP requests");
    const answer = asHttpError(await kie.kieAdapter.submit(propertyStep, propertyInput("16:9", {}, { sound: true })).catch((e) => e));
    assertEquals([answer.status, answer.details?.provider_status, answer.details?.dispatch_rejected, answer.details?.error_class],
      [400, 400, true, "validation"], "REFUSAL: the money path sees a releasable pre-dispatch refusal");
  }, null);
};

Deno.test("every property-profile violation is a definitive 400 validation refusal with zero HTTP and no key read", async () => {
  await proves("pre-HTTP refusals", refusalOracle, [
    ['if (input.image_b64 !== undefined || !ownedHttpsSource(source)) throw propertyRefusal("source image");',
      'if (typeof source !== "string") throw propertyRefusal("source image");', /REFUSAL/],
    ["input.image_b64 !== undefined || ", "", /REFUSAL/],
    [" || prompt.length > KIE_PROPERTY_PROMPT_MAX_CHARS", "", /REFUSAL/],
    [" || extra.property_video_target_aspect !== input.aspect", "", /REFUSAL/],
    ["const request = kiePropertyRequest(step, input);", "kieHeaders();\n      const request = kiePropertyRequest(step, input);", /REFUSAL/],
  ]);
});

// ── 4. Definite createTask refusals release the budget ───────────────────────

const DEFINITE: [number, ErrorClass][] = [
  [400, "validation"], [401, "upstream"], [402, "upstream"], [403, "upstream"], [404, "upstream"], [422, "validation"], [429, "rate_limit"],
];

const definiteOracle: Oracle = async (kie) => {
  const market: [string, RouteStep, GenerateInput][] = [
    ["property", propertyStep, propertyInput()],
    ["owner Kling", ownerStep, ownerInput("9:16", { kie_mode: "pro", sound: false })],
    ["owner Seedance", seedanceStep, seedanceInput],
  ];
  for (const [label, step, input] of market) {
    for (const [code, errorClass] of DEFINITE) {
      for (const httpStatus of [200, code]) {
        const tag = `DEFINITE ${label} ${code} (HTTP ${httpStatus})`;
        await offline(() => kieJson({ code, msg: `Fixture refusal ${code}`, data: null }, httpStatus), async (calls) => {
          const error = await assertRejects(() => kie.kieAdapter.submit(step, input), ProviderError, undefined, `${tag}: must reject`);
          assertEquals([error.status, error.dispatch_rejected, error.error_class], [code, true, errorClass], `${tag}: definite, vendor code kept`);
          assertEquals(calls.length, 1, `${tag}: one POST, never a second`);
          const answer = asHttpError(error);
          assertEquals([answer.details?.provider_status, answer.details?.dispatch_rejected], [code, true], `${tag}: release evidence`);
        });
      }
    }
  }
  await offline(() => kieJson({ code: 422, msg: "Image rejected by content policy" }), async () => {
    const error = await assertRejects(() => kie.kieAdapter.submit(propertyStep, propertyInput()), ProviderError);
    assertEquals([error.status, error.dispatch_rejected, error.error_class], [422, true, "nsfw"], "DEFINITE content-policy refusal is nsfw and definite");
  });
};

Deno.test("createTask codes 400/401/402/403/404/422/429 without a receipt are definite for every market model", async () => {
  await proves("definite refusals", definiteOracle, [
    ["new Set([400, 401, 402, 403, 404, 422, 429])", "new Set([400, 401, 403, 404, 422, 429])", /DEFINITE/],
    ['{ method: "POST", headers: kieHeaders(true), body: JSON.stringify(request) },\n        BUDGETS.submitMs,\n        true,',
      '{ method: "POST", headers: kieHeaders(true), body: JSON.stringify(request) },\n        BUDGETS.submitMs,\n        false,', /DEFINITE/],
    ["body: JSON.stringify({ model: step.model, input: jobInput }),\n        },\n        BUDGETS.submitMs,\n        true,",
      "body: JSON.stringify({ model: step.model, input: jobInput }),\n        },\n        BUDGETS.submitMs,\n        false,", /DEFINITE/],
  ]);
});

// ── 5. Everything else is ambiguous: hold retained, no second POST ──────────

const AMBIGUOUS: [string, Responder, number | undefined, ErrorClass][] = [
  ["code 455", () => kieJson({ code: 455, msg: "Service unavailable" }), 455, "upstream"],
  ["code 500", () => kieJson({ code: 500, msg: "Server error" }), 500, "upstream"],
  ["code 501", () => kieJson({ code: 501, msg: "Generation failed" }), 501, "upstream"],
  ["code 505", () => kieJson({ code: 505, msg: "Feature disabled" }), 505, "upstream"],
  ["code 405 (not a Kie refusal)", () => kieJson({ code: 405, msg: "Method not allowed" }), 405, "other"],
  ["HTTP 500 envelope", () => kieJson({ code: 500, msg: "Server error" }, 500), 500, "upstream"],
  ["HTTP 502", () => new Response("<html>bad gateway</html>", { status: 502 }), 502, "upstream"],
  ["HTTP 504 empty", () => new Response(null, { status: 504 }), 504, "upstream"],
  ["timeout", () => Promise.reject(new DOMException("Signal timed out.", "TimeoutError")), undefined, "timeout"],
  ["aborted", () => Promise.reject(new DOMException("The operation was aborted.", "AbortError")), undefined, "timeout"],
  ["network error", () => Promise.reject(new TypeError("error sending request: connection reset")), undefined, "upstream"],
  ["code 200 without taskId", () => kieJson({ code: 200, msg: "success", data: {} }), undefined, "upstream"],
  ["code 200 with empty taskId", () => kieJson({ code: 200, msg: "success", data: { taskId: "" } }), undefined, "upstream"],
  ["code 200 with blank taskId", () => kieJson({ code: 200, msg: "success", data: { taskId: "   " } }), undefined, "upstream"],
  ["code 200 with object taskId", () => kieJson({ code: 200, msg: "success", data: { taskId: {} } }), undefined, "upstream"],
  ["code 200 without data", () => kieJson({ code: 200, msg: "success", data: null }), undefined, "upstream"],
  ["truncated JSON", () => kieJson('{"code":200,"msg":"success","data":{"taskId":'), undefined, "upstream"],
  ["HTML on HTTP 200", () => new Response("<html>maintenance</html>", { status: 200 }), undefined, "upstream"],
  ["code 402 with a taskId receipt", () => kieJson({ code: 402, msg: "Insufficient credits", data: { taskId: "possibly-accepted" } }), 402, "upstream"],
  ["code 422 with a nested receipt", () => kieJson({ code: 422, msg: "Invalid", data: { record: { task_id: "possibly-accepted" } } }), 422, "validation"],
  ["HTTP 429 with a receipt", () => kieJson({ code: 429, msg: "Busy", data: { taskId: "possibly-accepted" } }, 429), 429, "rate_limit"],
];

const ambiguousOracle: Oracle = async (kie) => {
  for (const [label, respond, status, errorClass] of AMBIGUOUS) {
    const tag = `AMBIGUOUS ${label}`;
    await offline(respond, async (calls) => {
      const error = await assertRejects(() => kie.kieAdapter.submit(propertyStep, propertyInput("9:16")), ProviderError, undefined, `${tag}: must reject`);
      assertEquals([error.status, error.dispatch_rejected, error.error_class], [status, false, errorClass], `${tag}: ambiguous, hold retained`);
      assertEquals(calls.length, 1, `${tag}: exactly one POST`);
      assertEquals(asHttpError(error).details?.dispatch_rejected, false, `${tag}: no release evidence`);
    });
  }
  // Legacy Veo generate is outside the market-createTask contract: unchanged, conservative.
  await offline(() => kieJson({ code: 402, msg: "Insufficient credits" }), async (calls) => {
    const error = await assertRejects(() => kie.kieAdapter.submit(veoStep, veoInput), ProviderError);
    assertEquals([error.status, error.dispatch_rejected, calls.length], [402, false, 1], "AMBIGUOUS legacy Veo envelope stays unconfirmed");
  });
};

Deno.test("timeouts, network errors, 5xx, 455/500/501/505, missing receipts and malformed bodies stay ambiguous", async () => {
  await proves("ambiguous outcomes", ambiguousOracle, [
    ["const rejected = marketSubmit && KIE_DEFINITE_SUBMIT_CODES.has(code) && definitiveSubmitRejection(code, env);",
      "const rejected = marketSubmit;", /AMBIGUOUS/],
    ["KIE_DEFINITE_SUBMIT_CODES.has(code) && definitiveSubmitRejection(code, env)", "definitiveSubmitRejection(code, env)", /AMBIGUOUS/],
    ["KIE_DEFINITE_SUBMIT_CODES.has(code) && definitiveSubmitRejection(code, env)", "KIE_DEFINITE_SUBMIT_CODES.has(code)", /AMBIGUOUS/],
    ['return typeof value === "number" && Number.isFinite(value) ? String(value) : "";', 'return value == null ? "" : String(value);', /AMBIGUOUS/],
  ]);
});

// ── 6. The real money path: definite releases, ambiguous holds ───────────────

interface Booked { name: string; args: Record<string, unknown> }

async function reserveAndSubmit(kie: KieModule, input: GenerateInput, respond: Responder) {
  const booked: Booked[] = [];
  const rpc = (name: string, args: Record<string, unknown>) => {
    booked.push({ name, args });
    if (name === "org_has_internal_testing_grant" || name === "org_has_private_internal_testing") return Promise.resolve({ data: false, error: null });
    if (name === "app_video_cost_reserve_v2" || name === "serving_cost_reserve") return Promise.resolve({ data: { reserved: true }, error: null });
    if (name === "serving_cost_finish") return Promise.resolve({ data: { finished: true }, error: null });
    if (name === "app_video_cost_release_rejected") return Promise.resolve({ data: { released: true }, error: null });
    if (name === "app_video_cost_settle") return Promise.resolve({ data: { settled: true }, error: null });
    return Promise.resolve({ data: null, error: { message: `unexpected fixture rpc ${name}` } });
  };
  return await offline(respond, async (calls) => {
    let value: JobRef | undefined, error: unknown;
    try {
      value = (await submitReservedVideo({
        actorId: "fixture-actor", orgId: "fixture-org", key: "kie-property-money-fixture", feature: "reel",
        steps: [propertyStep], seconds: 5, input, listingId: "fixture-listing",
        allowance: { monthlyWindowStart: "2026-10-01T00:00:00Z", burstWindowStart: "2026-10-16T12:00:00Z" },
      }, {
        rpc,
        // Production submits through runChain; a chain of one surfaces asHttpError(err).
        submit: async (selected: RouteStep) => {
          try {
            return { step: selected, value: await kie.kieAdapter.submit(selected, input), latency_ms: 1 };
          } catch (caught) {
            throw asHttpError(caught);
          }
        },
      })).value;
    } catch (caught) {
      error = caught;
    }
    return { value, error, posts: calls.filter((c) => c.url === CREATE_TASK).length, booked };
  });
}

const moneyOracle: Oracle = async (kie) => {
  const finished = (b: Booked[]) => b.filter((c) => c.name === "serving_cost_finish").map((c) => [c.args.p_state, c.args.p_rejection_status]);
  const released = (b: Booked[]) => b.filter((c) => c.name === "app_video_cost_release_rejected").map((c) => [c.args.p_provider_status, c.args.p_error_class]);
  const holds = (b: Booked[]) => b.filter((c) => c.name.includes("reserve")).map((c) => [c.name, c.args.p_hold_cents]);

  const ok = await reserveAndSubmit(kie, propertyInput("9:16"), acceptedWith("kie-property-money-task"));
  assertEquals([ok.error, ok.value?.id, ok.posts], [undefined, "kie-property-money-task", 1], "MONEY accepted: one POST, receipt returned");
  assertEquals(holds(ok.booked), [["app_video_cost_reserve_v2", 167.5], ["serving_cost_reserve", 167.5]], "MONEY accepted: 167.5c in both authorities");
  assertEquals(finished(ok.booked), [["succeeded", null]], "MONEY accepted: serving hold succeeded");
  assertEquals([ok.booked.at(-1)?.name, ok.booked.at(-1)?.args.p_provider_request_id], ["app_video_cost_settle", "kie-property-money-task"],
    "MONEY accepted: settled on the Kie receipt");

  const definite: [string, GenerateInput, Responder, number, number, ErrorClass][] = [
    ["envelope 402", propertyInput(), () => kieJson({ code: 402, msg: "Insufficient credits" }), 1, 402, "upstream"],
    ["HTTP 401", propertyInput(), () => kieJson({ code: 401, msg: "Unauthorized" }, 401), 1, 401, "upstream"],
    ["pre-HTTP refusal", propertyInput("16:9", { image_url: "data:image/jpeg;base64,c291cmNl" }), NO_HTTP, 0, 400, "validation"],
  ];
  for (const [label, input, respond, posts, status, errorClass] of definite) {
    const r = await reserveAndSubmit(kie, input, respond);
    assert(r.error instanceof HttpError && !(r.error instanceof VideoDispatchUnconfirmed), `MONEY ${label}: reported as a refusal`);
    assertEquals(r.posts, posts, `MONEY ${label}: POST count`);
    assertEquals(finished(r.booked), [["rejected", status]], `MONEY ${label}: serving hold rejected with the vendor code`);
    assertEquals(released(r.booked), [[status, errorClass]], `MONEY ${label}: app hold released`);
  }

  const ambiguous: [string, Responder][] = [
    ["envelope 500", () => kieJson({ code: 500, msg: "Server error" })],
    ["envelope 455", () => kieJson({ code: 455, msg: "Service unavailable" })],
    ["HTTP 502", () => new Response("bad gateway", { status: 502 })],
    ["timeout", () => Promise.reject(new DOMException("Signal timed out.", "TimeoutError"))],
    ["code 200 without taskId", () => kieJson({ code: 200, msg: "success", data: {} })],
    ["code 402 with a receipt", () => kieJson({ code: 402, msg: "Insufficient credits", data: { taskId: "possibly-accepted" } })],
  ];
  for (const [label, respond] of ambiguous) {
    const r = await reserveAndSubmit(kie, propertyInput(), respond);
    assert(r.error instanceof VideoDispatchUnconfirmed, `MONEY ${label}: unconfirmed, hold retained`);
    assertEquals(r.posts, 1, `MONEY ${label}: exactly one POST`);
    assertEquals(finished(r.booked), [["uncertain", null]], `MONEY ${label}: serving hold uncertain`);
    assertEquals(released(r.booked), [], `MONEY ${label}: nothing released`);
  }
};

Deno.test("through the real reservation path a definite Kie refusal releases both holds and an ambiguous one retains them", async () => {
  await proves("money path", moneyOracle, [
    ['if (!taskId) throw new ProviderError(PROVIDER, "upstream", "Kie accepted the job but returned no taskId");',
      'if (!taskId) throw new ProviderError(PROVIDER, "upstream", "Kie accepted the job but returned no taskId", 400, true);', /MONEY/],
    ["KIE_DEFINITE_SUBMIT_CODES.has(code) && definitiveSubmitRejection(code, env)", "KIE_DEFINITE_SUBMIT_CODES.has(code)", /MONEY/],
    ["new Set([400, 401, 402, 403, 404, 422, 429])", "new Set([400, 401, 403, 404, 422, 429])", /MONEY/],
  ]);
});

// ── 7. A poll is never a dispatch rejection ──────────────────────────────────

const pollErrorOracle: Oracle = async (kie) => {
  for (const [kind, ref] of [["market", pollRef("poll-error-market")], ["veo", veoRef("poll-error-veo")]] as const) {
    for (const code of [400, 401, 402, 403, 404, 422, 429, 455, 500]) {
      for (const httpStatus of [200, code]) {
        const tag = `POLL ${kind} ${code} (HTTP ${httpStatus})`;
        await offline(() => kieJson({ code, msg: `Fixture ${code}`, data: null }, httpStatus), async (calls) => {
          const error = await assertRejects(() => kie.kieAdapter.poll(ref), ProviderError, undefined, `${tag}: must reject`);
          assertEquals([error.status, error.dispatch_rejected], [code, false], `${tag}: never a dispatch rejection`);
          assertEquals(calls.map((c) => [c.method, c.url]), [["GET", ref.poll_url]], `${tag}: one GET`);
        });
      }
    }
  }
};

Deno.test("recordInfo and Veo record-info errors are never dispatch rejections, whatever the code", async () => {
  await proves("poll errors", pollErrorOracle, [
    ["const rejected = marketSubmit && ", "const rejected = ", /POLL/],
  ]);
});

// ── 8. Poll success records credits_consumed and kie_state ───────────────────

const INFINITE = "__infinite_credits__";
const creditsOracle: Oracle = async (kie) => {
  await offline(acceptedWith("credits-warm"), () => kie.kieAdapter.submit(propertyStep, propertyInput("9:16")));
  await offline(successWith("credits-warm"), async (calls) => {
    const state = await kie.kieAdapter.poll(pollRef("credits-warm"));
    assertEquals(state, {
      status: "done", result_url: RESULT, mime: "video/mp4",
      meta: { task_id: "credits-warm", expires_in_days: 14, kie_state: "success", credits_consumed: 335 },
    }, "CREDITS warm property task: exact meta");
    assertEquals(calls.map((c) => c.method), ["GET"], "CREDITS: one GET, nothing downloaded");
  });
  const cases: [string, unknown, number | undefined][] = [
    ["integer", 335, 335], ["zero", 0, 0], ["fraction", 167.5, 167.5], ["string", "335", undefined], ["negative", -1, undefined],
    ["null", null, undefined], ["boolean", true, undefined], ["infinite", INFINITE, undefined], ["missing", undefined, undefined],
  ];
  for (const [label, credits, expected] of cases) {
    const id = `credits-${label}`;
    const raw = JSON.stringify({ code: 200, msg: "success", data: successRecord(id, { creditsConsumed: credits }) })
      .replace(`"${INFINITE}"`, "1e999");
    await offline(() => kieJson(raw), async () => {
      const meta = doneMeta(await kie.kieAdapter.poll(pollRef(id)), `CREDITS ${label}`);
      assertEquals([meta.kie_state, "credits_consumed" in meta, meta.credits_consumed], ["success", expected !== undefined, expected],
        `CREDITS ${label}: only a finite number >= 0 is recorded`);
    });
  }
  // Legacy Veo polling is unchanged: no new meta.
  await offline(() => kieJson({ code: 200, msg: "success", data: { taskId: "veo-meta", successFlag: 1, response: { resultUrls: [RESULT] }, creditsConsumed: 80 } }), async () => {
    assertEquals(await kie.kieAdapter.poll(veoRef("veo-meta")), {
      status: "done", result_url: RESULT, mime: "video/mp4", meta: { task_id: "veo-meta", expires_in_days: 14, echo_unverified: true },
    }, "CREDITS legacy Veo meta is unchanged");
  });
};

Deno.test("market poll success records numeric credits_consumed and kie_state; Veo meta is unchanged", async () => {
  await proves("credits and state", creditsOracle, [
    ['typeof credits === "number" && Number.isFinite(credits) && credits >= 0', "credits !== undefined", /CREDITS/],
    ["kie_state: state,", "", /CREDITS/],
  ]);
});

// ── 9. Never trust the echo; a cold start claims nothing ─────────────────────

const echoOracle: Oracle = async (kie) => {
  // Cold: this isolate never submitted the task, and the echo disagrees.
  await offline(successWith("echo-cold", { resultJson: JSON.stringify({ resultUrls: [RESULT], duration: "10", resolution: "720p" }) }, { duration: "10" }), async () => {
    const meta = doneMeta(await kie.kieAdapter.poll(pollRef("echo-cold")), "ECHO cold");
    assertEquals(meta.echo_unverified, true, "ECHO cold start is echo_unverified");
    assert(!("substituted" in meta) && !("requested" in meta) && !("returned" in meta), "ECHO cold start never claims a substitution");
  });
  // Warm, matching echo: verified, nothing claimed.
  await offline(acceptedWith("echo-warm"), () => kie.kieAdapter.submit(propertyStep, propertyInput()));
  await offline(successWith("echo-warm"), async () => {
    const meta = doneMeta(await kie.kieAdapter.poll(pollRef("echo-warm")), "ECHO warm");
    assert(!("echo_unverified" in meta) && !("substituted" in meta), "ECHO warm matching echo claims nothing");
  });
  // Warm, downgraded echo: the existing substitution meta is kept. The property
  // path records the tier it actually requests (mode 4K), not "1080p".
  await offline(acceptedWith("echo-downgraded"), () => kie.kieAdapter.submit(propertyStep, propertyInput()));
  await offline(successWith("echo-downgraded", {}, { duration: "10" }), async () => {
    const meta = doneMeta(await kie.kieAdapter.poll(pollRef("echo-downgraded")), "ECHO downgraded");
    assertEquals([meta.substituted, meta.requested, meta.returned, "echo_unverified" in meta],
      [true, { duration: "5", resolution: "4K" }, { duration: "10", resolution: undefined }, false], "ECHO warm downgrade is flagged");
  });
};

Deno.test("a cold-start poll is echo_unverified and never claims substitution; warm polls keep the substitution meta", async () => {
  await proves("echo", echoOracle, [
    ["if (!want) return { substituted: false };", 'if (!want) want = { duration: "5", resolution: "1080p" };', /ECHO/],
    ["...(want ? {} : { echo_unverified: true }),", "", /ECHO/],
  ]);
});

// ── 10. A success whose first result is not https is a failure ───────────────

const NON_HTTPS: [string, string][] = [
  ["http", JSON.stringify({ resultUrls: ["http://tempfile.aiquickdraw.com/k/a.mp4"] })],
  ["http first, https second", JSON.stringify({ resultUrls: ["http://tempfile.aiquickdraw.com/k/a.mp4", RESULT] })],
  ["data:", JSON.stringify({ resultUrls: ["data:video/mp4;base64,AAAAIGZ0eXBpc29t"] })],
  ["file:", JSON.stringify({ resultUrls: ["file:///etc/passwd"] })],
  ["ftp:", JSON.stringify({ resultUrls: ["ftp://files.invalid/a.mp4"] })],
  ["protocol-relative", JSON.stringify({ resultUrls: ["//tempfile.aiquickdraw.com/k/a.mp4"] })],
  ["javascript:", JSON.stringify({ resultUrls: ["javascript:alert(1)"] })],
  ["empty string", JSON.stringify({ resultUrls: [""] })],
  ["bare http string", "http://tempfile.aiquickdraw.com/k/a.mp4"],
  ["single resultUrl key", JSON.stringify({ resultUrl: "http://tempfile.aiquickdraw.com/k/a.mp4" })],
];

const nonHttpsOracle: Oracle = async (kie) => {
  for (const [label, resultJson] of NON_HTTPS) {
    const id = `non-https-${label.replace(/[^a-z0-9]+/gi, "-")}`;
    await offline(successWith(id, { resultJson }), async (calls) => {
      assertEquals(await kie.kieAdapter.poll(pollRef(id)),
        { status: "failed", error_class: "upstream", message: "Kie reported success with a non-https result URL" },
        `NON_HTTPS ${label}: refused`);
      assertEquals(calls.map((c) => [c.method, new URL(c.url).hostname]), [["GET", "api.kie.ai"]], `NON_HTTPS ${label}: nothing downloaded`);
    });
  }
  await offline(successWith("non-https-none", { resultJson: JSON.stringify({ resultUrls: [] }) }), async () => {
    assertEquals(await kie.kieAdapter.poll(pollRef("non-https-none")),
      { status: "failed", error_class: "upstream", message: "Kie reported success with no result URL" }, "NON_HTTPS: no URL is still a failure");
  });
  await offline(successWith("https-ok"), async () => {
    const state = await kie.kieAdapter.poll(pollRef("https-ok"));
    assertEquals(state.status === "done" ? state.result_url : state.status, RESULT, "NON_HTTPS: an https first result is delivered");
  });
};

Deno.test("a market success whose first result URL is not https fails upstream and is never downloaded", async () => {
  await proves("non-https result", nonHttpsOracle, [
    ["if (urls.length > 0 && !isHttpsUrl(urls[0])) {", "if (false) {", /NON_HTTPS/],
    ['return new URL(value).protocol === "https:";', "return /^https?:$/.test(new URL(value).protocol);", /NON_HTTPS/],
  ]);
});

// ── 11. Fail-state classification ────────────────────────────────────────────

const FAILS: [string, Record<string, unknown>, ErrorClass][] = [
  ["nsfw text with code 500", { failCode: "500", failMsg: "NSFW content detected in the input image" }, "nsfw"],
  ["sensitive text without a code", { failMsg: "The image contains sensitive content" }, "nsfw"],
  ["content policy with code 422", { failCode: "422", failMsg: "Your prompt violates our content policy" }, "nsfw"],
  ["validation", { failCode: "422", failMsg: "image_urls is invalid" }, "validation"],
  ["server error", { failCode: "500", failMsg: "Internal server error" }, "upstream"],
  ["no code and no message", {}, "upstream"],
  ["rate limited", { failCode: 429, failMsg: "Too many requests" }, "rate_limit"],
  ["vendor balance", { failCode: "402", failMsg: "Insufficient credits" }, "upstream"],
];

const failStateOracle: Oracle = async (kie) => {
  for (const [label, fields, errorClass] of FAILS) {
    const id = `fail-${label.replace(/[^a-z0-9]+/gi, "-")}`;
    await offline(() => kieJson({ code: 200, msg: "success", data: { taskId: id, model: "kling-3.0/video", state: "fail", ...fields } }), async () => {
      assertEquals(await kie.kieAdapter.poll(pollRef(id)), {
        status: "failed", error_class: errorClass, message: snippet(String(fields.failMsg ?? "Kie reported a failed generation"), 300),
      }, `FAIL_STATE ${label}`);
    });
  }
  const signed = "Could not fetch https://acct.r2.cloudflarestorage.com/up/x.jpg?X-Amz-Signature=deadbeef&X-Amz-Expires=900";
  await offline(() => kieJson({ code: 200, data: { taskId: "fail-signed", state: "fail", failCode: "500", failMsg: signed } }), async () => {
    const state = await kie.kieAdapter.poll(pollRef("fail-signed"));
    const message = state.status === "failed" ? state.message : "";
    assert(message.includes("[redacted-signed-url]") && !message.includes("X-Amz-Signature"), "FAIL_STATE: a vendor echo of a signed URL is redacted");
  });
  for (const [raw, status] of [["waiting", "queued"], ["queuing", "queued"], ["generating", "running"]] as const) {
    await offline(() => kieJson({ code: 200, data: { taskId: `state-${raw}`, state: raw } }), async () => {
      assertEquals(await kie.kieAdapter.poll(pollRef(`state-${raw}`)), { status }, `FAIL_STATE ${raw} is ${status}`);
    });
  }
};

Deno.test("a fail state with an nsfw/sensitive/content-policy message is nsfw whatever the code; others keep their class", async () => {
  await proves("fail state", failStateOracle, [
    ['error_class: KIE_CONTENT_REFUSAL.test(msg) ? "nsfw" : classifyKie(Number(data.failCode ?? 500), msg),',
      "error_class: classifyKie(Number(data.failCode ?? 500), msg),", /FAIL_STATE/],
  ]);
});
