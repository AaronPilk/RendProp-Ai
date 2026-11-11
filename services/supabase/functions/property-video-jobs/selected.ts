import{mapCatalogueRows}from'./catalogue-map.ts';
import{selectedGallerySources}from'./source-selection.ts';
import{assert}from'../_shared/http.ts';
import{adminClient,contentOrgForUser}from'../_shared/supabase.ts';
import{createPrivateMediaRequestSigner}from'../_shared/private-media.ts';
import{preparationReply}from'./prepared.ts';
import{ownedHead,rpc,reply}from'./runtime.ts';
/** Listing selection is authority. Editing-history latest rows never replace it. */
export async function selectedSources(actor:string,listing:string,expected:string,offset=0){
 const started=performance.now();
 const phases={authorize_ms:0,listing_ms:0,gallery_ms:0,catalogue_ms:0,provenance_ms:0,reference_ms:0,head_ms:0,sign_ms:0,prepared_lookup_ms:0,prepared_reply_ms:0};
 let selectedRows=0,preparedRows=0,referenceAttempts=0,headAttempts=0,signAttempts=0,success=false;
 async function timed<T>(phase:keyof typeof phases,work:()=>PromiseLike<T>):Promise<T>{const at=performance.now();try{return await work();}finally{phases[phase]+=Math.max(0,performance.now()-at);}}
 try{
  const org=await timed('authorize_ms',()=>contentOrgForUser(actor,expected,listing,true)),db=adminClient(),signer=createPrivateMediaRequestSigner(org);
  const row=await timed('listing_ms',()=>db.from('listings').select('gallery_asset_ids').eq('id',listing).maybeSingle());assert(!row.error&&row.data,404,'This property is unavailable.');const gallery=row.data.gallery_asset_ids as string[]|null;
  const {selected,count}=await timed('gallery_ms',()=>selectedGallerySources(db,listing,gallery,offset));selectedRows=selected.length;
  const sources=await timed('catalogue_ms',()=>mapCatalogueRows(selected,async({asset:a,photo})=>{
   let verifiedBytes:number|null=a.bytes??null,verifiedSHA:string|null=a.sha256??null;let referenceVerified=false;let provenance:string|null=null,eligible=false,reason='This selected image needs a retained prepared JPEG upload.',preview_url:string|null=null;
   if(a.storage_key){const p=await timed('provenance_ms',()=>db.from('media_provenance').select('id').eq('listing_id',listing).eq('altered_key',a.storage_key).in('kind',['photo_edit','virtual_stage','declutter']).order('created_at',{ascending:false}).limit(1).maybeSingle());assert(!p.error,503,'Selected photo provenance could not be read.');provenance=p.data?.id??null;}
   if(a.id){try{referenceAttempts++;const owned=await timed('reference_ms',()=>rpc('property_photo_reference',{p_actor:actor,p_listing:listing,p_asset:a.id,p_provenance:provenance}));headAttempts++;await timed('head_ms',()=>ownedHead(owned));referenceVerified=true;signAttempts++;preview_url=await timed('sign_ms',()=>signer.sign({actor,org,listing,bucket:owned.bucket,key:owned.storage_key}));verifiedBytes=owned.bytes;verifiedSHA=owned.sha256;eligible=['image/jpeg','image/png','image/webp'].includes(owned.content_type)&&owned.bytes<=8*1024*1024&&typeof owned.sha256==='string';reason=eligible?'':'Prepare this exact selected version as an8MiB-or-smaller JPEG for video.';}catch{referenceVerified=false;reason='This selected version is unavailable or has not passed its photo review.';}}
   const prep=referenceVerified?await timed('prepared_lookup_ms',()=>db.from('property_video_preparations').select('id').eq('actor_id',actor).eq('listing_id',listing).eq('original_asset_id',a.id??'00000000-0000-0000-0000-000000000000').eq('version_id','asset:'+a.id).eq('state','ready').order('created_at',{ascending:false}).limit(1).maybeSingle()):{data:null,error:null};assert(!prep.error,503,'Prepared video inputs could not be read.');if(prep.data){const prepId=prep.data.id;preparedRows++;const p=await timed('prepared_reply_ms',async()=>preparationReply(await rpc('property_video_preparation_scope',{p_id:prepId,p_actor:actor}),signer.sign));if(p.source)return p.source;}
   eligible=false;if(referenceVerified)reason='Prepare this exact selected master for video; its original stays unchanged.';
   return{needs_preparation:referenceVerified&&!!a.id&&typeof verifiedSHA==='string'&&verifiedBytes!==null&&verifiedBytes<=50*1024*1024,photo_id:photo,photo_asset_id:a.id,photo_version_id:a.id?'asset:'+a.id:'photo:'+photo,photo_provenance_id:provenance,preview_url,bytes:verifiedBytes,sha256:verifiedSHA,eligible,...(!eligible?{reason}:{})};}));
  const currentOrg=await timed('authorize_ms',()=>contentOrgForUser(actor,expected,listing,true));
  assert(currentOrg===org,403,'Current workspace access changed during this source request.');
  await timed('sign_ms',()=>signer.assertFresh());
  success=true;
  return{listing_id:listing,org_id:org,selected_library_org_id:expected,selected_count:count,sources,next_offset:offset+100<count?offset+100:null};
 }finally{
  // Fixed names and aggregate timings only. Never log media paths, actors,
  // listing identities, URLs, tokens, or errors from a private source row.
  try{console.info(JSON.stringify({event:'property_video_sources_timing',ok:success,total_ms:Math.round(Math.max(0,performance.now()-started)),selected_rows:selectedRows,prepared_rows:preparedRows,reference_attempts:referenceAttempts,head_attempts:headAttempts,sign_attempts:signAttempts,...Object.fromEntries(Object.entries(phases).map(([name,value])=>[name,Math.round(value)]))}));}catch{/* Observation must not affect source reads. */}
 }
}
export async function pastJobs(actor:string,listing:string,expected:string,offset=0){const org=await contentOrgForUser(actor,expected,listing,true);const rows=await adminClient().from('property_video_jobs').select('id').eq('actor_id',actor).eq('listing_id',listing).order('created_at',{ascending:false}).range(offset,offset+20);assert(!rows.error,503,'Saved videos could not be read.');const jobs=[];for(const row of(rows.data??[]).slice(0,20))jobs.push(await reply(await rpc('property_video_job_scope',{p_job:row.id,p_actor:actor,p_active:false})));return{listing_id:listing,org_id:org,selected_library_org_id:expected,jobs,next_offset:(rows.data?.length??0)>20?offset+20:null};}

// A closed operation never starts work. Before C2 only a durable capacity
// refusal could close one, so a missing reason keeps that meaning.
async function operationReply(found:any,actor:string,listing:string,expected:string,operation:string){const closed=found.operation_closed===true;return{operation_id:operation,listing_id:listing,org_id:found.org_id,selected_library_org_id:expected,operation_closed:closed,closed_reason:closed?(found.closed_reason==='abandoned'?'abandoned':'capacity_refused'):null,message:found.message??null,job:found.job_id?await reply(await rpc('property_video_job_scope',{p_job:found.job_id,p_actor:actor,p_active:false})):null};}
export async function operationJob(actor:string,listing:string,expected:string,operation:string){return operationReply(await rpc('property_video_operation_lookup',{p_actor:actor,p_listing:listing,p_expected:expected,p_operation:operation}),actor,listing,expected,operation);}
/** C2: resolves the exact saved operation and tombstones it only if the server never accepted or refused it. */
export async function abandonOperation(actor:string,listing:string,expected:string,operation:string){return operationReply(await rpc('property_video_operation_abandon',{p_actor:actor,p_listing:listing,p_expected:expected,p_operation:operation}),actor,listing,expected,operation);}
