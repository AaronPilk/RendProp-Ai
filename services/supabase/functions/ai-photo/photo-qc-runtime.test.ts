import {assert,assertEquals,assertRejects,assertThrows} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {HttpError} from "../_shared/http.ts";
import {inputHash,resetServingModeCache} from "../_shared/funded-serving.ts";
import {decodePhotoOutput} from "./input-policy.ts";
import {PHOTO_QC_POLICY,unavailablePhotoQuality} from "./photo-qc-verdict.ts";
import {beginPhotoQuality,retainPhotoCandidate,statusPhotoQuality,photoQualityResponse,photoBytesHash,failPhotoQuality,throwPhotoQualityState,type PhotoQualityEnvelope,type PhotoEvidenceIO} from "./photo-qc-store.ts";
import {continuePhotoQuality,photoJudgeQuote,photoDerivatives,type PhotoJudgeDependencies} from "./photo-qc-runner.ts";
const actor="ea100606-0000-4000-8000-000000000001",org="ea100606-0000-4000-8000-000000000002",listing="ea100606-0000-4000-8000-000000000003",evidence="ea100606-0000-4000-8000-000000000004",check="ea100606-0000-4000-8000-000000000005",lease="ea100606-0000-4000-8000-000000000006",reservation="ea100606-0000-4000-8000-000000000007";
const jpeg=(width=1024,height=768)=>new Uint8Array([255,216,255,192,0,11,8,height>>8,height&255,width>>8,width&255,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]);
const b64=(bytes:Uint8Array)=>btoa(String.fromCharCode(...bytes));
const pass={policy:PHOTO_QC_POLICY,verdict:"pass",action:"accept",confidence:.99,preservation:{geometry:100,openings:100,fixtures:100,surfaces:100,viewpoint:100},artifacts:100,edit_quality:100,findings:[],reason:"Visible fixed features preserved."};
const step={route_id:"existing-approved-sonnet",task:"judge.qc_drift",provider:"anthropic",model:"claude-sonnet-5",unit:"call",unit_cents:1.3,capabilities:["classifier","vision","multi_image"],max_latency_s:60,min_plan:"free",same_model_as:null,privacy_tier:"retained_30d" as const,enabled:true};
async function fixture(){
 const input=jpeg(),output=jpeg(3584,4780),inputSHA=await photoBytesHash(input),outputSHA=await photoBytesHash(output);
 const identity={actorId:actor,orgId:org,requestKey:"photo-qc-runtime-fixture",listingId:listing};
 const state={row:null as PhotoQualityEnvelope|null,enabled:true,current:true,library:org,readWithdraw:false,wrongPutHash:false,corruptGet:false,headChanged:false,beginArgs:null as any,rpcs:[] as string[],puts:0,reads:0,claims:0,binds:0,calls:0,holds:0,ledger:[] as any[],attempt:null as any,operation:false,verdict:JSON.stringify(pass),lostReply:false,missingLedger:false,objects:new Map<string,{bytes:Uint8Array<ArrayBuffer>;mime:string;sha256:string;etag:string}>()};
 const view=()=>{const row=structuredClone(state.row!);row.can_continue=!!row.evidence.output_etag&&["pending","derivative_ready"].includes(row.check.state)&&row.check.judge_started_at===null&&(!state.attempt||state.attempt.state==="rejected");return row;};
 const unavailable=()=>({data:null,error:{message:"RP404: Current selected library is unavailable"}});
 const admin:any={from:(table:string)=>{const query:any={select:()=>query,eq:()=>query,maybeSingle:async()=>{
  if(table==="app_config")return{data:{value:{enabled:state.enabled,approved_judge:{provider:"anthropic",model:"claude-sonnet-5"}}},error:null};
  if(table==="private_ai_outputs"){const e=state.row!.evidence,file=e.output!;return{data:state.row!.check.state==="accept"?{org_id:org,user_id:actor,listing_id:listing,bucket:"renders",storage_key:file.key,bytes:file.bytes}:null,error:null};}
  throw Error("Unexpected table "+table);
 }};return query;},rpc:async(name:string,args:any)=>{
  state.rpcs.push(name);
  if(name==="listing_library_scope")return state.current?{data:{actor_id:actor,listing_id:listing,org_id:org,library_org_id:state.library,billing_org_id:org,team_org_id:null,library_owner_user_id:actor,listing_owner_user_id:actor,role:"owner",access_mode:"own",can_read:true,can_write:true,can_manage_subscription:true},error:null}:unavailable();
  if(name==="photo_quality_begin"){
   if(!state.enabled)return{data:null,error:{message:"RP503: Photo quality review is not active yet"}};
   if(state.row)return{data:{...view(),created:false},error:null};state.beginArgs=args;
   state.row={evidence:{id:evidence,actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,request_key:identity.requestKey,request_sha256:await inputHash({image_b64:b64(input)}),policy:PHOTO_QC_POLICY,edit:"stage",style:"modern",input:{...args.p_input,bucket:"renders",key:`ai-router/${org}/photo-evidence/${actor}/${evidence}/input.jpg`},output:null,input_etag:null,output_etag:null,state:"pending",provenance_id:null,generation_stage:null,generation_provider:null,generation_model:null},check:{id:check,evidence_id:evidence,policy:PHOTO_QC_POLICY,state:"pending",lease_token:null,lease_until:null,judge_started_at:null,derivatives:null,derivative_manifest_sha256:null},can_continue:false,created:true};
   return{data:view(),error:null};
  }
  if(name==="photo_quality_status"||name==="photo_quality_lookup")return !state.current||args.p_actor!==actor?unavailable():{data:state.row?view():null,error:null};
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
  if(name==="serving_operation_begin"){if(state.operation)return{data:null,error:{message:"RP409: This operation already started"}};state.operation=true;return{data:{begun:true},error:null};}
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
   state.row!.check.state=s;state.row!.evidence.state=s;return{data:view(),error:null};
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
 const deps:PhotoJudgeDependencies={plan:async()=>"free",routes:async()=>[step],read:async file=>jpeg(file.width,file.height),call:async(_step,_rubric,content,onUsage)=>{assertEquals(state.binds,1);assertEquals(state.attempt.state,"reserved");assertEquals(state.row!.check.state,"checking");assertEquals(content.length,20);state.calls++;if(state.lostReply)throw Error("Synthetic lost supplier reply");onUsage({inputTokens:18000,outputTokens:160});return state.verdict;},report:async()=>{},ledger:async(_admin,args)=>{if(!state.missingLedger)state.ledger.push(args);return{recorded:!state.missingLedger,total_cents:args.unitCents};}};
 const run=(row:PhotoQualityEnvelope)=>continuePhotoQuality(admin,row,{actor,selected:org,request:new Request("https://example.invalid/ai-photo",{method:"POST",headers:{"X-Org":org}})},deps);
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
Deno.test("oversize paid failure remains explicit and cannot advertise a saved result",async()=>{
 const f=await fixture();await f.begin();const row=await failPhotoQuality(f.admin,f.view(),"photo_output_size",{provider_cost_incurred:true,retained_output:false});
 const error=assertThrows(()=>throwPhotoQualityState(row,org),HttpError,"could not be saved");assertEquals(error.code,"photo_quality_hold");assertEquals(error.details?.provider_cost_incurred,true);assertEquals(error.details?.retained_output,false);assertEquals(error.details?.asset_key,undefined);
});
Deno.test("Sonnet5 quote covers native whole images and all quadrants; no low-resolution generic estimate",()=>{
 const quote=photoJudgeQuote(step,"a".repeat(8192),"source whole\ncandidate whole")!;
 assertEquals(quote.inputBound,2*4784+8*1369+8192+"source whole\ncandidate whole".length+1024);assert(quote.inputBound>10*2048+1024);assert(quote.cents>6);assertEquals(photoJudgeQuote({...step,model:"claude-haiku-4-5"},"r","l"),null);
 assertEquals(photoJudgeQuote({...step,params:{max_output_tokens:401}} as any,"r","l"),null);assertEquals(photoJudgeQuote(step,"a".repeat(12289),""),null);
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
