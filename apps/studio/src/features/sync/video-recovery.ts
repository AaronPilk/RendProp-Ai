import type {StudioServices} from "../../data/services";
import {abandonVideoOperation,assertVideoScope,inspectVideoOperation,MUSIC,readVideoJournal,videoClosure,videoScopeKey,type VideoJournal,type VideoOperation,type VideoOperationReference,type VideoScope} from "./property-video";

const UUID=/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
export const VIDEO_RECOVERY_NOTICE="This browser holds a saved video request that this version of Studio cannot reopen. Your photos and finished videos are below. Recover or discard the saved request before making a new video.";
export type UnreadableVideoRequest={raw:string|null;reference:VideoOperationReference|null};
export type VideoRecovery={journal:VideoJournal|null;unreadable:UnreadableVideoRequest|null};
function currentRecipe(journal:VideoJournal):boolean {
 const i=journal.input,p=i.presentation;
 const string=(value:unknown,max:number)=>typeof value==="string"&&value.length<=max;
 const uuidOrNull=(value:unknown)=>value===null||typeof value==="string"&&UUID.test(value);
 return Object.keys(i).every(key=>["operation_id","listing_id","expected_org_id","purpose","aspect","sources","narration_result_id","narration_asset_id","narration_words","music","presentation","allow_original_photo_fallback"].includes(key))
  &&["listing","social"].includes(i.purpose)&&i.aspect===(i.purpose==="listing"?"16:9":"9:16")&&typeof i.allow_original_photo_fallback==="boolean"
  &&i.sources.every(s=>["fly_through","push_in","side_glide","pull_back"].includes(s.motion))
  &&uuidOrNull(i.narration_result_id)&&uuidOrNull(i.narration_asset_id)&&Array.isArray(i.narration_words)&&i.narration_words.length<=2000&&i.narration_words.every(w=>w&&string(w.text,200)&&Number.isFinite(w.start)&&Number.isFinite(w.end)&&w.start>=0&&w.end>w.start)
  &&(i.music===null||MUSIC.some(track=>i.music&&Object.keys(i.music).length===Object.keys(track).length&&Object.entries(track).every(([key,value])=>(i.music as unknown as Record<string,unknown>)[key]===value)))
  &&!!p&&["cut","dissolve","whip"].includes(p.transition)&&["off","lowerThird","punchCard","highlightBox"].includes(p.shot_caption_style)&&typeof p.spoken_captions==="boolean"
  &&Array.isArray(p.shot_labels)&&p.shot_labels.length===i.sources.length&&p.shot_labels.every(label=>label===null||string(label,180))
  &&(p.title_card===null||!!p.title_card&&string(p.title_card.title,200)&&string(p.title_card.subtitle,300)&&string(p.title_card.watermark,100));
}

// A recipe from another release must never become an input to paid work. Only
// its scoped identifiers may be used for authenticated recovery reads/C2 discard.
export function readVideoRecovery(storage:Pick<Storage,"getItem">,scope:VideoScope):VideoRecovery {
 let raw:string|null=null;
 try{
  raw=storage.getItem(videoScopeKey(scope));
  if(raw===null)return{journal:null,unreadable:null};
  const journal=readVideoJournal({getItem:()=>raw},scope);
  if(!journal||!currentRecipe(journal))throw Error("Unsupported saved recipe");
  return{journal,unreadable:null};
 }catch{
  let reference:VideoOperationReference|null=null;
  try{
   const j=JSON.parse(raw!),input=j.input;
   if(j.schema===1&&j.actor===scope.actor&&j.org===scope.org&&j.library===scope.library&&j.listing===scope.listing&&input.listing_id===scope.listing&&input.expected_org_id===scope.library&&typeof input.operation_id==="string"&&UUID.test(input.operation_id)&&(j.job_id===undefined||typeof j.job_id==="string"&&UUID.test(j.job_id))){
    reference={input:{operation_id:input.operation_id},...(j.job_id===undefined?{}:{job_id:j.job_id})};
   }
  }catch{/* Retain the unreadable pointer and pause paid work. */}
  return{journal:null,unreadable:{raw,reference}};
 }
}

type RecoveryStorage=Pick<Storage,"getItem"|"setItem"|"removeItem">;
export async function resolveUnreadableVideo(services:Pick<StudioServices,"api"|"getSnapshot">,scope:VideoScope,request:UnreadableVideoRequest,storage:RecoveryStorage,signal?:AbortSignal,discard=false):Promise<VideoOperation>{
 assertVideoScope(services,scope,signal);
 const key=videoScopeKey(scope);
 if(!request.raw||!request.reference)throw Error("We could not match this saved video request to a video on our side. Your finished videos are below. Contact support to recover this request.");
 const checked=readVideoRecovery({getItem:()=>request.raw},scope).unreadable?.reference;
 if(!checked||checked.input.operation_id!==request.reference.input.operation_id||checked.job_id!==request.reference.job_id)throw Error("The recovery details do not match the video saved for this property. Refresh and try again.");
 if(storage.getItem(key)!==request.raw)throw Error("The saved request changed in another window. Reopen this property before recovering it.");
 const verifiedServices={getSnapshot:()=>services.getSnapshot(),api:async(path:string,options:Parameters<StudioServices['api']>[1])=>{
  const raw=await services.api(path,options) as Record<string,unknown>;
  if(!raw||raw.operation_id!==request.reference!.input.operation_id||raw.listing_id!==scope.listing||raw.selected_library_org_id!==scope.library||raw.org_id!==undefined&&raw.org_id!==scope.org)throw Error("The answer we got was not for this property's video. Your saved request is kept. Try recovering it again.");
  return raw;
 }};
 const outcome=discard?await abandonVideoOperation(verifiedServices,scope,request.reference,signal):await inspectVideoOperation(verifiedServices,scope,request.reference,signal);
 assertVideoScope(services,scope,signal);
 if(request.reference.job_id&&outcome.job?.job_id!==request.reference.job_id)throw Error("We could not confirm the saved video. Your request is kept. Try recovering it again before making another video.");
 if(!outcome.job&&!videoClosure(outcome))return outcome;
 if(storage.getItem(key)!==request.raw)throw Error("The saved request changed in another window. Reopen this property before recovering it.");
 const archive=`${key}:recovered:${request.reference.input.operation_id}`;
 const prior=storage.getItem(archive);
 if(prior!==null&&prior!==request.raw)throw Error("This video already has a different recovery saved. Your request is kept. Contact support.");
 storage.setItem(archive,request.raw);
 if(storage.getItem(archive)!==request.raw||storage.getItem(key)!==request.raw)throw Error("We could not keep a copy of your original request. Try recovering it again before making another video.");
 if(outcome.job){const review=JSON.stringify({operation_id:outcome.job.operation_id,job_id:outcome.job.job_id});storage.setItem(`${key}:recovered-job`,review);if(storage.getItem(`${key}:recovered-job`)!==review)throw Error("We could not save the recovered video for you to review. Your original request is kept. Try again.");}
 storage.removeItem(key);
 if(storage.getItem(key)!==null)throw Error("The recovered request is still active in this browser. Reopen the property before creating another video.");
 return outcome;
}
