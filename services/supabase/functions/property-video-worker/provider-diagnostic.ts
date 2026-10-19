/** Read-only operator inspection of ONE exact retained paid provider receipt
 * (FAL, or the Kie property profile). No acceptance/lease/queue mutation,
 * persistence, generation or provider URLs leave this function. Existing
 * service authentication is enforced by caller. */
import {assert}from'../_shared/http.ts';
import {ProviderError}from'../_shared/providers/common.ts';
import {decodeJobToken,type RouterJobToken}from'../_shared/providers/jobtoken.ts';
import {falAdapter,falRetainedResultDiagnostic,type FalRetainedResultDiagnostic}from'../_shared/providers/fal.ts';
import {kieAdapter}from'../_shared/providers/kie.ts';
import {KIE_PROPERTY_MODEL}from'../_shared/property-video-kie.ts';
import type{JobRef,JobState}from'../_shared/providers/types.ts';
import {rpc}from'../property-video-jobs/runtime.ts';
interface Dependencies{rpc:typeof rpc;decode:(raw:string)=>Promise<RouterJobToken|null>;poll:(ref:JobRef)=>Promise<JobState>;result?:(ref:JobRef)=>Promise<FalRetainedResultDiagnostic>;kiePoll?:(ref:JobRef)=>Promise<JobState>}
const DEFAULT_DEPENDENCIES:Dependencies={rpc,decode:decodeJobToken,poll:ref=>falAdapter.poll(ref),result:falRetainedResultDiagnostic,kiePoll:ref=>kieAdapter.poll(ref)};
/** Dispatches on the retained receipt's provider only: a Kie receipt is read by
 * the Kie branch, everything else by the FAL branch (which still refuses any
 * receipt that is not an exact retained paid FAL receipt). */
export type ProviderDiagnosticReport=Record<string,unknown>;
export async function providerDiagnostic(jobId:string,attemptId:string,deps:Dependencies=DEFAULT_DEPENDENCIES,resultOnly=false):Promise<ProviderDiagnosticReport>{
 const j=await deps.rpc('property_video_job_scope',{p_job:jobId,p_actor:null,p_active:false});
 const proof=await deps.rpc('property_video_delivery_receipt',{p_job:jobId,p_attempt:attemptId});
 if(proof&&proof.attempt_id===attemptId&&proof.provider==='kie')return await kieProviderDiagnostic(jobId,attemptId,j,proof,deps,resultOnly);
 return await falProviderDiagnostic(jobId,attemptId,j,proof,deps,resultOnly);
}
/** The FAL branch, exactly as before the Kie branch existed. */
export async function falProviderDiagnostic(jobId:string,attemptId:string,j:any,proof:any,deps:Dependencies,resultOnly=false):Promise<ProviderDiagnosticReport>{
 assert(proof&&proof.attempt_id===attemptId&&proof.provider==='fal',409,'An exact retained paid FAL receipt is required.');
 let raw:string|null=null;try{raw=new URL(proof.receipt.status_url).searchParams.get('job');}catch{/* no provider read */}
 const token=raw?await deps.decode(raw):null;
 assert(token&&token.p==='fal'&&token.i===proof.request_id&&token.m===proof.model&&token.o===j.org_id&&token.usr===j.actor_id&&token.l===j.listing_id&&token.a===proof.request_key&&token.k==='video.reel_clip',409,'The signed retained receipt does not match this property and payment.');
 try{
  const ref={provider:token.p,model:token.m,id:token.i,poll_url:token.u,submitted_at:token.t};
  if(resultOnly){assert(deps.result,503,'The bounded result reader is unavailable.');const result=await deps.result(ref);return{job_id:jobId,attempt_id:attemptId,provider:'fal',state:result.state,provider_status:result.provider_status,phase:'result_read',...(result.reason?{reason:result.reason}:{}),...(result.has_media!==undefined?{has_media:result.has_media}:{}),...(result.error_class?{error_class:result.error_class}:{}),read_only:true};}
  const state=await deps.poll(ref);
  const issue=state.status==='running'?state.delivery_issue:undefined;
  return {job_id:jobId,attempt_id:attemptId,provider:'fal',state:state.status==='done'?'completed':state.status==='running'?'processing':state.status,
   ...(issue?{provider_status:issue.provider_status,phase:'result_read',reason:issue.reason}:{}),
   ...(state.status==='failed'?{error_class:state.error_class}:{}),read_only:true};
 }catch(error){
  return{job_id:jobId,attempt_id:attemptId,provider:'fal',state:'unavailable',provider_status:error instanceof ProviderError&&Number.isInteger(error.status)?error.status:null,error_class:error instanceof ProviderError?error.error_class:'other',reason:'unknown',read_only:true};
 }
}
/** Kie's own task states, as its record read reports them (closed vocabulary). */
const KIE_TASK_STATES=['waiting','queuing','generating','success','fail'] as const;
/** The Kie branch: ONE bounded record read through the existing adapter poll
 * (recordInfo, host-pinned, our key never leaves the adapter). It reports the
 * task state Kie named, the credits Kie says it consumed and the HOST of the
 * result (never its URL or any media). Kie's echo of the request (mode,
 * resolution, duration) is not evidence of what was generated and is not
 * reported: only the retained MP4 probe in the worker poll decides. Kie has
 * no separate result endpoint, so the result-only mode is refused. */
export async function kieProviderDiagnostic(jobId:string,attemptId:string,j:any,proof:any,deps:Dependencies,resultOnly=false):Promise<ProviderDiagnosticReport>{
 assert(proof&&proof.attempt_id===attemptId&&proof.provider==='kie',409,'An exact retained paid Kie receipt is required.');
 assert(!resultOnly,409,'A Kie record read is the only provider read for this receipt; use the status diagnostic.');
 let raw:string|null=null;try{raw=new URL(proof.receipt.status_url).searchParams.get('job');}catch{/* no provider read */}
 const token=raw?await deps.decode(raw):null;
 assert(token&&token.p==='kie'&&token.m===KIE_PROPERTY_MODEL&&token.i===proof.request_id&&token.m===proof.model&&token.o===j.org_id&&token.usr===j.actor_id&&token.l===j.listing_id&&token.a===proof.request_key&&token.k==='video.reel_clip',409,'The signed retained receipt does not match this property and payment.');
 assert(deps.kiePoll,503,'The Kie record reader is unavailable.');
 const base={job_id:jobId,attempt_id:attemptId,provider:'kie' as const,read_only:true as const};
 try{
  const ref={provider:token.p,model:token.m,id:token.i,poll_url:token.u,submitted_at:token.t};
  const state=await deps.kiePoll(ref);
  if(state.status==='done'){
   const meta=state.meta??{};
   let host:string|null=null;try{host=new URL(state.result_url).hostname||null;}catch{host=null;}
   const kieState=typeof meta.kie_state==='string'&&(KIE_TASK_STATES as readonly string[]).includes(meta.kie_state)?meta.kie_state:null;
   const credits=typeof meta.credits_consumed==='number'&&Number.isFinite(meta.credits_consumed)&&meta.credits_consumed>=0?meta.credits_consumed:null;
   return{...base,state:'completed',kie_state:kieState,credits_consumed:credits,result_host:host,result_mime:state.mime,echo_trusted:false};
  }
  if(state.status==='failed')return{...base,state:'failed',error_class:state.error_class};
  return{...base,state:state.status==='running'?'processing':'queued'};
 }catch(error){
  return{...base,state:'unavailable',provider_status:error instanceof ProviderError&&Number.isInteger(error.status)?error.status:null,error_class:error instanceof ProviderError?error.error_class:'other',reason:'unknown'};
 }
}
