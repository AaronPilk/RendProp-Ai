import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import type { RouteStep } from "../_shared/router.ts";
import { admitFundedReelRecipe, admitFundedReelSteps, readKieAccountCredits } from "./reel-provider-admission.ts";

const fal: RouteStep = {
  route_id: "live-fal-first", task: "video.reel_clip", provider: "fal",
  model: "bytedance/seedance/v1/pro/fast/image-to-video", unit: "second",
  unit_cents: 4.86, capabilities: ["i2v", "1080p", "5s"],
  max_latency_s: 900, min_plan: "free", same_model_as: null,
  privacy_tier: "retained_30d", enabled: true,
};
const kie: RouteStep = {
  ...fal, route_id: "funded-kie-second", provider: "kie", model: "kling-3.0/video",
  unit_cents: 9, privacy_tier: "trains_by_default",
};

Deno.test("live FAL-first or legacy-only reel routes cannot dispatch when FAL has no funded balance", async () => {
  let creditReads = 0;
  const deps = { kieKey: () => "synthetic-not-a-secret", kieCredits: async () => { creditReads++; return 100; } };
  for (const routerOn of [false, true]) {
    const steps = routerOn ? [fal] : [{ ...fal, route_id: "legacy-local" }];
    const error = await assertRejects(() => admitFundedReelSteps(steps, 5, deps), HttpError);
    assertEquals(error.status, 503);
  }
  assertEquals(creditReads, 0, "No funded KIE route means no provider or balance probe");
});

Deno.test("a verified KIE route is selected ahead of unfunded FAL and requires enough credits", async () => {
  let reads = 0;
  const deps = { kieKey: () => "synthetic-not-a-secret", kieCredits: async () => { reads++; return 90; } };
  assertEquals(await admitFundedReelSteps([fal, kie], 5, deps), [kie]);
  assertEquals(reads, 1);
  const refused = await assertRejects(() => admitFundedReelSteps([fal, kie], 5, {
    ...deps, kieCredits: async () => 89,
  }), HttpError);
  assertEquals(refused.status, 402);
  const noKey = await assertRejects(() => admitFundedReelSteps([kie], 5, {
    ...deps, kieKey: () => "",
  }), HttpError);
  assertEquals(noKey.status, 402);
  const disabled = await assertRejects(() => admitFundedReelSteps([{ ...kie, enabled: false }, fal], 5, deps), HttpError);
  assertEquals(disabled.status, 503);
});

Deno.test("server-job quote refuses FAL and an underfunded KIE batch before admission", async () => {
  let reads = 0;
  const deps = { kieKey: () => "synthetic-not-a-secret", kieCredits: async () => { reads++; return 1000; } };
  assertEquals((await assertRejects(() => admitFundedReelRecipe({ provider: "fal", reel_cents: 210 }, undefined, deps), HttpError)).status, 503);
  assertEquals(reads, 0);
  await admitFundedReelRecipe({ provider: "kie", reel_cents: 450 }, undefined, deps);
  assertEquals((await assertRejects(() => admitFundedReelRecipe({ provider: "kie", reel_cents: 550 }, undefined, deps), HttpError)).status, 402);
  // A saved job needs funding only for unpaid clips, not completed receipts.
  await admitFundedReelRecipe({ provider: "kie", reel_cents: 550 }, 450, deps);
});

Deno.test("KIE credit probe rejects HTTP-success auth errors, unknown balances and negative balances", async () => {
  const previous = globalThis.fetch;
  try {
    for (const payload of [{ code: 401, data: 100 }, { code: 200, data: null }, { code: 200, data: -1 }]) {
      globalThis.fetch = async (raw, init) => {
        const request = new Request(raw, init);
        assertEquals(request.method, "GET");
        assertEquals(request.url, "https://api.kie.ai/api/v1/chat/credit");
        assertEquals(request.headers.get("Authorization"), "Bearer synthetic-not-a-secret");
        return Response.json(payload);
      };
      const error = await assertRejects(() => readKieAccountCredits("synthetic-not-a-secret"), HttpError);
      assertEquals(error.status, 402);
    }
    globalThis.fetch = async () => Response.json({ code: 200, data: 1389 });
    assertEquals(await readKieAccountCredits("synthetic-not-a-secret"), 1389);
  } finally { globalThis.fetch = previous; }
});

Deno.test("reel route gates provider funding before a supplier reservation or POST", async () => {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  const route = source.slice(source.indexOf('seg[0] === "reel-clip"'), source.indexOf("// ---- POST /ai-video/drift ----"));
  assert(route.includes("await resolveRoute("), "No hardcoded FAL fallback is allowed for this route");
  assert(!route.includes("legacyVideoStep("));
  assert(route.indexOf("admitFundedReelSteps(") < route.indexOf("submitReservedVideo({"));
});
