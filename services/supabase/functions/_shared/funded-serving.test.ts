import {assert,assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {fundedAttempt,fundingContext,mediaAttemptQuote,geminiImageGenerationQuote,textAttemptQuote,TARIFF_VERSION,completeFundingOperation,SavedFundingResponse,boundedPhotoChain,assertPhotoHelperSponsorship,type FundingContext} from "./funded-serving.ts";
import {HttpError,respondError} from "./http.ts";
import {ProviderError} from "./providers/common.ts";
import {runChain} from "./providers/chain.ts";
import {geminiAdapter,geminiImagePayload,GEMINI_IMAGE_MAX_OUTPUT_TOKENS} from "./providers/gemini.ts";
import {falInput} from "./providers/fal.ts";
import type {RouteStep} from "./router.ts";
const step:RouteStep={route_id:"synthetic",task:"copy.synthetic",provider:"openai",model:"gpt-5.6-terra",unit:"call",unit_cents:2,capabilities:[],max_latency_s:30,min_plan:"starter",same_model_as:null,privacy_tier:"no_retention",enabled:true};
function fixture(options:{reserveError?:string;reserveShape?:unknown;finishError?:boolean;qa?:boolean;qaError?:boolean}={}){
 const calls:{name:string;args:Record<string,unknown>}[]=[];
 const context:FundingContext={actorId:"synthetic-actor",orgId:"synthetic-org",requestKey:"synthetic-request-key",async rpc(name,args){
  calls.push({name,args});
  if(name==="serving_operation_begin")return {data:{begun:true},error:null};
  if(name.startsWith("org_has_"))return {data:options.qa??false,error:options.qaError?{message:"unavailable"}:null};
  if(name==="serving_cost_reserve")return {data:options.reserveShape??{reserved:true},error:options.reserveError?{message:options.reserveError}:null};
  assertEquals(name,"serving_cost_finish");return {data:{finished:true},error:options.finishError?{message:"unavailable"}:null};
 }};
 return {calls,context};
}
Deno.test("finite photo route retains one eligible primary and one priced task-correct fallback",async()=>{
 const primary={...step,task:"photo.stage",provider:"gemini",model:"gemini-3.1-flash-image"};
 const fallback={...primary,provider:"fal",model:"fal-ai/flux-pro/kontext"};
 const unpriced={...primary,provider:"openai",model:"gpt-image-2"};
 const input={task:primary.task,prompt:"synthetic"};
 assertEquals(await boundedPhotoChain(fixture().context,[unpriced,fallback,primary],input),[primary,fallback]);
 for(const chain of [[unpriced],[fallback],[primary,primary],[primary,fallback,fallback],[{...primary,task:"photo.custom"}]])
  await assertRejects(()=>boundedPhotoChain(fixture().context,chain,input),HttpError,"bounded serving route");
 await assertRejects(()=>boundedPhotoChain(fixture().context,[primary,fallback],{...input,mask_url:"data:image/png;base64,AAA="}),HttpError);
 const qa=fixture({qa:true});assertEquals(await boundedPhotoChain(qa.context,[unpriced,fallback,primary],input),[unpriced,fallback,primary]);
 await assertRejects(()=>boundedPhotoChain(fixture({qaError:true}).context,[primary],input),HttpError);
});
Deno.test("bounded photo fallback holds at most35.1296c and uncertain primary is never treated as free",async()=>{
 const primary={...step,task:"photo.custom",provider:"gemini",model:"gemini-3.1-flash-image"};
 const fallback={...primary,provider:"fal",model:"flux-pro/kontext"};
 const input={task:primary.task,prompt:"synthetic"},f=fixture(),calls:string[]=[];
 const old=globalThis.fetch;globalThis.fetch=async()=>Response.json(null);
 try {
  const chain=await boundedPhotoChain(f.context,[primary,fallback,{...primary,provider:"openai",model:"gpt-image-2"}],input);
  const result=await runChain(input.task,chain,async(s)=>fundedAttempt(f.context,`photo:${chain.indexOf(s)}`,s,input,mediaAttemptQuote(s,input),async()=>{
   calls.push(s.provider);if(s.provider==="gemini")throw new ProviderError("gemini","timeout","synthetic uncertain acceptance");return "fallback output";
  }));
  assertEquals(result.value,"fallback output");assertEquals(calls,["gemini","fal"]);
  const reserves=f.calls.filter(c=>c.name==="serving_cost_reserve");assertEquals(reserves.map(c=>c.args.p_hold_cents),[31.1296,4]);
  assertEquals(reserves.reduce((n,c)=>n+Math.round(Number(c.args.p_hold_cents)*10000),0),351296);
  assertEquals(f.calls.filter(c=>c.name==="serving_cost_finish").map(c=>c.args.p_state),["uncertain","succeeded"]);
 }finally{globalThis.fetch=old;}
});
Deno.test("trial helper denial fences dispatch; paid metered helpers and private QA remain available",async()=>{
 let paid=0,noDispatch=0,usage:unknown={org_id:"org",status:"active"},error=false;
 const context:FundingContext={actorId:"actor",orgId:"org",requestKey:"key",operationBegun:true,rpc:async(name)=>{
  if(name.startsWith("org_has_"))return{data:false,error:null};
  if(name==="subscription_trial_context")return{data:{trial_usage:usage,trial_offer:null},error:error?{message:"unavailable"}:null};
  if(name==="serving_operation_no_dispatch"){noDispatch++;return{data:{retryable:true},error:null};}
  paid++;return{data:{reserved:true},error:null};
 }};
 await assertRejects(()=>assertPhotoHelperSponsorship(context),HttpError,"not included");assertEquals(paid,0);assertEquals(noDispatch,1);
 for(const bad of [{org_id:"foreign",status:"active"},[],false,{},undefined]){usage=bad;await assertRejects(()=>assertPhotoHelperSponsorship(context),HttpError,"could not be checked");}
 usage=null;error=true;await assertRejects(()=>assertPhotoHelperSponsorship(context),HttpError,"could not be checked");
 error=false;await assertPhotoHelperSponsorship(context);assertEquals(paid,0);
 await assertPhotoHelperSponsorship(fixture({qa:true}).context);
});

Deno.test("every priced paid attempt reserves before dispatch and retains success liability",async()=>{
 const f=fixture();let dispatched=0;
 const value=await fundedAttempt(f.context,"copy.initial:0",step,{prompt:"private text"},{cents:2.00001,version:TARIFF_VERSION},async()=>{assertEquals(f.calls.at(-1)?.name,"serving_cost_reserve");dispatched++;return "result";});
 assertEquals(value,"result");assertEquals(dispatched,1);assertEquals(f.calls[0].args.p_hold_cents,2.0001);assertEquals(f.calls[1].args.p_state,"succeeded");
 assert(!JSON.stringify(f.calls).includes("private text"));assert(/^[a-f0-9]{64}$/.test(String(f.calls[0].args.p_input_sha256)));
});
Deno.test("failed or malformed money admission never dispatches",async()=>{
 for(const options of [{reserveError:"RP402: No funded allowance"},{reserveError:"unavailable"},{reserveShape:{reserved:false}}]){
  const f=fixture(options);let dispatched=0;
  await assertRejects(()=>fundedAttempt(f.context,"copy",step,{}, {cents:2,version:TARIFF_VERSION},async()=>{dispatched++;}),HttpError);
  assertEquals(dispatched,0);assertEquals(f.calls.length,1);
 }
});

Deno.test("missing funded activation is unavailable, exhausted interval is quota, and neither dispatches or falls back", async () => {
 const originalFetch=globalThis.fetch;globalThis.fetch=async()=>Response.json(null);
 try {
  for(const [reason,status,code] of [
   ["This workspace has no funded serving allowance",503,"upstream"],
   ["This paid service interval is not funded",503,"upstream"],
   ["This attempt exceeds the shared funded serving allowance",402,"quota_exceeded"],
  ] as const){
   const f=fixture({reserveError:`RP402: ${reason}`});let dispatched=0;
   const error=await assertRejects(()=>runChain("coach.chat",[step,{...step,model:"fallback"}],s=>
    fundedAttempt(f.context,"copy",s,{}, {cents:2,version:TARIFF_VERSION},async()=>{dispatched++;})),HttpError);
   assertEquals(error.status,status);assertEquals(error.code,code);
   assertEquals(dispatched,0);assertEquals(f.calls.filter(c=>c.name==="serving_cost_reserve").length,1);
  }
  const unrelated=fixture({reserveError:"RP402: Upgrade to use this feature"});
  const error=await assertRejects(()=>fundedAttempt(unrelated.context,"copy",step,{}, {cents:2,version:TARIFF_VERSION},async()=>{}),HttpError);
  assertEquals(error.status,402);assertEquals(error.code,"plan_required");
 } finally {globalThis.fetch=originalFetch;}
});
Deno.test("finite users cannot use unpriced averages or failed QA authority",async()=>{
 for(const options of [{},{qaError:true}]){
  const f=fixture(options);let dispatched=0;
  await assertRejects(()=>fundedAttempt(f.context,"unknown",step,{},null,async()=>{dispatched++;}),HttpError);
  assertEquals(dispatched,0);assert(!f.calls.some(c=>c.name==="serving_cost_reserve"));
 }
 const f=fixture({qa:true});await fundedAttempt(f.context,"unknown",step,{},null,async()=>"QA result");
 assertEquals(f.calls.find(c=>c.name==="serving_cost_reserve")?.args.p_tariff_version,"unpriced-private-sponsorship");
});
Deno.test("timeout and generic provider error retain liability; only proven no-queue rejection releases",async()=>{
 const uncertain=[new Error("lost acceptance"),new HttpError(502,"Vendor400"),new ProviderError("openai","upstream","Vendor500",500)];
 for(const error of uncertain){const f=fixture();await assertRejects(()=>fundedAttempt(f.context,"copy",step,{}, {cents:2,version:TARIFF_VERSION},async()=>{throw error;}));assertEquals(f.calls.at(-1)?.args.p_state,"uncertain");}
 const f=fixture();await assertRejects(()=>fundedAttempt(f.context,"copy",step,{}, {cents:2,version:TARIFF_VERSION},async()=>{throw new ProviderError("openai","validation","Rejected before queue",400,true);}));
 assertEquals(f.calls.at(-1)?.args.p_state,"rejected");assertEquals(f.calls.at(-1)?.args.p_rejection_status,400);
});
Deno.test("settlement outage preserves accepted result and committed hold",async()=>{
 const f=fixture({finishError:true});assertEquals(await fundedAttempt(f.context,"copy",step,{}, {cents:2,version:TARIFF_VERSION},async()=>"accepted"),"accepted");
 assertEquals(f.calls.map(c=>c.name),["serving_cost_reserve","serving_cost_finish"]);
});
Deno.test("raw HTTP response cannot be mistaken for validated provider success",async()=>{
 const f=fixture();await assertRejects(()=>fundedAttempt(f.context,"voice",step,{}, {cents:2,version:TARIFF_VERSION},async()=>new Response("failed",{status:503})),HttpError);
 assertEquals(f.calls.at(-1)?.args.p_state,"uncertain");
});
Deno.test("permanent logical operation admission refuses response-loss replay before any chain",async()=>{
 const seen=new Set<string>();let begins=0;
 const rpc:FundingContext["rpc"]=async(name,args)=>{
  assertEquals(name,"serving_operation_begin");begins++;
  if(seen.has(String(args.p_key)))return {data:null,error:{message:"RP409: This operation already started"}};
  seen.add(String(args.p_key));return {data:{begun:true},error:null};
 };
 const req=new Request("https://fixture.invalid/coach",{headers:{"Idempotency-Key":"same-logical-request"}});
 await fundingContext("actor","org",req,{text:"same"},rpc);
 const error=await assertRejects(()=>fundingContext("actor","org",req,{text:"same"},rpc),HttpError);assertEquals(error.status,409);assertEquals(begins,2);
});
Deno.test("zero-attempt financial refusal permits repair; owned saved result replays without dispatch",async()=>{
 let state="absent",allow=false,saved:Record<string,unknown>|null=null,dispatches=0,reserves=0;
 const rpc:FundingContext["rpc"]=async(name,args)=>{
  if(name==="serving_operation_begin"){
   if(state==="completed")return {data:{begun:false,replay:true,result:saved},error:null};
   if(state==="started")return {data:null,error:{message:"RP409: This operation already started"}};
   state="started";return {data:{begun:true},error:null};
  }
  if(name==="serving_cost_reserve"){reserves++;return allow?{data:{reserved:true},error:null}:{data:null,error:{message:"RP402: No allowance"}};}
  if(name==="serving_operation_no_dispatch"){state="not_dispatched";return {data:{retryable:true},error:null};}
  if(name==="serving_operation_complete"){saved=args.p_result as Record<string,unknown>;state="completed";return {data:{saved:true},error:null};}
  assertEquals(name,"serving_cost_finish");return {data:{finished:true},error:null};
 };
 const req=new Request("https://fixture.invalid/coach",{headers:{"Idempotency-Key":"same-repairable-request"}});
 let ctx=await fundingContext("actor","org",req,{text:"same"},rpc);
 await assertRejects(()=>fundedAttempt(ctx,"coach",step,{}, {cents:1,version:TARIFF_VERSION},async()=>{dispatches++;}),HttpError);
 assertEquals(state,"not_dispatched");allow=true;
 ctx=await fundingContext("actor","org",req,{text:"same"},rpc);
 const answer=await fundedAttempt(ctx,"coach",step,{}, {cents:1,version:TARIFF_VERSION},async()=>{dispatches++;return {reply:"saved answer"};});
 await completeFundingOperation(ctx,answer);
 const replay=await assertRejects(()=>fundingContext("actor","org",req,{text:"same"},rpc),SavedFundingResponse);
 const response=respondError(replay);assertEquals(response.status,200);assertEquals(await response.json(),answer);
 assertEquals(dispatches,1);assertEquals(reserves,2);
});
Deno.test("actual chain stops money-authority failure and duplicate stage before any fallback",async()=>{
 const oldFetch=globalThis.fetch;globalThis.fetch=async()=>Response.json(null);
 try{
  for(const reason of ["RP402: Insufficient funds","RP403: Lost authority","RP409: Already journaled","Unavailable"]){
   const f=fixture({reserveError:reason});let dispatched=0;
   await assertRejects(()=>runChain("coach.chat",[step,{...step,model:"fallback"}],s=>fundedAttempt(f.context,"coach:"+s.model,s,{}, {cents:1,version:TARIFF_VERSION},async()=>{dispatched++;return "unexpected";})),HttpError);
   assertEquals(dispatched,0);assertEquals(f.calls.filter(c=>c.name==="serving_cost_reserve").length,1);
  }
  const journal=new Set<string>();const f=fixture();
  const rpc:FundingContext["rpc"]=async(name,args)=>{
   if(name==="serving_cost_reserve"){const key=String(args.p_stage);if(journal.has(key))return {data:null,error:{message:"RP409: Already journaled"}};journal.add(key);return {data:{reserved:true},error:null};}
   return f.context.rpc(name,args);
  };
  const context={...f.context,rpc};let dispatched=0;
  const execute=()=>runChain("coach.chat",[step,{...step,model:"fallback"}],s=>fundedAttempt(context,"coach:"+s.model,s,{}, {cents:1,version:TARIFF_VERSION},async()=>{dispatched++;return "saved";}));
  assertEquals((await execute()).value,"saved");const error=await assertRejects(execute,HttpError);assertEquals(error.status,409);assertEquals(dispatched,1);
 }finally{globalThis.fetch=oldFetch;}
});
Deno.test("per logical request transport key survives retry; old helper requests have permanent scoped hash",async()=>{
 const f=fixture();const req=new Request("https://fixture.invalid/ai-copy/script",{headers:{"Idempotency-Key":"caller-request-key"}});
 assertEquals((await fundingContext("actor","org",req,{a:1},f.context.rpc)).requestKey,"caller-request-key");
 const plain=new Request("https://fixture.invalid/coach");const a=await fundingContext("actor","org",plain,{a:1},f.context.rpc);const b=await fundingContext("actor","org",plain,{a:1},f.context.rpc);assertEquals(a.requestKey,b.requestKey);
 assert(a.requestKey!==(await fundingContext("actor","org",new Request("https://fixture.invalid/ai-copy"),{a:1},f.context.rpc)).requestKey);
});
Deno.test("text prices use actual configured output ceiling and reject unknown models, tools or unbounded input",()=>{
 const base=textAttemptQuote(step,"rules","hello",300)!;
 const configured={...step,params:{max_output_tokens:8000}};
 assert(textAttemptQuote(configured,"rules","hello",300)!.cents>base.cents);
 assertEquals(textAttemptQuote({...step,model:"unknown-flat-price"},"rules","hello",300),null);
 assertEquals(textAttemptQuote(step,"x".repeat(100001),"",300),null);
});
Deno.test("photo and Seedance price authority bounds the ACTUAL adapter payload",()=>{
 const photo={...step,provider:"gemini",model:"gemini-3.1-flash-image",task:"photo.stage"};
 const payload=geminiImagePayload(photo.model,"synthetic","image/jpeg","YWJj");
 const config=payload.generationConfig as Record<string,unknown>;
 assertEquals(config.candidateCount,1);assertEquals(config.maxOutputTokens,4096);
 assertEquals(mediaAttemptQuote(photo,{task:photo.task,prompt:"synthetic"})!.cents,31.1296);
 assertEquals(geminiImageGenerationQuote(config)!.cents,31.1296);
 const video={...step,provider:"fal",model:"bytedance/seedance/v1/pro/fast/image-to-video",task:"video.reel_clip"};
 const input=falInput(video,{task:video.task,prompt:"synthetic",seconds:5,image_url:"https://fixture.invalid/source"});
 assertEquals(input.aspect_ratio,"16:9");assertEquals(input.resolution,"1080p");assertEquals(input.num_frames,121);
 const kontext=falInput({...photo,provider:"fal",model:"flux-pro/kontext"},{task:photo.task,prompt:"synthetic",image_url:"https://fixture.invalid/source"});assertEquals(kontext.num_images,1);
});

Deno.test("Gemini quote increases with the actual combined cap and rejects missing or unpriced generation shapes",()=>{
 const config=geminiImagePayload("gemini-3.1-flash-image","synthetic","image/jpeg","YWJj").generationConfig as Record<string,unknown>;
 assertEquals(geminiImageGenerationQuote({...config,maxOutputTokens:8192})!.cents,55.7056);
 assertEquals(geminiImageGenerationQuote({...config,maxOutputTokens:32768})!.cents,203.1616);
 for(const changed of [
  {maxOutputTokens:undefined},{maxOutputTokens:0},{maxOutputTokens:4096.5},{maxOutputTokens:32769},
  {maxOutputTokens:Infinity},{candidateCount:2},{candidateCount:undefined},
  {responseModalities:["TEXT","IMAGE"]},{imageConfig:{imageSize:"2K"}},
 ])assertEquals(geminiImageGenerationQuote({...config,...changed}),null);
});

Deno.test("actual Gemini HTTP payload and funded reservation share one combined token cap",async()=>{
 const originalFetch=globalThis.fetch;const originalKey=Deno.env.get("GEMINI_API_KEY");
 Deno.env.set("GEMINI_API_KEY","synthetic-not-real");
 const photo={...step,provider:"gemini",model:"gemini-3.1-flash-image",task:"photo.stage"};
 const input={task:photo.task,prompt:"synthetic",image_b64:"YWJj"};const f=fixture();let posts=0;
 let outgoing:Record<string,unknown>={};let reservedHold:unknown;
 globalThis.fetch=(async(url:string|URL|Request,init?:RequestInit)=>{
  assertEquals(String(url),"https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image:generateContent");
  assertEquals(init?.method,"POST");posts++;
  outgoing=JSON.parse(String(init?.body)).generationConfig;
  assertEquals(f.calls.at(-1)?.name,"serving_cost_reserve");
  reservedHold=f.calls.at(-1)?.args.p_hold_cents;
  return Response.json({candidates:[{content:{parts:[{inlineData:{mimeType:"image/png",data:"YWJj"}}]}}]});
 }) as typeof fetch;
 try{
  const ref=await fundedAttempt(f.context,"photo:0",photo,input,mediaAttemptQuote(photo,input),()=>geminiAdapter.submit(photo,input));
  assertEquals((await geminiAdapter.poll(ref)).status,"done");assertEquals(posts,1);
  assertEquals(outgoing.maxOutputTokens,GEMINI_IMAGE_MAX_OUTPUT_TOKENS);
  assertEquals(outgoing.candidateCount,1);assertEquals(outgoing.imageConfig,{imageSize:"1K"});
  assertEquals(outgoing.responseModalities,["IMAGE"]);
  const expected=(131072*.5+Number(outgoing.maxOutputTokens)*60)/10000;
  assertEquals(reservedHold,Math.ceil(expected*10000)/10000);
 }finally{globalThis.fetch=originalFetch;if(originalKey===undefined)Deno.env.delete("GEMINI_API_KEY");else Deno.env.set("GEMINI_API_KEY",originalKey);}
});
