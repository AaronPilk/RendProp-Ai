import {assert,assertEquals,assertRejects,AssertionError} from "https://deno.land/std@0.224.0/assert/mod.ts";
const actor="ea100606-0000-4000-8000-000000000001",org="ea100606-0000-4000-8000-000000000002",listing="ea100606-0000-4000-8000-000000000003";
const encode=(source:string)=>`data:application/typescript;base64,${btoa(unescape(encodeURIComponent(source)))}`;
const url=(path:string)=>JSON.stringify(new URL(path,import.meta.url).href);
async function fixture(removeFinalAuthority=false){
 const source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
 const start=source.indexOf("Deno.serve(async (req) => {")+"Deno.serve(".length,end=source.indexOf("\n});\n\n// ── helper modes",start);
 assert(start>0&&end>start,"Extract actual handler callback");
 let helper=url("./photo-result.ts");
 if(removeFinalAuthority){
  const original=await Deno.readTextFile(new URL("./photo-result.ts",import.meta.url));
  const anchor=" const bytes=await boundedBytes(response,saved.bytes);\n await authority(admin,identity,saved.key,saved.bytes);";
  assert(original.includes(anchor),"Compile the precise actual final-authority fault");
  const mutant=original.replace(anchor," const bytes=await boundedBytes(response,saved.bytes);").replace(/from "(\.\.\/[^\"]+)"/g,(_all,path)=>`from ${url(path)}`);
  helper=JSON.stringify(encode(mutant));
 }
 const imported=await import(encode(`// @ts-nocheck
 // Fresh synthetic boundary state ${crypto.randomUUID()}
 import {assert,HttpError,json,readJson,respondError} from ${url("../_shared/http.ts")};
 import {requiredIdempotencyKey} from ${url("../_shared/idempotency.ts")};
 import {fundingContext,fundedAttempt,mediaAttemptQuote,textAttemptQuote,SavedFundingResponse,completeFundingOperation,abortFundingOperationBeforeDispatch} from ${url("../_shared/funded-serving.ts")};
 import {persistOwnedPhotoResult,restorePhotoResult,photoResultKeys} from ${helper};
 import {inlineImageResult,inlineBase64,ProviderError,BUDGETS} from ${url("../_shared/providers/common.ts")};
 import {runChain} from ${url("../_shared/providers/chain.ts")};
 export const state={actor:${JSON.stringify(actor)},org:${JSON.stringify(org)},role:"owner",deleted:false,router:false,journal:null,object:null,saved:null,started:false,completeLost:false,putLost:false,storageFail:false,withdrawOnGet:false,charges:0,submits:0,polls:0,puts:0,gets:0,completes:0};
 const GEMINI_KEY="synthetic",MODEL="gemini-3.1-flash-image",MAX_IMAGE_B64_CHARS=12000000,ALLOWED_MIMES=["image/jpeg","image/png","image/webp"],PROFILES={real_estate:{}},RE_PROMPTS={twilight:"Synthetic"};
 const spaceTypeOf=()=>"real_estate",getUser=async()=>({id:state.actor}),requireEditorRole=async()=>state.org,guardrailsFor=()=>"",provenanceKind=()=>"photo_edit",disclosureFallback=()=>"Synthetic disclosure";
 const step={route_id:"fixture-route",provider:"gemini",model:MODEL,task:"photo.twilight",unit:"output_image",unit_cents:1,capabilities:[],max_latency_s:60,min_plan:"free",privacy_tier:"retained_30d",enabled:true};
 const routerEnabled=async()=>state.router,resolveChain=async()=>[step],legacyPhotoStep=()=>step,needsForPhotoEdit=()=>[];
 const guardEdit=async()=>{state.charges++;return{orgId:state.org,plan:"pro",monthlyKey:"monthly",burstKey:"burst"};},refundEditCharge=async()=>{};
 const adapterFor=()=>({submit:async()=>{state.submits++;return{id:"synthetic-job"};}}),awaitJob=async()=>{state.polls++;return{status:"done",mime:"image/png",result_url:"data:image/png;base64,QUFB"};};
 const recordRoutedAiCost=async()=>{},recordProvenance=async()=>({id:"synthetic-provenance",recorded:true,disclosure:"Synthetic disclosure"});
 const admin={from:(table)=>{let filters=[];const q={select:()=>q,eq:(key,value)=>{filters.push([key,[value]]);return q;},is:(key,value)=>{filters.push([key,[value]]);return q;},in:(key,value)=>{filters.push([key,value]);return q;},limit:async()=>({data:state.journal&&filters.every(([key,values])=>values.includes(state.journal[key]))?[state.journal]:[],error:null}),maybeSingle:async()=>({data:{user_id:state.actor,org_id:state.org,role:state.role},error:null})};return q;},rpc:async(name,args)=>{
 if(name==="serving_operation_begin"){
 if(state.deleted||state.role!=="owner")return{data:null,error:{message:"RP403: Current editor access is required"}};
 if(state.started){if(state.saved)return{data:{replay:true,result:structuredClone(state.saved)},error:null};return{data:null,error:{message:"RP409: This operation already started. Check its saved result or status before starting another"}};}
 state.started=true;return{data:{begun:true},error:null};}
 if(name==="serving_cost_reserve")return{data:{reserved:true},error:null};
 if(name==="serving_cost_finish")return{data:{finished:true},error:null};
 if(name==="serving_operation_complete"){state.completes++;if(state.completeLost&&state.completes===1)throw Error("lost operation write");state.saved=structuredClone(args.p_result);return{data:{saved:true},error:null};}
 if(name==="register_private_ai_output"){
 if(state.deleted||state.role!=="owner")return{data:null,error:{message:"RP403: gone"}};
 const row={org_id:args.p_org,user_id:args.p_user,listing_id:args.p_listing,bucket:args.p_bucket,storage_key:args.p_key,bytes:args.p_bytes};
 if(state.journal&&JSON.stringify(state.journal)!==JSON.stringify(row))return{data:null,error:{message:"RP409: foreign receipt"}};
 state.journal??=row;return{data:{ok:true,key:args.p_key},error:null};}
 if(name==="serving_operation_no_dispatch")return{data:{retryable:false},error:null};
 throw Error("Unexpected RPC "+name);
 }};
 const adminClient=()=>admin;
 export const run=${source.slice(start,end)}};
 export async function restore(identity,pointer){return await restorePhotoResult(admin,identity,pointer);}
 export async function withdrawDuringSign(){return await restorePhotoResult(admin,{actorId:state.actor,orgId:state.org,requestKey:"owned-photo-0001",listingId:${JSON.stringify(listing)}},undefined,{head:async()=>({exists:true,bytes:3}),sign:async()=>{state.role="viewer";return"https://synthetic.invalid";},read:async()=>{state.gets++;throw Error("Never read after signing-time withdrawal");}});}
 export {photoResultKeys};
 `));
 const previous=globalThis.fetch;
 globalThis.fetch=(async(input:Request|string|URL,init?:RequestInit)=>{
 const request=input instanceof Request?input:new Request(input,init),u=new URL(request.url),method=request.method;
 if(!u.hostname.endsWith(".r2.cloudflarestorage.com"))throw Error("Unexpected vendor/network transport");
 if(method==="PUT"){
 imported.state.puts++;assertEquals(request.headers.get("if-none-match"),"*");assertEquals(request.redirect,"error");
 if(imported.state.storageFail)return new Response("",{status:503});
 if(imported.state.object)return new Response(null,{status:412});
 imported.state.object=await request.arrayBuffer();if(imported.state.putLost)throw Error("lost committed PUT");return new Response(null,{status:200});}
 if(method==="HEAD")return imported.state.object?new Response(null,{headers:{"content-length":String(imported.state.object.byteLength),"content-type":"image/png"}}):new Response(null,{status:404});
 if(method==="GET"){
 imported.state.gets++;assertEquals(request.redirect,"error");assertEquals(init?.credentials,"omit");assertEquals([...request.headers],[]);assertEquals(u.searchParams.get("X-Amz-Expires"),"600");assertEquals(u.searchParams.get("X-Amz-SignedHeaders"),"host");
 if(imported.state.withdrawOnGet)imported.state.role="viewer";
 return new Response(imported.state.object,{headers:{"content-length":String(imported.state.object?.byteLength??0),"content-type":"image/png"}});}
 throw Error("Unexpected R2 method");
 }) as typeof fetch;
 return{...imported,close:()=>{globalThis.fetch=previous;},request:()=>new Request("https://example.invalid/ai-photo",{method:"POST",headers:{"content-type":"application/json","idempotency-key":"owned-photo-0001"},body:JSON.stringify({image_b64:"QUFB",edit:"twilight",mime:"image/jpeg",listing_id:listing})})};
}
// Load exact production signers only after synthetic test credentials exist.
for(const [key,value] of Object.entries({CLOUDFLARE_ACCOUNT_ID:"a".repeat(32),R2_ACCESS_KEY_ID:"b".repeat(32),R2_SECRET_ACCESS_KEY:"c".repeat(64)}))Deno.env.set(key,value);
Deno.test("actual photo handler router-off and router-on persist once and replay inline without another quota or provider",async()=>{
 for(const router of [false,true]){const f=await fixture();try{f.state.router=router;
 const first=await f.run(f.request());assertEquals(first.status,200);const result=await first.json();assertEquals(result.image_b64,"QUFB");assert(/^ai-router\/.+\/completed-photo\/[a-f0-9]{64}\.png$/.test(result.asset_key));
 const second=await f.run(f.request());assertEquals(second.status,200);const restored=await second.json();assertEquals(restored.image_b64,"QUFB");assertEquals(restored.asset_key,result.asset_key);assertEquals(f.state.charges,1);assertEquals(f.state.submits,1);assertEquals(f.state.polls,1);assertEquals(f.state.puts,1);assertEquals(f.state.gets,1);
 assert(!JSON.stringify(f.state.saved).includes("X-Amz"));assert(!JSON.stringify(f.state.saved).includes("QUFB"));
 }finally{f.close();}}
});
Deno.test("actual photo handler recovers a committed output whose result-pointer response was lost",async()=>{
 const f=await fixture();try{f.state.completeLost=true;assertEquals((await f.run(f.request())).status,200);assertEquals(f.state.saved,null);
 const retry=await f.run(f.request());assertEquals(retry.status,200);assertEquals((await retry.json()).image_b64,"QUFB");assertEquals(f.state.submits,1);assertEquals(f.state.puts,1);assertEquals(f.state.charges,1);assertEquals(f.state.completes,2);assert(f.state.saved);
 }finally{f.close();}
});
Deno.test("actual photo handler recovers a lost committed PUT without another provider or object write",async()=>{
 const f=await fixture();try{f.state.putLost=true;assertEquals((await f.run(f.request())).status,503);assert(f.state.journal&&f.state.object);
 const retry=await f.run(f.request());assertEquals(retry.status,200);assertEquals((await retry.json()).image_b64,"QUFB");assertEquals(f.state.submits,1);assertEquals(f.state.puts,1);assertEquals(f.state.charges,1);
 }finally{f.close();}
});
Deno.test("actual completed-image storage failure cannot start paid fallback or regenerate a missing object",async()=>{
 const f=await fixture();try{f.state.storageFail=true;assertEquals((await f.run(f.request())).status,503);assertEquals((await f.run(f.request())).status,503);assertEquals(f.state.submits,1);assertEquals(f.state.puts,1);assertEquals(f.state.charges,1);
 }finally{f.close();}
});
Deno.test("actual photo replay refuses foreign exact receipt and deletion before storage",async()=>{
 for(const mode of ["foreign","deleted"]){const f=await fixture();try{assertEquals((await f.run(f.request())).status,200);if(mode==="foreign")f.state.journal.user_id="foreign";else f.state.deleted=true;
 const retry=await f.run(f.request());assert(retry.status!==200);assertEquals(f.state.gets,0);assertEquals(f.state.submits,1);
 }finally{f.close();}}
});
Deno.test("actual photo replay rechecks access after signing and after the bounded private read",async()=>{
 const f=await fixture();try{assertEquals((await f.run(f.request())).status,200);f.state.withdrawOnGet=true;const retry=await f.run(f.request());assertEquals(retry.status,403);assertEquals(f.state.gets,1);assertEquals(f.state.submits,1);const body=await retry.text();assert(!body.includes("QUFB"));assert(!body.includes("X-Amz"));
 }finally{f.close();}
});
Deno.test("actual photo replay rejects signing-time access withdrawal before GET",async()=>{
 const f=await fixture();try{assertEquals((await f.run(f.request())).status,200);await assertRejects(()=>f.withdrawDuringSign(),Error,"unavailable for this account");assertEquals(f.state.gets,0);}finally{f.close();}
});
Deno.test("compiled removed final photo-authority check fails the unchanged no-private-bytes boundary",async()=>{
 const verify=async(remove:boolean)=>{const f=await fixture(remove);try{assertEquals((await f.run(f.request())).status,200);f.state.withdrawOnGet=true;const retry=await f.run(f.request());assertEquals(retry.status,403,"Withdrawal during replay must suppress private photo bytes");}finally{f.close();}};
 await verify(false);await assertRejects(()=>verify(true),AssertionError,"Withdrawal during replay must suppress private photo bytes");
});
