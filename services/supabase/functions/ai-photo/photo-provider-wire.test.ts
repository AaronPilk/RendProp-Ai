import {assert,assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {boundedProviderText,ProviderResponseLimitError,fetchJson} from "../_shared/providers/common.ts";
import {runChain} from "../_shared/providers/chain.ts";
import {HttpError} from "../_shared/http.ts";
import {GEMINI_PHOTO_4K_MAX_RESPONSE_BYTES} from "../_shared/providers/gemini.ts";
Deno.test("opted-in provider stream accepts exact byte bound and refuses one additional byte before JSON parse",async()=>{
 const text=JSON.stringify({text:"é".repeat(40)}),bytes=new TextEncoder().encode(text);
 assertEquals(await boundedProviderText(new Response(bytes),"gemini",bytes.length),text);
 const error=await assertRejects(()=>boundedProviderText(new Response(bytes),"gemini",bytes.length-1),ProviderResponseLimitError);assertEquals(error.dispatch_rejected,false);assertEquals(error.terminal_after_dispatch,true);
 assertEquals(GEMINI_PHOTO_4K_MAX_RESPONSE_BYTES,35_052_536);
});
Deno.test("unknown-length oversized response is cancelled at bound, without consuming an unbounded supplier body",async()=>{
 let sent=0,cancelled=false;const chunk=new Uint8Array(65536),response=new Response(new ReadableStream({pull(controller){sent+=chunk.length;controller.enqueue(chunk);if(sent>=40*1024*1024)controller.close();},cancel(){cancelled=true;}}));
 await assertRejects(()=>boundedProviderText(response,"gemini",GEMINI_PHOTO_4K_MAX_RESPONSE_BYTES),ProviderResponseLimitError);assert(cancelled);assert(sent<=GEMINI_PHOTO_4K_MAX_RESPONSE_BYTES+2*chunk.length);
});
Deno.test("response-limit uncertainty stops an authorized multi-step chain and preserves liability facts",async()=>{
 const step={route_id:"fixture",task:"photo.stage",provider:"gemini",model:"gemini-3.1-flash-image",unit:"image",unit_cents:16.7584,capabilities:[],max_latency_s:60,min_plan:"free",same_model_as:null,privacy_tier:"retained_30d" as const,enabled:true};let calls=0;
 const error=await assertRejects(()=>runChain("photo.stage",[step,{...step,route_id:"second"}],async()=>{calls++;throw new ProviderResponseLimitError("gemini",200,GEMINI_PHOTO_4K_MAX_RESPONSE_BYTES);}),HttpError);
 assertEquals(calls,1);assertEquals(error.status,502);assertEquals(error.details?.retain_feature_charge,true);assertEquals(error.details?.provider_cost_incurred,"possible");assertEquals(error.details?.dispatch_rejected,false);
});
Deno.test("generic fetchJson remains unchanged unless response bound explicitly supplied",async()=>{
 const before=globalThis.fetch;let calls=0;globalThis.fetch=async()=>{calls++;return new Response(JSON.stringify({text:"a".repeat(1024)}));};
 try{assertEquals((await fetchJson<any>("fixture","https://example.invalid",{method:"POST"},1000)).text.length,1024);await assertRejects(()=>fetchJson("fixture","https://example.invalid",{method:"POST"},1000,undefined,{maxResponseBytes:128}),ProviderResponseLimitError);assertEquals(calls,2);}finally{globalThis.fetch=before;}
});
