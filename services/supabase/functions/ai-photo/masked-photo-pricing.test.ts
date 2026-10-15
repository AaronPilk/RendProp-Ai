import {assert,assertEquals,assertRejects,assertThrows} from "https://deno.land/std@0.224.0/assert/mod.ts";
for(const key of ["SUPABASE_SECRET_KEYS","RENDPROP_SECRET_KEY_NAME","SUPABASE_PUBLISHABLE_KEYS","RENDPROP_PUBLISHABLE_KEY_NAME"])Deno.env.delete(key);
Deno.env.set("SUPABASE_URL","https://closed-mask-fixture.invalid");Deno.env.set("SUPABASE_SERVICE_ROLE_KEY","closed-fixture-not-valid");Deno.env.set("SUPABASE_ANON_KEY","closed-fixture-not-valid");
const {priceMaskedPhotoChain}=await import("./masked-photo-pricing.ts");
const {ceilingVerifiedQuote,fundedAttempt,mediaAttemptQuote,resetServingModeCache}=await import("../_shared/funded-serving.ts");
const {falInput}=await import("../_shared/providers/fal.ts");
const {paramsOf}=await import("../_shared/router.ts");
const {HttpError}=await import("../_shared/http.ts");
import type {ChainStep} from "../_shared/router.ts";
import type {GenerateInput} from "../_shared/providers/types.ts";
import type {FundingContext} from "../_shared/funded-serving.ts";
// Structural container fixtures check price/geometry, never visual quality.
const jpeg=(w:number,h:number)=>btoa(String.fromCharCode(...[255,216,255,224,0,34,...new Array(32).fill(0),255,192,0,11,8,h>>8,h&255,w>>8,w&255,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]));
const input=(w:number,h:number):GenerateInput=>{const b64=jpeg(w,h);return{task:"photo.declutter",prompt:"Remove loose clutter; retain fixed features.",image_b64:b64,image_url:"data:image/jpeg;base64,"+b64,mask_url:"data:image/jpeg;base64,"+b64,extra:{image_mime:"image/jpeg",mask_mime:"image/jpeg"}};};
const step:ChainStep={route_id:"existing-fill",task:"photo.declutter",position:1,retire_after:null,provider:"fal",model:"fal-ai/flux-pro/v1/fill",unit:"image",unit_cents:5,capabilities:["mask"],max_latency_s:120,min_plan:"free",same_model_as:null,privacy_tier:"retained_30d",enabled:true,params:null};
Deno.test("masked Fill rounds per-megapixel boundaries and preserves authorized route/payload",()=>{
 for(const [width,height,cents]of [[1000,1000,5],[1001,1000,10],[1536,2048,20],[2048,2048,25]]){
  for(const model of ["fal-ai/flux-pro/v1/fill","flux-pro/v1/fill"]){
   const source=input(width,height),original={...step,model},other={...step,route_id:"different-model",model:"flux-pro/kontext",unit_cents:4};
   const priced=priceMaskedPhotoChain([original,other],source);
   assertEquals(priced[0].unit_cents,cents);assertEquals(priced[0].unit,"image");
   assertEquals(priced[0].route_id,original.route_id);assertEquals(priced[0].privacy_tier,original.privacy_tier);assertEquals(priced[0].capabilities,original.capabilities);assertEquals(paramsOf(priced[0]),original.params);
   assertEquals(priced[1],other);assertEquals(original.unit_cents,5,"Do not mutate a cached route shared by another request");
   const hold=ceilingVerifiedQuote(priced[0],source,mediaAttemptQuote(priced[0],source));
   assert(hold!==null&&hold.cents>=cents&&hold.cents-cents<0.00011,"Ledger price must equal the independently documented complete ceiling hold");
   assertEquals(falInput(priced[0],source),{prompt:source.prompt,image_url:source.image_url,mask_url:source.mask_url});
  }
 }
 const noMask={...input(1536,2048),mask_url:undefined,image_b64:"invalid-not-used"};const routes=[step];
 assertEquals(priceMaskedPhotoChain(routes,noMask),routes);
 assertThrows(()=>priceMaskedPhotoChain(routes,{...input(1,1),image_b64:"broken"}),HttpError);
});
Deno.test("ordinary ceiling masked Fill reserves complete20-cent liability before dispatch and refuses denied admission",async()=>{
 const saved=globalThis.fetch;globalThis.fetch=()=>Promise.resolve(Response.json("ceiling"));resetServingModeCache();
 try{
  const source=input(1536,2048),route=priceMaskedPhotoChain([step],source)[0],events:string[]=[];let hold=0,dispatched=0;
  const context:FundingContext={actorId:"ordinary-fixture",orgId:"ordinary-org",requestKey:"masked-price-fixture",rpc:async(name,args)=>{
   events.push(name);if(name==="serving_cost_reserve")hold=Number(args.p_hold_cents);
   return{data:{reserved:true,finished:true},error:null};
  }};
  await fundedAttempt(context,"photo.declutter:0",route,source,mediaAttemptQuote(route,source),async()=>{
   events.push("provider-dispatch");dispatched++;assert(hold>=20&&hold-20<0.00011);return{confirmed:true};
  });
  assertEquals(events,["serving_cost_reserve","provider-dispatch","serving_cost_finish"]);assertEquals(dispatched,1);
  const denied:FundingContext={...context,rpc:async()=>({data:null,error:{message:"RP402: AI usage limit reached [kind=free]"}})};
  await assertRejects(()=>fundedAttempt(denied,"photo.declutter:0",route,source,mediaAttemptQuote(route,source),async()=>{dispatched++;return{};}),HttpError);
  assertEquals(dispatched,1,"Insufficient ordinary envelope cannot dispatch a paid mask call");
 }finally{globalThis.fetch=saved;resetServingModeCache();}
});
