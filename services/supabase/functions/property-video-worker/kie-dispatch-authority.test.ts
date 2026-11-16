// Per-dispatch Kie supplier authority at the ACTUAL worker boundary. engine.ts's
// aiScope/callAI/fail/dispatch are compiled from source and drive the ACTUAL
// ai-video handler prelude + /reel-clip route (compiled from index.ts with its own
// imports). The authority closure is engine.ts's own and its RPC goes through the
// REAL property-video-jobs/runtime.ts rpc (supabase-js -> closed PostgREST fixture ->
// throwRpc), so an SQL RP403 reaches the worker exactly as production maps it.
// Only I/O edges are doubles; nothing reaches Kie, FAL, R2 or a database.
import {assert,assertEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
// Same fixture database values as the other Kie dispatch tests (identical values, so
// module order cannot matter); never a real project or credential.
for(const[k,v]of Object.entries({SUPABASE_URL:"https://kie-dispatch-db.fixture.invalid",SUPABASE_ANON_KEY:"public-fixture",SUPABASE_SERVICE_ROLE_KEY:"service-fixture"}))Deno.env.set(k,v);
for(const k of["SUPABASE_SECRET_KEYS","RENDPROP_SECRET_KEY_NAME","SUPABASE_PUBLISHABLE_KEYS","RENDPROP_PUBLISHABLE_KEY_NAME"])Deno.env.delete(k);
// A synthetic fixture string (never a credential); restored by the last test.
const FIXTURE_KIE_KEY="offline-fixture-kie-authority-key-MUST-NOT-BE-LOGGED",KIE_KEY_BEFORE=Deno.env.get("KIE_API_KEY");
Deno.env.set("KIE_API_KEY",FIXTURE_KIE_KEY);

const FUNCTIONS=new URL("../",import.meta.url),INDEX=new URL("ai-video/index.ts",FUNCTIONS);
const {KIE_PROPERTY_IDENTITY:KIE,KIE_PROPERTY_PROFILE}=await import(new URL("_shared/property-video-kie.ts",FUNCTIONS).href);
const {resetRouterCache}=await import(new URL("_shared/router.ts",FUNCTIONS).href);
const {resetServingModeCache}=await import(new URL("_shared/funded-serving.ts",FUNCTIONS).href);
const {resolveChain:realResolveChain}=await import(new URL("_shared/providers/chain.ts",FUNCTIONS).href);
const {R2_BUCKET_UPLOADS}=await import(new URL("_shared/r2.ts",FUNCTIONS).href);
const {HttpError}=await import(new URL("_shared/http.ts",FUNCTIONS).href);
// The worker's actual RPC helper and its error mapping (adminClient().rpc -> throwRpc).
const {rpc:workerRpc}=await import(new URL("property-video-jobs/runtime.ts",FUNCTIONS).href);

const enc=(s:string)=>{const b=new TextEncoder().encode(s);let out="";for(let i=0;i<b.length;i+=32768)out+=String.fromCharCode(...b.subarray(i,i+32768));return "data:application/typescript;base64,"+btoa(out);};
const absolute=(text:string,base:URL)=>text.replace(/from\s+(["'])(\.\.?\/[^"']+)\1/g,(_a,_q,path)=>`from ${JSON.stringify(new URL(path,base).href)}`);
const between=(text:string,start:string,end:string)=>{const a=text.indexOf(start),b=text.indexOf(end,a+start.length);assert(a>=0&&b>a,"Actual anchor changed: "+start);return text.slice(a,b);};
const fn=(text:string,name:string)=>{const m=new RegExp(`(?:export )?(?:async )?function ${name}\\(`).exec(text);assert(m,"Actual helper missing: "+name);return text.slice(m.index,text.indexOf("\n}\n",m.index)+3).replace(/^export /,"");};
const once=(text:string,before:string,after:string)=>{assertEquals(text.split(before).length,2,"Mutation anchor must be unique: "+before);return text.replace(before,()=>after);};
const sha=async(value:Uint8Array)=>Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",new Uint8Array(value))),b=>b.toString(16).padStart(2,"0")).join("");
const fails=(check:()=>void,label:string)=>{let caught=false;try{check();}catch{caught=true;}assert(caught,"control: "+label);};

// ---- the actual ai-video route (same compile as property-video-kie-dispatch.test.ts) ----
const INDEX_SOURCE=await Deno.readTextFile(INDEX);
const SIGNATURE="export async function handleAiVideo(req:Request,worker?:AiVideoWorkerScope):Promise<Response> {";
type Route={make:(stub:unknown)=>(req:Request,worker?:unknown)=>Promise<Response>};
async function compileRoute(indexSource=INDEX_SOURCE):Promise<Route>{
 const imports=(indexSource.match(/^import [\s\S]*?;\n/gm)??[]).map(s=>absolute(s,INDEX)).join("");
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
 ${prelude}
${route}
    throw new HttpError(404,"Closed fixture route");
  } catch (err) { return respondError(err); }
 };
}`)) as Route;
}

const ACTOR="e1000000-0000-4000-8000-000000000001",ORG="e1000000-0000-4000-8000-000000000002",LISTING="e1000000-0000-4000-8000-000000000003",ASSET="e1000000-0000-4000-8000-000000000004";
const JOB="e1000000-0000-4000-8000-0000000000c1",ATTEMPT="e1000000-0000-4000-8000-0000000000c2",LEASE="e1000000-0000-4000-8000-0000000000c3";
const BYTES=new TextEncoder().encode("owned-prepared-source-photo-bytes"),SOURCE_SHA=await sha(BYTES);
const KEY=`uploads/${ORG}/${LISTING}/prepared-source.jpg`,ETAG='"src-etag"',DB_HOST="kie-dispatch-db.fixture.invalid",REQUEST_KEY="kie-authority-source-attempt-0001";
const KIE_ROW={id:KIE.route_id,task:KIE.task,position:1,provider:"kie",model:"kling-3.0/video",unit:"second",unit_cents:33.5,capabilities:["i2v","1080p","5s","native4k","preserve_photo"],
 max_latency_s:1800,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"trains_by_default",enabled:true,retire_after:null,note:"kie-kling3-4k-steady-v1 pinned route",params:{kie_mode:"4K",sound:false}};
const FAL_ROW={id:"closed-normal-fal4k",task:"video.property_reel_clip",position:1,provider:"fal",model:"fal-ai/kling-video/v3/4k/image-to-video",unit:"second",unit_cents:42,
 capabilities:["i2v","1080p","5s","native4k","preserve_photo"],max_latency_s:900,min_plan:"free",same_model_as:"kling_3_pro",privacy_tier:"retained_30d",enabled:true,retire_after:null,note:null,params:null};
/** Postgres jsonb object key order (what the worker forwards from the job row). */
const byteOrder=(a:string,b:string)=>{const x=new TextEncoder().encode(a),y=new TextEncoder().encode(b);if(x.length!==y.length)return x.length-y.length;for(let i=0;i<x.length;i++)if(x[i]!==y[i])return x[i]-y[i];return 0;};
const jsonbOrder=(value:unknown):any=>Array.isArray(value)?value.map(jsonbOrder):value&&typeof value==="object"
 ?Object.fromEntries(Object.keys(value).sort(byteOrder).map(k=>[k,jsonbOrder((value as Record<string,unknown>)[k])])):value;

/** The PostgREST answer of property_video_kie_dispatch_authority. */
type Answer={status:number;body:unknown};
const ACCEPTED:Answer={status:200,body:{authority:"owner_quality_test",grant_id:"e1000000-0000-4000-8000-0000000000c9",attempt_id:ATTEMPT,creates_used:1,cents_used:167.5,replayed:false}};
const refusal=(message:string):Answer=>({status:400,body:{message,code:"P0001",details:null,hint:null}});
const GRANT_ENDED="RP403: The owner quality-test permission has ended. No new clip was sent.",BUDGET_USED="RP403: The owner quality-test budget is used up. No new clip was sent.",
 OUTSIDE="RP403: This clip is outside the owner quality-test permission",NOT_EXACT="RP409: This saved video is not an exact native-4K Kie recipe with its processor permission";
const AUTHORITY_UNAVAILABLE="The native-4K dispatch authority is unavailable. No generation was sent.";
type Reservation={released_at:string|null;provider_request_id:string|null;model:unknown};
const state={route:null as null|((req:Request,worker?:unknown)=>Promise<Response>),http:[] as number[],bodies:[] as any[],worker:[] as [string,any][],events:[] as string[],rpcs:[] as string[],
 posts:0,charges:0,refunds:0,reservation:null as Reservation|null,receipt:null as unknown,authority:ACCEPTED,authorityRequests:[] as {path:string;body:unknown}[],workerRpc};
(globalThis as any).__kieAuthorityWorker=()=>state;

// One closed transport for every module (supabase-js for the route AND the worker's real rpc(), funded serving, source read).
globalThis.fetch=(async(input:RequestInfo|URL,init?:RequestInit)=>{
 const req=new Request(input,init),u=new URL(req.url);
 if(u.hostname===DB_HOST){
  // The SQL authority: reachable only through the worker's real rpc() (a supabase-js POST).
  if(u.pathname==="/rest/v1/rpc/property_video_kie_dispatch_authority"){
   state.events.push("authority");state.authorityRequests.push({path:u.pathname,body:await req.json()});
   return new Response(JSON.stringify(state.authority.body),{status:state.authority.status,headers:{"content-type":"application/json"}});
  }
  if(u.pathname==="/rest/v1/rpc/serving_mode")return Response.json("funded");
  if(u.pathname==="/rest/v1/rpc/report_provider_outcome")return new Response(null,{status:204});
  if(u.pathname==="/rest/v1/ai_routes"&&u.searchParams.get("id")==="eq."+KIE.route_id&&!u.searchParams.has("task"))return Response.json([KIE_ROW]);
  if(u.pathname==="/rest/v1/ai_routes"&&u.searchParams.get("task")==="eq.video.property_reel_clip")return Response.json([FAL_ROW]);
  if(u.pathname==="/rest/v1/app_config")return Response.json({value:{enabled:true}});
  if(u.pathname==="/rest/v1/provider_health")return Response.json([]);
 }
 if(u.hostname==="api.kie.ai"&&u.pathname==="/api/v1/chat/credit"&&req.method==="GET"){
  assertEquals(req.headers.get("authorization"),`Bearer ${FIXTURE_KIE_KEY}`);
  return Response.json({code:200,data:1000});
 }
 if(u.hostname==="r2-fixture.invalid"&&req.method==="GET"&&u.searchParams.get("X-Amz-Expires")==="300")return new Response(BYTES,{status:200,headers:{etag:ETAG}});
 throw new Error("Closed fixture refused "+u.hostname+u.pathname);
}) as typeof fetch;

// The route's SQL boundary (allowance hold and its release/settle, exactly as the worker reads them afterwards).
const rpc=async(name:string,args:Record<string,unknown>)=>{state.rpcs.push(name);state.events.push(name);
 if(name==="property_owned_upload")return{data:{actor_id:ACTOR,org_id:ORG,listing_id:LISTING,asset_id:ASSET,bucket:"uploads",storage_key:KEY,bytes:BYTES.length,etag:ETAG,content_type:"image/jpeg",sha256:SOURCE_SHA},error:null};
 if(name==="property_photo_reference")return{data:{},error:null};
 if(name==="app_video_cost_reserve_v2"){assertEquals(args.p_key,REQUEST_KEY);state.reservation={released_at:null,provider_request_id:null,model:args.p_model};return{data:{reserved:true},error:null};}
 if(name==="serving_cost_reserve")return{data:{reserved:true},error:null};
 if(name==="serving_cost_finish")return{data:{finished:true},error:null};
 if(name==="app_video_cost_release_rejected"){state.reservation!.released_at="2026-10-16T00:00:01.000Z";return{data:{released:true},error:null};}
 if(name==="app_video_cost_settle"){state.reservation!.provider_request_id=String(args.p_provider_request_id);return{data:{settled:true},error:null};}
 if(name==="bind_property_video_source")return{data:{bound:true},error:null};
 if(name==="org_has_internal_testing_grant"||name==="org_has_private_internal_testing")return{data:false,error:null};
 throw new Error("Unexpected closed RPC "+name);};
const routeStub={
 getUser:()=>{throw new Error("worker path never authenticates HTTP");},userClient:()=>{throw new Error("worker path never uses a user client");},adminClient:()=>({rpc}),
 headObject:async(bucket:string,key:string)=>{state.events.push("head");assertEquals([bucket,key],[R2_BUCKET_UPLOADS,KEY]);return{exists:true,bytes:BYTES.length,etag:ETAG,contentType:"image/jpeg"};},
 presignGet:async(bucket:string,key:string,seconds:number)=>{state.events.push("sign:"+seconds);return `https://r2-fixture.invalid/${bucket}/${key}?X-Amz-Expires=${seconds}&X-Amz-Signature=fixture`;},
 guardGenerate:async()=>{state.events.push("charge");state.charges++;return{orgId:ORG,plan:"team",monthlyKey:"m",burstKey:"b",monthlyReceipt:{windowStart:"2026-10-16T00:00:00Z"},burstReceipt:{windowStart:"2026-10-16T01:00:00Z"}};},
 refundGenerateCharge:async()=>{state.refunds++;},routerEnabled:async()=>false,
 ownerQaReelStep:async()=>{throw new Error("Owner QA is unreachable for saved quality profiles");},resolveChain:realResolveChain,
 // Provider adapters are doubles here (the Kie wire belongs to kie.ts and its own tests).
 adapterFor:(provider:string)=>({submit:async(step:Record<string,unknown>)=>{state.events.push("POST");state.posts++;return{provider,model:step.model,id:"provider-accepted-task",submitted_at:"2026-10-16T00:00:00.000Z"};}}),
 submitEnvelope:async(_req:Request,_on:boolean,_task:string,ref:{id:string})=>({request_id:ref.id,status_url:"https://fixture.invalid/ai-video/status?job=opaque",response_url:"https://fixture.invalid/ai-video/status?job=opaque"}),
 assertVideoReceiptSigningReady:async()=>{},recordProvenance:async()=>{throw new Error("worker provenance only");},retainVideoSubmission:async()=>{throw new Error("worker never journals HTTP receipts");},
 resolvePublicAsset:async()=>{throw new Error("asset path unreachable");},listingSpaceType:async()=>"real_estate",contentOrgForUser:async()=>ORG,putBytes:async()=>{throw new Error("no staging");},
};

// ---- the actual worker dispatch (engine.ts aiScope + callAI + fail + dispatch) ----
const ENGINE=await Deno.readTextFile(new URL("./engine.ts",import.meta.url));
const engineStart=ENGINE.indexOf("async function aiScope("),engineEnd=ENGINE.indexOf("export type PropertyVideoPollPhase=",engineStart);
assert(engineStart>0&&engineEnd>engineStart,"actual worker dispatch entry point");
const ENGINE_DISPATCH=ENGINE.slice(engineStart,engineEnd);
const AUTHORITY_FIELD=between(ENGINE_DISPATCH,"kieDispatchAuthority:async()=>{","provenance:async args=>");
assert(AUTHORITY_FIELD.endsWith("},"),"actual authority closure field boundary");
type Engine={dispatch:(ctx:unknown)=>Promise<void>;aiScope:(ctx:unknown)=>Promise<any>};
async function compileEngine(source=ENGINE_DISPATCH):Promise<Engine>{
 return await import("data:application/typescript,"+encodeURIComponent(`
import{assert}from ${JSON.stringify(new URL("../_shared/http.ts",import.meta.url).href)};
import{PHOTO_MOTION_MODE}from ${JSON.stringify(new URL("../_shared/photo-motion.ts",import.meta.url).href)};
type AiVideoWorkerScope=any;
const f=()=>globalThis.__kieAuthorityWorker();
const handleAiVideo=async(req,worker)=>{const response=await f().route(req,worker);f().http.push(response.status);f().bodies.push(await response.clone().json());return response;};
const scope=async(...args)=>{f().worker.push(['scope',args]);};
// Every worker RPC is recorded; the dispatch authority goes through the REAL runtime.ts rpc().
const rpc=async(name,args)=>{f().worker.push([name,args]);if(name==='property_video_kie_dispatch_authority')return await f().workerRpc(name,args);
 if(name==='property_video_job_receipt')f().receipt=args.p_receipt;
 if(name==='property_video_job_provenance')return{id:'e1000000-0000-4000-8000-0000000000b1',disclosure:'AI motion from photographs'};return true;};
const adminClient=()=>({from:table=>{const q={select:()=>q,eq:()=>q,maybeSingle:async()=>{
 if(table==='property_video_job_sources')return{error:null,data:{receipt:f().receipt}};
 if(table==='app_video_cost_reservations')return{error:null,data:f().reservation?{...f().reservation}:null};
 throw new Error('closed worker table '+table);}};return q;}});
const bytesFrom=async()=>({bytes:new Uint8Array(${JSON.stringify([...BYTES])}),sha256:${JSON.stringify(SOURCE_SHA)}});
const validatePhotoInput=()=>({width:2048,height:1365});
const base64=(bytes)=>{let s='';for(const b of bytes)s+=String.fromCharCode(b);return btoa(s);};
${source}
export{aiScope};`)) as Engine;
}

const KIE_P=KIE_PROPERTY_PROFILE as string;
const ctx=(profile:string)=>({job:{id:JOB,actor_id:ACTOR,org_id:ORG,library_org_id:ORG,listing_id:LISTING,quality_profile:profile,
 quality_identity:profile===KIE_P?jsonbOrder(JSON.parse(JSON.stringify(KIE))):null,manifest:{aspect:"16:9"}},
 source:{attempt_id:ATTEMPT,lease_token:LEASE,request_key:REQUEST_KEY,asset_id:ASSET,photo_provenance_id:null,motion:"side_glide",
  source:{bucket:"uploads",storage_key:KEY,bytes:BYTES.length,etag:ETAG,content_type:"image/jpeg",sha256:SOURCE_SHA}}});
const AUTHORITY_ARGS={p_job:JOB,p_lease:LEASE,p_attempt:ATTEMPT};
type Filed={code:string;ambiguous:boolean};
const REFUSED:Filed={code:"provider_submit_refused",ambiguous:false},CAPACITY:Filed={code:"capacity_before_dispatch",ambiguous:false};
async function dispatchOnce(engine:Engine,route:Route,profile:string,authority:Answer=ACCEPTED){
 resetRouterCache();resetServingModeCache();
 Object.assign(state,{route:route.make(routeStub),http:[],bodies:[],worker:[],events:[],rpcs:[],posts:0,charges:0,refunds:0,reservation:null,receipt:null,authority,authorityRequests:[]});
 const saved=console.error;console.error=()=>{};
 try{await engine.dispatch(ctx(profile));}finally{console.error=saved;}
 const filed:Filed[]=state.worker.filter(([name])=>name==="property_video_job_failure").map(([,args])=>({code:args.p_code,ambiguous:args.p_ambiguous}));
 const hold=state.reservation===null?"none":state.reservation.released_at?"released":"held";
 return{filed,http:[...state.http],body:state.bodies[0],hold,posts:state.posts,charges:state.charges,refunds:state.refunds,rpcs:[...state.rpcs],events:[...state.events],
  authority:state.worker.filter(([name])=>name==="property_video_kie_dispatch_authority").map(([,args])=>args)};
}
type Outcome=Awaited<ReturnType<typeof dispatchOnce>>;
/** The exact worker closure checks its current attempt at the final prospective POST boundary. */
function dispatchedOnce(r:Outcome){
 assertEquals([r.filed,r.http,r.hold,r.posts,r.charges,r.refunds],[[],[202],"held",1,1,0]);assertEquals(r.authority,[AUTHORITY_ARGS]);
 const at=(event:string)=>r.events.indexOf(event);
 assert(at("property_owned_upload")<at("charge")&&at("charge")<at("app_video_cost_reserve_v2")&&at("app_video_cost_reserve_v2")<at("serving_cost_reserve")&&at("serving_cost_reserve")<at("sign:7200")&&at("sign:7200")<at("authority"),r.events.join(","));
 assertEquals(at("POST"),at("authority")+1);
}
/** A definitive SQL refusal is terminal after confirmed hold release and allowance refund. */
function terminalRefusal(r:Outcome,status:number,message:string){
 assertEquals(r.filed,[REFUSED],message);assertEquals(r.http,[status],message);
 assertEquals([r.body?.error,r.body?.code],[message.replace(/^RP\d{3}:\s*/,""),status===403?"forbidden":"conflict"],message);
 assertEquals([r.hold,r.posts,r.charges,r.refunds],["released",0,1,1],message);assertEquals(r.authority,[AUTHORITY_ARGS],message);
 assertEquals(r.rpcs.filter(x=>x==="app_video_cost_release_rejected").length,1);assert(!r.rpcs.includes("app_video_cost_settle"));
}
const engine=await compileEngine(),actual=await compileRoute();

Deno.test("engine aiScope: kieDispatchAuthority calls exactly property_video_kie_dispatch_authority(job, lease, attempt) through the real rpc()",async()=>{
 Object.assign(state,{worker:[],events:[],authority:ACCEPTED,authorityRequests:[]});
 const scope=await engine.aiScope(ctx(KIE_P));assertEquals(typeof scope.kieDispatchAuthority,"function");
 assertEquals(await scope.kieDispatchAuthority(),ACCEPTED.body);
 assertEquals(state.worker,[["property_video_kie_dispatch_authority",AUTHORITY_ARGS]]);
 assertEquals(state.authorityRequests,[{path:"/rest/v1/rpc/property_video_kie_dispatch_authority",body:AUTHORITY_ARGS}]);
 // The same closure maps an SQL refusal through throwRpc: HttpError 403 carrying the SQL copy.
 for(const[message,status,code]of[[GRANT_ENDED,403,"forbidden"],[NOT_EXACT,409,"conflict"]]as const){
  Object.assign(state,{authority:refusal(message)});let caught:any=null;try{await scope.kieDispatchAuthority();}catch(error){caught=error;}
  assert(caught instanceof HttpError,message);assertEquals([caught.status,caught.code,caught.message],[status,code,message.replace(/^RP\d{3}:\s*/,"")]);
 }
});

Deno.test("actual worker dispatch: an accepted authority dispatches once after source, allowance and reservations",async()=>{
 dispatchedOnce(await dispatchOnce(engine,actual,KIE_P));
 // An attempt the grant already counted (replayed:true) dispatches the same way: SQL is the idempotency authority.
 dispatchedOnce(await dispatchOnce(engine,actual,KIE_P,{status:200,body:{...(ACCEPTED.body as Record<string,unknown>),replayed:true}}));
});

Deno.test("an ended, used-up or out-of-scope owner test files terminal refusal after release/refund, never a capacity pause or supplier POST",async()=>{
 for(const message of[GRANT_ENDED,BUDGET_USED,OUTSIDE])terminalRefusal(await dispatchOnce(engine,actual,KIE_P,refusal(message)),403,message);
 // Not the exact recipe/permission (RP409) is terminal too.
 terminalRefusal(await dispatchOnce(engine,actual,KIE_P,refusal(NOT_EXACT)),409,NOT_EXACT);
});

Deno.test("unfunded FAL worker route never asks for Kie authority or sends a supplier request",async()=>{
 for(const profile of["fal-kling3-4k-steady-v2","fal-kling3-4k-v1"]){
  const r=await dispatchOnce(engine,actual,profile,refusal(GRANT_ENDED));
  assertEquals([r.filed,r.http,r.hold,r.posts,r.charges,r.refunds,r.authority],[[REFUSED],[503],"none",0,1,1,[]],profile);
  assert(!r.events.includes("authority")&&!r.events.includes("POST")&&!r.rpcs.includes("app_video_cost_reserve_v2"),profile);
 }
});

Deno.test("compiled defect controls: the 403 passthrough keeps an ended grant terminal, and the engine field is load-bearing",async()=>{
 // 1. The route maps the authority refusal to the vendor 402: the worker would file a resumable capacity pause.
 const asPause=await compileRoute(once(INDEX_SOURCE,"if(kieAuthorityRefusal&&!(e instanceof VideoDispatchUnconfirmed))throw kieAuthorityRefusal;",'if(kieAuthorityRefusal&&!(e instanceof VideoDispatchUnconfirmed))throw new HttpError(402,KIE_VENDOR_NOT_READY,"upstream");'));
 const paused=await dispatchOnce(engine,asPause,KIE_P,refusal(GRANT_ENDED));
 assertEquals([paused.filed,paused.http],[[CAPACITY],[402]],"control: an ended grant becomes a capacity pause");fails(()=>terminalRefusal(paused,403,GRANT_ENDED),"402 mapping");
 // 2. engine.ts without the closure: every Kie dispatch fails closed (503), nothing is read, charged, held or sent.
 const noField=await compileEngine(once(ENGINE_DISPATCH,AUTHORITY_FIELD,""));
 const closed=await dispatchOnce(noField,actual,KIE_P);
 fails(()=>dispatchedOnce(closed),"closure removed");
 assertEquals([closed.filed,closed.http,closed.body?.error,closed.posts,closed.charges,closed.hold,closed.rpcs],[[REFUSED],[503],AUTHORITY_UNAVAILABLE,0,0,"none",[]]);
 // 3. engine.ts sending the lease as the attempt: the exact-argument oracle catches it.
 const swapped=await compileEngine(once(ENGINE_DISPATCH,AUTHORITY_FIELD,AUTHORITY_FIELD.replace("p_attempt:s.attempt_id","p_attempt:s.lease_token")));
 const wrong=await dispatchOnce(swapped,actual,KIE_P);fails(()=>dispatchedOnce(wrong),"attempt swapped for the lease");
 assertEquals(wrong.authority,[{p_job:JOB,p_lease:LEASE,p_attempt:LEASE}]);
 console.log("KIE_DISPATCH_AUTHORITY_WORKER_CONTROLS=3");
});

Deno.test("actual worker supplier authority validates exact reply shape, current job/attempt and bounded grant counters before POST",async()=>{
 const owner=ACCEPTED.body as Record<string,unknown>;
 const activated={authority:"activated_profile",job_id:JOB,attempt_id:ATTEMPT};
 dispatchedOnce(await dispatchOnce(engine,actual,KIE_P,{status:200,body:activated}));
 const invalid:unknown[]=[null,undefined,{},[],true,"accepted",{...owner,attempt_id:LEASE},{...owner,grant_id:"other"},{...owner,replayed:"true"},
  {...owner,creates_used:0},{...owner,creates_used:1.5},{...owner,creates_used:21},{...owner,cents_used:0},{...owner,cents_used:335},
  {...owner,cents_used:"167.5"},{...owner,extra:true},{...activated,job_id:LISTING},{...activated,attempt_id:LEASE},{...activated,extra:true}];
 for(const body of invalid){
  // Supabase JSON replies cannot contain undefined; null represents a missing body.
  const r=await dispatchOnce(engine,actual,KIE_P,{status:200,body:body??null});
  assertEquals([r.filed,r.http,r.hold,r.posts,r.charges,r.refunds],[[{code:"provider_submit_refused",ambiguous:true}],[502],"held",0,1,0],JSON.stringify(body));
  assertEquals(r.authority,[AUTHORITY_ARGS]);assert(!r.rpcs.includes("app_video_cost_release_rejected")&&!r.rpcs.includes("app_video_cost_settle"));
 }
 // A structurally valid second counted attempt is accepted with its matching total.
 dispatchedOnce(await dispatchOnce(engine,actual,KIE_P,{status:200,body:{...owner,creates_used:2,cents_used:335}}));
 // Compiled omission: a malformed HTTP200 answer becomes a paid supplier request if reply validation is removed.
 const validate="assert(object&&evidence.attempt_id===s.attempt_id&&(activated||owner),503,'The video dispatch permission could not be confirmed. No generation was sent.');";
 const unchecked=await compileEngine(once(ENGINE_DISPATCH,validate,""));
 const bad=await dispatchOnce(unchecked,actual,KIE_P,{status:200,body:{}});
 assertEquals([bad.http,bad.posts],[[202],1]);
 fails(()=>assertEquals(bad.posts,0),"malformed authority accepted without reply validation");
 console.log("KIE_DISPATCH_AUTHORITY_REPLY_CONTROL=1");
});

// Registered last: the process environment is shared by every test module in one run.
Deno.test("restore the process KIE_API_KEY this module set for its fixtures",()=>{
 if(KIE_KEY_BEFORE===undefined)Deno.env.delete("KIE_API_KEY");else Deno.env.set("KIE_API_KEY",KIE_KEY_BEFORE);
 assertEquals(Deno.env.get("KIE_API_KEY"),KIE_KEY_BEFORE);
});
