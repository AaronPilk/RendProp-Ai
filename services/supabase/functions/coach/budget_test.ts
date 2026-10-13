import { assert, assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { boundedCoachChain, boundedCoachTurn, coachAttemptQuote, coachPromptBytes, COACH_MAX_PROMPT_BYTES, COACH_MAX_OUTPUT_TOKENS } from "./budget.ts";
import { buildUserTurn, systemInstruction, reelStateOf } from "./prompt.ts";
import { paramsOf, type RouteStep } from "../_shared/router.ts";
import { textAttemptQuote } from "../_shared/funded-serving.ts";
import { anthropicMaxTokens } from "../_shared/providers/anthropic.ts";
import { openaiChatConfig } from "../_shared/providers/openai.ts";

const id = "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb";
const steps: RouteStep[] = [
 {route_id:"a",task:"coach.chat",provider:"anthropic",model:"claude-sonnet-5",unit:"call",unit_cents:2.1,capabilities:["text","chat"],max_latency_s:30,min_plan:"free",same_model_as:null,privacy_tier:"retained_30d",enabled:true},
 {route_id:"b",task:"coach.chat",provider:"openai",model:"gpt-5.6-terra",unit:"call",unit_cents:2,capabilities:["text","chat"],max_latency_s:30,min_plan:"free",same_model_as:null,privacy_tier:"retained_30d",enabled:true},
];
const context = {plan:"pro",screen:"reel_studio",selectedListingId:id,listings:[{id,title:'A title "quoted"',hasVideo:false,roomTags:0,hasTour:false,published:false,photos:8,edits:0,reels:0}]};

Deno.test("coach actual prompt uses screen/intent, correct feature facts and no forced walkthrough", () => {
 const system = systemInstruction("real_estate");
 assert(system.includes("walkthrough video is NOT required"));
 assert(!system.includes("nothing else can start before it"));
 assert(system.includes("identified account"));
 assert(!system.includes("Sign in with Apple is optional"));
 assert(system.includes("simulated") && system.includes("not real drone footage"));
 assert(!system.includes("word-by-word captions that land on the beat"));
 const turn=buildUserTurn({space:"real_estate",context,history:[{role:"user",content:"How do I make this reel?"}]});
 assert(turn.includes("CURRENT SCREEN HELP: Reel Studio"));
 assert(turn.includes("Recover request") && turn.includes("not physical whereabouts"));
 assert(turn.includes('title="A title \\"quoted\\""'));
 for(const screen of ["photos","photo_studio","files","plan","settings"]){
  const scoped=buildUserTurn({space:"real_estate",context:{...context,screen},history:[{role:"user",content:"What do I do here?"}]});
  assert(scoped.includes("CURRENT SCREEN HELP:"));
 }
});

Deno.test("coach state sanitation drops free text, unauthorized/other-screen and invalid counts", () => {
 const state={phase:"paused",completed:3,total:8,still_photo_shots:1,status:"secret raw text",lat:1};
 assertEquals(reelStateOf(state,"reel_studio",id),{phase:"paused",completed:3,total:8,stillPhotoShots:1});
 for(const value of [{...state,phase:"PRIVATE"},{...state,completed:9},{...state,total:101},{...state,completed:"3"},{...state,still_photo_shots:4},[],null]) assertEquals(reelStateOf(value,"reel_studio",id),null);
 assertEquals(reelStateOf(state,"photos",id),null);
 assertEquals(reelStateOf(state,"reel_studio",null),null);
});

Deno.test("coach budget pins actual adapter caps, keeps eligible order and at most two attempts", () => {
 const injected=steps.map(s=>({...s,params:{max_output_tokens:8000,effort:"low"}}));
 const bounded=boundedCoachChain([...injected,...injected],"system","turn");
 assertEquals(bounded.length,2);
 assertEquals(bounded.map(s=>s.route_id),["a","b"]);
 assertEquals(anthropicMaxTokens(paramsOf(bounded[0]),8000),600);
 assertEquals(openaiChatConfig(paramsOf(bounded[1]),8000).maxOutputTokens,600);
 assertEquals(paramsOf(injected[0])?.max_output_tokens,8000,"operator object must not be mutated");
 const maxText="x".repeat(COACH_MAX_PROMPT_BYTES-7);
 assertEquals(coachPromptBytes("",maxText),COACH_MAX_PROMPT_BYTES);
 const max=boundedCoachChain(steps,"",maxText);
 const prices=max.map(s=>coachAttemptQuote(s,"",maxText)!.cents);
 assertEquals(prices,[6.1296,7.812]);
 assert(prices.reduce((a,b)=>a+b,0)<16);
});

Deno.test("coach refuses unknown/high tariff/oversized inputs before any dispatch", () => {
 for(const bad of [{...steps[0],model:"unknown"},{...steps[0],unit_cents:9},{...steps[0],unit:"second"},{...steps[0],provider:"gemini",model:"gemini-3.8-flash"}]) assertThrows(()=>boundedCoachChain([bad],"system","turn"));
 assertThrows(()=>boundedCoachChain(steps,"s","x".repeat(COACH_MAX_PROMPT_BYTES)));
 const long={space:"real_estate" as const,context,history:[{role:"assistant" as const,content:"界".repeat(10000)},{role:"user" as const,content:"Keep my latest question"}]};
 const turn=boundedCoachTurn(systemInstruction("real_estate"),long);
 assert(coachPromptBytes(systemInstruction("real_estate"),turn)<=COACH_MAX_PROMPT_BYTES);
 assert(turn.includes("Keep my latest question") && !turn.includes("界"));
 assert(turn.includes(id),"selected project retained");
});

async function mutatedBudget(before: string, after: string) {
 let source=await Deno.readTextFile(new URL("./budget.ts",import.meta.url));
 assertEquals(source.split(before).length-1,1,"mutation must hit one production anchor");
 source=source.replace(before,after).replace(/from "([^"]+)";/g,(_all,path)=>`from ${JSON.stringify(new URL(path,import.meta.url).href)};`);
 return await import(`data:application/typescript;base64,${btoa(unescape(encodeURIComponent(source)))}`);
}

Deno.test("coach compiled budget controls detect enlarged prompt/chain/output/catalog", async () => {
 const output=await mutatedBudget("max_output_tokens: COACH_MAX_OUTPUT_TOKENS","max_output_tokens: 8000");
 assertThrows(()=>output.boundedCoachChain(steps,"s","t"));
 const chain=await mutatedBudget("steps.slice(0, COACH_MAX_ATTEMPTS)","steps");
 assertEquals(chain.boundedCoachChain([...steps,...steps],"s","t").length,4,"control must expose unwanted extra attempts");
 const prompt=await mutatedBudget("COACH_MAX_PROMPT_BYTES = 26_624","COACH_MAX_PROMPT_BYTES = 65_536");
 const args={space:"real_estate" as const,context,history:[{role:"user" as const,content:"x".repeat(40_000)}]};
 assertThrows(()=>boundedCoachTurn("s",args));
 assert(coachPromptBytes("s",prompt.boundedCoachTurn("s",args))>COACH_MAX_PROMPT_BYTES,"control must expose oversized prompt");
 const catalog=await mutatedBudget(" || catalog.cents > COACH_MAX_ATTEMPT_CENTS","");
 assertEquals(catalog.boundedCoachChain([{...steps[0],unit_cents:99}],"s","t").length,1,"control must expose unbounded catalog hold");
});

Deno.test("coach actual provider HTTP serializers carry 600-token ceilings despite configured 8000", async () => {
 const {anthropicMessages}=await import("../_shared/providers/anthropic.ts");
 const {openaiChat}=await import("../_shared/providers/openai.ts");
 const originalFetch=globalThis.fetch, originalGet=Deno.env.get;
 const bodies: Record<string,unknown>[]=[];
 // Closed transport/key seam: never read real credentials or dispatch network.
 Deno.env.get=(name:string)=>["ANTHROPIC_API_KEY","OPENAI_API_KEY"].includes(name)?"synthetic-not-a-key":undefined;
 globalThis.fetch=async(_url,options)=>{
  const body=JSON.parse(String((options as {body?: unknown})?.body));bodies.push(body);
  return new Response(JSON.stringify(body.model.startsWith("claude")?{content:[{type:"text",text:'{"reply":"Synthetic","actions":[],"suggested_replies":[]}'}]}:{status:"completed",output:[{type:"message",content:[{type:"output_text",text:'{"reply":"Synthetic","actions":[],"suggested_replies":[]}'}]}]}),{status:200,headers:{"content-type":"application/json"}});
 };
 try{
  const bounded=boundedCoachChain(steps.map(s=>({...s,params:{max_output_tokens:8000}})),"s","t");
  await anthropicMessages({model:bounded[0],system:"s",content:[{type:"text",text:"t"}],maxTokens:8000});
  await openaiChat(bounded[1],[{role:"user",content:[{type:"input_text",text:"s\n\n---\n\nt"}]}],{maxOutputTokens:8000,json:true});
  assertEquals(bodies.length,2);
  assertEquals(bodies[0].max_tokens,600);
  assertEquals(bodies[1].max_output_tokens,600);
  assertEquals(bodies[1].tools,undefined);
 }finally{globalThis.fetch=originalFetch;Deno.env.get=originalGet;}
});
