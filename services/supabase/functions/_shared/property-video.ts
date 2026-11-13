import { assert,HttpError,throwRpc } from './http.ts';
import { driftLineageKey } from './drift.ts';
import { probeComposedMP4Video,probeMP4Video } from '../ai-video/mp4video.ts';
import { KIE_PROPERTY_PROFILE } from './property-video-kie.ts';
const PHOTO_MODE='photo_motion_v1';
const PHOTO_PROFILES=['photo-motion-v1-cfr24','photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24'] as const;
const PHOTO_MOVES=['push_in','pull_back','slide_left','slide_right'];
const HEX=/^[a-f0-9]{64}$/;
const UUID=/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
/** Registered Photo motion, FAL steady-v2 and Kie native 4K masters compose at native 24 fps CFR. */
const CFR24_MASTER_PROFILES:readonly unknown[]=[...PHOTO_PROFILES,'fal-kling3-4k-steady-v2',KIE_PROPERTY_PROFILE];
/** The exact owned object whose bytes were verified; never returned to a client. */
export type PropertySourceLocation={bucket:'uploads'|'renders';storage_key:string;etag:string;bytes:number;content_type:string};
type Rpc=(name:string,args:Record<string,unknown>)=>PromiseLike<{data:unknown;error:{message:string}|null}>;
type Head={exists:boolean;bytes:number|null;etag:string|null;contentType:string|null};
export type PropertyVideoDeps={rpc:Rpc;head:(bucket:string,key:string,signal:AbortSignal)=>Promise<Head>;
 sign:(bucket:string,key:string,seconds:number)=>Promise<string>;fetch:typeof fetch};
type Owned={actor_id:string;org_id:string;listing_id:string;asset_id:string;bucket:string;storage_key:string;bytes:number;etag:string;content_type:string;sha256:string|null};
async function owned(actor:string,listing:string,asset:string,kind:'photo'|'video',deps:PropertyVideoDeps):Promise<Owned>{
 const {data,error}=await deps.rpc('property_owned_upload',{p_actor:actor,p_listing:listing,p_asset:asset,p_kind:kind});if(error)throwRpc(error.message);
 const c=data as Owned|null;
 assert(c&&c.actor_id===actor&&c.listing_id===listing&&c.asset_id===asset&&UUID.test(c.org_id)&&['uploads','renders'].includes(c.bucket)
  &&Number.isSafeInteger(c.bytes)&&c.bytes>0&&c.bytes<=1073741824&&typeof c.etag==='string'&&c.etag.length>0
  &&c.storage_key.startsWith(`${c.bucket}/${c.org_id}/${listing}/`)&&!c.storage_key.includes('..'),503,'The owned upload could not be verified.');
 return c;
}
function same(h:Head,c:Owned){return h.exists&&h.bytes===c.bytes&&h.etag===c.etag&&h.contentType?.split(';')[0].trim().toLowerCase()===c.content_type.split(';')[0].trim().toLowerCase();}
export function propertyVideoManifest(value:unknown){
 assert(value!==null&&typeof value==='object'&&!Array.isArray(value),400,'Choose a finished listing video with its saved source receipts.');
 const m=value as Record<string,unknown>;assert(m.schema===1&&m.purpose==='listing'&&m.aspect==='16:9'&&m.branding_policy==='unbranded'&&Array.isArray(m.sources)
  &&m.sources.length>=1&&m.sources.length<=100&&new TextEncoder().encode(JSON.stringify(m)).byteLength<=100000,400,'Choose a landscape listing video with up to100 sources.');
 const photo=Object.hasOwn(m,'source_mode')||Object.hasOwn(m,'composition_profile')||m.sources.some((s:unknown)=>s!==null&&typeof s==='object'&&!Array.isArray(s)&&(s as Record<string,unknown>).motion_kind==='photo_motion');
 if(photo){
  assert(m.source_mode===PHOTO_MODE&&PHOTO_PROFILES.includes(m.composition_profile as typeof PHOTO_PROFILES[number])&&m.fps===24&&Number.isSafeInteger(m.total_frames),400,'Keep the saved Photo motion mode, profile and exact timeline.');
  let frames=0;for(const item of m.sources){const s=item as Record<string,unknown>;
   assert(s&&typeof s==='object'&&!Array.isArray(s)&&s.motion_kind==='photo_motion'&&s.source_bound===true&&(s.generation_request_id===undefined||s.generation_request_id===null)&&(s.generation_provenance_id===undefined||s.generation_provenance_id===null)
    &&typeof s.photo_asset_id==='string'&&UUID.test(s.photo_asset_id)&&s.photo_version_id==='asset:'+s.photo_asset_id
    &&typeof s.source_sha256==='string'&&HEX.test(s.source_sha256)&&Number.isSafeInteger(s.source_bytes)&&Number(s.source_bytes)>=1&&Number(s.source_bytes)<=52428800
    &&[48,72,96,120].includes(Number(s.visible_frames))&&Number.isSafeInteger(s.visible_frames)
    &&(m.composition_profile==='photo-motion-v1-cfr24'?(s.motion===undefined||s.motion==='push_in'):PHOTO_MOVES.includes(String(s.motion))),400,'Keep exact saved Photo motion masters, timing and ungenerated source receipts.');
   assert(s.photo_provenance_id===undefined||s.photo_provenance_id===null||typeof s.photo_provenance_id==='string'&&UUID.test(s.photo_provenance_id),400,'Keep the saved photo disclosure.');frames+=Number(s.visible_frames);
  }
  assert(new Set(m.sources.map((s:Record<string,unknown>)=>s.photo_asset_id)).size===m.sources.length,400,'Keep each saved Photo motion master once.');
  if(m.composition_profile==='photo-motion-v2-opening-cfr24'){
   const o=m.opening as Record<string,unknown>;assert(o&&typeof o==='object'&&!Array.isArray(o)&&o.kind==='aerial_opening'&&o.position===0&&o.aspect===m.aspect&&o.fps===24
    &&[120,121,144,192].includes(Number(o.visible_frames))&&o.available_frames===o.visible_frames,400,'Keep the exact accepted full opening receipt.');frames+=Number(o.visible_frames);
  }else assert(!Object.hasOwn(m,'opening'),400,'An opening requires its saved composition profile.');
  assert(m.total_frames===frames,400,'Keep the full saved Photo motion timeline.');return m;
 }
 for(const item of m.sources){assert(item!==null&&typeof item==='object'&&!Array.isArray(item),400,'Saved video source is invalid.');
  const s=item as Record<string,unknown>;assert(typeof s.photo_asset_id==='string'&&UUID.test(s.photo_asset_id)&&typeof s.photo_version_id==='string'
   &&s.photo_version_id.length>=1&&s.photo_version_id.length<=200&&['ai','original_photo'].includes(String(s.motion_kind)),400,'Saved video source is incomplete.');
  for(const k of ['photo_provenance_id','generation_provenance_id'])assert(s[k]===undefined||s[k]===null||typeof s[k]==='string'&&UUID.test(s[k] as string),400,'Saved source provenance is invalid.');
  assert(s.generation_request_id===undefined||s.generation_request_id===null||typeof s.generation_request_id==='string'&&s.generation_request_id.length>0&&s.generation_request_id.length<=256,400,'Saved generated-clip identity is invalid.');
  if(s.motion_kind==='ai')assert(typeof s.generation_request_id==='string'&&typeof s.generation_provenance_id==='string',409,'This AI clip has no verified generation receipt.');
 }
 return m;
}
/** Exact private input bytes are compared before any paid provider dispatch.
 * A client SHA or source-provenance UUID alone never proves an uploaded file. */
export async function verifyPropertyVideoInput(actor:string,listing:string,asset:string,base64:string,photoProvenance:string|null,deps:PropertyVideoDeps){
 try{
 const c=await owned(actor,listing,asset,'photo',deps);assert(c.bytes<=8*1024*1024,413,'The prepared video source exceeds8MB.');
 const reference=await deps.rpc('property_photo_reference',{p_actor:actor,p_listing:listing,p_asset:asset,p_provenance:photoProvenance});if(reference.error)throwRpc(reference.error.message);
 const expected=Uint8Array.from(atob(base64),x=>x.charCodeAt(0));
 const hex=(data:Uint8Array)=>crypto.subtle.digest('SHA-256',new Uint8Array(data)).then(x=>Array.from(new Uint8Array(x),b=>b.toString(16).padStart(2,'0')).join(''));
 const digest=await hex(expected);assert(expected.length===c.bytes&&digest===c.sha256,409,'The saved video source does not match the selected photo.');
 const signal=AbortSignal.timeout(15000);assert(same(await deps.head(c.bucket,c.storage_key,signal),c),409,'The saved photo changed. Upload it again.');
 const signed=await deps.sign(c.bucket,c.storage_key,300),response=await deps.fetch(signed,{method:'GET',headers:{'If-Match':c.etag},redirect:'error',signal});
 assert(response.status===200&&response.headers.get('etag')===c.etag,409,'The saved photo changed during verification.');
 const chunks:Uint8Array[]=[];let total=0;const reader=response.body?.getReader();assert(reader,503,'The saved photo could not be read.');
 try{while(true){const next=await reader.read();if(next.done)break;total+=next.value.length;assert(total<=c.bytes,409,'The saved photo changed during verification.');chunks.push(next.value);}}
 catch(error){await reader.cancel();throw error;}
 const bytes=new Uint8Array(total);let at=0;for(const part of chunks){bytes.set(part,at);at+=part.length;}
 assert(total===c.bytes&&await hex(bytes)===digest&&same(await deps.head(c.bucket,c.storage_key,signal),c),409,'The saved photo changed during verification.');
 const location:PropertySourceLocation={bucket:c.bucket as PropertySourceLocation['bucket'],storage_key:c.storage_key,etag:c.etag,bytes:c.bytes,content_type:c.content_type};
 return {asset,listing,photoProvenance,sha256:digest,qcHash:await driftLineageKey(base64),org:c.org_id,location};
 }catch(error){if(error instanceof HttpError)throw error;throw new HttpError(503,'The saved video source could not be verified. No generation was submitted.');}
}
/** Reuse the bounded real MP4 metadata parser; completion metadata supplied by
 * an iPhone is not authority for1080p/aspect/duration. No GPU/model calls. */
export async function attestPropertyVideo(actor:string,listing:string,asset:string,deps:PropertyVideoDeps,composition?:Record<string,unknown>){
 try{
  const c=await owned(actor,listing,asset,'video',deps),signal=AbortSignal.timeout(20000);
  assert(c.bucket==='renders'&&c.content_type.split(';')[0].trim().toLowerCase()==='video/mp4',400,'Choose the saved H.264 property video.');
  // Only a registered, ready server master may use the compositor's exact
  // CFR30 presentation-window verifier. A filename or client claim is not
  // authority. This existing read-only RPC repeats source/QC/withdrawal checks;
  // p_bytes=0 performs no delivery-budget debit. Native uploads stay strict.
  const registered=await deps.rpc('background_video_delivery',{p_actor:actor,p_org:c.org_id,p_listing:listing,p_key:c.storage_key,p_bytes:0});
  if(registered.error)throwRpc(registered.error.message);
  const master=registered.data as Record<string,unknown>|null;
  if(master!==null)assert(master&&master.kind==='registered_background_video'&&master.asset_id===asset&&master.bytes===c.bytes
   &&typeof c.sha256==='string'&&/^[a-f0-9]{64}$/.test(c.sha256)&&master.sha256===c.sha256,409,'The registered property video receipt changed.');
  assert(same(await deps.head(c.bucket,c.storage_key,signal),c),409,'The finalized video changed. Upload it again.');
  const photo=composition?.source_mode===PHOTO_MODE;
  const photoMaster=!!master&&PHOTO_PROFILES.includes(master.quality_profile as typeof PHOTO_PROFILES[number]);
  if(photo||photoMaster)assert(photo&&photoMaster&&master!.quality_profile===composition!.composition_profile,409,'This Photo motion video needs its exact registered server profile.');
  const signed=await deps.sign(c.bucket,c.storage_key,300);
  const cfr24=!!master&&CFR24_MASTER_PROFILES.includes(master.quality_profile);
  assert(!master||master.quality_profile===undefined||cfr24,409,'The saved composition profile is unavailable.');
  const info=await (master?probeComposedMP4Video:probeMP4Video)(signed,async(url,init)=>{
   assert(url===signed&&init.method==='GET'&&init.redirect==='error',503,'Unexpected property video read.');
   const h=new Headers(init.headers);h.set('If-Match',c.etag);
   const response=await deps.fetch(url,{...init,headers:h,signal:AbortSignal.any([signal,...(init.signal?[init.signal]:[])])});
   assert(response.headers.get('etag')===c.etag&&new RegExp(`^bytes \\d+-\\d+/${c.bytes}$`).test(response.headers.get('content-range')??''),409,'The video changed during verification.');return response;
  },cfr24?24:30);
  if(photo)assert(info.fps===24&&Math.abs(info.duration_s-Number(composition!.total_frames)/24)<=.001,409,'The registered Photo motion timeline changed.');
  assert(info.width>=1920&&info.height>=1080&&info.width*9===info.height*16&&info.width<=7680&&info.height<=4320&&info.duration_s<=600,400,'The listing video must be landscape16:9 at1080p or higher.');
  assert(same(await deps.head(c.bucket,c.storage_key,signal),c),409,'The finalized video changed. Upload it again.');
  const {data,error}=await deps.rpc('record_property_video_attestation',{p_actor:actor,p_listing:listing,p_asset:asset,p_etag:c.etag,p_bytes:c.bytes,p_width:info.width,p_height:info.height,p_duration:info.duration_s});if(error)throwRpc(error.message);
  assert((data as {attested?:unknown}|null)?.attested===true,503,'Property video verification could not be recorded.');return {...info,org_id:c.org_id};
 }catch(error){if(error instanceof HttpError)throw error;throw new HttpError(503,'The saved property video could not be checked. Please retry its publication.');}
}
