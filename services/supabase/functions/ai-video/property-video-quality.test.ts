import{assert,assertEquals,assertRejects,assertThrows}from"https://deno.land/std@0.224.0/assert/mod.ts";
import{HttpError}from"../_shared/http.ts";
for(const[k,v]of Object.entries({SUPABASE_URL:"https://quality-profile-db.fixture.invalid",SUPABASE_ANON_KEY:"public-fixture",SUPABASE_SERVICE_ROLE_KEY:"service-fixture"}))Deno.env.set(k,v);
const{PROPERTY_VIDEO_QUALITY_PROFILE:P,PROPERTY_VIDEO_STEADY_PROFILE:S,PROPERTY_VIDEO_QUALITY_TASK:T,PROPERTY_VIDEO_QUALITY_MODEL:M,propertyVideoQualityProfile,currentPropertyVideoQualityProfile,propertyVideoQualitySteps}=await import("./property-video-quality.ts");
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
 for(const profile of[undefined,"legacy",P,S]){const s=await m.aiScope({job:{actor_id:"actor",listing_id:"property",manifest:{aspect:"9:16"},quality_profile:profile},source:{}});assertEquals(s.qualityProfile,profile??"legacy");}
 const mutant=await import("data:application/typescript,"+encodeURIComponent("type AiVideoWorkerScope=any;const scope=async()=>true;"+text.replace("qualityProfile:j.quality_profile??'legacy',","")));
 const broken=await mutant.aiScope({job:{actor_id:"actor",listing_id:"property",manifest:{aspect:"9:16"},quality_profile:P},source:{}});
 assert(broken.qualityProfile!==P,"compiled omitted profile must expose silent legacy dispatch");
});

Deno.test("steady-v2 is prospective, reuses exact funded route and saved quotes ignore the default",async()=>{
 assertEquals(propertyVideoQualityProfile(S),S);
 await fixture(async(reqs)=>{const v1=await propertyVideoRecipeQuote('actor','org','listing','16:9',2,P);const v2=await propertyVideoRecipeQuote('actor','org','listing','16:9',2,S);assertEquals({...v2,quality_profile:P},v1);assert(!reqs.some(u=>u.pathname.endsWith('/rpc/property_video_quality_profile')));},{profile:'legacy'});
});

Deno.test('actual generation prompt branch switches only saved steady-v2 and omission loses the motorized contract',async()=>{
 const src=await Deno.readTextFile(new URL('./index.ts',import.meta.url)),start=src.indexOf('const reelText ='),end=src.indexOf('// When the caller supplied free text',start);assert(start>0&&end>start);
 const fragment=src.slice(start,end),prefix=`import{buildSteadyPropertyReelPrompt,buildPropertyCanvasReelPrompt,buildPhotoPreservingReelPrompt}from ${JSON.stringify(new URL('./reel-framing.ts',import.meta.url).href)};
 const PROPERTY_VIDEO_STEADY_PROFILE='fal-kling3-4k-steady-v2';const SCENE_NOUN={real_estate:'home'};const REEL_PRESETS=['fly_through','push_in','side_glide','pull_back']as const;
 const buildSeedanceReelPreset=()=>{throw Error('unexpected legacy branch')},guardedUserPrompt=buildSeedanceReelPreset,buildReelPrompt=buildSeedanceReelPreset;
 export function select(savedQualityProfile:string){const worker={targetAspect:'16:9' as const},presetVersion=1,framing='preserve_photo',space='real_estate',shotMotion='fly_through',userMotion='';`;
 const compile=async(code:string)=>await import('data:application/typescript,'+encodeURIComponent(prefix+code+'return reelText;}'));
 const actual=await compile(fragment),oracle=(text:string)=>assert(text.includes('motorized slider'));oracle(actual.select(S));assert(actual.select(P).includes('calm indoor drone glide'));
 const mutant=await compile(fragment.replace('savedQualityProfile===PROPERTY_VIDEO_STEADY_PROFILE && worker?.targetAspect','false'));
 assertThrows(()=>oracle(mutant.select(S)),Error,undefined,'Compiled omission must fail the same motorized prompt oracle');
});

Deno.test('actual CPU action binds saved24 profile and matching narration limit without changing old task shape',async()=>{
 const src=await Deno.readTextFile(new URL('../property-video-worker/engine.ts',import.meta.url)),start=src.indexOf('export async function action(');assert(start>0);
 const prefix=`import{isPhotoMotion}from ${JSON.stringify(new URL('../_shared/photo-motion.ts',import.meta.url).href)};type WorkerAction=any;type ComposeAction=any;const PROPERTY_VIDEO_STEADY_PROFILE='fal-kling3-4k-steady-v2';const KIE_PROPERTY_PROFILE='kie-kling3-4k-steady-v1';const scope=async()=>{};const seconds=()=> 'closed-expiry';const media=async(c:any)=>c;const bytesFrom=async()=>({sha256:'exact'});const assert=(ok:boolean)=>{if(!ok)throw Error('assert')};const rpc=async()=>({});const headObject=async()=>({});const bucket=(x:any)=>x;
 const adminClient=()=>({from:()=>{const q:any={select:()=>q,eq:()=>q,maybeSingle:async()=>({error:null,data:{state:'ready',storage_key:'saved-voice',bytes:12,sha256:'a'.repeat(64),etag:'owned',mime:'audio/mp4'}})};return q;}});`;
 const compile=async(code:string)=>await import('data:application/typescript,'+encodeURIComponent(prefix+code));
 const actual=await compile(src.slice(start));
 const j=(profile:string)=>({id:'job',quality_profile:profile,source_count:2,manifest_sha256:'manifest',compose_lease:'lease',audio_lease:'audio-lease',output_asset_id:'out',poster_asset_id:'poster',manifest:{purpose:'listing',aspect:'16:9',presentation:{transition:'dissolve'}}});
 const sources=[{position:0,state:'ready',clip:{sha256:'first',bytes:1}},{position:1,state:'ready',clip:{sha256:'second',bytes:2}}];
 const old=await actual.action({action:'compose',job:j(P),sources}),steady=await actual.action({action:'compose',job:j(S),sources});
 assertEquals(old.composition_profile,undefined);assertEquals(steady.composition_profile,'steady-v2-cfr24');const{composition_profile,...rest}=steady;assertEquals(rest,old);assertEquals(steady.sources.map((x:any)=>x.sha256),['first','second']);
 for(const [profile,max]of[[P,10-8/30],[S,10-6/24]]as const){const job=j(profile);(job.manifest as any).narration_asset_id='saved';assertEquals((await actual.action({action:'inspect_audio',job})).max_duration_s,max);}
 const bad=await compile(src.slice(start).replace("steady?{composition_profile:'steady-v2-cfr24' as const}:{}",'{}'));assertEquals((await bad.action({action:'compose',job:j(S),sources})).composition_profile,undefined,'Compiled omitted profile exposes silent30fallback');
});
