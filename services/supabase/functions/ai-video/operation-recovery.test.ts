import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { recoverVideoOperation, retainVideoSubmission } from "./operation-recovery.ts";
import type { JobRef } from "../_shared/providers/types.ts";

const actor = "10000000-0000-4000-8000-000000000001", org = "20000000-0000-4000-8000-000000000001";
const listing = "30000000-0000-4000-8000-000000000001", operation = "40000000-0000-4000-8000-00000000000A";
const reference: JobRef = { provider: "fal", model: "bytedance/seedance/v1/pro/fast/image-to-video", id: "same-accepted-request",
  poll_url: "https://queue.fal.run/fal-ai/bytedance/requests/same-accepted-request/status", submitted_at: "2026-10-15T10:11:12.123Z" };
const request = (op = operation, home = listing) => new Request(`https://closed.invalid/functions/v1/ai-video/operation?operation_id=${op}&listing_id=${home}`);

function fixture() {
  const calls: {name:string;args:Record<string,unknown>}[] = [];
  let scopeCalls = 0, paidCalls = 0, signCalls = 0;
  const state = { response: { status: "accepted", actor_id: actor, org_id: org, listing_id: listing, operation_id: operation, receipt: structuredClone(reference) } as Record<string,unknown>,
    error: null as unknown, paid: true, revokeOn: 0, signedReference: null as JobRef|null };
  const deps = {
    preferredOrg: () => org,
    contentOrg: async (who:string, preferred:string|undefined, home:string) => {
      assertEquals([who,preferred,home],[actor,org,listing]);
      scopeCalls++; if (state.revokeOn === scopeCalls) throw Error("current property access revoked"); return org;
    },
    rpc: async (name:string,args:Record<string,unknown>) => { calls.push({name,args}); return {data:state.response,error:state.error}; },
    paidReceiptMatches: async (job:import("../_shared/providers/jobtoken.ts").RouterJobToken) => {
      paidCalls++; assertEquals([job.i,job.t,job.a,job.l,job.o,job.usr],[reference.id,reference.submitted_at,operation,listing,org,actor]); return state.paid;
    },
    sign: async (_req:Request, ref:JobRef, owner:Record<string,string>) => {
      signCalls++;state.signedReference=ref;assertEquals(owner,{orgId:org,userId:actor,listingId:listing,admissionKey:operation});return "https://closed.invalid/same-owned-signed-job";
    },
  };
  return {state,deps,calls,counts:()=>({scopeCalls,paidCalls,signCalls})};
}

Deno.test("lost202 lookup keeps exact original reference, key case, current scope and private response", async () => {
  const f=fixture(), response=await recoverVideoOperation(request(),actor,f.deps), data=await response.json();
  assertEquals(response.status,200);assertEquals(response.headers.get("cache-control"),"private, no-store");
  assertEquals(data,{operation_id:operation,listing_id:listing,selected_library_org_id:org,org_id:org,status:"accepted",request_id:reference.id,
    status_url:"https://closed.invalid/same-owned-signed-job",response_url:"https://closed.invalid/same-owned-signed-job",kind:"reel",model_id:reference.model});
  assertEquals(f.state.signedReference,reference);assertEquals(f.counts(),{scopeCalls:3,paidCalls:1,signCalls:1});
  assertEquals(f.calls,[{name:"app_video_submission_receipt_read",args:{p_actor:actor,p_org:org,p_key:operation,p_listing:listing}}]);
});

Deno.test("an unknown acceptance stays pending without payment, signing, generation or inferred success",async()=>{
  const f=fixture();f.state.response={...f.state.response,status:"pending"};delete f.state.response.receipt;
  const r=await recoverVideoOperation(request(),actor,f.deps),data=await r.json();
  assertEquals(data.status,"pending");assertEquals(data.operation_id,operation);assertEquals(data.request_id,undefined);
  assertEquals(f.counts(),{scopeCalls:2,paidCalls:0,signCalls:0});assertEquals(f.calls.length,1);
});

for(const field of ["actor_id","org_id","listing_id","operation_id"]){
  Deno.test(`operation recovery refuses a foreign ${field} before issuing a capability`,async()=>{
    const f=fixture();f.state.response[field]="50000000-0000-4000-8000-000000000001";
    await assertRejects(()=>recoverVideoOperation(request(),actor,f.deps));assertEquals(f.counts().signCalls,0);
  });
}
for(const revokeOn of [1,2,3]){
  Deno.test(`current property revocation at authority read${revokeOn} suppresses recovered receipt`,async()=>{
    const f=fixture();f.state.revokeOn=revokeOn;
    await assertRejects(()=>recoverVideoOperation(request(),actor,f.deps),Error,"current property access revoked");
    assertEquals(f.counts().signCalls,revokeOn===3?1:0);
  });
}

Deno.test("an unpaid or mismatched admission cannot mint a recovered token",async()=>{
  const f=fixture();f.state.paid=false;await assertRejects(()=>recoverVideoOperation(request(),actor,f.deps));assertEquals(f.counts().signCalls,0);
});
Deno.test("database errors and malformed results never become reassuring pending responses",async()=>{
  const f=fixture();f.state.error={message:"closed unavailable"};await assertRejects(()=>recoverVideoOperation(request(),actor,f.deps));
  const g=fixture();g.state.response.status="unknown";await assertRejects(()=>recoverVideoOperation(request(),actor,g.deps));
});

for(const bad of [
  {...reference,provider:"kie"}, {...reference,poll_url:reference.poll_url+"?key=private"},
  {...reference,poll_url:reference.poll_url!.replace("queue.fal.run","foreign.invalid")},
  {...reference,poll_url:reference.poll_url!.replace("bytedance","different-model")},
  {...reference,poll_url:reference.poll_url!.replace("same-accepted-request","another-request")},
  {...reference,submitted_at:"not-a-timestamp"}, {...reference,extra:"unbound"},
]){
  Deno.test(`invalid retained provider reference never reaches signing: ${JSON.stringify(bad)}`,async()=>{
    const f=fixture();f.state.response.receipt=bad;await assertRejects(()=>recoverVideoOperation(request(),actor,f.deps));assertEquals(f.counts().signCalls,0);
  });
}
Deno.test("malformed operation identity fails before any authority or database read",async()=>{
  const f=fixture();await assertRejects(()=>recoverVideoOperation(request("not-a-key"),actor,f.deps));assertEquals(f.calls.length,0);assertEquals(f.counts().scopeCalls,0);
});

Deno.test("submission receipt save binds exact fields despite JSONB object order",async()=>{
  const args={actor,org,key:operation,listing,ref:reference};let count=0;
  await retainVideoSubmission(args,async(name,body)=>{
    count++;assertEquals(name,"app_video_submission_receipt_save");assertEquals(body,{p_actor:actor,p_org:org,p_key:operation,p_listing:listing,p_receipt:reference});
    return{data:{saved:true,receipt:{submitted_at:reference.submitted_at,id:reference.id,model:reference.model,provider:reference.provider,poll_url:reference.poll_url}},error:null};
  });assertEquals(count,1);
  await assertRejects(()=>retainVideoSubmission(args,async()=>({data:{saved:true,receipt:{...reference,submitted_at:"2026-10-15T10:11:13Z"}},error:null})));
  await assertRejects(()=>retainVideoSubmission(args,async()=>({data:null,error:{message:"closed unavailable"}})));
});

Deno.test("actual GET operation route executes only recovery with ordinary authenticated actor",async()=>{
  const source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
  const start=source.indexOf('    if (req.method === "GET" && seg.length === 1 && seg[0] === "operation")');
  const end=source.indexOf("\n    // Reflection removal",start);assertEquals(start>0&&end>start,true);
  const f=fixture();
  const invoke=new Function("req","user","seg","recoverVideoOperation","preferredOrg","contentOrgForUser","rpc","paidRoutedReceiptMatches","routerStatusUrl",
    `return (async()=>{${source.slice(start,end)}})()`);
  const r=await invoke(request(),{id:actor},["operation"],recoverVideoOperation,f.deps.preferredOrg,f.deps.contentOrg,f.deps.rpc,f.deps.paidReceiptMatches,
    (req:Request,_name:string,_task:string,ref:JobRef,owner:Record<string,string>)=>f.deps.sign(req,ref,owner));
  assertEquals((await r.json()).request_id,reference.id);assertEquals(f.calls.length,1);
});

Deno.test("actual post-acceptance hook journals ordinary FAL only and never hides its known receipt",async()=>{
  const source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
  const start=source.indexOf("      const savedListing = body.listing_id ?? reelListingId;");
  const end=source.indexOf("      const sub = await submitEnvelope",start);
  assertEquals(start>0&&end>start,true);
  const invoke=new Function("worker","step","attempt","body","reelListingId","user","orgId","req","requiredIdempotencyKey","retainVideoSubmission","rpc","console",
    `return (async()=>{${source.slice(start,end)}return attempt.value;})()`);
  for(const [worker,provider,home,expected]of [[null,"fal",listing,1],[{},"fal",listing,0],[null,"kie",listing,0],[null,"fal",null,0]]as const){
    let calls=0;
    const original=structuredClone(reference);
    const returned=await invoke(worker,{provider},{value:original},{listing_id:home},null,{id:actor},org,request(),()=>operation,
      async(args:Record<string,unknown>)=>{calls++;assertEquals(args.ref,reference);throw Error("closed journal unavailable");},()=>{throw Error("unexpected directRPC");},{error:(message:string)=>assertEquals(message,"ai-video accepted receipt recovery journal unavailable")});
    assertEquals(calls,expected);assertEquals(returned,reference);
  }
});
