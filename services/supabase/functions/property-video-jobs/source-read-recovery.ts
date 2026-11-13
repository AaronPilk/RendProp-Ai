import {assert} from '../_shared/http.ts';
import {adminClient} from '../_shared/supabase.ts';
import {assertMediaVisible} from '../_shared/media-source-access.ts';
import {validatePhotoInput} from '../ai-photo/input-policy.ts';
import {base64,bytesFrom,ownedHead,sourceReadResumeProof} from './runtime.ts';
import {checkedSourceReadProof} from './source-read-proof.ts';
type IO={db:typeof adminClient;visible:typeof assertMediaVisible;head:typeof ownedHead;bytes:typeof bytesFrom;proof:typeof sourceReadResumeProof};
const defaults:IO={db:adminClient,visible:assertMediaVisible,head:ownedHead,bytes:bytesFrom,proof:sourceReadResumeProof};
/** Failed parents cannot use worker_scope. This preflight receives only the
 * closed, read-only saved-job proof. It neither forges a worker lease nor
 * changes the parent. The ordinary claim repeats its full active custody
 * fence after the transactional recovery; any changed proof stops here. */
export async function preflightSourceReadRecovery(j:any,raw:any,io:IO=defaults):Promise<string>{
 const proof=checkedSourceReadProof(raw,j),sources=proof.sources;
 // Same prepared-alias disclosure expansion as deployed worker17 scope().
 const assets:string[]=sources.map((s:any)=>s.asset_id),provenance=[...new Set(sources.filter((s:any)=>s.photo_provenance_id!=null).map((s:any)=>s.photo_provenance_id))];
 if(provenance.length){
  const {data,error}=await io.db().from('media_provenance').select('id,org_id,listing_id,photo_publication').eq('org_id',j.org_id).eq('listing_id',j.listing_id).in('id',provenance);
  assert(!error&&Array.isArray(data)&&data.length===provenance.length&&data.every((m:any)=>provenance.includes(m.id)&&m.org_id===j.org_id&&m.listing_id===j.listing_id),503,'Saved video disclosure custody could not be verified.');
  for(const m of data){const p=m.photo_publication;if(p===null)continue;
   assert(p&&p.schema===1&&p.phase==='prepared'&&p.target?.org_id===j.org_id&&p.target?.listing_id===j.listing_id&&typeof p.target.output_asset_id==='string'&&typeof p.target.source_copy_asset_id==='string',503,'Saved video publication identity could not be verified.');
   assets.push(p.target.output_asset_id,p.target.source_copy_asset_id);
  }
 }
 // Includes actual four-object publication HEADs and a fresh descriptor read.
 await io.visible(io.db(),j.listing_id,{assets:[...new Set(assets)]});
 for(const s of sources)await io.head(s.source);
 for(const position of proof.failed_positions){const s=sources[position],{bytes}=await io.bytes(s.source);const info=validatePhotoInput(base64(bytes),s.source.content_type);assert(Math.max(info.width,info.height)<=2048,409,'Prepare this exact photo within the video input geometry before resuming.');}
 const fresh=await io.proof(j);assert(fresh&&fresh.proof_sha256===proof.proof_sha256,409,'Saved video inputs changed during source-read verification.');
 checkedSourceReadProof(fresh,j);
 return proof.proof_sha256;
}
