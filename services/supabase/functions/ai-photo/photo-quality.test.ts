import { assert, assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
for(const key of ["SUPABASE_SECRET_KEYS","RENDPROP_SECRET_KEY_NAME","SUPABASE_PUBLISHABLE_KEYS","RENDPROP_PUBLISHABLE_KEY_NAME"])Deno.env.delete(key);
Deno.env.set("SUPABASE_URL","https://closed-fixture.invalid");Deno.env.set("SUPABASE_SERVICE_ROLE_KEY","closed-fixture-not-valid");Deno.env.set("SUPABASE_ANON_KEY","closed-fixture-not-valid");
const {preparePhoto2KInput,photo2KChain,assertPhoto2KOutput}=await import("./photo-quality.ts");
const {photo2KInputAllowance}=await import("../_shared/photo-image-quality.ts");
const {geminiAdapter}=await import("../_shared/providers/gemini.ts");
const {mediaAttemptQuote,ceilingVerifiedQuote,fundedAttempt,resetServingModeCache,servingMode}=await import("../_shared/funded-serving.ts");
const {HttpError}=await import("../_shared/http.ts");
const {ProviderError}=await import("../_shared/providers/common.ts");
import type {GenerateInput} from "../_shared/providers/types.ts";
import type {ChainStep} from "../_shared/router.ts";
import type {FundingContext} from "../_shared/funded-serving.ts";
const jpeg=(width=1536,height=2048)=>btoa(String.fromCharCode(...[255,216,255,192,0,11,8,height>>8,height&255,width>>8,width&255,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]));
const input=(changes:Partial<GenerateInput>={}):GenerateInput=>({task:"photo.stage",prompt:"Add movable furniture only; preserve all fixed finishes.",image_b64:jpeg(),extra:{image_mime:"image/jpeg"},...changes});
const step:ChainStep={route_id:"already-authorized",task:"photo.stage",position:1,provider:"gemini",model:"gemini-3.1-flash-image",unit:"output_image",unit_cents:6.7,capabilities:["fidelity"],max_latency_s:120,min_plan:"pro",same_model_as:null,privacy_tier:"retained_30d",enabled:true,retire_after:null,params:null};
Deno.test("normal2K input tiers preserve complete source and long brief/reference without owner grant",()=>{
 for(const [request,allowance,cents]of [[input(),8192,11.7184],[input({image_b64:jpeg(2048,256)}),16384,12.128],[input({image_b64:jpeg(128,2048)}),24576,12.5376],[input({prompt:"é".repeat(2400)}),16384,12.128],[input({prompt:"x".repeat(8192),extra:{image_mime:"image/jpeg",staging_reference_b64:jpeg(1024,768),staging_reference_mime:"image/jpeg"}}),24576,12.5376]]as const){
  const prepared=preparePhoto2KInput(request),chain=photo2KChain([step],prepared);assertEquals(prepared.image_b64,request.image_b64);assertEquals(prepared.prompt,request.prompt);assertEquals(prepared.extra?.staging_reference_b64,request.extra?.staging_reference_b64);
  assertEquals(prepared.extra?.photo_input_allowance,allowance);assertEquals(prepared.extra?.owner_photo_2k,undefined);assertEquals(photo2KInputAllowance(prepared),allowance);
  assertEquals(chain[0].unit_cents,cents);assertEquals(mediaAttemptQuote(chain[0],prepared)?.cents,cents);const held=ceilingVerifiedQuote(chain[0],prepared,null)?.cents;assert(held!==undefined&&held>=cents&&held-cents<0.00011);
 }
 for(const bad of [input({image_b64:"broken"}),input({image_b64:jpeg(2049,1536)}),input({mask_url:"data:image/png;base64,AA=="}),input({prompt:"x".repeat(24577)}),input({image_b64:jpeg(2048,64)})])assertThrows(()=>preparePhoto2KInput(bad),HttpError);
});
Deno.test("normal2K preserves route eligibility and cannot silently use lower-resolution fallback",()=>{
 const prepared=preparePhoto2KInput(input());
 const routes=photo2KChain([{...step,provider:"fal",model:"flux-pro/kontext"},step,{...step,model:"gemini-3.1-flash-lite-image"},{...step,provider:"openai",model:"gpt-image-2"}],prepared);
 assertEquals(routes.length,1);assertEquals(routes[0].route_id,step.route_id);assertEquals(routes[0].min_plan,"pro");assertEquals(routes[0].privacy_tier,step.privacy_tier);assertEquals(routes[0].params,{image_size:"2K"});assertEquals(step.params,null);
 assertThrows(()=>photo2KChain([{...step,model:"gemini-3.1-flash-lite-image"}],prepared),HttpError);assertThrows(()=>photo2KChain([step],input()),HttpError);
 for(const dimensions of [[2048,2048],[1792,2390],[2752,1536]])assertPhoto2KOutput(jpeg(...dimensions as [number,number]),"image/jpeg");
 for(const dimensions of [[896,1195],[2048,1536],[4096,4096]])assertThrows(()=>assertPhoto2KOutput(jpeg(...dimensions as [number,number]),"image/jpeg"),HttpError);
 for(const extra of [{photo_quality_2k:true},{photo_quality_2k:true,photo_input_allowance:8192,photo_input_token_bound:8193},{photo_quality_2k:true,photo_input_allowance:8193,photo_input_token_bound:4096},{photo_quality_2k:true,photo_input_allowance:8192,photo_input_token_bound:0}])assertEquals(photo2KInputAllowance({...input(),extra}),null);
});
Deno.test("actual normal2K adapter sends2K exact source only after its full priced hold",async()=>{
 const savedFetch=globalThis.fetch,savedKey=Deno.env.get("GEMINI_API_KEY");Deno.env.set("GEMINI_API_KEY","closed-never-valid");resetServingModeCache();let posts=0;const events:string[]=[],bodies:Record<string,unknown>[]=[];
 globalThis.fetch=async(url,init)=>{if(!String(url).includes("generativelanguage.googleapis.com"))return Response.json("ceiling");events.push("POST");posts++;bodies.push(JSON.parse(String((init as {body?:unknown}|undefined)?.body)));return Response.json({candidates:[{content:{parts:[{inlineData:{mimeType:"image/jpeg",data:jpeg(1792,2390)}}]}}]});};
 try{assertEquals(await servingMode(),"ceiling");for(const prompt of ["Add one sofa.","x".repeat(5000)]){
  const prepared=preparePhoto2KInput(input({prompt})),route=photo2KChain([step],prepared)[0];let held=0;
  const context:FundingContext={actorId:"closed-actor",orgId:"closed-org",requestKey:"case-"+posts,rpc:async(name,args)=>{events.push(name);if(name==="serving_cost_reserve")held=Number(args.p_hold_cents);return{data:{reserved:true,finished:true},error:null};}};
  const job=await fundedAttempt(context,"photo.stage:0",route,prepared,mediaAttemptQuote(route,prepared),()=>geminiAdapter.submit(route,prepared));assertEquals((await geminiAdapter.poll(job)).status,"done");assert(held>=route.unit_cents&&held-route.unit_cents<0.00011);
  assertEquals((bodies.at(-1)?.generationConfig as {imageConfig:unknown}).imageConfig,{imageSize:"2K"});assertEquals((bodies.at(-1)?.contents as {parts:{inline_data?:{data:string}}[]}[])[0].parts[1].inline_data?.data,prepared.image_b64);
 }
 assertEquals(events,["serving_cost_reserve","POST","serving_cost_finish","serving_cost_reserve","POST","serving_cost_finish"]);
 const prepared=preparePhoto2KInput(input()),route=photo2KChain([step],prepared)[0];
 await assertRejects(()=>geminiAdapter.submit(route,{...prepared,extra:{...prepared.extra,photo_input_token_bound:8193}}),ProviderError);assertEquals(posts,2);
 const denied:FundingContext={actorId:"closed",orgId:"closed",requestKey:"closed",rpc:async()=>({data:null,error:{message:"RP402: This attempt exceeds the shared funded serving allowance"}})};
 await assertRejects(()=>fundedAttempt(denied,"photo.stage:0",route,prepared,mediaAttemptQuote(route,prepared),()=>geminiAdapter.submit(route,prepared)),HttpError);assertEquals(posts,2,"Denied allowance reached provider POST");
 }finally{globalThis.fetch=savedFetch;resetServingModeCache();if(savedKey===undefined)Deno.env.delete("GEMINI_API_KEY");else Deno.env.set("GEMINI_API_KEY",savedKey);}
});
const encoded=(source:string)=>"data:application/typescript;base64,"+btoa(unescape(encodeURIComponent(source)));
const imports=(source:string,base:string)=>source.replace(/from "(\.\.?\/[^"]+)"/g,(_all,path)=>`from ${JSON.stringify(new URL(path,base).href)}`);
Deno.test("compiled normal2K source/tier/fallback/output guard removals fail independent oracles",async()=>{
 const path=new URL("./photo-quality.ts",import.meta.url),source=await Deno.readTextFile(path);
 const controls:[string,string,(module:Record<string,any>)=>void][]=[
 ["Math.max(image.width,image.height)>2048","false",m=>assertThrows(()=>m.preparePhoto2KInput(input({image_b64:jpeg(2049,1536)})),HttpError)],
 ["used<=cap","true",m=>assertEquals(m.preparePhoto2KInput(input({prompt:"x".repeat(5000)})).extra.photo_input_allowance,16384)],
 ["4096*Math.ceil((Math.max(image.width,image.height)/Math.min(image.width,image.height))/4)","4096",m=>assertEquals(m.preparePhoto2KInput(input({image_b64:jpeg(2048,256)})).extra.photo_input_allowance,16384)],
 ['step.provider==="gemini"&&step.model==="gemini-3.1-flash-image"','true',m=>assertEquals(m.photo2KChain([{...step,provider:"fal",model:"flux-pro/kontext"},step],preparePhoto2KInput(input())).length,1)],
 ["image.width*image.height<3_800_000","false",m=>assertThrows(()=>m.assertPhoto2KOutput(jpeg(896,1195),"image/jpeg"),HttpError)],
 ["image.width*image.height>4_800_000","false",m=>assertThrows(()=>m.assertPhoto2KOutput(jpeg(4096,4096),"image/jpeg"),HttpError)],
 ];for(const [anchor,replacement,oracle]of controls){assertEquals(source.split(anchor).length-1,1,anchor);const module=await import(encoded(imports(source.replace(anchor,replacement),path.href)));await assertRejects(async()=>oracle(module),Error);}
 console.log("NORMAL_PHOTO_2K_COMPILED_CONTROLS=6");
});

Deno.test("compiled normal2K quote under-reservation and unverified-tier acceptance fail independent oracles",async()=>{
 const prepared=preparePhoto2KInput(input({prompt:"x".repeat(5000)})),route=photo2KChain([step],prepared)[0];
 const path=new URL("../_shared/funded-serving.ts",import.meta.url),source=await Deno.readTextFile(path);
 for(const [anchor,replacement,oracle]of [
  ["allowance*0.5+4096*3+1680*60","allowance*0.5+4096*3+1120*60",(m:Record<string,any>)=>assert(m.ceilingVerifiedQuote(route,prepared,null).cents>=12.128,"Complete2K ceiling input/image liability")],
  ["inputAllowance*.5+output*3+1680*60","inputAllowance*.5+output*3+1120*60",(m:Record<string,any>)=>assertEquals(m.mediaAttemptQuote(route,prepared).cents,12.128)],
 ]as const){assertEquals(source.split(anchor).length-1,1);const module=await import(encoded(imports(source.replace(anchor,replacement),path.href)));await assertRejects(async()=>oracle(module),Error);}
 const boundPath=new URL("../_shared/photo-image-quality.ts",import.meta.url),boundSource=await Deno.readTextFile(boundPath),anchor="Number(used)<=Number(allowance)";assertEquals(boundSource.split(anchor).length-1,1);
 const mutant=await import(encoded(imports(boundSource.replace(anchor,"true"),boundPath.href)));
 await assertRejects(async()=>assertEquals(mutant.photo2KInputAllowance({...input(),extra:{photo_quality_2k:true,photo_input_allowance:8192,photo_input_token_bound:8193}}),null),Error);
 console.log("NORMAL_PHOTO_2K_QUOTE_COMPILED_CONTROLS=3");
});

Deno.test("aspect-scaled source allowance dominates official rough tiling and refuses excessive thin inputs",()=>{
 let accepted=0,refused=0;for(const width of [32,64,85,128,256,384,512,768,960,1024,1536,2048])for(const height of [32,64,85,128,256,384,512,540,768,1024,1536,2048]){
  const aspect=Math.max(width,height)/Math.min(width,height),imageBound=4096*Math.ceil(aspect/4);
  const crop=Math.floor(Math.min(width,height)/1.5),roughTokens=width<=384&&height<=384?258:Math.ceil(width/crop)*Math.ceil(height/crop)*258;
  assert(imageBound>=roughTokens,`${width}x${height}: local${imageBound} does not cover rough${roughTokens}`);
  const request=input({image_b64:jpeg(width,height),prompt:""});
  if(imageBound>24576){assertThrows(()=>preparePhoto2KInput(request),HttpError);refused++;}
  else{assertEquals(preparePhoto2KInput(request).extra?.photo_input_token_bound,imageBound);accepted++;}
 }assert(accepted>0&&refused>0);console.log(`NORMAL_PHOTO_2K_TILING_GEOMETRIES=${accepted+refused};ACCEPTED=${accepted};REFUSED=${refused}`);
});
