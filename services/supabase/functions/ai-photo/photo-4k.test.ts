import { assert, assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
for(const key of ["SUPABASE_SECRET_KEYS","RENDPROP_SECRET_KEY_NAME","SUPABASE_PUBLISHABLE_KEYS","RENDPROP_PUBLISHABLE_KEY_NAME"])Deno.env.delete(key);
Deno.env.set("SUPABASE_URL","https://closed-fixture.invalid");Deno.env.set("SUPABASE_SERVICE_ROLE_KEY","closed-fixture-not-valid");Deno.env.set("SUPABASE_ANON_KEY","closed-fixture-not-valid");
const {preparePhoto4KInput,photo4KChain,assertPhoto4KOutput}=await import("./photo-quality.ts");
const {photo2KInputAllowance,photo4KInputAllowance}=await import("../_shared/photo-image-quality.ts");
const {geminiAdapter}=await import("../_shared/providers/gemini.ts");
const {mediaAttemptQuote,ceilingVerifiedQuote,fundedAttempt,boundedPhotoChain,resetServingModeCache,servingMode}=await import("../_shared/funded-serving.ts");
const {validatePhotoInput,validatePhotoOutput,PHOTO_OUTPUT_POLICY}=await import("./input-policy.ts");
const {HttpError}=await import("../_shared/http.ts");
const {ProviderError}=await import("../_shared/providers/common.ts");
import type {GenerateInput} from "../_shared/providers/types.ts";
import type {ChainStep} from "../_shared/router.ts";
import type {FundingContext} from "../_shared/funded-serving.ts";
// Complete structural JPEG fixtures establish guards/geometry, never image quality.
const jpeg=(width=1536,height=2048)=>btoa(String.fromCharCode(...[255,216,255,192,0,11,8,height>>8,height&255,width>>8,width&255,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]));
const input=(changes:Partial<GenerateInput>={}):GenerateInput=>({task:"photo.stage",prompt:"Add movable furniture only; retain installed items.",image_b64:jpeg(),extra:{image_mime:"image/jpeg"},...changes});
const step:ChainStep={route_id:"already-authorized",task:"photo.stage",position:1,provider:"gemini",model:"gemini-3.1-flash-image",unit:"output_image",unit_cents:6.7,capabilities:["fidelity"],max_latency_s:120,min_plan:"free",same_model_as:null,privacy_tier:"retained_30d",enabled:true,retire_after:null,params:null};

Deno.test("normal4K prices all complete input tiers at2520 image tokens and retains route/source authority",()=>{
 for(const [request,allowance,cents]of [[input(),8192,16.7584],[input({image_b64:jpeg(2048,256)}),16384,17.168],[input({image_b64:jpeg(128,2048)}),24576,17.5776],[input({prompt:"x".repeat(8192),extra:{image_mime:"image/jpeg",staging_reference_b64:jpeg(1024,768),staging_reference_mime:"image/jpeg"}}),24576,17.5776]]as const){
  const prepared=preparePhoto4KInput(request),routes=photo4KChain([{...step,provider:"fal",model:"flux-pro/kontext"},step,{...step,model:"gemini-3.1-flash-lite-image"}],prepared);
  assertEquals(prepared.image_b64,request.image_b64);assertEquals(prepared.prompt,request.prompt);assertEquals(prepared.extra?.staging_reference_b64,request.extra?.staging_reference_b64);
  assertEquals(prepared.extra?.photo_quality_2k,false);assertEquals(prepared.extra?.owner_photo_2k,undefined);assertEquals(photo4KInputAllowance(prepared),allowance);assertEquals(photo2KInputAllowance(prepared),null);
  assertEquals(routes.length,1);assertEquals(routes[0].route_id,step.route_id);assertEquals(routes[0].min_plan,step.min_plan);assertEquals(routes[0].privacy_tier,step.privacy_tier);assertEquals(routes[0].params,{image_size:"4K"});assertEquals(step.params,null);
  assertEquals(routes[0].unit_cents,cents);assertEquals(mediaAttemptQuote(routes[0],prepared)?.cents,cents);const hold=ceilingVerifiedQuote(routes[0],prepared,null)?.cents;assert(hold!==undefined&&hold>=cents&&hold-cents<0.00011);
  const lower={...routes[0],params:{image_size:"2K"}},unpinned={...routes[0],params:null};
  assertEquals(mediaAttemptQuote(lower,prepared),null);assertEquals(ceilingVerifiedQuote(unpinned,prepared,null),null);
 }
 for(const extra of [{photo_quality_4k:true},{photo_quality_4k:true,photo_input_allowance:8192,photo_input_token_bound:8193},{photo_quality_4k:true,photo_input_allowance:8193,photo_input_token_bound:4096},{photo_quality_4k:true,photo_input_allowance:8192,photo_input_token_bound:0},{photo_quality_4k:true,owner_photo_2k:true,photo_input_allowance:8192,photo_input_token_bound:4096},{photo_quality_4k:true,photo_quality_2k:true,photo_input_allowance:8192,photo_input_token_bound:4096}]){
  const unverified={...input(),extra};assertEquals(photo4KInputAllowance(unverified),null);assertEquals(mediaAttemptQuote({...step,params:{image_size:"4K"}} as ChainStep,unverified),null);
 }
 for(const bad of [input({image_b64:"broken"}),input({image_b64:jpeg(2049,1536)}),input({mask_url:"data:image/png;base64,AA=="}),input({prompt:"x".repeat(24577)})])assertThrows(()=>preparePhoto4KInput(bad),HttpError);
 assertThrows(()=>photo4KChain([{...step,model:"gemini-3.1-flash-lite-image"}],preparePhoto4KInput(input())),HttpError);
});

Deno.test("normal4K output accepts every official aspect but refuses2K, malformed and oversized output without widening inputs",()=>{
 for(const [w,h]of [[4096,4096],[2048,8192],[8192,2048],[1536,12288],[12288,1536],[3392,5056],[5056,3392],[3584,4800],[4800,3584],[3712,4608],[4608,3712],[3072,5504],[5504,3072],[6336,2688],[3584,4780]])assertPhoto4KOutput(jpeg(w,h),"image/jpeg");
 for(const [w,h]of [[1792,2390],[2048,2048],[896,1195],[4096,2048],[8192,8192],[16385,1]])assertThrows(()=>assertPhoto4KOutput(jpeg(w,h),"image/jpeg"),HttpError);
 for(const bad of ["broken",jpeg(4096,4096).slice(0,-4)])assertThrows(()=>assertPhoto4KOutput(bad,"image/jpeg"),HttpError);
 assertThrows(()=>validatePhotoInput(jpeg(12288,1536),"image/jpeg"),HttpError);
 assertEquals(validatePhotoOutput(jpeg(12288,1536),"image/jpeg").width,12288);
 assertThrows(()=>validatePhotoOutput("A".repeat(PHOTO_OUTPUT_POLICY.maxBase64Chars+4),"image/jpeg"),HttpError);
 // A full structural9MB JPEG is valid provider output. Its4096px edge still
 // exceeds the2048px source geometry limit; its byte size is allowed.
 // No compressed-image decoder/visual proof is implied.
 const frame=Uint8Array.from(atob(jpeg(4096,4096)),c=>c.charCodeAt(0)),parts:Uint8Array[]=[];let size=frame.length;
 while(size<9_000_000){const n=Math.min(65_000,9_000_000-size),part=new Uint8Array(n);part.set([255,224,(n-2)>>8,(n-2)&255]);parts.push(part);size+=n;}
 const bytes=new Uint8Array(size);bytes.set(frame.subarray(0,2));let offset=2;for(const part of parts){bytes.set(part,offset);offset+=part.length;}bytes.set(frame.subarray(2),offset);
 const pieces:string[]=[];for(let i=0;i<bytes.length;i+=32768)pieces.push(String.fromCharCode(...bytes.subarray(i,i+32768)));const b64=btoa(pieces.join(""));
 const decode=globalThis.atob,encode=globalThis.btoa;let calls=0;
 globalThis.atob=value=>{assert(value.length<=32768,"A4K check decoded a whole binary image string");calls++;return decode(value);};
 globalThis.btoa=()=>{throw Error("A4K check must validate pad bits without re-encoding the entire image");};
 try {assertPhoto4KOutput(b64,"image/jpeg");assert(calls>1,"The large image must exercise bounded decode chunks");}
 finally {globalThis.atob=decode;globalThis.btoa=encode;}
 assertThrows(()=>preparePhoto4KInput(input({image_b64:b64})),HttpError);
});

Deno.test("actual normal4K adapter holds the complete price before its only POST and refuses unpriced/denied dispatch",async()=>{
 const savedFetch=globalThis.fetch,savedKey=Deno.env.get("GEMINI_API_KEY");Deno.env.set("GEMINI_API_KEY","closed-never-valid");let mode="ceiling",posts=0;const events:string[]=[],bodies:Record<string,unknown>[]=[];
 globalThis.fetch=async(url,init)=>{if(!String(url).includes("generativelanguage.googleapis.com"))return Response.json(mode);events.push("POST");posts++;bodies.push(JSON.parse(String((init as RequestInit|undefined)?.body)));return Response.json({candidates:[{content:{parts:[{inlineData:{mimeType:"image/jpeg",data:jpeg(3584,4800)}}]}}]});};
 try{for(mode of ["ceiling","funded"]){resetServingModeCache();assertEquals(await servingMode(),mode);const prepared=preparePhoto4KInput(input()),route=photo4KChain([step],prepared)[0];let hold=0;
  const context:FundingContext={actorId:"closed-actor",orgId:"closed-org",requestKey:"4K-"+mode,rpc:async(name,args)=>{events.push(name);if(name==="serving_cost_reserve")hold=Number(args.p_hold_cents);return{data:name.startsWith("org_has_")?false:{reserved:true,finished:true},error:null};}};
  assertEquals((await boundedPhotoChain(context,[route],prepared)).length,1);
  if(mode==="funded")await assertRejects(()=>boundedPhotoChain(context,[{...route,task:"photo.custom"}],prepared),HttpError);
  const job=await fundedAttempt(context,"photo.stage:0",route,prepared,mediaAttemptQuote(route,prepared),()=>geminiAdapter.submit(route,prepared));assertEquals((await geminiAdapter.poll(job)).status,"done");assert(hold>=16.7584&&hold-16.7584<0.00021,`${mode}: complete hold ${hold}`);
  const body=bodies.at(-1)!;assertEquals((body.generationConfig as {imageConfig:unknown}).imageConfig,{imageSize:"4K"});assertEquals((body.contents as {parts:{inline_data?:{data:string}}[]}[])[0].parts[1].inline_data?.data,prepared.image_b64);
  for(const unpriced of [{...prepared,extra:{...prepared.extra,photo_input_token_bound:8193}},{...prepared,extra:{...prepared.extra,photo_quality_2k:true}}])await assertRejects(()=>geminiAdapter.submit(route,unpriced),ProviderError);
  await assertRejects(()=>geminiAdapter.submit({...route,params:null} as ChainStep,prepared),ProviderError);
  const denied:FundingContext={actorId:"closed",orgId:"closed",requestKey:"closed",rpc:async()=>({data:null,error:{message:"RP402: This attempt exceeds the shared funded serving allowance"}})};
  await assertRejects(()=>fundedAttempt(denied,"photo.stage:0",route,prepared,mediaAttemptQuote(route,prepared),()=>geminiAdapter.submit(route,prepared)),HttpError);
 }assertEquals(posts,2);const dispatched=events.filter(e=>e==="POST"||e==="serving_cost_reserve"||e==="serving_cost_finish");assertEquals(dispatched,["serving_cost_reserve","POST","serving_cost_finish","serving_cost_reserve","POST","serving_cost_finish"]);
 }finally{globalThis.fetch=savedFetch;resetServingModeCache();if(savedKey===undefined)Deno.env.delete("GEMINI_API_KEY");else Deno.env.set("GEMINI_API_KEY",savedKey);}
});

const encoded=(source:string)=>"data:application/typescript;base64,"+btoa(unescape(encodeURIComponent(source)));
const imports=(source:string,base:string)=>source.replace(/from "(\.\.?\/[^"]+)"/g,(_all,path)=>`from ${JSON.stringify(new URL(path,base).href)}`);
Deno.test("compiled4K under-reservation controls fail independent published-price oracles",async()=>{
 const prepared=preparePhoto4KInput(input({prompt:"x".repeat(5000)})),route=photo4KChain([step],prepared)[0],path=new URL("../_shared/funded-serving.ts",import.meta.url),source=await Deno.readTextFile(path);
 for(const [anchor,replacement,oracle]of [
  ["allowance*0.5+4096*3+2520*60","allowance*0.5+4096*3+1680*60",(m:Record<string,any>)=>assert(m.ceilingVerifiedQuote(route,prepared,null).cents>=17.168)],
  ["inputAllowance*.5+output*3+2520*60","inputAllowance*.5+output*3+1680*60",(m:Record<string,any>)=>assertEquals(m.mediaAttemptQuote(route,prepared).cents,17.168)],
 ]as const){assertEquals(source.split(anchor).length-1,1);const mutant=await import(encoded(imports(source.replace(anchor,replacement),path.href)));await assertRejects(async()=>oracle(mutant),Error);}
});
