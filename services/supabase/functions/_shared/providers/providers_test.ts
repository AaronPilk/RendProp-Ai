// deno test --allow-env --allow-net _shared/providers/providers_test.ts
//
// Offline only. There are NO vendor credentials in this environment, so every
// network call is stubbed: what these tests prove is the request we BUILD, the
// response shapes we PARSE, and the failover rules — not that any vendor
// answers. Nothing here has been exercised against a live API.

import { assert, assertEquals, assertRejects, assertStringIncludes } from "jsr:@std/assert@1";
import type { RouteStep } from "../router.ts";
import { FAL_OBJECT_LIFECYCLE_VALUE, falEndpoint, falInput } from "./fal.ts";
import { checkSubstitution, classifyKie, kieAdapter, parseResultUrls } from "./kie.ts";
import { HF_MOTION_FALLBACK, hfInput, higgsfieldAdapter } from "./higgsfield.ts";
import { imageSizeFor, mapWhisperWords } from "./openai.ts";
import { assertNotCoveredModel, outputConfigFor } from "./anthropic.ts";
import { geminiImagePayload } from "./gemini.ts";
import { runChain } from "./chain.ts";
import { routerJobFrom, routerStatusUrl } from "./jobtoken.ts";
import { ProviderError, snippet } from "./common.ts";
import { HttpError } from "../http.ts";

function step(over: Partial<RouteStep> = {}): RouteStep {
  return {
    route_id: "r1",
    task: "video.reel_clip",
    provider: "fal",
    model: "fal-ai/bytedance/seedance/v1/pro/fast/image-to-video",
    unit: "second",
    unit_cents: 4.8,
    capabilities: ["i2v", "1080p", "5s"],
    max_latency_s: 600,
    min_plan: "free",
    same_model_as: null,
    privacy_tier: "retained_30d",
    enabled: true,
    ...over,
  };
}

/** Swap global fetch for one call's worth of canned responses. */
async function withFetch(handler: (url: string, init?: RequestInit) => Response, fn: () => Promise<void>) {
  const real = globalThis.fetch;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) =>
    Promise.resolve(handler(String(input instanceof Request ? input.url : input), init))) as typeof fetch;
  try {
    await fn();
  } finally {
    globalThis.fetch = real;
  }
}

// ── 1. FLAG OFF = BYTE-IDENTICAL fal PAYLOADS ────────────────────────────────
//
// The literals below are copied from the shipped ai-video/index.ts. If this
// test fails, the flag-off path has stopped being a no-op.

Deno.test("fal reel-clip payload is byte-identical to the shipped call", () => {
  const body = falInput(step(), {
    task: "video.reel_clip",
    prompt: "PROMPT",
    image_url: "https://r2.example/photo.jpg",
    seconds: 5,
    resolution: "1080p",
  });
  assertEquals(
    JSON.stringify(body),
    JSON.stringify({
      prompt: "PROMPT",
      image_url: "https://r2.example/photo.jpg",
      resolution: "1080p",
      duration: "5",
    }),
  );
});

Deno.test("fal grounded-aerial payload is byte-identical (aspect_ratio + camera_fixed)", () => {
  const body = falInput(step({ task: "video.aerial" }), {
    task: "video.aerial",
    prompt: "PROMPT",
    image_url: "data:image/jpeg;base64,AAAA",
    seconds: 6,
    aspect: "16:9",
    resolution: "1080p",
  });
  assertEquals(
    JSON.stringify(body),
    JSON.stringify({
      prompt: "PROMPT",
      image_url: "data:image/jpeg;base64,AAAA",
      resolution: "1080p",
      duration: "6",
      aspect_ratio: "16:9",
      camera_fixed: false,
    }),
  );
});

Deno.test("fal ungrounded-aerial (veo3.1/fast t2v) payload is byte-identical", () => {
  const body = falInput(
    step({ task: "video.aerial_no_photo", model: "fal-ai/veo3.1/fast", unit: "call" }),
    { task: "video.aerial_no_photo", prompt: "PROMPT", seconds: 8, aspect: "9:16", resolution: "1080p" },
  );
  assertEquals(
    JSON.stringify(body),
    JSON.stringify({
      prompt: "PROMPT",
      duration: "8s",
      resolution: "1080p",
      aspect_ratio: "9:16",
      generate_audio: false,
    }),
  );
});

Deno.test("fal topaz payload is byte-identical, and target_fps only when interpolating", () => {
  const withFps = falInput(step({ task: "video.upscale_4k", model: "fal-ai/topaz/upscale/video" }), {
    task: "video.upscale_4k",
    video_url: "https://r2.example/clip.mp4",
    extra: { upscale_factor: 2, target_fps: 60 },
  });
  assertEquals(
    JSON.stringify(withFps),
    JSON.stringify({
      video_url: "https://r2.example/clip.mp4",
      model: "Proteus",
      upscale_factor: 2,
      H264_output: true,
      target_fps: 60,
    }),
  );
  const noFps = falInput(step({ task: "video.upscale_1080p60", model: "fal-ai/topaz/upscale/video" }), {
    task: "video.upscale_1080p60",
    video_url: "https://r2.example/clip.mp4",
    extra: { upscale_factor: 1 },
  });
  assertEquals(
    JSON.stringify(noFps),
    JSON.stringify({ video_url: "https://r2.example/clip.mp4", model: "Proteus", upscale_factor: 1, H264_output: true }),
  );
});

Deno.test("fal endpoints: route slugs get the fal-ai/ prefix, vendor namespaces do not", () => {
  assertEquals(falEndpoint("bytedance/seedance/v1/pro/fast/image-to-video"), "fal-ai/bytedance/seedance/v1/pro/fast/image-to-video");
  assertEquals(falEndpoint("fal-ai/veo3.1/fast"), "fal-ai/veo3.1/fast");
  assertEquals(falEndpoint("bria/video/erase/prompt"), "bria/video/erase/prompt");
  assertEquals(falEndpoint("flux-pro/v1/fill"), "fal-ai/flux-pro/v1/fill");
});

Deno.test("every fal submit asks for a 24h object lifecycle", () => {
  assertEquals(FAL_OBJECT_LIFECYCLE_VALUE, '{"expiration_duration_seconds":86400}');
});

// ── 2. KIE: resultJson is a JSON *STRING* ────────────────────────────────────

Deno.test("kie resultJson is parsed from its JSON string form", () => {
  assertEquals(
    parseResultUrls('{"resultUrls":["https://cdn.kie.ai/a.mp4","https://cdn.kie.ai/b.mp4"]}'),
    ["https://cdn.kie.ai/a.mp4", "https://cdn.kie.ai/b.mp4"],
  );
  // Already-parsed object, bare array, single string, and a bare URL all work.
  assertEquals(parseResultUrls({ resultUrls: ["https://cdn.kie.ai/c.mp4"] }), ["https://cdn.kie.ai/c.mp4"]);
  assertEquals(parseResultUrls('["https://cdn.kie.ai/d.mp4"]'), ["https://cdn.kie.ai/d.mp4"]);
  assertEquals(parseResultUrls('{"resultUrl":"https://cdn.kie.ai/e.mp4"}'), ["https://cdn.kie.ai/e.mp4"]);
  assertEquals(parseResultUrls("https://cdn.kie.ai/f.mp4"), ["https://cdn.kie.ai/f.mp4"]);
  // Garbage is empty, never a throw.
  assertEquals(parseResultUrls("not json"), []);
  assertEquals(parseResultUrls(""), []);
  assertEquals(parseResultUrls(null), []);
});

Deno.test("kie poll parses a success record and marks the media as expiring", async () => {
  Deno.env.set("KIE_API_KEY", "test-key-not-real");
  await withFetch(
    () =>
      new Response(
        JSON.stringify({
          code: 200,
          msg: "success",
          data: {
            taskId: "t1",
            state: "success",
            param: '{"model":"m","input":{"duration":"5","resolution":"1080p"}}',
            resultJson: '{"resultUrls":["https://cdn.kie.ai/out.mp4"]}',
          },
        }),
        { status: 200 },
      ),
    async () => {
      const state = await kieAdapter.poll({
        provider: "kie",
        model: "bytedance/v1-pro-fast-image-to-video",
        id: "t1",
        poll_url: "https://api.kie.ai/api/v1/jobs/recordInfo?taskId=t1",
        submitted_at: new Date().toISOString(),
      });
      assertEquals(state.status, "done");
      if (state.status !== "done") return;
      assertEquals(state.result_url, "https://cdn.kie.ai/out.mp4");
      assertEquals(state.mime, "video/mp4");
      assertEquals(state.meta?.expires_in_days, 14);
    },
  );
});

Deno.test("kie: never trust the echo — a substituted duration/resolution is flagged", () => {
  const want = { duration: "5", resolution: "1080p" };
  assertEquals(checkSubstitution(want, { duration: "5", resolution: "1080p" }).substituted, false);
  assertEquals(checkSubstitution(want, { duration: "5s", resolution: "1080P" }).substituted, false);
  assertEquals(checkSubstitution(want, { duration: "3", resolution: "1080p" }).substituted, true);
  assertEquals(checkSubstitution(want, { duration: "5", resolution: "720p" }).substituted, true);
  // Nothing to compare against is not a claim that nothing changed.
  assertEquals(checkSubstitution(undefined, { duration: "3" }).substituted, false);
});

Deno.test("kie status codes map to the router's vocabulary", () => {
  assertEquals(classifyKie(402), "validation"); // out of credits
  assertEquals(classifyKie(429), "rate_limit");
  assertEquals(classifyKie(408), "upstream");
  assertEquals(classifyKie(455), "upstream");
  assertEquals(classifyKie(501), "upstream");
  assertEquals(classifyKie(451, "sensitive content"), "nsfw");
});

// ── 3. HIGGSFIELD: nsfw is its own terminal state ────────────────────────────

Deno.test("higgsfield nsfw is a terminal state with error_class nsfw", async () => {
  Deno.env.set("HIGGSFIELD_API_KEY_ID", "id-not-real");
  Deno.env.set("HIGGSFIELD_API_KEY_SECRET", "secret-not-real");
  await withFetch(
    () => new Response(JSON.stringify({ status: "nsfw" }), { status: 200 }),
    async () => {
      const state = await higgsfieldAdapter.poll({
        provider: "higgsfield",
        model: "dop/turbo",
        id: "req1",
        poll_url: "https://api.higgsfield.ai/v1/jobs/req1",
        submitted_at: new Date().toISOString(),
      });
      assertEquals(state.status, "failed");
      if (state.status !== "failed") return;
      assertEquals(state.error_class, "nsfw");
    },
  );
});

Deno.test("higgsfield maps its other terminal states without calling them nsfw", async () => {
  Deno.env.set("HIGGSFIELD_API_KEY_ID", "id-not-real");
  Deno.env.set("HIGGSFIELD_API_KEY_SECRET", "secret-not-real");
  const ref = {
    provider: "higgsfield",
    model: "dop/turbo",
    id: "req1",
    poll_url: "https://api.higgsfield.ai/v1/jobs/req1",
    submitted_at: new Date().toISOString(),
  };
  for (const [status, expected] of [["queued", "queued"], ["in_progress", "running"]] as const) {
    await withFetch(
      () => new Response(JSON.stringify({ status }), { status: 200 }),
      async () => assertEquals((await higgsfieldAdapter.poll(ref)).status, expected),
    );
  }
  await withFetch(
    () => new Response(JSON.stringify({ status: "failed", error: "gpu exploded" }), { status: 200 }),
    async () => {
      const s = await higgsfieldAdapter.poll(ref);
      assertEquals(s.status, "failed");
      if (s.status !== "failed") return;
      assertEquals(s.error_class, "upstream");
    },
  );
});

Deno.test("higgsfield always sends enhance_prompt:false", async () => {
  const body = await hfInput(
    step({ provider: "higgsfield", model: "bytedance/seedance/v1/pro/fast/image-to-video", task: "video.aerial" }),
    { task: "video.aerial", prompt: "P", image_url: "https://r2.example/p.jpg", seconds: 6, aspect: "16:9", resolution: "1080p" },
  );
  assertEquals(body.enhance_prompt, false);
  assertEquals(body.duration, 6);
  assertEquals(body.resolution, "1080p");
});

Deno.test("higgsfield never invents a motion uuid", async () => {
  Deno.env.set("HIGGSFIELD_API_KEY_ID", "id-not-real");
  Deno.env.set("HIGGSFIELD_API_KEY_SECRET", "secret-not-real");
  // The offline fallback map deliberately holds nulls: uuids must be fetched.
  assertEquals(HF_MOTION_FALLBACK.crane_down, null);
  await withFetch(
    () => new Response("{}", { status: 500 }), // /v1/motions unavailable
    async () => {
      const err = await assertRejects(() =>
        hfInput(step({ provider: "higgsfield", model: "dop/turbo", task: "video.aerial" }), {
          task: "video.aerial",
          prompt: "P",
          image_url: "https://r2.example/p.jpg",
          extra: { motion: "crane_down" },
        })
      );
      assert(err instanceof ProviderError);
      assertEquals((err as ProviderError).error_class, "validation");
      assertStringIncludes((err as ProviderError).message, "never invented");
    },
  );
});

// ── 4. OPENAI ────────────────────────────────────────────────────────────────

Deno.test("whisper verbose_json words[] map to {text,start,end}", () => {
  const words = mapWhisperWords({
    text: "Bright open kitchen",
    words: [
      { word: "Bright", start: 0, end: 0.42 },
      { word: " open", start: 0.42, end: 0.71 },
      { word: "kitchen", start: 0.71, end: 1.2 },
      { word: "", start: 1.2, end: 1.4 }, // empty token: dropped
      { word: "bad", start: "x", end: 2 }, // unparseable timing: dropped
    ],
  });
  assertEquals(words, [
    { text: "Bright", start: 0, end: 0.42 },
    { text: "open", start: 0.42, end: 0.71 },
    { text: "kitchen", start: 0.71, end: 1.2 },
  ]);
  // Segment-only output (no words[]) is an empty timeline, never a throw.
  assertEquals(mapWhisperWords({ text: "x", segments: [] }), []);
});

Deno.test("gpt-image sizes come from the aspect, and 'auto' when there is none", () => {
  assertEquals(imageSizeFor("16:9"), "1536x1024");
  assertEquals(imageSizeFor("9:16"), "1024x1536");
  assertEquals(imageSizeFor("1:1"), "1024x1024");
  assertEquals(imageSizeFor(undefined), "auto");
});

Deno.test("gpt-image-2 edits never send input_fidelity", async () => {
  Deno.env.set("OPENAI_API_KEY", "sk-not-real");
  let seenFields: string[] = [];
  await withFetch(
    (_url, init) => {
      const form = init?.body as FormData;
      seenFields = [...form.keys()];
      return new Response(JSON.stringify({ data: [{ b64_json: "QUJD" }] }), { status: 200 });
    },
    async () => {
      const { openaiAdapter } = await import("./openai.ts");
      await openaiAdapter.submit(
        step({ provider: "openai", model: "gpt-image-2", task: "photo.declutter", unit: "image" }),
        { task: "photo.declutter", prompt: "remove the clutter", image_b64: "QUJD", extra: { image_mime: "image/png" } },
      );
    },
  );
  assert(!seenFields.includes("input_fidelity"), `input_fidelity must never be sent (sent: ${seenFields.join(",")})`);
  assert(seenFields.includes("quality"));
  assert(seenFields.includes("prompt"));
});

// ── 5. ANTHROPIC ─────────────────────────────────────────────────────────────

Deno.test("Covered Models are refused at construction", async () => {
  const { anthropicClient } = await import("./anthropic.ts");
  assertNotCoveredModel("claude-haiku-4-5"); // fine
  for (const bad of ["claude-fable-5", "claude-mythos-1", "CLAUDE-FABLE-5.1"]) {
    let threw = false;
    try {
      anthropicClient(bad);
    } catch (e) {
      threw = true;
      assert(e instanceof ProviderError);
      assertEquals((e as ProviderError).error_class, "validation");
    }
    assert(threw, `${bad} must be refused`);
  }
});

Deno.test("Sonnet 5 always carries output_config effort:low", () => {
  assertEquals(outputConfigFor("claude-sonnet-5"), { effort: "low" });
  assertEquals(outputConfigFor("claude-haiku-4-5"), null);
});

// ── 6. GEMINI ────────────────────────────────────────────────────────────────

Deno.test("gemini 2.5 payload is the shipped one; 3.x pins imageSize to 1K", () => {
  assertEquals(
    JSON.stringify(geminiImagePayload("gemini-2.5-flash-image", "PROMPT", "image/jpeg", "AAAA")),
    JSON.stringify({
      contents: [{ role: "user", parts: [{ text: "PROMPT" }, { inline_data: { mime_type: "image/jpeg", data: "AAAA" } }] }],
      generationConfig: { responseModalities: ["IMAGE"] },
    }),
  );
  const v3 = geminiImagePayload("gemini-3.1-flash-image", "PROMPT", "image/jpeg", "AAAA");
  assertEquals((v3.generationConfig as Record<string, unknown>).imageConfig, { imageSize: "1K" });
});

// ── 7. THE CHAIN LOOP ────────────────────────────────────────────────────────

Deno.test("chain: an upstream failure moves to the next step", async () => {
  const tried: string[] = [];
  const steps = [step({ route_id: "a", provider: "fal" }), step({ route_id: "b", provider: "kie" })];
  const out = await runChain("video.reel_clip", steps, (s) => {
    tried.push(s.route_id);
    if (s.route_id === "a") throw new ProviderError("fal", "upstream", "fal HTTP 503");
    return Promise.resolve("ok-from-b");
  });
  assertEquals(tried, ["a", "b"]);
  assertEquals(out.step.route_id, "b");
  assertEquals(out.value, "ok-from-b");
});

Deno.test("chain: rate_limit and timeout also fail over", async () => {
  for (const cls of ["rate_limit", "timeout", "other"] as const) {
    const tried: string[] = [];
    const steps = [step({ route_id: "a" }), step({ route_id: "b" })];
    const out = await runChain("video.reel_clip", steps, (s) => {
      tried.push(s.route_id);
      if (s.route_id === "a") throw new ProviderError("fal", cls, `fal ${cls}`);
      return Promise.resolve(1);
    });
    assertEquals(tried, ["a", "b"], `class ${cls} should fail over`);
    assertEquals(out.step.route_id, "b");
  }
});

Deno.test("chain: a validation failure is rethrown, never retried elsewhere", async () => {
  const tried: string[] = [];
  const steps = [step({ route_id: "a" }), step({ route_id: "b" })];
  const err = await assertRejects(() =>
    runChain("video.reel_clip", steps, (s) => {
      tried.push(s.route_id);
      throw new ProviderError("fal", "validation", "mask_url is required");
    })
  );
  assertEquals(tried, ["a"], "a validation failure must not touch the next provider");
  assert(err instanceof HttpError);
  assertEquals((err as HttpError).status, 400);
  assertEquals((err as HttpError).code, "validation");
});

Deno.test("chain: an nsfw refusal is rethrown, never shopped to another vendor", async () => {
  const tried: string[] = [];
  const steps = [step({ route_id: "a" }), step({ route_id: "b" })];
  const err = await assertRejects(() =>
    runChain("video.aerial", steps, (s) => {
      tried.push(s.route_id);
      throw new ProviderError("higgsfield", "nsfw", "Higgsfield refused this generation as NSFW");
    })
  );
  assertEquals(tried, ["a"]);
  assert(err instanceof HttpError);
  assertEquals((err as HttpError).status, 400);
  assertEquals((err as HttpError).code, "unsupported_edit");
});

Deno.test("chain: an exhausted multi-step chain is one 503 naming the task", async () => {
  const steps = [step({ route_id: "a" }), step({ route_id: "b" })];
  const err = await assertRejects(() =>
    runChain("video.reel_clip", steps, () => {
      throw new ProviderError("fal", "upstream", "fal HTTP 502");
    })
  );
  assert(err instanceof HttpError);
  assertEquals((err as HttpError).status, 503);
  assertStringIncludes((err as HttpError).message, "All providers for video.reel_clip are unavailable right now.");
});

Deno.test("chain: a chain of ONE surfaces the provider's own error (flag-off shape)", async () => {
  const err = await assertRejects(() =>
    runChain("photo.sky", [step({ provider: "gemini", task: "photo.sky" })], () => {
      throw new ProviderError("gemini", "upstream", "gemini HTTP 502: upstream boom");
    })
  );
  assert(err instanceof HttpError);
  assertEquals((err as HttpError).status, 502);
  assertEquals((err as HttpError).code, "upstream");
  assertStringIncludes((err as HttpError).message, "gemini HTTP 502");
});

// ── 8. THE ROUTED-JOB TOKEN (what ai-video puts in status_url) ───────────────

Deno.test("job token round-trips and carries no credential", () => {
  const ref = {
    provider: "kie",
    model: "bytedance/v1-pro-fast-image-to-video",
    id: "task-123",
    poll_url: "https://api.kie.ai/api/v1/jobs/recordInfo?taskId=task-123",
    submitted_at: "2026-09-04T12:00:00.000Z",
  };
  const req = new Request("https://proj.supabase.co/functions/v1/ai-video/reel-clip", { method: "POST" });
  const url = routerStatusUrl(req, "ai-video", "video.reel_clip", ref);
  assertStringIncludes(url, "https://proj.supabase.co/functions/v1/ai-video/status?job=");

  const params = new URL(url).searchParams;
  const job = routerJobFrom(params);
  assert(job);
  assertEquals(job.p, "kie");
  assertEquals(job.i, "task-123");
  assertEquals(job.k, "video.reel_clip");
  assertEquals(job.u, ref.poll_url);
  // Nothing secret rides along: no org, no key, no signature.
  const decoded = atob(new URL(url).searchParams.get("job")!.replace(/-/g, "+").replace(/_/g, "/"));
  for (const forbidden of ["org", "key", "secret", "X-Amz", "Authorization"]) {
    assert(!decoded.includes(forbidden), `token must not carry ${forbidden}`);
  }
});

Deno.test("a legacy fal status request is NOT treated as a routed job", () => {
  const params = new URLSearchParams({
    status_url: "https://queue.fal.run/fal-ai/veo3.1/fast/requests/abc/status",
    response_url: "https://queue.fal.run/fal-ai/veo3.1/fast/requests/abc",
  });
  assertEquals(routerJobFrom(params), null);
  assertEquals(routerJobFrom(new URLSearchParams()), null);
  // Garbage in the job slot is null, never a throw.
  assertEquals(routerJobFrom(new URLSearchParams({ job: "!!!not-base64!!!" })), null);
  assertEquals(routerJobFrom(new URLSearchParams({ job: btoa('{"nope":1}') })), null);
});

Deno.test("vendor bodies are redacted before they reach an error or a log", () => {
  const body = {
    error: "could not fetch https://acct.r2.cloudflarestorage.com/up/x.jpg?X-Amz-Signature=deadbeef&X-Amz-Expires=900",
  };
  const out = snippet(body, 400);
  assert(!out.includes("X-Amz-Signature"), out);
  assertStringIncludes(out, "[redacted-signed-url]");
  // A plain vendor CDN URL is not secret and stays readable.
  assertStringIncludes(snippet({ url: "https://cdn.kie.ai/out.mp4" }), "https://cdn.kie.ai/out.mp4");
});
