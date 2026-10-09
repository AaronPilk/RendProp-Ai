import {assert,assertEquals,assertRejects,AssertionError} from "https://deno.land/std@0.224.0/assert/mod.ts";
const actor="ea100606-0000-4000-8000-000000000001",org="ea100606-0000-4000-8000-000000000002",listing="ea100606-0000-4000-8000-000000000003";
const encode=(source:string)=>`data:application/typescript;base64,${btoa(unescape(encodeURIComponent(source)))}`;
const url=(path:string)=>JSON.stringify(new URL(path,import.meta.url).href);
async function fixture(removeFinalAuthority=false,removeAdmission:"input"|"chain"|"intent"|null=null){
 let source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
 if(removeAdmission==="input"){
  const anchor='validatePhotoInputs(body.image_b64,mime,body.mask_b64,\n        String(body.mask_mime??"image/png").split(";")[0].trim().toLowerCase());';
  assert(source.includes(anchor));source=source.replace(anchor,"");
 }
 if(removeAdmission==="chain"){
  const anchor="chain = await boundedPhotoChain(funding, chain, genInput);";
  assert(source.includes(anchor));source=source.replace(anchor,"");
 }
 if(removeAdmission==="intent"){
  const anchor="const prepared = assertCustomPhotoPrompt(userText, promptSpace);";
  assert(source.includes(anchor));source=source.replace(anchor,"const prepared = {prompt:userText};");
 }
 const start=source.indexOf("Deno.serve(async (req) => {")+"Deno.serve(".length,end=source.indexOf("\n});\n\n// ── helper modes",start);
 assert(start>0&&end>start,"Extract actual handler callback");
 const locksStart=source.indexOf("const CONDITION_LOCK ="),locksEnd=source.indexOf("\n/**\n * The photographer",locksStart);
 const customStart=source.indexOf("function customPrompt("),customEnd=source.indexOf("\nDeno.serve(",customStart);
 assert(locksStart>0&&locksEnd>locksStart&&customStart>0&&customEnd>customStart,"Extract actual fixed-feature locks and custom compiler wrapper");
 let helper=url("./photo-result.ts");
 if(removeFinalAuthority){
  const original=await Deno.readTextFile(new URL("./photo-result.ts",import.meta.url));
  const anchor=" const bytes=await boundedPhotoResultBytes(response,saved.bytes);\n await authority(admin,identity,saved.key,saved.bytes);";
  assert(original.includes(anchor),"Compile the precise actual final-authority fault");
  const mutant=original.replace(anchor," const bytes=await boundedPhotoResultBytes(response,saved.bytes);").replace(/from "(\.\.\/[^\"]+)"/g,(_all,path)=>`from ${url(path)}`);
  helper=JSON.stringify(encode(mutant));
 }
 const imported=await import(encode(`// @ts-nocheck
 // Fresh synthetic boundary state ${crypto.randomUUID()}
 import {assert,HttpError,json,readJson,respondError} from ${url("../_shared/http.ts")};
 import {requiredIdempotencyKey} from ${url("../_shared/idempotency.ts")};
 import {fundingContext,fundedAttempt,mediaAttemptQuote,SavedFundingResponse,completeFundingOperation,abortFundingOperationBeforeDispatch,boundedPhotoChain,assertPhotoHelperSponsorship,inputHash} from ${url("../_shared/funded-serving.ts")};
 import {photoHelperPayload,photoHelperQuote} from ${url("./helper-policy.ts")};
 import {assertCustomPhotoPrompt,assertCustomPhotoOutput} from ${url("../ai-copy/guard.ts")};
 import {CUSTOM_PHOTO_FIXED_FEATURES} from ${url("../_shared/custom-photo-prompt.ts")};
 import {MAX_PROMPT_INPUT,MAX_PROMPT_OUTPUT,editPromptInstruction} from ${url("../ai-copy/prompt.ts")};
 import {validatePhotoInputs,validatePhotoPrompt} from ${url("./input-policy.ts")};
 import {persistOwnedPhotoResult,restorePhotoResult,photoResultKeys} from ${helper};
 import {inlineImageResult,inlineBase64,ProviderError,BUDGETS} from ${url("../_shared/providers/common.ts")};
 import {runChain} from ${url("../_shared/providers/chain.ts")};
 export const state={actor:${JSON.stringify(actor)},org:${JSON.stringify(org)},role:"owner",deleted:false,router:false,qa:false,routes:null,journal:null,object:null,saved:null,operationInputHash:null,started:false,completeLost:false,putLost:false,storageFail:false,withdrawOnGet:false,primaryFail:false,helperText:"Improve brightness only.",helperDispatch:0,charges:0,holds:0,prompts:[],submits:0,polls:0,puts:0,gets:0,completes:0};
 const GEMINI_KEY="synthetic",MODEL="gemini-3.1-flash-image",MAX_IMAGE_B64_CHARS=12000000,MAX_CUSTOM_PROMPT=600,ALLOWED_MIMES=["image/jpeg","image/png","image/webp","image/heic","image/heif"],PROFILES={real_estate:{}},RE_PROMPTS={twilight:"Synthetic"};
 ${source.slice(locksStart,locksEnd)}
 ${source.slice(customStart,customEnd)}
 const assertFairHousing=()=>{},listingSpaceType=async()=>"real_estate",userClient=()=>({});
 const spaceTypeOf=()=>"real_estate",getUser=async()=>({id:state.actor}),requireEditorRole=async()=>state.org,guardrailsFor=()=>"",provenanceKind=()=>"photo_edit",disclosureFallback=()=>"Synthetic disclosure";
 const MAX_IMPROVE_INPUT=MAX_PROMPT_INPUT,TEXT_MODEL="gemini-3.6-flash";
 const guardHelper=async()=>{state.charges++;return{orgId:state.org};},refundHelperCharge=async()=>{},improvePrompt=async()=>{state.helperDispatch++;return state.helperText;};
 const step={route_id:"fixture-route",provider:"gemini",model:MODEL,task:"photo.twilight",unit:"output_image",unit_cents:1,capabilities:[],max_latency_s:60,min_plan:"free",privacy_tier:"retained_30d",enabled:true};
 const routerEnabled=async()=>state.router,resolveChain=async(task)=>state.routes??[{...step,task}],legacyPhotoStep=(task)=>({...step,task}),needsForPhotoEdit=()=>[];
 const guardEdit=async()=>{state.charges++;return{orgId:state.org,plan:"pro",monthlyKey:"monthly",burstKey:"burst"};},refundEditCharge=async()=>{};
 const adapterFor=()=>({submit:async(_step,input)=>{state.submits++;state.prompts.push(input.prompt);if(state.primaryFail&&state.submits===1)throw new ProviderError(_step.provider,"upstream","Synthetic failure");return{id:"synthetic-job"};}}),awaitJob=async()=>{state.polls++;return{status:"done",mime:"image/png",result_url:"data:image/png;base64,QUFB"};};
 const recordRoutedAiCost=async()=>{},recordProvenance=async()=>({id:"synthetic-provenance",recorded:true,disclosure:"Synthetic disclosure"});
 const admin={from:(table)=>{let filters=[];const q={select:()=>q,eq:(key,value)=>{filters.push([key,[value]]);return q;},is:(key,value)=>{filters.push([key,[value]]);return q;},in:(key,value)=>{filters.push([key,value]);return q;},limit:async()=>({data:state.journal&&filters.every(([key,values])=>values.includes(state.journal[key]))?[state.journal]:[],error:null}),maybeSingle:async()=>({data:{user_id:state.actor,org_id:state.org,role:state.role},error:null})};return q;},rpc:async(name,args)=>{
 if(name==="library_access"||name==="listing_library_scope"){
 if(state.deleted||state.role!=="owner"||args.p_actor!==state.actor)return {data:null,error:{message:"RP403: Current editor access is required"}};
 return {data:{actor_id:state.actor,org_id:state.org,library_owner_user_id:state.actor,role:state.role,access_mode:"own",can_read:true,can_write:true,can_manage_subscription:true,billing_org_id:state.org,team_org_id:null,
 ...(name==="listing_library_scope"?{listing_id:args.p_listing,library_org_id:state.org,listing_owner_user_id:state.actor}:{})},error:null};
 }
 if(name==="serving_operation_begin"){
 if(state.deleted||state.role!=="owner")return{data:null,error:{message:"RP403: Current editor access is required"}};
 if(state.started){if(state.operationInputHash!==args.p_input_sha256)return{data:null,error:{message:"RP409: This request key was used for different input"}};if(state.saved)return{data:{replay:true,result:structuredClone(state.saved)},error:null};return{data:null,error:{message:"RP409: This operation already started. Check its saved result or status before starting another"}};}
 state.started=true;state.operationInputHash=args.p_input_sha256;return{data:{begun:true},error:null};}
 if(name==="serving_cost_reserve"){state.holds++;return{data:{reserved:true},error:null};}
 if(name.startsWith("org_has_"))return{data:state.qa,error:null};
 if(name==="subscription_trial_context")return{data:{trial_usage:null},error:null};
 if(name==="hosting_retention_state")return{data:{org_id:state.org,policy:"preserved",protected:true,retention_ends_at:null,hosting_available:true},error:null};
 if(name==="media_delivery_admit")return{data:{admitted:true,legacy_unbudgeted:true},error:null};
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
 export {photoResultKeys,inputHash};
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
 const image=btoa(String.fromCharCode(...[255,216,255,192,0,11,8,0,1,0,1,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]));
 return{...imported,close:()=>{globalThis.fetch=previous;},request:(extra:Record<string,unknown>={})=>new Request("https://example.invalid/ai-photo",{method:"POST",headers:{"content-type":"application/json","idempotency-key":"owned-photo-0001"},body:JSON.stringify({image_b64:image,edit:"twilight",mime:"image/jpeg",listing_id:listing,...extra})})};
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
Deno.test("actual photo handler refuses malformed/animated/oversized prompt input before quota and dispatch",async()=>{
 for(const body of [{image_b64:"QUFB"},{image_b64:"AAAA",mime:"image/heic"},{edit:"custom",prompt:"é".repeat(601)}]){
  const f=await fixture();try{const response=await f.run(f.request(body));assertEquals(response.status,400,await response.text());assertEquals(f.state.charges,0);assertEquals(f.state.submits,0);}finally{f.close();}
 }
});
Deno.test("actual custom photo handler clarifies or refuses before operation admission, holds or image dispatch",async()=>{
 for(const [prompt,status,code] of [["make it nicer",409,"photo_clarification_required"],["clean garage",409,"photo_clarification_required"],["modernize garage",409,"photo_clarification_required"],["repaint garage white",400,"unsupported_edit"],["make the garage door white",400,"unsupported_edit"],["hide wall crack",400,"unsupported_edit"],["re\u200Bpaint the garage and improve lighting",400,"unsupported_edit"],["chànge trím color and improve lighting",400,"unsupported_edit"]] as const){
  const f=await fixture();try{const response=await f.run(f.request({edit:"custom",prompt}));assertEquals(response.status,status);const body=await response.json();assertEquals(body.code,code);assertEquals(body.no_charge,true);if(status===409)assertEquals(body.clarification_options.length,4);assertEquals(f.state.started,false);assertEquals(f.state.holds,0);assertEquals(f.state.charges,0);assertEquals(f.state.submits,0);}finally{f.close();}
 }
});
Deno.test("actual custom handler automatically prepares the complete request and locks garage, trim and paint on both routing modes",async()=>{
 const prefix="Improve brightness and exposure only. ",tail=" Preserve the garage door and trim colors exactly.";
 const prompt=prefix+"natural lighting ".repeat(40).slice(0,600-prefix.length-tail.length)+tail;assertEquals(prompt.length,600);
 for(const router of [false,true]){const f=await fixture();try{f.state.router=router;
  const response=await f.run(f.request({edit:"custom",prompt}));assertEquals(response.status,200,await response.text());assertEquals(f.state.submits,1);assertEquals(f.state.holds,1);
  const prepared=f.state.prompts[0];assert(prepared.includes(JSON.stringify(prompt)));assert(prepared.includes("garage-door color and finish"));assert(prepared.includes("trim color and finish"));assert(prepared.includes("every existing paint color"));assert(prepared.includes("quoted data"));
 }finally{f.close();}}
});
Deno.test("actual custom handler accepts all 600 accented characters without truncating the quoted request",async()=>{
 const prefix="Improve brightness only. ",tail=" Preserve the garage and trim colors.";
 const prompt=prefix+"é".repeat(600-prefix.length-tail.length)+tail;
 const f=await fixture();try{const response=await f.run(f.request({edit:"custom",prompt}));assertEquals(response.status,200,await response.text());assertEquals(f.state.submits,1);assert(f.state.prompts[0].includes(JSON.stringify(prompt)));}
 finally{f.close();}
});
Deno.test("actual custom handler's paid fallback receives exactly the same prepared scope and finish locks",async()=>{
 const f=await fixture();try{f.state.router=true;f.state.primaryFail=true;f.state.routes=[
  {route_id:"primary",provider:"gemini",model:"gemini-3.1-flash-image",task:"photo.custom",unit:"output_image",unit_cents:6.7},
  {route_id:"fallback",provider:"fal",model:"flux-pro/kontext",task:"photo.custom",unit:"output_image",unit_cents:4}];
  const response=await f.run(f.request({edit:"custom",prompt:"Remove bags from the garage. Do not repaint or change the trim color."}));assertEquals(response.status,200,await response.text());
  assertEquals(f.state.submits,2);assertEquals(f.state.holds,2);assertEquals(f.state.prompts[0],f.state.prompts[1]);assert(f.state.prompts[1].includes("garage-door color and finish"));assert(f.state.prompts[1].includes("trim color and finish"));
 }finally{f.close();}
});
Deno.test("legacy photo polisher clarifies before a paid helper and refuses invented same-category work",async()=>{
 for(const [prompt,status] of [["make garage nicer",409],["repair roof",400]] as const){const f=await fixture();try{
  const response=await f.run(f.request({edit:"improve_prompt",prompt}));assertEquals(response.status,status);assertEquals(f.state.started,false);assertEquals(f.state.holds,0);assertEquals(f.state.charges,0);assertEquals(f.state.helperDispatch,0);
 }finally{f.close();}}
 const f=await fixture();try{f.state.helperText="Remove boxes and movable furniture.";
  const response=await f.run(f.request({edit:"improve_prompt",prompt:"Remove boxes only."}));assertEquals(response.status,502);assertEquals((await response.json()).code,"upstream");assertEquals(f.state.helperDispatch,1);assertEquals(f.state.holds,1);assertEquals(f.state.submits,0);
 }finally{f.close();}
});
Deno.test("compiled missing custom preparation fails unchanged no-spend clarification oracle",async()=>{
 const f=await fixture(false,"intent");try{
  await assertRejects(async()=>{const response=await f.run(f.request({edit:"custom",prompt:"make it nicer"}));assertEquals(response.status,409);assertEquals(f.state.holds,0);assertEquals(f.state.submits,0);},AssertionError);
  assertEquals(f.state.holds,1);assertEquals(f.state.submits,1);
 }finally{f.close();}
});
Deno.test("actual photo handler refuses a duplicated priced primary before any paid dispatch",async()=>{
 const f=await fixture();try{f.state.router=true;f.state.routes=[0,1].map(i=>({route_id:"route-"+i,provider:"gemini",model:"gemini-3.1-flash-image",task:"photo.twilight"}));
  const response=await f.run(f.request());assertEquals(response.status,503);assertEquals(f.state.submits,0);assertEquals(f.state.puts,0);
 }finally{f.close();}
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
 const f=await fixture();try{assertEquals((await f.run(f.request())).status,200);await assertRejects(()=>f.withdrawDuringSign(),Error,"Current editor access is required");assertEquals(f.state.gets,0);}finally{f.close();}
});
Deno.test("compiled removed final photo-authority check fails the unchanged no-private-bytes boundary",async()=>{
 const verify=async(remove:boolean)=>{const f=await fixture(remove);try{assertEquals((await f.run(f.request())).status,200);f.state.withdrawOnGet=true;const retry=await f.run(f.request());assertEquals(retry.status,403,"Withdrawal during replay must suppress private photo bytes");}finally{f.close();}};
 await verify(false);await assertRejects(()=>verify(true),AssertionError,"Withdrawal during replay must suppress private photo bytes");
});

Deno.test("compiled missing input/finite-chain guards fail unchanged actual-handler admission oracles",async()=>{
 const oracle=async(remove:"input"|"chain"|null,mode:"input"|"chain")=>{
  const f=await fixture(false,remove);try{
   if(mode==="chain"){f.state.router=true;f.state.routes=[0,1].map(i=>({route_id:"route-"+i,provider:"gemini",model:"gemini-3.1-flash-image",task:"photo.twilight"}));}
   const response=await f.run(f.request(mode==="input"?{image_b64:"QUFB"}:{}));
   assertEquals(response.status,mode==="input"?400:503,"Prospective admission must refuse before paid dispatch");assertEquals(f.state.submits,0);
  }finally{f.close();}
 };
 for(const mode of ["input","chain"] as const){await oracle(null,mode);await assertRejects(()=>oracle(mode,mode),AssertionError,"Prospective admission must refuse before paid dispatch");}
});

Deno.test("actual saved photo recovery preserves a historical input now refused for new dispatch",async()=>{
 const f=await fixture();try{
  assertEquals((await f.run(f.request())).status,200);
  const request=f.request({image_b64:"QUFB",mime:"image/heic"});
  // Represent an exact immutable old financial input journal, whose saved
  // owned output predates this new dispatch policy. No old provider is called.
  f.state.operationInputHash=await f.inputHash(await request.clone().json());
  const response=await f.run(request);assertEquals(response.status,200);assertEquals((await response.json()).image_b64,"QUFB");
  assertEquals(f.state.submits,1);assertEquals(f.state.charges,1);assertEquals(f.state.puts,1);assertEquals(f.state.gets,1);
  const changed=await f.run(f.request({image_b64:"QUFB",mime:"image/heic",label:"different"}));assertEquals(changed.status,409);assertEquals(f.state.gets,1);
 }finally{f.close();}
});
