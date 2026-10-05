// Execute the actual legacy GET/status route, isolating auth/storage/HTTP only.
// No credentials, live calls, provider charges or quota writes.
import {
  assert,
  assertEquals,
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
async function fixture(skipTerminalCheck = false) {
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
  const orgForUser=async()=>{throw new Error("Routed status must not be reached");};
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
    type RouterJobToken=any;type JobRef=any;type JobState=any;
    const adapterFor=()=>({poll:async()=>{throw new ProviderError("fal","rate_limit",${JSON.stringify(privateMarker)},429);}});
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
    type RouterJobToken=any;type JobRef=any;type JobState=any;
    export const counts={polls:0,persists:0,submits:0};
    const adapterFor=()=>({poll:async()=>{counts.polls++;return {status:"done",mime:"video/mp4",result_url:"https://private.invalid/clip?token=${privateMarker}"};},
      persist:async()=>{counts.persists++;if(counts.persists===1)throw Error(${JSON.stringify(privateMarker)});return {key:"synthetic-retained"};}});
    const routedR2Key=()=>"synthetic-destination",persistedUrl=()=>"https://public.invalid/retained.mp4",uncheckedDriftBlock=()=>({publishable:false});
    async ${functionBody(source,"routedStatus")}
    export async function run(){try{return await routedStatus("synthetic-org",{p:"fal",m:"synthetic-model",i:"same-job",u:"synthetic-url",t:"now"});}catch(e){return respondError(e);}}
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
