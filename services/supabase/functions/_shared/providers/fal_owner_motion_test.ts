import { assert, assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { falInput, falAdapter } from "./fal.ts";
import { ProviderError } from "./common.ts";
import type { GenerateInput } from "./types.ts";
import type { RouteStep } from "../router.ts";

const step: RouteStep & { params: Record<string, unknown> } = { route_id: "owner-qa-fal-kling3-4k-rail-negative-v1", task: "video.reel_clip", provider: "fal",
  model: "fal-ai/kling-video/v3/4k/image-to-video", unit: "second", unit_cents: 42, capabilities: ["i2v", "1080p", "5s"],
  max_latency_s: 900, min_plan: "free", same_model_as: "kling_3_pro", privacy_tier: "retained_30d", enabled: true,
  params: { owner_motion_profile: "property-rail-negative-v1" } };
const input: GenerateInput = { task: "video.reel_clip", prompt: "same measured2cm prompt", image_url: "data:image/jpeg;base64,U0FNRQ==",
  seconds: 5, resolution: "1080p", framing: "preserve_photo", aspect: "16:9" };
const marker = { owner_motion_profile: "property-rail-negative-v1" };
const negative = "blur, distortion, low quality, walking camera, handheld motion, footsteps, vertical bobbing, camera sway, camera shake, jitter, tilted horizon, rolling horizon, orbit, speed ramp, digital zoom, warped geometry, morphing, flicker, text, logos, watermark";

Deno.test("exact FAL owner recipe changes only the fixed negative control and explicit documented0.5 default", () => {
  const old = { prompt: input.prompt, start_image_url: input.image_url, duration: "5", generate_audio: false };
  const unmarked = { ...step, route_id: "owner-qa-fal-kling3-4k-20261015", params: {} };
  assertEquals(JSON.stringify(falInput(unmarked, input)), JSON.stringify(old), "Unmarked4K wire must remain byte-identical");
  assertEquals(JSON.stringify(falInput(step, { ...input, extra: marker })), JSON.stringify({ ...old, negative_prompt: negative, cfg_scale: 0.5 }));
  for (const aspect of ["16:9", "9:16"] as const) {
    const body = falInput(step, { ...input, aspect, extra: marker });
    assert(!("end_image_url" in body) && !("aspect_ratio" in body) && !("resolution" in body));
  }
});

Deno.test("actual adapter emits one fixed silent5s payload and refuses marked omissions before HTTP", async () => {
  const oldFetch = globalThis.fetch, oldKey = Deno.env.get("FAL_KEY"); let posts = 0;
  Deno.env.set("FAL_KEY", "synthetic-test-key-never-an-account-secret");
  globalThis.fetch = (async (url: Request | URL | string, init?: RequestInit) => {
    posts++; assertEquals(String(url), "https://queue.fal.run/fal-ai/kling-video/v3/4k/image-to-video");
    assertEquals(init?.method, "POST");
    assertEquals(JSON.parse(String(init?.body)), { prompt: input.prompt, start_image_url: input.image_url, duration: "5", generate_audio: false,
      negative_prompt: negative, cfg_scale: 0.5 });
    assertEquals(new Headers(init?.headers).get("X-Fal-Object-Lifecycle-Preference"), '{"expiration_duration_seconds":86400}');
    const base = "https://queue.fal.run/fal-ai/kling-video/requests/rail-receipt";
    return Response.json({ request_id: "rail-receipt", status_url: base + "/status", response_url: base });
  }) as typeof fetch;
  try {
    const receipt = await falAdapter.submit(step, { ...input, extra: marker });
    assertEquals([receipt.provider, receipt.model, receipt.id], ["fal", step.model, "rail-receipt"]); assertEquals(posts, 1);
    for (const wrong of [input, { ...input, extra: { ...marker, cfg_scale: 0.5 } }, { ...input, seconds: 6, extra: marker }]) {
      const error = await assertRejects(() => falAdapter.submit(step, wrong), ProviderError);
      assertEquals([error.status, error.dispatch_rejected], [0, true]);
      assertEquals(posts, 1, "A malformed comparison must never reach HTTP");
    }
  } finally {
    globalThis.fetch = oldFetch;
    if (oldKey === undefined) Deno.env.delete("FAL_KEY"); else Deno.env.set("FAL_KEY", oldKey);
  }
});

Deno.test("wrong owner recipe, model, task, framing, duration, sound or arbitrary controls refuse before transport", () => {
  assertThrows(() => falInput(step, input), ProviderError, undefined, "Marked route cannot silently lose its input marker");
  for (const value of [null, true, 1, "unknown", "fal-kling3-4k-steady-v2"]) {
    assertThrows(() => falInput(step, { ...input, extra: { owner_motion_profile: value } }), ProviderError);
  }
  for (const extra of [{ negative_prompt: "arbitrary" }, { cfg_scale: 1 }, { end_image_url: "https://other.invalid/photo" },
    { generate_audio: false }, { sound: false }]) {
    assertThrows(() => falInput(step, { ...input, extra: { ...marker, ...extra } }), ProviderError);
  }
  for (const change of [{ task: "video.aerial" }, { framing: undefined }, { seconds: 6 }, { aspect: "1:1" as const }, { resolution: "4k" as const }]) {
    assertThrows(() => falInput(step, { ...input, ...change, extra: marker }), ProviderError);
  }
  for (const model of ["fal-ai/kling-video/v3/pro/image-to-video", "bytedance/seedance/v1/pro/fast/image-to-video", "veo3.1/fast/image-to-video"]) {
    assertThrows(() => falInput({ ...step, model }, { ...input, extra: marker }), ProviderError);
  }
  for (const changed of [{ route_id: "ordinary-4k-row" }, { params: {} }, { provider: "kie" }, { unit_cents: 41 }, { unit: "call" }]) {
    assertThrows(() => falInput({ ...step, ...changed }, { ...input, extra: marker }), ProviderError);
  }
});
