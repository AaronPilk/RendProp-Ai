import {assertEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {anthropicMessages,anthropicStopReason,ANTHROPIC_DEFAULT_MAX_TOKENS,type AnthropicStopReason} from "./anthropic.ts";

// Closed actual adapter transport only: no provider request/key is used.
Deno.test("Anthropic completion telemetry is a closed enum with no provider body leakage",()=>{
 for(const reason of ["end_turn","max_tokens","stop_sequence","tool_use","pause_turn","refusal","model_context_window_exceeded"]as const)assertEquals(anthropicStopReason(reason),reason);
 for(const value of [null,undefined,{},42,"https://private.invalid/capability","unexpected-private-text"])assertEquals(anthropicStopReason(value),"unknown");
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
