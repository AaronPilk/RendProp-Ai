import {assert, assertEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {buildUserTurn,photoStateOf,reelStateOf,systemInstruction} from "./prompt.ts";
import {knowledgeBlock,PLAN_ALLOWANCES} from "./knowledge.ts";
import {CoachUsageEvidence,tokenUsageOf} from "./usage.ts";
import {anthropicMessages} from "../_shared/providers/anthropic.ts";
import {openaiChat} from "../_shared/providers/openai.ts";

const id="aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb";
Deno.test("support: closed photo hints require current screen and authorized selected project",()=>{
 const raw={tab:"staged",selected_count:4,preview_url:"PRIVATE",style:"PRIVATE",version_id:"PRIVATE"};
 assertEquals(photoStateOf(raw,"photo_studio",id),{tab:"staged",selectedCount:4});
 for(const bad of [{...raw,tab:"PRIVATE"},{...raw,selected_count:-1},{...raw,selected_count:1001},{...raw,selected_count:1.5},null,[]])assertEquals(photoStateOf(bad,"photo_studio",id),null);
 assertEquals(photoStateOf(raw,"home",id),null);assertEquals(photoStateOf(raw,"photo_studio",null),null);
 const turn=buildUserTurn({space:"real_estate",context:{plan:"free",screen:"photo_studio",selectedListingId:id,listings:[],photoState:photoStateOf(raw,"photo_studio",id)},history:[{role:"user",content:"What do I do here?"}]});
 assert(turn.includes('"tab":"staged"')&&turn.includes("Original is the editing source"));assert(!turn.includes("PRIVATE"));
});
Deno.test("support: background guidance cannot be inferred from a local phase or unaccepted operation",()=>{
 const raw={phase:"generating",completed:1,total:4,still_photo_shots:0};
 assertEquals(reelStateOf(raw,"reel_studio",id)?.execution,"legacy_local");
 assertEquals(reelStateOf({...raw,execution:"awaiting_acceptance"},"reel_studio",id)?.serverPhase,null);
 assertEquals(reelStateOf({...raw,execution:"server_accepted"},"reel_studio",id),null);
 assertEquals(reelStateOf({...raw,execution:"server_accepted",server_phase:"PRIVATE"},"reel_studio",id),null);
 assertEquals(reelStateOf({...raw,execution:"server_accepted",server_phase:"ready",resume_available:true},"reel_studio",id),null);
 const accepted=reelStateOf({...raw,execution:"server_accepted",server_phase:"failed",resume_available:true,error:"PRIVATE"},"reel_studio",id)!;
 assertEquals(accepted.resumeAvailable,true);assertEquals(Object.keys(accepted).sort(),["completed","execution","phase","resumeAvailable","serverPhase","stillPhotoShots","total"].sort());
 const text=systemInstruction("real_estate");assert(text.includes("acknowledged saved server job")&&text.includes("Older device-owned batches"));
 assert(text.includes("Share controls. Branded and unbranded links are available without a recorded walkthrough"));
 assert(!text.includes("open that project's finished tour, where both"));
});
Deno.test("support: actual knowledge has photo-first flow, shot meters and truthful website previews",()=>{
 assertEquals(PLAN_ALLOWANCES.map(v=>v.reels),[30,60,150]);
 const text=knowledgeBlock();
 for(const phrase of ["address and details","edit from Original","earlier styles","generated five-second shots","Classic is included","per-property","switching between the two","already-published content","neither publishes nor changes","Contemporary","historical style","Never invent nearby businesses","not a replacement for the verified account snapshot"])
  assert(text.includes(phrase),`Missing actual support fact: ${phrase}`);
 assert(!text.includes("6 reels")&&!text.includes("12 reels")&&!text.includes("25 reels"));
});
Deno.test("support: measured tokens are closed evidence; estimates and unavailable usage stay explicit",()=>{
 const evidence=new CoachUsageEvidence();
 evidence.begin("coach.chat:0",{provider:"anthropic",model:"synthetic",unit_cents:2.1})({inputTokens:100,outputTokens:20,cacheReadInputTokens:40,cacheCreationInputTokens:5,prompt:"PRIVATE"});
 evidence.begin("coach.chat:1",{provider:"openai",model:"synthetic",unit_cents:2})({inputTokens:-1,outputTokens:1});
 const meta=evidence.metadata();assertEquals(meta[0],{stage:"coach.chat:0",provider:"anthropic",model:"synthetic",catalog_estimate_cents:2.1,counts_status:"provider_reported",input_tokens:100,output_tokens:20,cache_read_input_tokens:40,cache_creation_input_tokens:5,supplier_invoice_verified:false});
 assertEquals(meta[1].counts_status,"unavailable");assert(!JSON.stringify(meta).includes("PRIVATE"));
 for(const bad of [null,[],{inputTokens:NaN,outputTokens:1},{inputTokens:1,outputTokens:Infinity},{inputTokens:1.5,outputTokens:0},{inputTokens:2147483648,outputTokens:0}])assertEquals(tokenUsageOf(bad),null);
});
Deno.test("support: both actual HTTP adapters expose provider usage without changing request budgets",async()=>{
 const fetchBefore=globalThis.fetch,getBefore=Deno.env.get;const bodies:Record<string,unknown>[]=[];
 Deno.env.get=(name:string)=>["ANTHROPIC_API_KEY","OPENAI_API_KEY"].includes(name)?"synthetic-not-a-key":undefined;
 globalThis.fetch=async(_url,options)=>{
  const body=JSON.parse(String((options as {body?:unknown})?.body));bodies.push(body);
  return new Response(JSON.stringify(body.model==="synthetic-anthropic"?{content:[{type:"text",text:"synthetic"}],usage:{input_tokens:120,output_tokens:12,cache_read_input_tokens:50,cache_creation_input_tokens:5}}:{status:"completed",output:[{type:"message",content:[{type:"output_text",text:"synthetic"}]}],usage:{input_tokens:80,output_tokens:10}}),{status:200,headers:{"content-type":"application/json"}});
 };
 try{
  const evidence=new CoachUsageEvidence();
  assertEquals(await anthropicMessages({model:"synthetic-anthropic",content:[{type:"text",text:"synthetic"}],maxTokens:600,onUsage:evidence.begin("coach.chat:0",{provider:"anthropic",model:"synthetic-anthropic",unit_cents:2.1})}),"synthetic");
  assertEquals(await openaiChat("synthetic-openai",[{role:"user",content:[{type:"input_text",text:"synthetic"}]}],{maxOutputTokens:600,onUsage:evidence.begin("coach.chat:1",{provider:"openai",model:"synthetic-openai",unit_cents:2})}),"synthetic");
  assertEquals(evidence.metadata().map(v=>[v.input_tokens,v.output_tokens]),[[120,12],[80,10]]);
  assertEquals(bodies.map(v=>v.max_tokens??v.max_output_tokens),[600,600]);assert(bodies.every(v=>v.onUsage===undefined));
 }finally{globalThis.fetch=fetchBefore;Deno.env.get=getBefore;}
});
