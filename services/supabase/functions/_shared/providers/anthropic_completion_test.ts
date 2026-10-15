import {assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {anthropicMessages,anthropicStopReason,anthropicRequestTimeout,ANTHROPIC_DEFAULT_MAX_TOKENS,type AnthropicStopReason} from "./anthropic.ts";
import {PHOTO_QC_JSON_SCHEMA} from "../../ai-photo/photo-qc-verdict.ts";

// Closed actual adapter transport only: no provider request/key is used.
Deno.test("Anthropic completion telemetry is a closed enum with no provider body leakage",()=>{
 for(const reason of ["end_turn","max_tokens","stop_sequence","tool_use","pause_turn","refusal","model_context_window_exceeded"]as const)assertEquals(anthropicStopReason(reason),reason);
 for(const value of [null,undefined,{},42,"https://private.invalid/capability","unexpected-private-text"])assertEquals(anthropicStopReason(value),"unknown");
});
Deno.test("explicit server photo schema reaches actual Messages wire without changing ordinary or video requests",async()=>{
 const previousFetch=globalThis.fetch,previousKey=Deno.env.get("ANTHROPIC_API_KEY");Deno.env.set("ANTHROPIC_API_KEY","closed-fixture-no-provider-key");
 try{
  const sent:any[]=[];globalThis.fetch=async(_input,init)=>{sent.push(JSON.parse(String((init as {body?:unknown})?.body)));return Response.json({content:[{type:"text",text:"{}"}],stop_reason:"end_turn"});};
  for(const model of["claude-sonnet-5","claude-haiku-4-5"])await anthropicMessages({model,content:[{type:"text",text:"unchanged video/classifier"}]});
  await anthropicMessages({model:"claude-sonnet-5",content:[{type:"text",text:"photo"}],maxTokens:4096,jsonSchema:PHOTO_QC_JSON_SCHEMA});
  assertEquals(sent[0],{model:"claude-sonnet-5",max_tokens:400,messages:[{role:"user",content:[{type:"text",text:"unchanged video/classifier"}]}],output_config:{effort:"low"}});
  assertEquals(sent[1],{model:"claude-haiku-4-5",max_tokens:400,messages:[{role:"user",content:[{type:"text",text:"unchanged video/classifier"}]}]});
  assertEquals(sent[2].output_config,{effort:"low",format:{type:"json_schema",schema:PHOTO_QC_JSON_SCHEMA}});
  for(const args of[{model:"claude-haiku-4-5",jsonSchema:PHOTO_QC_JSON_SCHEMA},{model:"claude-sonnet-5",jsonSchema:{...PHOTO_QC_JSON_SCHEMA,additionalProperties:true}},{model:"claude-sonnet-5",jsonSchema:{...PHOTO_QC_JSON_SCHEMA,description:"x".repeat(8193)}}])
   await assertRejects(()=>anthropicMessages({...args,content:[]}as any),Error,"Unsupported server structured-output contract");
  assertEquals(sent.length,3,"Unsupported contracts refuse before provider transport");
 }finally{globalThis.fetch=previousFetch;if(previousKey===undefined)Deno.env.delete("ANTHROPIC_API_KEY");else Deno.env.set("ANTHROPIC_API_KEY",previousKey);}
});
Deno.test("Anthropic explicit90second server request uses its real timeout while absent still uses30seconds",async()=>{
 assertEquals(anthropicRequestTimeout(),30000);assertEquals(anthropicRequestTimeout(90000),90000);assertEquals(anthropicRequestTimeout(300000),90000);assertEquals(anthropicRequestTimeout(15000),15000);
 const previousFetch=globalThis.fetch,previousKey=Deno.env.get("ANTHROPIC_API_KEY"),previousTimeout=AbortSignal.timeout;
 Deno.env.set("ANTHROPIC_API_KEY","closed-fixture-no-provider-key");
 try{
  for(const timeoutMs of[undefined,90000]){
   const timers:number[]=[];
   AbortSignal.timeout=(delay:number)=>{timers.push(delay);return previousTimeout(delay);};
   globalThis.fetch=async()=>Response.json({content:[{type:"text",text:"ok"}],stop_reason:"end_turn"});
   assertEquals(await anthropicMessages({model:"claude-sonnet-5",content:[{type:"text",text:"synthetic"}],timeoutMs}),"ok");
   assertEquals(timers,[timeoutMs??30000]);
  }
 }finally{globalThis.fetch=previousFetch;AbortSignal.timeout=previousTimeout;if(previousKey===undefined)Deno.env.delete("ANTHROPIC_API_KEY");else Deno.env.set("ANTHROPIC_API_KEY",previousKey);}
});
Deno.test("photo caller may reserve4096 while shared400 default remains unchanged; real stop reason and usage are retained",async()=>{
 const previousFetch=globalThis.fetch,previousKey=Deno.env.get("ANTHROPIC_API_KEY");Deno.env.set("ANTHROPIC_API_KEY","closed-fixture-no-provider-key");
 try{
  for(const [budget,reason]of[[4096,"max_tokens"],[undefined,"end_turn"],[4096,undefined]]as const){
   let sent:any,completion:AnthropicStopReason|undefined,usage:unknown;
   globalThis.fetch=async(_input,init)=>{sent=JSON.parse(String((init as {body?:unknown})?.body));return new Response(JSON.stringify({content:[{type:"text",text:'{"incomplete":true}'}],stop_reason:reason,usage:{input_tokens:20000,output_tokens:reason==="max_tokens"?4096:20}}),{headers:{"Content-Type":"application/json"}});};
   assertEquals(await anthropicMessages({model:"claude-sonnet-5",content:[{type:"text",text:"closed synthetic input"}],maxTokens:budget,onStopReason:value=>{completion=value;},onUsage:value=>{usage=value;}}),'{"incomplete":true}');
   assertEquals(sent.max_tokens,budget??ANTHROPIC_DEFAULT_MAX_TOKENS);assertEquals(sent.output_config,{effort:"low"});
   assertEquals(completion,reason??"unknown");assertEquals(usage,{inputTokens:20000,outputTokens:reason==="max_tokens"?4096:20});
  }
 }finally{globalThis.fetch=previousFetch;if(previousKey===undefined)Deno.env.delete("ANTHROPIC_API_KEY");else Deno.env.set("ANTHROPIC_API_KEY",previousKey);}
});
