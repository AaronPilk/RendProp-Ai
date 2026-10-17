// photo-feedback edge function. Closed: the RPCs, Auth and the limiter are
// synthetic; every test also installs a fetch that refuses any network, and
// the production-wiring test only answers the exact Supabase Auth/RPC paths.
// No provider, generation, quality, funding or publication RPC is reachable.
import {assert,assertEquals,assertStringIncludes} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {HttpError} from "../_shared/http.ts";
import {createPhotoFeedbackHandler,FEEDBACK_REASONS,mapRpcError,SUBMITS_PER_WINDOW,SUBMIT_WINDOW_SECONDS,READS_PER_WINDOW,type FeedbackDeps} from "./handler.ts";

const id=(n:number)=>`f8500000-0000-4000-8000-${String(n).padStart(12,"0")}`;
const actor=id(1),org=id(2),prov=id(3),feedbackId=id(4),signalId=id(5),caseId=id(6);
const ALLOWED_RPCS=["photo_feedback_submit","photo_feedback_signal","photo_feedback_state","photo_regression_case_mark"];

interface Fixture{deps:FeedbackDeps;calls:{name:string;args:Record<string,unknown>}[];limits:{key:string;max:number;window:number}[];state:{user:unknown;limit:boolean|"throw";reply:(name:string,args:Record<string,unknown>)=>{data:unknown;error:{message?:string}|null}}}
function fixture():Fixture{
 const calls:Fixture["calls"]=[],limits:Fixture["limits"]=[];
 const state:Fixture["state"]={user:{id:actor,is_anonymous:false},limit:true,reply:(name,args)=>({data:defaultReply(name,args),error:null})};
 return {calls,limits,state,deps:{
  getUser:async()=>{if(state.user===null)throw new HttpError(401,"Invalid or expired token");return state.user as {id:string;is_anonymous?:boolean};},
  rpc:async(name,args)=>{assert(ALLOWED_RPCS.includes(name),"Only feedback RPCs are reachable: "+name);calls.push({name,args});return state.reply(name,args);},
  rateLimit:async(key,max,window)=>{limits.push({key,max,window});if(state.limit==="throw")throw new HttpError(503,"Processing limits are temporarily unavailable — try again shortly.","upstream");return state.limit;},
 }};
}
function defaultReply(name:string,args:Record<string,unknown>):unknown{
 if(name==="photo_feedback_submit")return{state:"recorded",feedback_id:feedbackId,provenance_id:args.p_provenance,revision:args.p_revision,revision_count:1,verdict:args.p_verdict,reasons:args.p_reasons,note:args.p_note,updated_at:"2026-10-17T20:00:00Z",
  attribution:{basis:"evidence",evidence_id:id(7),edit:"stage",provider:"gemini",model:"gemini-3.1-flash-image",generation_stage:"photo.stage:0",recipe_revision:"photo-recipe/2026-10-17.1",prompt_sha256:"a".repeat(64),attempts_known:true}};
 if(name==="photo_feedback_signal")return{state:"recorded",signal_id:signalId,provenance_id:args.p_provenance,signal:args.p_signal,detail:args.p_detail,created_at:"2026-10-17T20:00:00Z"};
 if(name==="photo_feedback_state")return{provenance_id:args.p_provenance,feedback:null,signals:[],regression_case:null,attribution:{basis:"provenance_only"}};
 return{state:args.p_withdraw?"withdrawn":"recorded",case_id:caseId,protocol:"photo-fixed-features-v1",defect:args.p_defect,recipe_revision:null,withdrawn_at:null};
}
const submitBody=(extra:Record<string,unknown>={})=>({output:{provenance_id:prov,output_sha256:"b".repeat(64)},client_key:"studio:k-0001",revision:1,verdict:"needs_work",reasons:["blocked_doorway_or_opening"],note:"Door covered",platform:"studio",...extra});
function request(method:string,path="",body?:unknown,headers:Record<string,string>={}):Request{
 return new Request("https://db.fixture.invalid/functions/v1/photo-feedback"+path,{method,headers:{authorization:"Bearer fixture","x-org-id":org,...(body!==undefined?{"content-type":"application/json"}:{}),...headers},body:body===undefined?undefined:typeof body==="string"?body:JSON.stringify(body)});
}
async function closed<T>(work:()=>Promise<T>):Promise<T>{
 const previous=globalThis.fetch;globalThis.fetch=(()=>{throw new Error("Unexpected network call");}) as typeof fetch;
 try{return await work();}finally{globalThis.fetch=previous;}
}
async function send(f:Fixture,req:Request){return await closed(async()=>{const response=await createPhotoFeedbackHandler(f.deps)(req);return {response,body:response.status===200&&req.method==="OPTIONS"?null:await response.json()};});}

Deno.test("preflight answers without auth and allows the selected-library headers",async()=>{
 const f=fixture();const response=await closed(()=>createPhotoFeedbackHandler(f.deps)(request("OPTIONS")));
 assertEquals(response.status,200);assertStringIncludes(response.headers.get("access-control-allow-headers")!,"x-org-id");assertStringIncludes(response.headers.get("access-control-allow-headers")!,"x-rendprop-org");
 assertEquals(response.headers.get("access-control-allow-methods"),"GET, POST, OPTIONS");assertEquals(response.headers.get("cache-control"),"no-store");assertEquals(f.calls.length,0);
});
Deno.test("submit sends exactly the validated body with the caller and selected library",async()=>{
 const f=fixture();const {response,body}=await send(f,request("POST","",submitBody({output:{provenance_id:prov.toUpperCase(),output_sha256:"b".repeat(64)}})));
 assertEquals(response.status,200);assertEquals(response.headers.get("cache-control"),"no-store");assertEquals(body.state,"recorded");assertEquals(body.attribution.recipe_revision,"photo-recipe/2026-10-17.1");
 assertEquals(f.calls,[{name:"photo_feedback_submit",args:{p_actor:actor,p_selected:org,p_provenance:prov,p_output_sha256:"b".repeat(64),p_client_key:"studio:k-0001",p_revision:1,
  p_verdict:"needs_work",p_reasons:["blocked_doorway_or_opening"],p_note:"Door covered",p_platform:"studio"}}]);
 assertEquals(f.limits,[{key:"photo-feedback:"+actor,max:SUBMITS_PER_WINDOW,window:SUBMIT_WINDOW_SECONDS}]);
 assertEquals([SUBMITS_PER_WINDOW,SUBMIT_WINDOW_SECONDS],[120,600],"contract 4.5: 120 submits per 10 minutes per user");
});
Deno.test("a useful verdict needs no reasons and optional fields default to null",async()=>{
 const f=fixture();const {response}=await send(f,request("POST","",{output:{provenance_id:prov},client_key:"ios-key-0001",revision:3,verdict:"useful"}));
 assertEquals(response.status,200);
 assertEquals(f.calls[0].args,{p_actor:actor,p_selected:org,p_provenance:prov,p_output_sha256:null,p_client_key:"ios-key-0001",p_revision:3,p_verdict:"useful",p_reasons:[],p_note:null,p_platform:null});
});
Deno.test("x-rendprop-org is accepted as an alias and must agree with X-Org-Id",async()=>{
 const f=fixture();
 assertEquals((await send(f,request("POST","",submitBody(),{"x-org-id":"","x-rendprop-org":org}))).response.status,200);
 assertEquals(f.calls[0].args.p_selected,org);
 const bad=await send(f,request("POST","",submitBody(),{"x-rendprop-org":id(99)}));assertEquals(bad.response.status,400);assertEquals(bad.body.code,"invalid_request");
 const missing=await send(f,request("POST","",submitBody(),{"x-org-id":""}));assertEquals(missing.response.status,400);
 assertEquals(f.calls.length,1);
});
Deno.test("signal, state and regression-case routes call only their own RPC",async()=>{
 const f=fixture();
 const signal=await send(f,request("POST","/signal",{output:{provenance_id:prov},client_key:"sig-key-0001",signal:"manual_selection",detail:"gallery_save",platform:"ios"}));
 assertEquals(signal.response.status,200);assertEquals(signal.body.signal_id,signalId);
 const state=await send(f,request("GET","?provenance_id="+prov));assertEquals(state.response.status,200);assertEquals(state.body.provenance_id,prov);
 const keep=await send(f,request("POST","/regression-case",{output:{provenance_id:prov},defect:"blocked_doorway_or_opening",expected_behavior:"  Keep the right-hand doorway open.  ",retain_for_evaluation:true}));
 assertEquals(keep.response.status,200);assertEquals(keep.body.protocol,"photo-fixed-features-v1");
 const withdraw=await send(f,request("POST","/regression-case",{output:{provenance_id:prov},withdraw:true}));assertEquals(withdraw.body.state,"withdrawn");
 assertEquals(f.calls.map(c=>c.name),["photo_feedback_signal","photo_feedback_state","photo_regression_case_mark","photo_regression_case_mark"]);
 assertEquals(f.calls[0].args,{p_actor:actor,p_selected:org,p_provenance:prov,p_client_key:"sig-key-0001",p_signal:"manual_selection",p_detail:"gallery_save",p_platform:"ios"});
 assertEquals(f.calls[2].args,{p_actor:actor,p_selected:org,p_provenance:prov,p_defect:"blocked_doorway_or_opening",p_expected:"Keep the right-hand doorway open.",p_retain:true,p_withdraw:false});
 assertEquals(f.calls[3].args,{p_actor:actor,p_selected:org,p_provenance:prov,p_defect:null,p_expected:null,p_retain:false,p_withdraw:true});
 assertEquals(f.limits.map(l=>l.key),["photo-feedback:"+actor,"photo-feedback-read:"+actor,"photo-feedback:"+actor,"photo-feedback:"+actor]);
 assertEquals(f.limits[1].max,READS_PER_WINDOW);
});
Deno.test("keeping a case without explicit retention consent is refused before any RPC",async()=>{
 for(const consent of [undefined,false]){
  const f=fixture();const {response,body}=await send(f,request("POST","/regression-case",{output:{provenance_id:prov},defect:"other",expected_behavior:"Keep every fixed feature as photographed.",...(consent===undefined?{}:{retain_for_evaluation:consent})}));
  assertEquals(response.status,403);assertEquals(body.code,"evaluation_consent_required");assertEquals(f.calls.length,0);
 }
});
Deno.test("shape violations are 400 invalid_request with no RPC",async()=>{
 const cases:[string,unknown][]=[
  ["",{...submitBody(),verdict:"great"}],["",{...submitBody(),reasons:["not_a_reason"]}],["",{...submitBody(),verdict:"useful"}],["",{...submitBody(),reasons:[]}],
  ["",{...submitBody(),reasons:["other","other"]}],["",{...submitBody(),note:"n".repeat(501)}],["",{...submitBody(),client_key:"short"}],["",{...submitBody(),client_key:"has space key"}],
  ["",{...submitBody(),revision:0}],["",{...submitBody(),revision:1.5}],["",{...submitBody(),revision:"1"}],["",{...submitBody(),extra:true}],["",{...submitBody(),platform:"android"}],
  ["",{...submitBody(),output:{provenance_id:"not-a-uuid"}}],["",{...submitBody(),output:{provenance_id:prov,output_sha256:"B".repeat(64)}}],["",{...submitBody(),output:{provenance_id:prov,other:1}}],
  ["",[submitBody()]],["","not json"],
  ["/signal",{output:{provenance_id:prov},client_key:"sig-key-0001",signal:"liked"}],["/signal",{output:{provenance_id:prov},client_key:"sig-key-0001",signal:"export",detail:"printed"}],
  ["/signal",{output:{provenance_id:prov,output_sha256:"b".repeat(64)},client_key:"sig-key-0001",signal:"export"}],
  ["/regression-case",{output:{provenance_id:prov},defect:"personal_style_preference",expected_behavior:"Taste is not a defect to keep.",retain_for_evaluation:true}],
  ["/regression-case",{output:{provenance_id:prov},defect:"other",expected_behavior:"too short",retain_for_evaluation:true}],
  ["/regression-case",{output:{provenance_id:prov},withdraw:"yes"}],
 ];
 for(const [path,body] of cases){
  const f=fixture();const result=await send(f,request("POST",path,body));
  assertEquals(result.response.status,400,JSON.stringify(body));assertEquals(result.body.code,"invalid_request");assertEquals(f.calls.length,0,JSON.stringify(body));
 }
 const f=fixture();
 const plain=await send(f,new Request("https://db.fixture.invalid/functions/v1/photo-feedback",{method:"POST",headers:{authorization:"Bearer fixture","x-org-id":org,"content-type":"text/plain"},body:JSON.stringify(submitBody())}));
 assertEquals(plain.response.status,400);
 for(const query of ["","?provenance_id=nope","?provenance_id="+prov+"&provenance_id="+prov,"?provenance_id="+prov+"&debug=1"]){
  const result=await send(f,request("GET",query));assertEquals(result.response.status,400,query);
 }
 assertEquals(f.calls.length,0);
 assertEquals(FEEDBACK_REASONS.length,8);
});
Deno.test("auth, anonymity, routing and rate limits refuse before any RPC",async()=>{
 const f=fixture();f.state.user=null;
 let r=await send(f,request("POST","",submitBody()));assertEquals(r.response.status,401);assertEquals(r.body.code,"unauthorized");assertEquals(f.limits.length,0);
 f.state.user={id:actor,is_anonymous:true};r=await send(f,request("POST","",submitBody()));assertEquals(r.response.status,403);assertEquals(r.body.code,"forbidden");
 f.state.user={id:actor,is_anonymous:false};
 r=await send(f,request("GET","/signal"));assertEquals(r.response.status,405);
 r=await send(f,request("POST","/delete",submitBody()));assertEquals(r.response.status,404);assertEquals(r.body.code,"not_found");
 f.state.limit=false;r=await send(f,request("POST","",submitBody()));assertEquals(r.response.status,429);assertEquals(r.body.code,"rate_limited");
 f.state.limit="throw";r=await send(f,request("POST","",submitBody()));assertEquals(r.response.status,503);assertEquals(r.body.code,"upstream");
 assertEquals(f.calls.length,0);
});
Deno.test("deliberate SQL refusals map to contract codes and raw database text never leaks",async()=>{
 const table:[string,number,string][]=[
  ["RP404: This photo is unavailable in the selected library",404,"output_not_found"],["RP403: A current editor of this library is required",403,"forbidden"],
  ["RP403: A current named editor is required",403,"forbidden"],["RP403: CONSENT Explicit permission to keep this photo for evaluation is required",403,"evaluation_consent_required"],
  ["RP409: FEEDBACK_KEY_CONFLICT This feedback key already belongs to another photo",409,"feedback_key_conflict"],
  ["RP409: FEEDBACK_REVISION_CONFLICT Bump the feedback revision to change it",409,"feedback_revision_conflict"],
  ["RP409: OUTPUT_MISMATCH The pinned photo bytes differ from the retained result",409,"output_mismatch"],
  ["RP409: EVIDENCE_UNAVAILABLE This photo has no retained evidence to evaluate against",409,"evidence_unavailable"],
  ["RP400: A bounded photo feedback verdict is required",400,"invalid_request"],
  ["duplicate key value violates unique constraint \"photo_output_feedback_provenance_id_actor_id_key\"",503,"upstream"],
  ["canceling statement due to statement timeout",503,"upstream"],
 ];
 for(const [message,status,code] of table){
  const f=fixture();f.state.reply=()=>({data:null,error:{message}});
  const {response,body}=await send(f,request("POST","",submitBody()));
  assertEquals([response.status,body.code],[status,code],message);
  assert(!JSON.stringify(body).includes("photo_output_feedback_provenance_id_actor_id_key"),"No constraint names reach a client");
  assert(!JSON.stringify(body).includes("RP4"),"No internal prefixes reach a client");
  if(status===404)assertEquals(body.error,"This photo is unavailable in the selected library.");
 }
 assertEquals(mapRpcError("RP409: The recipe is immutable").code,"conflict");
 const f=fixture();f.state.reply=()=>{throw new Error("socket hang up");};
 const {response,body}=await send(f,request("GET","?provenance_id="+prov));assertEquals([response.status,body.code],[503,"upstream"]);
});
Deno.test("an existing verdict under another key answers 409 feedback_exists with the key to adopt",async()=>{
 const f=fixture();f.state.reply=()=>({data:{state:"conflict",code:"feedback_exists",feedback_id:feedbackId,provenance_id:prov,client_key:"ios:original-key",revision:4,revision_count:2},error:null});
 const {response,body}=await send(f,request("POST","",submitBody({client_key:"studio:another-key"})));
 assertEquals(response.status,409);assertEquals(body.code,"feedback_exists");assertEquals(body.client_key,"ios:original-key");assertEquals(body.revision,4);assertEquals(body.revision_count,2);
});
Deno.test("an unconfirmable RPC answer is a retryable 503, never a false success",async()=>{
 for(const data of [null,[],{state:"recorded",provenance_id:id(42),feedback_id:feedbackId},{state:"saved",provenance_id:prov,feedback_id:feedbackId},{state:"recorded",provenance_id:prov}]){
  const f=fixture();f.state.reply=()=>({data,error:null});
  const {response,body}=await send(f,request("POST","",submitBody()));assertEquals([response.status,body.code],[503,"upstream"],JSON.stringify(data));
 }
});

// The production wiring (index.ts) through the real Supabase client and
// limiter, against a closed transport that answers only the exact Auth/RPC paths.
Deno.test("production wiring authenticates, rate-limits and calls only the feedback RPC with the service key",async()=>{
 const serviceKey="sb_secret_"+"f".repeat(24);
 const env={SUPABASE_URL:"https://feedback-db.fixture.invalid",SUPABASE_ANON_KEY:"public-fixture",SUPABASE_SERVICE_ROLE_KEY:"service-fixture",SUPABASE_SECRET_KEYS:JSON.stringify({default:serviceKey}),RENDPROP_SECRET_KEY_NAME:"default"};
 const previous=Object.fromEntries(Object.keys(env).map(k=>[k,Deno.env.get(k)]));for(const [k,v] of Object.entries(env))Deno.env.set(k,v);
 const seen:string[]=[];let rpcBody:unknown=null;
 const priorFetch=globalThis.fetch;
 globalThis.fetch=(async(raw:Request|URL|string,init?:RequestInit)=>{
  const req=new Request(raw,init),url=new URL(req.url);seen.push(req.method+" "+url.pathname);
  if(url.hostname!=="feedback-db.fixture.invalid")throw new Error("Unexpected network host "+url.hostname);
  if(url.pathname==="/auth/v1/user")return Response.json({id:actor,is_anonymous:false,aud:"authenticated"});
  assertEquals(req.headers.get("apikey"),serviceKey);
  if(url.pathname==="/rest/v1/rpc/bump_rate")return Response.json(true);
  if(url.pathname==="/rest/v1/rpc/photo_feedback_submit"){rpcBody=await req.json();return Response.json(defaultReply("photo_feedback_submit",rpcBody as Record<string,unknown>));}
  throw new Error("Unexpected path "+url.pathname);
 }) as typeof fetch;
 try{
  const {handler}=await import("./index.ts");
  const response=await handler(request("POST","",submitBody()));
  assertEquals(response.status,200,await response.clone().text());assertEquals((await response.json()).state,"recorded");
  assertEquals(rpcBody,{p_actor:actor,p_selected:org,p_provenance:prov,p_output_sha256:"b".repeat(64),p_client_key:"studio:k-0001",p_revision:1,p_verdict:"needs_work",p_reasons:["blocked_doorway_or_opening"],p_note:"Door covered",p_platform:"studio"});
  assertEquals(seen,["GET /auth/v1/user","POST /rest/v1/rpc/bump_rate","POST /rest/v1/rpc/photo_feedback_submit"]);
 }finally{
  globalThis.fetch=priorFetch;for(const [k,v] of Object.entries(previous))if(v===undefined)Deno.env.delete(k);else Deno.env.set(k,v);
 }
});
