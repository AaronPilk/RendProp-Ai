import {assert,throwRpc}from'./http.ts';
import{KIE_PROPERTY_PROFILE}from'./property-video-kie.ts';
export const GENERIC_MEDIA_BYTES=256*1024*1024,REGISTERED_BACKGROUND_BYTES=1536*1024*1024;
/** Saved native-CFR24 steady profiles whose ready master receipt names its profile. */
export type BackgroundSteadyProfile='fal-kling3-4k-steady-v2'|typeof KIE_PROPERTY_PROFILE;
const STEADY_PROFILES:readonly BackgroundSteadyProfile[]=['fal-kling3-4k-steady-v2',KIE_PROPERTY_PROFILE];
export interface BackgroundObjectLimit{kind:'registered_background_video';asset_id:string;bytes:number;sha256:string;max_object_bytes:number;quality_profile?:BackgroundSteadyProfile}
/** Key shape is only a query optimization. Ready immutable SQL output/source
 * authority, never this path hint or an R2 HEAD, grants the larger limit. */
export async function backgroundObjectLimits(admin:any,scope:{orgId:string;listingId:string;actorId?:string},objects:Record<string,'uploads'|'renders'>,bytes=0,readKey?:string):Promise<Record<string,BackgroundObjectLimit>>{
 assert(Number.isSafeInteger(bytes)&&bytes>=0&&bytes<=REGISTERED_BACKGROUND_BYTES,400,'Use bounded media delivery.');
 if(bytes>GENERIC_MEDIA_BYTES)assert(typeof readKey==='string'&&objects[readKey]==='renders',403,'Use the exact registered background master.');
 const limits:Record<string,BackgroundObjectLimit>=Object.create(null);
 for(const[key,which]of Object.entries(objects)){
  if(which!=='renders'||!key.includes('/background/'))continue;
  const{data,error}=await admin.rpc('background_video_delivery',{p_actor:scope.actorId??null,p_org:scope.orgId,p_listing:scope.listingId,p_key:key,p_bytes:bytes>GENERIC_MEDIA_BYTES&&key===readKey?bytes:0});
  if(error)throwRpc(error.message);if(data===null)continue;
  const keys=data&&Object.keys(data).sort().join(',');
  const shape=keys==='asset_id,bytes,kind,max_object_bytes,sha256'||keys==='asset_id,bytes,kind,max_object_bytes,quality_profile,sha256'&&STEADY_PROFILES.includes(data.quality_profile);
  assert(data&&shape&&data.kind==='registered_background_video'&&typeof data.asset_id==='string'&&/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(data.asset_id)&&Number.isSafeInteger(data.bytes)&&data.bytes>0&&data.bytes<=REGISTERED_BACKGROUND_BYTES&&typeof data.sha256==='string'&&/^[a-f0-9]{64}$/.test(data.sha256)&&data.max_object_bytes===REGISTERED_BACKGROUND_BYTES,503,'Registered background-video authority could not be verified.');limits[key]=data;
 }
 if(bytes>GENERIC_MEDIA_BYTES)assert(!!readKey&&!!limits[readKey]&&bytes<=limits[readKey].bytes,403,'Large delivery needs its exact registered background receipt.');
 return limits;
}
