// deno test --allow-env --allow-read --allow-net _shared/providers/kie_property_guards_test.ts
//
// Fix-wave guards on the Kie property path (kie-kling3-4k-steady-v1), OFFLINE:
// fetch is stubbed (only api.kie.ai is answered, every other host throws), the
// key is a synthetic fixture string, and every oracle also runs against compiled
// defects (kie.ts or property-video-kie.ts with one unique anchor mutated, loaded
// from a data: URL) and must fail for the reason it names.
//   1. the exact reviewed prompt (pinned template SHA-256) before the key or any request;
//   2. a missing KIE_API_KEY is a definite pre-request refusal that the REAL runChain /
//      asHttpError / submitReservedVideo turn into a released hold (other Kie paths unchanged);
//   3. the property ask records the tier it requests (4K): a truthful echo is no substitution;
//   4. an inconsistent identity loads, and the property path refuses before any request.

import { assert, assertEquals, assertMatch, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import * as realKie from "./kie.ts";
import { ProviderError } from "./common.ts";
import { asHttpError, runChain } from "./chain.ts";
import { HttpError } from "../http.ts";
import { KIE_PROPERTY_IDENTITY, KIE_PROPERTY_PROFILE, KIE_PROPERTY_ROUTE_ID } from "../property-video-kie.ts";
import { submitReservedVideo, VideoDispatchUnconfirmed } from "../../ai-video/cost-reservation.ts";
import { buildPhotoPreservingReelPrompt, buildPropertyCanvasReelPrompt, buildSteadyPropertyReelPrompt } from "../../ai-video/reel-framing.ts";
import { buildReelPrompt } from "../../ai-video/motion.ts";
import type { RouteStep } from "../router.ts";
import type { GenerateInput, JobRef, JobState } from "./types.ts";

type KieModule = typeof import("./kie.ts");
type Oracle = (kie: KieModule) => Promise<void>;
type Control = [needle: string, replacement: string, reason: RegExp];

// ── Compiled defects ─────────────────────────────────────────────────────────

const KIE_MODULE = new URL("./kie.ts", import.meta.url);
const KIE_SOURCE = await Deno.readTextFile(KIE_MODULE);
const IDENTITY_MODULE = new URL("../property-video-kie.ts", import.meta.url);
const IDENTITY_SOURCE = await Deno.readTextFile(IDENTITY_MODULE);
const IDENTITY_DATA = await Deno.readTextFile(new URL("../property-video-kie-identity.ts", import.meta.url));

function dataUrl(source: string): string {
  const bytes = new TextEncoder().encode(source);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return `data:application/typescript;base64,${btoa(binary)}`;
}
function once(text: string, needle: string, replacement: string): string {
  assertEquals(text.split(needle).length, 2, `Defect anchor must occur exactly once: ${needle}`);
  return text.replace(needle, () => replacement);
}
/** kie.ts (optionally mutated), its relative imports absolute; optionally over a broken identity module. */
async function compileKie(source = KIE_SOURCE, brokenIdentity?: string): Promise<KieModule> {
  let identityHref = IDENTITY_MODULE.href;
  if (brokenIdentity !== undefined) {
    identityHref = dataUrl(IDENTITY_SOURCE.replace(/from "(\.\/[^"]+)"/g, (_all, path: string) =>
      `from ${JSON.stringify(path === "./property-video-kie-identity.ts" ? dataUrl(brokenIdentity) : new URL(path, IDENTITY_MODULE).href)}`));
  }
  const text = source.replace(/from "(\.\.?\/[^"]+)"/g, (_all, path: string) => {
    const href = new URL(path, KIE_MODULE).href;
    return `from ${JSON.stringify(href === IDENTITY_MODULE.href ? identityHref : href)}`;
  });
  return await import(dataUrl(text));
}
async function proves(name: string, oracle: Oracle, controls: Control[]): Promise<void> {
  await oracle(realKie);
  for (const [needle, replacement, reason] of controls) {
    const broken = await compileKie(once(KIE_SOURCE, needle, replacement));
    const error = await assertRejects(() => oracle(broken), Error, undefined, `${name}: defect not detected (${needle})`);
    assertMatch(error.message, reason, `${name}: defect detected for an unrelated reason (${needle})`);
  }
  console.log(`KIE_PROPERTY_GUARD_CONTROLS[${name}]=${controls.length}`);
}

// ── Offline transport ────────────────────────────────────────────────────────

interface Wire { url: string; method: string; body: string | null }
type Responder = (call: Wire) => Response | Promise<Response>;
const FIXTURE_KEY = "offline-fixture-key-not-a-credential";
const CREATE_TASK = "https://api.kie.ai/api/v1/jobs/createTask";
const RECORD_INFO = "https://api.kie.ai/api/v1/jobs/recordInfo";
const NO_HTTP: Responder = () => {
  throw new Error("No HTTP request is permitted here");
};

/** fetch stubbed; KIE_API_KEY set to the fixture, a given value, or unset (null). */
async function offline<T>(respond: Responder, work: (calls: Wire[]) => Promise<T>, key: string | null = FIXTURE_KEY): Promise<T> {
  const previousFetch = globalThis.fetch, previousKey = Deno.env.get("KIE_API_KEY");
  const calls: Wire[] = [];
  if (key === null) Deno.env.delete("KIE_API_KEY");
  else Deno.env.set("KIE_API_KEY", key);
  globalThis.fetch = (async (resource: string | URL | Request, init?: RequestInit) => {
    const url = resource instanceof Request ? resource.url : String(resource);
    calls.push({ url, method: init?.method ?? "GET", body: typeof init?.body === "string" ? init.body : null });
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
const kieCalls = (calls: Wire[]) => calls.filter((c) => new URL(c.url).hostname === "api.kie.ai");
const kieJson = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const acceptedWith = (taskId: string): Responder => () => kieJson({ code: 200, msg: "success", data: { taskId } });

// ── Fixtures ─────────────────────────────────────────────────────────────────

const SOURCE = "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/rendprop-uploads/uploads/org/listing/photo.jpg" +
  "?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires=7200&X-Amz-SignedHeaders=host&X-Amz-Signature=" + "0".repeat(64);
const MOTIONS = ["fly_through", "push_in", "side_glide", "pull_back"] as const;
const ASPECTS = ["16:9", "9:16"] as const;
const PROMPT = buildSteadyPropertyReelPrompt("home", "side_glide", "9:16");
const propertyStep: RouteStep = {
  route_id: KIE_PROPERTY_ROUTE_ID, task: "video.reel_clip", provider: "kie", model: "kling-3.0/video",
  unit: "second", unit_cents: 33.5, capabilities: ["i2v", "1080p", "5s", "native4k", "preserve_photo"],
  max_latency_s: 1800, min_plan: "free", same_model_as: "kling_3_pro", privacy_tier: "trains_by_default", enabled: true,
};
function propertyInput(aspect: "16:9" | "9:16" = "9:16", prompt = PROMPT): GenerateInput {
  return {
    task: "video.reel_clip", prompt, image_url: SOURCE, seconds: 5, resolution: "1080p", aspect, framing: "preserve_photo",
    extra: { kie_mode: "4K", sound: false, property_video_target_aspect: aspect, property_video_quality_profile: KIE_PROPERTY_PROFILE },
  };
}
const propertyWire = (prompt: string) => `{"model":"kling-3.0/video","input":{"prompt":${JSON.stringify(prompt)},"image_urls":[${JSON.stringify(SOURCE)}],` +
  `"sound":false,"duration":"5","mode":"4K","multi_shots":false}}`;
const ownerStep: RouteStep = {
  route_id: "closed-owner-kling", task: "video.reel_clip", provider: "kie", model: "kling-3.0/video", unit: "second",
  unit_cents: 33.5, capabilities: ["i2v", "1080p", "5s"], max_latency_s: 900, min_plan: "free", same_model_as: "kling_3_pro",
  privacy_tier: "trains_by_default", enabled: true,
};
const OWNER_PROMPT = "Exact full photo. Physical shallow camera track, fixed lens.";
const ownerInput: GenerateInput = {
  task: "video.reel_clip", prompt: OWNER_PROMPT, image_url: "https://owned-fixture.invalid/full-photo.jpg", seconds: 5, resolution: "1080p",
  aspect: "9:16", framing: "preserve_photo", extra: { kie_mode: "4K", sound: false },
};
const OWNER_WIRE = `{"model":"kling-3.0/video","input":{"prompt":${JSON.stringify(OWNER_PROMPT)},"image_urls":["https://owned-fixture.invalid/full-photo.jpg"],` +
  `"sound":false,"duration":"5","mode":"4K","multi_shots":false}}`;
const RESULT = "https://tempfile.aiquickdraw.com/k/property-4k-fixture.mp4";
const pollRef = (id: string): JobRef => ({
  provider: "kie", model: "kling-3.0/video", id, poll_url: `${RECORD_INFO}?taskId=${encodeURIComponent(id)}`, submitted_at: "2026-10-16T12:00:00.000Z",
});
function successWith(taskId: string, result: Record<string, unknown> = {}, echo: Record<string, unknown> = {}): Responder {
  return () => kieJson({ code: 200, msg: "success", data: {
    taskId, model: "kling-3.0/video", state: "success", creditsConsumed: 335,
    param: JSON.stringify({ model: "kling-3.0/video", input: { prompt: "echo", image_urls: ["https://echo.invalid/x.jpg"], sound: false, duration: "5", mode: "4K", multi_shots: false, ...echo } }),
    resultJson: JSON.stringify({ resultUrls: [RESULT], ...result }),
  } });
}
function doneMeta(state: JobState, tag: string): Record<string, unknown> {
  assertEquals(state.status, "done", `${tag}: expected a result`);
  return state.status === "done" ? state.meta ?? {} : {};
}

// ── 1. The exact reviewed prompt, before the key or any request ─────────────

const promptPinOracle: Oracle = async (kie) => {
  for (const noun of KIE_PROPERTY_IDENTITY.prompt_scene_nouns) for (const motion of MOTIONS) for (const aspect of ASPECTS) {
    const prompt = buildSteadyPropertyReelPrompt(noun, motion, aspect);
    await offline(acceptedWith(`pin-${motion}-${aspect.replace(":", "x")}`), async (calls) => {
      await kie.kieAdapter.submit(propertyStep, propertyInput(aspect, prompt));
      assertEquals(calls.map((c) => [c.url, c.method, c.body]), [[CREATE_TASK, "POST", propertyWire(prompt)]], `PIN pass ${noun} ${motion} ${aspect}: one exact POST`);
    });
  }
  const at = (i: number) => PROMPT.slice(0, i) + (PROMPT[i] === "x" ? "y" : "x") + PROMPT.slice(i + 1);
  const refused: [string, string][] = [
    ["first character changed", at(0)], ["middle character changed", at(Math.floor(PROMPT.length / 2))], ["last character changed", at(PROMPT.length - 1)],
    ["unknown noun", buildSteadyPropertyReelPrompt("castle", "side_glide", "9:16")],
    ["FAL v1 canvas prompt", buildPropertyCanvasReelPrompt("home", "side_glide", "9:16")],
    ["photo-preserving prompt", buildPhotoPreservingReelPrompt("home", "side_glide")],
    ["legacy reel prompt", buildReelPrompt({ sceneNoun: "home", motion: "side_glide" })],
    ["owner QA prompt", OWNER_PROMPT],
  ];
  // Key unset: a pin refusal (validation) proves the check precedes the key read.
  for (const key of [null, FIXTURE_KEY]) {
    await offline(NO_HTTP, async (calls) => {
      for (const [label, prompt] of refused) {
        const error = await assertRejects(() => kie.kieAdapter.submit(propertyStep, propertyInput("9:16", prompt)), ProviderError, undefined, `PIN refuse ${label}`);
        assertEquals([error.provider, error.error_class, error.status, error.dispatch_rejected], ["kie", "validation", 400, true], `PIN refuse ${label}: definite (key ${key === null ? "unset" : "set"})`);
        assertEquals(error.message, `Kie property video refused before dispatch: prompt does not match ${KIE_PROPERTY_PROFILE}.`, `PIN refuse ${label}: no prompt echoed`);
      }
      assertEquals(calls, [], "PIN refuse: zero requests of any kind");
    }, key);
  }
};

Deno.test("property submit sends only the pinned reviewed prompt (4 motions x 6 nouns x 2 canvases); anything else is refused before the key or any request", async () => {
  await proves("prompt pin", promptPinOracle, [
    ["if (!await kiePropertyPromptPinned(request.input.prompt)) throw propertyRefusal(\"prompt\");", "", /PIN refuse/],
    ["if (!await kiePropertyPromptPinned(request.input.prompt)) throw propertyRefusal(\"prompt\");",
      "kieHeaders(true);\n      if (!await kiePropertyPromptPinned(request.input.prompt)) throw propertyRefusal(\"prompt\");", /PIN refuse/],
  ]);
});

// ── 2. Missing KIE_API_KEY: definite on the property path only ──────────────

interface Booked { name: string; args: Record<string, unknown> }
/** Production shape: submitReservedVideo -> runChain (one step) -> the adapter, with real asHttpError mapping. */
async function moneyPath(kie: KieModule, step: RouteStep, input: GenerateInput, respond: Responder, key: string | null) {
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
    let error: unknown;
    try {
      await submitReservedVideo({
        actorId: "fixture-actor", orgId: "fixture-org", key: "kie-key-money-fixture", feature: "reel", steps: [step], seconds: 5, input,
        listingId: "fixture-listing", allowance: { monthlyWindowStart: "2026-10-01T00:00:00Z", burstWindowStart: "2026-10-16T12:00:00Z" },
      }, { rpc, submit: (selected: RouteStep) => runChain("video.reel_clip", [selected], (s) => kie.kieAdapter.submit(s, input)) });
    } catch (caught) {
      error = caught;
    }
    return { error, kie: kieCalls(calls).length, booked };
  }, key);
}

const missingKeyOracle: Oracle = async (kie) => {
  for (const key of [null, "", "  \t\n"]) {
    const tag = `KEY ${JSON.stringify(key)}`;
    await offline(NO_HTTP, async (calls) => {
      const error = await assertRejects(() => kie.kieAdapter.submit(propertyStep, propertyInput()), ProviderError, undefined, `${tag}: refused`);
      assertEquals([error.provider, error.error_class, error.message, error.status, error.dispatch_rejected],
        ["kie", "upstream", "KIE_API_KEY function secret is not set", 0, true], `${tag}: definite pre-request refusal`);
      assertEquals(calls, [], `${tag}: zero requests`);
      // The real chain mapping keeps the release evidence.
      const answer = await assertRejects(() => runChain("video.reel_clip", [propertyStep], (s) => kie.kieAdapter.submit(s, propertyInput())), HttpError);
      assertEquals([answer.status, answer.details?.provider, answer.details?.provider_status, answer.details?.dispatch_rejected, answer.details?.error_class],
        [502, "kie", 0, true, "upstream"], `${tag}: runChain/asHttpError keep provider_status 0 and dispatch_rejected`);
      assertEquals(asHttpError(error).details?.provider_status, 0, `${tag}: asHttpError keeps status 0`);
      assertEquals(kieCalls(calls), [], `${tag}: the chain never reached Kie`);
    }, key);
    const money = await moneyPath(kie, propertyStep, propertyInput(), NO_HTTP, key);
    assert(money.error instanceof HttpError && !(money.error instanceof VideoDispatchUnconfirmed), `${tag}: a refusal, not an unconfirmed dispatch`);
    assertEquals(money.kie, 0, `${tag}: zero Kie requests`);
    assertEquals(money.booked.filter((b) => b.name === "serving_cost_finish").map((b) => [b.args.p_state, b.args.p_rejection_status]), [["rejected", 0]], `${tag}: serving hold rejected`);
    assertEquals(money.booked.filter((b) => b.name === "app_video_cost_release_rejected").map((b) => [b.args.p_provider_status, b.args.p_error_class]),
      [[0, "upstream"]], `${tag}: app hold released`);
  }
  // Other Kie paths keep their existing non-definite error (unchanged): the hold stays fenced.
  await offline(NO_HTTP, async (calls) => {
    const error = await assertRejects(() => kie.kieAdapter.submit(ownerStep, ownerInput), ProviderError);
    assertEquals([error.error_class, error.message, error.status, error.dispatch_rejected], ["upstream", "KIE_API_KEY function secret is not set", undefined, false], "KEY owner QA unchanged");
    assertEquals(calls, []);
  }, null);
  const owner = await moneyPath(kie, ownerStep, ownerInput, NO_HTTP, null);
  assert(owner.error instanceof VideoDispatchUnconfirmed, "KEY owner QA: unchanged retained hold");
  assertEquals(owner.booked.filter((b) => b.name === "app_video_cost_release_rejected"), [], "KEY owner QA: nothing released (unchanged)");
};

Deno.test("a missing KIE_API_KEY on the property path is a definite pre-request refusal the real chain releases; owner QA is unchanged", async () => {
  await proves("missing key", missingKeyOracle, [
    ["headers: kieHeaders(true), body: JSON.stringify(request)", "headers: kieHeaders(), body: JSON.stringify(request)", /KEY/],
    ["? new ProviderError(PROVIDER, \"upstream\", KIE_KEY_MISSING, 0, true)", "? new ProviderError(PROVIDER, \"upstream\", KIE_KEY_MISSING)", /KEY/],
  ]);
});

// ── 3. The property ask records the 4K tier it requests ─────────────────────

const echoTierOracle: Oracle = async (kie) => {
  const warm = async (id: string, step: RouteStep, input: GenerateInput, result: Record<string, unknown>, echo: Record<string, unknown> = {}) => {
    await offline(acceptedWith(id), () => kie.kieAdapter.submit(step, input));
    return await offline(successWith(id, result, echo), async () => doneMeta(await kie.kieAdapter.poll(pollRef(id)), `ECHO ${id}`));
  };
  // Truthful native-4K echoes, wherever Kie puts them, are not a substitution.
  const truthful: [string, Record<string, unknown>, Record<string, unknown>][] = [
    ["result 4K", { resolution: "4K" }, {}], ["result 4k", { resolution: "4k" }, {}], ["result 2160p", { resolution: "2160p" }, {}],
    ["result 2160P", { resolution: "2160P" }, {}], ["param 4K", {}, { resolution: "4K" }], ["param 2160p", {}, { resolution: "2160p" }],
    ["duration 5s and 4K", { duration: "5s", resolution: "4K" }, {}], ["no resolution echo", {}, {}],
  ];
  for (const [label, result, echo] of truthful) {
    const meta = await warm(`echo-true-${label.replace(/\W+/g, "-")}`, propertyStep, propertyInput(), result, echo);
    assert(!("substituted" in meta) && !("echo_unverified" in meta), `ECHO truthful ${label}: nothing claimed`);
  }
  // A downgraded tier or duration is still flagged, against what was actually requested.
  for (const [label, result, returned] of [["1080p", { resolution: "1080p" }, { duration: "5", resolution: "1080p" }],
    ["720P", { resolution: "720P" }, { duration: "5", resolution: "720p" }], ["10s", { duration: "10s", resolution: "4K" }, { duration: "10", resolution: "4k" }]] as const) {
    const meta = await warm(`echo-down-${label}`, propertyStep, propertyInput(), result);
    assertEquals([meta.substituted, meta.requested, meta.returned], [true, { duration: "5", resolution: "4K" }, returned], `ECHO downgrade ${label}`);
  }
  // Owner QA (asked "1080p") keeps the exact case-insensitive comparison: unchanged.
  const ownerFourK = await warm("echo-owner-2160p", ownerStep, ownerInput, { resolution: "2160p" });
  assertEquals([ownerFourK.substituted, ownerFourK.requested], [true, { duration: "5", resolution: "1080p" }], "ECHO owner QA 2160p is still a difference (unchanged)");
  const ownerSame = await warm("echo-owner-1080P", ownerStep, ownerInput, { resolution: "1080P" });
  assert(!("substituted" in ownerSame), "ECHO owner QA 1080P matches (unchanged)");
  assertEquals(realKie.checkSubstitution({ duration: "5", resolution: "4K" }, { resolution: "2160p" }).substituted, true,
    "ECHO an ask not recorded by the property path keeps the exact comparison");
  // Cold start: nothing to compare, nothing claimed (unchanged).
  const cold = await offline(successWith("echo-cold-tier", { resolution: "720p" }), async () => doneMeta(await kie.kieAdapter.poll(pollRef("echo-cold-tier")), "cold"));
  assertEquals([cold.echo_unverified, "substituted" in cold], [true, false], "ECHO cold start unchanged");
};

Deno.test("the property ask records mode 4K: a truthful 4K/4k/2160p echo is no substitution, a downgrade still is; other asks unchanged", async () => {
  await proves("echo tier", echoTierOracle, [
    ["const want: Asked = { duration: request.input.duration, resolution: request.input.mode };",
      "const want: Asked = { duration: request.input.duration, resolution: \"1080p\" };", /ECHO/],
    ["      nativeFourKAsks.add(want);\n", "", /ECHO/],
    ["const nativeFourKTier = (value: string) => value === \"2160p\" ? \"4k\" : value;", "const nativeFourKTier = (value: string) => value;", /ECHO/],
  ]);
});

// ── 4. An inconsistent identity loads; the property path refuses ────────────

Deno.test("an inconsistent identity never crashes the adapter module: property submit refuses before any request, owner QA is byte-identical", async () => {
  const brokenIdentity = once(IDENTITY_DATA, '"unit_cents": 33.5,', '"unit_cents": 33.6,');
  const oracle = async (kie: KieModule) => {
    await offline(NO_HTTP, async (calls) => {
      const error = await assertRejects(() => kie.kieAdapter.submit(propertyStep, propertyInput()), ProviderError, undefined, "LAZY: property refused");
      assertEquals([error.error_class, error.status, error.dispatch_rejected], ["validation", 400, true], "LAZY: definite");
      assertEquals(error.message, `Kie property video refused before dispatch: the ${KIE_PROPERTY_PROFILE} identity is internally inconsistent.`, "LAZY: refused for the identity");
      assertThrows(() => kie.kiePropertyRequest(propertyStep, propertyInput()), ProviderError, "internally inconsistent", "LAZY: the closed builder refuses it too");
      assertEquals(calls, [], "LAZY: zero requests");
    });
    await offline(acceptedWith("lazy-owner-qa"), async (calls) => {
      await kie.kieAdapter.submit(ownerStep, ownerInput);
      assertEquals(calls.map((c) => [c.url, c.body]), [[CREATE_TASK, OWNER_WIRE]], "LAZY: owner QA wire unchanged");
    });
  };
  await oracle(await compileKie(KIE_SOURCE, brokenIdentity));
  // Defect control: without the builder's consistency check the refusal is no longer the identity's.
  const unchecked = await compileKie(once(KIE_SOURCE, "  if (!kiePropertyIdentityConsistent()) throw inconsistentPropertyIdentity();\n", ""), brokenIdentity);
  await assertRejects(() => oracle(unchecked), Error, "LAZY");
  // And with the shipped identity the same module path is the normal property wire.
  await offline(acceptedWith("lazy-shipped"), async (calls) => {
    await (await compileKie()).kieAdapter.submit(propertyStep, propertyInput());
    assertEquals(calls.map((c) => c.body), [propertyWire(PROMPT)]);
  });
});
