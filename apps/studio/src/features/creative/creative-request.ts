import type {StudioServices} from "../../data/services";
import {StudioError} from "../../data/config";
import {beginPhotoRequest,readyPhotoRequest,finishPhotoRequest,validateSavedPhotoRequest,type PhotoRequestScope,type PhotoRequestContext,type SavedPhotoRequest} from "./photo-request-journal";
export const PHOTO_RECOVERY_PROTOCOL="retained-operation-v1";
export function definitivePhotoRefusal(error:unknown):boolean{
 const e=error as {code?:string;status?:number;details?:Record<string,unknown>};
 if(e?.details?.provider_cost_incurred===true||e?.details?.provider_cost_incurred==="possible")return false;
 return e?.code==="photo_quality_refused"||e?.details?.no_provider_dispatch===true||[400,402,413,429].includes(e?.status??0)&&!["photo_quality_hold","photo_quality_pending"].includes(e?.code??"");
}
export async function resumePhotoRequest(services:StudioServices,identity:PhotoRequestScope,row:SavedPhotoRequest,assertScope:()=>void,signal:AbortSignal):Promise<{row:SavedPhotoRequest;result:unknown}>{
 signal.throwIfAborted();assertScope();row=await validateSavedPhotoRequest(row,identity);signal.throwIfAborted();assertScope();
 if(row.state==="ready")return{row,result:JSON.parse(row.resultJSON!)};
 try{
  const result=await services.api("/functions/v1/ai-photo-v2",{orgId:identity.library,method:"POST",body:JSON.parse(row.requestJSON),idempotencyKey:row.requestKey,photoQualityProtocol:PHOTO_RECOVERY_PROTOCOL,signal,timeoutMs:300_000,maxResponseBytes:32*1024*1024});
  signal.throwIfAborted();assertScope();const value=result as {image_b64?:unknown;mime?:unknown;disclosure?:unknown};
  if(typeof value?.image_b64!=="string"||!value.image_b64||value.image_b64.length>12_000_000||!["image/jpeg","image/png","image/webp"].includes(String(value.mime))||typeof value.disclosure!=="string")throw new StudioError("invalid-response","The saved photo answer could not be confirmed. Check this same edit again.");
  row=await readyPhotoRequest(row,result);signal.throwIfAborted();assertScope();return{row,result:JSON.parse(row.resultJSON!)};
 }catch(error){
  // Identity/abort/unknown outcomes retain the exact operation. A definite
  // server refusal may release it; this never manufactures a provider refund.
  if(!signal.aborted){assertScope();if(definitivePhotoRefusal(error))await finishPhotoRequest(row,true);}
  throw error;
 }
}
export async function retainedPhotoRequest(services:StudioServices,identity:PhotoRequestScope,body:Record<string,unknown>,context:PhotoRequestContext,assertScope:()=>void,signal:AbortSignal){
 signal.throwIfAborted();assertScope();const row=await beginPhotoRequest(identity,body,context,signal);signal.throwIfAborted();assertScope();return await resumePhotoRequest(services,identity,row,assertScope,signal);
}
