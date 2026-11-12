// Whole-recipe quote for the Kie native-4K profile through the ACTUAL exported
// propertyVideoRecipeQuote (real router for the QC judge chain, real catalog and
// documented-bound pricing). FAL and legacy quotes are pinned byte-for-byte to
// outputs captured from the unmodified base (462e4c8) under the same fixture.
// Closed in-process PostgREST transport only; compiled variants of the actual
// quote function prove each Kie guard is load-bearing.
import {assert,assertEquals,assertNotEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {HttpError} from "../_shared/http.ts";
import {KIE_PROPERTY_IDENTITY as KIE,KIE_PROPERTY_PROFILE} from "../_shared/property-video-kie.ts";
for(const[k,v]of Object.entries({SUPABASE_URL:"https://kie-quote-db.fixture.invalid",SUPABASE_ANON_KEY:"public-fixture",SUPABASE_SERVICE_ROLE_KEY:"service-fixture"}))Deno.env.set(k,v);
for(const k of["SUPABASE_SECRET_KEYS","RENDPROP_SECRET_KEY_NAME","SUPABASE_PUBLISHABLE_KEYS","RENDPROP_PUBLISHABLE_KEY_NAME"])Deno.env.delete(k);
const {resetRouterCache}=await import("../_shared/router.ts");
const {routeCatalogQuote,ceilingVerifiedQuote}=await import("../_shared/funded-serving.ts");
const Q=await import("./property-video-quality.ts");
const {propertyVideoRecipeQuote}=await import("./index.ts");
const P=Q.PROPERTY_VIDEO_QUALITY_PROFILE,S=Q.PROPERTY_VIDEO_STEADY_PROFILE,T=Q.PROPERTY_VIDEO_QUALITY_TASK,M=Q.PROPERTY_VIDEO_QUALITY_MODEL;
const FAL_ROW={id:"closed-normal-fal4k",task:T,position:1,provider:"fal",model:M,unit:"second",unit_cents:42,capabilities:["i2v","1080p","5s","native4k","preserve_photo"],max_latency_s:900,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"retained_30d",enabled:true,retire_after:null};
const KIE_ROW={id:KIE.route_id,task:KIE.task,position:1,provider:"kie",model:"kling-3.0/video",unit:"second",unit_cents:33.5,capabilities:["i2v","1080p","5s","native4k","preserve_photo"],
 max_latency_s:1800,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"trains_by_default",enabled:true,retire_after:null,note:"pinned",params:{kie_mode:"4K",sound:false}};
const db={profile:KIE_PROPERTY_PROFILE as string,pinned:KIE_ROW as unknown,requests:[] as URL[]};
// Same answers as the baseline capture; plus the pinned Kie row by primary key.
globalThis.fetch=(async(input:RequestInfo|URL,init?:RequestInit)=>{
 const u=new URL(new Request(input,init).url);db.requests.push(u);assertEquals(u.hostname,"kie-quote-db.fixture.invalid","No external/provider request");
 if(u.pathname.endsWith("/rpc/property_video_quality_profile"))return Response.json(db.profile);
 if(u.pathname.endsWith("/rpc/org_entitlement"))return Response.json({plan:"starter",cogs_ceiling_cents:2032,reels_per_month:30,seats:1,renders_per_month:3,photo_edits_per_month:50,aerials_per_month:3,topaz_per_month:0,price_cents:4900});
 if(u.pathname.endsWith("/app_config"))return Response.json({value:{enabled:true}});
 if(u.pathname.endsWith("/plan_routing_policy"))return Response.json([{plan:"starter",policy:"cheapest"},{plan:"pro",policy:"best"},{plan:"team",policy:"best"}]);
 if(u.pathname.endsWith("/provider_health"))return Response.json([]);
 if(u.pathname.endsWith("/ai_routes")){
  if(u.searchParams.get("id")==="eq."+KIE.route_id&&!u.searchParams.has("task"))return Response.json(db.pinned===undefined?[]:[db.pinned]);
  const task=u.searchParams.get("task");
  if(task==="eq."+T)return Response.json([FAL_ROW]);
  if(task==="eq.judge.qc_drift")return Response.json([{...FAL_ROW,task:"judge.qc_drift",provider:"anthropic",model:"claude-sonnet-5",unit:"call",unit_cents:1.3,capabilities:["classifier","vision","multi_image"]}]);
  if(task==="eq.video.reel_clip")return Response.json([{...FAL_ROW,task:"video.reel_clip",model:"bytedance/seedance/v1/pro/fast/image-to-video",unit_cents:4.86}]);
 }
 throw new Error("Unexpected closed request "+u.pathname+u.search);
}) as typeof fetch;
function reset(o:Partial<typeof db>={}){resetRouterCache();Object.assign(db,{profile:KIE_PROPERTY_PROFILE,pinned:KIE_ROW,requests:[]},o);}
const quote=(aspect:"16:9"|"9:16",count:number,saved?:string)=>propertyVideoRecipeQuote("not-a-uuid","org","listing",aspect,count,saved as never);
const BASIS=(count:number)=>({provider:"kie",model:"kling-3.0/video",mode:"4K",unit:"second",unit_cents:33.5,attempt_cents:167.5,credits_per_second:67,usd_per_credit:0.005,
 price_source:"https://kie.ai/kling-3-0",price_checked:"2026-10-16",bonus_credits_excluded:true,max_paid_attempts_per_source:2,expected_generation_cents:167.5*count,worst_case_generation_cents:335*count});
const FAL_KEYS=["quality_profile","source_count","estimated_cents","reel_cents","qc_cents","planning_cents","narration_cents","provider","model","basis","atomic_reservation"];

Deno.test("Kie whole-recipe quote: exactly167.5c per shot, the same paid QC, additive exact priced basis",async()=>{
 reset({profile:"legacy"});const fal1=await quote("16:9",1,P);const perQC=fal1.qc_cents;assertEquals(perQC,6.3636);
 for(const aspect of["16:9","9:16"]as const)for(const count of[1,3,7,20,100]){
  reset({profile:"legacy"});const fal=await quote(aspect,count,P);
  reset();const q=await quote(aspect,count);
  assertEquals(Object.keys(q),[...FAL_KEYS,"priced_basis"],"FAL fields keep their order; priced_basis is additive");
  assertEquals([q.quality_profile,q.source_count,q.provider,q.model,q.basis,q.atomic_reservation,q.planning_cents,q.narration_cents],[KIE_PROPERTY_PROFILE,count,"kie","kling-3.0/video","current_catalog_and_documented_bounds",false,0,0]);
  assertEquals(q.reel_cents,167.5*count);assertEquals(q.qc_cents,fal.qc_cents,"Same judge chain and bounded QC as the FAL recipe");
  assertEquals(q.estimated_cents,Math.ceil((167.5+perQC)*count*10000)/10000);assert(q.estimated_cents>=167.5*count+q.qc_cents);
  assertEquals((q as {priced_basis?:unknown}).priced_basis,BASIS(count));
  // Generation route: one primary-key read; the FAL task and the Kie task are never scanned.
  const routes=db.requests.filter(u=>u.pathname.endsWith("/ai_routes"));
  assertEquals(routes.filter(u=>u.searchParams.get("id")==="eq."+KIE.route_id).length,1);
  assert(!routes.some(u=>[`eq.${T}`,`eq.${KIE.task}`,"eq.video.reel_clip"].includes(String(u.searchParams.get("task")))),"Router never selects the generation step");
 }
 reset();assertEquals((await quote("16:9",1)).estimated_cents,173.8636);
});

Deno.test("both price authorities price the exact Kie recipe at167.5c; the quote input carries the exact Kie extra",()=>{
 const step=Q.kiePropertyRouteStep(KIE_ROW)!;
 for(const aspect of["16:9","9:16"]as const){
  const input={task:"video.reel_clip",seconds:5,resolution:"1080p",aspect,framing:"preserve_photo",extra:Q.kiePropertyExtra(aspect)};
  const catalog=routeCatalogQuote(step,input);assertEquals(catalog?.cents,167.5);assertEquals(ceilingVerifiedQuote(step,input,catalog)?.cents,167.5);
  assertEquals(input.extra,{kie_mode:"4K",sound:false,property_video_target_aspect:aspect,property_video_quality_profile:KIE_PROPERTY_PROFILE});
 }
});

Deno.test("saved profiles are honoured on resume: Kie ignores today's default; FAL saved while Kie is default stays FAL",async()=>{
 reset({profile:"legacy"});const kie=await quote("9:16",2,KIE_PROPERTY_PROFILE);
 assertEquals([kie.quality_profile,kie.reel_cents,kie.provider],[KIE_PROPERTY_PROFILE,335,"kie"]);
 assert(!db.requests.some(u=>u.pathname.endsWith("/rpc/property_video_quality_profile")),"Saved profile never re-reads today's selector");
 reset();const fal=await quote("9:16",2,S);assertEquals([fal.quality_profile,fal.reel_cents,fal.provider,"priced_basis" in fal],[S,420,"fal",false]);
 assert(!db.requests.some(u=>u.searchParams.get("id")==="eq."+KIE.route_id),"FAL resume never reads the pinned Kie row");
});

Deno.test("pinned row drift or absence refuses the Kie quote with503; no FAL fallback price is returned",async()=>{
 const today=new Date().toISOString().slice(0,10);
 for(const pinned of[undefined,{...KIE_ROW,unit_cents:9},{...KIE_ROW,unit_cents:33.4},{...KIE_ROW,params:{kie_mode:"pro",sound:false}},{...KIE_ROW,params:{kie_mode:"4K",sound:true}},
  {...KIE_ROW,params:{kie_mode:"4K",sound:false,aspect_ratio:"16:9"}},{...KIE_ROW,privacy_tier:"retained_30d"},{...KIE_ROW,enabled:false},{...KIE_ROW,provider:"fal"},
  {...KIE_ROW,model:M},{...KIE_ROW,task:T},{...KIE_ROW,retire_after:today}]){
  reset({pinned});const e=await assertRejects(()=>quote("16:9",3),HttpError);assertEquals(e.status,503,JSON.stringify(pinned));
 }
});

// Captured from the unmodified base (462e4c8): same fixture, actor and inputs.
const BASE:Record<string,string>={
 "fal-kling3-4k-v1|1":'{"quality_profile":"fal-kling3-4k-v1","source_count":1,"estimated_cents":216.3636,"reel_cents":210,"qc_cents":6.3636,"planning_cents":0,"narration_cents":0,"provider":"fal","model":"fal-ai/kling-video/v3/4k/image-to-video","basis":"current_catalog_and_documented_bounds","atomic_reservation":false}',
 "fal-kling3-4k-v1|3":'{"quality_profile":"fal-kling3-4k-v1","source_count":3,"estimated_cents":649.0908,"reel_cents":630,"qc_cents":19.0908,"planning_cents":0,"narration_cents":0,"provider":"fal","model":"fal-ai/kling-video/v3/4k/image-to-video","basis":"current_catalog_and_documented_bounds","atomic_reservation":false}',
 "fal-kling3-4k-v1|20":'{"quality_profile":"fal-kling3-4k-v1","source_count":20,"estimated_cents":4327.272,"reel_cents":4200,"qc_cents":127.27199999999999,"planning_cents":0,"narration_cents":0,"provider":"fal","model":"fal-ai/kling-video/v3/4k/image-to-video","basis":"current_catalog_and_documented_bounds","atomic_reservation":false}',
 "fal-kling3-4k-steady-v2|1":'{"quality_profile":"fal-kling3-4k-steady-v2","source_count":1,"estimated_cents":216.3636,"reel_cents":210,"qc_cents":6.3636,"planning_cents":0,"narration_cents":0,"provider":"fal","model":"fal-ai/kling-video/v3/4k/image-to-video","basis":"current_catalog_and_documented_bounds","atomic_reservation":false}',
 "fal-kling3-4k-steady-v2|3":'{"quality_profile":"fal-kling3-4k-steady-v2","source_count":3,"estimated_cents":649.0908,"reel_cents":630,"qc_cents":19.0908,"planning_cents":0,"narration_cents":0,"provider":"fal","model":"fal-ai/kling-video/v3/4k/image-to-video","basis":"current_catalog_and_documented_bounds","atomic_reservation":false}',
 "fal-kling3-4k-steady-v2|20":'{"quality_profile":"fal-kling3-4k-steady-v2","source_count":20,"estimated_cents":4327.272,"reel_cents":4200,"qc_cents":127.27199999999999,"planning_cents":0,"narration_cents":0,"provider":"fal","model":"fal-ai/kling-video/v3/4k/image-to-video","basis":"current_catalog_and_documented_bounds","atomic_reservation":false}',
 "legacy|1":'{"quality_profile":"legacy","source_count":1,"estimated_cents":30.6636,"reel_cents":24.3,"qc_cents":6.3636,"planning_cents":0,"narration_cents":0,"provider":"fal","model":"bytedance/seedance/v1/pro/fast/image-to-video","basis":"current_catalog_and_documented_bounds","atomic_reservation":false}',
 "legacy|3":'{"quality_profile":"legacy","source_count":3,"estimated_cents":91.9909,"reel_cents":72.9,"qc_cents":19.0908,"planning_cents":0,"narration_cents":0,"provider":"fal","model":"bytedance/seedance/v1/pro/fast/image-to-video","basis":"current_catalog_and_documented_bounds","atomic_reservation":false}',
 "legacy|20":'{"quality_profile":"legacy","source_count":20,"estimated_cents":613.2721,"reel_cents":486,"qc_cents":127.27199999999999,"planning_cents":0,"narration_cents":0,"provider":"fal","model":"bytedance/seedance/v1/pro/fast/image-to-video","basis":"current_catalog_and_documented_bounds","atomic_reservation":false}',
};
Deno.test("FAL v1, FAL steady-v2 and legacy quotes are byte-identical to base (saved and current selector)",async()=>{
 for(const[key,expected]of Object.entries(BASE)){
  const[profile,count]=key.split("|");
  for(const aspect of["16:9","9:16"]as const){
   reset({profile:"legacy"});assertEquals(JSON.stringify(await quote(aspect,Number(count),profile)),expected,key+" saved "+aspect);
   reset({profile});assertEquals(JSON.stringify(await quote(aspect,Number(count))),expected,key+" current "+aspect);
   assert(!db.requests.some(u=>u.searchParams.get("id")==="eq."+KIE.route_id),"Non-Kie quotes never read the pinned Kie row");
  }
 }
});

Deno.test("compiled defect controls: each Kie quote guard is load-bearing",async()=>{
 const source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
 const start=source.indexOf("export async function propertyVideoRecipeQuote("),end=source.indexOf("export interface AiVideoWorkerScope",start);assert(start>0&&end>start);
 const enc=(s:string)=>"data:application/typescript;base64,"+btoa(String.fromCharCode(...new TextEncoder().encode(s)));
 const href=(path:string)=>JSON.stringify(new URL(path,import.meta.url).href);
 const once=(text:string,a:string,b:string)=>{assertEquals(text.split(a).length,2,"Mutation anchor must be unique: "+a);return text.replace(a,b);};
 const compile=async(fragment:string)=>await import(enc(`
  import {assert} from ${href("../_shared/http.ts")};import {paramsOf} from ${href("../_shared/router.ts")};
  import {routeCatalogQuote as realCatalog,ceilingVerifiedQuote,textAttemptQuote,visionInputTokenBound} from ${href("../_shared/funded-serving.ts")};
  import {reelFramingSteps} from ${href("./reel-framing.ts")};import {driftRubric} from ${href("../_shared/drift.ts")};import {DRIFT_SOURCE_EXTRA_INPUT_TOKENS} from ${href("./drift-input.ts")};
  import {isPropertyVideoQualityProfile,propertyVideoQualityProfile,propertyVideoQualitySteps as actualSteps,kiePropertyExtra,kiePropertyPricedBasis} from ${href("./property-video-quality.ts")};
  const DRIFT_MAX_TOKENS=${source.match(/const DRIFT_MAX_TOKENS = (\d+);/)![1]},MODEL_I2V="bytedance/seedance/v1/pro/fast/image-to-video",APP_AI_UNIT_CENTS={seedance_per_s:4.86};
  export const seen:any={inputs:[],skew:0};
  const routeCatalogQuote=(step:any,input:any)=>{seen.inputs.push(input);const q=realCatalog(step,input);return q&&{...q,cents:q.cents+seen.skew};};
  const currentPropertyVideoQualityProfile=async()=>${JSON.stringify(KIE_PROPERTY_PROFILE)},entitlementForCharge=async()=>({plan:"starter"});
  const ownerQaReelStep=async()=>{throw Error("owner QA unreachable");},resolveChain=async()=>{throw Error("legacy chain unreachable");};
  const legacyVideoStep=(task:any,model:any,unit:any,unit_cents:any,capabilities:any)=>({task,model,unit,unit_cents,capabilities,provider:"fal"});
  const fal=${JSON.stringify({...FAL_ROW,route_id:FAL_ROW.id})},kieRow=${JSON.stringify(KIE_ROW)};
  const propertyVideoQualitySteps=(plan:string,_resolver?:any,profile?:any)=>actualSteps(plan,async()=>[fal],profile,async()=>kieRow);
  const driftChain=async()=>[{route_id:"judge",task:"judge.qc_drift",provider:"anthropic",model:"claude-sonnet-5",unit:"call",unit_cents:1.3,capabilities:["classifier","vision","multi_image"],max_latency_s:900,min_plan:"free",same_model_as:null,privacy_tier:"retained_30d",enabled:true}];
  ${fragment}
  export const run=(aspect:any,count:number)=>propertyVideoRecipeQuote("actor","org","listing",aspect,count);`));
 const fragment=source.slice(start,end);
 const actual=await compile(fragment),q=await actual.run("9:16",4);
 assertEquals([q.provider,q.reel_cents,q.priced_basis],["kie",670,BASIS(4)]);assertEquals(actual.seen.inputs.at(-1).extra,Q.kiePropertyExtra("9:16"));
 actual.seen.skew=-0.1;await assertRejects(()=>actual.run("9:16",4),HttpError,"priced exactly");
 // 1. priced_basis dropped.
 const noBasis=await compile(once(fragment,"...(kie?{priced_basis:kiePropertyPricedBasis(count)}:{})",""));assertEquals((await noBasis.run("9:16",4)).priced_basis,undefined);
 // 2. Kie extra replaced by the FAL recipe extra.
 const noExtra=await compile(once(fragment,"extra:kie?kiePropertyExtra(aspect):{","extra:false?kiePropertyExtra(aspect):{"));await noExtra.run("16:9",1);
 assertNotEquals(noExtra.seen.inputs.at(-1).extra,Q.kiePropertyExtra("16:9"));
 // 3. Saved profile not passed to selection: the Kie quote no longer succeeds (the FAL row is selected
 //    and the exact-price guard refuses it), so the main oracle fails.
 const dropProfile=(text:string)=>once(text,"await propertyVideoQualitySteps(ent.plan,undefined,profile)","await propertyVideoQualitySteps(ent.plan)");
 const noProfile=await compile(dropProfile(fragment));await assertRejects(()=>noProfile.run("16:9",2),HttpError,"priced exactly");
 // 4. Exact-price assertion removed: a drifted pricing authority would quote 167.4c.
 const dropExact=(text:string)=>once(text,"if(kie)assert(perShot===kiePropertyPricedBasis(1).attempt_cents,","if(false)assert(perShot===kiePropertyPricedBasis(1).attempt_cents,");
 const noExact=await compile(dropExact(fragment));noExact.seen.skew=-0.1;assertEquals((await noExact.run("16:9",1)).reel_cents,167.4);
 // 5. Both layers removed: the FAL resolver price leaks into a Kie-labelled quote.
 const leaked=await (await compile(dropExact(dropProfile(fragment)))).run("16:9",2);
 assertEquals([leaked.quality_profile,leaked.provider,leaked.reel_cents],[KIE_PROPERTY_PROFILE,"fal",420]);
 console.log("KIE_QUOTE_COMPILED_CONTROLS=5");
});

Deno.test("an inconsistent identity never crashes the quote module: the actual Kie quote refuses 503 before the pinned read; FAL quotes are unchanged",async()=>{
 const source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
 const start=source.indexOf("export async function propertyVideoRecipeQuote("),end=source.indexOf("export interface AiVideoWorkerScope",start);assert(start>0&&end>start);
 const enc=(s:string)=>{const b=new TextEncoder().encode(s);let out="";for(let i=0;i<b.length;i+=32768)out+=String.fromCharCode(...b.subarray(i,i+32768));return "data:application/typescript;base64,"+btoa(out);};
 const href=(path:string)=>JSON.stringify(new URL(path,import.meta.url).href);
 const KIE_URL=new URL("../_shared/property-video-kie.ts",import.meta.url),QUALITY_URL=new URL("./property-video-quality.ts",import.meta.url);
 const identityText=await Deno.readTextFile(new URL("../_shared/property-video-kie-identity.ts",import.meta.url));
 assertEquals(identityText.split('"unit_cents": 33.5,').length,2);
 const kieData=enc((await Deno.readTextFile(KIE_URL)).replace(/from "(\.\/[^"]+)"/g,(_a,p:string)=>`from ${JSON.stringify(p==="./property-video-kie-identity.ts"?enc(identityText.replace('"unit_cents": 33.5,','"unit_cents": 33.6,')):new URL(p,KIE_URL).href)}`));
 const qualityData=enc((await Deno.readTextFile(QUALITY_URL)).replace(/from\s+(["'])(\.\.?\/[^"']+)\1/g,(_a,_q,p:string)=>{const h=new URL(p,QUALITY_URL).href;return `from ${JSON.stringify(h===KIE_URL.href?kieData:h)}`;}));
 const m=await import(enc(`
  import {assert} from ${href("../_shared/http.ts")};import {paramsOf} from ${href("../_shared/router.ts")};
  import {routeCatalogQuote,ceilingVerifiedQuote,textAttemptQuote,visionInputTokenBound} from ${href("../_shared/funded-serving.ts")};
  import {reelFramingSteps} from ${href("./reel-framing.ts")};import {driftRubric} from ${href("../_shared/drift.ts")};import {DRIFT_SOURCE_EXTRA_INPUT_TOKENS} from ${href("./drift-input.ts")};
  import {isPropertyVideoQualityProfile,propertyVideoQualityProfile,propertyVideoQualitySteps as actualSteps,kiePropertyExtra,kiePropertyPricedBasis} from ${JSON.stringify(qualityData)};
  const DRIFT_MAX_TOKENS=${source.match(/const DRIFT_MAX_TOKENS = (\d+);/)![1]},MODEL_I2V="bytedance/seedance/v1/pro/fast/image-to-video",APP_AI_UNIT_CENTS={seedance_per_s:4.86};
  export const seen:any={reads:0};
  const currentPropertyVideoQualityProfile=async()=>${JSON.stringify(KIE_PROPERTY_PROFILE)},entitlementForCharge=async()=>({plan:"starter"});
  const ownerQaReelStep=async()=>{throw Error("owner QA unreachable");},resolveChain=async()=>{throw Error("legacy chain unreachable");};
  const legacyVideoStep=(task:any,model:any,unit:any,unit_cents:any,capabilities:any)=>({task,model,unit,unit_cents,capabilities,provider:"fal"});
  const fal=${JSON.stringify({...FAL_ROW,route_id:FAL_ROW.id})},kieRow=${JSON.stringify(KIE_ROW)};
  const propertyVideoQualitySteps=(plan:string,_resolver?:any,profile?:any)=>actualSteps(plan,async()=>[fal],profile,async()=>{seen.reads++;return kieRow;});
  const driftChain=async()=>[{route_id:"judge",task:"judge.qc_drift",provider:"anthropic",model:"claude-sonnet-5",unit:"call",unit_cents:1.3,capabilities:["classifier","vision","multi_image"],max_latency_s:900,min_plan:"free",same_model_as:null,privacy_tier:"retained_30d",enabled:true}];
  ${source.slice(start,end)}
  export const run=(aspect:any,count:number,profile?:any)=>propertyVideoRecipeQuote("actor","org","listing",aspect,count,profile);`));
 for(const saved of[undefined,KIE_PROPERTY_PROFILE]){
  const e=await assertRejects(()=>m.run("9:16",3,saved),HttpError);
  assertEquals([e.status,e.message],[503,"The native-4K video profile is unavailable. No generation was sent."]);assertEquals(m.seen.reads,0,"the pinned row is never read");
 }
 // FAL quotes from the same (broken-identity) module graph are exactly the base values.
 for(const[profile,count]of[[P,3],[S,20]]as const){
  const q=await m.run("16:9",count,profile);assertEquals(JSON.stringify(q),BASE[`${profile}|${count}`]);
 }
});
