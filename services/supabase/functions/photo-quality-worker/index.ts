/** Private comparison bridge and isolated funded judge. Never generates photos. */
import{assert,json,pathSegments,readJsonLimited,respondError}from'../_shared/http.ts';
import{adminClient,isServiceRole}from'../_shared/supabase.ts';
import{R2_BUCKET_RENDERS}from'../_shared/r2.ts';
import{presignGet,bytesToB64}from'../_shared/providers/common.ts';
import{boundedPhotoResultBytes}from'../ai-photo/photo-result.ts';
import{validatePhotoInput}from'../ai-photo/input-policy.ts';
import{photoBytesHash,photoUUID,photoSHA,photoQualityRpc}from'../ai-photo/photo-qc-store.ts';
import{photoOutputHead,photoPutCapability}from'./storage.ts';
import{judgeSavedPhoto}from'./judge.ts';
const rpc=(name:string,args:Record<string,unknown>)=>photoQualityRpc(adminClient(),name,args);
const uuid=(v:unknown)=>{assert(photoUUID(v),400,'Use the retained photo check identity.');return v;};
async function scope(check:string,lease:string){return await rpc('photo_quality_worker_scope',{p_check:check,p_lease:lease});}
async function media(e:any,kind:'input'|'output'){
 const f=e[kind],etag=e[kind+'_etag'];assert(f&&f.bucket==='renders'&&f.key===`ai-router/${e.org_id}/photo-evidence/${e.actor_id}/${e.id}/${kind==='input'?'input':'candidate'}.${f.mime==='image/jpeg'?'jpg':f.mime==='image/png'?'png':'webp'}`&&photoSHA(f.sha256)&&Number.isSafeInteger(f.bytes)&&f.bytes>0&&f.bytes<=9000000&&typeof etag==='string',409,'The saved comparison source changed.');
 const head=await photoOutputHead(f.key);assert(head.bytes===f.bytes&&head.sha256===f.sha256&&head.mime===f.mime&&head.etag===etag,409,'The exact saved photo evidence changed.');
 return{bucket:'renders',key:f.key,etag,bytes:f.bytes,sha256:f.sha256,mime:f.mime,url:await presignGet(R2_BUCKET_RENDERS,f.key,600)};
}
export async function handler(req:Request){try{
 assert(isServiceRole(req),403,'This route is limited to the private Rendprop photo comparison worker.');
 const seg=pathSegments(req,'photo-quality-worker');
 if(req.method==='GET'&&seg.join('/')==='queue'){
  const admin=adminClient(),since=new Date(Date.now()-3600000).toISOString();
  const [rows,judges]=await Promise.all([
   admin.from('photo_quality_checks').select('id').in('state',['pending','preparing']).is('judge_started_at',null).gt('created_at',since).order('created_at').limit(20),
   admin.from('photo_quality_checks').select('id').eq('state','derivative_ready').eq('automatic',true).is('judge_started_at',null).gt('created_at',since).order('created_at').limit(2),
  ]);
  // A prepared comparison can outlive its initiating phone request. Return only
  // bounded identities; the existing judge rechecks scope and paid dispatch.
  assert(!rows.error&&!judges.error,503,'Saved photo checks could not be listed.');return json({enabled:true,checks:(rows.data??[]).map(x=>({check_id:x.id})),judges:(judges.data??[]).map(x=>({check_id:x.id}))});
 }
 assert(req.method==='POST'&&seg.length===1,405,'Use an explicit private photo comparison action.');
 const b=await readJsonLimited<Record<string,any>>(req,65536),check=uuid(b.check_id);
 if(seg[0]==='judge'){
  assert(Object.keys(b).length===1,400,'The private judge accepts only its saved check identity.');
  const c=await judgeSavedPhoto(adminClient(),check,req);
  return json({check_id:c.check.id,evidence_id:c.evidence.id,state:c.check.state});
 }
 if(seg[0]==='tick'){
  assert(b.worker_id==='slot-0'||b.worker_id==='slot-1',400,'Use a fixed dedicated CPU slot.');
  const c=await rpc('photo_quality_claim',{p_check:check});
  if(c.action!=='prepare_photo_quality')return json({check_id:check,action:c.action==='judge'||['accept','refuse','hold','checking','derivative_ready'].includes(c.check?.state)?'done':'wait',state:c.check?.state??'hold'});
  const e=c.evidence,q=c.check;assert(q.id===check&&q.evidence_id===e.id&&photoUUID(q.lease_token),503,'The comparison lease identity is inconsistent.');
  await scope(check,q.lease_token);const prepared=await media(e,'input'),candidate=await media(e,'output');await scope(check,q.lease_token);
  return json({action:'prepare_photo_quality',policy:'photo-fixed-features-v1',check_id:check,evidence_id:e.id,lease_token:q.lease_token,expires_at:q.lease_until,prepared_source:prepared,candidate});
 }
 const lease=uuid(b.lease_token);
 if(seg[0]==='heartbeat')return json({current:await rpc('photo_quality_heartbeat',{p_check:check,p_lease:lease})});
 if(seg[0]==='failure'){
  assert(b.code==='cpu_photo_comparison_failed',400,'Use a closed photo comparison preparation failure.');
  const c=await rpc('photo_quality_cpu_failure',{p_check:check,p_lease:lease,p_code:b.code});return json({recorded:true,check_id:check,state:c.check.state});
 }
 if(seg[0]==='derivatives'){
  await scope(check,lease);const o=await rpc('photo_quality_derivatives_reserve',{p_check:check,p_lease:lease,p_manifest:b.manifest});
  const images=[];for(const file of o.images)images.push({...file,...await photoPutCapability(file.key,file.bytes,file.sha256)});
  await scope(check,lease);return json({check_id:check,evidence_id:o.evidence_id,parents:o.parents,images,expires_at:new Date(Date.now()+600000).toISOString()});
 }
 if(seg[0]==='derivatives-finish'){
  const c=await scope(check,lease);assert(Array.isArray(b.receipts)&&b.receipts.length===10&&Array.isArray(c.check.derivatives)&&c.check.derivatives.length===10,400,'Use all ten retained comparison receipts.');
  const receipts=[];let total=0;const seen=new Set<string>();
  for(const raw of b.receipts){const stored=c.check.derivatives.find((x:any)=>x.key===raw.key);assert(stored&&!seen.has(raw.key)&&JSON.stringify(Object.keys(raw).filter(k=>k!=='etag').sort())===JSON.stringify(Object.keys(stored).sort()),409,'The comparison receipt identity changed.');seen.add(raw.key);
   for(const k of Object.keys(stored)){if(k==='crop'){assert(raw.crop&&JSON.stringify(Object.keys(raw.crop).sort())===JSON.stringify(['left','top','width','height'].sort())&&['left','top','width','height'].every(n=>raw.crop[n]===stored.crop[n]),409,'A reserved comparison crop changed.');}else assert(raw[k]===stored[k],409,'A reserved comparison descriptor changed.');}
   const head=await photoOutputHead(stored.key);assert(head.bytes===stored.bytes&&head.mime==='image/jpeg'&&head.sha256===stored.sha256&&(raw.etag===undefined||head.etag===raw.etag)&&head.etag.length>0&&head.etag.length<=200,409,'The uploaded comparison image changed.');
   total+=stored.bytes;assert(total<=6000000,413,'The comparison package exceeds its measured memory envelope.');
   const response=await fetch(await presignGet(R2_BUCKET_RENDERS,stored.key,60),{redirect:'error',credentials:'omit',signal:AbortSignal.timeout(10000)});const bytes=await boundedPhotoResultBytes(response,stored.bytes);assert(await photoBytesHash(bytes)===stored.sha256,409,'The comparison image fingerprint changed.');const image=validatePhotoInput(bytesToB64(bytes),'image/jpeg');assert(image.width===stored.width&&image.height===stored.height,409,'The comparison image geometry changed.');receipts.push({...stored,etag:head.etag});
  }
  await scope(check,lease);const done=await rpc('photo_quality_derivatives_complete',{p_check:check,p_lease:lease,p_receipts:receipts});return json({accepted:true,check_id:check,evidence_id:done.evidence.id,state:done.check.state});
 }
 assert(false,405,'Unsupported private photo comparison action.');
 }catch(error){return respondError(error);}}
if(import.meta.main)Deno.serve(handler);
