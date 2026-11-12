import {assertEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {waitForPhotoQuality,continuePhotoQualityAfterResponse,type PhotoWaitDependencies} from "./photo-qc-wait.ts";
import type {PhotoQualityEnvelope} from "./photo-qc-store.ts";
const actor="ea100606-0000-4000-8000-000000000001",org="ea100606-0000-4000-8000-000000000002",listing="ea100606-0000-4000-8000-000000000003",id="ea100606-0000-4000-8000-000000000004";
function fixture(){
 const state={now:0,starts:0,reads:0,judges:0,scope:0,busy:false,withdrawn:false,abort:new AbortController(),sequence:["preparing","derivative_ready"],deadline:0};
 const row={evidence:{id,actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,request_key:"wait-fixture",request_sha256:"a".repeat(64),policy:"photo-fixed-features-v1",state:"evidence_ready"},check:{id,evidence_id:id,policy:"photo-fixed-features-v1",state:"pending",judge_started_at:null},can_continue:true} as PhotoQualityEnvelope;
 const admin={rpc:async()=>{state.scope++;return state.withdrawn?{data:null,error:{message:"RP404: Removed"}}:{data:{actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,billing_org_id:org,team_org_id:null,library_owner_user_id:actor,listing_owner_user_id:actor,role:"owner",access_mode:"own",can_read:true,can_write:true,can_manage_subscription:true},error:null};}};
 const deps:PhotoWaitDependencies={now:()=>state.now,sleep:async ms=>{state.now+=ms;},start:async()=>{state.starts++;return{started:!state.busy};},status:async(_admin,row)=>{state.reads++;return{...row,check:{...row.check,state:state.sequence.shift()??"preparing"}};},judge:async(_admin,row,args)=>{state.judges++;state.deadline=args.deadline!;return{...row,check:{...row.check,state:"accept"}};}};
 const run=(deadline?:number)=>waitForPhotoQuality(admin,row,{actor,selected:org,request:new Request("https://example.invalid/ai-photo",{signal:state.abort.signal}),deadline},deps);
 return{state,row,admin,deps,run};
}
Deno.test("fresh ordinary request starts CPU once, polls only scoped status, then judges exactly once",async()=>{
 const f=fixture(),result=await f.run();assertEquals(result.check.state,"accept");assertEquals(f.state.starts,1);assertEquals(f.state.reads,2);assertEquals(f.state.judges,1);assertEquals(f.state.deadline,120000);assertEquals(f.state.scope,3);
});
Deno.test("busy/lost kickoff returns saved pending without another start, read or judge",async()=>{
 const f=fixture();f.state.busy=true;assertEquals((await f.run()).check.state,"pending");assertEquals(f.state.starts,1);assertEquals(f.state.reads,0);assertEquals(f.state.judges,0);
});
Deno.test("read-only wait exhausts75seconds CPU budget and leaves45seconds unspent without repeat",async()=>{
 const f=fixture();f.state.sequence=[];assertEquals((await f.run()).check.state,"preparing");assertEquals(f.state.now,75000);assertEquals(f.state.starts,1);assertEquals(f.state.judges,0);assertEquals(f.state.reads,50);
});
Deno.test("already preparing check does not issue another CPU kickoff",async()=>{
 const f=fixture();f.row.check.state="preparing";f.row.can_continue=false;f.state.sequence=["derivative_ready"];f.deps.status=async(_admin,row)=>{f.state.reads++;return{...row,can_continue:true,check:{...row.check,state:"derivative_ready"}};};assertEquals((await f.run()).check.state,"accept");assertEquals(f.state.starts,0);assertEquals(f.state.judges,1);
});
Deno.test("caller abort, library withdrawal, and replaced IDs cannot trigger a judge",async()=>{
 for(const fault of ["abort","library","identity"]){const f=fixture();
  if(fault==="abort")f.state.abort.abort();
  if(fault==="library")f.deps.status=async(_admin,row)=>{f.state.withdrawn=true;return{...row,check:{...row.check,state:"derivative_ready"}};};
  if(fault==="identity")f.deps.status=async(_admin,row)=>({...row,check:{...row.check,id:org,state:"derivative_ready"}});
  await f.run();assertEquals(f.state.judges,0);assertEquals(f.state.starts,fault==="abort"?0:1);
 }
});

Deno.test("slow90s generation leaves40s: CPU starts once but saved pending returns without a paid judge",async()=>{
 const f=fixture();f.state.now=90_000;const result=await f.run(130_000);
 assertEquals(result.check.state,"pending");assertEquals(f.state.now,90_000);assertEquals(f.state.starts,1);assertEquals(f.state.reads,0);assertEquals(f.state.judges,0);
});
Deno.test("request absolute deadline cannot restart a fresh120s QC budget",async()=>{
 const f=fixture();f.state.now=60_000;f.state.sequence=[];await f.run(130_000);
 assertEquals(f.state.now,85_000);assertEquals(f.state.starts,1);assertEquals(f.state.judges,0);
 const expired=fixture();expired.state.now=130_000;await expired.run(130_000);assertEquals(expired.state.starts,0);assertEquals(expired.state.reads,0);assertEquals(expired.state.judges,0);
});
Deno.test("ready derivatives use only caller remainder, never a fresh judge deadline",async()=>{
 const f=fixture();f.state.now=70_000;f.row.check.state="derivative_ready";await f.run(130_000);assertEquals(f.state.deadline,130_000);assertEquals(f.state.judges,1);assertEquals(f.state.starts,0);
});
Deno.test("after an early release the saved check continues once on a detached request and can never reject",async()=>{
 const f=fixture(),seen={work:null as Promise<unknown>|null,calls:0,aborted:true,deadline:0,method:""};
 const host=globalThis as {EdgeRuntime?:unknown},previous=host.EdgeRuntime;
 host.EdgeRuntime={waitUntil:(work:Promise<unknown>)=>{seen.work=work;}};
 try{
  // The phone's connection is gone once the reply is sent; its abort must not end the check.
  f.state.abort.abort();
  continuePhotoQualityAfterResponse(f.admin,f.row,{actor,selected:org,url:"https://example.invalid/ai-photo",deadline:130_000},async(_admin,_row,args)=>{
   seen.calls++;seen.aborted=args.request.signal.aborted;seen.deadline=args.deadline!;seen.method=args.request.method;throw Error("synthetic background failure");});
  assertEquals(seen.work instanceof Promise,true);await seen.work;
  assertEquals(seen.calls,1);assertEquals(seen.aborted,false);assertEquals(seen.deadline,130_000);assertEquals(seen.method,"POST");
 }finally{host.EdgeRuntime=previous;}
 // Without a runtime that keeps the instance alive, only the controller wake
 // is sent: the deadline handed on leaves no room for a status loop or judge.
 delete host.EdgeRuntime;
 try{
  const wake={calls:0,deadline:0},before=Date.now();
  continuePhotoQualityAfterResponse(f.admin,f.row,{actor,selected:org,url:"https://example.invalid/ai-photo",deadline:before+110_000},async(_admin,row,args)=>{wake.calls++;wake.deadline=args.deadline!;return row;});
  await Promise.resolve();assertEquals(wake.calls,1);assertEquals(wake.deadline<=Date.now()+45_000,true);
  const real=fixture();real.deps.now=()=>Date.now();
  await new Promise<void>(done=>continuePhotoQualityAfterResponse(real.admin,real.row,{actor,selected:org,url:"https://example.invalid/ai-photo",deadline:Date.now()+110_000},async(admin,row,args)=>{try{return await waitForPhotoQuality(admin,row,args,real.deps);}finally{done();}}));
  assertEquals(real.state.starts,1);assertEquals(real.state.reads,0);assertEquals(real.state.judges,0);
 }finally{host.EdgeRuntime=previous;}
});
Deno.test("the detached continuation runs the real wait: one wake, scoped reads, one judge inside the request deadline",async()=>{
 const f=fixture();f.state.now=20_000;const seen={work:null as Promise<unknown>|null};
 const host=globalThis as {EdgeRuntime?:unknown},previous=host.EdgeRuntime;
 host.EdgeRuntime={waitUntil:(work:Promise<unknown>)=>{seen.work=work;}};
 try{
  continuePhotoQualityAfterResponse(f.admin,f.row,{actor,selected:org,url:"https://example.invalid/ai-photo",deadline:130_000},(admin,row,args)=>waitForPhotoQuality(admin,row,args,f.deps));
  await seen.work;assertEquals(f.state.starts,1);assertEquals(f.state.reads,2);assertEquals(f.state.judges,1);assertEquals(f.state.deadline,130_000);
 }finally{host.EdgeRuntime=previous;}
});
