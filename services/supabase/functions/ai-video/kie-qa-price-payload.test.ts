// Offline actual adapter + paid-attempt boundary. No provider key or request.
import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { kieAdapter } from "../_shared/providers/kie.ts";
import { ProviderError } from "../_shared/providers/common.ts";
import { submitReservedVideo } from "./cost-reservation.ts";
import type { RouteStep } from "../_shared/router.ts";
import type { GenerateInput } from "../_shared/providers/types.ts";

const step: RouteStep = { route_id: "owner-qa-fixture", task: "video.reel_clip", provider: "kie",
  model: "bytedance/v1-pro-fast-image-to-video", unit: "second", unit_cents: 3.6,
  capabilities: ["i2v", "1080p", "5s"], max_latency_s: 900, min_plan: "free",
  same_model_as: "seedance_v1_pro_fast", privacy_tier: "trains_by_default", enabled: true };
const input: GenerateInput = { task: "video.reel_clip", prompt: "Guarded fixture camera movement.",
  image_url: "https://owned-fixture.invalid/byte-exact-source.jpg", seconds: 5, resolution: "1080p", aspect: "9:16" };

Deno.test("actual KIE owner QA payload matches its five-field schema and preserves source bytes URL", async () => {
  const fetchBefore = globalThis.fetch, keyBefore = Deno.env.get("KIE_API_KEY");
  const calls: {url: string; method: string; body: unknown}[] = [];
  Deno.env.set("KIE_API_KEY", "synthetic-offline-fixture");
  globalThis.fetch = ((url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), method: String(init?.method), body: JSON.parse(String(init?.body)) });
    return Promise.resolve(new Response(JSON.stringify({ code: 200, data: { taskId: "offline-owned-task" } }),
      { headers: { "content-type": "application/json" } }));
  }) as typeof fetch;
  try {
    const job = await kieAdapter.submit(step, input);
    assertEquals(calls, [{ url: "https://api.kie.ai/api/v1/jobs/createTask", method: "POST",
      body: { model: step.model, input: { prompt: input.prompt, image_url: input.image_url,
        resolution: "1080p", duration: "5", nsfw_checker: true } } }]);
    assertEquals(job.provider, "kie"); assertEquals(job.model, step.model); assertEquals(job.id, "offline-owned-task");
    assertEquals(job.poll_url, "https://api.kie.ai/api/v1/jobs/recordInfo?taskId=offline-owned-task");
    assert(!JSON.stringify(calls).includes("aspect_ratio"), "KIE schema does not support an aspect field");
  } finally { globalThis.fetch = fetchBefore; keyBefore === undefined ? Deno.env.delete("KIE_API_KEY") : Deno.env.set("KIE_API_KEY", keyBefore); }
});

Deno.test("actual KIE known model rejects unsupported durations/resolutions before vendor POST", async () => {
  const fetchBefore = globalThis.fetch; let calls = 0;
  globalThis.fetch = (() => { calls++; throw new Error("No vendor dispatch permitted"); }) as typeof fetch;
  try {
    const unsupported: Partial<GenerateInput>[] = [{seconds: 6}, {seconds: 12}, {resolution: "4k"}];
    for (const change of unsupported) {
      await assertRejects(() => kieAdapter.submit(step, { ...input, ...change }), ProviderError);
    }
    assertEquals(calls, 0);
  } finally { globalThis.fetch = fetchBefore; }
});

function pricedFixture() {
  const calls: { name: string; args: Record<string, unknown> }[] = []; let posts = 0;
  return { calls, posts: () => posts, deps: {
    rpc(name: string, args: Record<string, unknown>) {
      calls.push({name,args});
      if (name === "org_has_internal_testing_grant") return Promise.resolve({ data: false, error: null });
      if (name === "serving_cost_reserve" || name === "app_video_cost_reserve_v2") return Promise.resolve({ data: {reserved:true},error:null });
      if (name === "serving_cost_finish") return Promise.resolve({data:{finished:true},error:null});
      if (name === "app_video_cost_release_rejected") return Promise.resolve({data:{released:true},error:null});
      assertEquals(name,"app_video_cost_settle");return Promise.resolve({data:{settled:true},error:null});
    },
    submit(selected: RouteStep) { posts++; assertEquals(calls.at(-1)?.name,"serving_cost_reserve");
      return Promise.resolve({step:selected,value:{id:"owned-kie-request"},latency_ms:1}); },
  }};
}
const options = { actorId:"fixture-actor",orgId:"fixture-org",key:"owner-qa-price-fixture",
  feature:"reel" as const,steps:[step],seconds:5,input,listingId:"fixture-listing",
  allowance:{monthlyWindowStart:"2026-10-12T00:00:00Z",burstWindowStart:"2026-10-12T19:00:00Z"} };

Deno.test("actual KIE comparison holds and settles eighteen cents before exactly one paid submit", async () => {
  const f = pricedFixture(); const receipt = await submitReservedVideo(options, f.deps);
  assertEquals(f.posts(),1); assertEquals(receipt.step.provider,"kie");
  assertEquals(f.calls.filter(c=>c.name.endsWith("reserve")||c.name.endsWith("reserve_v2")).map(c=>({name:c.name,cents:c.args.p_hold_cents,provider:c.args.p_provider})),
    [{name:"app_video_cost_reserve_v2",cents:18,provider:"kie"},{name:"serving_cost_reserve",cents:18,provider:"kie"}]);
  assertEquals(f.calls.at(-1)?.name,"app_video_cost_settle");
  assertEquals(f.calls.at(-1)?.args.p_provider_request_id,"owned-kie-request");
});

const unverifiedCases: [string, Partial<Parameters<typeof submitReservedVideo>[0]>][] = [
  ["unverified model",{steps:[{...step,model:"unverified-other-model"}]}],
  ["unverified duration",{seconds:6,input:{...input,seconds:6}}],
  ["unverified resolution",{input:{...input,resolution:"720p"}}],
  ["unverified price",{steps:[{...step,unit_cents:0.1}]}],
];
for (const [label, change] of unverifiedCases) {
  Deno.test(`actual paid boundary refuses ${label} without owner sponsorship before dispatch`, async()=>{
    const f = pricedFixture(); await assertRejects(()=>submitReservedVideo({...options,...change},f.deps));
    assertEquals(f.posts(),0); assert(!f.calls.some(c=>c.name==="serving_cost_reserve"));
    assertEquals(f.calls.at(-1)?.name,"app_video_cost_release_rejected");
  });
}
