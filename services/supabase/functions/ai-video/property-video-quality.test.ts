import{assert,assertEquals,assertRejects,assertThrows}from"https://deno.land/std@0.224.0/assert/mod.ts";
import{HttpError}from"../_shared/http.ts";
for(const[k,v]of Object.entries({SUPABASE_URL:"https://quality-profile-db.fixture.invalid",SUPABASE_ANON_KEY:"public-fixture",SUPABASE_SERVICE_ROLE_KEY:"service-fixture"}))Deno.env.set(k,v);
const{PROPERTY_VIDEO_QUALITY_PROFILE:P,PROPERTY_VIDEO_QUALITY_TASK:T,PROPERTY_VIDEO_QUALITY_MODEL:M,propertyVideoQualityProfile,currentPropertyVideoQualityProfile,propertyVideoQualitySteps}=await import("./property-video-quality.ts");
const{resetRouterCache}=await import("../_shared/router.ts");
const{propertyVideoRecipeQuote}=await import("./index.ts");
const row={id:"closed-normal-fal4k",task:T,position:1,provider:"fal",model:M,unit:"second",unit_cents:42,capabilities:["i2v","1080p","5s","native4k","preserve_photo"],max_latency_s:900,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"retained_30d",enabled:true,retire_after:null};
async function fixture(run:(requests:URL[])=>Promise<void>,options:{profile?:unknown;route?:Record<string,unknown>;missing?:boolean;routerOff?:boolean}={}){
 const old=fetch,requests:URL[]=[];resetRouterCache();
 globalThis.fetch=async(input,init)=>{const req=new Request(input,init),u=new URL(req.url);requests.push(u);assertEquals(u.hostname,"quality-profile-db.fixture.invalid","No external/provider request");
 if(u.pathname.endsWith("/rpc/property_video_quality_profile"))return Response.json(options.profile??P);
 if(u.pathname.endsWith("/rpc/org_entitlement"))return Response.json({plan:"starter",cogs_ceiling_cents:2032,reels_per_month:30,seats:1,renders_per_month:3,photo_edits_per_month:50,aerials_per_month:3,topaz_per_month:0,price_cents:4900});
 if(u.pathname.endsWith("/app_config"))return Response.json({value:{enabled:!options.routerOff}});
 if(u.pathname.endsWith("/plan_routing_policy"))return Response.json([{plan:"starter",policy:"cheapest"},{plan:"pro",policy:"best"},{plan:"team",policy:"best"}]);
 if(u.pathname.endsWith("/provider_health"))return Response.json([]);
 if(u.pathname.endsWith("/ai_routes")){
  const task=u.searchParams.get("task");
  if(task==="eq."+T){const s={...row,...options.route};return Response.json(options.missing||u.searchParams.get("note")==="eq.legacy"||s.enabled!==true?[]:[s]);}
  if(task==="eq.judge.qc_drift")return Response.json([{...row,task:"judge.qc_drift",provider:"anthropic",model:"claude-sonnet-5",unit:"call",unit_cents:1.3,capabilities:["classifier","vision","multi_image"]}]);
  if(task==="eq.video.reel_clip")return Response.json([{...row,task:"video.reel_clip",model:"bytedance/seedance/v1/pro/fast/image-to-video",unit_cents:4.86}]);
 }
 throw Error("Unexpected closed request "+u.pathname);
 };try{await run(requests);}finally{globalThis.fetch=old;resetRouterCache();}
}
Deno.test("server profile parser never accepts an arbitrary model/body claim",()=>{
 for(const x of[undefined,null,"legacy"])assertEquals(propertyVideoQualityProfile(x),"legacy");
 assertEquals(propertyVideoQualityProfile(P),P);
 for(const x of["fal","4K",{},false,"legacy "])assertThrows(()=>propertyVideoQualityProfile(x),HttpError);
});
Deno.test("ordinary property selector uses actual plan/privacy/capability resolver and isolated task",async()=>{
 await fixture(async(reqs)=>{
  for(const plan of["trial","starter","pro","team"]){const s=await propertyVideoQualitySteps(plan);assertEquals(s.length,1);assertEquals([s[0].provider,s[0].model,s[0].unit_cents,s[0].task],["fal",M,42,"video.reel_clip"]);}
  const reads=reqs.filter(u=>u.pathname.endsWith("/ai_routes"));assert(reads.every(u=>u.searchParams.get("task")==="eq."+T&&u.searchParams.get("enabled")==="eq.true"));
 });
 for(const route of[{privacy_tier:"trains_by_default"},{min_plan:"team"},{retire_after:"2026-01-01"},{capabilities:["i2v","1080p","5s"]},{unit_cents:41},{model:"fal-ai/kling-video/v3/pro/image-to-video"},{provider:"kie"},{enabled:false}])await fixture(async()=>{await assertRejects(()=>propertyVideoQualitySteps("starter"),HttpError);},{route});
 for(const opts of[{missing:true},{routerOff:true}])await fixture(async()=>{await assertRejects(()=>propertyVideoQualitySteps("starter"),HttpError);},opts);
});
Deno.test("actual whole quote pins ordinary210c per shot independently of owner grant and returns saved profile",async()=>{
 await fixture(async(reqs)=>{
  assertEquals(await currentPropertyVideoQualityProfile(),P);
  for(const aspect of["16:9","9:16"]as const)for(const count of[1,20,100]){
   const q=await propertyVideoRecipeQuote("actor","org","listing",aspect,count);
   assertEquals([q.quality_profile,q.provider,q.model,q.reel_cents],[P,"fal",M,210*count]);assert(q.qc_cents>0&&q.estimated_cents>=210*count+q.qc_cents);
  }
  assert(!reqs.some(u=>u.pathname.endsWith("/profiles")),"ordinary path cannot request admin QA override");
 });
});
Deno.test("saved v1 resume quote ignores today's OFF default; forced legacy does not read the new task",async()=>{
 await fixture(async(reqs)=>{
  const q=await propertyVideoRecipeQuote("actor","org","listing","9:16",2,P);assertEquals(q.quality_profile,P);assertEquals(q.reel_cents,420);
  assert(!reqs.some(u=>u.pathname.endsWith("/rpc/property_video_quality_profile")));
 },{profile:"legacy"});
 await fixture(async(reqs)=>{
  const q=await propertyVideoRecipeQuote("not-a-uuid","org","listing","9:16",2,"legacy");assertEquals(q.quality_profile,"legacy");assertEquals(q.reel_cents,48.6);
  assert(!reqs.some(u=>u.searchParams.get("task")==="eq."+T));
 });
});
Deno.test("actual trusted worker projection preserves saved profile for new and historical jobs",async()=>{
 const source=await Deno.readTextFile(new URL("../property-video-worker/engine.ts",import.meta.url));
 const start=source.indexOf("async function aiScope("),end=source.indexOf("\nasync function callAI(",start);assert(start>0&&end>start);
 const text=source.slice(start,end).replace("async function aiScope(","export async function aiScope(");
 const m=await import("data:application/typescript,"+encodeURIComponent("type AiVideoWorkerScope=any;const scope=async()=>true;"+text));
 for(const profile of[undefined,"legacy",P]){const s=await m.aiScope({job:{actor_id:"actor",listing_id:"property",manifest:{aspect:"9:16"},quality_profile:profile},source:{}});assertEquals(s.qualityProfile,profile??"legacy");}
 const mutant=await import("data:application/typescript,"+encodeURIComponent("type AiVideoWorkerScope=any;const scope=async()=>true;"+text.replace("qualityProfile:j.quality_profile??'legacy',","")));
 const broken=await mutant.aiScope({job:{actor_id:"actor",listing_id:"property",manifest:{aspect:"9:16"},quality_profile:P},source:{}});
 assert(broken.qualityProfile!==P,"compiled omitted profile must expose silent legacy dispatch");
});
