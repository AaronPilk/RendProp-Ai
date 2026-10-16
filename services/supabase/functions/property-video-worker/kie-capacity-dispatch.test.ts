// Kie vendor-account refusals at the ACTUAL worker dispatch. engine.ts's
// dispatch (with its real aiScope, callAI and fail) drives the ACTUAL ai-video
// handler prelude + /reel-clip route compiled from index.ts with its own imports,
// so submitReservedVideo, fundedAttempt, runChain/asHttpError and the REAL Kie
// adapter (kie.ts createTask classification) decide the HTTP status the worker
// maps. Only I/O edges are closed doubles: the job/source SQL boundary (which
// models the reservation row exactly as the reserve/release RPCs record it), R2,
// the allowance charge, a FAL adapter double, and an in-process transport that
// answers api.kie.ai with fixture envelopes. Nothing reaches Kie, FAL, R2 or a
// database. Each new ai-video guard has a compiled defect control below.
import {assert,assertEquals,assertNotEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
// Same fixture database values as ai-video/property-video-kie-dispatch.test.ts (identical
// values, so module order cannot matter); never a real project or credential.
for(const[k,v]of Object.entries({SUPABASE_URL:"https://kie-dispatch-db.fixture.invalid",SUPABASE_ANON_KEY:"public-fixture",SUPABASE_SERVICE_ROLE_KEY:"service-fixture"}))Deno.env.set(k,v);
for(const k of["SUPABASE_SECRET_KEYS","RENDPROP_SECRET_KEY_NAME","SUPABASE_PUBLISHABLE_KEYS","RENDPROP_PUBLISHABLE_KEY_NAME"])Deno.env.delete(k);
// A synthetic fixture string (never a credential); restored by the last test.
const FIXTURE_KIE_KEY="offline-fixture-kie-capacity-key-MUST-NOT-BE-LOGGED",KIE_KEY_BEFORE=Deno.env.get("KIE_API_KEY");
Deno.env.set("KIE_API_KEY",FIXTURE_KIE_KEY);

const FUNCTIONS=new URL("../",import.meta.url),INDEX=new URL("ai-video/index.ts",FUNCTIONS);
const {KIE_PROPERTY_IDENTITY:KIE,KIE_PROPERTY_PROFILE}=await import(new URL("_shared/property-video-kie.ts",FUNCTIONS).href);
const {resetRouterCache}=await import(new URL("_shared/router.ts",FUNCTIONS).href);
const {resetServingModeCache}=await import(new URL("_shared/funded-serving.ts",FUNCTIONS).href);
const {resolveChain:realResolveChain}=await import(new URL("_shared/providers/chain.ts",FUNCTIONS).href);
const {ProviderError}=await import(new URL("_shared/providers/common.ts",FUNCTIONS).href);
const {kieAdapter}=await import(new URL("_shared/providers/kie.ts",FUNCTIONS).href);
const {R2_BUCKET_UPLOADS}=await import(new URL("_shared/r2.ts",FUNCTIONS).href);
const {buildSteadyPropertyReelPrompt}=await import(new URL("ai-video/reel-framing.ts",FUNCTIONS).href);

const enc=(s:string)=>{const b=new TextEncoder().encode(s);let out="";for(let i=0;i<b.length;i+=32768)out+=String.fromCharCode(...b.subarray(i,i+32768));return "data:application/typescript;base64,"+btoa(out);};
const absolute=(text:string,base:URL)=>text.replace(/from\s+(["'])(\.\.?\/[^"']+)\1/g,(_a,_q,path)=>`from ${JSON.stringify(new URL(path,base).href)}`);
const between=(text:string,start:string,end:string)=>{const a=text.indexOf(start),b=text.indexOf(end,a+start.length);assert(a>=0&&b>a,"Actual anchor changed: "+start);return text.slice(a,b);};
const fn=(text:string,name:string)=>{const m=new RegExp(`(?:export )?(?:async )?function ${name}\\(`).exec(text);assert(m,"Actual helper missing: "+name);return text.slice(m.index,text.indexOf("\n}\n",m.index)+3).replace(/^export /,"");};
const once=(text:string,before:string,after:string)=>{assertEquals(text.split(before).length,2,"Mutation anchor must be unique: "+before);return text.replace(before,()=>after);};
const sha=async(value:Uint8Array)=>Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",new Uint8Array(value))),b=>b.toString(16).padStart(2,"0")).join("");

// ---- the actual ai-video route (same compile as property-video-kie-dispatch.test.ts) ----
const INDEX_SOURCE=await Deno.readTextFile(INDEX);
const SIGNATURE="export async function handleAiVideo(req:Request,worker?:AiVideoWorkerScope):Promise<Response> {";
type Route={make:(stub:unknown)=>(req:Request,worker?:unknown)=>Promise<Response>};
async function compileRoute(indexSource=INDEX_SOURCE):Promise<Route>{
 const imports=(indexSource.match(/^import [\s\S]*?;\n/gm)??[]).map(s=>absolute(s,INDEX)).join("");
 const helpers=[between(indexSource,"const SPACE_TYPES =","interface DroneBody"),fn(indexSource,"cleanPrompt"),fn(indexSource,"legacyVideoStep"),fn(indexSource,"durationNeeds"),
  indexSource.match(/^const ADVERTISED_SECONDS[\s\S]*?\n};\n/m)![0],indexSource.match(/^const MAX_IMAGE_B64_CHARS = [^;]+;/m)![0],
  indexSource.match(/^const ALLOWED_IMAGE_MIMES = [^;]+;/m)![0],indexSource.match(/^const MODEL_I2V = [^;]+;/m)![0]].join("\n");
 const prelude=between(indexSource,SIGNATURE,'    if (req.method === "GET" && seg.length === 1 && seg[0] === "operation")').replace(SIGNATURE,"return async function handleAiVideo(req:Request,worker?:any):Promise<Response> {");
 const route=between(indexSource,"    // ---- POST /ai-video/reel-clip ----","    // ---- POST /ai-video/drift ----");
 return await import(enc(`${imports}
type ReelBody=any;type AiVideoWorkerScope=any;
${helpers}
export function make(stub:any){
 const {getUser,userClient,adminClient,headObject,presignGet,guardGenerate,refundGenerateCharge,routerEnabled,ownerQaReelStep,resolveChain,adapterFor,submitEnvelope,assertVideoReceiptSigningReady,recordProvenance,retainVideoSubmission,resolvePublicAsset,listingSpaceType,contentOrgForUser,putBytes}=stub;
 ${prelude}
${route}
    throw new HttpError(404,"Closed fixture route");
  } catch (err) { return respondError(err); }
 };
}`)) as Route;
}

const ACTOR="e1000000-0000-4000-8000-000000000001",ORG="e1000000-0000-4000-8000-000000000002",LISTING="e1000000-0000-4000-8000-000000000003",ASSET="e1000000-0000-4000-8000-000000000004";
const BYTES=new TextEncoder().encode("owned-prepared-source-photo-bytes"),SOURCE_SHA=await sha(BYTES);
const KEY=`uploads/${ORG}/${LISTING}/prepared-source.jpg`,ETAG='"src-etag"',DB_HOST="kie-dispatch-db.fixture.invalid",REQUEST_KEY="kie-capacity-source-attempt-0001";
const KIE_ROW={id:KIE.route_id,task:KIE.task,position:1,provider:"kie",model:"kling-3.0/video",unit:"second",unit_cents:33.5,capabilities:["i2v","1080p","5s","native4k","preserve_photo"],
 max_latency_s:1800,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"trains_by_default",enabled:true,retire_after:null,note:"kie-kling3-4k-steady-v1 pinned route",params:{kie_mode:"4K",sound:false}};
const FAL_ROW={id:"closed-normal-fal4k",task:"video.property_reel_clip",position:1,provider:"fal",model:"fal-ai/kling-video/v3/4k/image-to-video",unit:"second",unit_cents:42,
 capabilities:["i2v","1080p","5s","native4k","preserve_photo"],max_latency_s:900,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"retained_30d",enabled:true,retire_after:null,note:null,params:null};
/** Postgres jsonb object key order (what the worker forwards from the job row). */
const byteOrder=(a:string,b:string)=>{const x=new TextEncoder().encode(a),y=new TextEncoder().encode(b);if(x.length!==y.length)return x.length-y.length;for(let i=0;i<x.length;i++)if(x[i]!==y[i])return x[i]-y[i];return 0;};
const jsonbOrder=(value:unknown):any=>Array.isArray(value)?value.map(jsonbOrder):value&&typeof value==="object"
 ?Object.fromEntries(Object.keys(value).sort(byteOrder).map(k=>[k,jsonbOrder((value as Record<string,unknown>)[k])])):value;

type Answer={status?:number;body:unknown};
type Reservation={released_at:string|null;provider_request_id:string|null;model:unknown};
const state={route:null as null|((req:Request,worker?:unknown)=>Promise<Response>),http:[] as number[],worker:[] as [string,any][],rpcs:[] as string[],kiePosts:[] as any[],
 falSubmits:0,charges:0,refunds:0,reservation:null as Reservation|null,receipt:null as unknown,kie:null as Answer|null,falError:null as unknown,releaseUnconfirmed:false,logs:[] as unknown[][]};
(globalThis as any).__kieCapacityWorker=()=>state;

// One closed transport for every module (supabase-js, funded serving, router telemetry, source read, Kie).
globalThis.fetch=(async(input:RequestInfo|URL,init?:RequestInit)=>{
 const req=new Request(input,init),u=new URL(req.url);
 if(u.hostname===DB_HOST){
  if(u.pathname==="/rest/v1/rpc/serving_mode")return Response.json("funded");
  if(u.pathname==="/rest/v1/rpc/report_provider_outcome")return new Response(null,{status:204});
  if(u.pathname==="/rest/v1/ai_routes"&&u.searchParams.get("id")==="eq."+KIE.route_id&&!u.searchParams.has("task"))return Response.json([KIE_ROW]);
  if(u.pathname==="/rest/v1/ai_routes"&&u.searchParams.get("task")==="eq.video.property_reel_clip")return Response.json([FAL_ROW]);
  if(u.pathname==="/rest/v1/app_config")return Response.json({value:{enabled:true}});
  if(u.pathname==="/rest/v1/provider_health")return Response.json([]);
 }
 if(u.hostname==="r2-fixture.invalid"&&req.method==="GET"&&u.searchParams.get("X-Amz-Expires")==="300")return new Response(BYTES,{status:200,headers:{etag:ETAG}});
 const answer=state.kie;
 if(u.hostname==="api.kie.ai"&&u.pathname==="/api/v1/jobs/createTask"&&req.method==="POST"&&answer){
  assert(req.headers.get("authorization")===`Bearer ${FIXTURE_KIE_KEY}`,"the fixture key authorizes the closed createTask");
  state.kiePosts.push(await req.json());
  return new Response(JSON.stringify(answer.body),{status:answer.status??200,headers:{"content-type":"application/json"}});
 }
 throw new Error("Closed fixture refused "+u.hostname+u.pathname);
}) as typeof fetch;

// The route's SQL boundary. The reservation row is created by the priced hold and
// released only by a confirmed release, exactly what the worker reads afterwards.
const rpc=async(name:string,args:Record<string,unknown>)=>{state.rpcs.push(name);
 if(name==="property_owned_upload")return{data:{actor_id:ACTOR,org_id:ORG,listing_id:LISTING,asset_id:ASSET,bucket:"uploads",storage_key:KEY,bytes:BYTES.length,etag:ETAG,content_type:"image/jpeg",sha256:SOURCE_SHA},error:null};
 if(name==="property_photo_reference")return{data:{},error:null};
 if(name==="app_video_cost_reserve_v2"){assertEquals(args.p_key,REQUEST_KEY);state.reservation={released_at:null,provider_request_id:null,model:args.p_model};return{data:{reserved:true},error:null};}
 if(name==="serving_cost_reserve")return{data:{reserved:true},error:null};
 if(name==="serving_cost_finish")return{data:{finished:true},error:null};
 if(name==="app_video_cost_release_rejected"){if(state.releaseUnconfirmed)return{data:{released:false},error:null};state.reservation!.released_at="2026-10-16T00:00:01.000Z";return{data:{released:true},error:null};}
 if(name==="app_video_cost_settle"){state.reservation!.provider_request_id=String(args.p_provider_request_id);return{data:{settled:true},error:null};}
 if(name==="bind_property_video_source")return{data:{bound:true},error:null};
 if(name==="org_has_internal_testing_grant"||name==="org_has_private_internal_testing")return{data:false,error:null};
 throw new Error("Unexpected closed RPC "+name);};
const routeStub={
 getUser:()=>{throw new Error("worker path never authenticates HTTP");},userClient:()=>{throw new Error("worker path never uses a user client");},adminClient:()=>({rpc}),
 headObject:async(bucket:string,key:string)=>{assertEquals([bucket,key],[R2_BUCKET_UPLOADS,KEY]);return{exists:true,bytes:BYTES.length,etag:ETAG,contentType:"image/jpeg"};},
 presignGet:async(bucket:string,key:string,seconds:number)=>`https://r2-fixture.invalid/${bucket}/${key}?X-Amz-Expires=${seconds}&X-Amz-Signature=fixture`,
 guardGenerate:async()=>{state.charges++;return{orgId:ORG,plan:"team",monthlyKey:"m",burstKey:"b",monthlyReceipt:{windowStart:"2026-10-16T00:00:00Z"},burstReceipt:{windowStart:"2026-10-16T01:00:00Z"}};},
 refundGenerateCharge:async()=>{state.refunds++;},routerEnabled:async()=>false,
 ownerQaReelStep:async()=>{throw new Error("Owner QA is unreachable for saved quality profiles");},resolveChain:realResolveChain,
 // The REAL Kie adapter; FAL is a double that answers like fal.ts fetchJson for a definite account refusal.
 adapterFor:(provider:string)=>provider==="kie"?kieAdapter:{submit:async()=>{state.falSubmits++;throw state.falError;}},
 submitEnvelope:async(_req:Request,_on:boolean,_task:string,ref:{id:string})=>({request_id:ref.id,status_url:"https://fixture.invalid/ai-video/status?job=opaque",response_url:"https://fixture.invalid/ai-video/status?job=opaque"}),
 assertVideoReceiptSigningReady:async()=>{},recordProvenance:async()=>{throw new Error("worker provenance only");},retainVideoSubmission:async()=>{throw new Error("worker never journals HTTP receipts");},
 resolvePublicAsset:async()=>{throw new Error("asset path unreachable");},listingSpaceType:async()=>"real_estate",contentOrgForUser:async()=>ORG,putBytes:async()=>{throw new Error("no staging");},
};

// ---- the actual worker dispatch (engine.ts aiScope + callAI + fail + dispatch) ----
const ENGINE=await Deno.readTextFile(new URL("./engine.ts",import.meta.url));
const engineStart=ENGINE.indexOf("async function aiScope("),engineEnd=ENGINE.indexOf("export type PropertyVideoPollPhase=",engineStart);
assert(engineStart>0&&engineEnd>engineStart,"actual worker dispatch entry point");
const ENGINE_DISPATCH=ENGINE.slice(engineStart,engineEnd);
assert(ENGINE_DISPATCH.includes("export async function dispatch(ctx:any){")&&ENGINE_DISPATCH.includes("async function callAI(")&&ENGINE_DISPATCH.includes("async function fail("),"actual dispatch, ai-video call and failure filing");
const engine=await import("data:application/typescript,"+encodeURIComponent(`
import{assert}from ${JSON.stringify(new URL("../_shared/http.ts",import.meta.url).href)};
type AiVideoWorkerScope=any;
const f=()=>globalThis.__kieCapacityWorker();
const handleAiVideo=async(req,worker)=>{const response=await f().route(req,worker);f().http.push(response.status);return response;};
const scope=async(...args)=>{f().worker.push(['scope',args]);};
const rpc=async(name,args)=>{f().worker.push([name,args]);if(name==='property_video_kie_dispatch_authority')return{authority:'activated_profile',job_id:args.p_job,attempt_id:args.p_attempt};if(name==='property_video_job_receipt')f().receipt=args.p_receipt;
 if(name==='property_video_job_provenance')return{id:'e1000000-0000-4000-8000-0000000000b1',disclosure:'AI motion from photographs'};return true;};
const adminClient=()=>({from:table=>{const q={select:()=>q,eq:()=>q,maybeSingle:async()=>{
 if(table==='property_video_job_sources')return{error:null,data:{receipt:f().receipt}};
 if(table==='app_video_cost_reservations')return{error:null,data:f().reservation?{...f().reservation}:null};
 throw new Error('closed worker table '+table);}};return q;}});
const bytesFrom=async()=>({bytes:new Uint8Array(${JSON.stringify([...BYTES])}),sha256:${JSON.stringify(SOURCE_SHA)}});
const validatePhotoInput=()=>({width:2048,height:1365});
const base64=(bytes)=>{let s='';for(const b of bytes)s+=String.fromCharCode(b);return btoa(s);};
${ENGINE_DISPATCH}`)) as {dispatch:(ctx:unknown)=>Promise<void>};

const ctx=(profile:string)=>({job:{id:"e1000000-0000-4000-8000-0000000000a1",actor_id:ACTOR,org_id:ORG,library_org_id:ORG,listing_id:LISTING,quality_profile:profile,
 quality_identity:profile===KIE_PROPERTY_PROFILE?jsonbOrder(JSON.parse(JSON.stringify(KIE))):null,manifest:{aspect:"16:9"}},
 source:{attempt_id:"e1000000-0000-4000-8000-0000000000a2",lease_token:"e1000000-0000-4000-8000-0000000000a3",request_key:REQUEST_KEY,asset_id:ASSET,photo_provenance_id:null,motion:"side_glide",
  source:{bucket:"uploads",storage_key:KEY,bytes:BYTES.length,etag:ETAG,content_type:"image/jpeg",sha256:SOURCE_SHA}}});

type Filed={code:string;ambiguous:boolean};
type Scenario={label:string;profile:string;kie?:Answer;fal?:number;missingKey?:boolean;releaseUnconfirmed?:boolean};
async function dispatchOnce(route:Route,s:Scenario){
 resetRouterCache();resetServingModeCache();
 Object.assign(state,{route:route.make(routeStub),http:[],worker:[],rpcs:[],kiePosts:[],falSubmits:0,charges:0,refunds:0,reservation:null,receipt:null,kie:s.kie??null,
  falError:s.fal?new ProviderError("fal","upstream",`fal request failed (HTTP ${s.fal})`,s.fal,true):null,releaseUnconfirmed:!!s.releaseUnconfirmed,logs:[]});
 const saved={error:console.error,warn:console.warn,log:console.log,info:console.info,debug:console.debug};
 for(const k of Object.keys(saved) as (keyof typeof saved)[])console[k]=(...args:unknown[])=>{state.logs.push(args);};
 if(s.missingKey)Deno.env.delete("KIE_API_KEY");
 try{await engine.dispatch(ctx(s.profile));}
 finally{Object.assign(console,saved);Deno.env.set("KIE_API_KEY",FIXTURE_KIE_KEY);}
 assert(!JSON.stringify(state.logs).includes(FIXTURE_KIE_KEY),"the provider secret is never printed");
 const filed:Filed[]=state.worker.filter(([name])=>name==="property_video_job_failure").map(([,args])=>({code:args.p_code,ambiguous:args.p_ambiguous}));
 const hold=state.reservation===null?"none":state.reservation.released_at?"released":"held";
 return{filed,http:state.http,hold,posts:state.kiePosts.length,falSubmits:state.falSubmits,charges:state.charges,refunds:state.refunds,rpcs:[...state.rpcs]};
}

const CAPACITY:Filed={code:"capacity_before_dispatch",ambiguous:false},REFUSED:Filed={code:"provider_submit_refused",ambiguous:false},UNCONFIRMED:Filed={code:"provider_submit_refused",ambiguous:true};
const envelope=(code:number,msg:string):Answer=>({body:{code,msg,data:null}});
const KIE_P=KIE_PROPERTY_PROFILE as string;
/** filed = with the G2 guards; before = the pre-G2 route (base 462e4c8 + F1), reproduced by the controls. */
const SCENARIOS:{s:Scenario;http:number;filed:Filed;before:Filed;beforeHttp:number;hold:"none"|"released"|"held";posts:number}[]=[
 {s:{label:"Kie createTask 402 out of credits",profile:KIE_P,kie:envelope(402,"Credits insufficient")},http:402,filed:CAPACITY,before:REFUSED,beforeHttp:502,hold:"released",posts:1},
 {s:{label:"Kie createTask 401 key rejected",profile:KIE_P,kie:envelope(401,"Unauthorized")},http:402,filed:CAPACITY,before:REFUSED,beforeHttp:502,hold:"released",posts:1},
 {s:{label:"Kie createTask 403 key blocked",profile:KIE_P,kie:envelope(403,"Forbidden")},http:402,filed:CAPACITY,before:REFUSED,beforeHttp:502,hold:"released",posts:1},
 {s:{label:"Kie HTTP 402 answer",profile:KIE_P,kie:{status:402,body:{code:402,msg:"Credits insufficient"}}},http:402,filed:CAPACITY,before:REFUSED,beforeHttp:502,hold:"released",posts:1},
 {s:{label:"KIE_API_KEY unset",profile:KIE_P,missingKey:true},http:402,filed:CAPACITY,before:REFUSED,beforeHttp:503,hold:"none",posts:0},
 {s:{label:"Kie createTask 429 rate limited",profile:KIE_P,kie:envelope(429,"Too many requests")},http:429,filed:CAPACITY,before:CAPACITY,beforeHttp:429,hold:"released",posts:1},
 {s:{label:"Kie createTask 404",profile:KIE_P,kie:envelope(404,"Not found")},http:502,filed:REFUSED,before:REFUSED,beforeHttp:502,hold:"released",posts:1},
 {s:{label:"Kie createTask 422 invalid input",profile:KIE_P,kie:envelope(422,"Invalid params")},http:400,filed:REFUSED,before:REFUSED,beforeHttp:400,hold:"released",posts:1},
 {s:{label:"Kie createTask 500 (ambiguous)",profile:KIE_P,kie:envelope(500,"Internal error")},http:502,filed:UNCONFIRMED,before:UNCONFIRMED,beforeHttp:502,hold:"held",posts:1},
 {s:{label:"Kie code 200 without a taskId (ambiguous)",profile:KIE_P,kie:{body:{code:200,msg:"success",data:{}}}},http:502,filed:UNCONFIRMED,before:UNCONFIRMED,beforeHttp:502,hold:"held",posts:1},
 {s:{label:"Kie 402 whose release is unconfirmed",profile:KIE_P,kie:envelope(402,"Credits insufficient"),releaseUnconfirmed:true},http:502,filed:UNCONFIRMED,before:UNCONFIRMED,beforeHttp:502,hold:"held",posts:1},
 {s:{label:"FAL steady-v2 402",profile:"fal-kling3-4k-steady-v2",fal:402},http:502,filed:REFUSED,before:REFUSED,beforeHttp:502,hold:"released",posts:0},
 {s:{label:"FAL v1 403",profile:"fal-kling3-4k-v1",fal:403},http:502,filed:REFUSED,before:REFUSED,beforeHttp:502,hold:"released",posts:0},
];
/** Every scenario files exactly `pick` (one failure, the decisive HTTP status, the money facts). */
async function workerFiles(route:Route,pick:"filed"|"before"){
 for(const c of SCENARIOS){
  const r=await dispatchOnce(route,c.s),label=c.s.label;
  assertEquals(r.filed,[c[pick]],label);assertEquals(r.http,[pick==="filed"?c.http:c.beforeHttp],label);
  assertEquals([r.hold,r.posts,r.falSubmits],[c.hold,c.posts,c.s.fal?1:0],label);
  // An unset key refuses before any read, allowance or hold; every later refusal refunds the
  // allowance only when its hold was released (an unconfirmed outcome keeps both).
  if(c.hold==="none")assertEquals([r.charges,r.refunds,r.rpcs],[0,0,[]],label);
  else assertEquals([r.charges,r.refunds],[1,c.hold==="released"?1:0],label);
 }
}

const MAPPING='if(savedQualityProfile==="kie-kling3-4k-steady-v1"&&e instanceof HttpError&&e.details?.provider==="kie"&&e.details?.dispatch_rejected===true&&[401,402,403].includes(e.details?.provider_status as number))throw new HttpError(402,KIE_VENDOR_NOT_READY,"upstream",e.details);';
const PREFLIGHT='if(!Deno.env.get("KIE_API_KEY")?.trim()){console.error("ai-video reel submit refused before dispatch",{provider:"kie",reason:"provider_not_configured"});throw new HttpError(402,KIE_VENDOR_NOT_READY,"upstream");}';
const PRE_FIX_PREFLIGHT='assert(!!Deno.env.get("KIE_API_KEY")?.trim(),503,"The native-4K video provider is not configured.");';
const actual=await compileRoute();

Deno.test("actual worker dispatch: a Kie 401/402/403 refusal or an unset key files a resumable capacity pause; every other outcome files what it did before",async()=>{
 await workerFiles(actual,"filed");
});

Deno.test("compiled defect controls: each new ai-video guard is what turns the terminal refusal into a resumable pause",async()=>{
 // 1. Both guards reverted (the pre-G2 route): every scenario files exactly its previous code.
 const preFix=await compileRoute(once(once(INDEX_SOURCE,MAPPING,""),PREFLIGHT,PRE_FIX_PREFLIGHT));
 await workerFiles(preFix,"before");
 // 2. Mapping removed alone: the vendor-account refusals become terminal again.
 const unmapped=await compileRoute(once(INDEX_SOURCE,MAPPING,""));
 for(const c of SCENARIOS.slice(0,4)){const r=await dispatchOnce(unmapped,c.s);assertEquals([r.filed,r.http],[[REFUSED],[502]],"control: "+c.s.label);}
 let caught=false;try{await workerFiles(unmapped,"filed");}catch{caught=true;}assert(caught,"control: the oracle detects the missing mapping");
 // 3. Preflight back to its pre-G2 503 alone: an unset key fails the source terminally.
 const terminal=await compileRoute(once(INDEX_SOURCE,PREFLIGHT,PRE_FIX_PREFLIGHT));
 const unset=await dispatchOnce(terminal,SCENARIOS[4].s);assertEquals([unset.filed,unset.http,unset.charges],[[REFUSED],[503],0],"control: 503 preflight");
 caught=false;try{await workerFiles(terminal,"filed");}catch{caught=true;}assert(caught,"control: the oracle detects the terminal preflight");
 // 4. Mapping widened to every profile and provider: FAL account refusals would pause too.
 const widened=await compileRoute(once(INDEX_SOURCE,MAPPING,MAPPING.replace('savedQualityProfile==="kie-kling3-4k-steady-v1"&&e instanceof HttpError&&e.details?.provider==="kie"&&','e instanceof HttpError&&')));
 for(const c of SCENARIOS.filter(x=>x.s.fal)){const r=await dispatchOnce(widened,c.s);assertNotEquals(r.filed,[REFUSED],"control: "+c.s.label);}
 caught=false;try{await workerFiles(widened,"filed");}catch{caught=true;}assert(caught,"control: the FAL rows detect a widened mapping");
});

Deno.test("harness sanity: an accepted Kie createTask returns 202 to the worker, files nothing and sent exactly the closed native-4K wire",async()=>{
 const r=await dispatchOnce(actual,{label:"accepted",profile:KIE_P,kie:{body:{code:200,msg:"success",data:{taskId:"kie-task-fixture-accepted"}}}});
 assertEquals([r.filed,r.http,r.hold,r.posts,r.charges,r.refunds],[[],[202],"held",1,1,0]);
 assertEquals(state.reservation?.provider_request_id,"kie-task-fixture-accepted");
 assert(state.worker.some(([name,args])=>name==="property_video_job_receipt"&&args.p_receipt.request_id==="kie-task-fixture-accepted"),"the accepted receipt is saved");
 const post=state.kiePosts[0];
 assertEquals(post,{model:"kling-3.0/video",input:{prompt:buildSteadyPropertyReelPrompt("home","side_glide","16:9"),
  image_urls:[`https://r2-fixture.invalid/${R2_BUCKET_UPLOADS}/${KEY}?X-Amz-Expires=7200&X-Amz-Signature=fixture`],sound:false,duration:"5",mode:"4K",multi_shots:false}});
});

// Registered last: the process environment is shared by every test module in one run.
Deno.test("restore the process KIE_API_KEY this module set for its fixtures",()=>{
 if(KIE_KEY_BEFORE===undefined)Deno.env.delete("KIE_API_KEY");else Deno.env.set("KIE_API_KEY",KIE_KEY_BEFORE);
 assertEquals(Deno.env.get("KIE_API_KEY"),KIE_KEY_BEFORE);
});
