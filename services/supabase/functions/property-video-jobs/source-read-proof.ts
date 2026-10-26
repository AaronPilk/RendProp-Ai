import {assert} from '../_shared/http.ts';
const UUID=/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
const object=(v:any)=>v&&typeof v==='object'&&!Array.isArray(v);
/** Closed service proof, never supplied by the public caller. The SQL digest
 * binds the whole saved job and every current source row to the later commit. */
export function checkedSourceReadProof(raw:any,j:any){
 assert(object(raw)&&raw.schema===1&&Object.keys(raw).sort().join(',')==='failed_positions,job,proof_sha256,schema,sources'&&typeof raw.proof_sha256==='string'&&/^[a-f0-9]{64}$/.test(raw.proof_sha256),503,'The saved source-read recovery proof could not be verified.');
 assert(object(raw.job)&&j.state==='failed'&&raw.job.state==='failed'&&['id','operation_id','actor_id','org_id','library_org_id','listing_id','manifest_sha256','quality_profile','consent_revision','kie_test_grant_id','deadline'].every(k=>raw.job[k]===j[k])&&JSON.stringify(raw.job.processor_consent)===JSON.stringify(j.processor_consent)&&JSON.stringify(raw.job.quality_identity)===JSON.stringify(j.quality_identity)&&JSON.stringify(raw.job.manifest)===JSON.stringify(j.manifest),409,'The saved source-read recovery belongs to different inputs.');
 assert(Array.isArray(raw.sources)&&raw.sources.length===j.source_count&&raw.sources.length>=1&&raw.sources.length<=100&&raw.sources.every((s:any,i:number)=>object(s)&&s.job_id===j.id&&s.position===i&&typeof s.asset_id==='string'&&UUID.test(s.asset_id)&&object(s.source)&&s.source.actor_id===j.actor_id&&s.source.org_id===j.org_id&&s.source.listing_id===j.listing_id&&s.source.asset_id===s.asset_id),503,'The saved source-read recovery has incomplete sources.');
 assert(Array.isArray(raw.failed_positions)&&raw.failed_positions.length===1&&Number.isInteger(raw.failed_positions[0])&&raw.failed_positions[0]>=0&&raw.failed_positions[0]<raw.sources.length,503,'Use one proven failed source read.');
 const affected=raw.sources[raw.failed_positions[0]];
 assert(affected.state==='failed'&&affected.last_error==='source_unavailable'&&raw.sources.filter((s:any)=>s.state==='failed').length===1,409,'The saved source-read failure changed.');
 return raw;
}
