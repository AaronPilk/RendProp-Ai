// Execute the actual legacy GET/status route, isolating auth/storage/HTTP only.
// No credentials, live calls, provider charges or quota writes.
import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
const encode = (s: string) =>
  `data:application/typescript;base64,${
    btoa(String.fromCharCode(...new TextEncoder().encode(s)))
  }`;
const functionBody = (source: string, name: string) => {
  const start = source.indexOf(`function ${name}(`),
    end = source.indexOf("\n}\n", start);
  assert(start >= 0 && end > start);
  return source.slice(start, end + 3);
};
async function fixture(skipTerminalCheck = false, enforceReceipt = false, skipReceipt = false) {
  const source = await Deno.readTextFile(
    new URL("./index.ts", import.meta.url),
  );
  const start = source.indexOf(
    '    if (req.method === "GET" && seg.length === 1 && seg[0] === "status")',
  );
  const end = source.indexOf("\n    throw new HttpError(405,", start);
  assert(start > 0 && end > start);
  let route = source.slice(start, end);
  if (skipTerminalCheck) {
    route = route.replace(
      "const terminalFailure = falCompletedFailure(st);",
      "const terminalFailure = null;",
    );
  }
  if (skipReceipt) {
    const gate="await assertLegacyVideoReceipt(user.id, await orgForUser(user.id, preferredOrg(req)), statusUrl, responseUrl);";
    assertEquals(route.split(gate).length,2);
    route=route.replace(gate,"");
  }
  const module = `
  import {HttpError,assert,json,respondError} from ${
    JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)
  };
  import {BUDGETS,fetchBounded} from ${
    JSON.stringify(
      new URL("../_shared/providers/common.ts", import.meta.url).href,
    )
  };
  import {falCompletedFailure} from ${
    JSON.stringify(new URL("../_shared/providers/fal.ts", import.meta.url).href)
  };
  const extractJobToken=()=>null, falHeaders=()=>({Authorization:"Key synthetic-test-placeholder"});
  const uncheckedDriftBlock=()=>({status:"unchecked",publishable:false});
  const orgForUser=async()=>"synthetic-org";
  const adminClient=()=>({from:()=>{const q:any={select:()=>q,eq:()=>q,limit:async()=>({data:[],error:null})};return q;}});
  ${enforceReceipt ? "async "+functionBody(source,"assertLegacyVideoReceipt") : "const assertLegacyVideoReceipt=async()=>{};"}
  const preferredOrg=()=>undefined, verifyJobToken=orgForUser,routedStatus=orgForUser;
  ${functionBody(source, "requireFalUrl")}
  ${functionBody(source, "extractVideoUrl")}
  ${functionBody(source, "logsTail")}
  export async function handler(req:Request){const seg=["status"],user={id:"synthetic"};try{${route}\nthrow new Error("Route did not match");}catch(e){return respondError(e);}}
  `;
  return await import(encode(module));
}
const statusURL =
  "https://queue.fal.run/fal-ai/synthetic/requests/synthetic-job/status";
const resultURL =
  "https://queue.fal.run/fal-ai/synthetic/requests/synthetic-job";
const request = () =>
  new Request(
    `https://fixture.invalid/ai-video/status?status_url=${
      encodeURIComponent(statusURL)
    }&response_url=${encodeURIComponent(resultURL)}`,
  );
const privateMarker = "synthetic-private-prompt-key-and-url-marker";
async function run(
  statusBody: unknown,
  resultStatus = 200,
  resultBody: unknown = { video: { url: "https://cdn.invalid/synthetic.mp4" } },
  mutation = false,
) {
  const f = await fixture(mutation),
    actual = globalThis.fetch,
    log = console.error;
  const calls: string[] = [], logs: unknown[][] = [];
  globalThis.fetch = ((url: string | URL | Request) => {
    const address = String(url);
    calls.push(address);
    return Promise.resolve(
      address.includes("/status")
        ? Response.json(statusBody)
        : Response.json(resultBody, { status: resultStatus }),
    );
  }) as typeof fetch;
  console.error = (...v: unknown[]) => logs.push(v);
  try {
    const response = await f.handler(request()), body = await response.json();
    assert(!JSON.stringify(body).includes(privateMarker));
    assert(!JSON.stringify(logs).includes(privateMarker));
    return { body, calls, logs, status: response.status };
  } finally {
    globalThis.fetch = actual;
    console.error = log;
  }
}
Deno.test("actual legacy status COMPLETED+error returns failed without fetching result", async () => {
  const r = await run({ status: "COMPLETED", error: privateMarker });
  assertEquals(r.status, 200);
  assertEquals(r.body.status, "failed");
  assertEquals(r.calls.length, 1);
});
Deno.test("actual legacy status COMPLETED+error_type returns failed without fetching result", async () => {
  const r = await run({ status: "COMPLETED", error_type: "INTERNAL_ERROR" });
  assertEquals(r.body.status, "failed");
  assertEquals(r.calls.length, 1);
});
for (const status of [422]) {
  Deno.test(`actual legacy completed result HTTP${status} is failed rather than thrown502`, async () => {
    const r = await run({ status: "COMPLETED" }, status, {
      detail: privateMarker,
    });
    assertEquals(r.status, 200);
    assertEquals(r.body.status, "failed");
    assertEquals(r.body.provider_status, status);
    assertEquals(r.calls.length, 2);
  });
}
for (const status of [408, 429, 500, 503]) {
  Deno.test(`actual legacy completed result HTTP${status} preserves saved-request recovery`, async () => {
    const r = await run({status:"COMPLETED"},status,{detail:privateMarker});
    assertEquals(r.status,502);
    assertEquals(r.body.provider_status,status);
    assertEquals(r.body.failure_phase,"result");
    assertEquals(r.body.retry_existing_job,true);
    assertEquals(r.calls.length,2);
    assertEquals((r.logs[0][1] as Record<string,unknown>).provider_status,status);
    assert(!Object.hasOwn(r.body,"status"),"Do not turn transient retrieval into terminal failed");
  });
}
Deno.test("actual legacy failed safety job retains classification without a raw reason", async () => {
  const r=await run({status:"FAILED",error_type:"SAFETY_CHECK_FAILED",error:privateMarker});
  assertEquals(r.body.status,"failed");
  assertEquals(r.body.error_class,"nsfw");
  assertEquals(r.body.failure_phase,"generation");
  assertEquals(r.calls.length,1);
});

Deno.test("actual routed status maps poll failure to sanitized recoverable HTTP facts", async () => {
  const source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
  const module=await import(encode(`
    import {HttpError,json,respondError} from ${JSON.stringify(new URL("../_shared/http.ts",import.meta.url).href)};
    import {asHttpError} from ${JSON.stringify(new URL("../_shared/providers/chain.ts",import.meta.url).href)};
    import {ProviderError} from ${JSON.stringify(new URL("../_shared/providers/common.ts",import.meta.url).href)};
    import {createRoutedOutput} from ${JSON.stringify(new URL("./routed-output.ts",import.meta.url).href)};
    type RouterJobToken=any;type JobRef=any;type JobState=any;
    const adapterFor=()=>({poll:async()=>{throw new ProviderError("fal","rate_limit",${JSON.stringify(privateMarker)},429);}});
    const adminClient=()=>({from:()=>{const q:any={select:()=>q,eq:()=>q,is:()=>q,in:()=>q,limit:async()=>({data:[],error:null})};return q;}});
    const routedR2Key=()=>{throw Error("No persist after poll failure");},persistedUrl=routedR2Key,uncheckedDriftBlock=routedR2Key;
    async ${functionBody(source,"routedStatus")}
    export async function run(){try{return await routedStatus("synthetic-org",{p:"fal",m:"synthetic-model",i:"id",u:"synthetic-url",t:"now"});}catch(e){return respondError(e);}}
  `));
  const before=console.error,logs:unknown[][]=[];console.error=(...v:unknown[])=>logs.push(v);
  try {
    const response=await module.run(),body=await response.json();
    assertEquals(response.status,429);
    assertEquals(body.provider_status,429);
    assertEquals(body.error_class,"rate_limit");
    assert(!JSON.stringify(body).includes(privateMarker));
    assert(!JSON.stringify(logs).includes(privateMarker));
  } finally {console.error=before;}
});

Deno.test("actual routed signed-result persistence failure retries the same completed job without submit", async () => {
  const source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
  const module=await import(encode(`
    import {HttpError,json,respondError} from ${JSON.stringify(new URL("../_shared/http.ts",import.meta.url).href)};
    import {asHttpError} from ${JSON.stringify(new URL("../_shared/providers/chain.ts",import.meta.url).href)};
    import {createRoutedOutput} from ${JSON.stringify(new URL("./routed-output.ts",import.meta.url).href)};
    type RouterJobToken=any;type JobRef=any;type JobState=any;
    export const counts={polls:0,persists:0,submits:0};
    const adapterFor=()=>({poll:async()=>{counts.polls++;return {status:"done",mime:"video/mp4",result_url:"https://private.invalid/clip?token=${privateMarker}"};}});
    let row:any=null,stored=false;
    const adminClient=()=>({from:(table:string)=>{const q:any={select:()=>q,eq:()=>q,is:()=>q,in:()=>q,limit:async()=>({data:table==="private_ai_outputs"&&row?[row]:[],error:null})};return q;},rpc:async(_n:any,args:any)=>{row={org_id:args.p_org,user_id:args.p_user,listing_id:args.p_listing,bucket:args.p_bucket,storage_key:args.p_key,bytes:args.p_bytes};return{data:{ok:true,key:args.p_key},error:null};}});
    const R2_BUCKET_RENDERS="rendprop-renders";
    const headObject=async()=>({exists:stored,bytes:stored?10:null});
    const persistResult=async(_provider:any,_state:any,key:any,beforeWrite:any)=>{counts.persists++;await beforeWrite({key,bytes:10});if(counts.persists===1)throw Error(${JSON.stringify(privateMarker)});stored=true;return {key,bytes:10};};
    const routedR2Key=()=>"synthetic-destination",persistedUrl=()=>"https://public.invalid/retained.mp4",uncheckedDriftBlock=()=>({publishable:false});
    async ${functionBody(source,"routedStatus")}
    export async function run(){try{return await routedStatus("synthetic-org",{p:"fal",m:"synthetic-model",i:"same-job",u:"synthetic-url",t:"now",usr:"synthetic-actor"});}catch(e){return respondError(e);}}
  `));
  const before=console.error,logs:unknown[][]=[];console.error=(...v:unknown[])=>logs.push(v);
  try {
    const first=await module.run(),error=await first.json();
    assertEquals(first.status,503);
    assertEquals(error.retry_existing_job,true);
    assertEquals(error.failure_phase,"persistence");
    assert(!Object.hasOwn(error,"status"));
    const second=await module.run(),done=await second.json();
    assertEquals(second.status,200);assertEquals(done.status,"completed");
    assertEquals(done.video_url,"https://public.invalid/retained.mp4");
    assertEquals(module.counts,{polls:2,persists:2,submits:0});
    assert(!JSON.stringify([error,done,logs]).includes(privateMarker));
  } finally {console.error=before;}
});
Deno.test("actual legacy completed result body with error is failed", async () => {
  const r = await run({ status: "COMPLETED" }, 200, { error: privateMarker });
  assertEquals(r.body.status, "failed");
});
Deno.test("actual legacy missing output is a terminal failed state", async () => {
  const r = await run({ status: "COMPLETED" }, 200, { detail: privateMarker });
  assertEquals(r.body.status, "failed");
});
Deno.test("actual legacy normal success and processing envelopes survive", async () => {
  const done = await run({ status: "COMPLETED" });
  assertEquals(done.body.status, "completed");
  assertEquals(done.body.video_url, "https://cdn.invalid/synthetic.mp4");
  assertEquals(done.body.drift.publishable, false);
  for (const status of ["IN_QUEUE", "IN_PROGRESS"]) {
    const pending = await run({ status, queue_position: 2 });
    assertEquals(pending.body.status, "processing");
    assertEquals(pending.calls.length, 1);
  }
});
Deno.test("actual legacy terminal-check removal is caught by the same no-result-fetch invariant", async () => {
  const mutated = await run(
    { status: "COMPLETED", error: privateMarker },
    200,
    { video: { url: "https://cdn.invalid/synthetic.mp4" } },
    true,
  );
  assertEquals(mutated.body.status, "completed");
  assertEquals(mutated.calls.length, 2);
  assert(
    mutated.body.status !== "failed" && mutated.calls.length !== 1,
    "Control must violate the production terminal-failure contract",
  );
});

Deno.test("legacy URL possession requires an exact actor workspace provider model and paid receipt mapping", async () => {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  const module = await import(encode(`
    import {HttpError,assert} from ${JSON.stringify(new URL("../_shared/http.ts",import.meta.url).href)};
    export const state:any={exists:true,calls:[]};
    const adminClient=()=>({from:(table:string)=>{state.calls.push([table]);const q:any={select:(v:any)=>{state.calls.push(["select",v]);return q;},eq:(k:any,v:any)=>{state.calls.push([k,v]);return q;},limit:async()=>({data:state.exists?[{id:"owned"}]:[],error:null})};return q;}});
    async ${functionBody(source,"assertLegacyVideoReceipt")}
    export {assertLegacyVideoReceipt};
  `));
  await module.assertLegacyVideoReceipt("actor", "org", statusURL, resultURL);
  assertEquals(module.state.calls, [["app_video_cost_reservations"],["select","id"],["org_id","org"],["actor_id","actor"],["provider","fal"],["model","fal-ai/synthetic"],["provider_request_id","synthetic-job"]]);
  module.state.exists=false;
  await assertRejects(()=>module.assertLegacyVideoReceipt("foreign-actor", "org", statusURL, resultURL), Error, "verified account recovery");
  module.state.calls=[];
  await assertRejects(()=>module.assertLegacyVideoReceipt("actor", "org", statusURL, resultURL.replace("synthetic-job","another-job")), Error, "verified account recovery");
  assertEquals(module.state.calls.length,0);
});

async function legacyDenialBoundary(skipReceipt=false){
  const m=await fixture(false,true,skipReceipt),before=globalThis.fetch;let fetches=0;
  globalThis.fetch=(()=>{fetches++;return Promise.resolve(Response.json({status:"IN_PROGRESS"}));}) as typeof fetch;
  try{
    const response=await m.handler(request());
    assertEquals(response.status,403,"unmapped legacy URLs must fail before any credentialed provider fetch");
    assertEquals(fetches,0,"unmapped legacy URLs must fail before any credentialed provider fetch");
  }finally{globalThis.fetch=before;}
}
Deno.test("actual status route denies unmapped legacy URLs before provider transport",async()=>{await legacyDenialBoundary();});
Deno.test("compiled removed legacy receipt gate fails the same no-provider-fetch boundary",async()=>{
  await assertRejects(()=>legacyDenialBoundary(true),Error,"unmapped legacy URLs must fail before any credentialed provider fetch");
});

async function routedJournalFixture(skipRefusal=false){
  const source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
  let method=functionBody(source,"routedStatus");
  if(skipRefusal){
    const gate='if(error || data?.ok!==true || data.key!==key) throw new Error("Video output could not be journaled");';
    assertEquals(method.split(gate).length,2);method=method.replace(gate,"");
  }
  return await import(encode(`
    // ${crypto.randomUUID()}
    import {HttpError,json,respondError} from ${JSON.stringify(new URL("../_shared/http.ts",import.meta.url).href)};
    import {asHttpError} from ${JSON.stringify(new URL("../_shared/providers/chain.ts",import.meta.url).href)};
    import {createRoutedOutput} from ${JSON.stringify(new URL("./routed-output.ts",import.meta.url).href)};
    type RouterJobToken=any;type JobRef=any;type JobState=any;
    export const state:any={puts:0,rpc:[]};
    const adapterFor=()=>({poll:async()=>({status:"done",mime:"video/mp4",result_url:"https://cdn.invalid/complete.mp4"})});
    const adminClient=()=>({from:()=>{const q:any={select:()=>q,eq:()=>q,is:()=>q,in:()=>q,limit:async()=>({data:[],error:null})};return q;},rpc:async(n:any,args:any)=>{state.rpc.push([n,args]);return {data:null,error:{message:"deleted-scope"}};}});
    const persistResult=async(_provider:any,_state:any,key:any,beforeWrite:any)=>{await beforeWrite({key,bytes:123});state.puts++;return {key,bytes:123};};
    const routedR2Key=()=>"ai-router/scoped-org/reel/immutable.mp4",persistedUrl=()=>"https://public.invalid/saved.mp4",uncheckedDriftBlock=()=>({publishable:false});
    async ${method}
    export async function run(){try{return await routedStatus("scoped-org",{p:"fal",m:"model",i:"accepted-job",u:"poll-url",t:"now",usr:"signed-actor",l:"fa300505-0000-4000-8000-000000000011"});}catch(e){return respondError(e);}}
  `));
}
async function assertRoutedJournalDenial(skipRefusal=false){
  const m=await routedJournalFixture(skipRefusal),before=console.error;console.error=()=>{};
  try{
    const response=await m.run(),body=await response.json();
    assertEquals(response.status,503,"journal refusal must retain the saved job without an object write");
    assertEquals(body.retry_existing_job,true);
    assertEquals(m.state.puts,0,"journal refusal must retain the saved job without an object write");
    assertEquals(m.state.rpc.length,1);const [name,args]=m.state.rpc[0];assertEquals(name,"register_private_ai_output");assert(/^ai-router\/scoped-org\/completed-video\/[a-f0-9]{64}\.mp4$/.test(args.p_key));assertEquals({...args,p_key:undefined},{p_user:"signed-actor",p_org:"scoped-org",p_listing:"fa300505-0000-4000-8000-000000000011",p_bucket:"renders",p_key:undefined,p_bytes:123});
  }finally{console.error=before;}
}
Deno.test("actual routed status binds signed admission scope and fails closed before PUT on journal refusal",async()=>{await assertRoutedJournalDenial();});
Deno.test("compiled ignored journal refusal fails the same saved-job no-write boundary",async()=>{
  await assertRejects(()=>assertRoutedJournalDenial(true),Error,"journal refusal must retain the saved job without an object write");
});
