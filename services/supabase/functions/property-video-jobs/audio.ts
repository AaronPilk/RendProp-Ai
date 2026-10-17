/** Recorded narration is an actual audio object, never a disguised video.
 * Browser transport stays on the authenticated app gateway; storage capability
 * is internal and immutable. Unknown PUT replies recover via HEAD before retry. */
import{assert,HttpError,readJsonLimited}from'../_shared/http.ts';
import{adminClient,assertNotDeleting,contentOrgForUser,preferredOrg}from'../_shared/supabase.ts';
import{uuid}from'./input.ts';
import{outputHead,putCapability,MissingPrivateMedia}from'./storage.ts';
import{bytesFrom,hash,rpc}from'./runtime.ts';
const LIMIT=20*1024*1024;
async function context(actor:string,id:string,req:Request){await assertNotDeleting(actor);const{data:a,error}=await adminClient().from('property_video_audio_assets').select('*').eq('id',uuid(id)).eq('actor_id',actor).maybeSingle();assert(!error,503,'Saved narration could not be read.');assert(a,404,'Saved narration is unavailable.');assert(!preferredOrg(req)||[a.library_org_id,a.org_id].includes(preferredOrg(req)),409,'The selected narration library changed.');await contentOrgForUser(actor,a.library_org_id,a.listing_id,true);return a;}
function receipt(row:any){return{narration_asset_id:row.id,listing_id:row.listing_id,selected_library_org_id:row.library_org_id,ready:true,sha256:row.sha256};}
function validAudio(bytes:Uint8Array,mime:string){assert(mime==='audio/mp4'?bytes.length>12&&new TextDecoder().decode(bytes.subarray(4,8))==='ftyp':bytes.length>3&&(new TextDecoder().decode(bytes.subarray(0,3))==='ID3'||bytes[0]===255&&(bytes[1]&224)===224),400,'Use a valid saved M4A or MP3 narration.');}
async function observed(a:any){const h=await outputHead('renders',a.storage_key);assert(h.exists&&h.bytes===a.bytes&&h.contentType?.split(';')[0]===a.mime&&h.etag&&h.sha256===a.sha256,409,'The uploaded narration could not be verified.');return h;}
async function finish(actor:string,a:any){const h=await observed(a);const{bytes}=await bytesFrom({...a,bucket:'renders',content_type:a.mime,etag:h.etag},LIMIT);validAudio(bytes,a.mime);const row=await rpc('property_video_audio_complete',{p_actor:actor,p_asset:a.id,p_etag:h.etag});return receipt(row);}
async function bodyBytes(req:Request,expected:number){const length=req.headers.get('content-length');assert(length===null||/^\d+$/.test(length)&&Number(length)===expected,400,'Narration size differs from its saved receipt.');const reader=req.body?.getReader();assert(reader,400,'The narration file is required.');const bytes=new Uint8Array(expected);let size=0;try{for(;;){const value=await reader.read();if(value.done)break;assert(size+value.value.byteLength<=expected&&size+value.value.byteLength<=LIMIT,413,'Narration exceeded its saved size.');bytes.set(value.value,size);size+=value.value.byteLength;}}catch(e){await reader.cancel();throw e;}assert(size===expected,400,'Narration ended before its saved size.');return bytes;}
export async function completeAudio(actor:string,id:string,req:Request){const a=await context(actor,id,req);const b=await readJsonLimited<Record<string,unknown>>(req,4096);assert(Object.keys(b).every(k=>['listing_id','expected_org_id'].includes(k))&&uuid(b.listing_id)===a.listing_id&&[a.org_id,a.library_org_id].includes(uuid(b.expected_org_id)),409,'Use this narration’s saved property and library.');return await finish(actor,a);}
export async function uploadAudio(actor:string,id:string,req:Request){const a=await context(actor,id,req);assert(req.headers.get('content-type')?.split(';')[0].toLowerCase()===a.mime,400,'Narration type differs from its saved receipt.');const bytes=await bodyBytes(req,a.bytes);assert(await hash(bytes)===a.sha256,409,'Narration fingerprint differs from its saved receipt.');validAudio(bytes,a.mime);
 try{await observed(a);return await finish(actor,a);}catch(e){if(!(e instanceof MissingPrivateMedia))throw e;}
 assert(a.state!=='ready'&&Date.parse(a.upload_until)>Date.now(),409,'Prepare this saved narration again before uploading.');await context(actor,id,req);
 const cap=await putCapability('renders',a.storage_key,a.bytes,a.mime,a.sha256);const result=await fetch(cap.put_url,{method:'PUT',headers:cap.headers,body:bytes,redirect:'error',signal:AbortSignal.timeout(60000)});
 assert(result.ok||result.status===412,503,'Narration upload could not be confirmed. Keep this saved upload and retry.');return await finish(actor,a);
}
