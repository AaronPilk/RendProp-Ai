/** Closed explicit photo motion: no provider authority or AI fallback. */
import type {ComposeAction,InspectAudioAction} from '../../../supabase/functions/property-video-jobs/contracts.ts';
export const PHOTO_MODE='photo_motion_v1';
export const PHOTO_PROFILE='photo-motion-v1-cfr24';
const LEGACY_IMAGE='registry.cloudflare.com/9c332c75b96cc642621dad5d86d4bf18/rendprop-property-video-cpu@sha256:4452a0488ae786dff4e607d11e4711af5a2d59e4d6d26f168d9063db039774bc';
export interface PhotoMotionProducer {image_uri:string;controller_sha256:string;renderer_source_sha256:string}
export type PhotoMotionComposeTask=Omit<ComposeAction,'composition_profile'|'sources'> & {source_mode:typeof PHOTO_MODE;composition_profile:typeof PHOTO_PROFILE;producer_identity:PhotoMotionProducer;sources:Array<{url:string;sha256:string;bytes:number;etag:string;position:number;motion_kind:'photo_motion';motion:'push_in';visible_frames:48|72|96|120}>};
export type PhotoMotionAudioTask=InspectAudioAction&{source_mode:typeof PHOTO_MODE;composition_profile:typeof PHOTO_PROFILE;producer_identity:PhotoMotionProducer};
export type PhotoMotionTask=PhotoMotionComposeTask|PhotoMotionAudioTask;
export function photoMotionTask(value:unknown):value is PhotoMotionTask {
  const t=value as Record<string,unknown>|undefined;
  if(!t||typeof t!=='object')return false;
  const sources=t.sources as Array<Record<string,unknown>>|undefined;
  const requested='source_mode'in t||t.composition_profile===PHOTO_PROFILE||Array.isArray(sources)&&sources.some(s=>s?.motion_kind==='photo_motion');
  if(!requested)return false;
  if(t.source_mode!==PHOTO_MODE||t.composition_profile!==PHOTO_PROFILE)throw Error('photo_motion_task_refused');
  checkedPhotoMotionProducer(t.producer_identity);
  const keys=t.action==='inspect_audio'?['state','action','job_id','lease_token','manifest_sha256','source','max_duration_s','expires_at','source_mode','composition_profile','producer_identity']:['state','action','job_id','lease_token','manifest_sha256','purpose','aspect','sources','narration','music','presentation','output','expires_at','source_mode','composition_profile','producer_identity'];
  if(Object.keys(t).some(k=>!keys.includes(k)))throw Error('photo_motion_task_fields_refused');
  if(t.action==='inspect_audio'){
    const source=t.source as Record<string,unknown>|undefined;
    if(!source||Object.keys(source).sort().join(',')!=='bytes,etag,sha256,url'||!Number.isSafeInteger(source.bytes)||(source.bytes as number)<1||(source.bytes as number)>20*1024*1024||typeof source.sha256!=='string'||!/^[a-f0-9]{64}$/.test(source.sha256)||typeof source.etag!=='string'||!source.etag||source.etag.length>512||typeof source.url!=='string'||typeof t.max_duration_s!=='number'||!Number.isFinite(t.max_duration_s)||t.max_duration_s<2||t.max_duration_s>500)throw Error('photo_motion_audio_refused');
    return true;
  }
  if(t.action!=='compose'||!Array.isArray(sources)||sources.length<1||sources.length>100)throw Error('photo_motion_task_refused');
  const p=t.presentation as Record<string,unknown>|undefined;
  if(!p||p.transition!=='cut')throw Error('photo_motion_requires_cut');
  for(const [position,s]of sources.entries()){
    if(!s||Object.keys(s).sort().join(',')!=='bytes,etag,motion,motion_kind,position,sha256,url,visible_frames'||s.position!==position||s.motion_kind!=='photo_motion'||s.motion!=='push_in'||![48,72,96,120].includes(s.visible_frames as number)||!Number.isSafeInteger(s.visible_frames)||!Number.isSafeInteger(s.bytes)||(s.bytes as number)<1||(s.bytes as number)>50*1024*1024||typeof s.etag!=='string'||!s.etag||s.etag.length>512||typeof s.sha256!=='string'||!/^[a-f0-9]{64}$/.test(s.sha256)||typeof s.url!=='string')throw Error('photo_motion_source_refused');
  }
  return true;
}
export function photoMotionImage(actual:unknown,marker:unknown):string {
  if(typeof actual!=='string'||actual!==marker||actual===LEGACY_IMAGE||!/^registry\.cloudflare\.com\/9c332c75b96cc642621dad5d86d4bf18\/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$/.test(actual))throw Error('photo_motion_image_refused');
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
  if(task.action==='inspect_audio'){
    samePhotoMotionProducer(result.producer_identity,task.producer_identity);
    const keys=['job_id','lease_token','manifest_sha256','source_sha256','duration_s','audio_streams','source_mode','composition_profile','producer_identity',...(withWall?['processing_wall_ms']:[])];
    if(Object.keys(result).sort().join(',')!==keys.sort().join(',')||result.job_id!==task.job_id||result.lease_token!==task.lease_token||result.manifest_sha256!==task.manifest_sha256||result.source_sha256!==task.source.sha256||result.audio_streams!==1||result.source_mode!==PHOTO_MODE||result.composition_profile!==PHOTO_PROFILE||typeof result.duration_s!=='number'||!Number.isFinite(result.duration_s)||result.duration_s<=0||result.duration_s>3600||withWall&&result.processing_wall_ms!==null&&(!Number.isSafeInteger(result.processing_wall_ms)||(result.processing_wall_ms as number)<0||(result.processing_wall_ms as number)>21*60_000))throw Error('photo_motion_audio_receipt_refused');
    return;
  }
  const frames=task.sources.map(s=>s.visible_frames),sum=frames.reduce((a,b)=>a+b,0);
  samePhotoMotionProducer(result.producer_identity,task.producer_identity);
  const width=task.aspect==='16:9'?1920:1080,height=task.aspect==='16:9'?1080:1920;
  const keys=['job_id','lease_token','manifest_sha256','asset_id','poster_asset_id','width','height','duration_s','fps','bytes','sha256','poster_bytes','poster_sha256','source_mode','composition_profile','total_frames','source_frames','source_sha256s','producer_identity',...(withWall?['processing_wall_ms']:[])];
  if(Object.keys(result).sort().join(',')!==keys.sort().join(',')||withWall&&result.processing_wall_ms!==null&&(!Number.isSafeInteger(result.processing_wall_ms)||(result.processing_wall_ms as number)<0||(result.processing_wall_ms as number)>21*60_000))throw Error('photo_motion_receipt_refused');
  if(!Number.isSafeInteger(result.bytes)||(result.bytes as number)<1||!Number.isSafeInteger(result.poster_bytes)||(result.poster_bytes as number)<1||typeof result.sha256!=='string'||!/^[a-f0-9]{64}$/.test(result.sha256)||typeof result.poster_sha256!=='string'||!/^[a-f0-9]{64}$/.test(result.poster_sha256))throw Error('photo_motion_output_refused');
  if(result.job_id!==task.job_id||result.lease_token!==task.lease_token||result.manifest_sha256!==task.manifest_sha256||result.asset_id!==task.output.asset_id||result.poster_asset_id!==task.output.poster_asset_id||result.source_mode!==PHOTO_MODE||result.composition_profile!==PHOTO_PROFILE||result.fps!==24||result.width!==width||result.height!==height||result.total_frames!==sum||result.duration_s!==sum/24||JSON.stringify(result.source_frames)!==JSON.stringify(frames)||JSON.stringify(result.source_sha256s)!==JSON.stringify(task.sources.map(s=>s.sha256)))throw Error('photo_motion_receipt_refused');
}
/** Conservative controller-observed alive window, never an invoice claim. */
export function photoMotionWall(startedAt:unknown,stopped:boolean,now:number):{processing_wall_ms:number|null} {
  return {processing_wall_ms:stopped&&typeof startedAt==='number'&&Number.isSafeInteger(startedAt)&&startedAt>0&&Number.isSafeInteger(now)&&now>=startedAt&&now-startedAt<=21*60_000?Math.ceil((now-startedAt)/10)*10:null};
}

/** Replay only a completed durable V1 receipt. This module grants no execution. */
export const V1_PRODUCER={image_uri:'registry.cloudflare.com/9c332c75b96cc642621dad5d86d4bf18/rendprop-property-video-photo-motion@sha256:990d6560303611ec28c323a3ce7d73da331d54f9b992530cd66fa450622e721e',controller_sha256:'4d23ec9494a6d80735b889577acee58c200cae57134fbedc9c87801f281a8e98',renderer_source_sha256:'b9837c98b1095e96242d94d33bd142bacc203f5ee3d631668b27fbada4bdcbf8'};
export function isV1PhotoMotionTask(value:unknown):boolean {const t=value as Record<string,unknown>|undefined;return !!t&&t.source_mode===PHOTO_MODE&&t.composition_profile===PHOTO_PROFILE;}
export function checkedV1PhotoMotionCallback(task:unknown,callback:{path:string;body:Record<string,unknown>},storedImage:unknown,storedProducer:unknown):void {
 if(!isV1PhotoMotionTask(task)||!photoMotionTask(task)||!['finish','audio-preflight'].includes(callback.path)||storedImage!==V1_PRODUCER.image_uri)throw Error('legacy_photo_callback_refused');
 if(callback.path!==(task.action==='inspect_audio'?'audio-preflight':'finish'))throw Error('legacy_photo_callback_phase_refused');
 samePhotoMotionProducer(storedProducer,V1_PRODUCER);
 samePhotoMotionProducer(task.producer_identity,V1_PRODUCER);
 checkedPhotoMotionResult(callback.body,task,true);
}
