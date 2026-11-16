import{aerialProcessingTask,checkedAerialProcessingResult,type AerialProcessingTask}from'./aerial-processing';
/** Closed explicit photo motion: no provider authority or AI fallback. */
import type {ComposeAction,InspectAudioAction} from '../../../supabase/functions/property-video-jobs/contracts.ts';
import {AERIAL_OPENING_PROFILE,aerialOpeningTask,sameAerialOpening,type AerialOpeningTask} from '../../../supabase/functions/_shared/aerial-opening-contract.ts';
export const PHOTO_MODE='photo_motion_v1';
export const PHOTO_PROFILE='photo-motion-v2-cfr24';
export interface PhotoMotionProducer {image_uri:string;controller_sha256:string;renderer_source_sha256:string}
export type PhotoMotionComposeTask=Omit<ComposeAction,'composition_profile'|'sources'> & {source_mode:typeof PHOTO_MODE;composition_profile:typeof PHOTO_PROFILE|typeof AERIAL_OPENING_PROFILE;opening?:AerialOpeningTask;producer_identity:PhotoMotionProducer;sources:Array<{url:string;sha256:string;bytes:number;etag:string;position:number;motion_kind:'photo_motion';motion:'push_in'|'pull_back'|'slide_left'|'slide_right';visible_frames:48|72|96|120}>};
export type PhotoMotionAudioTask=Omit<InspectAudioAction,'composition_profile'|'source_mode'|'producer_identity'>&{source_mode:typeof PHOTO_MODE;composition_profile:typeof PHOTO_PROFILE|typeof AERIAL_OPENING_PROFILE;producer_identity:PhotoMotionProducer};
export type PhotoMotionTask=PhotoMotionComposeTask|PhotoMotionAudioTask|AerialProcessingTask;
export function photoMotionTask(value:unknown):value is PhotoMotionTask {
  const t=value as Record<string,unknown>|undefined;
  if(!t||typeof t!=='object')return false;
  if(aerialProcessingTask(t)){checkedPhotoMotionProducer(t.producer_identity);return true;}
  const sources=t.sources as Array<Record<string,unknown>>|undefined;
  const requested='source_mode'in t||t.composition_profile===PHOTO_PROFILE||Array.isArray(sources)&&sources.some(s=>s?.motion_kind==='photo_motion');
  if(!requested)return false;
  if(t.source_mode!==PHOTO_MODE||![PHOTO_PROFILE,AERIAL_OPENING_PROFILE].includes(t.composition_profile as string))throw Error('photo_motion_task_refused');
  checkedPhotoMotionProducer(t.producer_identity);
  const keys=t.action==='inspect_audio'?['state','action','job_id','lease_token','manifest_sha256','source','max_duration_s','expires_at','source_mode','composition_profile','producer_identity']:['state','action','job_id','lease_token','manifest_sha256','purpose','aspect','sources','narration','music','presentation','output','expires_at','source_mode','composition_profile','producer_identity',...(t.composition_profile===AERIAL_OPENING_PROFILE?['opening']:[])];
  if(Object.keys(t).some(k=>!keys.includes(k)))throw Error('photo_motion_task_fields_refused');
  if(t.action==='inspect_audio'){
    const source=t.source as Record<string,unknown>|undefined;
    if(!source||Object.keys(source).sort().join(',')!=='bytes,etag,sha256,url'||!Number.isSafeInteger(source.bytes)||(source.bytes as number)<1||(source.bytes as number)>20*1024*1024||typeof source.sha256!=='string'||!/^[a-f0-9]{64}$/.test(source.sha256)||typeof source.etag!=='string'||!source.etag||source.etag.length>512||typeof source.url!=='string'||typeof t.max_duration_s!=='number'||!Number.isFinite(t.max_duration_s)||t.max_duration_s<(t.composition_profile===AERIAL_OPENING_PROFILE?7:2)||t.max_duration_s>(t.composition_profile===AERIAL_OPENING_PROFILE?508:500))throw Error('photo_motion_audio_refused');
    return true;
  }
  if(t.action!=='compose'||!Array.isArray(sources)||sources.length<1||sources.length>100)throw Error('photo_motion_task_refused');
  if(t.composition_profile===AERIAL_OPENING_PROFILE)aerialOpeningTask(t.opening,t.aspect as '16:9'|'9:16');
  const p=t.presentation as Record<string,unknown>|undefined;
  if(!p||p.transition!=='cut')throw Error('photo_motion_requires_cut');
  for(const [position,s]of sources.entries()){
    if(!s||Object.keys(s).sort().join(',')!=='bytes,etag,motion,motion_kind,position,sha256,url,visible_frames'||s.position!==position||s.motion_kind!=='photo_motion'||!['push_in','pull_back','slide_left','slide_right'].includes(s.motion as string)||![48,72,96,120].includes(s.visible_frames as number)||!Number.isSafeInteger(s.visible_frames)||!Number.isSafeInteger(s.bytes)||(s.bytes as number)<1||(s.bytes as number)>50*1024*1024||typeof s.etag!=='string'||!s.etag||s.etag.length>512||typeof s.sha256!=='string'||!/^[a-f0-9]{64}$/.test(s.sha256)||typeof s.url!=='string')throw Error('photo_motion_source_refused');
  }
  return true;
}
export function photoMotionImage(actual:unknown,marker:unknown):string {
  if(typeof actual!=='string'||actual!==marker||!/^registry\.cloudflare\.com\/9c332c75b96cc642621dad5d86d4bf18\/rendprop-property-video-photo-motion@sha256:[a-f0-9]{64}$/.test(actual))throw Error('photo_motion_image_refused');
  return actual;
}
export function checkedPhotoMotionProducer(value:unknown):PhotoMotionProducer {
  const p=value as PhotoMotionProducer|undefined;
  if(!p||typeof p!=='object'||Object.keys(p).sort().join(',')!=='controller_sha256,image_uri,renderer_source_sha256'||typeof p.image_uri!=='string'||p.image_uri.length>512||photoMotionImage(p.image_uri,p.image_uri)!==p.image_uri||typeof p.controller_sha256!=='string'||!/^[a-f0-9]{64}$/.test(p.controller_sha256)||typeof p.renderer_source_sha256!=='string'||!/^[a-f0-9]{64}$/.test(p.renderer_source_sha256))throw Error('photo_motion_producer_refused');
  return{image_uri:p.image_uri,controller_sha256:p.controller_sha256,renderer_source_sha256:p.renderer_source_sha256};
}
export function samePhotoMotionProducer(value:unknown,expected:PhotoMotionProducer):void {
  const p=checkedPhotoMotionProducer(value);if(p.image_uri!==expected.image_uri||p.controller_sha256!==expected.controller_sha256||p.renderer_source_sha256!==expected.renderer_source_sha256)throw Error('photo_motion_producer_refused');
}
export function photoMotionProducer(actual:unknown,image:unknown,controller:unknown,renderer:unknown):PhotoMotionProducer {
  return checkedPhotoMotionProducer({image_uri:photoMotionImage(actual,image),controller_sha256:controller,renderer_source_sha256:renderer});
}
export function checkedPhotoMotionResult(result:Record<string,unknown>,task:PhotoMotionTask,withWall=false):void {
  if(aerialProcessingTask(task)){samePhotoMotionProducer(result.producer_identity,task.producer_identity);checkedAerialProcessingResult(result,task,withWall);return;}
  if(task.action==='inspect_audio'){
    samePhotoMotionProducer(result.producer_identity,task.producer_identity);
    const keys=['job_id','lease_token','manifest_sha256','source_sha256','duration_s','audio_streams','source_mode','composition_profile','producer_identity',...(withWall?['processing_wall_ms']:[])];
    if(Object.keys(result).sort().join(',')!==keys.sort().join(',')||result.job_id!==task.job_id||result.lease_token!==task.lease_token||result.manifest_sha256!==task.manifest_sha256||result.source_sha256!==task.source.sha256||result.audio_streams!==1||result.source_mode!==PHOTO_MODE||result.composition_profile!==task.composition_profile||typeof result.duration_s!=='number'||!Number.isFinite(result.duration_s)||result.duration_s<=0||result.duration_s>3600||withWall&&result.processing_wall_ms!==null&&(!Number.isSafeInteger(result.processing_wall_ms)||(result.processing_wall_ms as number)<0||(result.processing_wall_ms as number)>21*60_000))throw Error('photo_motion_audio_receipt_refused');
    return;
  }
  const frames=task.sources.map(s=>s.visible_frames),sum=frames.reduce((a,b)=>a+b,0)+(task.composition_profile===AERIAL_OPENING_PROFILE?task.opening!.receipt.visible_frames:0);
  samePhotoMotionProducer(result.producer_identity,task.producer_identity);
  const width=task.aspect==='16:9'?1920:1080,height=task.aspect==='16:9'?1080:1920;
  const keys=['job_id','lease_token','manifest_sha256','asset_id','poster_asset_id','width','height','duration_s','fps','bytes','sha256','poster_bytes','poster_sha256','source_mode','composition_profile','total_frames','source_frames','source_sha256s','source_motions','producer_identity',...(task.composition_profile===AERIAL_OPENING_PROFILE?['opening']:[]),...(withWall?['processing_wall_ms']:[])];
  if(Object.keys(result).sort().join(',')!==keys.sort().join(',')||withWall&&result.processing_wall_ms!==null&&(!Number.isSafeInteger(result.processing_wall_ms)||(result.processing_wall_ms as number)<0||(result.processing_wall_ms as number)>21*60_000))throw Error('photo_motion_receipt_refused');
  if(task.composition_profile===AERIAL_OPENING_PROFILE&&!sameAerialOpening(result.opening,task.opening!.receipt))throw Error('aerial_opening_receipt_changed');
  if(!Number.isSafeInteger(result.bytes)||(result.bytes as number)<1||!Number.isSafeInteger(result.poster_bytes)||(result.poster_bytes as number)<1||typeof result.sha256!=='string'||!/^[a-f0-9]{64}$/.test(result.sha256)||typeof result.poster_sha256!=='string'||!/^[a-f0-9]{64}$/.test(result.poster_sha256))throw Error('photo_motion_output_refused');
  if(result.job_id!==task.job_id||result.lease_token!==task.lease_token||result.manifest_sha256!==task.manifest_sha256||result.asset_id!==task.output.asset_id||result.poster_asset_id!==task.output.poster_asset_id||result.source_mode!==PHOTO_MODE||result.composition_profile!==task.composition_profile||result.fps!==24||result.width!==width||result.height!==height||result.total_frames!==sum||result.duration_s!==sum/24||JSON.stringify(result.source_frames)!==JSON.stringify(frames)||JSON.stringify(result.source_sha256s)!==JSON.stringify(task.sources.map(s=>s.sha256))||JSON.stringify(result.source_motions)!==JSON.stringify(task.sources.map(s=>s.motion)))throw Error('photo_motion_receipt_refused');
}
/** Conservative controller-observed alive window, never an invoice claim. */
export function photoMotionWall(startedAt:unknown,stopped:boolean,now:number):{processing_wall_ms:number|null} {
  return {processing_wall_ms:stopped&&typeof startedAt==='number'&&Number.isSafeInteger(startedAt)&&startedAt>0&&Number.isSafeInteger(now)&&now>=startedAt&&now-startedAt<=21*60_000?Math.ceil((now-startedAt)/10)*10:null};
}

export function photoMotionCallbackPath(task:PhotoMotionTask):'prepared-finish'|'audio-preflight'|'finish'{return task.action==='prepare_image'?'prepared-finish':task.action==='inspect_audio'?'audio-preflight':'finish';}
