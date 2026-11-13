import { assert, assertEquals, assertThrows, assertStringIncludes } from "jsr:@std/assert@1";
import { buildSeedanceReelPreset, REEL_PRESETS, parseReelMotion } from "./motion.ts";
import { GUARDRAILS } from "../_shared/fairhousing.ts";
import { falInput } from "../_shared/providers/fal.ts";
import type { RouteStep } from "../_shared/router.ts";
const step = { model: "bytedance/seedance/v1/pro/fast/image-to-video" } as RouteStep;
Deno.test("versioned presets preserve the property and use only one supported reference image", () => {
  assertEquals(REEL_PRESETS, ["fly_through", "push_in", "side_glide", "pull_back"]);
  for (const motion of REEL_PRESETS) {
    assertEquals(parseReelMotion(motion), motion);
    const prompt = buildSeedanceReelPreset("home", motion);
    assertStringIncludes(prompt, "garage door and trim colors");
    assertStringIncludes(prompt, "only visual reference");
    assertStringIncludes(prompt, "Do not renovate, recolor, add, remove or move anything");
    assertStringIncludes(prompt, GUARDRAILS);
    for (const aspect of ["9:16", "16:9"] as const) {
      const body = falInput(step, { task: "video.reel_clip", prompt, image_url: "data:image/jpeg;base64,AA==", seconds: 5, aspect });
      assertEquals(body.aspect_ratio, aspect); assertEquals(body.duration, "5");
      assertEquals(body.num_frames, 121); assertEquals(body.camera_fixed, false);
      assert(!("end_image_url" in body), "Fast does not support a second image");
    }
  }
});
Deno.test("pull-back stays within the source image; fly-through has short, level tracking", () => {
  assertStringIncludes(buildSeedanceReelPreset("home", "pull_back"), "Never widen beyond the source image borders");
  const fly = buildSeedanceReelPreset("home", "fly_through");
  assertStringIncludes(fly, "short distance"); assertStringIncludes(fly, "horizon level");
  assertStringIncludes(fly, "No banking or flight through objects");
});
Deno.test("Hailuo does not silently expand a five-second reservation to six billable seconds", () => {
  const hailuo = { model: "minimax/hailuo-02/standard/image-to-video" } as RouteStep;
  assertThrows(() => falInput(hailuo, { task: "video.reel_clip", prompt: "tracking", seconds: 5 }), Error, "six- or ten-second");
  for (const seconds of [6, 10]) {
    const body = falInput(hailuo, { task: "video.reel_clip", prompt: "tracking", seconds });
    assertEquals(body.duration, String(seconds)); assertEquals(body.prompt_optimizer, false);
  }
});
