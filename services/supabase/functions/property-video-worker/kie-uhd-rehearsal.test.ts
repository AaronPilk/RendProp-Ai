// K2: whole-chain Kie rehearsal with synthetic native-UHD media, offline.
//
//   dispatch (real kieAdapter.submit, closed createTask)
//   -> poll (real routedStatus + routed-output journal + persistResult -> R2 double)
//   -> worker poll (real engine.ts: HEAD gate, presign, probeRetainedProviderMP4Video,
//      kieProperty4KFacts, bytesFrom, lineage, clip commit)
//   -> quality (real engine.ts quality plumbing; the drift judge is a closed verdict)
//   -> compose (real engine.ts action: the exact ComposeAction the CPU renderer
//      receives, bound to the retained object)
//
// The chain STOPS at the ComposeAction: the CPU compose itself is Python
// (services/edge/property-video-render) and is rehearsed with the same native-UHD
// geometry in its tests/test_cpu.py. Nothing here reaches Kie, R2 or a database.
// Media is ffmpeg-made at test time (flat-colour H.264, moov first, exact frame
// counts); when ffmpeg is unavailable the media cases are reported as ignored,
// never as passed.
import{assert,assertEquals,assertMatch}from"https://deno.land/std@0.224.0/assert/mod.ts";
import*as H from"./kie-rehearsal-harness.ts";
// The harness module is shared by every rehearsal file in one run; each file sets and restores the fixture key itself.
Deno.env.set("KIE_API_KEY",H.FIXTURE_KIE_KEY);
const{KIE_PROPERTY_PROFILE,KIE_PROPERTY_IDENTITY,KIE_PROPERTY_MODEL,PROPERTY_VIDEO_STEADY_PROFILE,common,r2,kieAdapter,buildSteadyPropertyReelPrompt,probeRetainedProviderMP4Video,kieProperty4KFacts,kiePropertyPromptPinned}=H;
const ffmpeg=await H.ffmpegAvailable();
const sha=async(bytes:Uint8Array)=>Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",new Uint8Array(bytes))),b=>b.toString(16).padStart(2,"0")).join("");
const OWNED_SOURCE_URL=`https://private-media.fixture.invalid/uploads/${H.ORG}/${H.LISTING}/source.jpg?cap=owned`;
const routedModule=await H.compileRoutedStatus();
const worker=await H.compileWorker();

function wire(resultUrl:string,media:{bytes:Uint8Array;type:string|null;declaredLength?:number}):H.KieWire{
 return{posts:[],polls:0,downloads:0,record:()=>H.kieSuccess(resultUrl),cdn:()=>media};
}
function routedFor(provider:"kie"|"fal",journal:Map<string,H.JournalRow>,falResultUrl="https://fal.media/files/fixture-clip.mp4"){
 const falPoll={poll:async()=>({status:"done",result_url:falResultUrl,mime:"video/mp4"})};
 return routedModule.make({admin:H.journalAdmin(journal),adapter:(p:string)=>p==="kie"?kieAdapter:falPoll,head:r2.headObject,bucket:r2.R2_BUCKET_RENDERS,persist:common.persistResult,
  sign:(scope:{key:string},seconds:number)=>`https://private-media.fixture.invalid/${scope.key}?ttl=${seconds}`});
}
/** One poll tick of the actual worker against the actual routed status. */
async function tick(provider:"kie"|"fal",profile:string|undefined,aspect:"16:9"|"9:16",w:H.KieWire,journal:Map<string,H.JournalRow>,ctx=H.ctxFor(profile,aspect)){
 const routed=routedFor(provider,journal);
 const status=async()=>{let r:Response;try{r=await routed(H.ORG,H.JOBS[provider]);}catch(e){r=H.respondError(e);}return{status:r.status,value:await r.json()};};
 const row=()=>{const rows=[...journal.values()];return rows.length===1?{storage_key:rows[0].storage_key,bytes:rows[0].bytes}:null;};
 return await H.withTransport(w,async()=>await H.runWorker({status,row,paid:{provider_request_id:H.TASK_ID,model:provider==="kie"?KIE_PROPERTY_MODEL:H.JOBS.fal.m}},async()=>{await worker.poll(ctx);}));
}

Deno.test("dispatch: the real adapter sends exactly the closed createTask body for the pinned steady prompt and returns the pinned recordInfo receipt",async()=>{
 const prompt=buildSteadyPropertyReelPrompt("home","push_in","16:9");assert(await kiePropertyPromptPinned(prompt,"push_in"),"the reviewed prompt is pinned");
 const w=wire("unused",{bytes:new Uint8Array(0),type:null});
 const step={provider:"kie",model:KIE_PROPERTY_MODEL,task:"video.property_reel_clip_kie",unit:"second",unit_cents:33.5,params:{kie_mode:"4K",sound:false}} as unknown as Parameters<typeof kieAdapter.submit>[0];
 const input={task:"video.reel_clip",prompt,image_url:OWNED_SOURCE_URL,seconds:5,aspect:"16:9" as const,framing:"preserve_photo" as const,resolution:"1080p" as const,extra:{kie_mode:"4K",sound:false,property_video_target_aspect:"16:9",property_video_quality_profile:KIE_PROPERTY_PROFILE}};
 const ref=await H.withTransport(w,()=>kieAdapter.submit(step,input));
 assertEquals(w.posts,[{model:KIE_PROPERTY_MODEL,input:{prompt,image_urls:[OWNED_SOURCE_URL],sound:false,duration:"5",mode:"4K",multi_shots:false}}]);
 assertEquals([ref.provider,ref.model,ref.id,ref.poll_url],["kie",KIE_PROPERTY_MODEL,H.TASK_ID,H.KIE_RECORD_URL]);
 // The status token the worker later polls is exactly this receipt.
 assertEquals([H.JOBS.kie.p,H.JOBS.kie.m,H.JOBS.kie.i,H.JOBS.kie.u],[ref.provider,ref.model,ref.id,ref.poll_url]);
 assertEquals(w.polls,0);assertEquals(w.downloads,0);
});

for(const spec of[H.UHD_LANDSCAPE,H.UHD_PORTRAIT]){
 const aspect=spec.width>spec.height?"16:9":"9:16";
 Deno.test({name:`rehearsal ${spec.name}: poll retains the native-UHD CFR24 clip, the actual probe + kieProperty4KFacts commit it, quality accepts, compose binds the exact retained object`,ignore:!ffmpeg,fn:async()=>{
  const clip=await H.syntheticClip(spec),clipSha=await sha(clip);
  H.r2Store.clear();const journal=new Map<string,H.JournalRow>();
  const w=wire(`https://${H.CDN_HOST}/kie/${H.TASK_ID}.mp4`,{bytes:clip,type:"application/octet-stream"});
  const ctx=H.ctxFor(KIE_PROPERTY_PROFILE,aspect,"push_in");await H.seedSourcePhoto(ctx);
  // 1. poll: persist through the real routed status, then the worker decides from the stored object.
  const{s}=await tick("kie",KIE_PROPERTY_PROFILE,aspect,w,journal,ctx);
  H.committed(s,spec.name);
  assertEquals([w.polls,w.downloads],[1,1],"one record read, one bounded download");
  assertEquals(s.methods,["GET status"]);
  const stored=[...H.r2Store.entries()].filter(([path])=>path.includes("/completed-video/"));assertEquals(stored.length,1,"exactly one retained object");
  assertEquals(stored[0][1].type,"video/mp4","a generic-binary labelled Kie MP4 is retained as video/mp4");assertEquals(stored[0][1].bytes.length,clip.length);
  assert(stored[0][0].endsWith(".mp4"));
  const clipRpc=s.rpcs.find(r=>r.name==="property_video_job_clip")!.args.p_clip as Record<string,unknown>;
  assertEquals([clipRpc.width,clipRpc.height,clipRpc.bytes,clipRpc.sha256,clipRpc.content_type],[spec.width,spec.height,clip.length,clipSha,"video/mp4"],"committed clip facts come from the actual probe and the actual bytes");
  assert(Math.abs(Number(clipRpc.duration_s)-5)<=0.001,"five seconds exactly");
  assertEquals(clipRpc.etag,stored[0][1].etag);
  const lineage=s.rpcs.find(r=>r.name==="bind_property_video_source")!.args;assertEquals([lineage.p_request,lineage.p_generation_provenance,lineage.p_listing],[H.TASK_ID,"owned-generation",H.LISTING]);
  // The same probe, run independently on the retained object: native UHD, CFR24, 120 frames.
  const signed=await common.presignGet(r2.R2_BUCKET_RENDERS,String(clipRpc.storage_key),300);
  const facts=await H.withTransport(w,()=>probeRetainedProviderMP4Video(signed,fetch));
  assertEquals([facts.width,facts.height,facts.fps,Math.round(facts.duration_s*facts.fps)],[spec.width,spec.height,24,120]);
  assertEquals(kieProperty4KFacts(facts),true);
  assert(Math.min(facts.width,facts.height)>=KIE_PROPERTY_IDENTITY.min_short_side_px&&facts.width*facts.height>=KIE_PROPERTY_IDENTITY.min_pixels);
  // 2. quality: the actual worker quality plumbing with the judge as a closed verdict.
  const source={...ctx.source,clip:{bucket:"renders",storage_key:clipRpc.storage_key,bytes:clipRpc.bytes,etag:clipRpc.etag,content_type:"video/mp4",sha256:clipRpc.sha256},generation_provenance_id:"owned-generation",quality_retries:0};
  const drifts:unknown[]=[];
  const frame={image_b64:btoa("synthetic-review-frame"),mime:"image/jpeg"};
  const q=await H.withTransport(w,()=>H.runWorker({status:async()=>{throw Error("no status read during quality");},drift:async(body:unknown)=>{drifts.push(body);return{status:200,value:{drift:{action:"accept",publishable:true}}};},row:()=>null,paid:null},async(st)=>{await worker.quality({...ctx,source},{clip_sha256:clipSha,frames:[frame,frame,frame]});return st;}));
  assertEquals(q.s.rpcs.map(r=>r.name),["property_video_job_qc"],"accepted verdict records QC for this lease/attempt");
  assertEquals(q.s.fail,[]);assertEquals(q.s.methods,["POST drift"]);
  const drift=drifts[0] as Record<string,unknown>;assertEquals([drift.request_id,drift.kind,drift.seconds,drift.motion,drift.listing_id,drift.provenance_id,drift.attempt],[H.TASK_ID,"reel",5,"push_in",H.LISTING,"owned-generation",0]);
  assertEquals((drift.frames as unknown[]).length,3);
  // 3. compose: the exact action handed to the CPU renderer, bound to the retained object.
  const composeCtx={...ctx,action:"compose",sources:[{state:"ready",position:0,motion:"push_in",asset_id:"same-source",source:ctx.source.source,clip:source.clip}]};
  const c=await H.withTransport(w,()=>H.runWorker({status:async()=>{throw Error("no status read during compose");},row:()=>null,paid:null},async()=>await worker.action(composeCtx)));
  const action=c.result as Record<string,any>;
  assertEquals([action.action,action.state,action.composition_profile,action.aspect,action.purpose,action.lease_token],["compose","composing","steady-v2-cfr24",aspect,"listing",H.COMPOSE_LEASE]);
  assertEquals([action.narration,action.music],[null,null]);
  assertEquals(action.sources.length,1);const src=action.sources[0];
  assertEquals([src.position,src.motion_kind,src.motion,src.sha256,src.bytes,src.etag],[0,"ai","push_in",clipSha,clip.length,clipRpc.etag]);
  const url=new URL(src.url);assert(url.hostname.endsWith(".r2.cloudflarestorage.com"));assertEquals(url.searchParams.get("X-Amz-Expires"),"1800");assertEquals(decodeURIComponent(url.pathname),H.r2Path(r2.R2_BUCKET_RENDERS,String(clipRpc.storage_key)));
  assertMatch(String(action.output.key),new RegExp(`^renders/${H.ORG}/${H.LISTING}/background/${H.JOB_ID}/${H.COMPOSE_LEASE}/master\\.mp4$`));
  // The source capability the renderer will GET resolves to the exact retained bytes.
  const head=await H.withTransport(w,()=>fetch(src.url,{method:"HEAD"}));
  assertEquals([head.status,head.headers.get("content-length"),head.headers.get("content-type"),head.headers.get("etag")],[200,String(clip.length),"video/mp4",clipRpc.etag]);
  assertEquals(c.s.events.filter(e=>e==="scope"),["scope"],"the compose lease is re-verified");
  // Where the offline chain stops: everything after this ComposeAction is the CPU renderer (test_cpu.py).
 }});
}

Deno.test({name:"negative: a 1920x1080 Pro-tier substitute (echo still says 4K) is terminal source_video_unverifiable at the actual probe; the FAL steady profile accepts the same clip (control)",ignore:!ffmpeg,fn:async()=>{
 const clip=await H.syntheticClip(H.HD_PRO_SUBSTITUTE);
 H.r2Store.clear();let journal=new Map<string,H.JournalRow>();
 const w=wire(`https://${H.CDN_HOST}/kie/${H.TASK_ID}.mp4`,{bytes:clip,type:"video/mp4"});
 const ctx=H.ctxFor(KIE_PROPERTY_PROFILE,"16:9");await H.seedSourcePhoto(ctx);
 const{s}=await tick("kie",KIE_PROPERTY_PROFILE,"16:9",w,journal,ctx);
 H.terminalOnce(s,"1080p substitute");
 assert(s.events.includes("probe")&&!s.events.includes("bytes"),"decided at the actual probe, before any clip byte read");
 assertEquals(s.diagnostics,[],"the probe accepted the container; the Kie 4K facts refused it");
 // Control: the same retained 1080p CFR24 clip satisfies the FAL steady profile's gate and commits.
 H.r2Store.clear();journal=new Map();const fctx=H.ctxFor(PROPERTY_VIDEO_STEADY_PROFILE,"16:9");await H.seedSourcePhoto(fctx);
 const fw=wire("unused",{bytes:clip,type:"video/mp4"});
 const f=await tick("fal",PROPERTY_VIDEO_STEADY_PROFILE,"16:9",fw,journal,fctx);
 H.committed(f.s,"FAL steady control");
 const clipRpc=f.s.rpcs.find(r=>r.name==="property_video_job_clip")!.args.p_clip as Record<string,unknown>;assertEquals([clipRpc.width,clipRpc.height],[1920,1080]);
}});

Deno.test({name:"negative: a 23.976 fps clip is refused by the actual retained-provider probe (terminal once, no re-poll, no byte read)",ignore:!ffmpeg,fn:async()=>{
 const clip=await H.syntheticClip(H.UHD_NTSC);
 H.r2Store.clear();const journal=new Map<string,H.JournalRow>();
 const w=wire(`https://${H.CDN_HOST}/kie/${H.TASK_ID}.mp4`,{bytes:clip,type:"video/mp4"});
 const ctx=H.ctxFor(KIE_PROPERTY_PROFILE,"16:9");await H.seedSourcePhoto(ctx);
 const{s}=await tick("kie",KIE_PROPERTY_PROFILE,"16:9",w,journal,ctx);
 H.terminalOnce(s,"23.976 fps");
 assertEquals(s.diagnostics.map((d:any)=>[d.phase,d.http_status]),[["mp4_probe",400]],"the probe's deterministic A400 refusal");
 assert(!s.events.includes("bytes"));
}});

Deno.test({name:"negative: a .mov result is terminal at the stored-object gate before any probe or byte read",ignore:!ffmpeg,fn:async()=>{
 const clip=await H.syntheticClip(H.UHD_LANDSCAPE);
 H.r2Store.clear();const journal=new Map<string,H.JournalRow>();
 const w=wire(`https://${H.CDN_HOST}/kie/${H.TASK_ID}.mov`,{bytes:clip,type:"video/quicktime"});
 const ctx=H.ctxFor(KIE_PROPERTY_PROFILE,"16:9");await H.seedSourcePhoto(ctx);
 const{s}=await tick("kie",KIE_PROPERTY_PROFILE,"16:9",w,journal,ctx);
 H.terminalOnce(s,".mov");
 assertEquals(s.events,["status","private_ai_outputs","head","app_video_cost_reservations"],"decided from the HEAD after the paid receipt");
 const stored=[...H.r2Store.keys()].filter(k=>k.includes("/completed-video/"));assertEquals(stored.length,1);assert(stored[0].endsWith(".mov"));
}});

Deno.test("negative: a retained object one byte over the 64 MiB bounded read is terminal before any byte read (simulated by the journal row and HEAD, no 64 MiB body)",async()=>{
 H.r2Store.clear();const journal=new Map<string,H.JournalRow>();
 const over=64*1024*1024+1,key=`ai-router/${H.ORG}/completed-video/simulated-oversize.mp4`;
 const stored=H.putStored(H.r2Path(r2.R2_BUCKET_RENDERS,key),new Uint8Array(16),"video/mp4",over);
 journal.set(key,{org_id:H.ORG,user_id:H.USER,listing_id:H.LISTING,bucket:"renders",storage_key:key,bytes:over});
 const w=wire("unused",{bytes:new Uint8Array(0),type:null});
 const ctx=H.ctxFor(KIE_PROPERTY_PROFILE,"16:9");await H.seedSourcePhoto(ctx);
 const{s}=await H.withTransport(w,()=>H.runWorker({status:async()=>({status:200,value:{status:"completed",persisted:true,asset_key:key}}),row:()=>({storage_key:key,bytes:over}),paid:{provider_request_id:H.TASK_ID,model:KIE_PROPERTY_MODEL}},async()=>{await worker.poll(ctx);}));
 H.terminalOnce(s,"64 MiB + 1");
 assertEquals(s.events,["status","private_ai_outputs","head","app_video_cost_reservations"]);
 assert(stored.etag,"the object exists unchanged");
});

// Registered last: the process environment is shared by every test module in one run.
Deno.test("restore the process KIE_API_KEY this module set for its fixtures",()=>{H.restoreKieKey();assertEquals(Deno.env.get("KIE_API_KEY"),H.KIE_KEY_BEFORE);});
