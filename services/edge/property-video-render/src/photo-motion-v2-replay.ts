/** Exact historical terminal receipts only. No boot, execute or producer relabel. */
import{photoMotionTask,checkedPhotoMotionResult,samePhotoMotionProducer,PHOTO_PROFILE}from'./photo-motion';
const image='registry.cloudflare.com/9c332c75b96cc642621dad5d86d4bf18/rendprop-property-video-photo-motion@sha256:f8bf65d52390bdd4470c36638b141251ec9fe924aa30bb7218fdbcba09a809ec';
const renderer='a98b48825fbd819dbf49fd4c2cca4b836cdd81d57bedda5bf2de7774a42d98be';
export const HISTORICAL_V2_PRODUCERS=['604b92b2c8b6a3ccfd49ac6bec6ff81993e52062c71ba6f910f057d1e2cb3db6','c36d9aba8975401865aacb6c58ad4026c9eff810050957435a53e55035705e64'].map(controller_sha256=>({image_uri:image,controller_sha256,renderer_source_sha256:renderer}));
export function isHistoricalV2PhotoMotionTask(task:unknown):boolean{
 const t=task as Record<string,unknown>|null;if(!t||t.source_mode!=='photo_motion_v1'||t.composition_profile!==PHOTO_PROFILE)return false;
 return HISTORICAL_V2_PRODUCERS.some(p=>{try{samePhotoMotionProducer(t.producer_identity,p);return true;}catch{return false;}});
}
export function checkedHistoricalV2Callback(task:unknown,callback:{path:string;body:Record<string,unknown>},storedImage:unknown,storedProducer:unknown):void{
 if(!isHistoricalV2PhotoMotionTask(task)||!photoMotionTask(task)||task.composition_profile!==PHOTO_PROFILE||!['finish','audio-preflight'].includes(callback.path))throw Error('historical_v2_callback_refused');
 const p=HISTORICAL_V2_PRODUCERS.find(p=>{try{samePhotoMotionProducer(task.producer_identity,p);return true;}catch{return false;}})!;
 samePhotoMotionProducer(storedProducer,p);samePhotoMotionProducer(callback.body.producer_identity,p);
 if(storedImage!==p.image_uri||callback.path!==(task.action==='inspect_audio'?'audio-preflight':'finish'))throw Error('historical_v2_callback_phase_refused');
 checkedPhotoMotionResult(callback.body,task,true);
}
