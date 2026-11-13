import {assert,throwRpc} from '../_shared/http.ts';
import {adminClient} from '../_shared/supabase.ts';
import {admitMediaRead} from '../_shared/media-delivery-admission.ts';
import {headObject,R2_BUCKET_UPLOADS} from '../_shared/r2.ts';
import {presignGet} from '../_shared/providers/common.ts';
import type {AerialOriginal} from './aerial-admission.ts';

export const AERIAL_ORIGINAL_PROOF_SCHEMA='aerial_original_server_bytes_v1';
const MIME=['image/jpeg','image/png','image/webp','image/heic','image/heif'];
/** Abort a wait without allowing its continuation to dispatch the next step.
 * An already-dispatched accounting/RPC request may settle; this never retries it. */
export async function aerialOriginalWait<T>(start:()=>PromiseLike<T>,signal:AbortSignal):Promise<T>{
 signal.throwIfAborted();
 return await new Promise<T>((resolve,reject)=>{const abort=()=>{signal.removeEventListener('abort',abort);reject(signal.reason);};signal.addEventListener('abort',abort,{once:true});if(signal.aborted){abort();return;}let work:PromiseLike<T>;try{work=start();}catch(error){signal.removeEventListener('abort',abort);reject(error);return;}Promise.resolve(work).then(value=>{signal.removeEventListener('abort',abort);if(signal.aborted)reject(signal.reason);else resolve(value);},error=>{signal.removeEventListener('abort',abort);reject(error);});});
}
export function aerialOriginalByteProof(actor:string,operation:string,org:string,listing:string,source:AerialOriginal,owned:any){
 return{method:'sha256_if_match',actor_id:actor,operation_id:operation,org_id:org,listing_id:listing,asset_id:source.photo_asset_id,bucket:owned.bucket,storage_key:owned.storage_key,bytes:source.bytes,etag:owned.etag,content_type:owned.content_type,sha256:source.sha256};
}
/** Only the legacy NULL-hash raw-upload lane. Reads once under the immutable
 * retained ETag, hashes actual bounded bytes, then rechecks custody. Generic
 * capture-asset SHA and every old owned receipt remain unchanged. */
export async function registerByteVerifiedAerialOriginal(actor:string,operation:string,org:string,library:string,listing:string,source:AerialOriginal,owned:any,signal:AbortSignal){
 signal.throwIfAborted();
 assert(owned?.actor_id===actor&&owned.org_id===org&&owned.listing_id===listing&&owned.asset_id===source.photo_asset_id&&owned.sha256===null&&owned.bucket==='uploads'&&typeof owned.storage_key==='string'&&owned.storage_key.startsWith(`uploads/${org}/${listing}/`)&&!owned.storage_key.includes('..')&&owned.bytes===source.bytes&&Number.isSafeInteger(owned.bytes)&&owned.bytes>0&&owned.bytes<=52_428_800&&MIME.includes(owned.content_type)&&typeof owned.etag==='string'&&owned.etag.length>0&&owned.etag.length<=256,409,'Keep the exact completed raw original receipt.');
 const admin=adminClient();
 await aerialOriginalWait(()=>admitMediaRead(admin,org,owned.bytes,false,actor),signal);
 const check=async()=>{const h=await aerialOriginalWait(()=>headObject(R2_BUCKET_UPLOADS,owned.storage_key,signal),signal);assert(h.exists&&h.etag===owned.etag&&h.bytes===owned.bytes&&h.contentType?.split(';')[0].trim().toLowerCase()===owned.content_type,409,'The original upload changed during verification.');};
 await check();
 const url=await aerialOriginalWait(()=>presignGet(R2_BUCKET_UPLOADS,owned.storage_key,60),signal);
 const response=await aerialOriginalWait(()=>fetch(url,{headers:{'If-Match':owned.etag},redirect:'error',signal}),signal);
 if(!(response.status===200&&response.body&&response.headers.get('etag')===owned.etag&&response.headers.get('content-length')===String(owned.bytes)&&(response.headers.get('content-type')??'').split(';')[0].trim().toLowerCase()===owned.content_type)){
  void response.body?.cancel().catch(()=>{});assert(false,409,'The original bytes no longer match their retained receipt.');
 }
 const bytes=new Uint8Array(owned.bytes),reader=response.body!.getReader();let used=0;
 try{for(;;){const next=await aerialOriginalWait(()=>reader.read(),signal);if(next.done)break;assert(used+next.value.byteLength<=bytes.byteLength,413,'The original exceeded its retained byte bound.');bytes.set(next.value,used);used+=next.value.byteLength;}}
 finally{void reader.cancel().catch(()=>{});reader.releaseLock();}
 assert(used===bytes.byteLength,409,'The original byte length changed.');
 const digest=await aerialOriginalWait(()=>crypto.subtle.digest('SHA-256',bytes),signal),sha=Array.from(new Uint8Array(digest),n=>n.toString(16).padStart(2,'0')).join('');
 assert(sha===source.sha256,409,'The original bytes do not match this saved photo.');
 await check();signal.throwIfAborted();
 // A lost reply is unknown, never a reason to replay a write. The same normal
 // operation can be read/verified again; SQL preserves its exact saved inputs.
 const {data,error}=await aerialOriginalWait(()=>admin.rpc('property_video_aerial_original_verify_register',{p_actor:actor,p_operation:operation,p_library:library,p_listing:listing,p_source:source,p_owned:owned,p_verified:aerialOriginalByteProof(actor,operation,org,listing,source,owned)}).abortSignal(signal),signal);
 if(error)throwRpc(error.message);assert(data!==null,503,'The verified original receipt could not be confirmed.');return data;
}
