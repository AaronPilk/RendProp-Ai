/** Read-only operator inspection of ONE exact retained paid FAL receipt.
 * No acceptance/lease/queue mutation, persistence, generation or provider URLs
 * leave this function. Existing service authentication is enforced by caller. */
import {assert}from'../_shared/http.ts';
import {ProviderError}from'../_shared/providers/common.ts';
import {decodeJobToken,type RouterJobToken}from'../_shared/providers/jobtoken.ts';
import {falAdapter,falRetainedResultDiagnostic,type FalRetainedResultDiagnostic}from'../_shared/providers/fal.ts';
import type{JobRef,JobState}from'../_shared/providers/types.ts';
import {rpc}from'../property-video-jobs/runtime.ts';
interface Dependencies{rpc:typeof rpc;decode:(raw:string)=>Promise<RouterJobToken|null>;poll:(ref:JobRef)=>Promise<JobState>;result?:(ref:JobRef)=>Promise<FalRetainedResultDiagnostic>}
export async function providerDiagnostic(jobId:string,attemptId:string,deps:Dependencies={rpc,decode:decodeJobToken,poll:ref=>falAdapter.poll(ref),result:falRetainedResultDiagnostic},resultOnly=false){
 const j=await deps.rpc('property_video_job_scope',{p_job:jobId,p_actor:null,p_active:false});
 const proof=await deps.rpc('property_video_delivery_receipt',{p_job:jobId,p_attempt:attemptId});
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
