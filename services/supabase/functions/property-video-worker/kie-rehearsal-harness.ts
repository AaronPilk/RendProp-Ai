// Offline whole-chain rehearsal harness for the Kie native-4K property profile.
//
// What is REAL here: the Kie adapter (submit/poll wire bodies and host pins),
// ai-video's routedStatus with its routed-output journal (compiled from
// index.ts), persistResult, the r2.ts/common.ts R2 signers (PUT/HEAD/presign),
// the worker poll/quality/action in engine.ts (compiled), the MP4 probe
// (mp4video.ts), kieProperty4KFacts, runtime.ts bytesFrom and the drift lineage
// key. What is CLOSED: every HTTP edge (Kie API, Kie's file CDN, R2) is an
// in-process double, the SQL journal and the worker's job RPCs are recorded
// doubles, and the drift judge answers a fixed verdict. Nothing reaches Kie,
// FAL, R2 or a database; no credential is real; no provider POST leaves the
// process. Media is synthetic: ffmpeg-made H.264 clips generated at test time.
//
// This module is NOT a test file (no `test` in its name): `deno test .` only
// collects it through the two rehearsal tests that import it.
import{assert,assertEquals}from"https://deno.land/std@0.224.0/assert/mod.ts";
for(const[k,v]of Object.entries({CLOUDFLARE_ACCOUNT_ID:"kie-rehearsal-fixture",R2_ACCESS_KEY_ID:"synthetic-access",R2_SECRET_ACCESS_KEY:"synthetic-secret"}))if(!Deno.env.get(k))Deno.env.set(k,v);
export const FIXTURE_KIE_KEY="offline-fixture-kie-rehearsal-key";
export const KIE_KEY_BEFORE=Deno.env.get("KIE_API_KEY");
Deno.env.set("KIE_API_KEY",FIXTURE_KIE_KEY);

export const {PROPERTY_VIDEO_STEADY_PROFILE,PROPERTY_VIDEO_QUALITY_PROFILE}=await import("../ai-video/property-video-quality.ts");
export const {KIE_PROPERTY_PROFILE,KIE_PROPERTY_IDENTITY,KIE_PROPERTY_MODEL,kieProperty4KFacts,kiePropertyPromptPinned}=await import("../_shared/property-video-kie.ts");
export const common=await import("../_shared/providers/common.ts");
export const r2=await import("../_shared/r2.ts");
export const {kieAdapter,kiePropertyRequest}=await import("../_shared/providers/kie.ts");
export const {HttpError,respondError}=await import("../_shared/http.ts");
export const {buildSteadyPropertyReelPrompt}=await import("../ai-video/reel-framing.ts");
export const {probeRetainedProviderMP4Video}=await import("../ai-video/mp4video.ts");

const href=(path:string)=>JSON.stringify(new URL(path,import.meta.url).href);
export const enc=(s:string)=>{const b=new TextEncoder().encode(s);let out="";for(let i=0;i<b.length;i+=32768)out+=String.fromCharCode(...b.subarray(i,i+32768));return "data:application/typescript;base64,"+btoa(out);};
export const once=(text:string,before:string,after:string)=>{assertEquals(text.split(before).length,2,"exact actual text: "+before);return text.replace(before,()=>after);};

// ---- identities ----
export const ORG="10000000-0000-4000-8000-0000000000d1",USER="20000000-0000-4000-8000-0000000000d2",LISTING="30000000-0000-4000-8000-0000000000d3";
export const JOB_ID="40000000-0000-4000-8000-0000000000d4",ATTEMPT="50000000-0000-4000-8000-0000000000d5",LEASE="60000000-0000-4000-8000-0000000000d6",COMPOSE_LEASE="70000000-0000-4000-8000-0000000000d7";
export const TASK_ID="kie-rehearsal-task-0001";
export const KIE_RECORD_URL=`https://api.kie.ai/api/v1/jobs/recordInfo?taskId=${TASK_ID}`;
export const CDN_HOST="tempfile.aiquickdraw.com";

// ---- synthetic media (ffmpeg at test time; never committed) ----
export interface ClipSpec{width:number;height:number;rate:string;frames:number;name:string}
export const UHD_LANDSCAPE:ClipSpec={width:3840,height:2160,rate:"24",frames:120,name:"uhd-landscape"};
export const UHD_PORTRAIT:ClipSpec={width:2160,height:3840,rate:"24",frames:120,name:"uhd-portrait"};
export const HD_PRO_SUBSTITUTE:ClipSpec={width:1920,height:1080,rate:"24",frames:120,name:"hd-pro-substitute"};
export const UHD_NTSC:ClipSpec={width:3840,height:2160,rate:"24000/1001",frames:120,name:"uhd-23976"};
let ffmpegChecked:boolean|null=null;
export async function ffmpegAvailable():Promise<boolean>{
 if(ffmpegChecked!==null)return ffmpegChecked;
 try{const out=await new Deno.Command("ffmpeg",{args:["-version"],stdout:"null",stderr:"null"}).output();ffmpegChecked=out.success;}catch{ffmpegChecked=false;}
 return ffmpegChecked;
}
const clips=new Map<string,Uint8Array>();
/** An H.264/AVC yuv420p MP4 with moov first, no B-frames, exactly `frames`
 * frames at `rate` (CFR). A flat colour source keeps it small (about 100 KiB
 * at UHD); the gate verifies container/codec/geometry/cadence facts, not
 * pictures. */
export async function syntheticClip(spec:ClipSpec):Promise<Uint8Array>{
 const cached=clips.get(spec.name);if(cached)return cached;
 const dir=await Deno.makeTempDir({prefix:"kie-rehearsal-"});
 try{
  const file=`${dir}/${spec.name}.mp4`;
  const out=await new Deno.Command("ffmpeg",{args:["-loglevel","error","-y","-f","lavfi","-i",`color=c=0x334455:size=${spec.width}x${spec.height}:rate=${spec.rate}`,"-frames:v",String(spec.frames),"-c:v","libx264","-preset","ultrafast","-crf","30","-g","48","-bf","0","-pix_fmt","yuv420p","-movflags","+faststart","-an",file],stdout:"null",stderr:"piped"}).output();
  assert(out.success,"ffmpeg could not make the synthetic clip: "+new TextDecoder().decode(out.stderr));
  const bytes=await Deno.readFile(file);assert(bytes.length>0&&bytes.length<1024*1024,"synthetic clip stays under 1 MiB: "+bytes.length);
  clips.set(spec.name,bytes);return bytes;
 }finally{await Deno.remove(dir,{recursive:true}).catch(()=>{});}
}

// ---- the in-memory R2 (PUT if-none-match, HEAD, GET with Range/If-Match) ----
/** `declaredLength` lets HEAD describe an object larger than the bytes held (a
 * simulated oversize clip); GET still serves the bytes held. */
export type Stored={bytes:Uint8Array;type:string|null;etag:string;declaredLength?:number};
export const r2Store=new Map<string,Stored>();let etags=0;
function r2Response(req:Request,path:string):Response{
 if(req.method==="PUT")throw new Error("PUT is handled by the caller");
 const o=r2Store.get(path);if(!o)return new Response(null,{status:404});
 const base:Record<string,string>={etag:o.etag,"accept-ranges":"bytes"};if(o.type!==null)base["content-type"]=o.type;
 if(req.method==="HEAD")return new Response(null,{status:200,headers:{...base,"content-length":String(o.declaredLength??o.bytes.length)}});
 assertEquals(req.method,"GET");
 const match=req.headers.get("if-match");if(match!==null&&match!==o.etag)return new Response(null,{status:412});
 const range=req.headers.get("range");
 if(range){
  const m=/^bytes=(\d+)-(\d+)$/.exec(range);if(!m)return new Response(null,{status:416});
  const first=Number(m[1]),last=Math.min(Number(m[2]),o.bytes.length-1);if(first>last)return new Response(null,{status:416});
  const slice=o.bytes.slice(first,last+1);
  return new Response(slice,{status:206,headers:{...base,"content-length":String(slice.length),"content-range":`bytes ${first}-${last}/${o.bytes.length}`}});
 }
 return new Response(o.bytes.slice(),{status:200,headers:{...base,"content-length":String(o.bytes.length)}});
}
export function putStored(path:string,bytes:Uint8Array,type:string|null,declaredLength?:number):Stored{const s:Stored={bytes,type,etag:`"rehearsal-etag-${++etags}"`,...(declaredLength!==undefined?{declaredLength}:{})};r2Store.set(path,s);return s;}
export const r2Path=(bucket:string,key:string)=>`/${bucket}/${key.split("/").map(encodeURIComponent).join("/")}`;

// ---- the Kie API and its file CDN ----
export interface KieWire{
 /** createTask: the exact JSON body the adapter POSTed (recorded), answer taskId. */
 posts:unknown[];
 /** recordInfo: what the closed Kie answers. */
 record:()=>Record<string,unknown>;
 /** The CDN result: bytes with the declared headers. */
 cdn:()=>{bytes:Uint8Array;type:string|null;declaredLength?:number};
 polls:number;downloads:number;
}
export function kieSuccess(url:string,extra:Record<string,unknown>={}){return{taskId:TASK_ID,model:KIE_PROPERTY_MODEL,state:"success",param:JSON.stringify({model:KIE_PROPERTY_MODEL,input:{duration:"5",mode:"4K"}}),resultJson:JSON.stringify({resultUrls:[url]}),creditsConsumed:335,...extra};}
/** Installs the closed transport for one rehearsal; restores the previous fetch after. */
export async function withTransport<T>(wire:KieWire,action:()=>Promise<T>):Promise<T>{
 const previous=globalThis.fetch;
 globalThis.fetch=(async(input:RequestInfo|URL,init?:RequestInit)=>{
  const req=new Request(input,init),u=new URL(req.url);
  if(u.hostname.endsWith(".r2.cloudflarestorage.com")){
   const path=decodeURIComponent(u.pathname);
   if(req.method==="PUT"){
    assertEquals(req.headers.get("if-none-match"),"*","immutable CAS PUT");
    if(r2Store.has(path))return new Response(null,{status:412});
    putStored(path,new Uint8Array(await req.arrayBuffer()),req.headers.get("content-type"));return new Response(null,{status:200});
   }
   return r2Response(req,path);
  }
  if(u.hostname==="api.kie.ai"){
   assertEquals(req.headers.get("authorization"),`Bearer ${FIXTURE_KIE_KEY}`,"the fixture key authorizes the closed wire");
   if(u.pathname==="/api/v1/jobs/createTask"&&req.method==="POST"){wire.posts.push(await req.json());return Response.json({code:200,msg:"success",data:{taskId:TASK_ID}});}
   if(u.pathname==="/api/v1/jobs/recordInfo"&&req.method==="GET"){wire.polls++;assertEquals(u.searchParams.get("taskId"),TASK_ID);return Response.json({code:200,msg:"success",data:wire.record()});}
   throw new Error("Closed Kie wire refused "+req.method+" "+u.pathname);
  }
  // Kie's file host, and FAL's for the FAL controls: the same closed bytes.
  if((u.hostname===CDN_HOST||u.hostname==="fal.media")&&req.method==="GET"){
   wire.downloads++;const c=wire.cdn();const headers:Record<string,string>={"content-length":String(c.declaredLength??c.bytes.length)};if(c.type!==null)headers["content-type"]=c.type;
   return new Response(c.bytes.slice(),{status:200,headers});
  }
  throw new Error("Closed rehearsal transport refused "+req.method+" "+u.hostname+u.pathname);
 })as typeof fetch;
 try{return await action();}finally{globalThis.fetch=previous;}
}

// ---- ai-video routedStatus, compiled from index.ts (the real journal + persist) ----
const INDEX_SOURCE=await Deno.readTextFile(new URL("../ai-video/index.ts",import.meta.url));
const rsStart=INDEX_SOURCE.indexOf("async function routedStatus("),rsEnd=INDEX_SOURCE.indexOf("\n}\n",rsStart);
assert(rsStart>0&&rsEnd>rsStart,"actual routedStatus");
export const ROUTED_STATUS_SOURCE=INDEX_SOURCE.slice(rsStart,rsEnd+3);
export type RoutedStatus=(org:string,job:unknown)=>Promise<Response>;
export async function compileRoutedStatus(body:string=ROUTED_STATUS_SOURCE):Promise<{make:(deps:unknown)=>RoutedStatus}>{
 return await import(enc(`
 import{json,HttpError}from ${href("../_shared/http.ts")};
 import{createRoutedOutput}from ${href("../ai-video/routed-output.ts")};
 import{asHttpError}from ${href("../_shared/providers/chain.ts")};
 export function make(deps:any){const adminClient=()=>deps.admin,adapterFor=(provider:string)=>deps.adapter(provider),headObject=deps.head,persistResult=deps.persist,privateMediaUrl=(scope:any,seconds:number)=>deps.sign(scope,seconds),R2_BUCKET_RENDERS=deps.bucket,uncheckedDriftBlock=()=>({status:"unchecked",publishable:false});
 ${body}
 return routedStatus;}
 // routed variant ${crypto.randomUUID()}
`))as {make:(deps:unknown)=>RoutedStatus};
}
export type JournalRow={org_id:string;user_id:string;listing_id:string;bucket:string;storage_key:string;bytes:number};
/** The accepted payment (app_video_cost_reservations) of the receipt, as routedStatus reads it. */
export type PaymentRow={provider_request_id:string|null;cost_ledger_id:string|null;settled_at:string|null;released_at:string|null};
/** Settled once at acceptance: the normal state of a paid receipt. */
export const SETTLED_PAYMENT:PaymentRow={provider_request_id:TASK_ID,cost_ledger_id:"a0000000-0000-4000-8000-0000000000da",settled_at:"2026-10-17T00:00:01.000Z",released_at:null};
/** Accepted, but app_video_cost_settle failed after acceptance: the priced hold is retained, nothing is booked yet. */
export const HELD_PAYMENT:PaymentRow={provider_request_id:null,cost_ledger_id:null,settled_at:null,released_at:null};
/** rows: what the read answers (an Error answers {error}); throws: the read itself throws (transport). */
export interface PaymentDouble{rows:PaymentRow[]|Error;throws?:boolean;reads:{columns:string;filters:Record<string,unknown>;limit:number}[]}
export const payment=(rows:PaymentRow[]|Error=[SETTLED_PAYMENT],throws=false):PaymentDouble=>({rows,throws,reads:[]});
export function journalAdmin(rows:Map<string,JournalRow>,paid:PaymentDouble=payment()){
 return{
  from:(table:string)=>{
   if(table==="app_video_cost_reservations"){
    // Records the exact lookup identity; answers the configured rows (or a read error).
    const read={columns:"",filters:{} as Record<string,unknown>,limit:0};
    // deno-lint-ignore no-explicit-any
    const q:any={select:(columns:string)=>{read.columns=columns;return q;},eq:(k:string,v:unknown)=>{assert(!(k in read.filters),"one filter per column");read.filters[k]=v;return q;},
     limit:async(n:number)=>{read.limit=n;paid.reads.push(read);if(paid.throws)throw new TypeError("payment read transport failure");
      return paid.rows instanceof Error?{data:null,error:{message:paid.rows.message}}:{data:paid.rows.slice(0,n),error:null};}};
    return q;
   }
   assertEquals(table,"private_ai_outputs");let keys:string[]=[];
   // deno-lint-ignore no-explicit-any
   const q:any={select:()=>q,eq:()=>q,is:()=>q,in:(_k:string,v:string[])=>{keys=v;return q;},limit:async()=>({error:null,data:[...rows.values()].filter(r=>keys.includes(r.storage_key))})};return q;},
  rpc:async(name:string,args:Record<string,unknown>)=>{assertEquals(name,"register_private_ai_output");const key=String(args.p_key),prior=rows.get(key);
   if(prior&&prior.bytes!==args.p_bytes)return{data:null,error:{message:"immutable identity conflict"}};
   if(!prior)rows.set(key,{org_id:ORG,user_id:USER,listing_id:LISTING,bucket:"renders",storage_key:key,bytes:Number(args.p_bytes)});return{data:{ok:true,key},error:null};},
 };
}
// o/usr/a: the owner and admission key every new receipt is signed with (ctxFor's request_key).
export const JOBS={
 kie:{p:"kie",m:KIE_PROPERTY_MODEL,i:TASK_ID,u:KIE_RECORD_URL,o:ORG,usr:USER,l:LISTING,a:"same-operation",k:"video.reel_clip",t:"2026-10-17T00:00:00.000Z"},
 fal:{p:"fal",m:"fal-ai/kling-video/v3/4k/image-to-video",i:TASK_ID,u:"https://queue.fal.run/fixture",o:ORG,usr:USER,l:LISTING,a:"same-operation",k:"video.reel_clip",t:"2026-10-17T00:00:00.000Z"},
};

// ---- the worker: poll, quality and action compiled from engine.ts ----
const ENGINE=await Deno.readTextFile(new URL("./engine.ts",import.meta.url));
const pollStart=ENGINE.indexOf("export type PropertyVideoPollPhase="),pollEnd=ENGINE.indexOf("\nexport async function quality(",pollStart);
const qualityEnd=ENGINE.indexOf("\nasync function media(",pollEnd);
assert(pollStart>0&&pollEnd>pollStart&&qualityEnd>pollEnd,"actual worker entry points");
export const ACTUAL_POLL=ENGINE.slice(pollStart,pollEnd);
export const ACTUAL_QUALITY=ENGINE.slice(pollEnd,qualityEnd);
export const ACTUAL_ACTION=ENGINE.slice(qualityEnd);
export interface WorkerState{
 events:string[];methods:string[];rpcs:{name:string;args:Record<string,unknown>}[];fail:{code:string;ambiguous:boolean}[];diagnostics:unknown[];
 status:(path:string)=>Promise<{status:number;value:unknown}>;
 drift?:(body:unknown)=>Promise<{status:number;value:unknown}>;
 row:()=>unknown;paid:unknown;
 /** adminClient table reads the action path makes (narration/music/preparations); default none. */
 tables?:Record<string,unknown>;
}
// deno-lint-ignore no-explicit-any
let workerState:any;
(globalThis as any).__kieRehearsalWorker=()=>workerState;
const PREFIX=`
import{HttpError,assert}from ${href("../_shared/http.ts")};
import{KIE_PROPERTY_PROFILE,kieProperty4KFacts}from ${href("../_shared/property-video-kie.ts")};
import{R2_BUCKET_RENDERS,headObject as realHeadObject}from ${href("../_shared/r2.ts")};
import{presignGet as realPresignGet}from ${href("../_shared/providers/common.ts")};
import{probeRetainedProviderMP4Video as realProbe}from ${href("../ai-video/mp4video.ts")};
import{bytesFrom as realBytesFrom,base64,bucket}from ${href("../property-video-jobs/runtime.ts")};
import{driftLineageKey}from ${href("../_shared/drift.ts")};
const PROPERTY_VIDEO_STEADY_PROFILE=${JSON.stringify(PROPERTY_VIDEO_STEADY_PROFILE)};
const seconds=(n)=>new Date(Date.now()+n*1000).toISOString();
const f=()=>globalThis.__kieRehearsalWorker();
// The REAL storage/probe/read functions, instrumented only to record the step order.
const headObject=async(...a)=>{f().events.push('head');return await realHeadObject(...a);};
const presignGet=async(...a)=>{f().events.push('sign');return await realPresignGet(...a);};
const probeRetainedProviderMP4Video=async(...a)=>{f().events.push('probe');return await realProbe(...a);};
const bytesFrom=async(...a)=>{f().events.push('bytes');return await realBytesFrom(...a);};
const callAI=async(_ctx,method,path,body)=>{f().methods.push(method+' '+path.split('?')[0]);if(method==='GET'){f().events.push('status');return await f().status(path);}if(path==='drift'&&f().drift){f().events.push('drift');return await f().drift(body);}throw Error('No supplier POST permitted: '+method+' '+path);};
const adminClient=()=>({from:table=>{const q={select:()=>q,eq:()=>q,maybeSingle:async()=>{f().events.push(table);if(table==='private_ai_outputs')return{error:null,data:f().row()};if(table==='app_video_cost_reservations')return{error:null,data:f().paid};return{error:null,data:(f().tables??{})[table]??null};}};return q;}});
const scope=async(..._args)=>{f().events.push('scope');};
const rpc=async(name,args)=>{f().rpcs.push({name,args});if(name==='property_video_job_provenance')return{id:'owned-generation'};return true;};
const fail=async(_ctx,code,ambiguous=false)=>{f().fail.push({code,ambiguous});};
`;
export type Worker={poll:(ctx:unknown)=>Promise<void>;quality:(ctx:unknown,raw:unknown)=>Promise<void>;action:(ctx:unknown)=>Promise<Record<string,unknown>>};
let instances=0;
export async function compileWorker(poll:string=ACTUAL_POLL,quality:string=ACTUAL_QUALITY,action:string=ACTUAL_ACTION):Promise<Worker>{
 return await import("data:application/typescript,"+encodeURIComponent(PREFIX+poll+quality+action+`\n// cold instance ${instances++}`)) as Worker;
}
export async function runWorker<T>(state:Omit<WorkerState,"events"|"methods"|"rpcs"|"fail"|"diagnostics">,work:(s:WorkerState)=>Promise<T>):Promise<{result:T;s:WorkerState}>{
 workerState={events:[],methods:[],rpcs:[],fail:[],diagnostics:[],...state};
 const oldWarn=console.warn,oldError=console.error;console.warn=(text:string)=>{try{workerState.diagnostics.push(JSON.parse(text));}catch{workerState.diagnostics.push({raw:String(text)});}};console.error=()=>{};
 try{return{result:await work(workerState),s:workerState};}finally{console.warn=oldWarn;console.error=oldError;}
}
export const KIE_4K_FACTS_FROM_PROBE="actual probe";
export const ctxFor=(profile:string|undefined,aspect:"16:9"|"9:16",motion="push_in",extra:Record<string,unknown>={})=>({job:{id:JOB_ID,actor_id:USER,org_id:ORG,library_org_id:ORG,listing_id:LISTING,quality_profile:profile,quality_identity:profile===KIE_PROPERTY_PROFILE?KIE_PROPERTY_IDENTITY:null,manifest:{aspect,purpose:"listing",presentation:{transition:"cut"}},manifest_sha256:"a".repeat(64),compose_lease:COMPOSE_LEASE,output_asset_id:"80000000-0000-4000-8000-0000000000d8",poster_asset_id:"90000000-0000-4000-8000-0000000000d9",source_count:1,...extra},
 source:{attempt_id:ATTEMPT,lease_token:LEASE,request_key:"same-operation",asset_id:"same-source",source:{bucket:"uploads",storage_key:`uploads/${ORG}/${LISTING}/source.jpg`,bytes:0,etag:"",content_type:"image/jpeg",sha256:undefined as string|undefined},photo_provenance_id:null,motion,receipt:{request_id:TASK_ID,status_url:"https://private-receipt.invalid/status?job=SIGNED"}}});
/** A tiny owned source photo in the uploads bucket (bytes are hashed, never decoded here). */
export async function seedSourcePhoto(ctx:ReturnType<typeof ctxFor>):Promise<void>{
 const bytes=new TextEncoder().encode("synthetic-source-photo-bytes-not-a-real-jpeg");
 const stored=putStored(r2Path(r2.R2_BUCKET_UPLOADS,ctx.source.source.storage_key),bytes,"image/jpeg");
 ctx.source.source.bytes=bytes.length;ctx.source.source.etag=stored.etag;
}
export const decision=(s:WorkerState)=>({fail:s.fail,rpcs:s.rpcs.map(r=>r.name),events:s.events,methods:s.methods,diagnostics:s.diagnostics});
export function terminalOnce(s:WorkerState,label:string,code="source_video_unverifiable"){
 assertEquals(s.fail,[{code,ambiguous:false}],label);assertEquals(s.rpcs,[],label+": no poll release, no commit");
 assert(!s.events.includes("bytes"),label+": refused clip bytes are never read");assertEquals(s.diagnostics.filter((d:any)=>d.phase!=="mp4_probe"),[],label);
}
export function released(s:WorkerState,label:string,phase:string){
 assertEquals(s.fail,[],label);assertEquals(s.rpcs.map(r=>r.name),["property_video_job_poll_release"],label);assertEquals(s.diagnostics.map((d:any)=>d.phase),[phase],label);
}
export function committed(s:WorkerState,label:string){
 assertEquals(s.fail,[],label);assertEquals(s.diagnostics,[],label);
 assertEquals(s.rpcs.map(r=>r.name),["property_video_job_provenance","bind_property_video_source","property_video_job_clip","property_video_job_poll_release"],label);
}
export function restoreKieKey(){if(KIE_KEY_BEFORE===undefined)Deno.env.delete("KIE_API_KEY");else Deno.env.set("KIE_API_KEY",KIE_KEY_BEFORE);}
