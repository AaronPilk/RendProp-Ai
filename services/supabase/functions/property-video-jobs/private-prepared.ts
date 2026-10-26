// Explicit private video choices do not replace the listing gallery selection.
import {assert,json,readJsonLimited,throwRpc} from '../_shared/http.ts';
import {adminClient,assertNotDeleting,contentOrgForUser,preferredOrg} from '../_shared/supabase.ts';
import {ensureAcceptedPhotoPublication} from '../_shared/photo-publication.ts';
import {assertMediaVisible} from '../_shared/media-source-access.ts';
import {publicationHash,publicationMediaType} from '../_shared/photo-publication-bytes.ts';
import {admitMediaRead} from '../_shared/media-delivery-admission.ts';
import {presignGet} from '../_shared/providers/common.ts';
import {R2_BUCKET_RENDERS} from '../_shared/r2.ts';
import {PHOTO_OUTPUT_MAX_BYTES} from '../_shared/photo-output-policy.ts';
import {preparationReply} from './prepared.ts';
import {uuid} from './input.ts';
import {rpc} from './runtime.ts';
async function actualMaster(target:any,sha:string,signal:AbortSignal){
 assert(Number.isSafeInteger(target.bytes)&&target.bytes>0&&target.bytes<=52_428_800,413,'Use an unchanged chosen master up to50MiB.');
 const response=await fetch(await presignGet(R2_BUCKET_RENDERS,target.key,60),{headers:{'If-Match':target.etag},redirect:'error',signal});
 assert(response.status===200&&response.body&&response.headers.get('etag')===target.etag&&response.headers.get('content-length')===String(target.bytes)&&(response.headers.get('content-type')??'').split(';')[0].trim().toLowerCase()===target.mime,409,'The full chosen master changed.');
 const bytes=new Uint8Array(target.bytes),reader=response.body.getReader();let used=0;
 try{for(;;){signal.throwIfAborted();const next=await new Promise<ReadableStreamReadResult<Uint8Array>>((resolve,reject)=>{const abort=()=>{signal.removeEventListener('abort',abort);reject(signal.reason);};signal.addEventListener('abort',abort,{once:true});if(signal.aborted){abort();return;}reader.read().then(v=>{signal.removeEventListener('abort',abort);resolve(v);},e=>{signal.removeEventListener('abort',abort);reject(e);});});if(next.done)break;assert(used+next.value.length<=bytes.length,409,'The chosen master exceeded its receipt.');bytes.set(next.value,used);used+=next.value.length;}}
 finally{void reader.cancel().catch(()=>{});reader.releaseLock();}
 assert(used===bytes.length&&publicationMediaType(bytes)===target.mime&&await publicationHash(bytes)===sha,409,'The chosen master bytes do not match this exact photo.');
 return{sha256:sha,bytes:target.bytes,mime:target.mime,etag:target.etag};
}
const keys=['operation_id','listing_id','expected_org_id','photo_id','photo_asset_id','photo_version_id','photo_provenance_id','source_sha256','source_bytes'];
async function chosenReply(p:any){
 await assertMediaVisible(adminClient(),p.listing_id,{assets:[p.original_asset_id]});
 const result=await preparationReply(p);let sourceID=p.photo_provenance_id;
 if(sourceID){const{data,error}=await adminClient().from('media_provenance').select('id,org_id,listing_id,photo_publication').eq('id',sourceID).eq('org_id',p.org_id).eq('listing_id',p.listing_id).maybeSingle();assert(!error&&data,503,'Saved video-source disclosure could not be verified.');if(data.photo_publication!==null){assert(data.photo_publication?.phase==='prepared'&&data.photo_publication?.target?.output_asset_id===p.original_asset_id,409,'Saved video-source publication changed.');sourceID=data.photo_publication.source.provenance_id;}}
 await assertMediaVisible(adminClient(),p.listing_id,{assets:[p.original_asset_id]});
 return{...result,actor_id:p.actor_id,master:{asset_id:p.original_asset_id,version_id:p.version_id,photo_id:p.photo_id,sha256:p.original_source.sha256,bytes:p.original_source.bytes,photo_provenance_id:p.photo_provenance_id,source_provenance_id:sourceID}};
}
export async function privatePreparationPublic(req:Request,actor:string,seg:string[]){
 if(seg.join('/')!=='sources/prepare-chosen')return null;
 assert(['GET','POST'].includes(req.method),405,'Use an exact private video-source request.');
 const admin=adminClient(),signal=AbortSignal.any([req.signal,AbortSignal.timeout(90_000)]);await assertNotDeleting(actor);
 if(req.method==='GET'){
  const q=new URL(req.url).searchParams;assert([...q.keys()].length===3&&['operation_id','listing_id','expected_org_id'].every(k=>q.getAll(k).length===1),400,'Check one exact saved video-source operation.');
  const op=uuid(q.get('operation_id')),listing=uuid(q.get('listing_id')),library=uuid(q.get('expected_org_id'));
  assert(!preferredOrg(req)||preferredOrg(req)===library,409,'The selected library changed.');await contentOrgForUser(actor,library,listing,true);
  const{data,error}=await admin.rpc('property_video_private_preparation_read',{p_actor:actor,p_listing:listing,p_expected:library,p_operation:op});if(error)throwRpc(error.message);assert(data,404,'This saved source request has not been confirmed. No new request was sent.');
  return json(await chosenReply(data),200,{'cache-control':'no-store'});
 }
 const b=await readJsonLimited<Record<string,any>>(req,4096);assert(Object.keys(b).length===keys.length&&keys.every(k=>Object.hasOwn(b,k)),400,'Send only the exact private master receipt.');
 for(const k of['operation_id','listing_id','expected_org_id','photo_asset_id'])b[k]=uuid(b[k]);b.photo_provenance_id=b.photo_provenance_id==null?null:uuid(b.photo_provenance_id);
 assert(typeof b.photo_id==='string'&&b.photo_id.length>0&&b.photo_id.length<=200&&b.photo_version_id==='asset:'+b.photo_asset_id&&/^[a-f0-9]{64}$/.test(b.source_sha256)&&Number.isSafeInteger(b.source_bytes)&&b.source_bytes>0&&b.source_bytes<=52_428_800,400,'Keep the full unchanged chosen master and its exact version.');
 assert(req.headers.get('idempotency-key')?.toLowerCase()==='property-video-source:'+b.operation_id&&(!preferredOrg(req)||preferredOrg(req)===b.expected_org_id),409,'Keep the saved source operation and library.');
 const org=await contentOrgForUser(actor,b.expected_org_id,b.listing_id,true);let normalized:string|null=null;
 const target=await rpc('photo_publication_target',{p_actor:actor,p_org:org,p_library:b.expected_org_id,p_listing:b.listing_id,p_asset:b.photo_asset_id});
 assert(target.target?.asset_id===b.photo_asset_id&&target.target?.bytes===b.source_bytes,409,'The chosen full-master receipt changed.');
 await admitMediaRead(admin,org,b.source_bytes,false,actor);const proof=await actualMaster(target.target,b.source_sha256,signal);
 let original:any=null;
 if(b.photo_provenance_id){const{data,error}=await admin.from('media_provenance').select('id,org_id,listing_id,original_key,altered_key,photo_publication').eq('id',b.photo_provenance_id).maybeSingle();assert(!error&&data&&data.org_id===org&&(data.listing_id===null||data.listing_id===b.listing_id),404,'This chosen edit is unavailable in this library.');original=data;}
 if(original?.listing_id!==null&&original!==null&&original.photo_publication===null){
  // Established listing-bound edits keep the existing attachment/QC contract;
  // a new uploaded or resized JPEG cannot borrow a different photo's verdict.
  assert(original.altered_key===target.target?.key&&target.target.bytes===b.source_bytes,409,'Use the exact attached edited master.');
  await assertMediaVisible(admin,b.listing_id,{assets:[b.photo_asset_id],keys:[target.target.key]});normalized=original.id;
 }else if(original===null){
  const known=b.source_bytes>PHOTO_OUTPUT_MAX_BYTES?null:await rpc('photo_publication_resolve',{p_actor:actor,p_org:org,p_library:b.expected_org_id,p_listing:b.listing_id,p_asset:b.photo_asset_id,p_provenance:null,p_verified_target:proof});
  assert(known===null&&target.publication===null,409,'Preserve the saved edit disclosure before preparing this photo.');
  await assertMediaVisible(admin,b.listing_id,{assets:[b.photo_asset_id]});
 }else{
  const selector=original?.photo_publication?.source?.provenance_id??original?.id;
  const publication=await ensureAcceptedPhotoPublication(admin,{orgId:org,libraryOrgId:b.expected_org_id,listingId:b.listing_id},actor,b.photo_asset_id,{...(selector?{provenanceID:selector}:{}),reviewed:true,expected:{sha256:b.source_sha256,bytes:b.source_bytes},signal:req.signal});normalized=publication?.id??null;
  assert(publication!==null,409,'Preserve the chosen master effects and saved disclosure.');
 }
 // No gallery read-modify-write or source substitution. The separate private
 // RPC preserves every old custody/quality/CPU rule except gallery membership.
 const body=Object.fromEntries(keys.slice(0,7).map(k=>[k,k==='photo_provenance_id'?normalized:b[k]]));
 const p=await rpc('property_video_private_preparation_enqueue',{p_actor:actor,p_body:body});
 assert(p.actor_id===actor&&p.operation_id===b.operation_id&&p.listing_id===b.listing_id&&p.library_org_id===b.expected_org_id&&p.original_asset_id===b.photo_asset_id&&p.version_id===b.photo_version_id&&p.original_source.sha256===b.source_sha256&&p.original_source.bytes===b.source_bytes,503,'The saved private source receipt did not match the chosen master.');
 return json(await chosenReply(p),p.state==='ready'?200:202,{'cache-control':'no-store'});
}
