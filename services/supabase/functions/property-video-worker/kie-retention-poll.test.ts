// Kie retained-clip stalls, persistence to worker poll. The ACTUAL routedStatus
// (ai-video/index.ts) with its routed-output journal, the REAL persistResult
// (_shared/providers/common.ts), the REAL Kie adapter poll and the REAL r2.ts
// PUT/HEAD signers retain a provider result in an in-memory R2; the ACTUAL worker
// poll (engine.ts) then decides from that same stored object. Only the provider,
// CDN and R2 HTTP edges, the SQL journal and the worker's job RPCs are closed
// doubles: nothing reaches Kie, FAL, R2 or a database. Every new guard has a
// compiled defect control, and FAL/legacy keep the exact pre-G2 decisions (the
// pre-G2 poll and persistResult are compiled from the same files as references).
import{assert,assertEquals,assertRejects}from"https://deno.land/std@0.224.0/assert/mod.ts";
// Synthetic storage identity (never a credential); set before r2.ts/common.ts load.
for(const[k,v]of Object.entries({CLOUDFLARE_ACCOUNT_ID:"kie-retention-fixture",R2_ACCESS_KEY_ID:"synthetic-access",R2_SECRET_ACCESS_KEY:"synthetic-secret"}))Deno.env.set(k,v);
const FIXTURE_KIE_KEY="offline-fixture-kie-retention-key",KIE_KEY_BEFORE=Deno.env.get("KIE_API_KEY");
Deno.env.set("KIE_API_KEY",FIXTURE_KIE_KEY);

const {PROPERTY_VIDEO_QUALITY_PROFILE,PROPERTY_VIDEO_STEADY_PROFILE}=await import("../ai-video/property-video-quality.ts");
const {KIE_PROPERTY_PROFILE}=await import("../_shared/property-video-kie.ts");
const common=await import("../_shared/providers/common.ts");
const r2=await import("../_shared/r2.ts");
const {kieAdapter}=await import("../_shared/providers/kie.ts");
const {HttpError,respondError}=await import("../_shared/http.ts");

const href=(path:string)=>JSON.stringify(new URL(path,import.meta.url).href);
const enc=(s:string)=>{const b=new TextEncoder().encode(s);let out="";for(let i=0;i<b.length;i+=32768)out+=String.fromCharCode(...b.subarray(i,i+32768));return "data:application/typescript;base64,"+btoa(out);};
const once=(text:string,before:string,after:string)=>{assertEquals(text.split(before).length,2,"exact actual text: "+before);return text.replace(before,()=>after);};

// ---- the actual worker poll, compiled with closed job/storage/probe boundaries ----
const ENGINE=await Deno.readTextFile(new URL("./engine.ts",import.meta.url));
const pollStart=ENGINE.indexOf("export type PropertyVideoPollPhase="),pollEnd=ENGINE.indexOf("\nexport async function quality(",pollStart);
assert(pollStart>0&&pollEnd>pollStart,"actual poll entry point");
const ACTUAL_POLL=ENGINE.slice(pollStart,pollEnd);
// deno-lint-ignore no-explicit-any
let state:any;
(globalThis as any).__kieRetentionFixture=()=>state;
const PREFIX=`
import{HttpError,assert}from ${href("../_shared/http.ts")};
import{KIE_PROPERTY_PROFILE,kieProperty4KFacts}from ${href("../_shared/property-video-kie.ts")};
import{R2_BUCKET_RENDERS}from ${href("../_shared/r2.ts")};
const PROPERTY_VIDEO_STEADY_PROFILE=${JSON.stringify(PROPERTY_VIDEO_STEADY_PROFILE)};
const f=()=>globalThis.__kieRetentionFixture();
const callAI=async(_ctx,method,path)=>{f().methods.push(method);if(method!=='GET')throw Error('No supplier POST permitted');f().events.push('status');return await f().status(path);};
const adminClient=()=>({from:table=>{const q={select:()=>q,eq:()=>q,maybeSingle:async()=>{f().events.push(table);return table==='private_ai_outputs'?{error:null,data:f().row()}:{error:null,data:f().paid};}};return q;}});
const headObject=async(bucket,key,signal)=>{f().events.push('head');return await f().head(bucket,key,signal);};
const presignGet=async()=>{f().events.push('sign');return'https://closed-signed.invalid/owned-clip';};
const probeRetainedProviderMP4Video=async()=>{f().events.push('probe');return f().facts;};
// Like runtime.ts bytesFrom: a clip above the bound is refused (413) before any byte.
const bytesFrom=async(source,maximum=8*1024*1024)=>{f().events.push('bytes');if(source.bytes>maximum)throw new HttpError(413,'Saved media exceeds its bounded read.');return{bytes:new Uint8Array([1,2,3]),sha256:'exact-hash'};};
const base64=()=>'AQID',driftLineageKey=async()=>'exact-lineage';
const scope=async()=>{f().events.push('scope');};
const rpc=async(name,args)=>{f().rpcs.push({name,args});if(name==='property_video_job_provenance')return{id:'owned-generation'};return true;};
const fail=async(_ctx,code,ambiguous=false)=>{f().fail.push({code,ambiguous});};
`;
type Poll={poll:(ctx:unknown)=>Promise<void>};
let instances=0;
const compilePoll=async(slice:string)=>await import("data:application/typescript,"+encodeURIComponent(PREFIX+slice+`\n// cold instance ${instances++}`)) as Poll;
// The G2 guard text in engine.ts, and the pre-G2 poll rebuilt from it (executable reference).
const UNREADABLE="const unreadable=kie&&h.exists&&h.bytes===saved.data.bytes&&!!h.etag&&(h.contentType!=='video/mp4'||saved.data.bytes>PROPERTY_VIDEO_CLIP_READ_BYTES);";
const HEAD_ASSERT="assert(unreadable||h.exists&&h.bytes===saved.data.bytes&&h.etag&&h.contentType==='video/mp4',503,'The generated clip bytes could not be verified.');";
const TERMINAL="if(unreadable){await fail(ctx,'source_video_unverifiable');return;}";
const PRE_G2_POLL=once(once(once(once(ACTUAL_POLL,UNREADABLE,""),HEAD_ASSERT,HEAD_ASSERT.replace("unreadable||","")),TERMINAL,""),"bytesFrom(clip,PROPERTY_VIDEO_CLIP_READ_BYTES)","bytesFrom(clip,64*1024*1024)");
const actual=await compilePoll(ACTUAL_POLL),preG2=await compilePoll(PRE_G2_POLL);

const ORG="10000000-0000-4000-8000-0000000000c1",USER="20000000-0000-4000-8000-0000000000c2",LISTING="30000000-0000-4000-8000-0000000000c3",RECEIPT_ID="kie-task-retained";
// A FAL-derived 4K geometry fixture: no retained Kie MP4 exists, so these are not Kie output facts.
const KIE_4K={width:2492,height:3324,fps:24,duration_s:121/24};
const ctx=(profile:string|undefined)=>({job:{id:"owned-job",actor_id:USER,org_id:ORG,library_org_id:ORG,listing_id:LISTING,quality_profile:profile,manifest:{aspect:"9:16"}},
 source:{attempt_id:"attempt",lease_token:"lease",request_key:"same-operation",asset_id:"same-source",source:{},photo_provenance_id:null,receipt:{request_id:RECEIPT_ID,status_url:"https://private-receipt.invalid/status?job=SIGNED"}}});
type Head={exists:boolean;bytes:number|null;etag:string|null;contentType:string|null};
type Fixture={status:(path:string)=>Promise<{status:number;value:unknown}>;row:()=>unknown;head:(bucket:string,key:string,signal?:AbortSignal)=>Promise<Head>;paid?:unknown};
async function poll(module:Poll,profile:string|undefined,fixture:Fixture){
 state={methods:[],events:[],rpcs:[],fail:[],diagnostics:[],facts:KIE_4K,paid:{provider_request_id:RECEIPT_ID,model:"kling-3.0/video"},...fixture};
 const old=console.warn;console.warn=(text:string)=>{try{state.diagnostics.push(JSON.parse(text));}catch{state.diagnostics.push({raw:String(text)});}};
 try{await module.poll(ctx(profile));}finally{console.warn=old;}
 return state;
}
// deno-lint-ignore no-explicit-any
const decision=(s:any)=>({fail:s.fail,rpcs:s.rpcs.map((r:{name:string})=>r.name),events:s.events,methods:s.methods,diagnostics:s.diagnostics});
// deno-lint-ignore no-explicit-any
function terminalOnce(s:any,label:string){
 assertEquals(s.fail,[{code:"source_video_unverifiable",ambiguous:false}],label);assertEquals(s.rpcs,[],label+": no poll release, no commit");assertEquals(s.methods,["GET"],label);
 assertEquals(s.events,["status","private_ai_outputs","head","app_video_cost_reservations"],label+": decided from the HEAD after the paid receipt; no capability, probe or byte read");
 assertEquals(s.diagnostics,[],label);
}
// deno-lint-ignore no-explicit-any
function committed(s:any,label:string){
 assertEquals(s.fail,[],label);assertEquals(s.diagnostics,[],label);
 assertEquals(s.rpcs.map((r:{name:string})=>r.name),["property_video_job_provenance","bind_property_video_source","property_video_job_clip","property_video_job_poll_release"],label);
}
// deno-lint-ignore no-explicit-any
function released(s:any,label:string,phase:string){
 assertEquals(s.fail,[],label);assertEquals(s.rpcs.map((r:{name:string})=>r.name),["property_video_job_poll_release"],label);assertEquals(s.diagnostics.map((d:{phase:string})=>d.phase),[phase],label);
}

// ---- engine-level cases: a retained object described by its journal row and HEAD ----
const owned=(bytes:number,head:Head|Error):Fixture=>({status:async()=>({status:200,value:{status:"completed",persisted:true,asset_key:"owned-clip"}}),
 row:()=>({storage_key:"owned-clip",bytes}),head:async()=>{if(head instanceof Error)throw head;return head;}});
const same=(bytes:number,contentType:string|null):Head=>({exists:true,bytes,etag:'"immutable"',contentType});
const MiB=1024*1024,READ_CAP=64*MiB;
/** Deterministic: the object exists unchanged yet can never pass. Kie is terminal once; FAL keeps re-polling. */
const DETERMINISTIC=[
 {label:"stored text/html",fixture:owned(100,same(100,"text/html"))},
 {label:"stored application/octet-stream",fixture:owned(100,same(100,"application/octet-stream"))},
 {label:"stored video/quicktime",fixture:owned(100,same(100,"video/quicktime"))},
 {label:"stored case variant Video/MP4",fixture:owned(100,same(100,"Video/MP4"))},
 {label:"stored video/mp4 with parameters",fixture:owned(100,same(100,"video/mp4; codecs=avc1"))},
 {label:"no stored content type",fixture:owned(100,same(100,null))},
 {label:"70 MB clip",fixture:owned(70_000_000,same(70_000_000,"video/mp4"))},
 {label:"one byte over the 64 MiB read",fixture:owned(READ_CAP+1,same(READ_CAP+1,"video/mp4"))},
 {label:"70 MB clip with a wrong stored type",fixture:owned(70_000_000,same(70_000_000,"text/html"))},
];
/** Transient: missing or changed object, transport errors. Every profile, Kie included, keeps the retry loop. */
const TRANSIENT=[
 {label:"object missing",fixture:owned(100,{exists:false,bytes:null,etag:null,contentType:null})},
 {label:"object missing, journal over the read",fixture:owned(70_000_000,{exists:false,bytes:null,etag:null,contentType:null})},
 {label:"size mismatch with a wrong type",fixture:owned(100,same(101,"text/html"))},
 {label:"size mismatch over the read",fixture:owned(70_000_000,same(70_000_001,"video/mp4"))},
 {label:"no etag with a wrong type",fixture:owned(100,{exists:true,bytes:100,etag:null,contentType:"text/html"})},
 {label:"HEAD transport error",fixture:owned(100,new TypeError("network unavailable"))},
 {label:"R2 HEAD 502",fixture:owned(70_000_000,new HttpError(502,"R2 HEAD failed (503)"))},
];
const READABLE=[
 {label:"exact video/mp4",fixture:owned(100,same(100,"video/mp4"))},
 {label:"exactly the 64 MiB read",fixture:owned(READ_CAP,same(READ_CAP,"video/mp4"))},
];
async function kieDecides(module:Poll){
 for(const c of DETERMINISTIC)terminalOnce(await poll(module,KIE_PROPERTY_PROFILE,c.fixture),c.label);
 for(const c of TRANSIENT){const s=await poll(module,KIE_PROPERTY_PROFILE,c.fixture);released(s,c.label,"clip_head");assert(!s.events.includes("probe")&&!s.events.includes("bytes"),c.label);}
 for(const c of READABLE)committed(await poll(module,KIE_PROPERTY_PROFILE,c.fixture),c.label);
}
const FAL_PROFILES=[undefined,"legacy",PROPERTY_VIDEO_QUALITY_PROFILE,PROPERTY_VIDEO_STEADY_PROFILE];
/** Legacy and FAL polls decide exactly as the pre-G2 poll for every case. */
async function falUnchanged(module:Poll){
 for(const profile of FAL_PROFILES)for(const c of[...DETERMINISTIC,...TRANSIENT,...READABLE])
  assertEquals(decision(await poll(module,profile,c.fixture)),decision(await poll(preG2,profile,c.fixture)),`${profile}: ${c.label}`);
}

Deno.test("Kie poll: a retained object with a wrong stored type or over the 64 MiB read is terminal once, before any byte read; transient failures keep the retry loop",async()=>{
 assertEquals(ENGINE.split("bytesFrom(clip,PROPERTY_VIDEO_CLIP_READ_BYTES)").length,2,"the Kie size rule and the actual clip read share one bound");
 assert(ACTUAL_POLL.includes("export const PROPERTY_VIDEO_CLIP_READ_BYTES=64*1024*1024;"));
 await kieDecides(actual);
 // The paid receipt is still verified first: while its recovery is pending the poll waits (no terminal).
 const pending=await poll(actual,KIE_PROPERTY_PROFILE,{...owned(100,same(100,"text/html")),paid:{provider_request_id:"another-request",model:"kling-3.0/video"}});
 released(pending,"payment recovery pending","paid_receipt");
 // The pre-G2 poll on the same objects: re-polled every tick to the deadline (a 70 MB clip probed and refused at its read each time).
 for(const c of DETERMINISTIC)released(await poll(preG2,KIE_PROPERTY_PROFILE,c.fixture),"pre-G2 stall: "+c.label,/70 MB clip$|over the 64 MiB/.test(c.label)?"clip_bytes":"clip_head");
});

Deno.test("legacy and FAL polls keep the exact pre-G2 decision for every retained-object case",async()=>{
 await falUnchanged(actual);
});

Deno.test("compiled defect controls: each Kie retention guard is load-bearing and Kie-only",async()=>{
 const RULE="(h.contentType!=='video/mp4'||saved.data.bytes>PROPERTY_VIDEO_CLIP_READ_BYTES)";
 // 1. Type rule removed: a wrong stored type loops again.
 const noType=await compilePoll(once(ACTUAL_POLL,RULE,"(saved.data.bytes>PROPERTY_VIDEO_CLIP_READ_BYTES)"));
 released(await poll(noType,KIE_PROPERTY_PROFILE,DETERMINISTIC[0].fixture),"control: type rule removed","clip_head");
 await assertRejects(()=>kieDecides(noType),Error,undefined,"control: type rule");
 // 2. Size rule removed: a 70 MB clip is probed, refused at its read, and loops.
 const noSize=await compilePoll(once(ACTUAL_POLL,RULE,"(h.contentType!=='video/mp4')"));
 const big=await poll(noSize,KIE_PROPERTY_PROFILE,DETERMINISTIC[6].fixture);released(big,"control: size rule removed","clip_bytes");assert(big.events.includes("probe")&&big.events.includes("bytes"));
 await assertRejects(()=>kieDecides(noSize),Error,undefined,"control: size rule");
 // 3. Terminal step removed: the head check no longer stops a wrong type, which would be probed and committed.
 const noTerminal=await compilePoll(once(ACTUAL_POLL,TERMINAL,""));
 committed(await poll(noTerminal,KIE_PROPERTY_PROFILE,DETERMINISTIC[0].fixture),"control: wrong type committed without the terminal step");
 await assertRejects(()=>kieDecides(noTerminal),Error,undefined,"control: terminal step");
 // 4. Gate widened beyond the saved Kie profile: FAL and legacy decisions change.
 const widened=await compilePoll(once(ACTUAL_POLL,"const unreadable=kie&&","const unreadable=true&&"));
 await assertRejects(()=>falUnchanged(widened),Error,undefined,"control: widened gate");
 console.log("KIE_RETENTION_POLL_COMPILED_CONTROLS=4");
});

// ---- persistence: the real persistResult and an in-memory R2 that keeps the PUT content type ----
type Stored={bytes:Uint8Array;type:string|null;etag:string};
let r2Store=new Map<string,Stored>(),etags=0;
let upstream:{type:string|null;bytes:Uint8Array<ArrayBuffer>}={type:"video/mp4",bytes:new Uint8Array(4096)};
let kieRecord:Record<string,unknown>|null=null;
globalThis.fetch=(async(input:RequestInfo|URL,init?:RequestInit)=>{
 const req=new Request(input,init),u=new URL(req.url);
 if(u.hostname.endsWith(".r2.cloudflarestorage.com")){
  const path=decodeURIComponent(u.pathname);
  if(req.method==="PUT"){
   assertEquals(req.headers.get("if-none-match"),"*");if(r2Store.has(path))return new Response(null,{status:412});
   r2Store.set(path,{bytes:new Uint8Array(await req.arrayBuffer()),type:req.headers.get("content-type"),etag:`"fixture-etag-${++etags}"`});return new Response(null,{status:200});
  }
  if(req.method==="HEAD"){
   const o=r2Store.get(path);if(!o)return new Response(null,{status:404});
   const headers:Record<string,string>={"content-length":String(o.bytes.length),etag:o.etag};if(o.type!==null)headers["content-type"]=o.type;
   return new Response(null,{status:200,headers});
  }
 }
 if(u.hostname==="api.kie.ai"&&u.pathname==="/api/v1/jobs/recordInfo"&&req.method==="GET"&&kieRecord){
  assert(req.headers.get("authorization")===`Bearer ${FIXTURE_KIE_KEY}`,"the fixture key authorizes the closed poll");
  return Response.json({code:200,msg:"success",data:kieRecord});
 }
 if(["tempfile.aiquickdraw.com","fal.media","results.fixture.invalid"].includes(u.hostname)&&req.method==="GET"){
  const headers:Record<string,string>={"content-length":String(upstream.bytes.length)};if(upstream.type!==null)headers["content-type"]=upstream.type;
  return new Response(upstream.bytes,{status:200,headers});
 }
 throw new Error("Closed fixture refused "+req.method+" "+u.hostname+u.pathname);
}) as typeof fetch;

// The actual persistResult body, compiled against the real common.ts helpers (controls and pre-G2 reference).
const COMMON_SOURCE=await Deno.readTextFile(new URL("../_shared/providers/common.ts",import.meta.url));
const persistStart=COMMON_SOURCE.indexOf("export async function persistResult("),persistEnd=COMMON_SOURCE.indexOf("\n}\n",persistStart);
assert(persistStart>0&&persistEnd>persistStart,"actual persistResult");
const ACTUAL_PERSIST=COMMON_SOURCE.slice(persistStart,persistEnd+3);
type Persist=typeof common.persistResult;
let persistVariants=0;
async function compilePersist(body:string):Promise<Persist>{
 return (await import(enc(`import{BUDGETS,MAX_PERSIST_BYTES,ProviderError,decodeDataUrl,fetchBounded,putBytes}from ${href("../_shared/providers/common.ts")};
import{R2_BUCKET_RENDERS}from ${href("../_shared/r2.ts")};
type DoneState=any;
${body}
// persist variant ${persistVariants++}`))).persistResult as Persist;
}
const KIE_MIME='  const mime = genericKieMp4 ? "video/mp4" : upstream || state.mime;';
const KIE_GATE='const genericKieMp4 = provider === "kie" && state.mime === "video/mp4" &&';
const compiledActualPersist=await compilePersist(ACTUAL_PERSIST);
const preG2Persist=await compilePersist(once(ACTUAL_PERSIST,KIE_MIME,'  const mime = res.headers.get("content-type")?.split(";")[0].trim() || state.mime;'));

async function storedType(persist:Persist,provider:string,mime:string,type:string|null){
 r2Store=new Map();upstream={type,bytes:new Uint8Array(4096)};
 const key=`ai-router/${ORG}/fixture/${crypto.randomUUID()}.bin`;
 const saved=await persist(provider,{status:"done",result_url:"https://results.fixture.invalid/clip",mime},key,undefined,true);
 assertEquals(saved.bytes,4096);const objects=[...r2Store.values()];assertEquals(objects.length,1);return objects[0].type;
}
const UPSTREAM_TYPES=[null,"","application/octet-stream","binary/octet-stream","APPLICATION/OCTET-STREAM","video/mp4","Video/MP4","video/mp4; codecs=avc1","video/quicktime","text/html","image/png"];
/** What persistResult stores for a Kie result its adapter identified as video/mp4. */
const KIE_MP4_STORED=(type:string|null)=>type===null||["","application/octet-stream","binary/octet-stream","video/mp4"].includes(type.split(";")[0].trim().toLowerCase())?"video/mp4":type;

Deno.test("persistResult: a Kie MP4 labelled generic binary, unlabelled or case-varied is stored as video/mp4; any other upstream type is kept as-is",async()=>{
 const expected:Record<string,string>={null:"video/mp4","":"video/mp4","application/octet-stream":"video/mp4","binary/octet-stream":"video/mp4","APPLICATION/OCTET-STREAM":"video/mp4",
  "video/mp4":"video/mp4","Video/MP4":"video/mp4","video/mp4; codecs=avc1":"video/mp4","video/quicktime":"video/quicktime","text/html":"text/html","image/png":"image/png"};
 for(const type of UPSTREAM_TYPES){
  assertEquals(KIE_MP4_STORED(type),expected[String(type)]);
  for(const persist of[common.persistResult,compiledActualPersist])assertEquals(await storedType(persist,"kie","video/mp4",type),expected[String(type)],String(type));
 }
});

Deno.test("persistResult: every other provider, and a Kie result not identified as MP4, stores exactly the pre-G2 type",async()=>{
 for(const provider of["fal","higgsfield","openai","kie"])for(const mime of["video/mp4","video/quicktime","image/png","Video/MP4"])for(const type of UPSTREAM_TYPES){
  if(provider==="kie"&&mime==="video/mp4")continue;
  const label=`${provider} ${mime} upstream ${type}`;
  assertEquals(await storedType(common.persistResult,provider,mime,type),await storedType(preG2Persist,provider,mime,type),label);
 }
 // Defect control: the Kie gate widened to every provider changes what FAL stores.
 const widened=await compilePersist(once(ACTUAL_PERSIST,KIE_GATE,'const genericKieMp4 = state.mime === "video/mp4" &&'));
 assertEquals(await storedType(widened,"fal","video/mp4","application/octet-stream"),"video/mp4","control: widened gate");
 assertEquals(await storedType(preG2Persist,"fal","video/mp4","application/octet-stream"),"application/octet-stream");
});

Deno.test("the Kie poll names a Kling result video/mp4 (any .mp4/.m4v or extension-less URL); only a .mov names another type",async()=>{
 const ref={provider:"kie",model:"kling-3.0/video",id:RECEIPT_ID,poll_url:`https://api.kie.ai/api/v1/jobs/recordInfo?taskId=${RECEIPT_ID}`,submitted_at:"2026-10-16T00:00:00.000Z"};
 const base="https://tempfile.aiquickdraw.com/kie/fixture-clip";
 for(const[url,mime]of[[base+".mp4","video/mp4"],[base+".mp4?sig=fixture","video/mp4"],[base,"video/mp4"],[base+".MP4","video/mp4"],[base+".m4v","video/mp4"],[base+".mov","video/quicktime"]]){
  kieRecord=kieSuccess(url);const done=await kieAdapter.poll(ref) as unknown as Record<string,unknown>;
  assertEquals([done.status,done.result_url,done.mime],["done",url,mime],url);
 }
 kieRecord=null;
});

// ---- the full chain: ai-video routedStatus persists, the worker poll decides from the stored object ----
const INDEX_SOURCE=await Deno.readTextFile(new URL("../ai-video/index.ts",import.meta.url));
const rsStart=INDEX_SOURCE.indexOf("async function routedStatus("),rsEnd=INDEX_SOURCE.indexOf("\n}\n",rsStart);
assert(rsStart>0&&rsEnd>rsStart,"actual routedStatus");
const routedModule=await import(enc(`
 import{json,HttpError}from ${href("../_shared/http.ts")};
 import{createRoutedOutput}from ${href("../ai-video/routed-output.ts")};
 import{asHttpError}from ${href("../_shared/providers/chain.ts")};
 export function make(deps:any){const adminClient=()=>deps.admin,adapterFor=(provider:string)=>deps.adapter(provider),headObject=deps.head,persistResult=deps.persist,privateMediaUrl=(scope:any,seconds:number)=>deps.sign(scope,seconds),R2_BUCKET_RENDERS=deps.bucket,uncheckedDriftBlock=()=>({status:"unchecked",publishable:false});
 ${INDEX_SOURCE.slice(rsStart,rsEnd+3)}
 return routedStatus;}
`)) as {make:(deps:unknown)=>(org:string,job:unknown)=>Promise<Response>};
type Row={org_id:string;user_id:string;listing_id:string;bucket:string;storage_key:string;bytes:number};
function journalAdmin(rows:Map<string,Row>){
 return{
  from:(table:string)=>{assertEquals(table,"private_ai_outputs");let keys:string[]=[];
   // deno-lint-ignore no-explicit-any
   const q:any={select:()=>q,eq:()=>q,is:()=>q,in:(_k:string,v:string[])=>{keys=v;return q;},limit:async()=>({error:null,data:[...rows.values()].filter(r=>keys.includes(r.storage_key))})};return q;},
  rpc:async(name:string,args:Record<string,unknown>)=>{assertEquals(name,"register_private_ai_output");const key=String(args.p_key),prior=rows.get(key);
   if(prior&&prior.bytes!==args.p_bytes)return{data:null,error:{message:"immutable identity conflict"}};
   if(!prior)rows.set(key,{org_id:ORG,user_id:USER,listing_id:LISTING,bucket:"renders",storage_key:key,bytes:Number(args.p_bytes)});return{data:{ok:true,key},error:null};},
 };
}
const KIE_RESULT="https://tempfile.aiquickdraw.com/kie/fixture-clip.mp4";
function kieSuccess(url:string){return{taskId:RECEIPT_ID,model:"kling-3.0/video",state:"success",param:JSON.stringify({model:"kling-3.0/video",input:{duration:"5",mode:"4K"}}),resultJson:JSON.stringify({resultUrls:[url]}),creditsConsumed:335};}
const JOBS={
 kie:{p:"kie",m:"kling-3.0/video",i:RECEIPT_ID,u:`https://api.kie.ai/api/v1/jobs/recordInfo?taskId=${RECEIPT_ID}`,usr:USER,l:LISTING,k:"video.reel_clip",t:"2026-10-16T00:00:00.000Z"},
 fal:{p:"fal",m:"fal-ai/kling-video/v3/4k/image-to-video",i:RECEIPT_ID,u:"https://queue.fal.run/fixture",usr:USER,l:LISTING,k:"video.reel_clip",t:"2026-10-16T00:00:00.000Z"},
};
const falPoll={poll:async()=>({status:"done",result_url:"https://fal.media/files/fixture-clip.mp4",mime:"video/mp4"})};
async function chain(o:{provider:"kie"|"fal";profile:string|undefined;type:string|null;persist:Persist;engine:Poll;resultUrl?:string}){
 r2Store=new Map();upstream={type:o.type,bytes:new Uint8Array(4096)};kieRecord=o.provider==="kie"?kieSuccess(o.resultUrl??KIE_RESULT):null;
 const journal=new Map<string,Row>();
 const routed=routedModule.make({admin:journalAdmin(journal),adapter:(p:string)=>p==="kie"?kieAdapter:falPoll,head:r2.headObject,bucket:r2.R2_BUCKET_RENDERS,persist:o.persist,
  sign:(scope:{key:string},seconds:number)=>`https://private-media.fixture.invalid/${scope.key}?ttl=${seconds}`});
 const status=async()=>{let r:Response;try{r=await routed(ORG,JOBS[o.provider]);}catch(e){r=respondError(e);}return{status:r.status,value:await r.json()};};
 const row=()=>{const rows=[...journal.values()];return rows.length===1?{storage_key:rows[0].storage_key,bytes:rows[0].bytes}:null;};
 const old=console.error;console.error=()=>{};
 try{
  const s=await poll(o.engine,o.profile,{status,row,head:(bucket,key,signal)=>r2.headObject(bucket,key,signal)});
  const objects=[...r2Store.values()];assertEquals(objects.length,1,"exactly one retained object");
  return{stored:objects[0].type,s};
 }finally{console.error=old;kieRecord=null;}
}
const KIE_MP4_LABELS=[null,"","application/octet-stream","binary/octet-stream","APPLICATION/OCTET-STREAM","Video/MP4","video/mp4; codecs=avc1","video/mp4"];
const KIE_FOREIGN=["text/html","video/quicktime","application/json","image/png"];
async function kieChainCommitsMp4(persist:Persist){
 for(const type of KIE_MP4_LABELS){const r=await chain({provider:"kie",profile:KIE_PROPERTY_PROFILE,type,persist,engine:actual});
  assertEquals(r.stored,"video/mp4",String(type));committed(r.s,"Kie MP4 labelled "+type);}
}

Deno.test("chain: a Kie MP4 labelled octet-stream (or unlabelled, or case-varied) is retained as video/mp4 and the worker poll proceeds to commit",async()=>{
 await kieChainCommitsMp4(common.persistResult);
 // Defect control: persistResult without the Kie normalization keeps the generic label, and the
 // worker (now terminal on a wrong stored type) would refuse a good paid clip.
 const noKie=await compilePersist(once(ACTUAL_PERSIST,KIE_MIME,"  const mime = upstream || state.mime;"));
 const r=await chain({provider:"kie",profile:KIE_PROPERTY_PROFILE,type:"application/octet-stream",persist:noKie,engine:actual});
 assertEquals(r.stored,"application/octet-stream");terminalOnce(r.s,"control: unnormalized Kie MP4");
 await assertRejects(()=>kieChainCommitsMp4(noKie),Error,undefined,"control: normalization");
});

Deno.test("chain: a Kie result stored as text/html, MOV or JSON is terminal once (no poll release), never re-polled to the deadline",async()=>{
 for(const type of KIE_FOREIGN){
  const r=await chain({provider:"kie",profile:KIE_PROPERTY_PROFILE,type,persist:common.persistResult,engine:actual});
  assertEquals(r.stored,type);terminalOnce(r.s,"Kie stored "+type);
  // The pre-G2 poll on the same retained object only released its lease, every tick.
  const old=await chain({provider:"kie",profile:KIE_PROPERTY_PROFILE,type,persist:common.persistResult,engine:preG2});
  released(old.s,"pre-G2 stall: "+type,"clip_head");
 }
 // A .mov result is named video/quicktime by the adapter; whatever its host labels it, it cannot stall.
 for(const type of["application/octet-stream","video/quicktime",null]){
  const r=await chain({provider:"kie",profile:KIE_PROPERTY_PROFILE,type,persist:common.persistResult,engine:actual,resultUrl:"https://tempfile.aiquickdraw.com/kie/fixture-clip.mov"});
  assertEquals(r.stored,type??"video/quicktime");terminalOnce(r.s,"Kie .mov stored "+type);
 }
});

Deno.test("chain: FAL and legacy retain and poll exactly as before (same stored type, same decision as the pre-G2 persist + poll)",async()=>{
 const types=[null,"application/octet-stream","binary/octet-stream","Video/MP4","video/mp4","video/mp4; codecs=avc1","text/html"];
 for(const profile of FAL_PROFILES)for(const type of types){
  const now=await chain({provider:"fal",profile,type,persist:common.persistResult,engine:actual});
  const before=await chain({provider:"fal",profile,type,persist:preG2Persist,engine:preG2});
  assertEquals([now.stored,decision(now.s)],[before.stored,decision(before.s)],`${profile} upstream ${type}`);
 }
 // The FAL octet-stream case still loops exactly as before (the FAL-only behaviour G2 leaves alone).
 const loop=await chain({provider:"fal",profile:PROPERTY_VIDEO_STEADY_PROFILE,type:"application/octet-stream",persist:common.persistResult,engine:actual});
 assertEquals(loop.stored,"application/octet-stream");released(loop.s,"FAL octet-stream","clip_head");
});

// Registered last: the process environment is shared by every test module in one run.
Deno.test("restore the process KIE_API_KEY this module set for its fixtures",()=>{
 if(KIE_KEY_BEFORE===undefined)Deno.env.delete("KIE_API_KEY");else Deno.env.set("KIE_API_KEY",KIE_KEY_BEFORE);
 assertEquals(Deno.env.get("KIE_API_KEY"),KIE_KEY_BEFORE);
});
