import {assert,assertEquals,assertRejects,assertThrows,AssertionError} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {anthropicMessages} from "../_shared/providers/anthropic.ts";
import {HttpError} from "../_shared/http.ts";
import {inputHash,resetServingModeCache} from "../_shared/funded-serving.ts";
import {decodePhotoOutput} from "./input-policy.ts";
import {PHOTO_QC_POLICY,PHOTO_QC_JSON_SCHEMA,unavailablePhotoQuality,parsePhotoQuality,type PhotoQualityVerdict} from "./photo-qc-verdict.ts";
import {beginPhotoQuality,retainPhotoCandidate,statusPhotoQuality,photoQualityResponse,photoBytesHash,failPhotoQuality,throwPhotoQualityState,type PhotoQualityEnvelope,type PhotoEvidenceIO} from "./photo-qc-store.ts";
import {continuePhotoQuality,photoJudgeQuote,photoJudgeRubric,photoJudgeTimeout,PHOTO_QC_MAX_OUTPUT_TOKENS,PHOTO_QC_JUDGE_CONTRACT,PHOTO_QC_OUTPUT_FORMAT,photoDerivatives,type PhotoJudgeDependencies} from "./photo-qc-runner.ts";
import {calibrationRequest,beginPhotoCalibration} from "./photo-qc-calibration.ts";
import {photoResultKeys} from "./photo-result.ts";
const actor="ea100606-0000-4000-8000-000000000001",org="ea100606-0000-4000-8000-000000000002",listing="ea100606-0000-4000-8000-000000000003",evidence="ea100606-0000-4000-8000-000000000004",check="ea100606-0000-4000-8000-000000000005",lease="ea100606-0000-4000-8000-000000000006",reservation="ea100606-0000-4000-8000-000000000007";
const jpeg=(width=1024,height=768)=>new Uint8Array([255,216,255,192,0,11,8,height>>8,height&255,width>>8,width&255,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]);
const b64=(bytes:Uint8Array)=>btoa(String.fromCharCode(...bytes));
const pass={policy:PHOTO_QC_POLICY,verdict:"pass",action:"accept",confidence:.99,preservation:{geometry:100,openings:100,fixtures:100,surfaces:100,viewpoint:100},artifacts:100,edit_quality:100,findings:[],reason:"Visible fixed features preserved."};
const step={route_id:"existing-approved-sonnet",task:"judge.qc_drift",provider:"anthropic",model:"claude-sonnet-5",unit:"call",unit_cents:1.3,capabilities:["classifier","vision","multi_image"],max_latency_s:60,min_plan:"free",same_model_as:null,privacy_tier:"retained_30d" as const,enabled:true};
async function fixture(){
 const input=jpeg(),output=jpeg(3584,4780),inputSHA=await photoBytesHash(input),outputSHA=await photoBytesHash(output);
 const identity={actorId:actor,orgId:org,requestKey:"photo-qc-runtime-fixture",listingId:listing};
 const state={row:null as PhotoQualityEnvelope|null,enabled:true,current:true,library:org,readWithdraw:false,wrongPutHash:false,corruptGet:false,headChanged:false,beginArgs:null as any,rpcs:[] as string[],puts:0,reads:0,claims:0,binds:0,calls:0,holds:0,ledger:[] as any[],attempt:null as any,operation:false,operationInputSHA:"",verdict:JSON.stringify(pass),lostReply:false,missingLedger:false,calledTimeout:0,stopReason:"end_turn" as import("../_shared/providers/anthropic.ts").AnthropicStopReason,objects:new Map<string,{bytes:Uint8Array<ArrayBuffer>;mime:string;sha256:string;etag:string}>()};
 const view=()=>{const row=structuredClone(state.row!);row.can_continue=!!row.evidence.output_etag&&["pending","derivative_ready"].includes(row.check.state)&&row.check.judge_started_at===null&&(!state.attempt||state.attempt.state==="rejected");return row;};
 const unavailable=()=>({data:null,error:{message:"RP404: Current selected library is unavailable"}});
 const admin:any={from:(table:string)=>{const query:any={select:()=>query,eq:()=>query,in:()=>query,limit:async()=>({data:[],error:null}),maybeSingle:async()=>{
  if(table==="app_config")return{data:{value:{enabled:state.enabled,approved_judge:{provider:"anthropic",model:"claude-sonnet-5"}}},error:null};
  if(table==="private_ai_outputs"){const e=state.row!.evidence,file=e.output!;return{data:state.row!.check.state==="accept"?{org_id:org,user_id:actor,listing_id:listing,bucket:"renders",storage_key:file.key,bytes:file.bytes}:null,error:null};}
  throw Error("Unexpected table "+table);
 }};return query;},rpc:async(name:string,args:any)=>{
  state.rpcs.push(name);
  if(name==="library_actor_billing_org")return{data:org,error:null};
  if(name==="listing_library_scope")return state.current?{data:{actor_id:actor,listing_id:listing,org_id:org,library_org_id:state.library,billing_org_id:org,team_org_id:null,library_owner_user_id:actor,listing_owner_user_id:actor,role:"owner",access_mode:"own",can_read:true,can_write:true,can_manage_subscription:true},error:null}:unavailable();
  if(name==="photo_quality_begin"){
   if(!state.enabled)return{data:null,error:{message:"RP503: Photo quality review is not active yet"}};
   if(state.row)return{data:{...view(),created:false},error:null};state.beginArgs=args;
   state.row={evidence:{id:evidence,actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,request_key:identity.requestKey,request_sha256:await inputHash({image_b64:b64(input)}),policy:PHOTO_QC_POLICY,edit:"stage",style:"modern",input:{...args.p_input,bucket:"renders",key:`ai-router/${org}/photo-evidence/${actor}/${evidence}/input.jpg`},output:null,input_etag:null,output_etag:null,state:"pending",provenance_id:null,generation_stage:null,generation_provider:null,generation_model:null},check:{id:check,evidence_id:evidence,policy:PHOTO_QC_POLICY,state:"pending",lease_token:null,lease_until:null,judge_started_at:null,derivatives:null,derivative_manifest_sha256:null},can_continue:false,created:true};
   return{data:view(),error:null};
  }
  if(name==="photo_quality_status"||name==="photo_quality_lookup")return !state.current||args.p_actor!==actor?unavailable():{data:state.row?view():null,error:null};
  if(name==="photo_quality_set_context"){
   const e=state.row!.evidence;assertEquals(args.p_request_sha256,e.request_sha256);assertEquals(args.p_context.edit,e.edit);assertEquals(args.p_context.style,e.style);
   if(e.judge_context&&JSON.stringify(e.judge_context)!==JSON.stringify(args.p_context))return{data:null,error:{message:"RP409: Saved judge context is immutable"}};
   e.judge_context=args.p_context;return{data:view(),error:null};
  }
  if(name==="photo_quality_evidence_receipt"){
   const e=state.row!.evidence;
   if(args.p_kind==="input"){e.input_etag=args.p_etag;e.state="input_ready";}
   else{e.output_etag=args.p_etag;e.state="evidence_ready";e.provenance_id="ea100606-0000-4000-8000-000000000008";}
   return{data:view(),error:null};
  }
  if(name==="photo_quality_evidence_reserve"){
   const {generation_stage,provider,model,...facts}=args.p_output,e=state.row!.evidence;
   e.output={...facts,bucket:"renders",key:`ai-router/${org}/photo-evidence/${actor}/${evidence}/candidate.jpg`};e.generation_stage=generation_stage;e.generation_provider=provider;e.generation_model=model;
   return{data:structuredClone(e),error:null};
  }
  if(name==="photo_quality_failure"){state.row!.evidence.state="hold";state.row!.evidence.failure={phase:args.p_phase,facts:args.p_facts};state.row!.check.state="hold";return{data:view(),error:null};}
  if(name==="photo_quality_claim"){
   state.claims++;if(state.row!.check.state!=="derivative_ready"||state.row!.check.judge_started_at)return{data:{action:"wait",...view()},error:null};
   state.row!.check.lease_token=lease;state.row!.check.lease_until=new Date(Date.now()+600000).toISOString();return{data:{action:"judge",...view()},error:null};
  }
  if(name==="serving_operation_begin"){if(state.operation)return{data:null,error:{message:"RP409: This operation already started"}};state.operation=true;state.operationInputSHA=args.p_input_sha256;return{data:{begun:true},error:null};}
  if(name==="serving_cost_reserve"){
   if(state.attempt)return{data:null,error:{message:"RP409: This provider attempt is already journaled"}};
   state.holds++;state.attempt={...args,id:reservation,state:"reserved"};return{data:{reserved:true,id:reservation},error:null};
  }
  if(name==="photo_quality_check_bind"){
   assertEquals(state.attempt?.state,"reserved");assertEquals(args.p_reservation,reservation);assertEquals(args.p_lease,lease);assertEquals(state.calls,0);
   state.binds++;state.row!.check.state="checking";state.row!.check.judge_started_at=new Date().toISOString();state.row!.evidence.state="checking";return{data:view(),error:null};
  }
  if(name==="serving_cost_finish"){state.attempt.state=args.p_state;return{data:{finished:true},error:null};}
  if(name==="photo_quality_finish"){
   assertEquals(state.attempt.state,"succeeded");assertEquals(state.binds,1);assertEquals(args.p_lease,lease);
   const accepted=state.ledger.length===1&&args.p_result.action==="accept",s=accepted?"accept":args.p_result.action==="refuse"&&!state.missingLedger?"refuse":"hold";
   state.row!.check.state=s;state.row!.check.result=args.p_result;state.row!.evidence.state=s;return{data:view(),error:null};
  }
  if(name==="serving_operation_complete")return{data:{saved:true},error:null};
  if(name==="serving_operation_no_dispatch")return{data:{retryable:false},error:null};
  if(name==="hosting_retention_state")return{data:{org_id:org,policy:"preserved",protected:true,retention_ends_at:null,hosting_available:true},error:null};
  if(name==="media_delivery_admit")return{data:{admitted:true,legacy_unbudgeted:true},error:null};
  throw Error("Unexpected RPC "+name);
 }};
 const io:PhotoEvidenceIO={write:async(key,bytes,mime,sha256)=>{state.puts++;if(!state.objects.has(key))state.objects.set(key,{bytes:bytes.slice(),mime,sha256:state.wrongPutHash?"f".repeat(64):sha256,etag:'"exact-etag"'});},inspect:async key=>{const object=state.objects.get(key);return object?{bytes:object.bytes.length,mime:object.mime,sha256:object.sha256,etag:state.headChanged?'"other-etag"':object.etag}:null;},read:async key=>{state.reads++;const bytes=state.objects.get(key)!.bytes.slice();if(state.corruptGet)bytes[2]^=1;if(state.readWithdraw)state.current=false;return bytes;}};
 const begin=()=>beginPhotoQuality(admin,identity,{edit:"stage",style:"modern",imageB64:b64(input),mime:"image/jpeg"},io);
 const retain=async()=>{const row=await begin();return await retainPhotoCandidate(admin,row,decodePhotoOutput(b64(output),"image/jpeg"),{stage:"photo.stage:0",provider:"gemini",model:"gemini-3.1-flash-image"},io);};
 const prepare=async()=>{
  await retain();const files=[];
  for(const region of ["whole","tl","tr","bl","br"] as const)for(const role of ["source","candidate"] as const){const data=jpeg(region==="whole"?1536:768,region==="whole"?2048:1024);files.push({bucket:"renders" as const,key:`ai-router/${org}/photo-evidence/${actor}/${evidence}/checks/${check}/${role}-${region}.jpg`,role,region,bytes:data.length,sha256:await photoBytesHash(data),mime:"image/jpeg",width:region==="whole"?1536:768,height:region==="whole"?2048:1024,etag:'"derivative"'});}
  state.row!.check.derivatives=files;state.row!.check.derivative_manifest_sha256="a".repeat(64);state.row!.check.state="derivative_ready";return view();
 };
 const deps:PhotoJudgeDependencies={plan:async()=>"free",routes:async()=>[step],read:async file=>jpeg(file.width,file.height),call:async(_step,_rubric,content,onUsage,options)=>{assertEquals(state.binds,1);assertEquals(state.attempt.state,"reserved");assertEquals(state.row!.check.state,"checking");assertEquals(content.length,20);assertEquals(options?.jsonSchema,PHOTO_QC_JSON_SCHEMA);assert(options!.timeoutMs>0&&options!.timeoutMs<=90_000);state.calledTimeout=options!.timeoutMs;state.calls++;if(state.lostReply)throw Error("Synthetic lost supplier reply");onUsage({inputTokens:18000,outputTokens:state.stopReason==="max_tokens"?PHOTO_QC_MAX_OUTPUT_TOKENS:160});options?.onStopReason(state.stopReason);return state.verdict;},report:async()=>{},ledger:async(_admin,args)=>{if(!state.missingLedger)state.ledger.push(args);return{recorded:!state.missingLedger,total_cents:args.unitCents};}};
 const run=(row:PhotoQualityEnvelope,runner=continuePhotoQuality)=>runner(admin,row,{actor,selected:org,request:new Request("https://example.invalid/ai-photo",{method:"POST",headers:{"X-Org":org}})},deps);
 return{state,admin,io,identity,input,output,inputSHA,outputSHA,view,begin,retain,prepare,deps,run};
}

Deno.test("prospective source/candidate are exact immutable private evidence; original bytes unchanged",async()=>{
 const f=await fixture(),before=f.input.slice();const first=await f.begin();assertEquals(first.created,true);assertEquals(first.evidence.input.sha256,f.inputSHA);assertEquals(f.state.beginArgs.p_legacy_keys.length,3);assert(f.state.beginArgs.p_legacy_keys.every((k:string)=>k.includes("/completed-photo/")));
 const again=await f.begin();assertEquals(again.created,false);assertEquals(f.state.puts,1,"A replay does not own another source PUT/generation");
 const row=await retainPhotoCandidate(f.admin,first,decodePhotoOutput(b64(f.output),"image/jpeg"),{stage:"photo.stage:0",provider:"gemini",model:"gemini-3.1-flash-image"},f.io);
 assertEquals(row.evidence.output?.sha256,f.outputSHA);assertEquals(row.check.state,"pending");assertEquals(f.input,before);assert(!f.state.rpcs.includes("register_private_ai_output"));
 const error=await assertRejects(()=>photoQualityResponse(f.admin,row,actor,org,{},f.io),HttpError);assertEquals(error.code,"photo_quality_pending");assertEquals(error.details?.check_id,check);assertEquals(error.details?.retry_existing_job,true);assertEquals(error.details?.image_b64,undefined);assertEquals(error.details?.asset_key,undefined);assertEquals(f.state.reads,0);
});
Deno.test("policy disabled refuses before source PUT and no provider reservation",async()=>{
 const f=await fixture();f.state.enabled=false;await assertRejects(f.begin,HttpError,"not active");assertEquals(f.state.puts,0);assertEquals(f.state.holds,0);assertEquals(f.state.calls,0);
});
Deno.test("equal-size immutable existing object with a different hash cannot be receipted",async()=>{
 const f=await fixture();f.state.wrongPutHash=true;await assertRejects(f.begin,HttpError,"exact private photo bytes");assert(!f.state.rpcs.includes("photo_quality_evidence_receipt"));assertEquals(f.state.row?.check.state,"hold");assertEquals(f.state.calls,0);
});
Deno.test("status scopes current actor/library and never generates, claims or judges",async()=>{
 const f=await fixture();await f.retain();const before=f.state.rpcs.length;await statusPhotoQuality(f.admin,actor,check,org);
 assertEquals(f.state.rpcs.slice(before),["photo_quality_status","listing_library_scope"]);assertEquals(f.state.claims,0);assertEquals(f.state.calls,0);
 await assertRejects(()=>statusPhotoQuality(f.admin,actor,check,"ea100606-0000-4000-8000-000000000099"),HttpError,"selected library");
 await assertRejects(()=>statusPhotoQuality(f.admin,"ea100606-0000-4000-8000-000000000099",check,org),HttpError);
 f.state.current=false;await assertRejects(()=>statusPhotoQuality(f.admin,actor,check,org),HttpError);
});
Deno.test("accepted delivery verifies promotion, exact bytes and fresh authority after read",async()=>{
 const f=await fixture();await f.retain();f.state.row!.evidence.state="accept";f.state.row!.check.state="accept";
 const response=await photoQualityResponse(f.admin,f.view(),actor,org,{},f.io),body=await response.json();assertEquals(body.image_b64,b64(f.output));assertEquals(body.photo_quality.state,"accept");assertEquals(body.provenance.recorded,true);assertEquals(body.selected_library_org_id,org);
 f.state.corruptGet=true;await assertRejects(()=>photoQualityResponse(f.admin,f.view(),actor,org,{},f.io),HttpError,"bytes changed");
 f.state.corruptGet=false;f.state.readWithdraw=true;await assertRejects(()=>photoQualityResponse(f.admin,f.view(),actor,org,{},f.io),HttpError);
});
Deno.test("fresh accepted reply reuses only its exact already-validated inline candidate receipt",async()=>{
 const f=await fixture();await f.retain();f.state.row!.evidence.state="accept";f.state.row!.check.state="accept";
 const row=f.view(),file=row.evidence.output!,inline={imageB64:b64(f.output),key:file.key,mime:file.mime,sha256:file.sha256,bytes:file.bytes};
 const response=await photoQualityResponse(f.admin,row,actor,org,{},f.io,inline);assertEquals((await response.json()).image_b64,b64(f.output));assertEquals(f.state.reads,0);
 await assertRejects(()=>photoQualityResponse(f.admin,row,actor,org,{},f.io,{...inline,sha256:"f".repeat(64)}),HttpError,"identity changed");
});
Deno.test("missing saved custom/staging context holds before normal funding and cannot be replaced by caller text",async()=>{
 const f=await fixture(),row=await f.prepare();row.evidence.judge_context=null;f.state.row!.evidence.judge_context=null;
 const result=await f.run(row);assertEquals(result.check.state,"hold");assertEquals(f.state.holds,0);assertEquals(f.state.calls,0);
});
Deno.test("oversize paid failure remains explicit and cannot advertise a saved result",async()=>{
 const f=await fixture();await f.begin();const row=await failPhotoQuality(f.admin,f.view(),"photo_output_size",{provider_cost_incurred:true,retained_output:false});
 const error=assertThrows(()=>throwPhotoQualityState(row,org),HttpError,"could not be saved");assertEquals(error.code,"photo_quality_hold");assertEquals(error.details?.provider_cost_incurred,true);assertEquals(error.details?.retained_output,false);assertEquals(error.details?.asset_key,undefined);
});
Deno.test("Sonnet5 quote covers native whole images and all quadrants; no low-resolution generic estimate",()=>{
 const quote=photoJudgeQuote(step,"a".repeat(8192),"source whole\ncandidate whole")!;
 assertEquals(quote.inputBound,2*4784+8*1369+8192+"source whole\ncandidate whole".length+new TextEncoder().encode(JSON.stringify(PHOTO_QC_OUTPUT_FORMAT)).byteLength+1024);assert(quote.inputBound>10*2048+1024);assert(quote.cents>6);assertEquals(photoJudgeQuote({...step,model:"claude-haiku-4-5"},"r","l"),null);
 assertEquals(PHOTO_QC_MAX_OUTPUT_TOKENS,4096);for(const tokens of[400,4095,4097,8000])assertEquals(photoJudgeQuote({...step,params:{max_output_tokens:tokens}} as any,"r","l"),null);assert(photoJudgeQuote({...step,params:{max_output_tokens:4096}} as any,"r","l"));assertEquals(photoJudgeQuote(step,"a".repeat(12289),""),null);
});
async function structuredContractOracle(runner=continuePhotoQuality){
 const f=await fixture(),ready=await f.prepare(),previousFetch=globalThis.fetch,previousKey=Deno.env.get("ANTHROPIC_API_KEY");resetServingModeCache();
 Deno.env.set("ANTHROPIC_API_KEY","closed-fixture-no-provider-key");let wire:any;
 f.deps.call=async(s,rubric,content,onUsage,options)=>{assertEquals(f.state.binds,1);f.state.calls++;return await anthropicMessages({model:s,system:rubric,content,maxTokens:4096,onUsage,...options});};
 globalThis.fetch=async(url,init)=>{assertEquals(String(url),"https://api.anthropic.com/v1/messages");wire=JSON.parse(String((init as {body?:unknown})?.body));return Response.json({content:[{type:"text",text:JSON.stringify(pass)}],stop_reason:"end_turn",usage:{input_tokens:18000,output_tokens:160}});};
 try{
  const result=await f.run(ready,runner);assertEquals(result.check.state,"accept");assertEquals(f.state.calls,1);
  assertEquals(wire.output_config,{effort:"low",format:PHOTO_QC_OUTPUT_FORMAT});assertEquals(wire.max_tokens,4096);assertEquals(wire.messages[0].content.length,20);
  const files=photoDerivatives(ready),rubric=photoJudgeRubric({edit:"stage",style:"modern",instruction:""}),labels=files.map(file=>`${file.role.toUpperCase()} ${file.region}`).join("\n");
  const inputBound=2*4784+8*1369+new TextEncoder().encode(rubric+labels+JSON.stringify(PHOTO_QC_OUTPUT_FORMAT)).byteLength+1024;
  const binding={policy:PHOTO_QC_POLICY,judge_contract:"photo-qc-furniture-reflections-v5",check_id:check,evidence_id:evidence,prepared_sha256:f.inputSHA,output_sha256:f.outputSHA,derivative_manifest_sha256:"a".repeat(64),rubric,output_format:PHOTO_QC_OUTPUT_FORMAT,images:files.map(file=>({role:file.role,region:file.region,sha256:file.sha256,bytes:file.bytes,width:file.width,height:file.height})),input_token_bound:inputBound,max_output_tokens:4096};
  assertEquals(f.state.operationInputSHA,await inputHash(binding));assertEquals(f.state.attempt.p_input_sha256,await inputHash(binding));assertEquals(f.state.ledger[0].meta.input_token_bound,inputBound);
  assertEquals(f.state.ledger[0].meta.parse_diagnostic,{reason:"verified",response_sha256:await photoBytesHash(new TextEncoder().encode(JSON.stringify(pass))),response_bytes:new TextEncoder().encode(JSON.stringify(pass)).byteLength});
 }finally{globalThis.fetch=previousFetch;resetServingModeCache();if(previousKey===undefined)Deno.env.delete("ANTHROPIC_API_KEY");else Deno.env.set("ANTHROPIC_API_KEY",previousKey);}
}
Deno.test("actual photo runner and Messages adapter bind, quote and send the identical structured format",()=>structuredContractOracle());
Deno.test("compiled removal of structured wire, immutable binding or schema pricing fails independent oracle",async()=>{
 const file=new URL("./photo-qc-runner.ts",import.meta.url),source=(await Deno.readTextFile(file)).replace(/from "(\.\.?\/[^\"]+)"/g,(_match,path)=>`from "${new URL(path,file).href}"`);
 for(const[anchor,replacement]of[["jsonSchema:PHOTO_QC_JSON_SCHEMA,",""],["output_format:PHOTO_QC_OUTPUT_FORMAT,",""],["rubric+labels+formatJSON","rubric+labels"]]){
  assertEquals(source.split(anchor).length-1,1);const module=await import("data:application/typescript;base64,"+btoa(unescape(encodeURIComponent(source.replace(anchor,replacement)))));
  await assertRejects(()=>structuredContractOracle(module.continuePhotoQuality),AssertionError);
 }
});
Deno.test("unverified end_turn response stores only closed parse reason, exact byte count and SHA; no repeat",async()=>{
 for(const[raw,reason]of[["PRIVATE provider prose ü","invalid_json"],[JSON.stringify({...pass,unexpected:"PRIVATE property observation"}),"schema"]]){
  const f=await fixture(),ready=await f.prepare();f.state.verdict=raw;const previousFetch=globalThis.fetch;resetServingModeCache();globalThis.fetch=(()=>{throw Error("No external transport in QC fixture");})as any;
  try{const result=await f.run(ready);assertEquals(result.check.state,"hold");const diagnostic=f.state.ledger[0].meta.parse_diagnostic;
   assertEquals(diagnostic,{reason,response_sha256:await photoBytesHash(new TextEncoder().encode(raw)),response_bytes:new TextEncoder().encode(raw).byteLength});
   assert(!JSON.stringify(f.state.ledger).includes("PRIVATE"));assert(!JSON.stringify(result.check.result).includes("PRIVATE"));await f.run(ready);assertEquals(f.state.calls,1);
  }finally{globalThis.fetch=previousFetch;resetServingModeCache();}
 }
});
Deno.test("photo verdict contract quotes the complete4096 output budget and fits all eight concise findings",async()=>{
 const rubric=photoJudgeRubric({edit:"stage",style:"modern",instruction:"Preserve the fixed room features."});
 assert(rubric.includes("at most3000UTF-8 bytes"));assert(rubric.includes("Never omit an axis"));
 const f=await fixture(),ready=await f.prepare(),before=globalThis.fetch;resetServingModeCache();globalThis.fetch=(()=>{throw Error("No external transport in QC fixture");})as any;
 const finding={category:"openings",region:"tr",source:"Original opaque covering remains in this region.",output:"The candidate replaces the covered area with clear glazing.",certainty:"confirmed"};
 f.state.verdict=JSON.stringify({...pass,verdict:"fail",action:"refuse",preservation:{...pass.preservation,openings:35},findings:Array.from({length:8},()=>finding),reason:"Confirmed fixed-feature differences in the marked regions."});
 assert(new TextEncoder().encode(f.state.verdict).byteLength<=3000);
 try{
  const result=await f.run(ready);assertEquals(result.check.state,"refuse");assertEquals((result.check.result as PhotoQualityVerdict).findings.length,8);
  const cost=f.state.ledger[0];assertEquals(cost.meta.max_output_tokens,4096);assertEquals(cost.meta.judge_contract,PHOTO_QC_JUDGE_CONTRACT);assertEquals(cost.meta.provider_stop_reason,"end_turn");
  assertEquals(f.state.attempt.p_hold_cents,cost.unitCents);assertEquals(f.state.calls,1);
  await f.run(ready);assertEquals(f.state.calls,1,"A confirmed terminal result is never rerolled");
 }finally{globalThis.fetch=before;resetServingModeCache();}
});
Deno.test("next photo judge contract distinguishes loose console decor from protected mounted fixtures",()=>{
 const rubric=photoJudgeRubric({edit:"stage",style:"modern",instruction:"Stage this room."});
 assertEquals(PHOTO_QC_JUDGE_CONTRACT,"photo-qc-furniture-reflections-v5");
 for(const required of["Loose tabletop/freestanding decor is NOT a fixture","decorative plates, books, vases","picture frames resting on a console","mounted wall art or a built-in installation","Report findings ONLY for suspected fixed-feature","Do not include permitted movable-decor/furniture changes as findings","retain a specific uncertain finding about that fixed feature"]){assert(rubric.includes(required),required);}
 const finding={category:"fixtures",region:"br",source:"Loose picture frame resting on a console.",output:"Different loose tabletop decor.",certainty:"uncertain"};
 // Even an incorrectly classified model answer is NOT silently cleared by
 // this prompt clarification. The existing strict parser still requires HOLD.
 assertEquals(parsePhotoQuality(JSON.stringify({...pass,findings:[finding]})).action,"hold");
 assert(photoJudgeQuote(step,rubric,"SOURCE whole\nCANDIDATE whole"));
});
Deno.test("prospective furniture/reflection context is funded and cannot erase uncertainty or a real redesign",async()=>{
 const rubric=photoJudgeRubric({edit:"declutter",instruction:""});
 assert(rubric.includes("Freestanding TV consoles, tables and chairs are furniture, not installed fixtures."));
 assert(rubric.includes("Concrete unpermitted furniture redesign remains an edit-quality failure"));
 const quote=photoJudgeQuote(step,rubric,"SOURCE whole\nCANDIDATE whole")!;
 assertEquals(quote.textBytes,new TextEncoder().encode(rubric+"SOURCE whole\nCANDIDATE whole"+JSON.stringify(PHOTO_QC_OUTPUT_FORMAT)).byteLength);
 for(const kind of["uncertain_furniture","confirmed_redesign","uncertain_structure"]){
  const f=await fixture(),ready=await f.prepare();f.state.row!.evidence.edit="declutter";f.state.row!.evidence.style=null;f.state.row!.evidence.judge_context={edit:"declutter",style:null,instruction:""};
  const finding={category:"fixtures",region:"bl",source:kind==="uncertain_structure"?"Existing wall opening partially covered.":"Freestanding glossy console partly occluded.",output:kind==="confirmed_redesign"?"Visible console changed from a rectangular cabinet to a curved bench.":"Different reflection or newly exposed surface.",certainty:kind==="confirmed_redesign"?"confirmed":"uncertain"};
  f.state.verdict=JSON.stringify({...pass,...(kind==="confirmed_redesign"?{verdict:"fail",action:"refuse",edit_quality:35}:{}),findings:[finding]});
  const before=globalThis.fetch;resetServingModeCache();globalThis.fetch=(()=>{throw Error("No external transport in QC fixture");})as any;
  try{const result=await f.run(f.view());assertEquals(result.check.state,kind==="confirmed_redesign"?"refuse":"hold");assertEquals((result.check.result as PhotoQualityVerdict).findings,[finding]);assertEquals(f.state.ledger[0].meta.judge_contract,"photo-qc-furniture-reflections-v5");await f.run(ready);assertEquals(f.state.calls,1);}finally{globalThis.fetch=before;resetServingModeCache();}
 }
});
Deno.test("one photo judge may use90seconds but leaves10seconds and obeys the actual remaining endpoint budget",async()=>{
 assertEquals(photoJudgeTimeout(120000,0),90000);assertEquals(photoJudgeTimeout(45000,0),35000);
 assertEquals(photoJudgeTimeout(10000,0),0);assertEquals(photoJudgeTimeout(9000,0),0);
 const f=await fixture(),ready=await f.prepare(),before=globalThis.fetch;resetServingModeCache();globalThis.fetch=(()=>{throw Error("No external transport in QC fixture");})as any;
 try{await f.run(ready);assertEquals(f.state.calls,1);assert(f.state.calledTimeout>89000&&f.state.calledTimeout<=90000);}finally{globalThis.fetch=before;resetServingModeCache();}
 const short=await fixture(),pending=await short.prepare();
 const result=await continuePhotoQuality(short.admin,pending,{actor,selected:org,request:new Request("https://example.invalid/ai-photo"),deadline:Date.now()+9000},short.deps);
 assertEquals(result.check.state,"derivative_ready");assertEquals(short.state.holds,0);assertEquals(short.state.calls,0);
});
Deno.test("truncated or non-final photo verdict stays HOLD even when its returned text is valid pass JSON",async()=>{
 for(const reason of ["max_tokens","refusal","pause_turn","unknown"]as const)for(const truncated of reason==="max_tokens"?[false,true]:[false]){
  const f=await fixture(),ready=await f.prepare(),before=globalThis.fetch;resetServingModeCache();globalThis.fetch=(()=>{throw Error("No external transport in QC fixture");})as any;
  f.state.stopReason=reason;if(truncated)f.state.verdict=f.state.verdict.slice(0,-5);
  try{
   const result=await f.run(ready);assertEquals(result.check.state,"hold");assertEquals((result.check.result as PhotoQualityVerdict).verdict,"unknown");
   assert((result.check.result as PhotoQualityVerdict).reason.includes(reason));assertEquals(f.state.ledger[0].meta.provider_stop_reason,reason);
   assertEquals(f.state.calls,1);assertEquals(f.state.holds,1);assertEquals(f.state.attempt.state,"succeeded");
   await f.run(ready);assertEquals(f.state.calls,1,"An inconclusive paid verdict cannot automatically buy a second judge");
  }finally{globalThis.fetch=before;resetServingModeCache();}
 }
});
Deno.test("incomplete/repeated/cross-operation/over-bound comparison never reaches a judge",async()=>{
 for(const kind of ["duplicate","cross_operation","aggregate"]){const f=await fixture();const row=await f.prepare();
  if(kind==="duplicate")row.check.derivatives![1]=row.check.derivatives![0];
  if(kind==="cross_operation")row.check.derivatives![0].key=row.check.derivatives![0].key.replace(check,lease);
  if(kind==="aggregate")for(const file of row.check.derivatives!)file.bytes=600001;
  assertThrows(()=>photoDerivatives(row),HttpError);await f.run(row);assertEquals(f.state.calls,0);assertEquals(f.state.holds,0);
 }
});
Deno.test("evidence pending and unapproved route/config never reserve a judge or CPU lease",async()=>{
 const f=await fixture();await f.retain();await f.run(f.view());assertEquals(f.state.claims,0);assertEquals(f.state.calls,0);
 const ready=await f.prepare();f.state.enabled=false;await f.run(ready);assertEquals(f.state.holds,0);f.state.enabled=true;f.deps.routes=async()=>[{...step,model:"claude-haiku-4-5"}];await f.run(ready);assertEquals(f.state.holds,0);assertEquals(f.state.claims,0);
});
Deno.test("one funded judge binds before POST and matching ledger precedes atomic accept; stale replay cannot redispatch",async()=>{
 const f=await fixture(),ready=await f.prepare(),before=globalThis.fetch;resetServingModeCache();globalThis.fetch=(()=>{throw Error("No external transport in QC fixture");}) as any;
 try{const result=await f.run(ready);assertEquals(result.check.state,"accept");assertEquals(f.state.holds,1);assertEquals(f.state.binds,1);assertEquals(f.state.calls,1);assertEquals(f.state.ledger.length,1);const cost=f.state.ledger[0];assertEquals(cost.meta.prepared_sha256,f.inputSHA);assertEquals(cost.meta.output_sha256,f.outputSHA);assertEquals(cost.meta.derivative_manifest_sha256,"a".repeat(64));assertEquals(cost.meta.request_key,`photo-qc:${check}`);assertEquals(cost.feature,"qc");assertEquals(f.state.attempt.state,"succeeded");
  await f.run(ready);assertEquals(f.state.calls,1);assertEquals(f.state.holds,1);
 }finally{globalThis.fetch=before;resetServingModeCache();}
});
Deno.test("lost judge reply retains uncertain liability and HOLD; missing ledger/malformed verdict never accept",async()=>{
 for(const kind of ["lost","ledger","malformed"]){const f=await fixture(),ready=await f.prepare(),before=globalThis.fetch;resetServingModeCache();globalThis.fetch=(()=>{throw Error("No external transport in QC fixture");}) as any;
  if(kind==="lost")f.state.lostReply=true;if(kind==="ledger")f.state.missingLedger=true;if(kind==="malformed")f.state.verdict="Not a JSON verdict";
  try{const result=await f.run(ready);assertEquals(result.check.state,"hold");assertEquals(f.state.calls,1);assertEquals(f.state.attempt.state,kind==="lost"?"uncertain":"succeeded");await f.run(ready);assertEquals(f.state.calls,1);assertEquals(f.state.holds,1);}finally{globalThis.fetch=before;resetServingModeCache();}
 }
 assertEquals(unavailablePhotoQuality().action,"hold");
});

async function historicalFixture(){
 const f=await fixture(),old={image_b64:b64(f.input),mime:"image/jpeg",edit:"stage",style:"modern",listing_id:listing,original_asset_id:"ea100606-0000-4000-8000-000000000009"},keys=await photoResultKeys(f.identity),key=keys["image/jpeg"];
 const originalPointer={kind:"photo_output",bucket:"renders",key,mime:"image/jpeg",metadata:{edit:"stage",style:"modern",provenance:{id:"historical-provenance",recorded:true}}};
 const historic={operation:{state:"completed",input_sha256:await inputHash(old),operation:"/ai-photo"},result:{result:originalPointer},owned:{org_id:org,user_id:actor,listing_id:listing,bucket:"renders",storage_key:key,bytes:f.output.length},costs:[{provider:"gemini",model:"gemini-3.1-flash-image",total_cents:16.7584,meta:{stage:"photo.stage:0",request_key:f.identity.requestKey}}],paid:true,reads:0};
 const originalFrom=f.admin.from,originalRPC=f.admin.rpc;
 f.admin.from=(table:string)=>{
  if(!["serving_operations","serving_operation_results","private_ai_outputs","cost_ledger","serving_cost_reservations"].includes(table))return originalFrom(table);
  const query:any={select:()=>query,eq:()=>query,limit:async()=>({data:historic.costs,error:null}),maybeSingle:async()=>({data:table==="serving_operations"?historic.operation:table==="serving_operation_results"?historic.result:table==="private_ai_outputs"?historic.owned:historic.paid?{id:reservation}:null,error:null})};return query;
 };
 f.admin.rpc=async(name:string,args:any)=>{
  if(name!=="photo_quality_calibration_begin")return await originalRPC(name,args);
  const enabled=f.state.enabled;f.state.enabled=true;const result=await originalRPC("photo_quality_begin",args);f.state.enabled=enabled;
  f.state.row!.evidence.purpose="calibration";f.state.row!.evidence.request_sha256=args.p_request_sha256;
  return{data:{...f.view(),created:result.data.created},error:null};
 };
 const raw={generation_request_key:f.identity.requestKey,generation_request_body:old};
 const run=()=>beginPhotoCalibration(f.admin,{actor,org,selected:org,body:calibrationRequest(raw)},{evidence:f.io,read:async()=>{historic.reads++;return f.output.slice();}});
 return{...f,historic,raw,run};
}
Deno.test("explicit historical calibration binds old hash/owned pointer/payment and only copies private evidence",async()=>{
 const f=await historicalFixture(),old=JSON.stringify(f.historic);f.state.enabled=false;
 const row=await f.run();assertEquals(row.evidence.purpose,"calibration");assertEquals(row.evidence.output?.sha256,f.outputSHA);assertEquals(f.state.puts,2);assertEquals(f.state.holds,0);assertEquals(f.state.calls,0);assertEquals(f.state.ledger.length,0);assertEquals(f.historic.reads,1);
 f.historic.reads=0;assertEquals(JSON.stringify(f.historic),old,"Old result pointer/provenance/owned receipt stay identical");
 await f.run();assertEquals(f.state.puts,2,"An existing calibration does not write evidence again");
});
Deno.test("calibration rejects changed source body, foreign saved key, missing ownership or payment before copying",async()=>{
 for(const fault of ["hash","pointer","owner","payment"]){const f=await historicalFixture();
  if(fault==="hash")f.raw.generation_request_body.style="rustic";
  if(fault==="pointer")f.historic.result.result.key="ai-router/foreign/completed-photo/"+"a".repeat(64)+".jpg";
  if(fault==="owner")f.historic.owned.user_id=org;
  if(fault==="payment")f.historic.paid=false;
  await assertRejects(f.run,HttpError);assertEquals(f.state.puts,0);assertEquals(f.historic.reads,0);assertEquals(f.state.calls,0);assertEquals(f.state.holds,0);
 }
});
Deno.test("calibration terminal status is verdict-only and never advertises a ready image or ordinary asset",async()=>{
 const f=await historicalFixture();await f.run();f.state.row!.evidence.state="accept";f.state.row!.check.state="accept";f.state.row!.check.result=pass;
 const response=await photoQualityResponse(f.admin,f.view(),actor,org,{},f.io),body=await response.json();assertEquals(body.publishable,false);assertEquals(body.purpose,"calibration");assertEquals(body.result,pass);assertEquals(body.image_b64,undefined);assertEquals(body.asset_key,undefined);assertEquals(f.state.reads,0);
});

Deno.test("concurrent cron and client continuations share one funded bind and one judge",async()=>{
 const f=await fixture(),ready=await f.prepare(),previous=globalThis.fetch;resetServingModeCache();globalThis.fetch=(()=>{throw Error("No external transport in concurrent QC fixture");}) as any;
 try{
  const results=await Promise.all([f.run(ready),f.run(ready)]);
  assert(results.some(row=>row.check.state==="accept"));assertEquals(f.state.holds,1);assertEquals(f.state.binds,1);assertEquals(f.state.calls,1);assertEquals(f.state.ledger.length,1);assertEquals(f.state.attempt.state,"succeeded");
  await Promise.all([f.run(ready),f.run(ready)]);assertEquals(f.state.holds,1);assertEquals(f.state.binds,1);assertEquals(f.state.calls,1);
 }finally{globalThis.fetch=previous;resetServingModeCache();}
});
Deno.test("a cron arriving during a judge or after its lost reply cannot dispatch another paid check",async()=>{
 for(const lost of[false,true]){
  const f=await fixture(),ready=await f.prepare(),previous=globalThis.fetch;resetServingModeCache();globalThis.fetch=(()=>{throw Error("No external transport in held judge fixture");}) as any;
  let entered!:()=>void,release!:()=>void;const started=new Promise<void>(resolve=>entered=resolve),permit=new Promise<void>(resolve=>release=resolve),call=f.deps.call;f.state.lostReply=lost;
  f.deps.call=async(...args)=>{entered();await permit;return await call(...args);};
  try{
   const first=f.run(ready);await started;const concurrent=await f.run(ready);assertEquals(concurrent.check.state,"checking");assertEquals(f.state.holds,1);assertEquals(f.state.binds,1);
   release();const finished=await first;assertEquals(finished.check.state,lost?"hold":"accept");assertEquals(f.state.calls,1);await f.run(ready);assertEquals(f.state.calls,1);assertEquals(f.state.holds,1);assertEquals(f.state.binds,1);
  }finally{release();globalThis.fetch=previous;resetServingModeCache();}
 }
});
Deno.test("background judge refuses a withdrawn actor/library before funding and cannot reopen terminal states",async()=>{
 for(const state of["checking","accept","refuse","hold"]){
  const f=await fixture(),ready=await f.prepare();f.state.row!.check.state=state;f.state.row!.evidence.state=state;if(state==="checking")f.state.row!.check.judge_started_at=new Date().toISOString();
  await f.run(ready);assertEquals(f.state.holds,0);assertEquals(f.state.binds,0);assertEquals(f.state.calls,0);
 }
 const gone=await fixture(),ready=await gone.prepare();gone.state.current=false;await assertRejects(()=>gone.run(ready),HttpError,"unavailable");assertEquals(gone.state.holds,0);assertEquals(gone.state.binds,0);assertEquals(gone.state.calls,0);
 const withdrawn=await fixture(),before=await withdrawn.prepare(),read=withdrawn.deps.read;withdrawn.deps.read=async(...args)=>{const value=await read(...args);withdrawn.state.current=false;return value;};
 await assertRejects(()=>withdrawn.run(before),HttpError,"unavailable");assertEquals(withdrawn.state.holds,0);assertEquals(withdrawn.state.binds,0);assertEquals(withdrawn.state.calls,0);
});
