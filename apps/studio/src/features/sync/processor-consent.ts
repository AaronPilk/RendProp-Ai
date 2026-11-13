import {StudioError} from "../../data/config";
import type {StudioServices} from "../../data/services";
import {abandonVideoOperation,assertVideoScope,decodeJob,inspectVideoOperation,videoScopeKey,type VideoScope,type VideoJob} from "./property-video";

// Compiled reviewed draft; tests bind every field and copy digest to the shared JSON.
// A known draft never proves that the server has published it or that a user agreed.
export const PROCESSOR_DISCLOSURE = Object.freeze({
  "token": "property-video-jobs-v2",
  "disclosure_revision": "rendprop-property-video-kie-20261016-r1",
  "processors": [
    "kie"
  ],
  "profiles": [
    "kie-kling3-4k-steady-v1"
  ],
  "title": "Allow Kie to make your video clips?",
  "body": "Rendprop may send the property photos you select and camera-motion instructions to Kie (kie.ai). Kie’s terms allow submitted content to be used to operate and improve its services, and do not expressly rule out AI model training. Choose Allow only if you agree to that processing. Your saved originals stay unchanged.",
  "allow_label": "Allow and continue",
  "decline_label": "Not now",
  "privacy_url": "https://rendprop.com/privacy",
  "provider_terms_url": "https://kie.ai/terms-of-use",
  "copy_sha256": "11d500972be541f0c34f1ccd96f1a2d79d15c9827a4a010e934ca6b534f9ef9c",
  "publication_state": "draft_not_published",
  "source_checked": "2026-10-16",
  "source_urls": [
    "https://kie.ai/terms-of-use",
    "https://docs.kie.ai/1973359m0"
  ]
} as const);
export const CONSENT_V1="property-video-jobs-v1" as const;
export const CONSENT_V2="property-video-jobs-v2" as const;
export type ProcessorContract={token:typeof CONSENT_V2;disclosure_revision:string;processors:string[];profiles:string[]};
export type VideoPermission={token:typeof CONSENT_V1}|(ProcessorContract&{copy_sha256:string});
export type ProcessorAvailability={kind:"legacy"}|{kind:"known";contract:ProcessorContract};
export type RecordedProcessorConsent={token:typeof CONSENT_V2;disclosure_revision:string;processors:string[];recorded_at:string};
export type VideoPermissionMetadata={consent_revision?:unknown;processor_consent?:unknown;quality_profile?:unknown};
const KNOWN_PROFILES=["legacy","fal-kling3-4k-v1","fal-kling3-4k-steady-v2",PROCESSOR_DISCLOSURE.profiles[0]];
const own=(v:object,k:string)=>Object.prototype.hasOwnProperty.call(v,k);
const object=(v:unknown):v is Record<string,unknown>=>!!v&&typeof v==="object"&&!Array.isArray(v);
const sameArray=(v:unknown,expected:readonly string[]):v is string[]=>Array.isArray(v)&&v.length===expected.length&&v.every((item,index)=>item===expected[index]);
const exactKeys=(v:Record<string,unknown>,keys:readonly string[])=>Object.keys(v).length===keys.length&&keys.every(k=>own(v,k));
export function decodeProcessorContract(value:unknown):ProcessorContract{
 if(!object(value)||!exactKeys(value,["token","disclosure_revision","processors","profiles"])||value.token!==CONSENT_V2||value.disclosure_revision!==PROCESSOR_DISCLOSURE.disclosure_revision||!sameArray(value.processors,PROCESSOR_DISCLOSURE.processors)||!sameArray(value.profiles,PROCESSOR_DISCLOSURE.profiles))throw new StudioError("processor-contract-unknown","Our notice about the AI services used for video has changed and this version of Studio does not know the new one. Your saved videos are still available. Refresh the page before starting a new video.");
 return{token:CONSENT_V2,disclosure_revision:value.disclosure_revision,processors:[...value.processors],profiles:[...value.profiles]};
}
export function knownVideoPermission(contract:ProcessorContract):VideoPermission{
 return{...decodeProcessorContract(contract),copy_sha256:PROCESSOR_DISCLOSURE.copy_sha256};
}
export function decodeVideoPermission(value:unknown):VideoPermission{
 if(object(value)&&exactKeys(value,["token"])&&value.token===CONSENT_V1)return{token:CONSENT_V1};
 if(!object(value)||!exactKeys(value,["token","disclosure_revision","processors","profiles","copy_sha256"])||value.copy_sha256!==PROCESSOR_DISCLOSURE.copy_sha256)throw new StudioError("saved-processor-permission","We could not tell which AI permission your saved video was started with. Recover or discard that video before choosing new options.");
 const {copy_sha256,...contract}=value;return{...decodeProcessorContract(contract),copy_sha256:copy_sha256 as string};
}
export function sameVideoPermission(a:VideoPermission|null|undefined,b:VideoPermission|null|undefined):boolean{
 return JSON.stringify(a??null)===JSON.stringify(b??null);
}
export async function fetchProcessorAvailability(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,signal?:AbortSignal):Promise<ProcessorAvailability>{
 assertVideoScope(services,scope,signal);
 try{
  const raw=await services.api("/functions/v1/property-video-jobs/processor-consent",{orgId:scope.library,expectedLibraryOrgId:scope.library,expectedListingId:scope.listing,signal});
  assertVideoScope(services,scope,signal);return{kind:"known",contract:decodeProcessorContract(raw)};
 }catch(error){
  assertVideoScope(services,scope,signal);
  if(error instanceof StudioError&&error.status===404&&error.code==="processor_disclosure_unpublished")return{kind:"legacy"};
  throw error;
 }
}
export function permissionBeforePaidWork(availability:ProcessorAvailability,allowed:VideoPermission|null,saved?:{permission?:VideoPermission}):VideoPermission{
 const current=availability.kind==="legacy"?{token:CONSENT_V1}as const:knownVideoPermission(availability.contract);
 if(saved){
  const prior=saved.permission===undefined?{token:CONSENT_V1}as const:decodeVideoPermission(saved.permission);
  if(!sameVideoPermission(prior,current))throw new StudioError("saved-processor-permission","Your saved video keeps the AI permission it was started with. Recover it, or discard it before agreeing to a different AI notice. Nothing new was started.");
  if(prior.token===CONSENT_V2&&!sameVideoPermission(allowed,prior))throw new StudioError("processor-permission-required","Allow AI processing for this video before resuming it. Nothing about the saved video has changed.");
  return prior;
 }
 if(current.token===CONSENT_V2&&!sameVideoPermission(allowed,current))throw new StudioError("processor-permission-required","Read and allow AI processing of the photos you selected before the video starts.");
 return current;
}
export function videoPermissionHeaders(permission:VideoPermission){
 const checked=decodeVideoPermission(permission);
 return checked.token===CONSENT_V1?{aiConsent:CONSENT_V1}:{aiConsent:CONSENT_V2,aiConsentDisclosure:checked.disclosure_revision};
}
// Preserve presence, including malformed/future metadata, without stranding
// status/review/cancel. Only the closed validator below can authorize a resume.
export function retainVideoPermissionMetadata(raw:Record<string,unknown>):VideoPermissionMetadata{
 const result:VideoPermissionMetadata={};
 for(const key of ["consent_revision","processor_consent","quality_profile"]as const)if(own(raw,key))result[key]=raw[key];
 return result;
}
export function permissionForSavedJob(job:VideoPermissionMetadata,legacyEndpointConfirmed=false):VideoPermission|null{
 const keys=["consent_revision","processor_consent","quality_profile"];
 if(keys.every(k=>!own(job,k)))return legacyEndpointConfirmed?{token:CONSENT_V1}:null;
 if(keys.some(k=>!own(job,k)))return null;
 if(job.consent_revision===CONSENT_V1&&job.processor_consent===null&&KNOWN_PROFILES.slice(0,3).includes(String(job.quality_profile)))return{token:CONSENT_V1};
 const c=job.processor_consent;
 if(job.consent_revision!==CONSENT_V2||!KNOWN_PROFILES.includes(String(job.quality_profile))||!object(c)||!exactKeys(c,["token","disclosure_revision","processors","recorded_at"])||c.token!==CONSENT_V2||c.disclosure_revision!==PROCESSOR_DISCLOSURE.disclosure_revision||!sameArray(c.processors,PROCESSOR_DISCLOSURE.processors)||typeof c.recorded_at!=="string"||c.recorded_at.length>64||!/^\d{4}-\d{2}-\d{2}T/.test(c.recorded_at)||!Number.isFinite(Date.parse(c.recorded_at)))return null;
 return knownVideoPermission({token:CONSENT_V2,disclosure_revision:c.disclosure_revision,processors:[...c.processors],profiles:[...PROCESSOR_DISCLOSURE.profiles]});
}

// A local revocation is durable before any stop request. It never authorizes
// create/resume: unknown replies are reconciled through the operation GET.
export type VideoStopIntent={schema:1;actor:string;org:string;library:string;listing:string;operation_id:string};
const UUID=/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
const stopPrefix=(scope:VideoScope)=>`${videoScopeKey(scope)}:processor-stop:`;
export function saveVideoStop(storage:Pick<Storage,"setItem">,scope:VideoScope,operation:string):VideoStopIntent{
 if(!UUID.test(operation))throw Error("We could not read which video you asked to stop. Refresh this property.");
 const intent:VideoStopIntent={schema:1,actor:scope.actor,org:scope.org,library:scope.library,listing:scope.listing,operation_id:operation};
 storage.setItem(`${stopPrefix(scope)}${operation}`,JSON.stringify(intent));return intent;
}
export function readVideoStops(storage:Pick<Storage,"getItem"|"key"|"length">,scope:VideoScope):VideoStopIntent[]{
 if(storage.length>10000)throw Error("This browser holds too much saved data to check your stop requests. Contact support before starting a new video.");
 const found:VideoStopIntent[]=[];
 for(let index=0;index<storage.length;index++){
  const key=storage.key(index);if(!key?.startsWith(stopPrefix(scope)))continue;
  try{const v:unknown=JSON.parse(storage.getItem(key)??"null");if(!object(v)||!exactKeys(v,["schema","actor","org","library","listing","operation_id"])||v.schema!==1||v.actor!==scope.actor||v.org!==scope.org||v.library!==scope.library||v.listing!==scope.listing||typeof v.operation_id!=="string"||!UUID.test(v.operation_id)||key!==`${stopPrefix(scope)}${v.operation_id}`)throw Error();found.push(v as VideoStopIntent);}catch{throw Error("We could not read one of your requests to stop a video. Nothing new was started. Refresh this property.");}
 }
 return found;
}
export async function reconcileVideoStop(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,intent:VideoStopIntent,storage:Pick<Storage,"removeItem">,signal?:AbortSignal):Promise<VideoJob|null>{
 assertVideoScope(services,scope,signal);
 if(intent.actor!==scope.actor||intent.org!==scope.org||intent.library!==scope.library||intent.listing!==scope.listing||!UUID.test(intent.operation_id))throw Error("This saved video stop belongs to another workspace.");
 const reference={input:{operation_id:intent.operation_id}};
 let outcome=await inspectVideoOperation(services,scope,reference,signal);
 if(!outcome.job&&!outcome.closed)outcome=await abandonVideoOperation(services,scope,reference,signal);
 assertVideoScope(services,scope,signal);
 let job=outcome.job;
 if(job&&!['ready','cancelled'].includes(job.state)){
  const raw=await services.api(`/functions/v1/property-video-jobs/${job.job_id}/cancel`,{orgId:scope.library,expectedLibraryOrgId:scope.library,expectedListingId:scope.listing,method:"POST",body:{},signal});
  assertVideoScope(services,scope,signal);const stopped=decodeJob(raw,scope,intent.operation_id);
  if(stopped.job_id!==job.job_id||!['ready','cancelled'].includes(stopped.state))throw Error("We could not confirm this video has stopped. Your request to stop it is kept; try again.");job=stopped;
 }
 if(!job&&!outcome.closed)throw Error("We could not confirm this video request has stopped. Try again.");
 storage.removeItem(`${stopPrefix(scope)}${intent.operation_id}`);return job;
}
