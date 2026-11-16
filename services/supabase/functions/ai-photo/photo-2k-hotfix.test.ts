import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { preparePhoto2KInput, photo2KChain, assertPhoto2KGeometry } from "./photo-quality.ts";
import { submitPreparedGeminiPhoto, geminiAdapter } from "../_shared/providers/gemini.ts";
import { ceilingVerifiedQuote, mediaAttemptQuote } from "../_shared/funded-serving.ts";
import { ProviderError, ProviderResponseLimitError } from "../_shared/providers/common.ts";
import { PHOTO_OUTPUT_MAX_WIRE_BYTES } from "../_shared/photo-output-policy.ts";
import type { GenerateInput } from "../_shared/providers/types.ts";
import type { ChainStep } from "../_shared/router.ts";

// Complete structural JPEG fixtures model the dimensions of an ordinary phone
// editing copy and a returned 2K portrait, without claiming visual quality.
const jpeg=(width:number,height:number)=>btoa(String.fromCharCode(...[
  255,216,255,192,0,11,8,height>>8,height&255,width>>8,width&255,1,1,17,0,
  255,218,0,8,1,1,0,0,63,0,1,255,217,
]));
const route:ChainStep={route_id:"stage-flash-route",task:"photo.stage",position:1,
  provider:"gemini",model:"gemini-3.1-flash-image",unit:"image",unit_cents:6.7,
  capabilities:["prompt-edit","fidelity"],max_latency_s:120,min_plan:"free",
  same_model_as:null,privacy_tier:"retained_30d",enabled:true,retire_after:null,
  params:null};
const input:GenerateInput={task:"photo.stage",prompt:"Remove movable clutter only.",
  image_b64:jpeg(1536,2048),extra:{image_mime:"image/jpeg"}};

Deno.test("ordinary phone photo is pinned, priced and delivered as 2K without a paid retry",async()=>{
 const prepared=preparePhoto2KInput(input),step=photo2KChain([route],prepared)[0];
 assertEquals(prepared.image_b64,input.image_b64);
 assertEquals(step.params.image_size,"2K");
 assertEquals(mediaAttemptQuote(step,prepared)?.cents,11.7184);
 const ceiling=ceilingVerifiedQuote(step,prepared,null)?.cents;
 assert(ceiling!==undefined&&ceiling>=11.7184&&ceiling<=11.7185);
 const oldFetch=globalThis.fetch,oldKey=Deno.env.get("GEMINI_API_KEY");
 Deno.env.set("GEMINI_API_KEY","closed-test-key");let posts=0;
 globalThis.fetch=async(_url,init)=>{
  posts++;
  const body=JSON.parse(String((init as globalThis.RequestInit)?.body));
  assertEquals(body.generationConfig.imageConfig,{imageSize:"2K"});
  assertEquals(body.contents[0].parts[1].inline_data.data,prepared.image_b64);
  return Response.json({candidates:[{content:{parts:[{inlineData:{
   mimeType:"image/jpeg",data:jpeg(1792,2400),
  }}]}}]});
 };
 try{
  const budget={deadline:Date.now()+30_000,signal:new AbortController().signal};
  const ref=await submitPreparedGeminiPhoto(step,prepared,budget);
  assertEquals((await geminiAdapter.poll(ref)).status,"done");
  assertPhoto2KGeometry({width:1792,height:2400});
  await assertRejects(()=>submitPreparedGeminiPhoto(step,{...prepared,
   extra:{...prepared.extra,photo_quality_2k:false}},budget),ProviderError);
  assertEquals(posts,1,"No unpriced request or automatic paid retry");
 }finally{
  globalThis.fetch=oldFetch;
  if(oldKey===undefined)Deno.env.delete("GEMINI_API_KEY");else Deno.env.set("GEMINI_API_KEY",oldKey);
 }
});

Deno.test("2K provider response still has a bounded reader and never retries oversized wire data",async()=>{
 const prepared=preparePhoto2KInput(input),step=photo2KChain([route],prepared)[0];
 const oldFetch=globalThis.fetch,oldKey=Deno.env.get("GEMINI_API_KEY");
 Deno.env.set("GEMINI_API_KEY","closed-test-key");let posts=0;
 globalThis.fetch=async()=>{posts++;return new Response("oversize",{
  headers:{"content-length":String(PHOTO_OUTPUT_MAX_WIRE_BYTES+1)},
 });};
 try{
  await assertRejects(()=>submitPreparedGeminiPhoto(step,prepared,{
   deadline:Date.now()+30_000,signal:new AbortController().signal,
  }),ProviderResponseLimitError);
  assertEquals(posts,1);
 }finally{
  globalThis.fetch=oldFetch;
  if(oldKey===undefined)Deno.env.delete("GEMINI_API_KEY");else Deno.env.set("GEMINI_API_KEY",oldKey);
 }
});
