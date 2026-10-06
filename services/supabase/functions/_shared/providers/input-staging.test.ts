import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { ProviderError, publicImageUrlFor, stageInputImage } from "./common.ts";
import { hfInput } from "./higgsfield.ts";
import { kieAdapter } from "./kie.ts";
import type { RouteStep } from "../router.ts";

const step = (provider: string): RouteStep => ({route_id:"offline",task:"video.reel_clip",provider,model:provider==="kie"?"veo3":"bytedance/seedance/v1/pro/fast/image-to-video",unit:"second",unit_cents:1,capabilities:["i2v"],max_latency_s:60,min_plan:"free",same_model_as:null,privacy_tier:"retained_30d",enabled:true});
async function noTransport(work: () => Promise<void>) {
  const previous = globalThis.fetch; let transports = 0;
  globalThis.fetch = (() => { transports++; throw Error("No transport is permitted"); }) as typeof fetch;
  try { await work(); assertEquals(transports, 0, "Unowned input must never PUT or contact a provider"); }
  finally { globalThis.fetch = previous; }
}
Deno.test("actual inline staging refuses missing cleanup ownership before all transports", async () => {
  await noTransport(async () => {
    const error = await assertRejects(() => stageInputImage("QUFB", "image/jpeg"), ProviderError, "owned image URL");
    assertEquals(error.error_class, "validation"); assertEquals(error.status, 0); assertEquals(error.dispatch_rejected, true);
  });
});
Deno.test("actual provider URL helper refuses base64 and data URI before PUT", async () => {
  await noTransport(async () => {
    for (const input of [{image_b64:"QUFB"}, {image_url:"data:image/jpeg;base64,QUFB"}, {image_b64:"QUFB",extra:{org_id:"forged",user_id:"forged"}}]) {
      await assertRejects(() => publicImageUrlFor(input,"kie"), ProviderError, "cleanup ownership");
    }
  });
});
Deno.test("actual Kie and Higgsfield inline input refusal precedes vendor submit", async () => {
  await noTransport(async () => {
    const input={task:"video.reel_clip",prompt:"Synthetic",image_b64:"QUFB",image_url:"data:image/jpeg;base64,QUFB"};
    await assertRejects(() => kieAdapter.submit(step("kie"),input),ProviderError,"owned image URL");
    await assertRejects(() => hfInput(step("higgsfield"),input),ProviderError,"owned image URL");
  });
});
Deno.test("already owned header-free 600-second source capability remains byte-identical without staging", async () => {
  // Environment is synthetic; no remote call happens. Import a fresh actual
  // signer after setting only fixture credentials, then restore all values.
  const fixture:Record<string,string>={CLOUDFLARE_ACCOUNT_ID:"a".repeat(32),R2_ACCESS_KEY_ID:"b".repeat(32),R2_SECRET_ACCESS_KEY:"c".repeat(64)};
  const prior=Object.fromEntries(Object.keys(fixture).map(key=>[key,Deno.env.get(key)]));
  for(const [key,value] of Object.entries(fixture))Deno.env.set(key,value);
  try {
    const {presignGet}=await import(`./common.ts?owned-input=${crypto.randomUUID()}`);
    const signed=await presignGet("rendprop-uploads","uploads/owned/listing/image.jpg",600),url=new URL(signed);
    assertEquals(url.searchParams.get("X-Amz-Expires"),"600"); assertEquals(url.searchParams.get("X-Amz-SignedHeaders"),"host"); assert(url.searchParams.has("X-Amz-Signature"));
    await noTransport(async()=>assertEquals(await publicImageUrlFor({image_url:signed,image_b64:"QUFB"},"kie"),signed));
  } finally { for(const [key,value] of Object.entries(prior))value===undefined?Deno.env.delete(key):Deno.env.set(key,value); }
});
