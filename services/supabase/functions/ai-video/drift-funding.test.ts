import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { beginDriftCheck, finishDriftCheck } from "./drift-funding.ts";
import { FundingAdmissionError } from "../_shared/funded-serving.ts";
import { HttpError } from "../_shared/http.ts";

const id = (n: number) => `c0680001-0000-4000-8000-${String(n).padStart(12, "0")}`;
function fixture() {
  let ordinal = 0, running = false, terminal: Record<string, unknown> | null = null;
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const rpc = async (name: string, args: Record<string, unknown>) => {
    calls.push({ name, args });
    if (name === "app_video_drift_check_begin") {
      if (terminal) return { data: { id: id(ordinal), replay: true, result: terminal }, error: null };
      if (running) return { data: null, error: { message: "RP409: This quality check is already running" } };
      running = true; return { data: { id: id(++ordinal), replay: false }, error: null };
    }
    if (name === "serving_operation_begin") return { data: { begun: true }, error: null };
    if (name === "app_video_drift_check_finish") {
      assertEquals(args.p_check, id(ordinal)); running = false;
      if (args.p_action !== "hold") terminal = args.p_result as Record<string, unknown>;
      return { data: true, error: null };
    }
    throw new Error(`Unmodeled RPC ${name}`);
  };
  const args = { actor: id(90), orgId: id(91), requestId: "owned-paid-clip", kind: "reel" as const,
    sourceHash: "a".repeat(32), listingId: id(92), req: new Request("https://fixture.invalid/ai-video/drift", {
      method: "POST", headers: { "Idempotency-Key": "drift:owned-paid-clip:0", "x-org-id": id(91) } }),
    input: { frames: ["frame-one"] }, rpc };
  return { args, calls, rpc };
}
Deno.test("actual drift funding uses server identity: held recheck accepts changed frames and retains prior operation", async () => {
  const f = fixture(), first = await beginDriftCheck(f.args);
  assertEquals(first.funding!.requestKey, `drift-check:${id(1)}`);
  await finishDriftCheck(f.rpc, f.args.actor, f.args.orgId, first.id, "hold", null);
  const second = await beginDriftCheck({ ...f.args, input: { frames: ["re-decoded-frame"] } });
  assertEquals(second.funding!.requestKey, `drift-check:${id(2)}`);
  const operations = f.calls.filter(c => c.name === "serving_operation_begin");
  assertEquals(operations.length, 2);
  assert(operations[0].args.p_input_sha256 !== operations[1].args.p_input_sha256);
  assert(!f.calls.some(c => /release|refund|no_dispatch/.test(c.name)));
});
Deno.test("actual drift funding stops simultaneous check before a second funding operation", async () => {
  const f = fixture(); await beginDriftCheck(f.args);
  const error = await assertRejects(() => beginDriftCheck(f.args), HttpError);
  assertEquals(error.status, 409);
  assertEquals(f.calls.filter(c => c.name === "serving_operation_begin").length, 1);
});
Deno.test("actual drift funding returns saved terminal refusal without a new operation", async () => {
  const f = fixture(), first = await beginDriftCheck(f.args);
  const saved = { drift: { action: "refuse", publishable: false } };
  await finishDriftCheck(f.rpc, f.args.actor, f.args.orgId, first.id, "refuse", saved);
  const recovered = await beginDriftCheck(f.args);
  assertEquals(recovered.replay, saved); assertEquals(recovered.funding, null);
  assertEquals(f.calls.filter(c => c.name === "serving_operation_begin").length, 1);
});
Deno.test("actual funding refusal leaves a recheckable HOLD and exposes the true quota cause", async () => {
  const f = fixture(); let denied = true;
  const rpc: typeof f.rpc = async (name, args) => name === "serving_operation_begin" && denied
    ? { data: null, error: { message: "RP402: AI usage limit reached [kind=trial] (500 of 500 cents this period)" } }
    : f.rpc(name, args);
  const error = await assertRejects(() => beginDriftCheck({ ...f.args, rpc }), FundingAdmissionError);
  assertEquals(error.code, "quota_exceeded"); assert(error.message.includes("trial's AI allowance"));
  assertEquals(f.calls.at(-1)?.args.p_action, "hold");
  denied = false; const next = await beginDriftCheck({ ...f.args, rpc });
  assertEquals(next.funding!.requestKey, `drift-check:${id(2)}`);
  assert(!f.calls.some(c => /cost_reserve|judge|release|refund/.test(c.name)));
});
Deno.test("malformed journal reply and failed result save fail closed", async () => {
  const f = fixture();
  await assertRejects(() => beginDriftCheck({ ...f.args, rpc: async () => ({ data: { id: "caller-nonce" }, error: null }) }), HttpError);
  assertEquals(f.calls.length, 0);
  await assertRejects(() => finishDriftCheck(async () => ({ data: false, error: null }),
    f.args.actor, f.args.orgId, id(1), "hold", null), HttpError);
});
Deno.test("actual judge funding refusal is not rewritten as a provider outage", async () => {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  const start = source.indexOf("async function judgeDrift("), end = source.indexOf("\n}\n", start);
  assert(start > 0 && end > start);
  const module = await import("data:application/typescript;base64," + btoa(`
    import {FundingAdmissionError} from ${JSON.stringify(new URL("../_shared/funded-serving.ts", import.meta.url).href)};
    import {unavailableVerdict} from ${JSON.stringify(new URL("../_shared/drift.ts", import.meta.url).href)};
    type DriftImage=any;type DriftFrame=any;type FundingContext=any;type JudgeOutcome=any;type DriftPart=any;type ChainResult<T>=any;
    const driftLineageKey=async()=>"a".repeat(32),driftRubric=()=>"rubric",DRIFT_SOURCE_LABEL="source",DRIFT_TASK="qc",DRIFT_MAX_TOKENS=500,DRIFT_SOURCE_EXTRA_INPUT_TOKENS=2048;
    const driftFramesLabel=()=>"frames",driftChain=async()=>[{}],visionInputTokenBound=()=>8192;
    const runChain=async(_task:any,_steps:any,attempt:any)=>attempt(_steps[0]);
    const textAttemptQuote=()=>({cents:3}),callJudgeStep=()=>{throw Error("unreachable judge");};
    const fundedAttempt=async(funding:any)=>{throw funding.error;};
    const parseDriftVerdict=()=>{throw Error("unreachable parser");},ESCALATE_BELOW_CONFIDENCE=.8;
    ${source.slice(start,end+3)}
    export {judgeDrift};
  `));
  const args = { plan: "pro", subject: {kind:"reel",sceneNoun:"home",motionText:null},source:{b64:"source",mime:"image/jpeg"},frames:[],
    funding:{error:new FundingAdmissionError(402,"Your trial's AI allowance is used up.","quota_exceeded")} };
  await assertRejects(() => module.judgeDrift(args), FundingAdmissionError);
  const held = await module.judgeDrift({...args,funding:{error:new Error("provider unavailable")}});
  assertEquals(held.verdict.unavailable,true); assertEquals(held.calls,[]);
});
