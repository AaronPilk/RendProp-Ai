// K3: the two remaining Kie stall shapes are terminal at persistence instead of
// re-polling the same receipt to the 24 h deadline: a result whose extension
// names an image (never a storable video), and a result over the 100 MiB edge
// persist limit (refused on its declared size before any body byte). The REAL
// routedStatus (ai-video/index.ts), routed-output journal, persistResult and
// Kie adapter poll run against closed HTTP doubles; the REAL worker poll
// (engine.ts) then fails the attempt once. FAL keeps its retryable 503 and its
// poll-release loop exactly as before (controls), and compiled defect controls
// show each new guard is load-bearing.
import{assert,assertEquals,assertRejects}from"https://deno.land/std@0.224.0/assert/mod.ts";
import*as H from"./kie-rehearsal-harness.ts";
Deno.env.set("KIE_API_KEY",H.FIXTURE_KIE_KEY);
const{KIE_PROPERTY_PROFILE,KIE_PROPERTY_MODEL,PROPERTY_VIDEO_STEADY_PROFILE,PROPERTY_VIDEO_QUALITY_PROFILE,common,r2,kieAdapter,HttpError,respondError}=H;
const{createRoutedOutput}=await import("../ai-video/routed-output.ts");
const MiB=1024*1024;
const actualRouted=await H.compileRoutedStatus();
// The K3 branch in routedStatus, and the routed status rebuilt without it (the pre-K3 stall reference).
const K3_BRANCH_START='    if (job.p === "kie" && e instanceof HttpError && e.details?.result_unretainable === true) {';
const k3At=H.ROUTED_STATUS_SOURCE.indexOf(K3_BRANCH_START),k3End=H.ROUTED_STATUS_SOURCE.indexOf("\n    }\n",k3At);
assert(k3At>0&&k3End>k3At,"the K3 branch is in routedStatus");
const PRE_K3_ROUTED=H.ROUTED_STATUS_SOURCE.slice(0,k3At)+H.ROUTED_STATUS_SOURCE.slice(k3End+"\n    }\n".length);
assert(!PRE_K3_ROUTED.includes("result_unretainable"));
const preK3Routed=await H.compileRoutedStatus(PRE_K3_ROUTED);
const worker=await H.compileWorker();
const MAPPING="kie&&out.value.result_unretainable===true?'source_video_unverifiable':'provider_terminal_failed'";
const preK3Worker=await H.compileWorker(H.once(H.ACTUAL_POLL,MAPPING,"'provider_terminal_failed'"));
const widenedWorker=await H.compileWorker(H.once(H.ACTUAL_POLL,"kie&&out.value.result_unretainable===true","out.value.result_unretainable===true"));

type Routed={make:(deps:unknown)=>H.RoutedStatus};
function wire(resultUrl:string,media:{bytes:Uint8Array;type:string|null;declaredLength?:number}):H.KieWire{return{posts:[],polls:0,downloads:0,record:()=>H.kieSuccess(resultUrl),cdn:()=>media};}
async function chain(o:{routed:Routed;engine:H.Worker;provider:"kie"|"fal";profile:string|undefined;resultUrl:string;media:{bytes:Uint8Array;type:string|null;declaredLength?:number};paid?:H.PaymentDouble;job?:Record<string,unknown>}){
 H.r2Store.clear();const journal=new Map<string,H.JournalRow>();const w=wire(o.resultUrl,o.media);const paid=o.paid??H.payment();
 const falPoll={poll:async()=>({status:"done",result_url:o.resultUrl,mime:/\.png(\?|$)/i.test(o.resultUrl)?"image/png":"video/mp4"})};
 const routed=o.routed.make({admin:H.journalAdmin(journal,paid),adapter:(p:string)=>p==="kie"?kieAdapter:falPoll,head:r2.headObject,bucket:r2.R2_BUCKET_RENDERS,persist:common.persistResult,sign:(scope:{key:string},seconds:number)=>`https://private-media.fixture.invalid/${scope.key}?ttl=${seconds}`});
 const statuses:{status:number;value:Record<string,unknown>}[]=[];
 const status=async()=>{let r:Response;try{r=await routed(H.ORG,o.job??H.JOBS[o.provider]);}catch(e){r=respondError(e);}const out={status:r.status,value:await r.json()};statuses.push(out);return out;};
 const row=()=>{const rows=[...journal.values()];return rows.length===1?{storage_key:rows[0].storage_key,bytes:rows[0].bytes}:null;};
 const ctx=H.ctxFor(o.profile,"16:9");await H.seedSourcePhoto(ctx);
 const{s}=await H.withTransport(w,()=>H.runWorker({status,row,paid:{provider_request_id:H.TASK_ID,model:o.provider==="kie"?KIE_PROPERTY_MODEL:H.JOBS.fal.m}},async()=>{await o.engine.poll(ctx);}));
 const objects=[...H.r2Store.keys()].filter(k=>k.includes("/completed-video/"));
 return{s,w,journal,objects,status:statuses[0],paid};
}
const PNG=`https://${H.CDN_HOST}/kie/${H.TASK_ID}.png`,MP4=`https://${H.CDN_HOST}/kie/${H.TASK_ID}.mp4`;
const tiny={bytes:new Uint8Array(4096),type:"video/mp4"};
const OVER_LIMIT={bytes:new Uint8Array(64),type:"video/mp4",declaredLength:100*MiB+1};
// The one read the Kie branch makes: this receipt's accepted payment, by the signed owner and admission key.
const KIE_PAYMENT_READ={columns:"provider_request_id,cost_ledger_id,settled_at,released_at",filters:{org_id:H.ORG,actor_id:H.USER,provider:"kie",model:KIE_PROPERTY_MODEL,idempotency_key:"same-operation"},limit:2};
function terminalUnretainable(r:Awaited<ReturnType<typeof chain>>,label:string,downloads:number){
 assertEquals(r.status.status,200,label);
 assertEquals(r.status.value,{status:"failed",error:"The generated result cannot be retained as a video.",error_class:"upstream",provider:"kie",failure_phase:"persistence",result_unretainable:true},label);
 assertEquals(r.s.fail,[{code:"source_video_unverifiable",ambiguous:false}],label);
 assertEquals(r.s.rpcs,[],label+": no poll release, no commit");assertEquals(r.s.diagnostics,[],label);
 assertEquals(r.s.events,["status"],label+": decided from the status alone");
 assertEquals([r.w.polls,r.w.downloads,r.objects.length,r.journal.size],[1,downloads,0,0],label+": nothing retained or journaled");
 assertEquals(r.paid.reads,[KIE_PAYMENT_READ],label+": terminal only after one exact read of the settled payment");
}
function stalled(r:Awaited<ReturnType<typeof chain>>,label:string,paymentReads?:number){
 assertEquals(r.status.status,503,label);assertEquals(r.status.value.retry_existing_job,true,label);assertEquals(r.status.value.failure_phase,"persistence",label);
 H.released(r.s,label,"status_response");assertEquals([r.objects.length,r.journal.size],[0,0],label);
 if(paymentReads!==undefined)assertEquals(r.paid.reads.length,paymentReads,label+": payment reads");
}

Deno.test("Kie image-extension result: terminal failed at the status, before any download; the worker fails the attempt once (no poll release)",async()=>{
 const r=await chain({routed:actualRouted,engine:worker,provider:"kie",profile:KIE_PROPERTY_PROFILE,resultUrl:PNG,media:tiny});
 terminalUnretainable(r,".png",0);
 // The same receipt polled again still answers terminal (the worker never does, but a support read may).
 const again=await chain({routed:actualRouted,engine:worker,provider:"kie",profile:KIE_PROPERTY_PROFILE,resultUrl:PNG,media:tiny});terminalUnretainable(again,".png again",0);
});
Deno.test("Kie result over the 100 MiB persist limit: refused on its declared size (one bounded GET; the unit case below proves no body byte is read), terminal failed, the worker fails the attempt once",async()=>{
 const r=await chain({routed:actualRouted,engine:worker,provider:"kie",profile:KIE_PROPERTY_PROFILE,resultUrl:MP4,media:OVER_LIMIT});
 terminalUnretainable(r,"100 MiB + 1",1);
 // Exactly 100 MiB declared is within the limit: the declared-size rule, not a smaller bound, decides (a real 100 MiB body is not made; the double declares it and serves 64 bytes, which the actual-size rule then stores as 64 bytes).
 const at=await chain({routed:actualRouted,engine:worker,provider:"kie",profile:KIE_PROPERTY_PROFILE,resultUrl:MP4,media:{bytes:new Uint8Array(64),type:"video/mp4",declaredLength:100*MiB}});
 assertEquals(at.status.value.status,"completed","at the limit the download proceeds");
});
Deno.test("control: FAL keeps the retryable 503 and the worker's poll-release loop for both shapes; legacy and v1/steady profiles unchanged",async()=>{
 for(const profile of[undefined,"legacy",PROPERTY_VIDEO_QUALITY_PROFILE,PROPERTY_VIDEO_STEADY_PROFILE]){
  // A settled FAL payment is present, and is never read: the Kie branch is the only reader.
  const png=await chain({routed:actualRouted,engine:worker,provider:"fal",profile,resultUrl:"https://fal.media/files/fixture-result.png",media:tiny});stalled(png,`FAL .png ${profile}`,0);
  const over=await chain({routed:actualRouted,engine:worker,provider:"fal",profile,resultUrl:"https://fal.media/files/fixture-result.mp4",media:OVER_LIMIT});stalled(over,`FAL over limit ${profile}`,0);
  // Pre-K3 and actual FAL decisions are identical.
  const before=await chain({routed:preK3Routed,engine:preK3Worker,provider:"fal",profile,resultUrl:"https://fal.media/files/fixture-result.png",media:tiny});
  assertEquals([before.status,H.decision(before.s)],[png.status,H.decision(png.s)],`FAL unchanged ${profile}`);
 }
 // A retainable FAL MP4 still completes and commits through the same code.
 const ok=await chain({routed:actualRouted,engine:worker,provider:"fal",profile:PROPERTY_VIDEO_STEADY_PROFILE,resultUrl:"https://fal.media/files/fixture-result.mp4",media:tiny});
 assertEquals(ok.status.value.status,"completed");assertEquals(ok.objects.length,1);
});
Deno.test("compiled defect controls: without the K3 status branch a Kie image or oversize result is a 503 the worker re-polls to the deadline; the worker mapping is Kie-only and load-bearing",async()=>{
 // 1. The pre-K3 routed status: the exact stall shape (503, poll release every tick).
 stalled(await chain({routed:preK3Routed,engine:worker,provider:"kie",profile:KIE_PROPERTY_PROFILE,resultUrl:PNG,media:tiny}),"pre-K3 .png stall");
 stalled(await chain({routed:preK3Routed,engine:worker,provider:"kie",profile:KIE_PROPERTY_PROFILE,resultUrl:MP4,media:OVER_LIMIT}),"pre-K3 oversize stall");
 // 2. Worker mapping removed: the terminal status is recorded with the generic supplier-failure code.
 const generic=await chain({routed:actualRouted,engine:preK3Worker,provider:"kie",profile:KIE_PROPERTY_PROFILE,resultUrl:PNG,media:tiny});
 assertEquals(generic.s.fail,[{code:"provider_terminal_failed",ambiguous:false}]);assertEquals(generic.s.rpcs,[]);
 // 3. Worker mapping widened beyond the Kie profile: a FAL-profile job would take the Kie code (never produced by the FAL status, so proven directly).
 const ctx=H.ctxFor(PROPERTY_VIDEO_STEADY_PROFILE,"16:9");
 const forged={status:200,value:{status:"failed",error_class:"upstream",provider:"fal",result_unretainable:true}};
 for(const[engine,code]of[[worker,"provider_terminal_failed"],[widenedWorker,"source_video_unverifiable"]] as const){
  const{s}=await H.runWorker({status:async()=>forged,row:()=>null,paid:null},async()=>{await engine.poll(ctx);});
  assertEquals(s.fail,[{code,ambiguous:false}]);
 }
 // 4. The K3 branch without its payment gate (as first written): a still-held payment is answered
 // terminal, the worker fails the attempt and never polls again, so the expired-token recovery that
 // books a held acceptance never runs; the hold is stranded, neither booked nor released.
 const ungated=await H.compileRoutedStatus(H.once(H.ROUTED_STATUS_SOURCE,"      if (paid) {","      if (true) {"));
 const stranded=await chain({routed:ungated,engine:worker,provider:"kie",profile:KIE_PROPERTY_PROFILE,resultUrl:PNG,media:tiny,paid:H.payment([H.HELD_PAYMENT])});
 assertEquals([stranded.status.value.status,stranded.s.fail,stranded.s.rpcs],["failed",[{code:"source_video_unverifiable",ambiguous:false}],[]],"control: the ungated branch strands a held payment");
 console.log("KIE_UNRETAINABLE_COMPILED_CONTROLS=4");
});

// ---- the payment gate: terminal only once this receipt's accepted payment is booked ----
Deno.test("a Kie unretainable result whose accepted payment is still a held reservation (settlement failed after acceptance) keeps the retryable 503 and the worker's poll release; once that payment is settled the same receipt is terminal",async()=>{
 for(const[label,resultUrl,media,downloads]of[[".png",PNG,tiny,0],["100 MiB + 1",MP4,OVER_LIMIT,1]] as const){
  const held=await chain({routed:actualRouted,engine:worker,provider:"kie",profile:KIE_PROPERTY_PROFILE,resultUrl,media,paid:H.payment([H.HELD_PAYMENT])});
  stalled(held,label+" held",1);assertEquals(held.paid.reads,[KIE_PAYMENT_READ],label+" held: the same exact read");
  // The settlement recovery (an expired-token poll, paidRoutedReceiptMatches(routed,true)) books the hold; the next poll is terminal.
  const settled=await chain({routed:actualRouted,engine:worker,provider:"kie",profile:KIE_PROPERTY_PROFILE,resultUrl,media,paid:H.payment([H.SETTLED_PAYMENT])});
  terminalUnretainable(settled,label+" settled",downloads);
 }
});
Deno.test("only one settled, unreleased payment row for this exact receipt makes it terminal: released, another request id, a partial tuple, no row, two rows and a read error each keep the retryable 503",async()=>{
 const RELEASED={provider_request_id:null,cost_ledger_id:null,settled_at:null,released_at:"2026-10-17T00:00:02.000Z"};
 const cases:[string,H.PaymentRow[]|Error][]=[["released",[RELEASED]],["another request id",[{...H.SETTLED_PAYMENT,provider_request_id:"kie-another-task"}]],
  ["no ledger row",[{...H.SETTLED_PAYMENT,cost_ledger_id:null}]],["no settlement time",[{...H.SETTLED_PAYMENT,settled_at:null}]],["an unparseable settlement time",[{...H.SETTLED_PAYMENT,settled_at:"not-a-time"}]],
  ["no row",[]],["two rows",[H.SETTLED_PAYMENT,H.SETTLED_PAYMENT]],["a read error",new Error("permission denied for table app_video_cost_reservations")]];
 for(const[label,rows]of cases){
  const r=await chain({routed:actualRouted,engine:worker,provider:"kie",profile:KIE_PROPERTY_PROFILE,resultUrl:PNG,media:tiny,paid:H.payment(rows)});
  stalled(r,label,1);
 }
 // A thrown read (transport) is the same "not yet", even with a settled row behind it.
 stalled(await chain({routed:actualRouted,engine:worker,provider:"kie",profile:KIE_PROPERTY_PROFILE,resultUrl:PNG,media:tiny,paid:H.payment([H.SETTLED_PAYMENT],true)}),"a thrown read",1);
});
Deno.test("a receipt signed without an admission key reads the payment by its exact provider request id",async()=>{
 const{a:_admission,...unkeyed}=H.JOBS.kie;
 const r=await chain({routed:actualRouted,engine:worker,provider:"kie",profile:KIE_PROPERTY_PROFILE,resultUrl:PNG,media:tiny,job:unkeyed});
 assertEquals(r.status.value.status,"failed");assertEquals(r.s.fail,[{code:"source_video_unverifiable",ambiguous:false}]);
 assertEquals(r.paid.reads,[{...KIE_PAYMENT_READ,filters:{org_id:H.ORG,actor_id:H.USER,provider:"kie",model:KIE_PROPERTY_MODEL,provider_request_id:H.TASK_ID}}]);
});

// ---- unit: persistResult and the routed-output journal name the unretainable shapes ----
Deno.test("persistResult: a declared size over the limit refuses before any body byte with result_unretainable; the actual size after; every other failure stays retryable",async()=>{
 for(const provider of["kie","fal","higgsfield"]){
  let pulls=0;const previous=globalThis.fetch;
  globalThis.fetch=(async(input:RequestInfo|URL,init?:RequestInit)=>{
   const u=new URL(new Request(input,init).url);
   // highWaterMark 0: pull runs only for an actual read, so `pulls` counts body reads.
   if(u.pathname==="/declared-over")return new Response(new ReadableStream({pull(c){pulls++;c.enqueue(new Uint8Array(1));c.close();}},{highWaterMark:0}),{headers:{"content-length":String(100*MiB+1),"content-type":"video/mp4"}});
   if(u.pathname==="/actual-over")return new Response(new Uint8Array(100*MiB+1),{headers:{"content-type":"video/mp4"}});
   if(u.pathname==="/unavailable")return new Response("gone",{status:503});
   if(u.pathname==="/empty")return new Response(new Uint8Array(0),{headers:{"content-type":"video/mp4"}});
   throw new Error("closed");
  })as typeof fetch;
  try{
   const declared=await assertRejects(()=>common.persistResult(provider,{status:"done",result_url:"https://results.fixture.invalid/declared-over",mime:"video/mp4"},"ai-router/x/declared.mp4"),common.ProviderError);
   assertEquals([declared.result_unretainable,declared.error_class,declared.dispatch_rejected,pulls],[true,"upstream",false,0],provider+" declared");
   const actual=await assertRejects(()=>common.persistResult(provider,{status:"done",result_url:"https://results.fixture.invalid/actual-over",mime:"video/mp4"},"ai-router/x/actual.mp4"),common.ProviderError);
   assertEquals([actual.result_unretainable,actual.error_class],[true,"upstream"],provider+" actual");
   for(const path of["unavailable","empty"]){
    const other=await assertRejects(()=>common.persistResult(provider,{status:"done",result_url:"https://results.fixture.invalid/"+path,mime:"video/mp4"},"ai-router/x/other.mp4"),common.ProviderError);
    assertEquals(other.result_unretainable,false,provider+" "+path);
   }
  }finally{globalThis.fetch=previous;}
 }
 // The flag is constructor-opt-in: every other ProviderError reads false.
 assertEquals(new common.ProviderError("kie","upstream","x",500).result_unretainable,false);
 assertEquals(new common.ProviderError("kie","upstream","x",undefined,false,true).result_unretainable,true);
});
Deno.test("routed-output journal: an image mime and an unretainable persist each become one 503 carrying result_unretainable; other persist failures pass through unchanged",async()=>{
 const identity={orgId:H.ORG,userId:H.USER,listingId:H.LISTING,provider:"kie",model:KIE_PROPERTY_MODEL,requestId:H.TASK_ID,submittedAt:"2026-10-17T00:00:00.000Z",kind:"video.reel_clip"};
 const registered:string[]=[];
 const deps=(persist:(state:unknown,key:string)=>Promise<{key:string;bytes:number}>)=>({find:async()=>[],register:async(key:string)=>{registered.push(key);},head:async()=>({exists:false,bytes:null}),persist:persist as never,sign:async()=>"https://signed.invalid/x"});
 const output=await createRoutedOutput(identity,deps(async()=>{throw new Error("persist must not run for an image");}));
 const image=await assertRejects(()=>output.complete({status:"done",result_url:"https://x.invalid/a.png",mime:"image/png"}),HttpError);
 assertEquals([image.status,image.code,image.details],[503,"upstream",{failure_phase:"persistence",result_unretainable:true}]);
 assertEquals(registered,[],"nothing journaled for an unsupported format");
 const oversize=await createRoutedOutput(identity,deps(async()=>{throw new common.ProviderError("kie","upstream","over",undefined,false,true);}));
 const over=await assertRejects(()=>oversize.complete({status:"done",result_url:"https://x.invalid/a.mp4",mime:"video/mp4"}),HttpError);
 assertEquals([over.status,over.details],[503,{failure_phase:"persistence",result_unretainable:true}]);
 const plain=await createRoutedOutput(identity,deps(async()=>{throw new common.ProviderError("kie","upstream","download failed (HTTP 503)");}));
 const passthrough=await assertRejects(()=>plain.complete({status:"done",result_url:"https://x.invalid/a.mp4",mime:"video/mp4"}),common.ProviderError);
 assertEquals(passthrough.result_unretainable,false);
 const network=await createRoutedOutput(identity,deps(async()=>{throw new TypeError("network");}));
 await assertRejects(()=>network.complete({status:"done",result_url:"https://x.invalid/a.mp4",mime:"video/mp4"}),TypeError);
});

// Registered last: the process environment is shared by every test module in one run.
Deno.test("restore the process KIE_API_KEY this module set for its fixtures",()=>{H.restoreKieKey();assertEquals(Deno.env.get("KIE_API_KEY"),H.KIE_KEY_BEFORE);});
