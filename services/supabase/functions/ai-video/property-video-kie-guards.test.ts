// Fix-wave guards in ai-video/property-video-quality.ts for the Kie native-4K
// profile, offline (no transport is ever reached: every reader is an in-process
// double). Compiled variants of the actual module, loaded from data: URLs, prove
// each guard is load-bearing.
//   - lazy readiness: an inconsistent identity or a changed composition binding
//     never throws at module load; every Kie entry point refuses (503 / null /
//     false) before reading the pinned row, and FAL selection is unchanged;
//   - the post-hold pinned comparison (samePinnedKieDispatch) is exact and
//     independent of jsonb key order (route params come back {"sound":false,"kie_mode":"4K"}).
import {assert,assertEquals,assertRejects,assertThrows} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {HttpError} from "../_shared/http.ts";
import {KIE_PROPERTY_IDENTITY as KIE,KIE_PROPERTY_PROFILE} from "../_shared/property-video-kie.ts";
const Q=await import("./property-video-quality.ts");
type QualityModule=typeof Q;

const QUALITY=new URL("./property-video-quality.ts",import.meta.url),KIE_MODULE=new URL("../_shared/property-video-kie.ts",import.meta.url);
const QUALITY_SOURCE=await Deno.readTextFile(QUALITY),KIE_SOURCE=await Deno.readTextFile(KIE_MODULE);
const IDENTITY_DATA=await Deno.readTextFile(new URL("../_shared/property-video-kie-identity.ts",import.meta.url));
const enc=(s:string)=>{const b=new TextEncoder().encode(s);let out="";for(let i=0;i<b.length;i+=32768)out+=String.fromCharCode(...b.subarray(i,i+32768));return "data:application/typescript;base64,"+btoa(out);};
const once=(text:string,a:string,b:string)=>{assertEquals(text.split(a).length,2,"Mutation anchor must be unique: "+a);return text.replace(a,()=>b);};
/** property-video-quality.ts (optionally mutated) over the real or a broken-identity property-video-kie.ts. */
async function compileQuality(quality=QUALITY_SOURCE,brokenIdentity?:string):Promise<QualityModule>{
 let kieHref=KIE_MODULE.href;
 if(brokenIdentity!==undefined)kieHref=enc(KIE_SOURCE.replace(/from "(\.\/[^"]+)"/g,(_a,path:string)=>`from ${JSON.stringify(path==="./property-video-kie-identity.ts"?enc(brokenIdentity):new URL(path,KIE_MODULE).href)}`));
 return await import(enc(quality.replace(/from\s+(["'])(\.\.?\/[^"']+)\1/g,(_a,_q,path:string)=>{const href=new URL(path,QUALITY).href;return `from ${JSON.stringify(href===KIE_MODULE.href?kieHref:href)}`;})));
}

const ROW={id:KIE.route_id,task:KIE.task,position:1,provider:"kie",model:"kling-3.0/video",unit:"second",unit_cents:33.5,capabilities:["i2v","1080p","5s","native4k","preserve_photo"],
 max_latency_s:1800,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"trains_by_default",enabled:true,retire_after:null,note:"pinned",params:{kie_mode:"4K",sound:false}};
const STEP={route_id:KIE.route_id,task:"video.reel_clip",position:1,provider:"kie",model:"kling-3.0/video",unit:"second",unit_cents:33.5,capabilities:ROW.capabilities,
 max_latency_s:1800,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"trains_by_default" as const,enabled:true,retire_after:null,params:{kie_mode:"4K",sound:false}};
const FAL_STEP={route_id:"closed-fal4k",task:"video.property_reel_clip",provider:"fal",model:Q.PROPERTY_VIDEO_QUALITY_MODEL,unit:"second",unit_cents:42,capabilities:ROW.capabilities,
 max_latency_s:900,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"retained_30d" as const,enabled:true};
const REQUEST={aspect:"9:16",seconds:5,framing:"preserve_photo",presetVersion:1,customPrompt:undefined,assetId:undefined,sourceAssetId:"e1000000-0000-4000-8000-000000000004"};
const INPUT={task:"video.reel_clip",prompt:"steady",image_url:"data:image/jpeg;base64,AAAA",seconds:5,resolution:"1080p" as const,aspect:"9:16" as const,framing:"preserve_photo" as const,
 extra:{kie_mode:"4K",sound:false,property_video_target_aspect:"9:16",property_video_quality_profile:KIE_PROPERTY_PROFILE}};
const byteOrder=(a:string,b:string)=>{const x=new TextEncoder().encode(a),y=new TextEncoder().encode(b);if(x.length!==y.length)return x.length-y.length;for(let i=0;i<x.length;i++)if(x[i]!==y[i])return x[i]-y[i];return 0;};
// deno-lint-ignore no-explicit-any
const reorder=(value:unknown,order:(keys:string[])=>string[]):any=>Array.isArray(value)?value.map(v=>reorder(v,order)):value&&typeof value==="object"
 ?Object.fromEntries(order(Object.keys(value)).map(k=>[k,reorder((value as Record<string,unknown>)[k],order)])):value;
const jsonbOrder=(value:unknown)=>reorder(value,keys=>[...keys].sort(byteOrder));
const reversedOrder=(value:unknown)=>reorder(value,keys=>[...keys].reverse());
const identity=()=>JSON.parse(JSON.stringify(KIE));

// ── Lazy readiness ───────────────────────────────────────────────────────────

/** Every Kie entry point refuses before the pinned row is read; FAL is untouched. */
async function refusesKieOnly(m:QualityModule,label:string){
 assert(!m.kiePropertyProfileReady(),`READY ${label}: not ready`);
 const ids:string[]=[],reader=async(id:string)=>{ids.push(id);return ROW;};
 const e=await assertRejects(()=>m.propertyVideoQualitySteps("team",async()=>[],KIE_PROPERTY_PROFILE,reader),HttpError,undefined,`READY ${label}: Kie selection refused`);
 assertEquals([e.status,e.message],[503,"The native-4K video profile is unavailable. No generation was sent."],`READY ${label}: 503`);
 assertEquals(ids,[],`READY ${label}: the pinned row is never read`);
 const s=assertThrows(()=>m.assertKiePropertyDispatchScope({qualityIdentity:identity(),targetAspect:"9:16"},REQUEST),HttpError,undefined,`READY ${label}: dispatch scope refused`);
 assertEquals(s.status,503,`READY ${label}: dispatch scope 503`);
 assertEquals(m.kiePropertyRouteStep(ROW),null,`READY ${label}: no pinned step`);
 assert(!m.kiePropertyInputExact(INPUT),`READY ${label}: no exact recipe`);
 assert(!m.samePinnedKieDispatch(ROW,STEP,identity()),`READY ${label}: no dispatch match`);
 // FAL profiles keep the resolver path and never read the pinned Kie row.
 for(const profile of[undefined,Q.PROPERTY_VIDEO_QUALITY_PROFILE,Q.PROPERTY_VIDEO_STEADY_PROFILE]){
  const steps=await m.propertyVideoQualitySteps("pro",async()=>[FAL_STEP] as never,profile,reader);assertEquals(steps,[{...FAL_STEP,task:"video.reel_clip"}],`READY ${label}: FAL unchanged`);
 }
 assertEquals(ids,[],`READY ${label}: FAL never reads the Kie row`);
}
const BROKEN_COMPOSITION=once(QUALITY_SOURCE,'STEADY_PROPERTY_COMPOSITION_PROFILE="steady-v2-cfr24" as const','STEADY_PROPERTY_COMPOSITION_PROFILE="steady-v3-cfr24" as const');

Deno.test("a broken identity or composition binding loads; every Kie entry point refuses before the pinned read; FAL is unchanged",async()=>{
 assert(Q.kiePropertyProfileReady());
 for(const[label,needle,replacement]of[["unit cents",'"unit_cents": 33.5,','"unit_cents": 33.6,'],["profile",'"profile": "kie-kling3-4k-steady-v1",','"profile": "kie-kling3-4k-steady-v9",'],
  ["prompt pin",'"push_in": "275836a1','"push_in": "Z75836a1']]){
  await refusesKieOnly(await compileQuality(QUALITY_SOURCE,once(IDENTITY_DATA,needle,replacement)),label);
 }
 await refusesKieOnly(await compileQuality(BROKEN_COMPOSITION),"composition");
 // Defect control: the pre-fix module-level throw takes FAL selection down with it.
 const eager=BROKEN_COMPOSITION+'\nif(KIE_PROPERTY_IDENTITY.composition_profile!==STEADY_PROPERTY_COMPOSITION_PROFILE)throw new Error("Kie property identity changed its composition profile");\n';
 await assertRejects(()=>compileQuality(eager),Error,"composition profile");
 // Defect controls: each lazy readiness check removed lets the broken binding through.
 for(const[needle,replacement]of[[" assert(kiePropertyProfileReady(),503,KIE_PROFILE_UNAVAILABLE);\n  let row:unknown;","  let row:unknown;"],
  ["if(!kiePropertyProfileReady()||!row||","if(!row||"],[" assert(kiePropertyProfileReady(),503,KIE_PROFILE_UNAVAILABLE);\n assert(scope&&"," assert(scope&&"],
  ["return kiePropertyProfileReady()&&Object.keys(input)","return Object.keys(input)"]]){
  const weak=await compileQuality(once(BROKEN_COMPOSITION,needle,replacement));
  await assertRejects(()=>refusesKieOnly(weak,"control"),Error,"READY control",`control detected: ${needle}`);
 }
});

// ── samePinnedKieDispatch: exact, jsonb-order independent ───────────────────

function pinnedOracle(m:QualityModule){
 const jsonbParams={...ROW,params:jsonbOrder(ROW.params)};
 assertEquals(JSON.stringify(jsonbParams.params),'{"sound":false,"kie_mode":"4K"}',"fixture is in true jsonb order");
 const reserved=[STEP,{...STEP,params:reversedOrder(STEP.params)},reversedOrder(STEP)];
 for(const fresh of[ROW,jsonbParams,{...ROW,params:reversedOrder(ROW.params)},reversedOrder(ROW)])for(const r of reserved)for(const frozen of[identity(),jsonbOrder(identity()),reversedOrder(identity())]){
  assert(m.samePinnedKieDispatch(fresh,r,frozen),"PINNED key order alone never refuses");
 }
 const day=(n:number)=>new Date(Date.now()+n*86400000).toISOString().slice(0,10);
 for(const change of[{params:{sound:false,kie_mode:"4K",aspect_ratio:"9:16"}},{params:{sound:false}},{params:{sound:"false",kie_mode:"4K"}},{params:[]},{unit_cents:"33.5000001"},
  {capabilities:[...ROW.capabilities].reverse()},{retire_after:day(3)},{max_latency_s:1799}])assert(!m.samePinnedKieDispatch({...jsonbParams,...change},STEP,identity()),"PINNED fresh "+JSON.stringify(change));
 for(const change of[{params:{sound:false,kie_mode:"4K",extra:1}},{params:{sound:true,kie_mode:"4K"}},{capabilities:["i2v"]},{retire_after:"2099-12-31"}])
  assert(!m.samePinnedKieDispatch(jsonbParams,{...STEP,...change},identity()),"PINNED reserved "+JSON.stringify(change));
 const pins={...identity().prompt_template_sha256};
 assert(!m.samePinnedKieDispatch(ROW,STEP,jsonbOrder({...identity(),prompt_template_sha256:{...pins,orbit:"0".repeat(64)}})),"PINNED frozen nested drift");
}

Deno.test("post-hold pinned comparison is exact and independent of jsonb key order in the row, the reserved step and the frozen identity",async()=>{
 pinnedOracle(Q);
 // Defect controls: order-sensitive (stringify) comparisons refuse a reordered but identical step.
 for(const[needle,replacement]of[["sameJsonValue(paramsOf(reserved),{kie_mode:k.mode,sound:k.sound})","JSON.stringify(paramsOf(reserved))===JSON.stringify({kie_mode:k.mode,sound:k.sound})"],
  ["sameJsonValue(pinnedStepFacts(fresh),pinnedStepFacts(reserved))","JSON.stringify(pinnedStepFacts(fresh))===JSON.stringify(pinnedStepFacts(reserved))"]]){
  const weak=await compileQuality(once(QUALITY_SOURCE,needle,replacement));
  assertThrows(()=>pinnedOracle(weak),Error,"PINNED",`control detected: ${needle}`);
 }
 // Defect control: the full-step comparison removed: a non-identity column drift is no longer refused.
 const partial=await compileQuality(once(QUALITY_SOURCE,"&&sameJsonValue(pinnedStepFacts(fresh),pinnedStepFacts(reserved));",";"));
 assertThrows(()=>pinnedOracle(partial),Error,"PINNED fresh");
});
