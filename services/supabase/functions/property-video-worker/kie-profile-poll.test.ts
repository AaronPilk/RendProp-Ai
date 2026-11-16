// Kie native-4K profile at the ACTUAL worker poll. engine.ts's poll is compiled
// with closed RPC/storage/probe/ai-video boundaries (the poll.test.ts harness);
// the profile constants and kieProperty4KFacts are the real shared modules.
// Every Kie guard below has a compiled defect control: the same oracle is run
// against engine.ts with that guard removed and must fail.
import{assert,assertEquals,assertThrows}from'https://deno.land/std@0.224.0/assert/mod.ts';
import{PROPERTY_VIDEO_QUALITY_PROFILE,PROPERTY_VIDEO_STEADY_PROFILE}from'../ai-video/property-video-quality.ts';
import{KIE_PROPERTY_PROFILE}from'../_shared/property-video-kie.ts';

const href=(path:string)=>JSON.stringify(new URL(path,import.meta.url).href);
const engine=await Deno.readTextFile(new URL('./engine.ts',import.meta.url));
const start=engine.indexOf('export type PropertyVideoPollPhase='),end=engine.indexOf('\nexport async function quality(',start);
assert(start>0&&end>start,'actual poll entry point');
const actual=engine.slice(start,end);
let state:any;
(globalThis as any).__kiePollFixture=()=>state;
const prefix=`
import{HttpError,assert}from ${href('../_shared/http.ts')};
import{KIE_PROPERTY_PROFILE,kieProperty4KFacts}from ${href('../_shared/property-video-kie.ts')};
const PROPERTY_VIDEO_STEADY_PROFILE=${JSON.stringify(PROPERTY_VIDEO_STEADY_PROFILE)};
const f=()=>globalThis.__kiePollFixture();
const R2_BUCKET_RENDERS='closed-renders';
const callAI=async(_ctx,method,path)=>{f().methods.push(method);if(method!=='GET')throw Error('No supplier POST permitted');f().events.push('status');return{status:f().response.status,value:f().observe(f().response.value)};};
const adminClient=()=>({from:table=>{const q={select:()=>q,eq:()=>q,maybeSingle:async()=>{f().events.push(table);return table==='private_ai_outputs'?{error:null,data:{storage_key:'owned-clip',bytes:100}}:{error:null,data:{provider_request_id:'accepted-request',model:'kling-3.0/video'}};}};return q;}});
const headObject=async()=>{f().events.push('head');return{exists:true,bytes:100,etag:'"immutable"',contentType:'video/mp4'};};
const presignGet=async()=>{f().events.push('sign');return'https://closed-signed.invalid/owned-clip';};
const probeRetainedProviderMP4Video=async()=>{f().events.push('probe');return f().facts;};
const bytesFrom=async()=>{f().events.push('bytes');return{bytes:new Uint8Array([1,2,3]),sha256:'exact-hash'};};
const base64=()=> 'AQID',driftLineageKey=async()=> 'exact-lineage';
const scope=async()=>{f().events.push('scope');};
const rpc=async(name,args)=>{f().rpcs.push({name,args});if(name==='property_video_job_provenance')return{id:'owned-generation'};return true;};
const fail=async(_ctx,code,ambiguous=false)=>{f().fail.push({code,ambiguous});};
`;
// A fresh module per compile: a cold worker instance with no warm state.
let instances=0;
const compile=async(slice:string)=>await import('data:application/typescript,'+encodeURIComponent(prefix+slice+`\n// cold instance ${instances++}`));
const exactlyOnce=(text:string)=>{assertEquals(actual.split(text).length,2,'exact actual guard text: '+text);return text;};
const real=await compile(actual);

type Aspect='16:9'|'9:16';
type Facts={width:number;height:number;fps:number;duration_s:number};
const completed={status:'completed',persisted:true,asset_key:'owned-clip'};
const ctx=(profile:string|undefined,aspect:Aspect)=>({job:{id:'owned-job',actor_id:'owned-actor',org_id:'owned-org',library_org_id:'selected-library',listing_id:'owned-listing',quality_profile:profile,manifest:{aspect}},source:{attempt_id:'attempt',lease_token:'lease',request_key:'same-operation',asset_id:'same-source',source:{},photo_provenance_id:null,receipt:{request_id:'accepted-request',status_url:'https://private-receipt.invalid/status?job=SIGNED'}}});
async function run(module:any,profile:string|undefined,aspect:Aspect,facts:Facts,value:unknown=completed,status=200){
 const reads=new Set<string>();
 state={response:{status,value},facts,methods:[],events:[],rpcs:[],fail:[],diagnostics:[],reads,
  // Records every top-level read of the ai-video status body (provider echo included).
  observe:(v:any)=>v&&typeof v==='object'?new Proxy(v,{get:(t,k,r)=>{if(typeof k==='string')reads.add(k);return Reflect.get(t,k,r);}}):v};
 const old=console.warn;console.warn=(text:string)=>state.diagnostics.push(JSON.parse(text));
 try{await module.poll(ctx(profile,aspect));}finally{console.warn=old;}
 return state;
}
/** Everything a poll is allowed to change: failure code, RPCs, committed clip, supplier calls. */
const decision=(s:any)=>({fail:s.fail,rpcs:s.rpcs.map((r:any)=>r.name),clip:s.rpcs.find((r:any)=>r.name==='property_video_job_clip')?.args.p_clip??null,methods:s.methods,clipBytesRead:s.events.includes('bytes')});
/** Terminal deterministic refusal: no clip read/commit, no provenance, no release, no second supplier call. */
function refusedUnverifiable(s:any){
 assertEquals(s.fail,[{code:'source_video_unverifiable',ambiguous:false}]);assertEquals(s.rpcs,[]);assertEquals(s.methods,['GET']);
 assert(s.events.includes('probe'),'decided from the actual probe');assert(!s.events.includes('bytes'),'refused clip bytes are never read');assertEquals(s.diagnostics,[]);
}
function committedActual(s:any,facts:Facts){
 assertEquals(s.fail,[]);assertEquals(s.methods,['GET']);assertEquals(s.diagnostics,[]);
 assertEquals(s.rpcs.map((r:any)=>r.name),['property_video_job_provenance','bind_property_video_source','property_video_job_clip','property_video_job_poll_release']);
 const clip=s.rpcs[2].args.p_clip;assertEquals([clip.width,clip.height,clip.duration_s,clip.sha256],[facts.width,facts.height,facts.duration_s,'exact-hash']);
}

// The owner-required actual-fact floor: short side >=2160 AND >=8,000,000 pixels.
// Source-auto aspect stays unchanged; provider4K labels cannot replace actual pixels.
const KIE_4K:Array<{label:string;aspect:Aspect;facts:Facts}>=[
 // FAL-derived 4K geometry fixture: no retained Kie MP4 exists, so this is not a Kie output fact.
 {label:'FAL-derived 4K geometry fixture 2492x3324 @24, 121 frames',aspect:'9:16',facts:{width:2492,height:3324,fps:24,duration_s:121/24}},
 {label:'UHD 3840x2160 @24, 120 frames',aspect:'16:9',facts:{width:3840,height:2160,fps:24,duration_s:120/24}},
 {label:'UHD3840x2160 @24,121frames in a portrait job',aspect:'9:16',facts:{width:3840,height:2160,fps:24,duration_s:121/24}},
 {label:'portraitUHD2160x3840 @24,120frames in a landscape job',aspect:'16:9',facts:{width:2160,height:3840,fps:24,duration_s:120/24}},
 {label:'portraitUHD2160x3840 @24,121frames in a portrait job',aspect:'9:16',facts:{width:2160,height:3840,fps:24,duration_s:121/24}},
];
const SUBSTITUTED:Array<{label:string;aspect:Aspect;facts:Facts}>=[
 {label:'Pro-tier 1244x1660 @24',aspect:'9:16',facts:{width:1244,height:1660,fps:24,duration_s:121/24}},
 {label:'Pro-tier 1920x1080 @24',aspect:'16:9',facts:{width:1920,height:1080,fps:24,duration_s:120/24}},
 {label:'4K geometry at 30 fps',aspect:'9:16',facts:{width:2492,height:3324,fps:30,duration_s:150/30}},
 {label:'4K geometry @24 with 100 frames',aspect:'9:16',facts:{width:2492,height:3324,fps:24,duration_s:100/24}},
 {label:'8.1 MP but short side 1000 (8100x1000) @24',aspect:'16:9',facts:{width:8100,height:1000,fps:24,duration_s:120/24}},
];
// Each of these passes the generic 1080 canvas check, so only the Kie rule refuses it.
const NEAR_MISSES:Array<{label:string;aspect:Aspect;facts:Facts}>=[
 {label:'wide source-auto 4068x2032 @24 in a landscape job',aspect:'16:9',facts:{width:4068,height:2032,fps:24,duration_s:120/24}},
 {label:'wide source-auto 4068x2032 @24 in a portrait job',aspect:'9:16',facts:{width:4068,height:2032,fps:24,duration_s:121/24}},
 {label:'tall source-auto 1952x4236 @24 in a portrait job',aspect:'9:16',facts:{width:1952,height:4236,fps:24,duration_s:121/24}},
 {label:'tall source-auto 1952x4236 @24 in a landscape job',aspect:'16:9',facts:{width:1952,height:4236,fps:24,duration_s:120/24}},
 {label:'wide8192x1080 above8MP but shortside1080',aspect:'16:9',facts:{width:8192,height:1080,fps:24,duration_s:120/24}},
 {label:'tall1080x8192 above8MP but shortside1080',aspect:'9:16',facts:{width:1080,height:8192,fps:24,duration_s:121/24}},
 {label:'2159x4000 below2160 despite8MP',aspect:'16:9',facts:{width:2159,height:4000,fps:24,duration_s:120/24}},
 {label:'Pro-tier 1080x1920 @24',aspect:'9:16',facts:{width:1080,height:1920,fps:24,duration_s:120/24}},
 {label:'Pro-tier 1920x1080 @24 in a portrait job',aspect:'9:16',facts:{width:1920,height:1080,fps:24,duration_s:120/24}},
 {label:'4K geometry @24 with 119 frames',aspect:'9:16',facts:{width:2160,height:3840,fps:24,duration_s:119/24}},
 {label:'4K geometry @24 with 122 frames',aspect:'9:16',facts:{width:2160,height:3840,fps:24,duration_s:122/24}},
 {label:'2160 short side but under 8 MP',aspect:'9:16',facts:{width:2160,height:3600,fps:24,duration_s:120/24}},
 {label:'square 2800x2800 = 7.84 MP',aspect:'16:9',facts:{width:2800,height:2800,fps:24,duration_s:120/24}},
 {label:'non-finite probed cadence',aspect:'9:16',facts:{width:2492,height:3324,fps:Number.NaN,duration_s:120/24}},
];
const KIE_GUARD=exactlyOnce("if(kie&&!kieProperty4KFacts(facts)){await fail(ctx,'source_video_unverifiable');return;}");

Deno.test('Kie poll commits only actual native-4K CFR24 120/121-frame clips; a substituted Pro-tier clip is terminal unverifiable with no commit or paid call',async()=>{
 for(const c of KIE_4K)committedActual(await run(real,KIE_PROPERTY_PROFILE,c.aspect,c.facts),c.facts);
 for(const c of[...SUBSTITUTED,...NEAR_MISSES]){const s=await run(real,KIE_PROPERTY_PROFILE,c.aspect,c.facts);try{refusedUnverifiable(s);}catch(error){throw new Error(c.label+': '+(error as Error).message);}}
 // Defect control: the same oracle fails on engine.ts compiled without the Kie guard
 // (Pro-tier clips either commit or degrade to the generic below-1080 code).
 const unguarded=await compile(actual.replace(KIE_GUARD,''));
 for(const c of[...SUBSTITUTED,...NEAR_MISSES]){const s=await run(unguarded,KIE_PROPERTY_PROFILE,c.aspect,c.facts);assertThrows(()=>refusedUnverifiable(s),Error,undefined,'control must expose '+c.label);}
 const committed=await run(unguarded,KIE_PROPERTY_PROFILE,'16:9',SUBSTITUTED[1].facts);assert(committed.rpcs.some((r:any)=>r.name==='property_video_job_clip'),'without the guard a 1080p Pro clip is committed as a 4K Kie clip');
});

const ECHOES:Record<string,Record<string,unknown>>={
 none:{},
 claims_native_4k:{provider:'kie',model:'kling-3.0/video',video_url:'https://tempfile.kie.invalid/claimed-4k.mp4',mode:'4K',resolution:'4K',width:3840,height:2160,fps:24,frames:121,duration:'5',duration_s:5,meta:{substituted:false,requested:{duration:'5',resolution:'4K'},returned:{duration:'5',resolution:'4K'}}},
 admits_downgrade:{provider:'kie',model:'kling-3.0/video',mode:'pro',resolution:'1080p',width:1080,height:1920,fps:30,frames:150,duration:'5',meta:{substituted:true,requested:{duration:'5',resolution:'4K'},returned:{duration:'5',resolution:'1080p'}}},
 malformed:{mode:null,resolution:'',width:'4K',fps:'24',meta:'not-an-object',drift:{action:'accept',publishable:true}},
};
const STATUS_FIELDS=new Set(['status','persisted','asset_key','delivery_issue']);

Deno.test('cold-start Kie poll decides from probed facts alone: identical results under any provider echo, and echo fields are never read',async()=>{
 for(const c of[...KIE_4K,...SUBSTITUTED]){
  const baseline=decision(await run(await compile(actual),KIE_PROPERTY_PROFILE,c.aspect,c.facts));
  for(const[name,echo]of Object.entries(ECHOES)){
   const s=await run(await compile(actual),KIE_PROPERTY_PROFILE,c.aspect,c.facts,{...completed,...echo});
   assertEquals(decision(s),baseline,`${c.label} with ${name} echo`);
   assert([...s.reads].every(k=>STATUS_FIELDS.has(k)),`${c.label}: poll read ${[...s.reads].join(',')}`);
   for(const key of Object.keys(echo))assert(!s.reads.has(key),`${c.label}: provider echo field ${key} was read`);
  }
 }
 // Defect control: a poll that lets the echo vouch for 4K commits a Pro clip and reads the echo.
 const trusting=await compile(actual.replace(KIE_GUARD,KIE_GUARD.replace('!kieProperty4KFacts(facts)',"!(out.value.mode==='4K'||kieProperty4KFacts(facts))")));
 const pro=SUBSTITUTED[1],baseline=decision(await run(real,KIE_PROPERTY_PROFILE,pro.aspect,pro.facts));
 const s=await run(trusting,KIE_PROPERTY_PROFILE,pro.aspect,pro.facts,{...completed,...ECHOES.claims_native_4k});
 assertThrows(()=>assertEquals(decision(s),baseline),Error,undefined,'control: echo-trusting decision differs');
 assert(s.reads.has('mode'),'control: echo-trusting poll is caught reading the echo');
});

Deno.test('a lying echo (claims 4K, no substitution flag) never vouches for a Pro-class clip: only the probed facts decide',async()=>{
 // What the adapter now reports for a truthful-looking property echo: the 4K ask, a 4K echo, nothing substituted.
 const lying={...completed,provider:'kie',model:'kling-3.0/video',mode:'4K',resolution:'4K',meta:{requested:{duration:'5',resolution:'4K'},returned:{duration:'5',resolution:'4k'}}};
 for(const c of SUBSTITUTED){const s=await run(real,KIE_PROPERTY_PROFILE,c.aspect,c.facts,lying);try{refusedUnverifiable(s);}catch(error){throw new Error(c.label+': '+(error as Error).message);}assert(!s.reads.has('meta')&&!s.reads.has('resolution'));}
 for(const c of KIE_4K)committedActual(await run(real,KIE_PROPERTY_PROFILE,c.aspect,c.facts,lying),c.facts);
});

// Executable statement of the pre-Kie (base 462e4c8) poll rule for legacy and FAL jobs.
function preKieRule(profile:string|undefined,aspect:Aspect,facts:Facts){
 const[w,h]=aspect==='16:9'?[1920,1080]:[1080,1920];
 if(profile===PROPERTY_VIDEO_STEADY_PROFILE&&(facts.fps!==24||![120,121].includes(Math.round(facts.duration_s*24))))return'source_video_unverifiable';
 if(facts.width<w||facts.height<h||Math.abs(facts.duration_s-5)>.1)return'source_quality_below_1080';
 return'commit';
}
const FAL_PROFILES=[undefined,'legacy',PROPERTY_VIDEO_QUALITY_PROFILE,PROPERTY_VIDEO_STEADY_PROFILE];
const MATRIX:Facts[]=[...KIE_4K,...SUBSTITUTED,...NEAR_MISSES].map(c=>c.facts).concat([{width:1080,height:1920,fps:30,duration_s:5},{width:1920,height:1080,fps:30,duration_s:5},{width:2160,height:3840,fps:24,duration_s:5},{width:1080,height:1920,fps:24,duration_s:5.2}]);
async function matrixMatchesPreKieRule(module:any){
 for(const profile of FAL_PROFILES)for(const aspect of['16:9','9:16']as const)for(const facts of MATRIX){
  const expected=preKieRule(profile,aspect,facts),s=await run(module,profile,aspect,facts),label=`${profile}/${aspect}/${JSON.stringify(facts)}`;
  if(expected==='commit')committedActual(s,facts);else{assertEquals(s.fail,[{code:expected,ambiguous:false}],label);assertEquals(s.rpcs,[],label);assertEquals(s.methods,['GET'],label);}
 }
}
Deno.test('legacy, FAL v1 and FAL steady-v2 polls keep the exact pre-Kie decision for every probed shape',async()=>{
 await matrixMatchesPreKieRule(real);
 // Defect control: applying the Kie rule beyond the saved Kie profile changes historical FAL/legacy outcomes.
 const broad=await compile(actual.replace(exactlyOnce('kie=j.quality_profile===KIE_PROPERTY_PROFILE;'),'kie=true;'));
 let caught=false;try{await matrixMatchesPreKieRule(broad);}catch{caught=true;}
 assert(caught,'control: an over-broad Kie gate is detected by the historical matrix');
});

const DUAL404={phase:'status_and_result_read',provider:'fal',provider_state:'unavailable',provider_status:404,result_status:404,reason:'not_found'};
const READ403=(reason:string)=>({phase:'result_read',provider:'fal',provider_state:'completed',provider_status:403,reason});
const REASONS=['balance_exhausted','account_locked','auth','permission','unknown'];
const processing=(issue:unknown)=>({status:'processing',delivery_issue:issue});
const release={name:'property_video_job_poll_release',args:{p_job:'owned-job',p_lease:'lease',p_attempt:'attempt'}};
/** A saved Kie job only ever releases its poll lease on a processing response. */
function kieNeverEntersFalRecovery(s:any){assertEquals(s.rpcs,[release]);assertEquals(s.fail,[]);assertEquals(s.methods,['GET']);assertEquals(s.events,['status']);}
const KIE_ISSUES=[DUAL404,{...DUAL404,provider:'kie'},...REASONS.map(READ403),...REASONS.map(r=>({...READ403(r),provider:'kie'}))];

Deno.test('FAL-only paid-result recovery never fires for a saved Kie job, even for a fal-labelled delivery issue; FAL and legacy keep it',async()=>{
 const facts=KIE_4K[0].facts;
 for(const issue of KIE_ISSUES)kieNeverEntersFalRecovery(await run(real,KIE_PROPERTY_PROFILE,'9:16',facts,processing(issue)));
 for(const profile of FAL_PROFILES){
  assertEquals((await run(real,profile,'9:16',facts,processing(DUAL404))).rpcs,[{name:'property_video_job_result_missing',args:release.args}]);
  for(const reason of REASONS)assertEquals((await run(real,profile,'9:16',facts,processing(READ403(reason)))).rpcs,[{name:'property_video_job_result_read_failure',args:{...release.args,p_reason:reason}}]);
 }
 // Defect control: without the saved-Kie exclusion both FAL recovery RPCs fire for a Kie job.
 const guard="if(!kie&&out.status===200&&out.value.status==='processing'";
 assertEquals(actual.split(guard).length,3,'both FAL-only branches carry the saved-Kie exclusion');
 const unguarded=await compile(actual.replaceAll(guard,"if(out.status===200&&out.value.status==='processing'"));
 for(const issue of[DUAL404,READ403('auth')]){const s=await run(unguarded,KIE_PROPERTY_PROFILE,'9:16',facts,processing(issue));assertThrows(()=>kieNeverEntersFalRecovery(s),Error,undefined,'control: FAL recovery fires for Kie');}
});
