import { assert, assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { parseReelFraming, reelStepPreservesPhoto, reelFramingSteps, buildPhotoPreservingReelPrompt } from "./reel-framing.ts";
import { HttpError } from "../_shared/http.ts";
import { ProviderError } from "../_shared/providers/common.ts";
import { falInput } from "../_shared/providers/fal.ts";
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
Deno.test("actual Kling Pro silent adapter emits only documented full-source auto fields",async()=>{
  const result=await capturedSubmit();
  assertEquals(result.calls,[{url:"https://api.kie.ai/api/v1/jobs/createTask",method:"POST",body:{model:"kling-3.0/video",input:{prompt:input.prompt,image_urls:[input.image_url],sound:false,duration:"5",mode:"pro",multi_shots:false}}}]);
  assertEquals([result.job.id,result.job.provider,result.job.model],["closed-owned-task","kie",step.model]);
  assert(!JSON.stringify(result.calls).includes("aspect_ratio")&&!JSON.stringify(result.calls).includes('"resolution"'));
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
Deno.test("actual Kling admission reserves45 cents in both authorities before exactly one submit and settles owned receipt",async()=>{
  const f=funded();await submitReservedVideo(options,f.deps);assertEquals(f.posts(),1);
  assertEquals(f.calls.filter(x=>x.name.endsWith("reserve")||x.name.endsWith("reserve_v2")).map(x=>({name:x.name,cents:x.args.p_hold_cents})),[{name:"app_video_cost_reserve_v2",cents:45},{name:"serving_cost_reserve",cents:45}]);
  assertEquals(f.calls.at(-1)?.name,"app_video_cost_settle");assertEquals(f.calls.at(-1)?.args.p_provider_request_id,"owned-kling-task");
  for(const changed of [{...input,seconds:6},{...input,resolution:"720p"},{...input,framing:undefined},{...input,extra:{kie_mode:"standard",sound:false}},{...input,extra:{kie_mode:"pro",sound:true}}]){
    const no=funded();await assertRejects(()=>submitReservedVideo({...options,input:changed},no.deps));assertEquals(no.posts(),0);assert(!no.calls.some(x=>x.name==="serving_cost_reserve"));
  }
  const no=funded();await assertRejects(()=>submitReservedVideo({...options,steps:[{...step,unit_cents:3.6}]},no.deps));assertEquals(no.posts(),0);
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

Deno.test("actual FAL Seedance preserves legacy aspect but sends documented auto for the full-photo marker",()=>{
  const fal={...step,provider:"fal",model:"fal-ai/bytedance/seedance/v1/pro/fast/image-to-video"};
  const preserved=falInput(fal,input);assertEquals(preserved.aspect_ratio,"auto");assertEquals(preserved.image_url,input.image_url);
  assertEquals(falInput(fal,{...input,framing:undefined}).aspect_ratio,"9:16");
  assertThrows(()=>falInput({...fal,model:"fal-ai/veo3.1/fast/image-to-video"},input),ProviderError);
});
