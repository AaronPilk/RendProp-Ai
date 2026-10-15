import type {StudioServices} from "../../data/services";
import {privateMediaCapability} from "../../data/private-media";

export type VideoScope={actor:string;org:string;library:string;listing:string;identityVersion:number};
export type VideoMotion="fly_through"|"push_in"|"side_glide"|"pull_back";
export type VideoPurpose="listing"|"social";
export type PhotoPreparation={preparation_id:string;source_asset_id:string;source_sha256:string;width:number;height:number;policy:'video-jpeg-v1'};
export type VideoSource={width?:number;height?:number;needs_preparation?:boolean;preparation?:PhotoPreparation;photo_id:string;photo_asset_id:string|null;photo_version_id:string;photo_provenance_id:string|null;preview_url:string|null;bytes:number;sha256:string|null;eligible:boolean;reason:string|null};
export type FrozenSource={photo_id:string;photo_asset_id:string;photo_version_id:string;photo_provenance_id:string|null;motion:VideoMotion};
export type FinishedSource={photo_asset_id:string;photo_version_id:string;photo_provenance_id:string|null;generation_request_id:string|null;generation_provenance_id:string|null;motion_kind:"ai"|"original_photo"};
export type VideoPresentation={transition:"cut"|"dissolve"|"whip";shot_caption_style:"off"|"lowerThird"|"punchCard"|"highlightBox";spoken_captions:boolean;title_card:{title:string;subtitle:string;watermark:string}|null;shot_labels:(string|null)[]};
export type VideoInput={operation_id:string;listing_id:string;expected_org_id:string;purpose:VideoPurpose;aspect:"16:9"|"9:16";sources:FrozenSource[];narration_result_id:string|null;narration_asset_id:string|null;narration_words:{text:string;start:number;end:number}[];music:VideoMusic|null;presentation:VideoPresentation;allow_original_photo_fallback:boolean};
export type VideoState="queued"|"generating"|"quality_review"|"composing"|"ready"|"cancelled"|"failed"|"needs_reconciliation";
export type VideoJob={job_id:string;operation_id:string;listing_id:string;org_id:string;selected_library_org_id:string;source_count:number;manifest_sha256:string;state:VideoState;completed_sources:number;message?:string;resume_available?:boolean;result:{asset_id:string;poster_asset_id:string;download_url:string;width:number;height:number;duration_s:number;bytes:number;sha256:string;branding_policy:"unbranded"|"social";sources:FinishedSource[];original_photo_count:number;music:unknown|null}|null};
export type VideoMusic={track_id:"calm"|"upbeat"|"cinematic";asset_sha256:string;license_id:"CC0-1.0";license_evidence_sha256:string;gain:.18;duck_gain:.07};
const UUID=/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
const HEX=/^[a-f0-9]{64}$/;
export const MUSIC:readonly VideoMusic[]=[
 {track_id:"calm",asset_sha256:"9503b0d6d59cdc76f69f786b6f2fd2fb6f39a747e245e8f02dc358b7fd4dbb36",license_id:"CC0-1.0",license_evidence_sha256:"8a5d6e54d255e734a434dbb63abb7fbcf759eb619be6735c123f467d444a9074",gain:.18,duck_gain:.07},
 {track_id:"upbeat",asset_sha256:"ce55346893354d49746c689b3dde135ec1f3d9299d22ef8ec26b27a022020375",license_id:"CC0-1.0",license_evidence_sha256:"fa5b82351abf48b8b0877b1c10ed5163f3243a2cd7781c3b02dcb72ae4d26e27",gain:.18,duck_gain:.07},
 {track_id:"cinematic",asset_sha256:"119eaedb3c58948d6f6b346ec61aac58fa28174658714e06a6a5b8d0ec11bdc8",license_id:"CC0-1.0",license_evidence_sha256:"5f83d54c6e0d67b855d772f12615fe668c6678dc551cf1a95f382e96d89e3a45",gain:.18,duck_gain:.07},
];
const object=(v:unknown):Record<string,unknown>=>{if(!v||typeof v!=="object"||Array.isArray(v))throw Error("The saved video reply is incomplete. Refresh this property.");return v as Record<string,unknown>;};
const id=(v:unknown):string=>{if(typeof v!=="string"||!UUID.test(v))throw Error("The saved property identity is invalid.");return v;};
const nullableID=(v:unknown):string|null=>v==null?null:id(v);
const text=(v:unknown,max=200):string=>{if(typeof v!=="string"||!v||v.length>max||/[\u0000-\u001f]/.test(v))throw Error("The saved photo version is invalid.");return v;};
const integer=(v:unknown,min:number,max:number):number=>{if(typeof v!=="number"||!Number.isSafeInteger(v)||v<min||v>max)throw Error("The saved video count is invalid.");return v;};

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
  const s=object(v),photo=text(s.photo_id);if(seen.has(photo))throw Error("The photo selection contains duplicates.");seen.add(photo);
  if(typeof s.eligible!=="boolean")throw Error("The saved photo eligibility is incomplete.");
  const asset=nullableID(s.photo_asset_id),provenance=nullableID(s.photo_provenance_id),version=typeof s.photo_version_id==="string"?s.photo_version_id:"";
  let preparation:PhotoPreparation|undefined;
  if(s.preparation!==undefined){const p=object(s.preparation);const source=id(p.source_asset_id);if(p.policy!=='video-jpeg-v1'||version!==`asset:${source}`||typeof p.source_sha256!=='string'||!HEX.test(p.source_sha256))throw Error('The processing copy has no verified selected-master lineage.');preparation={preparation_id:id(p.preparation_id),source_asset_id:source,source_sha256:p.source_sha256,width:integer(p.width,1,2048),height:integer(p.height,1,2048),policy:'video-jpeg-v1'};}
  let geometry:{width:number;height:number}|undefined;
  if(s.width!==undefined||s.height!==undefined)geometry={width:integer(s.width,1,100000),height:integer(s.height,1,100000)};
  const needs=s.needs_preparation===true;
  if(needs&&(!asset||version!==`asset:${asset}`||typeof s.sha256!=='string'||!HEX.test(s.sha256)||typeof s.bytes!=='number'||!Number.isSafeInteger(s.bytes)||s.bytes<1||s.bytes>50*1024*1024))throw Error('The selected master is not available for private preparation.');
  if(s.eligible&&(!asset||!preparation&&version!==`asset:${asset}`||typeof s.sha256!=="string"||!HEX.test(s.sha256)||typeof s.bytes!=="number"||!Number.isSafeInteger(s.bytes)||s.bytes<1||s.bytes>8*1024*1024))throw Error("The exact selected photo bytes could not be verified.");
  let preview:string|null=null;
  if(typeof s.preview_url==="string"){privateMediaCapability(s.preview_url,{actor:scope.actor,org:scope.org,listing:scope.listing});preview=s.preview_url;}
  return{...(geometry??{}),needs_preparation:needs,...(preparation?{preparation}:{}),photo_id:photo,photo_asset_id:asset,photo_version_id:version,photo_provenance_id:provenance,preview_url:preview,bytes:typeof s.bytes==="number"?s.bytes:0,sha256:typeof s.sha256==="string"?s.sha256:null,eligible:s.eligible,reason:typeof s.reason==="string"?s.reason.slice(0,300):null};
 });
}
export function selectedSources(sources:readonly VideoSource[],selected:readonly string[]):FrozenSource[]{
 if(!selected.length||selected.length>100||new Set(selected).size!==selected.length)throw Error("Choose 1–100 different photos.");
 const map=new Map(sources.map(s=>[s.photo_id,s]));
 return selected.map(photo=>{const s=map.get(photo);if(!s?.eligible||!s.photo_asset_id)throw Error("A selected photo changed or is unavailable. Refresh its saved version.");return{photo_id:s.photo_id,photo_asset_id:s.photo_asset_id,photo_version_id:s.photo_version_id,photo_provenance_id:s.photo_provenance_id,motion:"push_in"};});
}
export function decodeJob(raw:unknown,scope:VideoScope,expectedOperation?:string):VideoJob {
 const j=object(raw);id(j.job_id);id(j.operation_id);
 if(j.listing_id!==scope.listing||j.org_id!==scope.org||j.selected_library_org_id!==scope.library||expectedOperation&&j.operation_id!==expectedOperation||typeof j.manifest_sha256!=="string"||!HEX.test(j.manifest_sha256)||!["queued","generating","quality_review","composing","ready","cancelled","failed","needs_reconciliation"].includes(String(j.state)))throw Error("This video belongs to another property or operation.");
 const count=integer(j.source_count,1,100),completed=integer(j.completed_sources,0,count);
 if(j.resume_available!==undefined&&(typeof j.resume_available!=="boolean"||j.resume_available===true&&j.state!=="failed"))throw Error("The saved video's resume state is invalid.");
 let result:VideoJob["result"]=null;
 if(j.result!=null){
  const r=object(j.result);id(r.asset_id);id(r.poster_asset_id);
  if(j.state!=="ready"||!Array.isArray(r.sources)||r.sources.length!==count||![[1920,1080],[1080,1920]].some(([w,h])=>r.width===w&&r.height===h)||typeof r.duration_s!=="number"||!Number.isFinite(r.duration_s)||r.duration_s<=0||r.duration_s>500||typeof r.sha256!=="string"||!HEX.test(r.sha256)||!["unbranded","social"].includes(String(r.branding_policy)))throw Error("The finished video is incomplete or below its promised framing.");
  integer(r.bytes,1,1536*1024*1024);integer(r.original_photo_count,0,count);
  privateMediaCapability(text(r.download_url,4096),{actor:scope.actor,org:scope.org,listing:scope.listing,bucket:"renders"});
  const refs=r.sources.map(v=>{const s=object(v),asset=id(s.photo_asset_id),version=text(s.photo_version_id),photoProv=nullableID(s.photo_provenance_id),request=s.generation_request_id==null?null:text(s.generation_request_id,256),generatedProv=nullableID(s.generation_provenance_id);
   if(!["ai","original_photo"].includes(String(s.motion_kind))||s.motion_kind==="ai"&&(!request||!generatedProv))throw Error("The video source provenance is invalid.");
   return{photo_asset_id:asset,photo_version_id:version,photo_provenance_id:photoProv,generation_request_id:request,generation_provenance_id:generatedProv,motion_kind:s.motion_kind as FinishedSource['motion_kind']};});
  result={...r,sources:refs} as VideoJob["result"];
 }
 if(j.state==="ready"&&!result)throw Error("The finished video receipt is missing. Refresh before reviewing or publishing.");
 return{job_id:j.job_id as string,operation_id:j.operation_id as string,listing_id:scope.listing,org_id:scope.org,selected_library_org_id:scope.library,source_count:count,manifest_sha256:j.manifest_sha256 as string,state:j.state as VideoState,completed_sources:completed,...(typeof j.message==="string"?{message:j.message.slice(0,1000)}:{}),...(j.resume_available===true?{resume_available:true}:{}),result};
}
export async function resumeVideo(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,job:VideoJob,signal?:AbortSignal):Promise<VideoJob>{
 assertVideoScope(services,scope,signal);const checked=decodeJob(job,scope);if(checked.resume_available!==true)throw Error("This saved video is not available to resume.");
 const reply=decodeJob(await services.api(`/functions/v1/property-video-jobs/${checked.job_id}/resume`,{orgId:scope.library,method:"POST",body:{},aiConsent:"property-video-jobs-v1",signal}),scope,checked.operation_id);
 assertVideoScope(services,scope,signal);if(reply.job_id!==checked.job_id||reply.completed_sources<checked.completed_sources)throw Error("The resumed video was not confirmed for the same saved work.");return reply;
}

const SCENES=["front_exterior","entry","living","kitchen","dining","bedroom","bathroom","outdoor","rear_exterior","detail","unknown"];
export async function planVideoSources(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,sources:FrozenSource[],operation:string,_legacyAutomaticOrder:boolean,signal?:AbortSignal):Promise<FrozenSource[]>{
 const planned:Array<{source:FrozenSource;scene:string;index:number}>=[];
 for(let start=0;start<sources.length;start+=20){
  assertVideoScope(services,scope,signal);const batch=sources.slice(start,start+20);
  const raw=object(await services.api("/functions/v1/property-video-plan",{orgId:scope.library,method:"POST",idempotencyKey:`video-plan:${operation}:${start}`,aiConsent:"property-video-plan-v1",signal,timeoutMs:90_000,body:{listing_id:scope.listing,expected_org_id:scope.library,photos:batch.map(s=>({photo_id:s.photo_id,asset_id:s.photo_asset_id}))}}));
  assertVideoScope(services,scope,signal);
  if(raw.listing_id!==scope.listing||raw.org_id!==scope.library||!Array.isArray(raw.photos)||raw.photos.length!==batch.length)throw Error("The automatic plan omitted a selected photo.");
  const map=new Map<string,Record<string,unknown>>();for(const v of raw.photos){const p=object(v);if(typeof p.photo_id!=="string"||map.has(p.photo_id))throw Error("The automatic plan repeats a selected photo.");map.set(p.photo_id,p);}
  batch.forEach((source,index)=>{const p=map.get(source.photo_id);if(!p||p.asset_id!==source.photo_asset_id||!SCENES.includes(String(p.scene))||!["fly_through","push_in","side_glide","pull_back"].includes(String(p.motion))||typeof p.confidence!=="number"||!Number.isFinite(p.confidence)||p.confidence<0||p.confidence>1)throw Error("The automatic plan changed a selected source.");
   planned.push({source:{...source,motion:(p.confidence>.6&&p.scene!=="unknown"?p.motion:"push_in") as VideoMotion},scene:p.confidence>.6?String(p.scene):"unknown",index:start+index});});
 }
 // The planner supplies per-photo classification and motion, never a new sequence.
 // Ignore the legacy automatic-order preference even on an unplanned saved recipe.
 return planned.map(p=>p.source);
}
export type VideoPreparation={photosComplete?:boolean;framingReviewed?:boolean;planned:boolean;voiceComplete:boolean;automatic:boolean;camera:string;voice:"off"|"own"|"ai";voiceID:string;script:string};
export type VideoJournal={schema:1;actor:string;org:string;library:string;listing:string;input:VideoInput;job_id?:string;preparation?:VideoPreparation;publication?:{id:string;job_id:string;asset_id:string};};
export function saveVideoJournal(storage:Pick<Storage,"setItem">,scope:VideoScope,value:VideoJournal):void {if(value.actor!==scope.actor||value.org!==scope.org||value.library!==scope.library||value.listing!==scope.listing)throw Error("Video recovery belongs to another account.");storage.setItem(videoScopeKey(scope),JSON.stringify(value));}
export function readVideoJournal(storage:Pick<Storage,"getItem">,scope:VideoScope):VideoJournal|null {
 const raw=storage.getItem(videoScopeKey(scope));if(!raw)return null;
 try{const j=object(JSON.parse(raw)),input=object(j.input);if(j.schema!==1||j.actor!==scope.actor||j.org!==scope.org||j.library!==scope.library||j.listing!==scope.listing||input.listing_id!==scope.listing||input.expected_org_id!==scope.library||!UUID.test(String(input.operation_id))||!Array.isArray(input.sources)||input.sources.length<1||input.sources.length>100)throw Error();
  // Recovered manifests carry source identities/options, never media URLs/keys.
  for(const s of input.sources){const r=object(s);if(Object.keys(r).some(k=>!["photo_id","photo_asset_id","photo_version_id","photo_provenance_id","motion"].includes(k)))throw Error();id(r.photo_asset_id);text(r.photo_id);text(r.photo_version_id);nullableID(r.photo_provenance_id);}
  if(j.job_id!==undefined)id(j.job_id);if(j.publication!==undefined){const p=object(j.publication);id(p.id);id(p.job_id);id(p.asset_id);}
  if(j.preparation!==undefined){const p=object(j.preparation);if(p.framingReviewed!==undefined&&typeof p.framingReviewed!=="boolean"||p.photosComplete!==undefined&&typeof p.photosComplete!=="boolean"||typeof p.planned!=="boolean"||typeof p.voiceComplete!=="boolean"||typeof p.automatic!=="boolean"||!["off","own","ai"].includes(String(p.voice))||!["automatic","fly_through","push_in","side_glide","pull_back"].includes(String(p.camera))||typeof p.voiceID!=="string"||p.voiceID.length>100||typeof p.script!=="string"||p.script.length>1000)throw Error();}
  return j as VideoJournal;
 }catch{throw Error("The saved video request could not be read. Its server jobs are preserved; refresh the video list before starting again.");}
}
export async function enqueueVideo(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,journal:VideoJournal,storage:Pick<Storage,"setItem">,signal?:AbortSignal):Promise<VideoJob>{
 assertVideoScope(services,scope,signal);saveVideoJournal(storage,scope,journal);
 const raw=await services.api("/functions/v1/property-video-jobs",{method:"POST",orgId:scope.library,body:journal.input,idempotencyKey:`property-video:${journal.input.operation_id}`,aiConsent:"property-video-jobs-v1",signal,timeoutMs:90_000});
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
function decodeOperation(rawValue:unknown,scope:VideoScope,journal:VideoJournal):VideoOperation{
 const raw=object(rawValue);
 const job=raw.job===null?null:decodeJob(raw.job,scope,journal.input.operation_id);
 if(raw.operation_closed===true){
  if(job||raw.operation_id!==journal.input.operation_id||raw.listing_id!==scope.listing||raw.selected_library_org_id!==scope.library)throw Error('The rejected operation proof belongs to another request.');
  if(raw.closed_reason==="abandoned")return{job:null,closed:true,abandoned:true};
  if(raw.closed_reason!=null&&raw.closed_reason!=="capacity_refused")throw Error("The saved request's server state is not recognized. Refresh this property before changing it.");
  return{job:null,closed:true};
 }
 if(raw.closed_reason!=null)throw Error("The saved request's server state is incomplete. Refresh this property before changing it.");
 return{job,closed:false};
}
export async function inspectVideoOperation(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,journal:VideoJournal,signal?:AbortSignal):Promise<VideoOperation>{
 assertVideoScope(services,scope,signal);
 const raw=await services.api(`/functions/v1/property-video-jobs?operation_id=${journal.input.operation_id}&listing_id=${scope.listing}&expected_org_id=${scope.library}`,{orgId:scope.library,signal});
 assertVideoScope(services,scope,signal);
 return decodeOperation(raw,scope,journal);
}
/** C2: the server resolves this exact unaccepted request. An accepted job comes back untouched; only an unseen operation is closed for good. */
export async function abandonVideoOperation(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,journal:VideoJournal,signal?:AbortSignal):Promise<VideoOperation>{
 assertVideoScope(services,scope,signal);
 if(journal.job_id)throw Error("This request already has a server video. Cancel or recover that video instead.");
 const operation=id(journal.input.operation_id);
 const raw=object(await services.api(`/functions/v1/property-video-jobs/operations/${operation}/abandon`,{method:"POST",orgId:scope.library,body:{listing_id:scope.listing,expected_org_id:scope.library},idempotencyKey:`property-video-abandon:${operation}`,signal}));
 assertVideoScope(services,scope,signal);
 if(raw.operation_id!==operation||raw.listing_id!==scope.listing||raw.selected_library_org_id!==scope.library)throw Error("The discard reply belongs to another request. Your saved request is unchanged.");
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
export async function publishVideo(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,job:VideoJob,publicationID:string,signal?:AbortSignal):Promise<string>{
 assertVideoScope(services,scope,signal);id(publicationID);const checked=decodeJob(job,scope);
 const result=checked.result;if(!result||result.branding_policy!=="unbranded"||result.width!==1920||result.height!==1080)throw Error("Only a reviewed landscape listing video can be selected for the website.");
 const raw=object(await services.api("/functions/v1/renders/publish-app",{method:"POST",orgId:scope.library,idempotencyKey:`photo-video:${publicationID}`,signal,body:{listing_id:scope.listing,asset_id:result.asset_id,poster_asset_id:result.poster_asset_id,presentation_kind:"photo_video",publication_id:publicationID,composition:{schema:1,purpose:"listing",aspect:"16:9",branding_policy:"unbranded",sources:result.sources}}}));
 assertVideoScope(services,scope,signal);
 if(raw.listing_id!==scope.listing||raw.org_id!==scope.org||raw.library_org_id!==scope.library||raw.presentation_kind!=="photo_video"||raw.presentation_asset_id!==result.asset_id||raw.publication_id!==publicationID||typeof raw.slug!=="string"||!/^[A-Za-z0-9_-]{1,160}$/.test(raw.slug)||raw.share_url!==`https://rendprop.com/f/${raw.slug}`)throw Error("Publication was not confirmed for this exact property video. Check its saved selection before retrying.");
 return `https://rendprop.com/property/${raw.slug}`;
}
