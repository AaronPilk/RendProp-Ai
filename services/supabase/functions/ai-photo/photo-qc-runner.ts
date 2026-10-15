// Exactly one funded, lease-bound judge for one preallocated saved photo check.
// CPU comparison preparation is a separate controller. GET never reaches here.
import {HttpError,assert} from "../_shared/http.ts";
import {fundingContext,fundedAttempt,completeFundingOperation,textAttemptQuote,type FundingContext} from "../_shared/funded-serving.ts";
import {resolveRoute,paramsOf,reportOutcome,type RouteStep} from "../_shared/router.ts";
import {anthropicMessages,anthropicMaxTokens,imageBlock,type ContentBlock} from "../_shared/providers/anthropic.ts";
import {ProviderError,bytesToB64,presignGet} from "../_shared/providers/common.ts";
import {R2_BUCKET_RENDERS,headObject} from "../_shared/r2.ts";
import {recordAppAiCost} from "../_shared/ledger.ts";
import {entitlementForCharge} from "../_shared/entitlements.ts";
import {boundedPhotoResultBytes} from "./photo-result.ts";
import {validatePhotoInput} from "./input-policy.ts";
import {PHOTO_QC_POLICY,PHOTO_QC_REGIONS,photoQualityRubric,parsePhotoQuality} from "./photo-qc-verdict.ts";
import {photoQualityRpc,photoEnvelope,photoQualityScope,statusPhotoQuality,failPhotoQuality,photoBytesHash,photoSHA,type PhotoAdmin,type PhotoDerivative,type PhotoQualityEnvelope} from "./photo-qc-store.ts";

export const PHOTO_QC_AGGREGATE_BYTES=6_000_000;
export const PHOTO_QC_MAX_TEXT_BYTES=12_288;
export const PHOTO_QC_MAX_WIRE_BYTES=9_000_000; // below the provider's32MB standard envelope
const MAX_OUTPUT_TOKENS=400;
type Usage={inputTokens:number;outputTokens:number;cacheReadInputTokens?:number;cacheCreationInputTokens?:number};
export interface PhotoJudgeDependencies {
 plan(org:string):Promise<string>;
 routes(plan:string):Promise<RouteStep[]>;
 read(file:PhotoDerivative):Promise<Uint8Array<ArrayBuffer>>;
 call(step:RouteStep,rubric:string,content:ContentBlock[],onUsage:(usage:Usage)=>void):Promise<string>;
 report(step:RouteStep,ok:boolean,milliseconds:number):Promise<void>;
 ledger:typeof recordAppAiCost;
}
const actual:PhotoJudgeDependencies={
 plan:async org=>(await entitlementForCharge(org)).plan,
 routes:plan=>resolveRoute("judge.qc_drift",{plan,needs:["classifier","vision","multi_image"],carries_customer_media:true}),
 read:async file=>{
  const head=await headObject(R2_BUCKET_RENDERS,file.key,AbortSignal.timeout(10_000));
  assert(head.exists&&head.bytes===file.bytes&&head.etag===file.etag&&head.contentType?.split(";")[0]==="image/jpeg",503,"A photo comparison receipt changed.");
  const response=await fetch(await presignGet(R2_BUCKET_RENDERS,file.key,60),{method:"GET",credentials:"omit",redirect:"error",signal:AbortSignal.timeout(30_000)});
  assert((response.headers.get("content-type")??"").split(";")[0]==="image/jpeg",503,"A photo comparison format changed.");
  return await boundedPhotoResultBytes(response,file.bytes);
 },
 call:(step,rubric,content,onUsage)=>anthropicMessages({model:step,system:rubric,content,maxTokens:MAX_OUTPUT_TOKENS,onUsage}),
 report:(step,ok,milliseconds)=>reportOutcome(step,{ok,latency_ms:milliseconds,...(!ok?{error_class:"upstream" as const}:{})}),
 ledger:recordAppAiCost,
};
/** Sonnet5 native-resolution vision: at most4784tokens per2048px whole
 * image; ceil(1024/28)^2=1369 per quadrant. Text bytes conservatively bound
 * text tokens. Primary docs: platform.claude.com/docs/en/build-with-claude/vision
 * and /docs/en/about-claude/pricing ($2/M input,$10/M output). */
export function photoJudgeQuote(step:RouteStep,rubric:string,labels:string){
 const textBytes=new TextEncoder().encode(rubric+labels).byteLength;
 if(step.provider!=="anthropic"||step.model!=="claude-sonnet-5"||anthropicMaxTokens(paramsOf(step),MAX_OUTPUT_TOKENS)>MAX_OUTPUT_TOKENS||textBytes>PHOTO_QC_MAX_TEXT_BYTES)return null;
 const inputBound=2*4784+8*1369+textBytes+1024;
 const quote=textAttemptQuote(step,rubric,labels,MAX_OUTPUT_TOKENS,true,inputBound);
 return quote?{...quote,inputBound,textBytes}:null;
}
export function photoDerivatives(row:PhotoQualityEnvelope):PhotoDerivative[]{
 const e=row.evidence,q=row.check,images=q.derivatives;
 assert(Array.isArray(images)&&images.length===10&&photoSHA(q.derivative_manifest_sha256),503,"The complete photo comparison is not ready.");
 const seen=new Set<string>();let total=0;
 for(const file of images){
  const key=`${file.role}:${file.region}`,bound=file.region==="whole"?2048:1024;
  assert(["source","candidate"].includes(file.role)&&PHOTO_QC_REGIONS.includes(file.region)&&!seen.has(key)&&file.bucket==="renders"&&file.mime==="image/jpeg"
   &&file.key===`ai-router/${e.org_id}/photo-evidence/${e.actor_id}/${e.id}/checks/${q.id}/${file.role}-${file.region}.jpg`&&photoSHA(file.sha256)
   &&Number.isSafeInteger(file.bytes)&&file.bytes>0&&file.bytes<=PHOTO_QC_AGGREGATE_BYTES&&Number.isSafeInteger(file.width)&&Number.isSafeInteger(file.height)&&file.width>0&&file.height>0&&file.width<=bound&&file.height<=bound&&typeof file.etag==="string"&&file.etag.length>0&&file.etag.length<=200,503,"The photo comparison identity is inconsistent.");
  seen.add(key);total+=file.bytes;
 }
 assert(total<=PHOTO_QC_AGGREGATE_BYTES,503,"The complete photo comparison exceeds its memory bound.");
 // Adjacent source/candidate blocks for each region; array order is never authority.
 return PHOTO_QC_REGIONS.flatMap(region=>["source","candidate"].map(role=>images.find(f=>f.region===region&&f.role===role)!));
}
/** Pending evidence is queued for the CPU controller, never fabricated here.
 * This explicit same-key POST can continue only derivative_ready and only
 * before the one paid judge has definitively ever been dispatched. */
export async function continuePhotoQuality(admin:PhotoAdmin,row:PhotoQualityEnvelope,args:{actor:string;selected:string|null;request:Request;instruction?:string},deps=actual):Promise<PhotoQualityEnvelope>{
 await photoQualityScope(admin,row,args.actor,args.selected);
 if(!row.can_continue||row.check.state!=="derivative_ready"||row.check.judge_started_at!==null)return row;
 const e=row.evidence;let claimed:PhotoQualityEnvelope|undefined,dispatched=false,reservedBeforeDispatch=false,paidStep:RouteStep|undefined,started=0;
 try{
  const config=await admin.from("app_config").select("value").eq("key","photo_quality").maybeSingle();
  const approved=config.data?.value?.approved_judge;
  if(config.error||config.data?.value?.enabled!==true||approved?.provider!=="anthropic"||approved?.model!=="claude-sonnet-5")return row;
  const plan=await deps.plan(e.org_id);
  const steps=await deps.routes(plan),step=steps.find(s=>s.provider===approved.provider&&s.model===approved.model);
  if(!step)return row; // no invented fallback or second judge
  const files=photoDerivatives(row),rubric=photoQualityRubric({edit:e.edit,...(e.style?{style:e.style}:{}),...(args.instruction?{instruction:args.instruction}:{})});
  const labels=files.map(f=>`${f.role.toUpperCase()} ${f.region}`).join("\n"),quote=photoJudgeQuote(step,rubric,labels);
  if(!quote)return row;
  const content:ContentBlock[]=[];
  for(const file of files){
   const bytes=await deps.read(file);assert(bytes.byteLength===file.bytes&&await photoBytesHash(bytes)===file.sha256,503,"A saved photo comparison changed.");
   const b64=bytesToB64(bytes),image=validatePhotoInput(b64,"image/jpeg");
   assert(image.width===file.width&&image.height===file.height,503,"The photo comparison dimensions changed.");
   content.push({type:"text",text:`${file.role.toUpperCase()} ${file.region}`},imageBlock(b64));
  }
  // The serialized provider body is ASCII except these bounded text fields.
  // Count its exact UTF8 bytes before reservation/dispatch; no image truncation.
  const wire={model:step.model,max_tokens:anthropicMaxTokens(paramsOf(step),MAX_OUTPUT_TOKENS),messages:[{role:"user",content}],system:rubric,output_config:{effort:paramsOf(step)?.effort??"low"}};
  assert(new TextEncoder().encode(JSON.stringify(wire)).byteLength<=PHOTO_QC_MAX_WIRE_BYTES,503,"The complete photo comparison request exceeds its memory bound.");
  const claim=await photoQualityRpc(admin,"photo_quality_claim",{p_check:row.check.id});
  if(claim?.action!=="judge")return await statusPhotoQuality(admin,args.actor,row.check.id,args.selected);
  claimed=photoEnvelope(claim,args.actor);await photoQualityScope(admin,claimed,args.actor,args.selected);
  assert(claimed.check.id===row.check.id&&claimed.evidence.id===e.id&&claimed.evidence.org_id===e.org_id&&claimed.evidence.input.sha256===e.input.sha256&&claimed.evidence.output?.sha256===e.output?.sha256&&claimed.check.state==="derivative_ready"&&claimed.check.lease_token&&claimed.check.judge_started_at===null&&claimed.check.derivative_manifest_sha256===row.check.derivative_manifest_sha256,409,"The photo comparison lease changed.","conflict");
  const binding={policy:PHOTO_QC_POLICY,check_id:row.check.id,evidence_id:e.id,prepared_sha256:e.input.sha256,output_sha256:e.output?.sha256,derivative_manifest_sha256:row.check.derivative_manifest_sha256,rubric,images:files.map(f=>({role:f.role,region:f.region,sha256:f.sha256,bytes:f.bytes,width:f.width,height:f.height})),input_token_bound:quote.inputBound,max_output_tokens:MAX_OUTPUT_TOKENS};
  let reservation:string|undefined;
  const rpc:FundingContext["rpc"]=async(name,parameters)=>{const result=await admin.rpc(name,parameters);if(name==="serving_cost_reserve"&&!result.error&&result.data?.reserved===true){reservation=result.data.id;reservedBeforeDispatch=true;}return result;};
  const headers=new Headers(args.request.headers);headers.set("Idempotency-Key",`photo-qc:${row.check.id}`);
  const funding=await fundingContext(args.actor,e.org_id,new Request(args.request.url,{method:"POST",headers}),binding,rpc);
  let usage:Usage|undefined;started=Date.now();paidStep=step;
  const raw=await fundedAttempt(funding,"photo.qc:0",step,binding,quote,async()=>{
   // The wrapper captures the ID returned by this exact fresh reserve. A
   // missing/lost reserve response cannot reach bind or the provider.
   try{
    assert(reservation,503,"The photo review funding receipt is missing.");
    const bound=await photoQualityRpc(admin,"photo_quality_check_bind",{p_actor:args.actor,p_check:row.check.id,p_lease:claimed!.check.lease_token,p_reservation:reservation});
    const verified=photoEnvelope(bound,args.actor);assert(verified.check.state==="checking"&&verified.check.judge_started_at,503,"The photo review dispatch fence was not confirmed.");
   }catch{throw new ProviderError(step.provider,"validation","The photo review could not be bound before dispatch.",0,true);}
   dispatched=true;
   return await deps.call(step,rubric,content,value=>{usage=value;});
  });
  await deps.report(step,true,Date.now()-started).catch(()=>{});
  // This is the documented complete bound, not a fabricated provider invoice.
  // Actual usage is retained as metadata; SQL requires its matching paid receipt.
  await deps.ledger(admin,{orgId:e.org_id,provider:step.provider,model:step.model,feature:"qc",unitCents:quote.cents,meta:{request_key:funding.requestKey,stage:"photo.qc:0",photo_check_id:row.check.id,evidence_id:e.id,prepared_sha256:e.input.sha256,output_sha256:e.output!.sha256,derivative_manifest_sha256:row.check.derivative_manifest_sha256,policy:e.policy,cost_basis:"published_complete_input_output_bound",input_token_bound:quote.inputBound,max_output_tokens:MAX_OUTPUT_TOKENS,...(usage?{provider_usage:usage}:{})}});
  const finished=photoEnvelope(await photoQualityRpc(admin,"photo_quality_finish",{p_actor:args.actor,p_check:row.check.id,p_lease:claimed.check.lease_token,p_result:parsePhotoQuality(raw)}),args.actor);
  await completeFundingOperation(funding,{kind:"photo_quality_check",check_id:row.check.id,evidence_id:e.id});
  return finished;
 }catch(error){
  // Before dispatch, funding/configuration/derivative failures leave the SAME
  // check pending. After bind/POST uncertainty it must never dispatch again.
  if(dispatched){
   if(paidStep)await deps.report(paidStep,false,Date.now()-started).catch(()=>{});
   try{return await failPhotoQuality(admin,claimed??row,"quality_check",{provider_dispatch_started:true,provider_cost_incurred:"possible",message:"The saved quality check did not return a confirmed verdict. No repeat judge or generation was started."});}catch{/* A lost failure ACK remains fenced by judge_started_at. */}
  }
  else if(reservedBeforeDispatch){
   // A rejected pre-dispatch reservation is still an immutable serving journal
   // row. The generic operation cannot reopen it; make that conservative HOLD
   // explicit instead of advertising an automatic continuation that is stuck.
   try{return await failPhotoQuality(admin,claimed??row,"quality_before_dispatch",{quality_provider_cost_incurred:false,no_quality_provider_dispatch:true,message:"The saved quality funding or binding receipt needs review. No judge was sent or repeated."});}catch{/* Keep the existing journal fenced. */}
  }
  if(error instanceof HttpError&&error.status===404)throw error;
  return await statusPhotoQuality(admin,args.actor,row.check.id,args.selected);
 }
}
