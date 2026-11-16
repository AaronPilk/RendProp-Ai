// Actual GET/status, paid proof, fresh content scope and routedStatus bodies.
// Real receipt HMAC and private-output identity/CAS; only auth, DB, provider
// polling and object transport are closed doubles. No generation or real DB writes;
// the accepted-hold tests exercise an idempotent settlement double explicitly.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { encodeJobToken, decodeJobToken } from "../_shared/providers/jobtoken.ts";
import { createRoutedOutput } from "./routed-output.ts";

const org = "a0100501-0000-4000-8000-000000000001";
const actor = "a0100502-0000-4000-8000-000000000002";
const listing = "a0100503-0000-4000-8000-000000000003";
const reservation = "a0100504-0000-4000-8000-000000000004";
const ledgerID = "a0100505-0000-4000-8000-000000000005";
const foreign = "a0100599-0000-4000-8000-000000000099";
const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
const body = (name: string) => {
  const start = source.indexOf(`async function ${name}(`), end = source.indexOf("\n}\n", start);
  assert(start > 0 && end > start, `${name} production anchor missing`);
  return source.slice(start, end + 3);
};
const routeStart = source.indexOf('    if (req.method === "GET" && seg.length === 1 && seg[0] === "status")');
const routeEnd = source.indexOf("\n    throw new HttpError(405,", routeStart);
assert(routeStart > 0 && routeEnd > routeStart);
type Row = Record<string, any>;
type Mutation = "proof" | "scope" | "ledger" | "listing" | "released" | "task" | "hold" | "partial" | "admission" | "repair";
const dataModule = (s: string) => "data:application/typescript;base64," + btoa(String.fromCharCode(...new TextEncoder().encode(s)));
async function compiled(mutation?: Mutation) {
  let proof = body("paidRoutedReceiptMatches"), route = source.slice(routeStart, routeEnd);
  function replace(text: string, from: string, to: string) { assertEquals(text.split(from).length, 2, `${mutation} anchor changed`); return text.replace(from, to); }
  if (mutation === "proof") proof = "async function paidRoutedReceiptMatches(_job: RouterJobToken){return true;}";
  if (mutation === "scope") route = replace(route, "await routedContentOrg(user.id, preferredOrg(req), routed)", "routed.o");
  if (mutation === "ledger") proof = replace(proof, "const paid = ledger.data;", `const paid = {id:row.cost_ledger_id,org_id:job.o,feature,provider:job.p,model:job.m,total_cents:1,meta:{app_video_reservation_id:row.id,request_id:job.i,billing_org_id:job.o}};`);
  if (mutation === "listing") proof = replace(proof, "(job.l !== undefined && allowance.data.listing_id !== job.l)", "false");
  if (mutation === "released") proof = replace(proof, "row.released_at !== null", "false");
  if (mutation === "task") proof = replace(proof, "row.meta?.task !== job.k", "false");
  if (mutation === "hold") proof = replace(proof, 'hold.state !== "succeeded"', "false");
  if (mutation === "partial") proof = replace(proof, "row.provider_request_id === null && row.cost_ledger_id === null && row.settled_at === null", "row.cost_ledger_id === null");
  if (mutation === "admission") { proof = replace(proof, 'query.eq("idempotency_key",job.a)', "query"); proof = replace(proof, "(job.a && row.idempotency_key !== job.a)", "false"); }
  if (mutation === "repair") route = replace(route, "isExpired(routed) && !await paidRoutedReceiptMatches(routed,true)", "false");
  return await import(dataModule(`
    import {HttpError,assert,json,respondError} from ${JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)};
    import {decodeJobToken,extractJobToken,verifyJobTokenForRecovery,isExpired,type RouterJobToken} from ${JSON.stringify(new URL("../_shared/providers/jobtoken.ts", import.meta.url).href)};
    import {createRoutedOutput} from ${JSON.stringify(new URL("./routed-output.ts", import.meta.url).href)};
    import {asHttpError} from ${JSON.stringify(new URL("../_shared/providers/chain.ts", import.meta.url).href)};
    import type {JobRef,JobState} from ${JSON.stringify(new URL("../_shared/providers/types.ts", import.meta.url).href)};
    export function make(deps:any){
      const adminClient=()=>deps.admin,contentOrgForUser=deps.contentOrg,adapterFor=deps.adapterFor;
      const preferredOrg=(req:Request)=>req.headers.get("x-org-id")||undefined;
      const R2_BUCKET_RENDERS="renders",headObject=deps.head,persistResult=deps.persist,privateMediaUrl=deps.sign;
      const uncheckedDriftBlock=()=>({status:"unchecked",publishable:false});
      // These names belong only to the unchanged unsigned FAL route; this
      // fixture's signed receipts must never fall through to it.
      const requireFalUrl=()=>{throw Error("unexpected unsigned route");},legacyReceiptOrg=requireFalUrl,assertLegacyVideoReceipt=requireFalUrl;
      const fetchBounded=requireFalUrl,falHeaders=requireFalUrl,falCompletedFailure=requireFalUrl,logsTail=requireFalUrl,extractVideoUrl=requireFalUrl,persistedUrl=requireFalUrl;
      const BUDGETS={pollMs:1};
      ${proof}
      ${body("routedContentOrg")}
      ${body("routedStatus")}
      return async(req:Request)=>{const seg=["status"],user={id:deps.actor};try{${route}\nthrow Error("unmatched route");}catch(e){return respondError(e);}};
    }
  `));
}

async function token(options: { expired?: boolean; owner?: string; org?: string; listing?: string; task?: string; noListing?: boolean; admissionKey?: string } = {}) {
  const oldClock = Date.now;
  if (options.expired !== false) Date.now = () => oldClock() - 3 * 60 * 60 * 1000;
  try {
    return await encodeJobToken({p:"fal",m:"fal-ai/synthetic-video",i:"owned-provider-job",u:"https://queue.fal.run/fal-ai/synthetic-video/requests/owned-provider-job/status",t:"2026-10-01T12:00:00.000Z",k:options.task??"video.reel_clip"},
      {orgId:options.org??org,userId:options.owner??actor,...(options.noListing?{}:{listingId:options.listing??listing}),...(options.admissionKey?{admissionKey:options.admissionKey}:{})});
  } finally { Date.now = oldClock; }
}

async function fixture(options: { stored?: boolean; token?: Parameters<typeof token>[0]; mutation?: Mutation; held?: boolean } = {}) {
  Deno.env.set("JOB_TOKEN_SIGNING_SECRET", "synthetic-expired-paid-recovery-secret");
  const raw = await token({...options.token,...(options.held?{admissionKey:"synthetic-original-key"}:{})}), job = await decodeJobToken(raw); assert(job);
  const payments: Row[] = [{id:reservation,org_id:org,actor_id:actor,idempotency_key:"synthetic-original-key",billing_org_id:org,input_sha256:"a".repeat(64),total_cents:30,hold_cents:30,feature:"reel",provider:job.p,model:job.m,provider_request_id:job.i,cost_ledger_id:ledgerID,settled_at:"2026-10-01T12:00:01.000Z",released_at:null,meta:{task:"video.reel_clip"}}];
  const allowances: Row[] = [{reservation_id:reservation,listing_id:listing,drift_refunded_at:null}];
  const ledgers: Row[] = [{id:ledgerID,org_id:org,feature:"reel",provider:job.p,model:job.m,total_cents:30,meta:{app_video_reservation_id:reservation,request_id:job.i,billing_org_id:org,request_key:"synthetic-original-key",stage:"reel"}}];
  const holds: Row[] = [{org_id:org,actor_id:actor,request_key:"synthetic-original-key",stage:"reel",provider:job.p,model:job.m,input_sha256:"a".repeat(64),hold_cents:30,state:"succeeded",ledger_id:null,billing_org_id:org}];
  if(options.held){payments[0].provider_request_id=null;payments[0].cost_ledger_id=null;payments[0].settled_at=null;ledgers.length=0;}
  const outputs: Row[] = [], objects = new Map<string, number>(), queries: string[] = [], rpcCalls: string[] = [];
  let denied = false, resolvedOrg = org, dbError: string | null = null, polls = 0, submissions = 0, persists = 0, signs = 0, permissionReads = 0;
  let state: any = {status:"processing"}, settlementFailure: "error"|"throw"|"noop"|null = null;
  const tables: Record<string, Row[]> = {app_video_cost_reservations:payments,app_video_allowance_receipts:allowances,cost_ledger:ledgers,serving_cost_reservations:holds,private_ai_outputs:outputs};
  const admin = { from(table: string) {
    assert(table in tables); queries.push(table); const filters: ((row: Row) => boolean)[] = [];
    const result = () => ({data:tables[table].filter(row=>filters.every(test=>test(row))),error:dbError===table?{message:"closed read unavailable"}:null});
    const q:any = {select:()=>q,eq:(key:string,value:unknown)=>{filters.push(row=>row[key]===value);return q;},is:(key:string,value:unknown)=>{filters.push(row=>row[key]===value);return q;},in:(key:string,values:unknown[])=>{filters.push(row=>values.includes(row[key]));return q;},limit:async(n:number)=>{const r=result();return {...r,data:r.data.slice(0,n)};},maybeSingle:async()=>{const r=result();return {data:r.data.length===1?r.data[0]:null,error:r.error||(r.data.length>1?{message:"ambiguous row"}:null)};}};
    return q;
  }, rpc:async(name:string,args:Row)=>{
    rpcCalls.push(name);
    if(name==="app_video_cost_settle"){
      assert(permissionReads>0,"fresh library permission must precede accounting repair");
      assertEquals(args,{p_actor:actor,p_org:org,p_key:"synthetic-original-key",p_provider_request_id:job.i});
      if(settlementFailure==="throw")throw Error("lost settlement response");
      if(settlementFailure==="error")return {data:null,error:{message:"settlement unavailable"}};
      if(settlementFailure==="noop")return {data:{settled:true},error:null};
      const row=payments[0];if(row.released_at!==null)return {data:null,error:{message:"released"}};
      if(!row.cost_ledger_id){row.provider_request_id=job.i;row.cost_ledger_id=ledgerID;row.settled_at="2026-10-01T12:00:01.000Z";ledgers.push({id:ledgerID,org_id:org,feature:"reel",provider:job.p,model:job.m,total_cents:30,meta:{app_video_reservation_id:reservation,request_id:job.i,billing_org_id:org,request_key:"synthetic-original-key",stage:"reel"}});holds[0].ledger_id=ledgerID;}
      return {data:{settled:true,ledger_id:ledgerID},error:null};
    }
    assertEquals(name,"register_private_ai_output");
    assertEquals([args.p_user,args.p_org,args.p_listing,args.p_bucket],[actor,org,listing,"renders"]);
    if(denied)return {data:null,error:{message:"current authority withdrawn"}};
    const previous=outputs.find(row=>row.storage_key===args.p_key);
    if(previous && previous.bytes!==args.p_bytes)return {data:null,error:{message:"immutable mismatch"}};
    if(!previous)outputs.push({org_id:org,user_id:actor,listing_id:listing,bucket:"renders",storage_key:args.p_key,bytes:args.p_bytes});
    return {data:{ok:true,key:args.p_key},error:null};
  }};
  if(options.stored){
    const output=await createRoutedOutput({orgId:org,userId:actor,listingId:listing,provider:job.p,model:job.m,requestId:job.i,submittedAt:job.t,kind:job.k},{find:async keys=>outputs.filter(row=>keys.includes(row.storage_key)),register:async(key,bytes)=>{if(!outputs.some(row=>row.storage_key===key))outputs.push({org_id:org,user_id:actor,listing_id:listing,bucket:"renders",storage_key:key,bytes});},head:async()=>({exists:true,bytes:4}),persist:async(_state,key,before)=>{await before({key,bytes:4});objects.set(key,4);return {key,bytes:4};},sign:async()=>"https://fixture.invalid/only-seed"});
    await output.complete({status:"done",result_url:"https://fixture.invalid/seed-only",mime:"video/mp4"});
  }
  const module=await compiled(options.mutation);
  const handler=module.make({admin,actor,contentOrg:async(user:string,preferred:string|undefined,listingID?:string)=>{permissionReads++;assertEquals(user,actor);if(denied)throw new Error("Current permission denied");if(listingID && listingID!==listing)throw new Error("foreign listing");if(preferred && preferred!==org)throw new Error("foreign preferred library");return resolvedOrg;},adapterFor:(provider:string)=>{assertEquals(provider,"fal");return {submit:async()=>{submissions++;throw Error("No generation permitted");},poll:async(ref:Row)=>{polls++;assertEquals([ref.id,ref.provider,ref.model],[job.i,job.p,job.m]);return state;}};},head:async(_bucket:string,key:string)=>({exists:objects.has(key),bytes:objects.get(key)??null}),persist:async(_provider:string,_state:Row,key:string,before:(i:Row)=>Promise<void>)=>{persists++;await before({key,bytes:4});objects.set(key,4);return {key,bytes:4};},sign:async(scope:Row,seconds:number)=>{signs++;assertEquals([scope.actor,scope.org,scope.listing,scope.bucket,seconds],[actor,org,listing,"renders",600]);return "https://fixture.invalid/fresh-private-result";}});
  return {payments,allowances,ledgers,holds,outputs,queries,rpcCalls,job,raw,objects,
    settlementFailure:(value:"error"|"throw"|"noop")=>{settlementFailure=value;},
    deny:()=>{denied=true;},resolveElsewhere:()=>{resolvedOrg=foreign;},dbError:(table:string)=>{dbError=table;},state:(value:Row)=>{state=value;},
    invoke:async(value=raw,preferred=org)=>handler(new Request(`https://fixture.invalid/ai-video/status?status_url=${encodeURIComponent("https://fixture.invalid/ai-video/status?job="+value)}&response_url=${encodeURIComponent("https://fixture.invalid/ai-video/status?job="+value)}`,{headers:{"x-org-id":preferred}})),
    counts:()=>({polls,submissions,persists,signs,permissionReads})};
}

Deno.test("expired signed paid stored output recovers repeatedly with no provider call or settlement",async()=>{
  const f=await fixture({stored:true});
  for(let i=0;i<3;i++){const response=await f.invoke();assertEquals(response.status,200);const result=await response.json();assertEquals(result.status,"completed");assertEquals(result.video_url,"https://fixture.invalid/fresh-private-result");assertEquals(result.persisted,true);assertEquals(result.drift.publishable,false);}
  assertEquals(f.counts(),{polls:0,submissions:0,persists:0,signs:3,permissionReads:3});
  assertEquals(f.outputs.length,1);assertEquals(f.objects.size,1);assert(f.queries.includes("cost_ledger"));
  assert(f.rpcCalls.every(name=>name==="register_private_ai_output"));
});
Deno.test("expired paid QC-rejected receipt keeps stored output recovery after allowance refund",async()=>{
  const f=await fixture({stored:true});f.allowances[0].drift_refunded_at="2026-10-01T12:00:10Z";
  for(let i=0;i<3;i++){const response=await f.invoke();assertEquals(response.status,200);const result=await response.json();assertEquals(result.status,"completed");assertEquals(result.video_url,"https://fixture.invalid/fresh-private-result");}
  assertEquals(f.counts(),{polls:0,submissions:0,persists:0,signs:3,permissionReads:3});
  assertEquals(f.ledgers.length,1);assertEquals(f.payments[0].cost_ledger_id,f.ledgers[0].id);
  assert(f.rpcCalls.every(name=>name==="register_private_ai_output"));
  f.payments[0].released_at="2026-10-01T12:00:11Z";assertEquals((await f.invoke()).status,403);assertEquals(f.counts().signs,3);
});
Deno.test("expired paid receipt without saved bytes only polls its existing job, then stores exactly once",async()=>{
  const f=await fixture();assertEquals((await (await f.invoke()).json()).status,"processing");
  f.state({status:"done",result_url:"https://fixture.invalid/provider-existing",mime:"video/mp4"});
  assertEquals((await (await f.invoke()).json()).status,"completed");
  assertEquals((await (await f.invoke()).json()).status,"completed");
  assertEquals(f.counts(),{polls:2,submissions:0,persists:1,signs:2,permissionReads:3});
  assertEquals(f.outputs.length,1);assertEquals(f.objects.size,1);
});
Deno.test("expired old receipt without embedded listing uses exact allowance listing and current permission",async()=>{
  const f=await fixture({stored:true,token:{noListing:true}});assertEquals((await f.invoke()).status,200);assertEquals(f.counts().polls,0);f.deny();assert((await f.invoke()).status>=400);assertEquals(f.counts().signs,1);
});
Deno.test("unexpired receipt keeps existing transport path without requiring payment lookup",async()=>{
  const f=await fixture({token:{expired:false}});f.payments.length=0;f.ledgers.length=0;
  assertEquals((await (await f.invoke()).json()).status,"processing");assert(!f.queries.includes("cost_ledger"));assertEquals(f.counts().submissions,0);
});

const deniedCases: [string,(f:Awaited<ReturnType<typeof fixture>>)=>void][] = [
  ["missing reservation",f=>{f.payments.length=0;}], ["ambiguous reservation",f=>{f.payments.push({...f.payments[0]});}],
  ["unpaid reservation",f=>{f.payments[0].cost_ledger_id=null;f.payments[0].settled_at=null;}],
  ["cancelled or rejected reservation",f=>{f.payments[0].released_at=new Date().toISOString();}],
  ["different task",f=>{f.payments[0].meta.task="video.aerial";}], ["wrong feature",f=>{f.payments[0].feature="aerial";}],
  ["foreign actor",f=>{f.payments[0].actor_id=foreign;}], ["foreign org",f=>{f.payments[0].org_id=foreign;}],
  ["different model",f=>{f.payments[0].model="other";}], ["different provider",f=>{f.payments[0].provider="kie";}],
  ["different request",f=>{f.payments[0].provider_request_id="other-job";}],
  ["missing allowance",f=>{f.allowances.length=0;}], ["foreign allowance listing",f=>{f.allowances[0].listing_id=foreign;}],
  ["missing ledger",f=>{f.ledgers.length=0;}], ["foreign ledger",f=>{f.ledgers[0].org_id=foreign;}],
  ["ledger model mismatch",f=>{f.ledgers[0].model="other";}], ["ledger provider mismatch",f=>{f.ledgers[0].provider="kie";}],
  ["zero charge",f=>{f.ledgers[0].total_cents=0;}], ["ledger receipt mismatch",f=>{f.ledgers[0].meta.app_video_reservation_id=foreign;}],
  ["ledger request mismatch",f=>{f.ledgers[0].meta.request_id="other-job";}],
  ["withdrawn listing permission",f=>{f.deny();}], ["resolved foreign library",f=>{f.resolveElsewhere();}],
];
for(const [name,change]of deniedCases)Deno.test(`expired recovery refuses ${name} before result signing/provider work`,async()=>{
  const f=await fixture({stored:true});change(f);assert((await f.invoke()).status>=400);
  assertEquals(f.counts().polls,0);assertEquals(f.counts().submissions,0);assertEquals(f.counts().signs,0);assertEquals(f.counts().persists,0);
});
Deno.test("foreign or tampered signed receipt cannot reach payment, media or provider boundaries",async()=>{
  for(const options of [{owner:foreign},{org:foreign},{listing:foreign},{task:"video.unknown"}]){const f=await fixture({stored:true,token:options});assert((await f.invoke()).status>=400);assertEquals(f.counts().signs,0);assertEquals(f.counts().polls,0);}
  const f=await fixture({stored:true});const [payload,mac]=f.raw.split(".");const parsed=JSON.parse(atob(payload.replace(/-/g,"+").replace(/_/g,"/")));parsed.i="unpaid-job";
  const altered=btoa(JSON.stringify(parsed)).replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_")+"."+mac;
  assertEquals((await f.invoke(altered)).status,403);assertEquals(f.queries.length,0);assertEquals(f.counts().signs,0);assertEquals(f.counts().polls,0);
});
Deno.test("failed payment reads retain retriable failure instead of treating missing proof as paid",async()=>{
  for(const table of ["app_video_cost_reservations","app_video_allowance_receipts","cost_ledger"]){const f=await fixture({stored:true});f.dbError(table);assertEquals((await f.invoke()).status,503);assertEquals(f.counts().signs,0);assertEquals(f.counts().polls,0);}
});
Deno.test("current library and media withdrawal blocks an expired paid stored output",async()=>{
  const f=await fixture({stored:true});assert((await f.invoke(f.raw,foreign)).status>=400);assertEquals(f.counts().signs,0);assertEquals(f.counts().polls,0);
  f.outputs[0].user_id=foreign;assertEquals((await (await f.invoke()).json()).status,"processing");assertEquals(f.counts().signs,0);assertEquals(f.counts().persists,0);
});

for(const [mutation,change]of [
  ["proof",(f:any)=>{f.payments.length=0;}], ["scope",(f:any)=>{f.deny();}],
  ["ledger",(f:any)=>{f.ledgers.length=0;}], ["listing",(f:any)=>{f.allowances[0].listing_id=foreign;}],
  ["released",(f:any)=>{f.payments[0].released_at=new Date().toISOString();}], ["task",(f:any)=>{f.payments[0].meta.task="video.aerial";}],
] as [Mutation,(f:any)=>void][])Deno.test(`negative control detects removed ${mutation} recovery guard`,async()=>{
  const f=await fixture({stored:mutation!=="scope",mutation});change(f);
  const response=await f.invoke();
  // Every paired unmutated case above refuses before the provider/signing
  // boundary. The deliberate removal must demonstrably over-admit instead.
  if(mutation==="scope"){assertEquals(response.status,200);assertEquals(f.counts().polls,1);}
  else{assertEquals(response.status,200);assertEquals(f.counts().signs,1);}
  assertEquals(f.counts().submissions,0);
});


Deno.test("expired signed accepted admission repairs its retained hold once then polls only the original job",async()=>{
  const f=await fixture({held:true});
  for(let i=0;i<2;i++)assertEquals((await (await f.invoke()).json()).status,"processing");
  f.state({status:"done",result_url:"https://fixture.invalid/already-accepted",mime:"video/mp4"});
  assertEquals((await (await f.invoke()).json()).status,"completed");
  assertEquals((await (await f.invoke()).json()).status,"completed");
  assertEquals(f.rpcCalls.filter(name=>name==="app_video_cost_settle").length,1);
  assertEquals(f.ledgers.length,1);assertEquals(f.payments[0].provider_request_id,f.job.i);
  assertEquals(f.payments[0].cost_ledger_id,f.ledgers[0].id);assertEquals(f.holds[0].ledger_id,f.ledgers[0].id);
  assertEquals(f.counts().submissions,0);assertEquals(f.counts().persists,1);assertEquals(f.counts().polls,3);
});
Deno.test("expired accepted admission with retained output repairs accounting before private result access",async()=>{
  const f=await fixture({held:true,stored:true});
  assertEquals((await (await f.invoke()).json()).status,"completed");
  assertEquals(f.counts().polls,0);assertEquals(f.counts().submissions,0);assertEquals(f.counts().signs,1);
  assertEquals(f.rpcCalls.filter(name=>name==="app_video_cost_settle").length,1);assertEquals(f.ledgers.length,1);
});
const heldDenials:[string,(f:Awaited<ReturnType<typeof fixture>>)=>void][]=[
  ["missing held admission",f=>{f.holds.length=0;}],
  ["ambiguous held admission",f=>{f.holds.push({...f.holds[0]});}],
  ["foreign held actor",f=>{f.holds[0].actor_id=foreign;}],
  ["foreign held org",f=>{f.holds[0].org_id=foreign;}],
  ["wrong held provider",f=>{f.holds[0].provider="kie";}],
  ["wrong held model",f=>{f.holds[0].model="other";}],
  ["wrong held stage",f=>{f.holds[0].stage="aerial";}],
  ["wrong held request key",f=>{f.holds[0].request_key="other-admission";}],
  ["wrong admission key",f=>{f.payments[0].idempotency_key="other-admission";}],
  ["mismatched held input",f=>{f.holds[0].input_sha256="b".repeat(64);}],
  ["rejected held admission",f=>{f.holds[0].state="rejected";}],
  ["unconfirmed held admission",f=>{f.holds[0].state="uncertain";}],
  ["unconfirmed serving journal",f=>{f.holds[0].state="reserved";}],
  ["released video admission",f=>{f.payments[0].released_at="2026-10-01T12:00:01Z";}],
  ["wrong held billing org",f=>{f.holds[0].billing_org_id=foreign;}],
  ["already bound foreign held ledger",f=>{f.holds[0].ledger_id=foreign;}],
  ["insufficient retained hold",f=>{f.holds[0].hold_cents=1;}],
  ["invalid priced video hold",f=>{f.payments[0].hold_cents=1;}],
  ["foreign allowance",f=>{f.allowances[0].listing_id=foreign;}],
  ["partial provider binding",f=>{f.payments[0].provider_request_id="other-job";}],
  ["partial ledger binding",f=>{f.payments[0].cost_ledger_id=foreign;}],
  ["partial settlement timestamp",f=>{f.payments[0].settled_at="2026-10-01T12:00:01Z";}],
  ["withdrawn current listing authority",f=>{f.deny();}],
];
for(const[name,change]of heldDenials)Deno.test(`expired accepted admission refuses ${name} without cost repair/provider access`,async()=>{
  const f=await fixture({held:true,stored:true});change(f);assert((await f.invoke()).status>=400);
  assertEquals(f.rpcCalls.filter(name=>name==="app_video_cost_settle").length,0);
  assertEquals(f.counts().polls,0);assertEquals(f.counts().submissions,0);assertEquals(f.counts().signs,0);
});
Deno.test("old expired unsettled receipt cannot infer an admission from provider or time",async()=>{
  const f=await fixture({stored:true});f.payments[0].provider_request_id=null;f.payments[0].cost_ledger_id=null;f.payments[0].settled_at=null;f.ledgers.length=0;
  assertEquals((await f.invoke()).status,403);assertEquals(f.counts().polls,0);assertEquals(f.counts().signs,0);assertEquals(f.rpcCalls.length,0);
});
for(const failure of["error","throw","noop"]as const)Deno.test(`failed accepted admission repair ${failure} cannot unlock results`,async()=>{
  const f=await fixture({held:true,stored:true});f.settlementFailure(failure);
  assert((await f.invoke()).status>=400);assertEquals(f.counts().polls,0);assertEquals(f.counts().signs,0);assertEquals(f.ledgers.length,0);assertEquals(f.counts().submissions,0);
});
Deno.test("expired accepted admission journal read failure is retriable before settlement or provider",async()=>{
  const f=await fixture({held:true});f.dbError("serving_cost_reservations");assertEquals((await f.invoke()).status,503);assertEquals(f.rpcCalls.length,0);assertEquals(f.counts().polls,0);
});
for(const[mutation,change]of[
  ["hold",(f:any)=>{f.holds[0].state="rejected";}],
  ["partial",(f:any)=>{f.payments[0].provider_request_id="other-job";}],
  ["admission",(f:any)=>{f.payments[0].idempotency_key="other-admission";}],
  ["repair",(_f:any)=>{}],
]as[Mutation,(f:any)=>void][])Deno.test(`negative control detects removed ${mutation} accepted recovery guard`,async()=>{
  const f=await fixture({held:true,stored:true,mutation});change(f);
  assertEquals((await f.invoke()).status,200);assertEquals(f.counts().signs,1);
  if(mutation==="repair"){assertEquals(f.ledgers.length,0);assertEquals(f.rpcCalls.filter(name=>name==="app_video_cost_settle").length,0);}
  else assertEquals(f.rpcCalls.filter(name=>name==="app_video_cost_settle").length,1);
  assertEquals(f.counts().submissions,0);
});
