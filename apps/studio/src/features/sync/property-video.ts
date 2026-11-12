import type {StudioServices} from "../../data/services";
import {mediaURL} from "../../data/contracts";
import {isPrivateMediaURL,privateMediaCapability} from "../../data/private-media";
import {resolveTourLinks,safeTourLinks} from "../listings/share-link";
import {CONSENT_V1,decodeVideoPermission,permissionForSavedJob,retainVideoPermissionMetadata,sameVideoPermission,videoPermissionHeaders,type VideoPermission,type VideoPermissionMetadata} from "./processor-consent";

export type VideoScope={actor:string;org:string;library:string;listing:string;identityVersion:number};
export type VideoMotion="fly_through"|"push_in"|"side_glide"|"pull_back";
export type VideoPurpose="listing"|"social";
export type PhotoPreparation={preparation_id:string;source_asset_id:string;source_sha256:string;width:number;height:number;policy:'video-jpeg-v1'};
export type VideoSource={width?:number;height?:number;needs_preparation?:boolean;preparation?:PhotoPreparation;photo_id:string;photo_asset_id:string|null;photo_version_id:string;photo_provenance_id:string|null;preview_url:string|null;bytes:number;sha256:string|null;eligible:boolean;reason:string|null};
export type FrozenSource={photo_id:string;photo_asset_id:string;photo_version_id:string;photo_provenance_id:string|null;motion:VideoMotion};
export type PhotoMotionProfile="photo-motion-v1-cfr24"|"photo-motion-v2-cfr24"|"photo-motion-v2-opening-cfr24";
export type PhotoMotionMove="push_in"|"pull_back"|"slide_left"|"slide_right";
export type FinishedSource={photo_asset_id:string;photo_version_id:string;photo_provenance_id:string|null;generation_request_id:string|null;generation_provenance_id:string|null;motion_kind:"ai"|"original_photo"}|{photo_asset_id:string;photo_version_id:string;photo_provenance_id:string|null;generation_request_id:null;generation_provenance_id:null;motion_kind:"photo_motion";source_bound:true;source_sha256:string;source_bytes:number;visible_frames:48|72|96|120;motion?:PhotoMotionMove};
export type VideoPresentation={transition:"cut"|"dissolve"|"whip";shot_caption_style:"off"|"lowerThird"|"punchCard"|"highlightBox";spoken_captions:boolean;title_card:{title:string;subtitle:string;watermark:string}|null;shot_labels:(string|null)[]};
export type VideoInput={operation_id:string;listing_id:string;expected_org_id:string;purpose:VideoPurpose;aspect:"16:9"|"9:16";sources:FrozenSource[];narration_result_id:string|null;narration_asset_id:string|null;narration_words:{text:string;start:number;end:number}[];music:VideoMusic|null;presentation:VideoPresentation;allow_original_photo_fallback:boolean};
export type VideoState="queued"|"generating"|"quality_review"|"composing"|"ready"|"cancelled"|"failed"|"needs_reconciliation";
export type VideoJob=VideoPermissionMetadata&{job_id:string;operation_id:string;listing_id:string;org_id:string;selected_library_org_id:string;source_count:number;manifest_sha256:string;state:VideoState;completed_sources:number;message?:string;resume_available?:boolean;source_mode?:"photo_motion_v1";composition_profile?:PhotoMotionProfile;result:{asset_id:string;poster_asset_id:string;download_url:string;width:number;height:number;duration_s:number;bytes:number;sha256:string;branding_policy:"unbranded"|"social";sources:FinishedSource[];original_photo_count:number;music:unknown|null;source_mode?:"photo_motion_v1";composition_profile?:PhotoMotionProfile;fps?:24;total_frames?:number;source_frames?:number[];source_sha256s?:string[];source_motions?:PhotoMotionMove[];opening?:unknown}|null};
export type VideoMusic={track_id:"calm"|"upbeat"|"cinematic";asset_sha256:string;license_id:"CC0-1.0";license_evidence_sha256:string;gain:.18;duck_gain:.07};
const UUID=/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
const HEX=/^[a-f0-9]{64}$/;
const PHOTO_MOTION_PROFILES:readonly PhotoMotionProfile[]=["photo-motion-v1-cfr24","photo-motion-v2-cfr24","photo-motion-v2-opening-cfr24"];
const PHOTO_MOTION_MOVES:readonly PhotoMotionMove[]=["push_in","pull_back","slide_left","slide_right"];
const PHOTO_MOTION_FRAMES:readonly number[]=[48,72,96,120];
export const MUSIC:readonly VideoMusic[]=[
 {track_id:"calm",asset_sha256:"9503b0d6d59cdc76f69f786b6f2fd2fb6f39a747e245e8f02dc358b7fd4dbb36",license_id:"CC0-1.0",license_evidence_sha256:"8a5d6e54d255e734a434dbb63abb7fbcf759eb619be6735c123f467d444a9074",gain:.18,duck_gain:.07},
 {track_id:"upbeat",asset_sha256:"ce55346893354d49746c689b3dde135ec1f3d9299d22ef8ec26b27a022020375",license_id:"CC0-1.0",license_evidence_sha256:"fa5b82351abf48b8b0877b1c10ed5163f3243a2cd7781c3b02dcb72ae4d26e27",gain:.18,duck_gain:.07},
 {track_id:"cinematic",asset_sha256:"119eaedb3c58948d6f6b346ec61aac58fa28174658714e06a6a5b8d0ec11bdc8",license_id:"CC0-1.0",license_evidence_sha256:"5f83d54c6e0d67b855d772f12615fe668c6678dc551cf1a95f382e96d89e3a45",gain:.18,duck_gain:.07},
];
const object=(v:unknown):Record<string,unknown>=>{if(!v||typeof v!=="object"||Array.isArray(v))throw Error("We only received part of this video's details. Refresh this property.");return v as Record<string,unknown>;};
const id=(v:unknown):string=>{if(typeof v!=="string"||!UUID.test(v))throw Error("We could not match this video to its property. Refresh this property.");return v;};
const nullableID=(v:unknown):string|null=>v==null?null:id(v);
const text=(v:unknown,max=200):string=>{if(typeof v!=="string"||!v||v.length>max||/[\u0000-\u001f]/.test(v))throw Error("One of the saved photos could not be read. Refresh this property.");return v;};
const integer=(v:unknown,min:number,max:number):number=>{if(typeof v!=="number"||!Number.isSafeInteger(v)||v<min||v>max)throw Error("The number of saved videos did not add up. Refresh this property.");return v;};

/** Video replies do not declare a separate expiry. `now` is only an upper bound
 * for mediaURL's declared-expiry check; the capability or SigV4 timestamp is
 * still checked against the current clock. Only finished videos require renders. */
function videoMediaURL(raw:string,scope:VideoScope,bucket?:"renders"):string {
 const now=Date.now();
 const url=mediaURL(raw,scope.org,scope.listing,new Date(now).toISOString(),now,scope.actor);
 if(isPrivateMediaURL(url))privateMediaCapability(url,{actor:scope.actor,org:scope.org,listing:scope.listing,...(bucket?{bucket}:{})},now);
 else if(bucket&&new URL(url).pathname.split("/")[2]!==bucket)throw Error("The link to the finished video points to the wrong place. Refresh this property; if it keeps happening, contact support.");
 return url;
}

export function assertVideoScope(services:Pick<StudioServices,"getSnapshot">,scope:VideoScope,signal?:AbortSignal):void {
 const snap=services.getSnapshot();
 if(signal?.aborted||snap.status!=="signed-in"||snap.identity?.isAnonymous||snap.identity?.userId!==scope.actor||snap.identityVersion!==scope.identityVersion)throw Error("Your account changed. Reopen this property's videos.");
}
export function videoScopeKey(scope:VideoScope):string {return `rendprop-video-v1:${id(scope.actor)}:${id(scope.library)}:${id(scope.listing)}`;}
export function decodeSources(raw:unknown,scope:VideoScope,offset=0):VideoSource[]{
 const r=object(raw);
 const total=integer(r.selected_count,0,1000);
 if(r.listing_id!==scope.listing||r.org_id!==scope.org||r.selected_library_org_id!==scope.library||!Array.isArray(r.sources)||r.sources.length!==Math.min(100,Math.max(0,total-offset))||r.next_offset!==(offset+100<total?offset+100:null))throw Error("These photos belong to another property or changed while loading.");
 const seen=new Set<string>();
 return r.sources.map(v=>{
  const s=object(v),photo=text(s.photo_id);if(seen.has(photo))throw Error("The same photo was chosen twice. Remove the duplicate and try again.");seen.add(photo);
  if(typeof s.eligible!=="boolean")throw Error("We could not tell which photos can go into a video. Refresh this property.");
  const asset=nullableID(s.photo_asset_id),provenance=nullableID(s.photo_provenance_id),version=typeof s.photo_version_id==="string"?s.photo_version_id:"";
  let preparation:PhotoPreparation|undefined;
  if(s.preparation!==undefined){const p=object(s.preparation);const source=id(p.source_asset_id);if(p.policy!=='video-jpeg-v1'||version!==`asset:${source}`||typeof p.source_sha256!=='string'||!HEX.test(p.source_sha256))throw Error('The prepared copy of a photo could not be traced back to the photo you selected. Refresh and choose the photo again.');preparation={preparation_id:id(p.preparation_id),source_asset_id:source,source_sha256:p.source_sha256,width:integer(p.width,1,2048),height:integer(p.height,1,2048),policy:'video-jpeg-v1'};}
  let geometry:{width:number;height:number}|undefined;
  if(s.width!==undefined||s.height!==undefined)geometry={width:integer(s.width,1,100000),height:integer(s.height,1,100000)};
  const needs=s.needs_preparation===true;
  if(needs&&(!asset||version!==`asset:${asset}`||typeof s.sha256!=='string'||!HEX.test(s.sha256)||typeof s.bytes!=='number'||!Number.isSafeInteger(s.bytes)||s.bytes<1||s.bytes>50*1024*1024))throw Error('The selected master is not available for private preparation.');
  if(s.eligible&&(!asset||!preparation&&version!==`asset:${asset}`||typeof s.sha256!=="string"||!HEX.test(s.sha256)||typeof s.bytes!=="number"||!Number.isSafeInteger(s.bytes)||s.bytes<1||s.bytes>8*1024*1024))throw Error("One selected photo did not match its saved file. Refresh this property and choose the photo again.");
  let preview:string|null=null;
  if(typeof s.preview_url==="string")preview=videoMediaURL(s.preview_url,scope);
  return{...(geometry??{}),needs_preparation:needs,...(preparation?{preparation}:{}),photo_id:photo,photo_asset_id:asset,photo_version_id:version,photo_provenance_id:provenance,preview_url:preview,bytes:typeof s.bytes==="number"?s.bytes:0,sha256:typeof s.sha256==="string"?s.sha256:null,eligible:s.eligible,reason:typeof s.reason==="string"?s.reason.slice(0,300):null};
 });
}
export function selectedSources(sources:readonly VideoSource[],selected:readonly string[]):FrozenSource[]{
 if(!selected.length||selected.length>100||new Set(selected).size!==selected.length)throw Error("Choose 1–100 different photos.");
 const map=new Map(sources.map(s=>[s.photo_id,s]));
 return selected.map(photo=>{const s=map.get(photo);if(!s?.eligible||!s.photo_asset_id)throw Error("A selected photo changed or is no longer available. Refresh and choose it again.");return{photo_id:s.photo_id,photo_asset_id:s.photo_asset_id,photo_version_id:s.photo_version_id,photo_provenance_id:s.photo_provenance_id,motion:"push_in"};});
}
// Planner-unavailable fallback (V3): a deterministic rotation by selected index so an
// outage never produces a run of identical push-ins. Selected order is preserved and
// fly_through is never chosen; all three moves are safe in any interior.
export const FALLBACK_MOTION_ROTATION:readonly VideoMotion[]=["push_in","side_glide","pull_back"];
export function fallbackVideoMotion(sources:readonly FrozenSource[]):FrozenSource[]{
 return sources.map((source,index)=>({...source,motion:FALLBACK_MOTION_ROTATION[index%FALLBACK_MOTION_ROTATION.length]!}));
}
export function decodeJob(raw:unknown,scope:VideoScope,expectedOperation?:string):VideoJob {
 const j=object(raw);id(j.job_id);id(j.operation_id);
 if(j.listing_id!==scope.listing||j.org_id!==scope.org||j.selected_library_org_id!==scope.library||expectedOperation&&j.operation_id!==expectedOperation||typeof j.manifest_sha256!=="string"||!HEX.test(j.manifest_sha256)||!["queued","generating","quality_review","composing","ready","cancelled","failed","needs_reconciliation"].includes(String(j.state)))throw Error("This video belongs to a different property or a different request. Refresh this property.");
 const photoMotion=j.source_mode==="photo_motion_v1";
 const profile=photoMotion&&PHOTO_MOTION_PROFILES.includes(j.composition_profile as PhotoMotionProfile)?j.composition_profile as PhotoMotionProfile:null;
 if(photoMotion?(!profile||j.quality_profile!==profile||j.consent_revision!=="photo-motion-v1"||j.processor_consent!==null||j.resume_available!==false):j.source_mode!==undefined||j.composition_profile!==undefined)throw Error("This video was made with settings this version of Studio does not know. Refresh before reviewing or publishing it.");
 const count=integer(j.source_count,1,100),completed=integer(j.completed_sources,0,count);
 if(j.resume_available!==undefined&&(typeof j.resume_available!=="boolean"||j.resume_available===true&&j.state!=="failed"))throw Error("We could not tell whether this video can be resumed. Refresh this property.");
 let result:VideoJob["result"]=null;
 if(j.result!=null){
  const r=object(j.result);id(r.asset_id);id(r.poster_asset_id);
  if(j.state!=="ready"||!Array.isArray(r.sources)||r.sources.length!==count||![[1920,1080],[1080,1920]].some(([w,h])=>r.width===w&&r.height===h)||typeof r.duration_s!=="number"||!Number.isFinite(r.duration_s)||r.duration_s<=0||r.duration_s>(photoMotion?600:500)||typeof r.sha256!=="string"||!HEX.test(r.sha256)||!["unbranded","social"].includes(String(r.branding_policy)))throw Error("The finished video is incomplete or the wrong shape. Refresh this property; if it stays like this, make the video again.");
  integer(r.bytes,1,1536*1024*1024);integer(r.original_photo_count,0,count);
  videoMediaURL(text(r.download_url,4096),scope,"renders");
  const refs:FinishedSource[]=r.sources.map(v=>{const s=object(v),asset=id(s.photo_asset_id),version=text(s.photo_version_id),photoProv=nullableID(s.photo_provenance_id),request=s.generation_request_id==null?null:text(s.generation_request_id,256),generatedProv=nullableID(s.generation_provenance_id);
   if(photoMotion){
    const frame=integer(s.visible_frames,48,120),bytes=integer(s.source_bytes,1,52428800);
    if(s.motion_kind!=="photo_motion"||s.source_bound!==true||request!==null||generatedProv!==null||version!==`asset:${asset}`||!PHOTO_MOTION_FRAMES.includes(frame)||typeof s.source_sha256!=="string"||!HEX.test(s.source_sha256)||(profile==="photo-motion-v1-cfr24"?s.motion!==undefined:!PHOTO_MOTION_MOVES.includes(s.motion as PhotoMotionMove)))throw Error("Part of the record for this Photo Motion video is missing. Refresh this property; if it stays like this, contact support.");
    return{photo_asset_id:asset,photo_version_id:version,photo_provenance_id:photoProv,generation_request_id:null,generation_provenance_id:null,motion_kind:"photo_motion",source_bound:true,source_sha256:s.source_sha256,source_bytes:bytes,visible_frames:frame as 48|72|96|120,...(profile==="photo-motion-v1-cfr24"?{}:{motion:s.motion as PhotoMotionMove})};
   }
   if(!["ai","original_photo"].includes(String(s.motion_kind))||s.motion_kind==="ai"&&(!request||!generatedProv))throw Error("We could not confirm which photos this video was made from. Refresh this property.");
   return{photo_asset_id:asset,photo_version_id:version,photo_provenance_id:photoProv,generation_request_id:request,generation_provenance_id:generatedProv,motion_kind:s.motion_kind as "ai"|"original_photo"};});
  if(photoMotion){
   const frames=refs.map(source=>source.motion_kind==="photo_motion"?source.visible_frames:0),hashes=refs.map(source=>source.motion_kind==="photo_motion"?source.source_sha256:null);
   const motions=refs.map(source=>source.motion_kind==="photo_motion"?source.motion:null);
   const opening=profile==="photo-motion-v2-opening-cfr24"?object(r.opening):null;
   if(opening&&(opening.kind!=="aerial_opening"||opening.position!==0||opening.fps!==24||opening.aspect!==(r.width===1920?"16:9":"9:16")||![120,121,144,192].includes(Number(opening.visible_frames))||opening.available_frames!==opening.visible_frames))throw Error("The record for this video's opening shot is incomplete. Refresh this property; if it stays like this, contact support.");
   if((!opening&&Object.hasOwn(r,"opening"))||r.source_mode!=="photo_motion_v1"||r.composition_profile!==profile||r.fps!==24||r.original_photo_count!==0||new Set(refs.map(source=>source.photo_asset_id)).size!==count||r.total_frames!==frames.reduce<number>((sum,frame)=>sum+frame,0)+(opening?Number(opening.visible_frames):0)||!Array.isArray(r.source_frames)||JSON.stringify(r.source_frames)!==JSON.stringify(frames)||!Array.isArray(r.source_sha256s)||JSON.stringify(r.source_sha256s)!==JSON.stringify(hashes)||(profile==="photo-motion-v1-cfr24"?Object.hasOwn(r,"source_motions"):!Array.isArray(r.source_motions)||JSON.stringify(r.source_motions)!==JSON.stringify(motions)))throw Error("The record of this video's timing is incomplete. Refresh this property; if it stays like this, contact support.");
  }
  result={...r,sources:refs} as VideoJob["result"];
 }
 if(j.state==="ready"&&!result)throw Error("The record for this finished video is missing. Refresh before reviewing or publishing it.");
 return{...retainVideoPermissionMetadata(j),job_id:j.job_id as string,operation_id:j.operation_id as string,listing_id:scope.listing,org_id:scope.org,selected_library_org_id:scope.library,source_count:count,manifest_sha256:j.manifest_sha256 as string,state:j.state as VideoState,completed_sources:completed,...(typeof j.message==="string"?{message:j.message.slice(0,1000)}:{}),...(j.resume_available===true?{resume_available:true}:{}),...(profile?{source_mode:"photo_motion_v1" as const,composition_profile:profile,resume_available:false}:{}),result};
}
export async function resumeVideo(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,job:VideoJob,signal?:AbortSignal,legacyEndpointConfirmed=false):Promise<VideoJob>{
 assertVideoScope(services,scope,signal);const checked=decodeJob(job,scope);if(checked.resume_available!==true)throw Error("This saved video cannot be resumed.");
 const permission=permissionForSavedJob(checked,legacyEndpointConfirmed);if(!permission)throw Error("We could not confirm the AI permission this video was started with. Refresh its status or cancel it. Nothing new was started.");
 const reply=decodeJob(await services.api(`/functions/v1/property-video-jobs/${checked.job_id}/resume`,{orgId:scope.library,expectedLibraryOrgId:scope.library,expectedListingId:scope.listing,method:"POST",body:{},...videoPermissionHeaders(permission),signal}),scope,checked.operation_id);
 assertVideoScope(services,scope,signal);if(reply.job_id!==checked.job_id||reply.completed_sources<checked.completed_sources)throw Error("We could not confirm that the right video was resumed. Refresh this property to check.");return reply;
}

const SCENES=["front_exterior","entry","living","kitchen","dining","bedroom","bathroom","outdoor","rear_exterior","detail","unknown"];
export async function planVideoSources(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,sources:FrozenSource[],operation:string,_legacyAutomaticOrder:boolean,signal?:AbortSignal):Promise<FrozenSource[]>{
 const planned:Array<{source:FrozenSource;scene:string;index:number}>=[];
 for(let start=0;start<sources.length;start+=20){
  assertVideoScope(services,scope,signal);const batch=sources.slice(start,start+20);
  const raw=object(await services.api("/functions/v1/property-video-plan",{orgId:scope.library,method:"POST",idempotencyKey:`video-plan:${operation}:${start}`,aiConsent:"property-video-plan-v1",signal,timeoutMs:90_000,body:{listing_id:scope.listing,expected_org_id:scope.library,photos:batch.map(s=>({photo_id:s.photo_id,asset_id:s.photo_asset_id}))}}));
  assertVideoScope(services,scope,signal);
  if(raw.listing_id!==scope.listing||raw.org_id!==scope.library||!Array.isArray(raw.photos)||raw.photos.length!==batch.length)throw Error("The automatic plan left out one of your photos. Try again.");
  const map=new Map<string,Record<string,unknown>>();for(const v of raw.photos){const p=object(v);if(typeof p.photo_id!=="string"||map.has(p.photo_id))throw Error("The automatic plan used one photo twice. Try again.");map.set(p.photo_id,p);}
  batch.forEach((source,index)=>{const p=map.get(source.photo_id);if(!p||p.asset_id!==source.photo_asset_id||!SCENES.includes(String(p.scene))||!["fly_through","push_in","side_glide","pull_back"].includes(String(p.motion))||typeof p.confidence!=="number"||!Number.isFinite(p.confidence)||p.confidence<0||p.confidence>1)throw Error("The automatic plan swapped one of your photos for another. Try again.");
   planned.push({source:{...source,motion:(p.confidence>.6&&p.scene!=="unknown"?p.motion:"push_in") as VideoMotion},scene:p.confidence>.6?String(p.scene):"unknown",index:start+index});});
 }
 // The planner supplies per-photo classification and motion, never a new sequence.
 // Ignore the legacy automatic-order preference even on an unplanned saved recipe.
 return planned.map(p=>p.source);
}
export type VideoPreparation={photosComplete?:boolean;framingReviewed?:boolean;planned:boolean;voiceComplete:boolean;automatic:boolean;camera:string;voice:"off"|"own"|"ai";voiceID:string;script:string};
export type VideoJournal={permission?:VideoPermission;schema:1;actor:string;org:string;library:string;listing:string;input:VideoInput;job_id?:string;preparation?:VideoPreparation;publication?:{id:string;job_id:string;asset_id:string};};
export function saveVideoJournal(storage:Pick<Storage,"setItem">&Partial<Pick<Storage,"getItem">>,scope:VideoScope,value:VideoJournal):void {
 if(value.actor!==scope.actor||value.org!==scope.org||value.library!==scope.library||value.listing!==scope.listing)throw Error("Video recovery belongs to another account.");
 if(value.permission!==undefined)decodeVideoPermission(value.permission);
 const raw=storage.getItem?.(videoScopeKey(scope));
 if(raw){const prior=readVideoJournal({getItem:()=>raw},scope);if(prior?.input.operation_id===value.input.operation_id&&!sameVideoPermission(prior.permission,value.permission))throw Error("A saved video keeps the AI permission it was started with. Recover or discard that video before changing the permission.");}
 storage.setItem(videoScopeKey(scope),JSON.stringify(value));
}
export function readVideoJournal(storage:Pick<Storage,"getItem">,scope:VideoScope):VideoJournal|null {
 const raw=storage.getItem(videoScopeKey(scope));if(!raw)return null;
 try{const j=object(JSON.parse(raw)),input=object(j.input);if(j.schema!==1||j.actor!==scope.actor||j.org!==scope.org||j.library!==scope.library||j.listing!==scope.listing||input.listing_id!==scope.listing||input.expected_org_id!==scope.library||!UUID.test(String(input.operation_id))||!Array.isArray(input.sources)||input.sources.length<1||input.sources.length>100)throw Error();
  // Recovered manifests carry source identities/options, never media URLs/keys.
  for(const s of input.sources){const r=object(s);if(Object.keys(r).some(k=>!["photo_id","photo_asset_id","photo_version_id","photo_provenance_id","motion"].includes(k)))throw Error();id(r.photo_asset_id);text(r.photo_id);text(r.photo_version_id);nullableID(r.photo_provenance_id);}
  if(j.permission!==undefined)j.permission=decodeVideoPermission(j.permission);
  if(j.job_id!==undefined)id(j.job_id);if(j.publication!==undefined){const p=object(j.publication);id(p.id);id(p.job_id);id(p.asset_id);}
  if(j.preparation!==undefined){const p=object(j.preparation);if(p.framingReviewed!==undefined&&typeof p.framingReviewed!=="boolean"||p.photosComplete!==undefined&&typeof p.photosComplete!=="boolean"||typeof p.planned!=="boolean"||typeof p.voiceComplete!=="boolean"||typeof p.automatic!=="boolean"||!["off","own","ai"].includes(String(p.voice))||!["automatic","fly_through","push_in","side_glide","pull_back"].includes(String(p.camera))||typeof p.voiceID!=="string"||p.voiceID.length>100||typeof p.script!=="string"||p.script.length>1000)throw Error();}
  return j as VideoJournal;
 }catch{throw Error("We could not read the video request saved in this browser. Videos already being made are safe. Refresh the video list before starting again.");}
}
export async function enqueueVideo(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,journal:VideoJournal,storage:Pick<Storage,"setItem">,signal?:AbortSignal):Promise<VideoJob>{
 assertVideoScope(services,scope,signal);saveVideoJournal(storage,scope,journal);
 const raw=await services.api("/functions/v1/property-video-jobs",{method:"POST",orgId:scope.library,body:journal.input,idempotencyKey:`property-video:${journal.input.operation_id}`,...videoPermissionHeaders(journal.permission??{token:CONSENT_V1}),expectedLibraryOrgId:scope.library,expectedListingId:scope.listing,signal,timeoutMs:90_000});
 assertVideoScope(services,scope,signal);const job=decodeJob(raw,scope,journal.input.operation_id);saveVideoJournal(storage,scope,{...journal,job_id:job.job_id});return job;
}
// A closed operation can never start a job: either a durable capacity refusal
// or the agent's server-confirmed discard (C2). Servers before C2 send no
// reason, and then only a capacity refusal could close an operation.
export type VideoClosure="capacity_refused"|"abandoned";
// `abandoned` is present only for a server-confirmed discard, so existing
// capacity-refusal and open-operation shapes are unchanged.
export type VideoOperation={job:VideoJob|null;closed:boolean;abandoned?:true};
export function videoClosure(operation:VideoOperation):VideoClosure|null{return operation.closed?(operation.abandoned?"abandoned":"capacity_refused"):null;}
export type VideoOperationReference={input:{operation_id:string};job_id?:string};
function decodeOperation(rawValue:unknown,scope:VideoScope,journal:VideoOperationReference):VideoOperation{
 const raw=object(rawValue);
 const job=raw.job===null?null:decodeJob(raw.job,scope,journal.input.operation_id);
 if(raw.operation_closed===true){
  if(job||raw.operation_id!==journal.input.operation_id||raw.listing_id!==scope.listing||raw.selected_library_org_id!==scope.library)throw Error('The answer we got was for a different video request. Refresh this property.');
  if(raw.closed_reason==="abandoned")return{job:null,closed:true,abandoned:true};
  if(raw.closed_reason!=null&&raw.closed_reason!=="capacity_refused")throw Error("We could not tell where this saved video stands. Refresh this property before changing it.");
  return{job:null,closed:true};
 }
 if(raw.closed_reason!=null)throw Error("We only received part of this saved video's status. Refresh this property before changing it.");
 return{job,closed:false};
}
export async function inspectVideoOperation(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,journal:VideoOperationReference,signal?:AbortSignal):Promise<VideoOperation>{
 assertVideoScope(services,scope,signal);
 id(journal.input.operation_id);
 const raw=await services.api(`/functions/v1/property-video-jobs?operation_id=${journal.input.operation_id}&listing_id=${scope.listing}&expected_org_id=${scope.library}`,{orgId:scope.library,expectedLibraryOrgId:scope.library,expectedListingId:scope.listing,signal});
 assertVideoScope(services,scope,signal);
 return decodeOperation(raw,scope,journal);
}
/** C2: the server resolves this exact unaccepted request. An accepted job comes back untouched; only an unseen operation is closed for good. */
export async function abandonVideoOperation(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,journal:VideoOperationReference,signal?:AbortSignal):Promise<VideoOperation>{
 assertVideoScope(services,scope,signal);
 if(journal.job_id)throw Error("A video was already started for this request. Cancel or recover that video instead.");
 const operation=id(journal.input.operation_id);
 const raw=object(await services.api(`/functions/v1/property-video-jobs/operations/${operation}/abandon`,{method:"POST",orgId:scope.library,body:{listing_id:scope.listing,expected_org_id:scope.library},idempotencyKey:`property-video-abandon:${operation}`,expectedLibraryOrgId:scope.library,expectedListingId:scope.listing,signal}));
 assertVideoScope(services,scope,signal);
 if(raw.operation_id!==operation||raw.listing_id!==scope.listing||raw.selected_library_org_id!==scope.library)throw Error("The answer we got was for a different video. Your saved request is unchanged. Try again.");
 const outcome=decodeOperation(raw,scope,journal);
 if(!outcome.closed&&!outcome.job)throw Error("The discard was not confirmed. Your saved request is unchanged; try again.");
 return outcome;
}
function retainClosedVideo(storage:Pick<Storage,'setItem'>,scope:VideoScope,journal:VideoJournal,reason:VideoClosure):void{
 if(journal.job_id)throw Error('An accepted video cannot be replaced as a rejected request.');
 saveVideoJournal({setItem:(_key,value)=>storage.setItem(`${videoScopeKey(scope)}:${reason==="abandoned"?"abandoned":"capacity-refused"}:${journal.input.operation_id}`,value)},scope,journal);
}
export function retainRejectedVideo(storage:Pick<Storage,'setItem'>,scope:VideoScope,journal:VideoJournal):void{retainClosedVideo(storage,scope,journal,"capacity_refused");}
export function retainAbandonedVideo(storage:Pick<Storage,'setItem'>,scope:VideoScope,journal:VideoJournal):void{retainClosedVideo(storage,scope,journal,"abandoned");}
export async function recoverVideo(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,journal:VideoJournal,signal?:AbortSignal):Promise<VideoJob|null>{
 return (await inspectVideoOperation(services,scope,journal,signal)).job;
}
export async function publishVideo(services:Pick<StudioServices,"api"|"getSnapshot"|"listingReadScope">,scope:VideoScope,job:VideoJob,publicationID:string,signal?:AbortSignal,resolve:typeof resolveTourLinks=resolveTourLinks):Promise<{url:string|null;assertCurrent:()=>void}>{
 assertVideoScope(services,scope,signal);id(publicationID);const checked=decodeJob(job,scope);
 const result=checked.result;if(!result||result.branding_policy!=="unbranded"||result.width!==1920||result.height!==1080)throw Error("Only the wide (landscape) listing video without branding can be put on the website.");
 const composition={schema:1,purpose:"listing",aspect:"16:9",branding_policy:"unbranded",sources:result.sources,...(checked.source_mode==="photo_motion_v1"?{source_mode:checked.source_mode,composition_profile:checked.composition_profile,fps:result.fps,total_frames:result.total_frames,...(result.opening===undefined?{}:{opening:result.opening})}:{})};
 const raw=object(await services.api("/functions/v1/renders/publish-app",{method:"POST",orgId:scope.library,idempotencyKey:`photo-video:${publicationID}`,signal,body:{listing_id:scope.listing,asset_id:result.asset_id,poster_asset_id:result.poster_asset_id,presentation_kind:"photo_video",publication_id:publicationID,composition}}));
 assertVideoScope(services,scope,signal);
 if(raw.listing_id!==scope.listing||raw.org_id!==scope.org||raw.library_org_id!==scope.library||raw.presentation_kind!=="photo_video"||raw.presentation_asset_id!==result.asset_id||raw.publication_id!==publicationID||typeof raw.slug!=="string"||!/^[A-Za-z0-9_-]{1,160}$/.test(raw.slug)||raw.share_url!==`https://rendprop.com/f/${raw.slug}`)throw Error("We could not confirm this video was put on the website. Check the website's video before trying again.");
 // The mutation confirms publication identity, not its address URL. Resolve
 // the current public link after publication; a directory refresh or account
 // change must not put a stale property's link into this workspace.
 const guard=await services.listingReadScope(scope.org,scope.listing,scope.library,signal);
 assertVideoScope(services,scope,signal);guard();
 const proof=await resolve(raw.slug,{signal});
 assertVideoScope(services,scope,signal);guard();
 return {url:safeTourLinks(raw.slug,proof)?.branded??null,
  assertCurrent:()=>{assertVideoScope(services,scope,signal);guard();}};
}
