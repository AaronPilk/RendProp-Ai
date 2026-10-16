// Kie native-4K profile selection: parser/helpers, the pinned route read by id
// (never the router), exact identity enforcement, FAL profiles unchanged, and
// the pure dispatch guards. Offline: the only transport is a closed in-process
// PostgREST double; compiled variants prove each guard is load-bearing.
import {assert,assertEquals,assertRejects,assertThrows} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {HttpError} from "../_shared/http.ts";
import {ProviderError} from "../_shared/providers/common.ts";
import {KIE_PROPERTY_IDENTITY as KIE,KIE_PROPERTY_PROFILE} from "../_shared/property-video-kie.ts";
for(const[k,v]of Object.entries({SUPABASE_URL:"https://kie-selection-db.fixture.invalid",SUPABASE_ANON_KEY:"public-fixture",SUPABASE_SERVICE_ROLE_KEY:"service-fixture"}))Deno.env.set(k,v);
for(const k of["SUPABASE_SECRET_KEYS","RENDPROP_SECRET_KEY_NAME","SUPABASE_PUBLISHABLE_KEYS","RENDPROP_PUBLISHABLE_KEY_NAME"])Deno.env.delete(k);
const Q=await import("./property-video-quality.ts");
const QUALITY=new URL("./property-video-quality.ts",import.meta.url),SOURCE=await Deno.readTextFile(QUALITY);
const enc=(s:string)=>{const b=new TextEncoder().encode(s);let out="";for(let i=0;i<b.length;i+=32768)out+=String.fromCharCode(...b.subarray(i,i+32768));return "data:application/typescript;base64,"+btoa(out);};
const absolute=(text:string)=>text.replace(/from\s+(["'])(\.\.?\/[^"']+)\1/g,(_a,_q,path)=>`from ${JSON.stringify(new URL(path,QUALITY).href)}`);
const mutant=async(...pairs:[string,string][]):Promise<typeof Q>=>{let text=SOURCE;for(const[a,b]of pairs){assertEquals(text.split(a).length,2,"Mutation anchor must be unique: "+a);text=text.replace(a,b);}return await import(enc(absolute(text)));};
const P=Q.PROPERTY_VIDEO_QUALITY_PROFILE,S=Q.PROPERTY_VIDEO_STEADY_PROFILE;
const ROW={id:KIE.route_id,task:KIE.task,position:1,provider:"kie",model:"kling-3.0/video",unit:"second",unit_cents:33.5,capabilities:["i2v","1080p","5s","native4k","preserve_photo"],
 max_latency_s:1800,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"trains_by_default",enabled:true,retire_after:null,note:"pinned",params:{kie_mode:"4K",sound:false}};
const STEP={route_id:KIE.route_id,task:"video.reel_clip",position:1,provider:"kie",model:"kling-3.0/video",unit:"second",unit_cents:33.5,capabilities:ROW.capabilities,
 max_latency_s:1800,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"trains_by_default" as const,enabled:true,retire_after:null,params:{kie_mode:"4K",sound:false}};
const FAL_STEP={route_id:"closed-fal4k",task:"video.property_reel_clip",provider:"fal",model:Q.PROPERTY_VIDEO_QUALITY_MODEL,unit:"second",unit_cents:42,capabilities:ROW.capabilities,
 max_latency_s:900,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"retained_30d" as const,enabled:true};
const day=(offset:number)=>new Date(Date.now()+offset*86400000).toISOString().slice(0,10);
function recorder(rows:unknown[]=[FAL_STEP]){const calls:{task:string;context:unknown}[]=[];return{calls,resolver:async(task:string,context:unknown)=>{calls.push({task,context});return rows as never;}};}
function pinned(row:unknown=ROW){const ids:string[]=[];return{ids,reader:async(id:string)=>{ids.push(id);return row;}};}
const DRIFTS:Record<string,unknown>[]=[{id:"7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f22"},{task:"video.property_reel_clip"},{task:"video.reel_clip"},{provider:"fal"},{provider:"KIE"},
 {model:"kling-3.0/pro"},{model:Q.PROPERTY_VIDEO_QUALITY_MODEL},{unit:"call"},{unit_cents:33.4},{unit_cents:33.6},{unit_cents:9},{unit_cents:0},{unit_cents:null},{unit_cents:"33.5 "},{unit_cents:"3.35e1"},
 {params:null},{params:{}},{params:[]},{params:{kie_mode:"4K"}},{params:{kie_mode:"pro",sound:false}},{params:{kie_mode:"4k",sound:false}},{params:{kie_mode:"4K",sound:true}},
 {params:{kie_mode:"4K",sound:"false"}},{params:{kie_mode:"4K",sound:false,aspect_ratio:"16:9"}},{enabled:false},{enabled:null},{enabled:"true"},
 {privacy_tier:"retained_30d"},{privacy_tier:"no_retention"},{privacy_tier:null},{retire_after:day(0)},{retire_after:day(-1)},{retire_after:"2027-1-1"},{retire_after:"tomorrow"}];

Deno.test("parser admits the Kie profile; steady helpers name both steady profiles and only them",()=>{
 assertEquals(Q.PROPERTY_VIDEO_KIE_PROFILE,KIE_PROPERTY_PROFILE);assertEquals(KIE.profile,KIE_PROPERTY_PROFILE);
 assertEquals(Q.propertyVideoQualityProfile(KIE_PROPERTY_PROFILE),KIE_PROPERTY_PROFILE);
 for(const x of[undefined,null,"legacy"])assertEquals(Q.propertyVideoQualityProfile(x),"legacy");
 for(const x of[P,S])assertEquals(Q.propertyVideoQualityProfile(x),x);
 for(const x of["kie-kling3-4k-steady-v2","KIE-KLING3-4K-STEADY-V1"," kie-kling3-4k-steady-v1","kie","kling-3.0/video",{profile:KIE_PROPERTY_PROFILE},[KIE_PROPERTY_PROFILE],KIE])
  assertThrows(()=>Q.propertyVideoQualityProfile(x),HttpError,"saved video quality profile is unavailable");
 for(const x of[S,KIE_PROPERTY_PROFILE]){assert(Q.isSteadyPropertyVideoProfile(x));assertEquals(Q.propertyVideoCompositionProfile(x),"steady-v2-cfr24");}
 for(const x of[P,"legacy",undefined,null,"steady-v2-cfr24","kie-kling3-4k-steady-v2",{}]){assert(!Q.isSteadyPropertyVideoProfile(x));assertEquals(Q.propertyVideoCompositionProfile(x),undefined);}
 assert(Q.isKiePropertyVideoProfile(KIE_PROPERTY_PROFILE));for(const x of[P,S,"legacy",null])assert(!Q.isKiePropertyVideoProfile(x));
 assertEquals(Q.STEADY_PROPERTY_COMPOSITION_PROFILE,KIE.composition_profile);
 assert(Q.isPropertyVideoQualityProfile(KIE_PROPERTY_PROFILE));
});

Deno.test("Kie selection reads only its pinned row by id, never the router, for every plan",async()=>{
 for(const plan of["free","trial","starter","solo","pro","team","brokerage","unknown-plan"]){
  const r=recorder(),p=pinned();const steps=await Q.propertyVideoQualitySteps(plan,r.resolver,KIE_PROPERTY_PROFILE,p.reader);
  assertEquals(steps,[STEP]);assertEquals(p.ids,[KIE.route_id]);assertEquals(r.calls,[],"Resolver privacy/plan/health ordering is never consulted for Kie");
 }
 // Retirement strictly in the future (same rule as SQL admission); catalog numeric text is the same exact price.
 for(const patch of[{retire_after:day(1)},{unit_cents:"33.5"},{unit_cents:"33.50"},{position:7,capabilities:[],min_plan:"team",note:null,max_latency_s:1}]){
  const steps=await Q.propertyVideoQualitySteps("team",recorder().resolver,KIE_PROPERTY_PROFILE,pinned({...ROW,...patch}).reader);
  assertEquals([steps[0].route_id,steps[0].provider,steps[0].model,steps[0].unit_cents,(steps[0] as typeof STEP).params],[KIE.route_id,"kie","kling-3.0/video",33.5,{kie_mode:"4K",sound:false}]);
 }
});

Deno.test("every drifted identity field, a missing row or an unreadable row is a503 with no step",async()=>{
 for(const patch of DRIFTS){
  assertEquals(Q.kiePropertyRouteStep({...ROW,...patch}),null,JSON.stringify(patch));
  await assertRejects(()=>Q.propertyVideoQualitySteps("team",recorder().resolver,KIE_PROPERTY_PROFILE,pinned({...ROW,...patch}).reader),HttpError,"No generation was sent");
 }
 const {retire_after:_omitted,...withoutRetirement}=ROW;
 for(const row of[null,undefined,[],[ROW],"row",withoutRetirement]){
  const e=await assertRejects(()=>Q.propertyVideoQualitySteps("team",recorder().resolver,KIE_PROPERTY_PROFILE,async()=>row),HttpError);assertEquals(e.status,503);
 }
 const e=await assertRejects(()=>Q.propertyVideoQualitySteps("team",recorder().resolver,KIE_PROPERTY_PROFILE,async()=>{throw new Error("private database detail");}),HttpError);
 assertEquals([e.status,e.message.includes("private")],[503,false]);
});

Deno.test("default reader is one primary-key PostgREST read: no flag, policy, health, or task scan",async()=>{
 const old=globalThis.fetch,requests:URL[]=[];let mode:"row"|"error"="row";
 globalThis.fetch=(async(input:RequestInfo|URL,init?:RequestInit)=>{const u=new URL(new Request(input,init).url);requests.push(u);
  assertEquals(u.hostname,"kie-selection-db.fixture.invalid","No external request");
  if(u.pathname==="/rest/v1/ai_routes")return mode==="row"?Response.json([ROW]):Response.json({message:"private database detail",code:"XX000"},{status:500});
  throw new Error("Closed fixture refused "+u.pathname);}) as typeof fetch;
 try{
  const r=recorder();assertEquals(await Q.propertyVideoQualitySteps("starter",r.resolver,KIE_PROPERTY_PROFILE),[STEP]);assertEquals(r.calls,[]);
  assertEquals(requests.length,1);const u=requests[0];
  assertEquals([u.pathname,u.searchParams.get("id"),u.searchParams.has("task"),u.searchParams.has("enabled")],["/rest/v1/ai_routes","eq."+KIE.route_id,false,false]);
  for(const column of["id","task","provider","model","unit","unit_cents","privacy_tier","enabled","retire_after","params"])assert(u.searchParams.get("select")!.split(",").includes(column),column);
  mode="error";const e=await assertRejects(()=>Q.propertyVideoQualitySteps("starter",r.resolver,KIE_PROPERTY_PROFILE),HttpError);assertEquals(e.status,503);
  assert(!requests.some(x=>/app_config|plan_routing_policy|provider_health/.test(x.pathname)));
 }finally{globalThis.fetch=old;}
});

Deno.test("FAL profiles keep the resolver path unchanged and never return a Kie step; legacy has no quality step",async()=>{
 const outputs:unknown[]=[];
 for(const profile of[undefined,P,S]){
  const r=recorder(),p=pinned();const steps=await Q.propertyVideoQualitySteps("pro",r.resolver,profile,p.reader);
  assertEquals(r.calls,[{task:Q.PROPERTY_VIDEO_QUALITY_TASK,context:{plan:"pro",needs:["i2v","1080p","5s","native4k","preserve_photo"],carries_customer_media:true}}]);
  assertEquals(p.ids,[],"FAL never reads the pinned Kie row");assertEquals(steps,[{...FAL_STEP,task:"video.reel_clip"}]);outputs.push(steps);
 }
 assertEquals(outputs[1],outputs[0]);assertEquals(outputs[2],outputs[0]);
 const kieShaped={...STEP,task:Q.PROPERTY_VIDEO_QUALITY_TASK};
 for(const rows of[[kieShaped],[{...FAL_STEP,provider:"kie"}],[{...FAL_STEP,privacy_tier:"trains_by_default"}],[FAL_STEP,FAL_STEP],[]])for(const profile of[undefined,P,S])
  await assertRejects(()=>Q.propertyVideoQualitySteps("pro",recorder(rows).resolver,profile,pinned().reader),HttpError);
 const r=recorder();await assertRejects(()=>Q.propertyVideoQualitySteps("pro",r.resolver,"legacy",pinned().reader),HttpError);assertEquals(r.calls,[]);
});

Deno.test("dispatch scope, re-read comparison and exact input guards",async()=>{
 const identity=()=>JSON.parse(JSON.stringify(KIE));
 const request={aspect:"9:16",seconds:5,framing:"preserve_photo",presetVersion:1,customPrompt:undefined,assetId:undefined,sourceAssetId:"e1000000-0000-4000-8000-000000000004"};
 assertEquals(Q.assertKiePropertyDispatchScope({qualityIdentity:identity(),targetAspect:"9:16"},request),"9:16");
 for(const scope of[undefined,{targetAspect:"9:16"},{qualityIdentity:{...identity(),sound:true},targetAspect:"9:16"},{qualityIdentity:identity(),targetAspect:"16:9"}])
  assertEquals(assertThrows(()=>Q.assertKiePropertyDispatchScope(scope,request),HttpError).status,409);
 for(const change of[{aspect:"1:1"},{seconds:6},{framing:undefined},{presetVersion:undefined},{customPrompt:"zoom"},{assetId:"asset"},{sourceAssetId:undefined}])
  assertThrows(()=>Q.assertKiePropertyDispatchScope({qualityIdentity:identity(),targetAspect:"9:16"},{...request,...change}),HttpError);
 // The post-hold re-read compares the RAW pinned row (re-validated against the identity) with the reserved step.
 assert(Q.samePinnedKieDispatch(ROW,STEP,identity()));
 for(const frozen of[undefined,null,{...identity(),unit_cents:9},{...identity(),extra:1}])assert(!Q.samePinnedKieDispatch(ROW,STEP,frozen));
 for(const change of[{id:"other"},{task:"video.aerial"},{provider:"fal"},{model:"kling-3.0/pro"},{unit:"call"},{unit_cents:9},{params:{kie_mode:"pro",sound:false}},{params:null},
  {position:2},{retire_after:day(30)},{capabilities:["i2v"]}])
  assert(!Q.samePinnedKieDispatch({...ROW,...change},STEP,identity()),"re-read row "+JSON.stringify(change));
 for(const change of[{route_id:"other"},{task:"video.aerial"},{provider:"fal"},{model:"kling-3.0/pro"},{unit:"call"},{unit_cents:9},{params:{kie_mode:"pro",sound:false}},{params:null}])
  assert(!Q.samePinnedKieDispatch(ROW,{...STEP,...change},identity()),"reserved step "+JSON.stringify(change));
 const input={task:"video.reel_clip",prompt:"steady",image_url:"data:image/jpeg;base64,AAAA",seconds:5,resolution:"1080p" as const,aspect:"9:16" as const,framing:"preserve_photo" as const,
  extra:{kie_mode:"4K",sound:false,property_video_target_aspect:"9:16",property_video_quality_profile:KIE_PROPERTY_PROFILE}};
 assert(Q.kiePropertyInputExact(input));assertEquals(Q.kiePropertyExtra("9:16"),input.extra);
 for(const change of[{task:"video.aerial"},{prompt:""},{image_url:undefined},{seconds:6},{resolution:"4k"},{aspect:"1:1"},{framing:undefined},{image_b64:"AAAA"},{mask_url:"https://x.invalid"},
  {extra:{...input.extra,sound:true}},{extra:{...input.extra,kie_mode:"pro"}},{extra:{...input.extra,property_video_target_aspect:"16:9"}},{extra:{...input.extra,property_video_quality_profile:S}},
  {extra:{...input.extra,aspect_ratio:"9:16"}},{extra:undefined}])assert(!Q.kiePropertyInputExact({...input,...change} as typeof input),JSON.stringify(change));
});

Deno.test("provider input: exact owned object re-checked, presigned for7200s, inline photo replaced; every gap is a definite refusal",async()=>{
 const input={task:"video.reel_clip",prompt:"steady",image_url:"data:image/jpeg;base64,AAAA",seconds:5,resolution:"1080p" as const,aspect:"16:9" as const,framing:"preserve_photo" as const,extra:Q.kiePropertyExtra("16:9")};
 const location={bucket:"uploads" as const,storage_key:"uploads/org/listing/prepared.jpg",etag:'"exact"',bytes:42,content_type:"image/jpeg"};
 const good={exists:true,bytes:42,etag:'"exact"',contentType:"image/jpeg; charset=binary"};
 const deps=(head:unknown=good,url="https://r2.fixture.invalid/signed?X-Amz-Signature=x")=>{const calls:unknown[]=[];return{calls,head:async(bucket:string,key:string)=>{calls.push(["head",bucket,key]);if(head instanceof Error)throw head;return head as typeof good;},
  sign:async(bucket:string,key:string,seconds:number)=>{calls.push(["sign",bucket,key,seconds]);return url;}};};
 const d=deps();assertEquals(await Q.kiePropertyProviderInput(input,location,d),{...input,image_url:"https://r2.fixture.invalid/signed?X-Amz-Signature=x"});
 assertEquals(d.calls,[["head","uploads",location.storage_key],["sign","uploads",location.storage_key,7200]]);assertEquals(Q.KIE_PROPERTY_SOURCE_URL_SECONDS,7200);
 const refusals:[unknown,typeof input,ReturnType<typeof deps>][]=[[null,input,deps()],[undefined,input,deps()],[location,{...input,extra:{...input.extra,sound:true}},deps()],
  [location,input,deps({...good,etag:'"other"'})],[location,input,deps({...good,bytes:43})],[location,input,deps({...good,contentType:"image/png"})],[location,input,deps({exists:false,bytes:null,etag:null,contentType:null})],
  [location,input,deps(new Error("R2 HEAD failed"))],[location,input,deps(good,"http://r2.fixture.invalid/plain")],[location,input,deps(good,"data:image/jpeg;base64,AAAA")]];
 for(const[at,value,dep]of refusals){
  const e=await assertRejects(()=>Q.kiePropertyProviderInput(value,at as typeof location,dep),ProviderError);
  assertEquals([e.provider,e.error_class,e.status,e.dispatch_rejected],["kie","validation",0,true]);
 }
 assertEquals(refusals[2][2].calls,[],"An inexact recipe is refused before any storage read");
});

Deno.test("priced basis keeps exact fractional cents and the bounded worst case",()=>{
 for(const count of[1,3,7,20,100]){
  assertEquals(Q.kiePropertyPricedBasis(count),{provider:"kie",model:"kling-3.0/video",mode:"4K",unit:"second",unit_cents:33.5,attempt_cents:167.5,credits_per_second:67,usd_per_credit:0.005,
   price_source:"https://kie.ai/kling-3-0",price_checked:"2026-10-16",bonus_credits_excluded:true,max_paid_attempts_per_source:2,expected_generation_cents:167.5*count,worst_case_generation_cents:335*count});
 }
 assertEquals(Q.kiePropertyPricedBasis(3).expected_generation_cents,502.5);
});

Deno.test("compiled defect controls: each selection guard is load-bearing",async()=>{
 // 1. Kie routed through the FAL resolver: the control returns a FAL step for the Kie profile.
 const router=await mutant(["if(profile===PROPERTY_VIDEO_KIE_PROFILE){","if(false){"],["assert(profile===undefined||profile===PROPERTY_VIDEO_QUALITY_PROFILE","assert(true||profile===PROPERTY_VIDEO_QUALITY_PROFILE"]);
 assertEquals((await router.propertyVideoQualitySteps("team",recorder().resolver,KIE_PROPERTY_PROFILE,pinned().reader))[0].provider,"fal");
 // 2-5. Each identity comparison removed: the drifted row is accepted.
 for(const[anchor,patch]of[["catalogCents(r.unit_cents)!==k.unit_cents",{unit_cents:9}],['Object.keys(p).sort().join(",")==="kie_mode,sound"',{params:{kie_mode:"4K",sound:false,aspect_ratio:"16:9"}}],
  ["r.privacy_tier!==k.privacy_tier",{privacy_tier:"retained_30d"}],["retire>now.toISOString().slice(0,10)",{retire_after:day(-1)}]]as const){
  const weak=await mutant([anchor,anchor.includes("!==")?"false":"true"]);
  assert(weak.kiePropertyRouteStep({...ROW,...patch}),"control accepts drift: "+anchor);
 }
 // 6. Reader keyed by task instead of the primary key.
 const old=globalThis.fetch,seen:URL[]=[];globalThis.fetch=(async(input:RequestInfo|URL,init?:RequestInit)=>{seen.push(new URL(new Request(input,init).url));return Response.json([ROW]);}) as typeof fetch;
 try{const byTask=await mutant(['.eq("id",id)','.eq("task","video.property_reel_clip_kie")']);await byTask.readPinnedRoute(KIE.route_id);assertEquals(seen[0].searchParams.get("id"),null);}
 finally{globalThis.fetch=old;}
 console.log("KIE_SELECTION_COMPILED_CONTROLS=6");
});
