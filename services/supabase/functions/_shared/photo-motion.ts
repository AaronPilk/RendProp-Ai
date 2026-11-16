import{AERIAL_OPENING_PROFILE,aerialOpeningReference,aerialOpeningReceipt,sameAerialOpening,type AerialOpeningReceipt}from'./aerial-opening-contract.ts';
/** Explicit deterministic photo render. No supplier/prompt/quality fallback authority. */
export const PHOTO_MOTION_MODE='photo_motion_v1' as const;
export const PHOTO_MOTION_PROFILE='photo-motion-v1-cfr24' as const;
export const PHOTO_MOTION_PROFILE_V2='photo-motion-v2-cfr24' as const;
export type PhotoMotionProfile=typeof PHOTO_MOTION_PROFILE|typeof PHOTO_MOTION_PROFILE_V2|typeof AERIAL_OPENING_PROFILE;
export function photoMotionProfile(manifest:any):PhotoMotionProfile {
 if(!manifest||manifest.source_mode!==PHOTO_MOTION_MODE)throw Error('Invalid explicit Photo Motion mode');
 if(!Object.hasOwn(manifest,'composition_profile'))return PHOTO_MOTION_PROFILE;
 if(manifest.composition_profile!==PHOTO_MOTION_PROFILE&&manifest.composition_profile!==PHOTO_MOTION_PROFILE_V2&&manifest.composition_profile!==AERIAL_OPENING_PROFILE)throw Error('Invalid explicit Photo Motion profile');
 return manifest.composition_profile;
}
export const PHOTO_MOTION_REVISION='photo-motion-v1' as const;
export const PHOTO_MOTION_MOVES=['push_in','pull_back','slide_left','slide_right'] as const;
export const PHOTO_MOTION_FRAMES=[48,72,96,120] as const;
export const PHOTO_MOTION_RATE_EVIDENCE='8b8db0d3d1925f1ce48a96a944bba5c66b4e0a3d8561ebba9c9c3add8460588a';
export const isPhotoMotion=(j:any)=>{if(j?.manifest?.source_mode!==PHOTO_MOTION_MODE)return false;try{return j.quality_profile===photoMotionProfile(j.manifest);}catch{return false;}};
export function photoMotionTimeline(j:any){
 if(!isPhotoMotion(j)||!Array.isArray(j.manifest.sources)||j.manifest.sources.length<1||j.manifest.sources.length>100||j.manifest.presentation?.transition!=='cut')throw Error('Invalid explicit Photo Motion timeline');
 const frames=j.manifest.sources.map((s:any)=>{if(!(photoMotionProfile(j.manifest)===PHOTO_MOTION_PROFILE?s.motion==='push_in':PHOTO_MOTION_MOVES.includes(s.motion))||!PHOTO_MOTION_FRAMES.includes(s.visible_frames)||typeof s.source_sha256!=='string'||!/^[a-f0-9]{64}$/.test(s.source_sha256)||!Number.isSafeInteger(s.source_bytes)||s.source_bytes<1||s.source_bytes>52428800)throw Error('Invalid explicit Photo Motion source');return s.visible_frames as number;});
 const opening=photoMotionProfile(j.manifest)===AERIAL_OPENING_PROFILE?aerialOpeningReference(j.manifest.opening):null;
 return{source_frames:frames,total_frames:frames.reduce((a:number,b:number)=>a+b,0)+(opening?.visible_frames??0),fps:24 as const,...(photoMotionProfile(j.manifest)!==PHOTO_MOTION_PROFILE?{source_motions:j.manifest.sources.map((s:any)=>s.motion)}:{})};
}

export type PhotoMotionProducer={image_uri:string;controller_sha256:string;renderer_source_sha256:string};
export function photoMotionProducer(j:any):PhotoMotionProducer{
 const p=j?.quality_identity?.producer_identity;
 if(!isPhotoMotion(j)||!p||typeof p!=='object'||Array.isArray(p)||Object.keys(p).sort().join(',')!=='controller_sha256,image_uri,renderer_source_sha256'||
  typeof p.image_uri!=='string'||!/^registry\.cloudflare\.com\/[a-f0-9]{32}\/[a-z0-9][a-z0-9._/-]{0,180}@sha256:[a-f0-9]{64}$/.test(p.image_uri)||
  !/^[a-f0-9]{64}$/.test(p.controller_sha256)||!/^[a-f0-9]{64}$/.test(p.renderer_source_sha256))throw Error('Photo Motion verified producer is unavailable');
 return{image_uri:p.image_uri,controller_sha256:p.controller_sha256,renderer_source_sha256:p.renderer_source_sha256};
}
/** Unknown clock stays null, retaining the full admitted liability bound. */
export function photoMotionObservation(j:any,b:any,phase:'inspect_audio'|'compose',outcome:'completed'|'failed'){
 const p=photoMotionProducer(j),got=b.producer_identity;
 const exact=got&&typeof got==='object'&&!Array.isArray(got)&&Object.keys(got).sort().join(',')===Object.keys(p).sort().join(',')&&Object.keys(p).every(k=>got[k]===p[k as keyof PhotoMotionProducer]);
 if(b.source_mode!==PHOTO_MOTION_MODE||b.composition_profile!==photoMotionProfile(j.manifest)||b.manifest_sha256!==j.manifest_sha256||!Object.hasOwn(b,'processing_wall_ms')||
  (!exact&&!(outcome==='failed'&&got===null&&b.processing_wall_ms===null)))throw Error('Use the exact Photo Motion producer and processing observation');
 const wall=Number.isSafeInteger(b.processing_wall_ms)&&b.processing_wall_ms>=0&&b.processing_wall_ms<=1260000&&b.processing_wall_ms%10===0?b.processing_wall_ms:null;
 return{p_job:j.id,p_lease:b.lease_token,p_manifest:j.manifest_sha256,p_phase:phase,p_outcome:outcome,p_wall_ms:wall,p_producer:exact?p:null};
}

export function photoMotionFinishFacts(j:any,b:any){
 photoMotionObservation(j,b,'compose','completed');const t=photoMotionTimeline(j);
 if(photoMotionProfile(j.manifest)===AERIAL_OPENING_PROFILE){const o=aerialOpeningReceipt(b.opening,j.manifest.aspect);const ref=aerialOpeningReference(Object.fromEntries(['aerial_job_id','asset_id','provenance_id','sha256','bytes','visible_frames','source'].map(k=>[k,(o as any)[k]])));if(!sameAerialOpening(ref,j.manifest.opening)||o.scope.actor_id!==j.actor_id||o.scope.org_id!==j.org_id||o.scope.selected_library_org_id!==j.library_org_id||o.scope.listing_id!==j.listing_id)throw Error('The accepted aerial opening or current video scope changed');}else if(Object.hasOwn(b,'opening'))throw Error('The saved Photo motion result has an unsupported opening');
 if((photoMotionProfile(j.manifest)!==PHOTO_MOTION_PROFILE&&JSON.stringify(b.source_motions)!==JSON.stringify(t.source_motions))||b.fps!==24||b.total_frames!==t.total_frames||JSON.stringify(b.source_frames)!==JSON.stringify(t.source_frames)||
  JSON.stringify(b.source_sha256s)!==JSON.stringify(j.manifest.sources.map((s:any)=>s.source_sha256)))throw Error('The exact Photo Motion output timeline changed');
 return t;
}
