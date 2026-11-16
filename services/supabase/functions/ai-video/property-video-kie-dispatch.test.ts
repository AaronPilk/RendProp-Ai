// Kie native-4K property dispatch through the ACTUAL /reel-clip route source.
// The handler prelude and the whole reel-clip route are compiled from index.ts
// with index.ts's own import block, so verification (verifyPropertyVideoInput),
// the pinned route read (property-video-quality.ts -> Supabase REST),
// submitReservedVideo, fundedAttempt, runChain and ProviderError mapping are the
// production modules. Only I/O edges are doubles: worker scope, allowance
// charge, R2 HEAD/presign, the Supabase RPC client used by the route, the
// status envelope and the provider adapter (the Kie wire belongs to kie.ts and
// is pinned by its own lane). Every network request is answered by a closed
// in-process transport; nothing reaches a provider or a real database.
import {assert,assertEquals,assertNotEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
for(const[k,v]of Object.entries({SUPABASE_URL:"https://kie-dispatch-db.fixture.invalid",SUPABASE_ANON_KEY:"public-fixture",SUPABASE_SERVICE_ROLE_KEY:"service-fixture"}))Deno.env.set(k,v);
for(const k of["SUPABASE_SECRET_KEYS","RENDPROP_SECRET_KEY_NAME","SUPABASE_PUBLISHABLE_KEYS","RENDPROP_PUBLISHABLE_KEY_NAME"])Deno.env.delete(k);
// The Kie profile refuses before any spend without its provider secret. This is
// a synthetic fixture string (never a credential); the adapter is a double here.
const FIXTURE_KIE_KEY="offline-fixture-kie-key-MUST-NOT-BE-LOGGED",KIE_KEY_BEFORE=Deno.env.get("KIE_API_KEY");
Deno.env.set("KIE_API_KEY",FIXTURE_KIE_KEY);

const FUNCTIONS=new URL("../",import.meta.url);
const INDEX=new URL("ai-video/index.ts",FUNCTIONS),QUALITY=new URL("ai-video/property-video-quality.ts",FUNCTIONS);
const KIE_MODULE=new URL("_shared/property-video-kie.ts",FUNCTIONS),FRAMING=new URL("ai-video/reel-framing.ts",FUNCTIONS);
const REGISTRY=new URL("_shared/property-video-prompt-registry.ts",FUNCTIONS);
const IDENTITY_MODULE=new URL("_shared/property-video-kie-identity.ts",FUNCTIONS);
const {KIE_PROPERTY_IDENTITY:KIE,KIE_PROPERTY_PROFILE}=await import(KIE_MODULE.href);
const {resetRouterCache}=await import(new URL("_shared/router.ts",FUNCTIONS).href);
const {resetServingModeCache}=await import(new URL("_shared/funded-serving.ts",FUNCTIONS).href);
const {resolveChain:realResolveChain}=await import(new URL("_shared/providers/chain.ts",FUNCTIONS).href);
const {ProviderError}=await import(new URL("_shared/providers/common.ts",FUNCTIONS).href);
const {R2_BUCKET_UPLOADS}=await import(new URL("_shared/r2.ts",FUNCTIONS).href);
const {buildSteadyPropertyReelPrompt}=await import(FRAMING.href);

const enc=(s:string)=>{const b=new TextEncoder().encode(s);let out="";for(let i=0;i<b.length;i+=32768)out+=String.fromCharCode(...b.subarray(i,i+32768));return "data:application/typescript;base64,"+btoa(out);};
const absolute=(text:string,base:URL,overrides:Record<string,string>={})=>text.replace(/from\s+(["'])(\.\.?\/[^"']+)\1/g,(_a,_q,path)=>{const href=new URL(path,base).href;return `from ${JSON.stringify(overrides[href]??href)}`;});
const between=(text:string,start:string,end:string)=>{const a=text.indexOf(start),b=text.indexOf(end,a+start.length);assert(a>=0&&b>a,"Actual route anchor changed: "+start);return text.slice(a,b);};
const fn=(text:string,name:string)=>{const m=new RegExp(`(?:export )?(?:async )?function ${name}\\(`).exec(text);assert(m,"Actual helper missing: "+name);return text.slice(m.index,text.indexOf("\n}\n",m.index)+3).replace(/^export /,"");};
const once=(text:string,before:string,after:string)=>{assertEquals(text.split(before).length,2,"Mutation anchor must be unique: "+before);return text.replace(before,after);};
const sha=async(value:string|Uint8Array)=>Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",new Uint8Array(typeof value==="string"?new TextEncoder().encode(value):value))),b=>b.toString(16).padStart(2,"0")).join("");
const INDEX_SOURCE=await Deno.readTextFile(INDEX),QUALITY_SOURCE=await Deno.readTextFile(QUALITY);
const KIE_SOURCE=await Deno.readTextFile(KIE_MODULE),FRAMING_SOURCE=await Deno.readTextFile(FRAMING),IDENTITY_SOURCE=await Deno.readTextFile(IDENTITY_MODULE);
const REGISTRY_SOURCE=await Deno.readTextFile(REGISTRY);
const SIGNATURE="export async function handleAiVideo(req:Request,worker?:AiVideoWorkerScope):Promise<Response> {";
/** Compiles the actual handler prelude + reel-clip route. `quality` swaps in a
 * compiled property-video-quality.ts variant; `kie` a compiled
 * _shared/property-video-kie.ts (for index.ts and the quality module alike);
 * `framing` a compiled reel-framing.ts (defect controls only). */
async function compileRoute(indexSource=INDEX_SOURCE,quality?:string,o:{kie?:string;framing?:string;identity?:string;registry?:string}={}){
 const shared:Record<string,string>={},kieText=o.kie??(o.identity?KIE_SOURCE:undefined);
 if(kieText)shared[KIE_MODULE.href]=enc(absolute(kieText,KIE_MODULE,o.identity?{[IDENTITY_MODULE.href]:enc(o.identity)}:{}));
 if(o.framing)shared[FRAMING.href]=enc(absolute(o.framing,FRAMING));
 if(kieText||o.framing||o.registry)shared[REGISTRY.href]=enc(absolute(o.registry??REGISTRY_SOURCE,REGISTRY,shared));
 const qualityText=quality??(kieText?QUALITY_SOURCE:undefined);
 const overrides:Record<string,string>={...shared,...(qualityText?{[QUALITY.href]:enc(absolute(qualityText,QUALITY,shared))}:{})};
 const imports=(indexSource.match(/^import [\s\S]*?;\n/gm)??[]).map(s=>absolute(s,INDEX,overrides)).join("");
 const helpers=[between(indexSource,"const SPACE_TYPES =","interface DroneBody"),fn(indexSource,"cleanPrompt"),fn(indexSource,"legacyVideoStep"),fn(indexSource,"durationNeeds"),fn(indexSource,"buildKieRegisteredPrompt"),
  indexSource.match(/^const ADVERTISED_SECONDS[\s\S]*?\n};\n/m)![0],indexSource.match(/^const MAX_IMAGE_B64_CHARS = [^;]+;/m)![0],
  indexSource.match(/^const ALLOWED_IMAGE_MIMES = [^;]+;/m)![0],indexSource.match(/^const MODEL_I2V = [^;]+;/m)![0]].join("\n");
 const prelude=between(indexSource,SIGNATURE,'    if (req.method === "GET" && seg.length === 1 && seg[0] === "operation")').replace(SIGNATURE,"return async function handleAiVideo(req:Request,worker?:any):Promise<Response> {");
 const route=between(indexSource,"    // ---- POST /ai-video/reel-clip ----","    // ---- POST /ai-video/drift ----");
 return await import(enc(`${imports}
type ReelBody=any;type AiVideoWorkerScope=any;
${helpers}
export function make(stub:any){
 const {getUser,userClient,adminClient,headObject,presignGet,guardGenerate,refundGenerateCharge,routerEnabled,ownerQaReelStep,resolveChain,adapterFor,submitEnvelope,assertVideoReceiptSigningReady,recordProvenance,retainVideoSubmission,resolvePublicAsset,listingSpaceType,contentOrgForUser,putBytes}=stub;
 const admitFundedReelSteps=async(steps:any)=>steps;
 const resolveRoute=(task:any,context:any)=>resolveChain(task,context,{route_id:"synthetic-fal",task,provider:"fal",model:"fal-ai/bytedance/seedance/v1/pro/fast/image-to-video",unit:"second",unit_cents:4.86,capabilities:["i2v","1080p","5s"],enabled:true});
 ${prelude}
${route}
    throw new HttpError(404,"Closed fixture route");
  } catch (err) { return respondError(err); }
 };
}`)) as {make:(stub:unknown)=>(req:Request,worker?:unknown)=>Promise<Response>};
}

const ACTOR="e1000000-0000-4000-8000-000000000001",ORG="e1000000-0000-4000-8000-000000000002",LISTING="e1000000-0000-4000-8000-000000000003",ASSET="e1000000-0000-4000-8000-000000000004";
const BYTES=new TextEncoder().encode("owned-prepared-source-photo-bytes"),B64=btoa(String.fromCharCode(...BYTES)),SOURCE_SHA=await sha(BYTES);
const KEY=`uploads/${ORG}/${LISTING}/prepared-source.jpg`,ETAG='"src-etag"',DB_HOST="kie-dispatch-db.fixture.invalid";
const KIE_ROW={id:KIE.route_id,task:KIE.task,position:1,provider:"kie",model:"kling-3.0/video",unit:"second",unit_cents:33.5,capabilities:["i2v","1080p","5s","native4k","preserve_photo"],
 max_latency_s:1800,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"trains_by_default",enabled:true,retire_after:null,note:"kie-kling3-4k-steady-v1 pinned route",params:{kie_mode:"4K",sound:false}};
const KIE_STEP={route_id:KIE.route_id,task:"video.reel_clip",position:1,provider:"kie",model:"kling-3.0/video",unit:"second",unit_cents:33.5,capabilities:KIE_ROW.capabilities,
 max_latency_s:1800,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"trains_by_default",enabled:true,retire_after:null,params:{kie_mode:"4K",sound:false}};
const FAL_ROW={id:"closed-normal-fal4k",task:"video.property_reel_clip",position:1,provider:"fal",model:"fal-ai/kling-video/v3/4k/image-to-video",unit:"second",unit_cents:42,
 capabilities:["i2v","1080p","5s","native4k","preserve_photo"],max_latency_s:900,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"retained_30d",enabled:true,retire_after:null,note:null,params:null};

type State={events:string[];rpcs:{name:string;args:Record<string,unknown>}[];posts:{provider:string;step:Record<string,unknown>;input:Record<string,unknown>}[];requests:string[];
 signs:{bucket:string;key:string;seconds:number}[];charges:number;refunds:number;resolveChains:number;accepted:unknown;pinned:unknown[];pinnedDefault:unknown;
 heads:{exists:boolean;bytes:number|null;etag:string|null;contentType:string|null}[];servingMode:string;signUrl?:(bucket:string,key:string,seconds:number)=>string;submitError?:unknown;releaseUnconfirmed:boolean;allowanceError?:Error;rpcRefusal?:string;
 /** What had already happened each time the worker's Kie dispatch authority ran. */
 authorityCalls:{events:string[];rpcs:number;requests:number;charges:number}[]};
const state:State={events:[],rpcs:[],posts:[],requests:[],signs:[],charges:0,refunds:0,resolveChains:0,accepted:null,pinned:[],pinnedDefault:KIE_ROW,heads:[],servingMode:"funded",releaseUnconfirmed:false,authorityCalls:[]};
function reset(o:Partial<State>={}){resetRouterCache();resetServingModeCache();
 Object.assign(state,{events:[],rpcs:[],posts:[],requests:[],signs:[],charges:0,refunds:0,resolveChains:0,accepted:null,pinned:[],pinnedDefault:KIE_ROW,heads:[],servingMode:"funded",signUrl:undefined,submitError:undefined,releaseUnconfirmed:false,allowanceError:undefined,rpcRefusal:undefined,authorityCalls:[]},o);}
// One closed transport for every module (supabase-js, funded serving, router telemetry, source read).
globalThis.fetch=(async(input:RequestInfo|URL,init?:RequestInit)=>{
 const req=new Request(input,init),u=new URL(req.url);state.requests.push(`${req.method} ${u.hostname}${u.pathname}${u.search}`);
 if(u.hostname===DB_HOST){
  if(u.pathname==="/rest/v1/rpc/serving_mode")return Response.json(state.servingMode);
  if(u.pathname==="/rest/v1/rpc/report_provider_outcome")return new Response(null,{status:204});
  if(u.pathname==="/rest/v1/ai_routes"&&u.searchParams.get("id")==="eq."+KIE.route_id&&!u.searchParams.has("task")){
   state.events.push("pinned_read");const row=state.pinned.length?state.pinned.shift():state.pinnedDefault;return Response.json(row===undefined?[]:[row]);
  }
  if(u.pathname==="/rest/v1/ai_routes"&&u.searchParams.get("task")==="eq.video.property_reel_clip")return Response.json([FAL_ROW]);
  if(u.pathname==="/rest/v1/app_config")return Response.json({value:{enabled:true}});
  if(u.pathname==="/rest/v1/provider_health")return Response.json([]);
 }
 if(u.hostname==="r2-fixture.invalid"&&req.method==="GET"&&u.searchParams.get("X-Amz-Expires")==="300")return new Response(BYTES,{status:200,headers:{etag:ETAG}});
 throw new Error("Closed fixture refused "+u.hostname+u.pathname);
}) as typeof fetch;
const rpc=async(name:string,args:Record<string,unknown>)=>{state.rpcs.push({name,args});state.events.push(name);
 if(name===state.rpcRefusal)return{data:null,error:{message:"RP402: Fixture allowance unavailable"}};
 if(name==="property_owned_upload")return{data:{actor_id:ACTOR,org_id:ORG,listing_id:LISTING,asset_id:ASSET,bucket:"uploads",storage_key:KEY,bytes:BYTES.length,etag:ETAG,content_type:"image/jpeg",sha256:SOURCE_SHA},error:null};
 if(name==="property_photo_reference")return{data:{},error:null};
 if(name==="app_video_cost_reserve_v2"||name==="serving_cost_reserve")return{data:{reserved:true},error:null};
 if(name==="serving_cost_finish")return{data:{finished:true},error:null};
 // releaseUnconfirmed: the release RPC answers without confirming (the hold stays fenced).
 if(name==="app_video_cost_release_rejected")return{data:{released:!state.releaseUnconfirmed},error:null};
 if(name==="app_video_cost_settle")return{data:{settled:true},error:null};
 if(name==="bind_property_video_source")return{data:{bound:true},error:null};
 if(name==="org_has_internal_testing_grant"||name==="org_has_private_internal_testing")return{data:false,error:null};
 throw new Error("Unexpected closed RPC "+name);};
const stub={
 getUser:()=>{throw new Error("worker path never authenticates HTTP");},userClient:()=>{throw new Error("worker path never uses a user client");},adminClient:()=>({rpc}),
 headObject:async(bucket:string,key:string)=>{state.events.push("head");assertEquals([bucket,key],[R2_BUCKET_UPLOADS,KEY]);return state.heads.shift()??{exists:true,bytes:BYTES.length,etag:ETAG,contentType:"image/jpeg"};},
 presignGet:async(bucket:string,key:string,seconds:number)=>{state.events.push("sign:"+seconds);state.signs.push({bucket,key,seconds});
  return state.signUrl?.(bucket,key,seconds)??`https://r2-fixture.invalid/${bucket}/${key}?X-Amz-Expires=${seconds}&X-Amz-Signature=fixture`;},
 guardGenerate:async()=>{state.events.push("charge");if(state.allowanceError)throw state.allowanceError;state.charges++;return{orgId:ORG,plan:"team",monthlyKey:"m",burstKey:"b",monthlyReceipt:{windowStart:"2026-10-16T00:00:00Z"},burstReceipt:{windowStart:"2026-10-16T01:00:00Z"}};},
 refundGenerateCharge:async()=>{state.events.push("refund");state.refunds++;},routerEnabled:async()=>false,
 ownerQaReelStep:async()=>{throw new Error("Owner QA is unreachable for saved quality profiles");},
 resolveChain:async(...args:Parameters<typeof realResolveChain>)=>{state.resolveChains++;return await realResolveChain(...args);},
 adapterFor:(provider:string)=>({submit:async(step:Record<string,unknown>,input:Record<string,unknown>)=>{
  // An adapter-side refusal before any request exists (e.g. kie.ts with no secret).
  if(state.submitError){state.events.push("adapter_refused");throw state.submitError;}
  state.events.push("POST");state.posts.push({provider,step,input});
  return{provider,model:step.model,id:"provider-accepted-task",submitted_at:"2026-10-16T00:00:00.000Z"};}}),
 submitEnvelope:async(_req:Request,_on:boolean,_task:string,ref:{id:string})=>({request_id:ref.id,status_url:"https://fixture.invalid/ai-video/status?job=opaque",response_url:"https://fixture.invalid/ai-video/status?job=opaque"}),
 assertVideoReceiptSigningReady:async()=>{},recordProvenance:async()=>{throw new Error("worker provenance only");},retainVideoSubmission:async()=>{throw new Error("worker never journals HTTP receipts");},
 resolvePublicAsset:async()=>{throw new Error("asset path unreachable");},listingSpaceType:async()=>"real_estate",contentOrgForUser:async()=>ORG,putBytes:async()=>{throw new Error("no staging");},
};
/** Postgres jsonb object key order: by UTF-8 byte length, then bytewise, at every level. */
const byteOrder=(a:string,b:string)=>{const x=new TextEncoder().encode(a),y=new TextEncoder().encode(b);if(x.length!==y.length)return x.length-y.length;for(let i=0;i<x.length;i++)if(x[i]!==y[i])return x[i]-y[i];return 0;};
const reorder=(value:unknown,order:(keys:string[])=>string[]):any=>Array.isArray(value)?value.map(v=>reorder(v,order)):value&&typeof value==="object"
 ?Object.fromEntries(order(Object.keys(value)).map(k=>[k,reorder((value as Record<string,unknown>)[k],order)])):value;
const jsonbOrder=(value:unknown)=>reorder(value,keys=>[...keys].sort(byteOrder));
const reversedOrder=(value:unknown)=>reorder(value,keys=>[...keys].reverse());
const CANONICAL_IDENTITY=()=>JSON.parse(JSON.stringify(KIE));
/** What the worker forwards from property_video_jobs.quality_identity: the jsonb read back in jsonb key order. */
const IDENTITY=()=>jsonbOrder(CANONICAL_IDENTITY());
function worker(o:{profile?:string;identity?:unknown;aspect?:"16:9"|"9:16";failAuthorizeAt?:number;authority?:"missing"|Error}={}){
 let calls=0;
 return{user:{id:ACTOR,is_anonymous:false},listing:LISTING,targetAspect:o.aspect??"16:9",qualityProfile:o.profile??KIE_PROPERTY_PROFILE,...("identity" in o?{qualityIdentity:o.identity}:{qualityIdentity:IDENTITY()}),
  authorize:async()=>{calls++;state.events.push("authorize");if(o.failAuthorizeAt===calls)throw new Error("closed lease moved to another account");},
  // engine.ts's per-dispatch Kie supplier authority (SQL property_video_kie_dispatch_authority).
  ...(o.authority==="missing"?{}:{kieDispatchAuthority:async()=>{
   state.authorityCalls.push({events:[...state.events],rpcs:state.rpcs.length,requests:state.requests.length,charges:state.charges});state.events.push("kie_dispatch_authority");
   if(o.authority instanceof Error)throw o.authority;return{authority:"activated_profile"};}}),
  accepted:async(receipt:unknown)=>{state.accepted=receipt;},provenance:async()=>({id:"e1000000-0000-4000-8000-000000000009",recorded:true,disclosure:"AI motion from photographs"})};
}
/** Exactly the body property-video-worker/engine.ts dispatch() sends. */
function dispatchRequest(o:{aspect?:string;motion?:string;body?:Record<string,unknown>}={}){
 return new Request("https://functions.rendprop.invalid/ai-video/reel-clip",{method:"POST",headers:{"x-org-id":ORG,"idempotency-key":"kie-source-attempt-0001","content-type":"application/json"},
  body:JSON.stringify({image_b64:B64,mime:"image/jpeg",listing_id:LISTING,source_asset_id:ASSET,source_provenance_id:null,seconds:5,preset_version:1,framing:"preserve_photo",aspect:o.aspect??"16:9",motion:o.motion??"side_glide",...o.body})});
}
const actual=await compileRoute();
async function run(w:unknown,req=dispatchRequest(),route=actual){const res=await route.make(stub)(req,w);return{status:res.status,body:await res.json()};}
const quiet=async<T>(f:()=>Promise<T>)=>{const old=console.error;console.error=()=>{};try{return await f();}finally{console.error=old;}};
const reservedInput=(aspect:"16:9"|"9:16",motion:string)=>({task:"video.reel_clip",prompt:buildSteadyPropertyReelPrompt("home",motion,aspect),image_url:`data:image/jpeg;base64,${B64}`,
 seconds:5,resolution:"1080p",aspect,framing:"preserve_photo",extra:{kie_mode:"4K",sound:false,property_video_target_aspect:aspect,property_video_quality_profile:KIE_PROPERTY_PROFILE}});
const presigned=(seconds:number)=>`https://r2-fixture.invalid/${R2_BUCKET_UPLOADS}/${KEY}?X-Amz-Expires=${seconds}&X-Amz-Signature=fixture`;
const noSpend=()=>{assertEquals(state.posts,[]);assert(!state.events.includes("sign:7200"),"No vendor source capability was minted");};
const KIE_EVENTS=["authorize","property_owned_upload","property_photo_reference","head","sign:300","head","charge","pinned_read","authorize","app_video_cost_reserve_v2",
 "authorize","serving_cost_reserve","authorize","pinned_read","head","sign:7200","kie_dispatch_authority","POST","serving_cost_finish","app_video_cost_settle","bind_property_video_source"];

Deno.test("actual Kie dispatch: pinned step, steady prompt, presigned owned source, exact input and167.5c holds in both funding modes",async()=>{
 for(const servingMode of["funded","ceiling"])for(const aspect of["16:9","9:16"]as const)for(const motion of["fly_through","side_glide"]){
  reset({servingMode});const r=await run(worker({aspect}),dispatchRequest({aspect,motion}));
  assertEquals(r.status,202,JSON.stringify(r.body));assertEquals(state.events,KIE_EVENTS);
  assertEquals(state.posts.length,1);const post=state.posts[0];
  assertEquals(post.provider,"kie");assertEquals(post.step,KIE_STEP);
  const reserved=reservedInput(aspect,motion);assertEquals(post.input,{...reserved,image_url:presigned(7200)});
  assertEquals(state.signs.map(x=>[x.bucket,x.key,x.seconds]),[[R2_BUCKET_UPLOADS,KEY,300],[R2_BUCKET_UPLOADS,KEY,7200]]);
  assert(!JSON.stringify(state.posts).includes("data:image"),"Inline source never reaches the URL-only vendor");
  const holds=state.rpcs.filter(x=>x.name==="app_video_cost_reserve_v2"||x.name==="serving_cost_reserve");
  assertEquals(holds.map(x=>[x.name,x.args.p_hold_cents,x.args.p_provider,x.args.p_model]),[["app_video_cost_reserve_v2",167.5,"kie","kling-3.0/video"],["serving_cost_reserve",167.5,"kie","kling-3.0/video"]]);
  assertEquals([holds[0].args.p_units,holds[0].args.p_unit_cost_cents,holds[0].args.p_meta],[5,33.5,{seconds:5,motion,aspect,route_id:KIE.route_id,task:"video.reel_clip",unit:"second",price_estimated:true}]);
  // The hold binds the deterministic server recipe (inline bytes), never a time-varying capability.
  const hash=await sha(JSON.stringify(reserved));assertEquals(holds.map(x=>x.args.p_input_sha256),[hash,hash]);assertNotEquals(hash,await sha(JSON.stringify(post.input)));
  // Router never consulted: two primary-key reads, no flag/policy/health/task scans.
  const db=state.requests.filter(x=>x.includes(DB_HOST));
  assertEquals(db.filter(x=>x.includes("/rest/v1/ai_routes")).length,2);
  assert(db.filter(x=>x.includes("/rest/v1/ai_routes")).every(x=>x.includes(`id=eq.${KIE.route_id}`)&&!x.includes("task=")));
  assert(!db.some(x=>/app_config|plan_routing_policy|provider_health/.test(x)));assertEquals(state.resolveChains,0);
  assertEquals((state.accepted as Record<string,unknown>).model_id,"kling-3.0/video");assertEquals(r.body.model_id,"kling-3.0/video");
  assert(!JSON.stringify(r.body).includes("X-Amz"),"Vendor capability never returned to the worker/app");
  assertEquals([state.charges,state.refunds],[1,0]);
 }
});

Deno.test("prompt profile steady-property-v1: eight pinned texts are exactly what the Kie route sends",async()=>{
 const pinned:Record<string,string>={fly_through:"4aea160430f6683dff51e6400514c402769e70d5fea0eda0607702c63f4917e1",push_in:"d377ea82778f80ce3c9c0768ee9f36d1aaaa6c8053d1eb284c9b577556dfd85e",
  side_glide:"a089bc4084a7c45bca0a9e7dca51375b35bdd0cf245dac25bb5b0e3c076f570d",pull_back:"5984cb8f098612b68313efc9586ca168245c8bf7c927368fcb17aa5afa49974c"};
 assertEquals(KIE.prompt_profile,"steady-property-v1");
 for(const[motion,digest]of Object.entries(pinned))for(const aspect of["16:9","9:16"]as const){
  assertEquals(await sha(buildSteadyPropertyReelPrompt("home",motion,aspect)),digest,`${motion} ${aspect}`);
  reset();assertEquals((await run(worker({aspect}),dispatchRequest({aspect,motion}))).status,202);
  assertEquals(await sha(String(state.posts[0].input.prompt)),digest,"Kie and FAL steady-v2 share the same reviewed prompt bytes");
 }
});

Deno.test("missing or changed frozen identity is refused before verification, allowance, hold, route read or POST",async()=>{
 const changed=(patch:Record<string,unknown>)=>({...IDENTITY(),...patch});
 const {route_id:_r,...withoutRoute}=IDENTITY();
 const pins=()=>({...IDENTITY().prompt_template_sha256}),{push_in:_p,...pinsMissing}=pins();
 const variants:unknown[]=[undefined,null,{},[],"kie-kling3-4k-steady-v1",JSON.stringify(IDENTITY()),withoutRoute,changed({extra:true}),changed({unit_cents:9}),changed({attempt_cents:45}),
  changed({mode:"pro"}),changed({sound:true}),changed({model:"kling-3.0/pro"}),changed({provider:"fal"}),changed({route_id:"7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f22"}),
  changed({task:"video.property_reel_clip"}),changed({privacy_tier:"retained_30d"}),changed({profile:"fal-kling3-4k-steady-v2"}),changed({content_license_ack:"accepted"}),
  changed({output_frames:[121,120]}),changed({max_paid_attempts_per_source:3}),changed({composition_profile:"cfr30"}),
  // Nested drift: extra / missing pinned motion, one changed digest character, reordered noun array.
  changed({prompt_template_sha256:{...pins(),orbit:"0".repeat(64)}}),changed({prompt_template_sha256:pinsMissing}),
  changed({prompt_template_sha256:{...pins(),fly_through:pins().fly_through.slice(0,-1)+(pins().fly_through.endsWith("0")?"1":"0")}}),
  changed({prompt_scene_nouns:[...IDENTITY().prompt_scene_nouns].reverse()}),changed({min_short_side_px:1080})];
 for(const identity of variants){
  reset();const r=await run(worker({identity}));
  assertEquals(r.status,409,JSON.stringify(identity));noSpend();
  assertEquals(state.events,["authorize"],"Only the worker scope check ran");assertEquals([state.charges,state.refunds],[0,0]);
  assert(!state.requests.some(x=>x.includes("/ai_routes")));
 }
});

Deno.test("Kie request outside the one closed worker recipe is refused before any spend",async()=>{
 const cases:{w?:Parameters<typeof worker>[0];req:Request}[]=[
  {w:{aspect:"9:16"},req:dispatchRequest({aspect:"16:9"})},{req:dispatchRequest({body:{aspect:"1:1"}})},{req:dispatchRequest({body:{seconds:6,preset_version:undefined}})},
  {req:dispatchRequest({body:{preset_version:undefined}})},{req:dispatchRequest({body:{framing:undefined}})},{req:dispatchRequest({body:{source_asset_id:undefined}})},
  {req:dispatchRequest({body:{prompt:"slow cinematic push"}})},{req:dispatchRequest({body:{asset_id:ASSET}})}];
 for(const c of cases){reset();const r=await run(worker(c.w),c.req);assert(r.status>=400&&r.status<500,String(r.status));noSpend();
  assertEquals([state.charges,state.refunds],[0,0]);assert(!state.rpcs.some(x=>/reserve/.test(x.name)));assert(!state.requests.some(x=>x.includes("/ai_routes")));}
});

const drifts:Record<string,unknown>[]=[{unit_cents:9},{unit_cents:33.4},{unit_cents:null},{params:{kie_mode:"pro",sound:false}},{params:{kie_mode:"4K",sound:true}},{params:{kie_mode:"4K",sound:false,aspect_ratio:"16:9"}},
 {params:null},{privacy_tier:"retained_30d"},{enabled:false},{model:"kling-3.0/pro"},{provider:"fal"},{task:"video.property_reel_clip"},{unit:"call"},{id:"7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f22"},
 {retire_after:"2026-01-01"},{retire_after:new Date().toISOString().slice(0,10)},{retire_after:"soon"}];
Deno.test("pinned row drift before the hold refuses with503, refunds the allowance and never reserves or POSTs",async()=>{
 for(const patch of[...drifts,{missing:true}]){
  reset({pinnedDefault:"missing" in patch?undefined:{...KIE_ROW,...patch}});const r=await run(worker());
  assertEquals(r.status,503,JSON.stringify(patch));noSpend();assertEquals([state.charges,state.refunds],[1,1]);
  assert(!state.rpcs.some(x=>/reserve/.test(x.name)));assertEquals(state.resolveChains,0);
 }
});

// Columns the pre-hold read accepts (they are not identity fields) but that differ
// from the reserved step: only the post-hold samePinnedKieDispatch comparison sees them.
const STEP_DRIFTS:Record<string,unknown>[]=[{position:2},{capabilities:["i2v","1080p","5s","native4k"]},{max_latency_s:900},{min_plan:"pro"},{same_model_as:null},{retire_after:"2099-12-31"}];
/** A definite pre-dispatch refusal after the hold: no POST, both holds released, allowance refunded. */
function refusedAfterHold(r:{status:number;body:Record<string,unknown>},label:string,tail:string[]){
 assertEquals(r.status,400,label);assertEquals([r.body.provider,r.body.provider_status,r.body.dispatch_rejected],["kie",0,true],label);noSpend();
 const release=state.rpcs.find(x=>x.name==="app_video_cost_release_rejected");assert(release,"definite refusal releases the priced hold: "+label);
 assertEquals([release.args.p_provider_status,release.args.p_error_class],[0,"validation"],label);assertEquals(state.refunds,1,label);
 assertEquals(state.events.slice(-tail.length),tail,label);
 const finish=state.rpcs.find(x=>x.name==="serving_cost_finish")!;assertEquals([finish.args.p_state,finish.args.p_rejection_status],["rejected",0],label);
}
const REREAD_TAIL=["authorize","pinned_read","serving_cost_finish","app_video_cost_release_rejected","refund"];
Deno.test("drift between the reserved read and dispatch is a definite pre-dispatch refusal: hold released, no POST",async()=>{
 for(const patch of[...drifts,...STEP_DRIFTS]){
  reset({pinned:[KIE_ROW,{...KIE_ROW,...patch}]});const r=await quiet(()=>run(worker()));
  refusedAfterHold(r,JSON.stringify(patch),REREAD_TAIL);
 }
});

Deno.test("jsonb key order of the pinned params (either read) is the same row: dispatch proceeds with the canonical recipe",async()=>{
 const jsonbParams={...KIE_ROW,params:jsonbOrder(KIE_ROW.params)},reversedParams={...KIE_ROW,params:reversedOrder(KIE_ROW.params)};
 assertEquals(JSON.stringify(jsonbParams.params),'{"sound":false,"kie_mode":"4K"}',"fixture is in true jsonb order");
 for(const pinned of[[jsonbParams,jsonbParams],[KIE_ROW,jsonbParams],[jsonbParams,reversedParams],[reversedParams,KIE_ROW]]){
  reset({pinned});const r=await run(worker());assertEquals(r.status,202,JSON.stringify(r.body));assertEquals(state.posts.length,1);
  assertEquals(state.posts[0].step,KIE_STEP);assertEquals(state.posts[0].input,{...reservedInput("16:9","side_glide"),image_url:presigned(7200)});
 }
});

Deno.test("pinned row changed between admission and the post-hold re-read: samePinnedKieDispatch is the load-bearing guard",async()=>{
 const named:Record<string,unknown>[]=[{params:{kie_mode:"pro",sound:false}},{params:{sound:true,kie_mode:"4K"}},{unit_cents:33.4},{model:"kling-3.0/pro"},{enabled:false},
  {privacy_tier:"retained_30d"},{retire_after:"2026-01-01"},{retire_after:"2099-12-31"},{task:"video.property_reel_clip"},{id:"7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f22"},...STEP_DRIFTS];
 const guard='if(!samePinnedKieDispatch(await readPinnedRoute(KIE_PROPERTY_ROUTE_ID),step,worker?.qualityIdentity))throw Error("Changed Kie property identity");';
 const unguarded=await compileRoute(once(INDEX_SOURCE,guard,"await readPinnedRoute(KIE_PROPERTY_ROUTE_ID);"));
 for(const patch of named){
  reset({pinned:[KIE_ROW,{...KIE_ROW,...patch}]});refusedAfterHold(await quiet(()=>run(worker())),JSON.stringify(patch),REREAD_TAIL);
  // Defect control: the same drift with the samePinnedKieDispatch condition deleted reaches the vendor.
  reset({pinned:[KIE_ROW,{...KIE_ROW,...patch}]});const leaked=await quiet(()=>run(worker(),dispatchRequest(),unguarded));
  assertEquals([leaked.status,state.posts.length,state.events.filter(e=>e==="pinned_read").length],[202,1,2],"control: drift no longer refused "+JSON.stringify(patch));
  assert(!state.rpcs.some(x=>x.name==="app_video_cost_release_rejected"));
 }
 // The reserved step and the frozen identity are part of the same comparison (unit-level coverage in
 // property-video-kie-guards.test.ts); an unchanged row with the canonical identity dispatches.
 reset({pinned:[KIE_ROW,KIE_ROW]});assertEquals((await run(worker())).status,202);
});

Deno.test("account switch at any worker authority check never reaches the vendor",async()=>{
 // 1 = handler entry, 2 = before the allowance hold RPC, 3 = before the serving hold, 4 = inside the dispatch callback.
 for(const failAuthorizeAt of[1,2,3,4]){
  reset();const r=await quiet(()=>run(worker({failAuthorizeAt})));
  assert(r.status>=400,String(r.status));noSpend();
  if(failAuthorizeAt===1)assertEquals(state.events,["authorize"]);
  // Kie profile: a scope that ended inside the dispatch callback (nothing was sent) is a definite
  // pre-dispatch refusal: the caller sees a refusal, not VideoDispatchUnconfirmed, and the hold is released.
  if(failAuthorizeAt===4){
   refusedAfterHold(r,"Kie scope ended in the dispatch callback",["authorize","serving_cost_finish","app_video_cost_release_rejected","refund"]);
   assertEquals(r.body.error_class,"validation");assert(!state.events.includes("adapter_refused"));
   assertEquals(state.events.filter(e=>e==="pinned_read").length,1,"refused before the post-hold re-read");
  }
 }
});

Deno.test("FAL profiles keep today's contract: a lost scope inside the dispatch callback stays fenced as unconfirmed",async()=>{
 for(const profile of["fal-kling3-4k-steady-v2","fal-kling3-4k-v1"]){
  reset();const r=await quiet(()=>run(worker({profile,identity:undefined,failAuthorizeAt:4})));
  assertEquals(r.status,502,"Existing contract: a lost lease after the hold stays fenced as unconfirmed");noSpend();
  assert(!state.rpcs.some(x=>x.name==="app_video_cost_release_rejected"));assertEquals(state.refunds,0);
  assertEquals(state.events.slice(-2),["authorize","serving_cost_finish"]);
  assertEquals(state.rpcs.find(x=>x.name==="serving_cost_finish")?.args.p_state,"uncertain");
 }
 // Defect control: without the Kie-only wrap, a Kie scope that ended keeps the hold (the pre-fix behaviour).
 const wrap='if(savedQualityProfile==="kie-kling3-4k-steady-v1"){try{await worker.authorize();}catch{throw new ProviderError(step.provider,"validation","The admitted clip scope ended before dispatch.",0,true);}}';
 const unwrapped=await compileRoute(once(INDEX_SOURCE,wrap,"if(false){}"));
 reset();const r=await quiet(()=>run(worker({failAuthorizeAt:4}),dispatchRequest(),unwrapped));
 assertEquals(r.status,502,"control: retained hold reproduced");assert(!state.rpcs.some(x=>x.name==="app_video_cost_release_rejected"));assertEquals(state.refunds,0);
});

Deno.test("owned source changed, missing or unsignable after verification refuses before POST and releases the hold",async()=>{
 const good={exists:true,bytes:BYTES.length,etag:ETAG,contentType:"image/jpeg"};
 for(const third of[{...good,etag:'"replaced"'},{...good,bytes:BYTES.length+1},{...good,contentType:"image/png"},{exists:false,bytes:null,etag:null,contentType:null}]){
  reset({heads:[good,good,third]});const r=await quiet(()=>run(worker()));
  assertEquals(r.status,400);assertEquals(r.body.dispatch_rejected,true);assertEquals(state.posts,[]);assert(state.rpcs.some(x=>x.name==="app_video_cost_release_rejected"));
 }
 for(const signUrl of[(b:string,k:string,s:number)=>s===7200?`http://r2-fixture.invalid/${b}/${k}`:`https://r2-fixture.invalid/${b}/${k}?X-Amz-Expires=${s}&X-Amz-Signature=fixture`]){
  reset({signUrl});const r=await quiet(()=>run(worker()));assertEquals(r.status,400);assertEquals(state.posts,[]);
 }
});

// Captured from the unmodified base (462e4c8) with this same harness and inputs.
const FAL_BASELINE:Record<string,string>={"fal-kling3-4k-steady-v2|16:9":"fa62239c859c612a436601e5c7ba881ca0c022266002632af6a2a99537da9ff4","fal-kling3-4k-steady-v2|9:16":"44c9191bac14110129fbfb2bc39e6a93a64dcb5f7185fa101486750d434b2bf3",
 "fal-kling3-4k-v1|16:9":"a0a0af7e9363f412d6d359f516a531ad1da347ad0fa479b943763528331c8489","fal-kling3-4k-v1|9:16":"8b06cf7845b5874d03d85110eb43ef2f1b7f0c8ef0b51a4510337f31f4728847"};
Deno.test("FAL steady-v2 and v1 dispatch is byte-identical to base: resolver route, inline source, 210c holds, no pinned read",async()=>{
 for(const[key,hash]of Object.entries(FAL_BASELINE)){
  const[profile,aspect]=key.split("|") as [string,"16:9"|"9:16"];reset();
  const r=await run(worker({profile,aspect,identity:undefined}),dispatchRequest({aspect}));assertEquals(r.status,202);
  assertEquals(state.events,["authorize","property_owned_upload","property_photo_reference","head","sign:300","head","charge","authorize","app_video_cost_reserve_v2","authorize","serving_cost_reserve","authorize","POST","serving_cost_finish","app_video_cost_settle","bind_property_video_source"]);
  const post=state.posts[0];assertEquals([post.provider,post.step.route_id,post.step.model,post.step.unit_cents,post.step.task],["fal","closed-normal-fal4k","fal-ai/kling-video/v3/4k/image-to-video",42,"video.reel_clip"]);
  assertEquals(post.input.image_url,`data:image/jpeg;base64,${B64}`);assertEquals(post.input.extra,{property_video_target_aspect:aspect,property_video_quality_profile:profile});
  const holds=state.rpcs.filter(x=>/reserve/.test(x.name));assertEquals(holds.map(x=>[x.args.p_hold_cents,x.args.p_input_sha256]),[[210,hash],[210,hash]]);
  assertEquals(await sha(JSON.stringify(post.input)),hash,"Adapter input equals the reserved base recipe");
  assertEquals(state.requests.filter(x=>x.includes(DB_HOST)).map(x=>new URL("https://"+x.split(" ")[1]).pathname),
   ["/rest/v1/app_config","/rest/v1/ai_routes","/rest/v1/provider_health","/rest/v1/rpc/serving_mode","/rest/v1/ai_routes","/rest/v1/provider_health","/rest/v1/rpc/report_provider_outcome"]);
  assert(!state.requests.some(x=>x.includes("id=eq.")),"FAL never reads the pinned Kie row");assertEquals(state.signs.length,1);
 }
});

Deno.test("Kie dispatch mutation controls preserve pre-spend identity fences and later checks",async()=>{
 const bad=IDENTITY();bad.unit_cents=9;
 // 1. The registered prompt now independently rejects a changed identity before money.
 const noScope=await compileRoute(once(INDEX_SOURCE,'if(savedQualityProfile==="kie-kling3-4k-steady-v1")assertKiePropertyDispatchScope(','if(false)assertKiePropertyDispatchScope('));
 reset();const noScopeResult=await quiet(()=>run(worker({identity:bad}),dispatchRequest(),noScope));assertEquals(noScopeResult.status,503);noSpend();
 // 2. Dispatch re-read removed (the admission-time row compared instead): drift after the hold reaches the vendor.
 const stale=await compileRoute(once(INDEX_SOURCE,"samePinnedKieDispatch(await readPinnedRoute(KIE_PROPERTY_ROUTE_ID),step,",`samePinnedKieDispatch(${JSON.stringify(KIE_ROW)},step,`));
 reset({pinned:[KIE_ROW,{...KIE_ROW,unit_cents:9}]});await quiet(()=>run(worker(),dispatchRequest(),stale));assertEquals(state.posts.length,1,"control exposes a POST after drift");
 // 3. Steady prompt branch removed: Kie would build the v1 canvas prompt. The prompt pin now refuses
 //    that before any spend; with the pin removed as well, the canvas prompt would be sent.
 const promptSource=once(INDEX_SOURCE,'savedQualityProfile==="kie-kling3-4k-steady-v1" && worker?.targetAspect',"false");
 reset();const refused=await quiet(async()=>run(worker(),dispatchRequest(),await compileRoute(promptSource)));assertEquals([refused.status,state.posts.length,state.charges],[503,0,0]);
 const prompt=await compileRoute(once(promptSource,"KIE_PROPERTY_IDENTITY.prompt_scene_nouns.includes(SCENE_NOUN[space])&&await registeredPropertyPromptPinned(worker?.qualityIdentity,reelText,shotMotion)","true"));
 reset();await run(worker(),dispatchRequest(),prompt);assertNotEquals(state.posts[0].input.prompt,buildSteadyPropertyReelPrompt("home","side_glide","16:9"));
 // 4. Pinned params omitted from the recipe: no exact 4K input, so nothing is sent.
 const params=await compileRoute(once(INDEX_SOURCE,'savedQualityProfile==="kie-kling3-4k-steady-v1"?paramsOf(steps[0])??{}:{}',"{}"));
 reset();const p=await quiet(()=>run(worker(),dispatchRequest(),params));assertNotEquals(p.status,202);assertEquals(state.posts,[]);
 // 5. Provider input keeps the inline data URL instead of the presigned owned object.
 const inline=await compileRoute(INDEX_SOURCE,once(QUALITY_SOURCE,"return{...input,image_url:url};","return input;"));
 reset();await run(worker(),dispatchRequest(),inline);assert(String(state.posts[0].input.image_url).startsWith("data:"),"control exposes the inline source");
 // 6. Source re-check before signing removed: a replaced object is still signed and sent.
 const head=await compileRoute(INDEX_SOURCE,once(QUALITY_SOURCE,'if(!head.exists||head.etag!==location.etag||head.bytes!==location.bytes||mime(head.contentType)!==mime(location.content_type))throw new Error("changed");',""));
 const good={exists:true,bytes:BYTES.length,etag:ETAG,contentType:"image/jpeg"};
 reset({heads:[good,good,{...good,etag:'"replaced"'}]});await run(worker(),dispatchRequest(),head);assertEquals(state.posts.length,1,"control exposes a replaced source reaching the vendor");
 // 7. Capability window changed: the exact 7200 s source URL is pinned.
 const ttl=await compileRoute(INDEX_SOURCE,once(QUALITY_SOURCE,"KIE_PROPERTY_SOURCE_URL_SECONDS=7200","KIE_PROPERTY_SOURCE_URL_SECONDS=600"));
 reset();await run(worker(),dispatchRequest(),ttl);assertEquals(state.signs.at(-1)?.seconds,600);
 // 8. The prompt registry still refuses before money when the scope helper loses its guard.
 const scope=await compileRoute(INDEX_SOURCE,once(QUALITY_SOURCE,"assert(scope&&!!registeredPropertyPromptIdentity(scope.qualityIdentity),","assert(scope,"));
 reset();const noScopeGuard=await quiet(()=>run(worker({identity:bad}),dispatchRequest(),scope));assertEquals(noScopeGuard.status,503);noSpend();
 console.log("KIE_DISPATCH_COMPILED_CONTROLS=8");
});

// ---- F1 fix wave: jsonb identity order, prompt pin, provider secret, logs, lazy identity ----

/** Every console channel, captured (the dispatch must never print the provider secret). */
async function captured<T>(f:()=>Promise<T>){
 const lines:unknown[][]=[],saved={error:console.error,log:console.log,warn:console.warn,info:console.info,debug:console.debug};
 for(const k of Object.keys(saved) as (keyof typeof saved)[])console[k]=(...args:unknown[])=>{lines.push(args);};
 try{return{value:await f(),lines};}finally{Object.assign(console,saved);}
}
Deno.test("the job's frozen identity read back from jsonb (sorted keys), reversed or canonical dispatches identically",async()=>{
 assertEquals(Object.keys(IDENTITY().prompt_template_sha256),["push_in","pull_back","side_glide","fly_through"],"fixture is in true jsonb order");
 const posts:unknown[]=[];
 for(const identity of[IDENTITY(),reversedOrder(CANONICAL_IDENTITY()),CANONICAL_IDENTITY()]){
  reset();const r=await run(worker({identity}));assertEquals(r.status,202,JSON.stringify(r.body));assertEquals(state.events,KIE_EVENTS);posts.push(state.posts[0].input);
 }
 assertEquals(posts[1],posts[0]);assertEquals(posts[2],posts[0]);
 // Defect control (the pre-fix comparison): nested values compared with JSON.stringify refuse every
 // identity PostgREST returns, before any spend, while the canonical order alone would have passed.
 const old=await compileRoute(INDEX_SOURCE,undefined,{registry:once(REGISTRY_SOURCE,"sameJsonValue(identity,entry.identity)","JSON.stringify(identity)===JSON.stringify(entry.identity)")});
 reset();const refused=await run(worker({identity:IDENTITY()}),dispatchRequest(),old);
 assertEquals(refused.status,503,"control: a jsonb-ordered frozen identity is refused by the stringify comparison");noSpend();assertEquals(state.charges,0);
 reset();assertEquals((await run(worker({identity:CANONICAL_IDENTITY()}),dispatchRequest(),old)).status,202,"control: only the canonical order passed the old comparison");
});

const SCENE_NOUNS:Record<string,string>=Object.fromEntries([...between(INDEX_SOURCE,"const SCENE_NOUN: Record<SpaceType, string> = {","};").matchAll(/(\w+): "([^"]+)"/g)].map(m=>[m[1],m[2]]));
Deno.test("prompt pin: every reviewed motion x scene noun x canvas dispatches, and the route's nouns are the identity's",async()=>{
 assertEquals(Object.values(SCENE_NOUNS),[...KIE.prompt_scene_nouns],"SCENE_NOUN values are exactly prompt_scene_nouns");
 for(const[space,noun]of Object.entries(SCENE_NOUNS))for(const motion of["fly_through","push_in","side_glide","pull_back"])for(const aspect of["16:9","9:16"]as const){
  reset();const r=await run(worker({aspect}),dispatchRequest({aspect,motion,body:{space_type:space}}));
  assertEquals(r.status,202,`${space} ${motion} ${aspect}: ${JSON.stringify(r.body)}`);assertEquals(state.posts[0].input.prompt,buildSteadyPropertyReelPrompt(noun,motion,aspect));
 }
});

Deno.test("prompt pin: a changed steady template or an unpinned scene noun is refused before any read, allowance, hold or POST",async()=>{
 const refusedBeforeMoney=(r:{status:number;body:Record<string,unknown>},label:string)=>{
  assertEquals([r.status,r.body.error],[503,"The reviewed native-4K camera prompt is unavailable. No generation was sent."],label);
  assertEquals(state.events,["authorize"],label);noSpend();assertEquals([state.charges,state.refunds,state.rpcs.length,state.requests.length],[0,0,0,0],label);
 };
 const mutatedFraming=once(FRAMING_SOURCE,"Maintain very slow constant speed","Maintain a very slow constant speed");
 const changedTemplate=await compileRoute(INDEX_SOURCE,undefined,{framing:mutatedFraming});
 for(const aspect of["16:9","9:16"]as const)for(const motion of["fly_through","pull_back"]){reset();refusedBeforeMoney(await quiet(()=>run(worker({aspect}),dispatchRequest({aspect,motion}),changedTemplate)),`template ${motion} ${aspect}`);}
 // A route noun outside the identity's pinned nouns.
 const house=await compileRoute(once(INDEX_SOURCE,'  real_estate: "home",\n  venue: "event venue",','  real_estate: "house",\n  venue: "event venue",'));
 reset();refusedBeforeMoney(await quiet(()=>run(worker(),dispatchRequest(),house)),"noun house");
 // FAL steady-v2 shares the template but has no Kie pin: unchanged, it still dispatches.
 reset();assertEquals((await run(worker({profile:"fal-kling3-4k-steady-v2",identity:undefined}),dispatchRequest(),changedTemplate)).status,202);
 // Defect control: the pre-money pin removed: the changed prompt is charged, held and POSTed.
 const unpinned=await compileRoute(once(INDEX_SOURCE,"KIE_PROPERTY_IDENTITY.prompt_scene_nouns.includes(SCENE_NOUN[space])&&await registeredPropertyPromptPinned(worker?.qualityIdentity,reelText,shotMotion)","true"),undefined,{framing:mutatedFraming});
 reset();const leaked=await run(worker(),dispatchRequest(),unpinned);
 assertEquals([leaked.status,state.charges,state.posts.length],[202,1,1],"control: the changed template reaches the vendor");assert(String(state.posts[0].input.prompt).includes("Maintain a very slow constant speed"));
 assert(state.rpcs.some(x=>x.name==="app_video_cost_reserve_v2"),"control: and is held");
});

const KIE_NOT_READY="The native-4K video service is not ready to accept this clip. Nothing was charged; resume this video later.";
const KIE_PREFLIGHT='if(!Deno.env.get("KIE_API_KEY")?.trim()){console.error("ai-video reel submit refused before dispatch",{provider:"kie",reason:"provider_not_configured"});throw new HttpError(402,KIE_VENDOR_NOT_READY,"upstream");}';
Deno.test("KIE_API_KEY preflight: an unset or blank secret refuses 402 (a resumable pause) before any read, allowance, hold or POST; FAL never reads it",async()=>{
 try{
  for(const value of[null,""," \t\n"]){
   if(value===null)Deno.env.delete("KIE_API_KEY");else Deno.env.set("KIE_API_KEY",value);
   reset();const {value:r,lines}=await captured(()=>run(worker()));
   assertEquals([r.status,r.body.error,r.body.code],[402,KIE_NOT_READY,"upstream"],JSON.stringify(value));
   assertEquals(state.events,["authorize"]);noSpend();assertEquals([state.charges,state.refunds,state.rpcs.length,state.requests.length],[0,0,0,0]);
   // Operators see why the source paused; only the secret's NAME-level reason is logged.
   assertEquals(lines,[["ai-video reel submit refused before dispatch",{provider:"kie",reason:"provider_not_configured"}]]);
  }
  // Defect control: the pre-fix 503 (which the worker files as the terminal provider_submit_refused;
  // property-video-worker/kie-capacity-dispatch.test.ts) fails the status oracle above.
  const terminal=await compileRoute(once(INDEX_SOURCE,KIE_PREFLIGHT,'assert(!!Deno.env.get("KIE_API_KEY")?.trim(),503,"The native-4K video provider is not configured.");'));
  reset();assertEquals((await quiet(()=>run(worker(),dispatchRequest(),terminal))).status,503,"control: the old preflight status");
  Deno.env.delete("KIE_API_KEY");
  for(const[key,hash]of Object.entries(FAL_BASELINE)){
   const[profile,aspect]=key.split("|") as [string,"16:9"|"9:16"];reset();
   assertEquals((await run(worker({profile,aspect,identity:undefined}),dispatchRequest({aspect}))).status,202,key);
   assertEquals(state.rpcs.filter(x=>/reserve/.test(x.name)).map(x=>x.args.p_input_sha256),[hash,hash],"FAL recipe unchanged without the Kie secret: "+key);
  }
  // Defect control: without the preflight an unconfigured Kie profile is charged and held first.
  const noPreflight=await compileRoute(once(INDEX_SOURCE,KIE_PREFLIGHT,""));
  reset();await quiet(()=>run(worker(),dispatchRequest(),noPreflight));
  assert(state.charges===1&&state.rpcs.some(x=>x.name==="app_video_cost_reserve_v2"),"control exposes spend before the configuration refusal");
 }finally{Deno.env.set("KIE_API_KEY",FIXTURE_KIE_KEY);}
 // The secret value never reaches any console channel or the response, on success or refusal.
 for(const submitError of[undefined,new ProviderError("kie","upstream","KIE_API_KEY function secret is not set",0,true)]){
  reset({submitError});const {value:r,lines}=await captured(()=>run(worker()));
  assert(!JSON.stringify(lines).includes(FIXTURE_KIE_KEY)&&!JSON.stringify(r).includes(FIXTURE_KIE_KEY),"secret value never printed");
 }
});

Deno.test("adapter-side missing Kie secret: definite pre-request refusal through runChain releases the hold; logs provider_not_configured",async()=>{
 const reasons=(lines:unknown[][])=>lines.filter(l=>l[0]==="ai-video reel submit failed").map(l=>(l[1] as Record<string,unknown>).reason);
 const KEY_MISSING=()=>new ProviderError("kie","upstream","KIE_API_KEY function secret is not set",0,true);
 reset({submitError:KEY_MISSING()});const {value:r,lines}=await captured(()=>run(worker()));
 assertEquals(reasons(lines),["provider_not_configured"]);
 // Real runChain/asHttpError keep status 0 and dispatch_rejected; submitReservedVideo releases both holds.
 assertEquals([r.status,r.body.provider,r.body.provider_status,r.body.dispatch_rejected,r.body.error_class],[502,"kie",0,true,"upstream"]);
 const release=state.rpcs.find(x=>x.name==="app_video_cost_release_rejected");assert(release,"hold released");
 assertEquals([release.args.p_provider_status,release.args.p_error_class],[0,"upstream"]);assertEquals(state.refunds,1);assertEquals(state.posts,[]);
 assertEquals(state.events.slice(-4),["adapter_refused","serving_cost_finish","app_video_cost_release_rejected","refund"]);
 for(const[error,reason]of[[new ProviderError("fal","upstream","FAL_KEY function secret is not set"),"provider_not_configured"],[new ProviderError("kie","upstream","Kie 500: fixture",500),"submission_failed"]]as const){
  reset({submitError:error});assertEquals(reasons((await captured(()=>run(worker()))).lines),[reason]);
 }
 // Defect control: the Kie message dropped from the reason condition.
 const falOnly=await compileRoute(once(INDEX_SOURCE,' || known?.message === "KIE_API_KEY function secret is not set"',""));
 reset({submitError:KEY_MISSING()});assertEquals(reasons((await captured(()=>run(worker(),dispatchRequest(),falOnly))).lines),["submission_failed"]);
});

Deno.test("an internally inconsistent identity never crashes module load: the Kie profile refuses 503 before any spend, FAL is unaffected",async()=>{
 const brokenIdentities=[once(IDENTITY_SOURCE,'"unit_cents": 33.5,','"unit_cents": 33.6,'),once(IDENTITY_SOURCE,'"profile": "kie-kling3-4k-steady-v1",','"profile": "kie-kling3-4k-steady-v2",'),
  once(IDENTITY_SOURCE,'"credits_per_second": 67,','"credits_per_second": 68,')];
 for(const identity of brokenIdentities){
  const route=await compileRoute(INDEX_SOURCE,undefined,{identity});
  reset();const r=await run(worker(),dispatchRequest(),route);
  assertEquals([r.status,r.body.error],[503,"The native-4K video profile is unavailable. No generation was sent."]);assertEquals(state.events,["authorize"]);noSpend();
  reset();assertEquals((await run(worker({profile:"fal-kling3-4k-steady-v2",identity:undefined}),dispatchRequest(),route)).status,202,"FAL dispatch still loads and runs");
 }
 // The composition binding (property-video-quality.ts) is lazy too.
 const composition=once(QUALITY_SOURCE,'STEADY_PROPERTY_COMPOSITION_PROFILE="steady-v2-cfr24" as const','STEADY_PROPERTY_COMPOSITION_PROFILE="steady-v3-cfr24" as const');
 reset();assertEquals((await run(worker(),dispatchRequest(),await compileRoute(INDEX_SOURCE,composition))).status,503);noSpend();
 // Defect control: the pre-fix module-level throw takes the whole function down (FAL included) at import.
 const eager=KIE_SOURCE+'\nif (!kiePropertyIdentityConsistent()) throw new Error("Kie property identity is internally inconsistent");\n';
 let crashed=false;try{await compileRoute(INDEX_SOURCE,undefined,{kie:eager,identity:brokenIdentities[0]});}catch{crashed=true;}
 assert(crashed,"control: an eager identity throw crashes module load");
 // Each lazy check is also load-bearing on its own at unit level (compiled controls in
 // _shared/property-video-kie_test.ts and ai-video/property-video-kie-guards.test.ts).
});

// ---- G2: a Kie vendor-account refusal after the hold is a resumable 402 pause ----

const {classifyKie}=await import(new URL("_shared/providers/kie.ts",FUNCTIONS).href);
/** What kie.ts throws for a createTask envelope code: definite (no taskId) or ambiguous. */
const kieAnswer=(code:number,definite=true,msg="fixture refusal")=>new ProviderError("kie",classifyKie(code,msg),`Kie ${code}: ${msg}`,code,definite);
const UNCONFIRMED="We couldn't confirm this video submission. Its processing budget remains reserved; check its status before starting another.";
const VENDOR_MAPPING='if(savedQualityProfile==="kie-kling3-4k-steady-v1"&&e instanceof HttpError&&e.details?.provider==="kie"&&e.details?.dispatch_rejected===true&&[401,402,403].includes(e.details?.provider_status as number))throw new HttpError(402,KIE_VENDOR_NOT_READY,"upstream",e.details);';
/** One definite Kie vendor-account refusal after the hold: 402, hold released, allowance refunded. */
function pausedAfterHold(r:{status:number;body:Record<string,unknown>},code:number){
 assertEquals([r.status,r.body.error,r.body.code],[402,KIE_NOT_READY,"upstream"],String(code));
 assertEquals([r.body.provider,r.body.provider_status,r.body.error_class,r.body.dispatch_rejected],["kie",code,"upstream",true],String(code));
 const release=state.rpcs.find(x=>x.name==="app_video_cost_release_rejected");assert(release,"hold released: "+code);
 assertEquals([release.args.p_provider_status,release.args.p_error_class],[code,"upstream"]);
 const finish=state.rpcs.find(x=>x.name==="serving_cost_finish")!;assertEquals([finish.args.p_state,finish.args.p_rejection_status],["rejected",code]);
 assertEquals([state.charges,state.refunds],[1,1]);assertEquals(state.posts,[]);
 assertEquals(state.events.slice(-4),["adapter_refused","serving_cost_finish","app_video_cost_release_rejected","refund"]);
}
async function vendorRefusalsPause(route:Awaited<ReturnType<typeof compileRoute>>){
 for(const code of[401,402,403]){reset({submitError:kieAnswer(code)});pausedAfterHold(await quiet(()=>run(worker(),dispatchRequest(),route)),code);}
}
/** FAL keeps today's 502 for the same account answers (the worker's FAL-only submit recovery). */
async function falAccountRefusalsUnchanged(route:Awaited<ReturnType<typeof compileRoute>>){
 for(const profile of["fal-kling3-4k-steady-v2","fal-kling3-4k-v1"])for(const code of[401,402,403]){
  reset({submitError:new ProviderError("fal","upstream",`fal request failed (HTTP ${code})`,code,true)});
  const r=await quiet(()=>run(worker({profile,identity:undefined}),dispatchRequest(),route));
  assertEquals([r.status,r.body.code,r.body.provider,r.body.provider_status,r.body.dispatch_rejected],[502,"upstream","fal",code,true],`${profile} ${code}`);
  assert(state.rpcs.some(x=>x.name==="app_video_cost_release_rejected"));assertEquals([state.charges,state.refunds],[1,1]);
 }
}

Deno.test("Kie vendor-account refusals after the hold (401/403 key, 402 credits) answer 402: hold released, allowance refunded",async()=>{
 await vendorRefusalsPause(actual);
 // Defect control: without the mapping the same refusals stay 502 (terminal provider_submit_refused).
 const unmapped=await compileRoute(once(INDEX_SOURCE,VENDOR_MAPPING,""));
 for(const code of[401,402,403]){reset({submitError:kieAnswer(code)});assertEquals((await quiet(()=>run(worker(),dispatchRequest(),unmapped))).status,502,"control: "+code);}
 let caught=false;try{await vendorRefusalsPause(unmapped);}catch{caught=true;}assert(caught,"control: the oracle detects the missing mapping");
});

Deno.test("every other Kie answer keeps its status: 429, recipe/media refusals, ambiguous answers and an unconfirmed release",async()=>{
 for(const[code,status,errorCode]of[[429,429,"rate_limited"],[404,502,"upstream"],[400,400,"validation"],[422,400,"validation"]]as const){
  reset({submitError:kieAnswer(code)});const r=await quiet(()=>run(worker()));
  assertEquals([r.status,r.body.code,r.body.provider_status,r.body.dispatch_rejected],[status,errorCode,code,true],String(code));assertNotEquals(r.body.error,KIE_NOT_READY);
  assert(state.rpcs.some(x=>x.name==="app_video_cost_release_rejected"));assertEquals(state.refunds,1);
 }
 // A content refusal of the customer's photo stays the 400 safety answer.
 reset({submitError:kieAnswer(422,true,"content policy violation")});const nsfw=await quiet(()=>run(worker()));
 assertEquals([nsfw.status,nsfw.body.code,nsfw.body.error_class],[400,"unsupported_edit","nsfw"]);
 // Ambiguous answers prove nothing: VideoDispatchUnconfirmed, hold retained, allowance kept.
 for(const code of[500,455,501,505]){
  reset({submitError:kieAnswer(code,false)});const r=await quiet(()=>run(worker()));
  assertEquals([r.status,r.body.code,r.body.error],[502,"upstream",UNCONFIRMED],String(code));
  assert(!state.rpcs.some(x=>x.name==="app_video_cost_release_rejected"));assertEquals(state.refunds,0);
 }
 // A vendor-account refusal whose release is NOT confirmed keeps the hold fenced: never a 402 pause.
 for(const code of[401,402,403]){
  reset({submitError:kieAnswer(code),releaseUnconfirmed:true});const r=await quiet(()=>run(worker()));
  assertEquals([r.status,r.body.error],[502,UNCONFIRMED],String(code));assertEquals(state.refunds,0);
  assert(state.rpcs.some(x=>x.name==="app_video_cost_release_rejected"),"release was attempted, not confirmed");
 }
 // A secret that vanished after the preflight (status 0, nothing sent) keeps the F1 502 refusal.
 reset({submitError:new ProviderError("kie","upstream","KIE_API_KEY function secret is not set",0,true)});
 assertEquals((await quiet(()=>run(worker()))).status,502);
});

Deno.test("FAL profiles keep 502 for the same account refusals; the 402 pause is Kie-profile only",async()=>{
 await falAccountRefusalsUnchanged(actual);
 // Defect control: the mapping widened to every profile and provider changes the FAL contract.
 const widened=await compileRoute(once(INDEX_SOURCE,VENDOR_MAPPING,VENDOR_MAPPING.replace('savedQualityProfile==="kie-kling3-4k-steady-v1"&&e instanceof HttpError&&e.details?.provider==="kie"&&','e instanceof HttpError&&')));
 let caught=false;try{await falAccountRefusalsUnchanged(widened);}catch{caught=true;}assert(caught,"control: a widened mapping is detected by the FAL oracle");
 await vendorRefusalsPause(widened);
});

// ---- Per-dispatch Kie supplier authority (activated profile or owner quality-test grant) ----

const {throwRpc}=await import(new URL("_shared/http.ts",FUNCTIONS).href);
/** Exactly what engine.ts's rpc() throws for an SQL refusal (property-video-jobs/runtime.ts -> throwRpc). */
const sqlRefusal=(message:string):Error=>{try{throwRpc(message);}catch(error){return error as Error;}throw new Error("throwRpc returned");};
const AUTHORITY_UNAVAILABLE="The native-4K dispatch authority is unavailable. No generation was sent.";
const AUTHORITY_CHECK=`if(!worker?.kieDispatchAuthority)throw new HttpError(503,"${AUTHORITY_UNAVAILABLE}");`;
const AUTHORITY_CALL="await worker!.kieDispatchAuthority!();";
const GRANT_ENDED="RP403: The owner quality-test permission has ended. No new clip was sent.";
const AUTHORITY_REFUSALS:[string,number][]=[[GRANT_ENDED,403],["RP403: The owner quality-test budget is used up. No new clip was sent.",403],
 ["RP403: This clip is outside the owner quality-test permission",403],["RP409: This saved video is not an exact native-4K Kie recipe with its processor permission",409],
 ["RP409: Only an unsent clip can ask for supplier authority",409]];
/** Consuming authority is immediately before the one supplier POST, after local preparation and both reservations. */
function authorityAtDispatch(label:string){
 assertEquals(state.authorityCalls.length,1,label);
 const before=state.authorityCalls[0];assertEquals(before.charges,1,label);
 assertEquals(before.events,KIE_EVENTS.slice(0,KIE_EVENTS.indexOf("kie_dispatch_authority")),label);
 const at=(event:string)=>state.events.indexOf(event);
 assert(at("property_owned_upload")<at("charge")&&at("charge")<at("app_video_cost_reserve_v2")&&at("app_video_cost_reserve_v2")<at("serving_cost_reserve")&&at("sign:7200")<at("kie_dispatch_authority"),label);
 if(state.posts.length)assertEquals(at("POST"),at("kie_dispatch_authority")+1,label);
}
function authorityRefused(r:{status:number;body:Record<string,unknown>},status:number,error:string,label:string){
 assertEquals([r.status,r.body.error],[status,error],label);assertEquals(state.posts,[],label);
 assertEquals([state.charges,state.refunds],[1,1],label);authorityAtDispatch(label);
 assertEquals(state.rpcs.filter(x=>x.name==="app_video_cost_release_rejected").length,1,label);
 assert(!state.rpcs.some(x=>x.name==="app_video_cost_settle"),label);
}
function missingAuthorityClosed(r:{status:number;body:Record<string,unknown>}){
 assertEquals([r.status,r.body.error],[503,AUTHORITY_UNAVAILABLE]);noSpend();
 assertEquals([state.charges,state.refunds,state.rpcs.length,state.requests.length],[0,0,0,0]);
}
Deno.test("Kie authority is consumed once at the prospective POST boundary after preparation, allowance and holds",async()=>{
 for(const aspect of["16:9","9:16"]as const)for(const motion of["fly_through","pull_back"]){
  reset();const r=await run(worker({aspect}),dispatchRequest({aspect,motion}));assertEquals(r.status,202,JSON.stringify(r.body));
  assertEquals(state.events,KIE_EVENTS);authorityAtDispatch(`${aspect} ${motion}`);assertEquals(state.posts.length,1);
 }
});
Deno.test("definitive authority refusals preserve SQL status only after confirmed reservation release and allowance refund",async()=>{
 for(const[message,status]of AUTHORITY_REFUSALS){
  reset();const r=await quiet(()=>run(worker({authority:sqlRefusal(message)})));
  authorityRefused(r,status,message.replace(/^RP\d{3}:\s*/,""),message);
  assertEquals(r.body.code,status===403?"forbidden":"conflict",message);
 }
 // A lost authority reply might have committed its use receipt: no POST, refund or automatic resend.
 reset();const unknown=await quiet(()=>run(worker({authority:sqlRefusal("connection reset")})));
 assertEquals(unknown.status,502);assertEquals([state.posts.length,state.charges,state.refunds],[0,1,0]);
 assertEquals(state.authorityCalls.length,1);assert(!state.rpcs.some(x=>x.name==="app_video_cost_release_rejected"||x.name==="app_video_cost_settle"));
 // Even a definite refusal remains fenced when the release cannot be confirmed.
 reset({releaseUnconfirmed:true});const fenced=await quiet(()=>run(worker({authority:sqlRefusal(GRANT_ENDED)})));
 assertEquals(fenced.status,502);assertEquals([state.posts.length,state.charges,state.refunds],[0,1,0]);
 assertEquals(state.authorityCalls.length,1);assertEquals(state.rpcs.filter(x=>x.name==="app_video_cost_release_rejected").length,1);
});
Deno.test("Kie preparation, allowance and reservation failures do not consume an owner-test create",async()=>{
 const cases:Partial<State>[]=[
  {allowanceError:sqlRefusal("RP402: Fixture allowance unavailable")},
  {rpcRefusal:"app_video_cost_reserve_v2"},
  {rpcRefusal:"serving_cost_reserve"},
  {heads:[{exists:false,bytes:null,etag:null,contentType:null}]},
  {signUrl:(bucket,key,seconds)=>{if(seconds===7200)throw new Error("Fixture presign unavailable");return `https://r2-fixture.invalid/${bucket}/${key}?X-Amz-Expires=${seconds}&X-Amz-Signature=fixture`;}}
 ];
 for(const setup of cases){reset(setup);const out=await quiet(()=>run(worker()));
  assert(out.status>=400,JSON.stringify(out));assertEquals(state.authorityCalls,[]);assertEquals(state.posts,[]);
 }
});
Deno.test("a missing authority closure fails before any source read or allowance",async()=>{
 reset();missingAuthorityClosed(await quiet(()=>run(worker({authority:"missing"}))));assertEquals(state.events,["authorize"]);
});
Deno.test("FAL profiles never call Kie authority",async()=>{
 for(const profile of["fal-kling3-4k-steady-v2","fal-kling3-4k-v1"])for(const authority of[undefined,sqlRefusal(GRANT_ENDED),"missing" as const]){
  reset();const r=await run(worker({profile,identity:undefined,authority}),dispatchRequest());assertEquals(r.status,202,profile);
  assertEquals(state.authorityCalls,[],profile);assertEquals(state.posts.length,1,profile);
 }
});
Deno.test("compiled authority controls reject omitted checks, pre-allowance consumption and unconfirmed-release status passthrough",async()=>{
 const fails=(check:()=>void,label:string)=>{let caught=false;try{check();}catch{caught=true;}assert(caught,"control: "+label);};
 const endedCopy=GRANT_ENDED.replace(/^RP403:\s*/,"");
 const oracle=(r:{status:number;body:Record<string,unknown>})=>authorityRefused(r,403,endedCopy,"oracle");
 reset();oracle(await quiet(()=>run(worker({authority:sqlRefusal(GRANT_ENDED)}))));
 const noCall=await compileRoute(once(INDEX_SOURCE,AUTHORITY_CALL,""));
 reset();const sent=await quiet(()=>run(worker({authority:sqlRefusal(GRANT_ENDED)}),dispatchRequest(),noCall));
 fails(()=>oracle(sent),"authority removed");assertEquals([sent.status,state.charges,state.posts.length],[202,1,1]);assertEquals(state.authorityCalls,[]);
 // Same source, deliberately consume before allowance, then force a real handler allowance refusal.
 const early=await compileRoute(once(once(INDEX_SOURCE,AUTHORITY_CALL,""),AUTHORITY_CHECK,AUTHORITY_CHECK+"await worker!.kieDispatchAuthority!();"));
 const budgetCase={allowanceError:sqlRefusal("RP402: Fixture allowance unavailable")};
 reset(budgetCase);assertEquals((await quiet(()=>run(worker()))).status,402);assertEquals(state.authorityCalls,[]);
 reset(budgetCase);const refused=await quiet(()=>run(worker(),dispatchRequest(),early));assertEquals(refused.status,402);
 fails(()=>assertEquals(state.authorityCalls,[]),"authority consumed before allowance");assertEquals(state.authorityCalls.length,1);assertEquals(state.posts,[]);
 const lenient=await compileRoute(once(once(INDEX_SOURCE,AUTHORITY_CHECK,""),AUTHORITY_CALL,"await worker?.kieDispatchAuthority?.();"));
 reset();const unchecked=await quiet(()=>run(worker({authority:"missing"}),dispatchRequest(),lenient));
 fails(()=>missingAuthorityClosed(unchecked),"missing capability made optional");assertEquals([unchecked.status,state.posts.length],[202,1]);
 const ungatedRelease=await compileRoute(once(INDEX_SOURCE,"if(kieAuthorityRefusal&&!(e instanceof VideoDispatchUnconfirmed))throw kieAuthorityRefusal;","if(kieAuthorityRefusal)throw kieAuthorityRefusal;"));
 reset({releaseUnconfirmed:true});const unsafe=await quiet(()=>run(worker({authority:sqlRefusal(GRANT_ENDED)}),dispatchRequest(),ungatedRelease));
 fails(()=>assertEquals(unsafe.status,502),"authority status escapes an unconfirmed release");assertEquals(unsafe.status,403);assertEquals([state.posts.length,state.refunds],[0,0]);
 console.log("KIE_DISPATCH_AUTHORITY_COMPILED_CONTROLS=4");
});

// Registered last: the process environment is shared by every test module in one run.
Deno.test("restore the process KIE_API_KEY this module set for its fixtures",()=>{
 if(KIE_KEY_BEFORE===undefined)Deno.env.delete("KIE_API_KEY");else Deno.env.set("KIE_API_KEY",KIE_KEY_BEFORE);
 assertEquals(Deno.env.get("KIE_API_KEY"),KIE_KEY_BEFORE);
});
