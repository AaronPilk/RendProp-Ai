// Execute the actual private adapter bodies plus the real fundedAttempt state
// machine. Transports and RPC persistence are closed synthetic fixtures only.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { fundedAttempt, resetServingModeCache, type FundingContext } from "./funded-serving.ts";
import { HttpError, respondError } from "./http.ts";
import { createHfMotionTransferInput, submitHfMotionTransfer, pollHfMotionTransfer } from "./providers/higgsfield.ts";

const encode = (text: string) => "data:application/typescript;base64," + btoa(String.fromCharCode(...new TextEncoder().encode(text)));
const common = new URL("./providers/common.ts", import.meta.url).href;
const http = new URL("./http.ts", import.meta.url).href;
type Kind = "voice" | "helper" | "chapters" | "higgsfield";
const steps = {voice:"elevenlabs",helper:"gemini",chapters:"gemini",higgsfield:"higgsfield"};
const retained = { request_id:"91000000-0000-4000-8000-000000000001",status_url:"https://api.higgsfield.ai/requests/91000000-0000-4000-8000-000000000001/status",cancel_url:"https://api.higgsfield.ai/requests/91000000-0000-4000-8000-000000000001/cancel" };

async function adapter(kind: Kind): Promise<() => Promise<unknown>> {
  if (kind === "higgsfield") return () => submitHfMotionTransfer(createHfMotionTransferInput({performanceVideoUrl:"https://uploads.rendprop.com/fixture.mp4",performanceDurationSeconds:5,approvedCharacterImageUrls:["https://uploads.rendprop.com/fixture.jpg"],reviewedPrompt:"Preserve the approved performance."}));
  if (kind === "chapters") {
    const module = await import("../ai-chapters/gemini.ts");
    return () => module.generateChapters({model:"fixture-model",fileUri:"https://files.fixture.invalid/test",mimeType:"video/mp4",systemInstruction:"Synthetic",prompt:"Synthetic",fps:1});
  }
  const source = await Deno.readTextFile(new URL(kind === "voice" ? "../ai-voice/index.ts" : "../ai-photo/index.ts", import.meta.url));
  let body: string;
  if (kind === "helper") {
    const start = source.indexOf("async function geminiText("),end = source.indexOf("\n/** Defensive JSON parse",start);
    assert(start > 0 && end > start,"actual Gemini helper body found");
    body = source.slice(start,end) + "\nexport const run = () => geminiText({});";
  } else {
    const paid = source.indexOf('const data = await fundedAttempt(funding, "voice.tts"');
    const start = source.indexOf("const res = await fetch(url",paid),end = source.indexOf("return data;",start);
    assert(paid > 0 && start > paid && end > start,"actual ElevenLabs funded callback found");
    body = "export async function run(){" + source.slice(start,end+"return data;".length) + "}";
  }
  // Imports are the real implementations; no provider/hold logic is mirrored.
  const module = await import(encode(`import * as c from ${JSON.stringify(common)};import {HttpError} from ${JSON.stringify(http)};
    const {ProviderError,definitiveSubmitRejection,classifyStatus}=c;
    const ProviderHttpError=(c as any).ProviderHttpError;
    type PhotoHelperPayload=any;const TEXT_MODEL='fixture-model',GEMINI_KEY='synthetic-fixture';
    const url='https://api.elevenlabs.io/fixture',payload={},elevenHeaders=()=>({});${body}`));
  return module.run;
}

async function exercise(kind: Kind, transport: (init: RequestInit) => Promise<Response>, run?:()=>Promise<unknown>) {
  const priorFetch = globalThis.fetch;
  const names=["GEMINI_API_KEY","HIGGSFIELD_API_KEY_ID","HIGGSFIELD_API_KEY_SECRET"];
  const prior=names.map(n=>Deno.env.get(n));names.forEach(n=>Deno.env.set(n,"synthetic-fixture-only"));
  let calls=0;const finishes:Record<string,unknown>[]=[];
  const context:FundingContext={actorId:"fixture-actor",orgId:"fixture-org",requestKey:crypto.randomUUID(),rpc:async(name,args)=>{
    if(name==="serving_cost_reserve")return {data:{reserved:true},error:null};
    if(name==="serving_cost_finish"){finishes.push(args);return {data:{finished:true},error:null};}
    throw Error("Unexpected financial RPC "+name);
  }};
  globalThis.fetch=((input:Request|URL|string,init:RequestInit={})=>{
    if(String(input).endsWith("/rest/v1/rpc/serving_mode"))return Promise.resolve(Response.json("funded"));
    calls++;return transport(init);
  }) as typeof fetch;
  resetServingModeCache();
  try {
    const attempt=run??await adapter(kind);
    let error:unknown,result:unknown;
    try {result=await fundedAttempt(context,"fixture.submit",{provider:steps[kind],model:"fixture-model"},{},{cents:1,version:"synthetic-tariff"},attempt);} catch(e){error=e;}
    return {error,result,calls,finishes};
  } finally { globalThis.fetch=priorFetch;names.forEach((n,i)=>prior[i]===undefined?Deno.env.delete(n):Deno.env.set(n,prior[i]!)); }
}

for (const kind of ["voice","helper","chapters"] as const) {
  for (const phase of ["headers","body"] as const) Deno.test(`${kind}: actual paid response deadline covers stalled ${phase} and retains uncertain hold`,async()=>{
    const nativeTimeout=AbortSignal.timeout;const budgets:number[]=[];let aborts=0;const release:(()=>void)[]=[];
    AbortSignal.timeout=(ms:number)=>{budgets.push(ms);return nativeTimeout(20);};
    let watchdog:ReturnType<typeof setTimeout>|undefined;let flight:ReturnType<typeof exercise>|undefined;
    try {
      const work=flight=exercise(kind,async(init)=>{
        if(phase==="headers")return await new Promise<Response>((_resolve,reject)=>{
          const stop=()=>{aborts++;reject(init.signal?.reason??Error("fixture cleanup"));};release.push(stop);
          init.signal?.addEventListener("abort",stop,{once:true});
        });
        return new Response(new ReadableStream({start(controller){
          const stop=()=>{aborts++;controller.error(init.signal?.reason??Error("fixture cleanup"));};release.push(stop);
          init.signal?.addEventListener("abort",stop,{once:true});
        }}),{headers:{"content-type":"application/json"}});
      });
      const outcome=await Promise.race([work,new Promise<null>(resolve=>{watchdog=setTimeout(()=>resolve(null),150);})]);
      assert(outcome!==null,`${kind} stalled ${phase} must settle before fixture watchdog`);
      assert(outcome.error);assertEquals(outcome.calls,1);assertEquals(outcome.finishes.map(x=>x.p_state),["uncertain"]);
      assertEquals(aborts,1);assertEquals(budgets,[kind==="helper"?30_000:90_000]);
    }finally{AbortSignal.timeout=nativeTimeout;if(watchdog)clearTimeout(watchdog);if(aborts===0)release.forEach(stop=>stop());await flight;}
  });
  Deno.test(`${kind}: actual submit refusal releases only a validated no-receipt response`,async()=>{
    const refusal=await exercise(kind,async()=>Response.json({error:"synthetic refusal"},{status:422}));
    assert(refusal.error);assertEquals(refusal.calls,1);assertEquals(refusal.finishes.map(x=>x.p_state),["rejected"]);
    assertEquals(refusal.finishes[0].p_rejection_status,422);
    for(const [status,body] of [[422,JSON.stringify({error:{task_id:"accepted-fixture"}})],[422,"not JSON"],[500,"{}"]] as const){
      const uncertain=await exercise(kind,async()=>new Response(body,{status}));
      assert(uncertain.error);assertEquals(uncertain.finishes.map(x=>x.p_state),["uncertain"]);
    }
    if(kind!=="voice"){
      assert(refusal.error instanceof HttpError);const wire=await respondError(refusal.error).json();
      assertEquals(Object.keys(wire).sort(),["code","error"]);assertEquals(wire.code,"upstream");
    }
  });
}
Deno.test("Higgsfield actual submit rejects only a no-receipt refusal; polling and malformed replies stay uncertain",async()=>{
  const refused=await exercise("higgsfield",async()=>Response.json({error:"synthetic refusal"},{status:422}));
  assert(refused.error);assertEquals(refused.finishes.map(x=>x.p_state),["rejected"]);
  for(const body of [JSON.stringify({request_id:retained.request_id}),"not JSON"]){
    const r=await exercise("higgsfield",async()=>new Response(body,{status:422}));assert(r.error);assertEquals(r.finishes.map(x=>x.p_state),["uncertain"]);
  }
  const poll=await exercise("higgsfield",async()=>Response.json({error:"not found"},{status:404}),()=>pollHfMotionTransfer(retained));
  assert(poll.error);assertEquals(poll.finishes.map(x=>x.p_state),["uncertain"]);
});
Deno.test("validated adapter answers still succeed once; generic2xx and transport errors never become free refusals",async()=>{
  const valid={voice:{audio_base64:"QUFB"},helper:{candidates:[{content:{parts:[{text:"Synthetic answer"}]}}]},chapters:{candidates:[{content:{parts:[{text:"{\"chapters\":[]}"}]},finishReason:"STOP"}],usageMetadata:{promptTokenCount:1,candidatesTokenCount:1}},higgsfield:retained};
  for(const kind of ["voice","helper","chapters","higgsfield"] as const){
    const success=await exercise(kind,async()=>Response.json(valid[kind]));
    assertEquals(success.error,undefined);assertEquals(success.calls,1);assertEquals(success.finishes.map(x=>x.p_state),["succeeded"]);
    const transport=await exercise(kind,()=>Promise.reject(new TypeError("synthetic transport failure")));
    assert(transport.error);assertEquals(transport.calls,1);assertEquals(transport.finishes.map(x=>x.p_state),["uncertain"]);
    const generic=await exercise(kind,async()=>Response.json({code:422,error:"not an authoritative HTTP rejection"}));
    assertEquals(generic.calls,1);assertEquals(generic.finishes.some(x=>x.p_state==="rejected"),false);
  }
});
