import { assert, assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { parseReelFraming, reelStepPreservesPhoto, reelFramingSteps, buildPhotoPreservingReelPrompt,buildPropertyCanvasReelPrompt,buildSteadyPropertyReelPrompt } from "./reel-framing.ts";
import { HttpError } from "../_shared/http.ts";
import { ProviderError } from "../_shared/providers/common.ts";
import { falInput, falAdapter, FAL_OBJECT_LIFECYCLE_HEADER, FAL_OBJECT_LIFECYCLE_VALUE } from "../_shared/providers/fal.ts";
import { kieAdapter } from "../_shared/providers/kie.ts";
import { submitReservedVideo } from "./cost-reservation.ts";
import type { RouteStep } from "../_shared/router.ts";
import type { GenerateInput } from "../_shared/providers/types.ts";

const step: RouteStep & {params: Record<string, unknown>} = {route_id:"closed-owner-kling",task:"video.reel_clip",provider:"kie",model:"kling-3.0/video",
  unit:"second",unit_cents:9,capabilities:["i2v","1080p","5s"],max_latency_s:900,min_plan:"free",
  same_model_as:"kling_3_pro",privacy_tier:"trains_by_default",enabled:true,params:{kie_mode:"pro",sound:false}};
const input: GenerateInput = {task:"video.reel_clip",prompt:"Exact full photo. Physical shallow camera track, fixed lens.",
  image_url:"https://owned-fixture.invalid/full-photo.jpg",seconds:5,resolution:"1080p",aspect:"9:16",
  framing:"preserve_photo",extra:{kie_mode:"pro",sound:false}};
const encode=(s:string)=>"data:application/typescript;base64,"+btoa(String.fromCharCode(...new TextEncoder().encode(s)));
function imports(s:string, file:string) {return s.replace(/from "(\.\.?\/[^\"]+)"/g,(_all,path)=>`from ${JSON.stringify(new URL(path,new URL(file,import.meta.url)).href)}`);}

Deno.test("full-photo framing is explicit, legacy compatible and restricted to capable models",()=>{
  assertEquals(parseReelFraming(undefined),undefined);assertEquals(parseReelFraming("preserve_photo"),"preserve_photo");
  for(const value of [null,"auto","crop",{},true,0])assertThrows(()=>parseReelFraming(value),HttpError);
  const legacy={...step,provider:"fal" as const,model:"fal-ai/bytedance/seedance/v1/pro/fast/image-to-video"};
  const unsupported={...step,model:"bytedance/v1-pro-fast-image-to-video"};
  assert(reelStepPreservesPhoto(step));assert(reelStepPreservesPhoto(legacy));assert(!reelStepPreservesPhoto(unsupported));
  const chain=[unsupported,legacy,step];assertEquals(reelFramingSteps(chain),chain);
  assertEquals(reelFramingSteps(chain,"preserve_photo"),[legacy,step]);
  assertThrows(()=>reelFramingSteps([unsupported],"preserve_photo"),HttpError,"Photo-preserving motion is unavailable");
  for(const change of [{provider:"openai"},{provider:"gemini"},{model:"arbitrary/model"}])assert(!reelStepPreservesPhoto({...step,...change} as RouteStep));
});

Deno.test("whole-photo prompts require complete original framing and physical fixed-lens moves",()=>{
  for(const motion of ["fly_through","push_in","side_glide","pull_back"] as const){
    const text=buildPhotoPreservingReelPrompt("home",motion);
    for(const lock of ["entire supplied photograph","original aspect ratio","wide scene","delivery canvas will be added separately","No added or removed objects"]){assert(text.includes(lock),motion+": "+lock);}
    assert(new TextEncoder().encode(text).length<4096);
  }
  const fly=buildPhotoPreservingReelPrompt("home","fly_through");
  assert(fly.includes("camera body translates") && fly.includes("Do not imitate travel with a digital zoom"));
});

async function capturedSubmit(adapter=kieAdapter,selected=step,value=input){
  const oldFetch=globalThis.fetch,oldKey=Deno.env.get("KIE_API_KEY");const calls:{url:string;method:string;body:any}[]=[];
  Deno.env.set("KIE_API_KEY","offline-fixture-key");
  globalThis.fetch=((url:string|URL|Request,init?:RequestInit)=>{calls.push({url:String(url),method:String(init?.method),body:JSON.parse(String(init?.body))});return Promise.resolve(new Response(JSON.stringify({code:200,data:{taskId:"closed-owned-task"}}),{headers:{"content-type":"application/json"}}));}) as typeof fetch;
  try{return {calls,job:await adapter.submit(selected,value)}}finally{globalThis.fetch=oldFetch;oldKey===undefined?Deno.env.delete("KIE_API_KEY"):Deno.env.set("KIE_API_KEY",oldKey);}
}
Deno.test("actual Kling Pro preserves full-source auto fields for both delivery formats",async()=>{
  for (const aspect of ["9:16","16:9"] as const) {
    const result=await capturedSubmit(kieAdapter,step,{...input,aspect});
    assertEquals(result.calls,[{url:"https://api.kie.ai/api/v1/jobs/createTask",method:"POST",body:{model:"kling-3.0/video",input:{prompt:input.prompt,image_urls:[input.image_url],sound:false,duration:"5",mode:"pro",multi_shots:false}}}]);
    assertEquals([result.job.id,result.job.provider,result.job.model],["closed-owned-task","kie",step.model]);
    assert(!JSON.stringify(result.calls).includes("aspect_ratio")&&!JSON.stringify(result.calls).includes('"resolution"'));
  }
});
Deno.test("actual Kling adapter refuses unsupported task, framing, mode, sound, duration and shape before POST",async()=>{
  const oldFetch=globalThis.fetch;let posts=0;globalThis.fetch=(()=>{posts++;throw Error("No vendor request permitted");}) as typeof fetch;
  try{
    const changes:Partial<GenerateInput>[]=[{task:"video.aerial"},{seconds:6},{resolution:"720p"},{framing:undefined},{extra:{kie_mode:"standard",sound:false}},{extra:{kie_mode:"pro",sound:true}},{extra:{kie_mode:"pro"}},{image_url:undefined}];
    for(const change of changes)await assertRejects(()=>kieAdapter.submit(step,{...input,...change}),ProviderError);
    await assertRejects(()=>kieAdapter.submit({...step,model:"bytedance/v1-pro-fast-image-to-video"},input),ProviderError);
    assertEquals(posts,0);
  }finally{globalThis.fetch=oldFetch;}
});
function funded(){
  const calls:{name:string;args:Record<string,unknown>}[]=[];let posts=0;
  return {calls,posts:()=>posts,deps:{
    rpc(name:string,args:Record<string,unknown>){calls.push({name,args});
      if(name==="org_has_internal_testing_grant")return Promise.resolve({data:false,error:null});
      if(name==="serving_cost_reserve"||name==="app_video_cost_reserve_v2")return Promise.resolve({data:{reserved:true},error:null});
      if(name==="serving_cost_finish")return Promise.resolve({data:{finished:true},error:null});
      if(name==="app_video_cost_release_rejected")return Promise.resolve({data:{released:true},error:null});
      assertEquals(name,"app_video_cost_settle");return Promise.resolve({data:{settled:true},error:null});},
    submit(selected:RouteStep){posts++;assertEquals(calls.at(-1)?.name,"serving_cost_reserve");return Promise.resolve({step:selected,value:{id:"owned-kling-task"},latency_ms:1});},
  }};
}
const options={actorId:"closed-actor",orgId:"closed-org",key:"closed-kling-key",feature:"reel" as const,steps:[step],seconds:5,input,listingId:"closed-listing",allowance:{monthlyWindowStart:"2026-10-12T00:00:00Z",burstWindowStart:"2026-10-12T23:00:00Z"}};
const fal4K:RouteStep={...step,route_id:"closed-owner-fal-kling4k",provider:"fal",model:"fal-ai/kling-video/v3/4k/image-to-video",unit_cents:42,privacy_tier:"retained_30d"};
const fal4KInput:GenerateInput={...input,extra:undefined};
Deno.test("actual Kling admission reserves45 cents in both authorities before exactly one submit and settles owned receipt",async()=>{
  const f=funded();await submitReservedVideo(options,f.deps);assertEquals(f.posts(),1);
  assertEquals(f.calls.filter(x=>x.name.endsWith("reserve")||x.name.endsWith("reserve_v2")).map(x=>({name:x.name,cents:x.args.p_hold_cents})),[{name:"app_video_cost_reserve_v2",cents:45},{name:"serving_cost_reserve",cents:45}]);
  assertEquals(f.calls.at(-1)?.name,"app_video_cost_settle");assertEquals(f.calls.at(-1)?.args.p_provider_request_id,"owned-kling-task");
  for(const changed of [{...input,seconds:6},{...input,resolution:"720p"},{...input,framing:undefined},{...input,extra:{kie_mode:"standard",sound:false}},{...input,extra:{kie_mode:"pro",sound:true}}]){
    const no=funded();await assertRejects(()=>submitReservedVideo({...options,input:changed},no.deps));assertEquals(no.posts(),0);assert(!no.calls.some(x=>x.name==="serving_cost_reserve"));
  }
  const no=funded();await assertRejects(()=>submitReservedVideo({...options,steps:[{...step,unit_cents:3.6}]},no.deps));assertEquals(no.posts(),0);
});
Deno.test("actual4K Kling wire and both funded authorities bind67credits per second before one submit",async()=>{
 const selected={...step,unit_cents:33.5,params:{kie_mode:"4K",sound:false}};
 const value={...input,extra:{kie_mode:"4K",sound:false}};
 const wire=await capturedSubmit(kieAdapter,selected,value);
 assertEquals(wire.calls[0].body.input.mode,"4K");assertEquals(wire.calls[0].body.input.sound,false);
 const f=funded();await submitReservedVideo({...options,steps:[selected],input:value},f.deps);
 assertEquals(f.posts(),1);assertEquals(f.calls.filter(x=>x.name.endsWith("reserve")||x.name.endsWith("reserve_v2")).map(x=>x.args.p_hold_cents),[167.5,167.5]);
 for(const [route,request]of [[{...selected,unit_cents:9},value],[selected,input],[selected,{...value,extra:{kie_mode:"4K",sound:true}}]]as const){const no=funded();await assertRejects(()=>submitReservedVideo({...options,steps:[route],input:request},no.deps));assertEquals(no.posts(),0);assert(!no.calls.some(x=>x.name==="serving_cost_reserve"));}
 const source=await Deno.readTextFile(new URL("./cost-reservation.ts",import.meta.url));
 const needle='quote = {cents: Math.max(hold, 167.5),version:TARIFF_VERSION};';assertEquals(source.split(needle).length,2);
 const mutant=await import(encode(imports(source.replace(needle,'quote = {cents: 45,version:TARIFF_VERSION};'),"./cost-reservation.ts")));
 const wrong=funded();await mutant.submitReservedVideo({...options,steps:[selected],input:value},wrong.deps);assertEquals(wrong.calls.find(x=>x.name==="serving_cost_reserve")?.args.p_hold_cents,45,"Independent money oracle detects an underfunded4K quote");
});
Deno.test("compiled framing, payload and money controls expose lost crop, sound and hold contracts",async()=>{
  const framingSource=await Deno.readTextFile(new URL("./reel-framing.ts",import.meta.url));
  const filter='const eligible = steps.filter(reelStepPreservesPhoto);';assertEquals(framingSource.split(filter).length,2);
  const framingMutant=await import(encode(imports(framingSource.replace(filter,'const eligible = steps;'),"./reel-framing.ts")));
  assertEquals(framingMutant.reelFramingSteps([{...step,model:"bytedance/v1-pro-fast-image-to-video"}],"preserve_photo").length,1,"Compiled unsupported framing control must expose the leak");
  const adapterSource=await Deno.readTextFile(new URL("../_shared/providers/kie.ts",import.meta.url));
  for(const [needle,replacement,field,wrong] of [['jobInput.sound = false;','jobInput.sound = true;','sound',true],['jobInput.mode = "pro";','jobInput.mode = "standard";','mode','standard'],['jobInput.multi_shots = false;','jobInput.multi_shots = true;','multi_shots',true]] as const){
    assertEquals(adapterSource.split(needle).length,2);const mutant=await import(encode(imports(adapterSource.replace(needle,replacement),"../_shared/providers/kie.ts")));
    const result=await capturedSubmit(mutant.kieAdapter);assertEquals(result.calls[0].body.input[field],wrong,"Compiled payload control must expose the selected contract breach");
  }
  const costSource=await Deno.readTextFile(new URL("./cost-reservation.ts",import.meta.url));const quote='quote = {cents: Math.max(hold, 45),version:TARIFF_VERSION};';assertEquals(costSource.split(quote).length,2);
  const costMutant=await import(encode(imports(costSource.replace(quote,'quote = {cents: 18,version:TARIFF_VERSION};'),"./cost-reservation.ts")));
  const f=funded();await costMutant.submitReservedVideo(options,f.deps);assertEquals(f.calls.find(x=>x.name==="serving_cost_reserve")?.args.p_hold_cents,18,"Compiled hold control must reveal the underreservation");
  console.log("PHOTO_FRAMING_COMPILED_CONTROLS=5");
});

Deno.test("actual FAL Seedance preserves both legacy aspects and sends source-auto for either full-photo delivery",()=>{
  const fal={...step,provider:"fal",model:"fal-ai/bytedance/seedance/v1/pro/fast/image-to-video"};
  for (const aspect of ["9:16","16:9"] as const) {
    const source={...input,aspect};
    const preserved=falInput(fal,source);
    assertEquals(preserved.aspect_ratio,"auto");assertEquals(preserved.image_url,input.image_url);
    assertEquals(preserved.resolution,"1080p");assertEquals(preserved.duration,"5");
    assertEquals(preserved.num_frames,121);assertEquals(preserved.camera_fixed,false);
    assertEquals(falInput(fal,{...source,framing:undefined}).aspect_ratio,aspect);
  }
  assertThrows(()=>falInput({...fal,model:"fal-ai/veo3.1/fast/image-to-video"},input),ProviderError);
});

Deno.test("server background targetcanvas reaches actualKlingPro andFAL1080 schemas, old native remains sourceauto",async()=>{
 for(const aspect of['16:9','9:16']as const){const targeted={...input,aspect,extra:{...input.extra,property_video_target_aspect:aspect}};const r=await capturedSubmit(kieAdapter,step,targeted);assertEquals(r.calls[0].body.input.aspect_ratio,aspect);assertEquals(r.calls[0].body.input.mode,'pro');assertEquals(r.calls[0].body.input.duration,'5');assertEquals(r.calls[0].body.input.image_urls,[input.image_url]);const f=falInput({...step,provider:'fal',model:'bytedance/seedance/v1/pro/fast/image-to-video'},targeted);assertEquals(f.aspect_ratio,aspect);assertEquals(f.resolution,'1080p');assertEquals(f.image_url,input.image_url);assertEquals(f.duration,'5');}
 const legacy=falInput({...step,provider:'fal',model:'bytedance/seedance/v1/pro/fast/image-to-video'},input);assertEquals(legacy.aspect_ratio,'auto');assertThrows(()=>falInput({...step,provider:'fal',model:'bytedance/seedance/v1/pro/fast/image-to-video'},{...input,extra:{property_video_target_aspect:'16:9'}}),ProviderError);await assertRejects(()=>capturedSubmit(kieAdapter,step,{...input,extra:{...input.extra,property_video_target_aspect:'16:9'}}),ProviderError);
});

Deno.test("FAL native4K builds the exact silent five-second source-aspect wire for both destination canvases",async()=>{
 const previousFetch=globalThis.fetch,previousKey=Deno.env.get("FAL_KEY");Deno.env.set("FAL_KEY","offline-fal-fixture-key");
 const requests:{url:string;body:unknown;lifecycle:string|null}[]=[];
 globalThis.fetch=((url:string|URL|Request,init?:RequestInit)=>{
  requests.push({url:String(url),body:JSON.parse(String(init?.body)),lifecycle:new Headers(init?.headers).get(FAL_OBJECT_LIFECYCLE_HEADER)});
  return Promise.resolve(new Response(JSON.stringify({request_id:"owned-fal4k-request",status_url:"https://queue.fal.run/fal-ai/kling-video/requests/owned-fal4k-request/status",response_url:"https://queue.fal.run/fal-ai/kling-video/requests/owned-fal4k-request"}),{headers:{"content-type":"application/json"}}));
 })as typeof fetch;
 try{
  assert(reelStepPreservesPhoto(fal4K));
  for(const aspect of["16:9","9:16"]as const)for(const image_url of[input.image_url!,"data:image/jpeg;base64,c2FtZS1vd25lZC1waG90bw=="]){
   const value={...fal4KInput,aspect,image_url,extra:{property_video_target_aspect:aspect}};
   const job=await falAdapter.submit(fal4K,value);
   assertEquals([job.provider,job.model,job.id],["fal",fal4K.model,"owned-fal4k-request"]);
   assertEquals(requests.at(-1),{url:"https://queue.fal.run/fal-ai/kling-video/v3/4k/image-to-video",body:{prompt:value.prompt,start_image_url:image_url,duration:"5",generate_audio:false},lifecycle:FAL_OBJECT_LIFECYCLE_VALUE});
  }
  assertEquals(requests.length,4,"One POST per validated request, no API fallback or extra upload");
 }finally{globalThis.fetch=previousFetch;previousKey===undefined?Deno.env.delete("FAL_KEY"):Deno.env.set("FAL_KEY",previousKey);}
});

Deno.test("FAL native4K refuses unsupported task, framing, duration, resolution, source and mismatched target before HTTP",async()=>{
 const previousFetch=globalThis.fetch;let posts=0;globalThis.fetch=(()=>{posts++;throw Error("No provider call permitted");})as typeof fetch;
 try{
  for(const change of[{task:"video.aerial"},{framing:undefined},{seconds:6},{seconds:4.99},{resolution:"720p"},{aspect:"1:1"},{image_url:undefined},{image_url:"file:///private/photo.jpg"},{image_url:"data:text/plain;base64,YWJj"},{extra:{property_video_target_aspect:"16:9"}}]as Partial<GenerateInput>[])
   await assertRejects(()=>falAdapter.submit(fal4K,{...fal4KInput,...change}),ProviderError);
  for(const model of["fal-ai/kling-video/v3/pro/image-to-video","fal-ai/kling-video/o3/4k/image-to-video","arbitrary/kling-video/v3/4k/image-to-video"]){
   assert(!reelStepPreservesPhoto({...fal4K,model}));await assertRejects(()=>falAdapter.submit({...fal4K,model},fal4KInput),ProviderError);
  }
  assertEquals(posts,0);
 }finally{globalThis.fetch=previousFetch;}
});

Deno.test("FAL native4K reserves exactly210c in both funding authorities before one submit; no sponsorship or underpriced Pro quote",async()=>{
 const f=funded();await submitReservedVideo({...options,steps:[fal4K],input:fal4KInput},f.deps);
 assertEquals(f.posts(),1);
 assertEquals(f.calls.filter(x=>x.name.endsWith("reserve")||x.name.endsWith("reserve_v2")).map(x=>({name:x.name,hold:x.args.p_hold_cents,provider:x.args.p_provider,model:x.args.p_model})),[
  {name:"app_video_cost_reserve_v2",hold:210,provider:"fal",model:fal4K.model},{name:"serving_cost_reserve",hold:210,provider:"fal",model:fal4K.model}]);
 assertEquals(f.calls.at(-1)?.name,"app_video_cost_settle");
 for(const [route,value]of [[{...fal4K,unit_cents:14},fal4KInput],[{...fal4K,model:"fal-ai/kling-video/v3/pro/image-to-video"},fal4KInput],[fal4K,{...fal4KInput,framing:undefined}],[fal4K,{...fal4KInput,seconds:6}],[fal4K,{...fal4KInput,resolution:"720p"}]]as const){
  const refused=funded();await assertRejects(()=>submitReservedVideo({...options,steps:[route],input:value},refused.deps));assertEquals(refused.posts(),0);assert(!refused.calls.some(x=>x.name==="serving_cost_reserve"));
 }
 const source=await Deno.readTextFile(new URL("./cost-reservation.ts",import.meta.url)),needle='quote = {cents: Math.max(hold, 210),version:TARIFF_VERSION};';assertEquals(source.split(needle).length,2);
 const mutant=await import(encode(imports(source.replace(needle,'quote = {cents: 45,version:TARIFF_VERSION};'),"./cost-reservation.ts")));
 const wrong=funded();await mutant.submitReservedVideo({...options,steps:[fal4K],input:fal4KInput},wrong.deps);
 assertEquals(wrong.calls.find(x=>x.name==="serving_cost_reserve")?.args.p_hold_cents,45,"Independent oracle detects a compiled underfunded4K serving hold");
});

Deno.test("prospective steady prompts use closed motorized moves and preserve property and v1 bytes",async()=>{
 const {assertFairHousing,GUARDRAILS}=await import('../_shared/fairhousing.ts');
 const expected=['forward-right slider','straight forward microdolly','rightward motorized slider','straight backward microdolly'];
 for(const [i,motion]of(['fly_through','push_in','side_glide','pull_back']as const).entries())for(const aspect of['16:9','9:16']as const){
  const text=buildSteadyPropertyReelPrompt('home',motion,aspect);
  for(const term of[expected[i],'five-second','constant speed','constant height','fixed orientation','fixed focal length','Preserve the property geometry','every object unchanged and stationary','entire supplied photograph at its original aspect ratio and composition','delivery canvas will be cropped separately'])assert(text.includes(term),term);
  assert(!/1080|native|16:9|9:16/.test(text),'Generation preserves the supplied photo; canvas geometry is a compositor contract');
  assertEquals(text,buildSteadyPropertyReelPrompt('home',motion,aspect==='16:9'?'9:16':'16:9'));
  assert(!/drone|walk|travers|connected rooms/i.test(text));
  assert(text.endsWith(GUARDRAILS));assert(text.length<2500);
  // This property-specific camera clause also passes the real free-text guard;
  // server-appended immutable compliance locks are not user instructions.
  assertFairHousing(text.slice(0,-GUARDRAILS.length),'Camera motion','real_estate');
 }
 assertThrows(()=>assertFairHousing('Create a take with no new surfaces, text or people','Camera motion','real_estate'),HttpError);
 // The v1 exported builders retain their exact reviewed snapshot below.
 assertEquals(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(buildPropertyCanvasReelPrompt('home','fly_through','16:9'))).then(b=>Array.from(new Uint8Array(b),v=>v.toString(16).padStart(2,'0')).join('')),'928e9af7c13b4ca1dfed1d85b078e4e69ca01c462190dfc6c9a11c34b2089842');
});
