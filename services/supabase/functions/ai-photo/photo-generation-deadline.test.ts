import {assert,assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {geminiAdapter,submitPreparedGeminiPhoto4K,GEMINI_PHOTO_4K_SUBMIT_MS} from "../_shared/providers/gemini.ts";
import {ProviderError} from "../_shared/providers/common.ts";
import type {RouteStep} from "../_shared/router.ts";
const step={route_id:"deadline-fixture",provider:"gemini",model:"gemini-3.1-flash-image",task:"photo.stage",unit:"image",unit_cents:16.7584,params:{image_size:"4K"},capabilities:[],max_latency_s:90,min_plan:"free",same_model_as:null,privacy_tier:"retained_30d",enabled:true} as RouteStep & {params:Record<string,unknown>};
const input={task:"photo.stage",image_b64:"QUFB",extra:{image_mime:"image/jpeg",photo_quality_4k:true,photo_input_token_bound:4096,photo_input_allowance:8192}};
const result=JSON.stringify({candidates:[{content:{parts:[{inlineData:{mimeType:"image/jpeg",data:"QUFB"}}]}}]});
Deno.test("verified4K90s fetch includes delayed headers AND body; ordinary1K keeps30s and request deadline aborts both",async()=>{
 const key=Deno.env.get("GEMINI_API_KEY"),priorFetch=globalThis.fetch;Deno.env.set("GEMINI_API_KEY","synthetic-local-only");
 let posts=0,aborts=0;const delays=new Set<ReturnType<typeof setTimeout>>();
 const delay=(ms:number)=>new Promise<void>(resolve=>{const timer=setTimeout(()=>{delays.delete(timer);resolve();},ms);delays.add(timer);});
 const server=Deno.serve({hostname:"127.0.0.1",port:0,onListen(){}},async req=>{
  posts++;const body=await req.json(),kind=body.contents[0].parts[0].text;
  if(kind==="late-headers"||kind==="legacy")await delay(31_100);
  if(kind==="deadline-headers")await delay(350);
  if(kind==="late-body"||kind==="deadline-body"){
   let timer:ReturnType<typeof setTimeout>;
   return new Response(new ReadableStream({start(c){c.enqueue(new TextEncoder().encode(result.slice(0,10)));timer=setTimeout(()=>{delays.delete(timer);c.enqueue(new TextEncoder().encode(result.slice(10)));c.close();},kind==="late-body"?31_100:350);delays.add(timer);},cancel(){clearTimeout(timer);delays.delete(timer);aborts++;}}),{headers:{"content-type":"application/json"}});
  }
  return new Response(result,{headers:{"content-type":"application/json"}});
 });
 globalThis.fetch=((url,init)=>{assert(String(url).startsWith("https://generativelanguage.googleapis.com/"));return priorFetch(`http://127.0.0.1:${server.addr.port}`,init);}) as typeof fetch;
 try{
  const started=Date.now();assertEquals(GEMINI_PHOTO_4K_SUBMIT_MS,90_000);
  const deadlines=["deadline-headers","deadline-body"].map(async prompt=>{
   const error=await assertRejects(()=>submitPreparedGeminiPhoto4K(step,{...input,prompt},{deadline:Date.now()+120,signal:new AbortController().signal}),ProviderError);
   assertEquals(error.error_class,"timeout");assertEquals(error.dispatch_rejected,false);
  });
  const success=["late-headers","late-body"].map(async prompt=>{
   const ref=await submitPreparedGeminiPhoto4K(step,{...input,prompt},{deadline:Date.now()+80_000,signal:new AbortController().signal});
   assertEquals((await geminiAdapter.poll(ref)).status,"done");
  });
  const legacy=(async()=>{const error=await assertRejects(()=>geminiAdapter.submit(Object.assign({...step},{params:{image_size:"1K"}}), {task:"photo.stage",prompt:"legacy",image_b64:"QUFB"}),ProviderError);assertEquals(error.error_class,"timeout");})();
  await Promise.all([...deadlines,...success,legacy]);assert(Date.now()-started>=31_000);assertEquals(posts,5);assert(aborts>=1);
 }finally{globalThis.fetch=priorFetch;for(const timer of delays)clearTimeout(timer);await server.shutdown();if(key===undefined)Deno.env.delete("GEMINI_API_KEY");else Deno.env.set("GEMINI_API_KEY",key);}
});
Deno.test("expired/unverified4K request fails before any supplier POST",async()=>{
 let calls=0;const prior=globalThis.fetch;globalThis.fetch=async()=>{calls++;throw Error("Must not send");};
 try{
  const expired=await assertRejects(()=>submitPreparedGeminiPhoto4K(step,input,{deadline:Date.now()-1,signal:new AbortController().signal}),ProviderError);assertEquals(expired.status,0);assertEquals(expired.dispatch_rejected,true);
  await assertRejects(()=>submitPreparedGeminiPhoto4K(Object.assign({...step},{params:{image_size:"1K"}}),input,{deadline:Date.now()+90_000,signal:new AbortController().signal}),ProviderError);
  await assertRejects(()=>submitPreparedGeminiPhoto4K(step,{...input,extra:{}},{deadline:Date.now()+90_000,signal:new AbortController().signal}),ProviderError);
  assertEquals(calls,0);
 }finally{globalThis.fetch=prior;}
});
