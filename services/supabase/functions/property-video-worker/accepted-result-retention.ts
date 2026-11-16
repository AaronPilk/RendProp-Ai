import{registeredPropertyPromptIdentity}from'../_shared/property-video-prompt-registry.ts';
/** One explicit already-paid result retention directive. No generation, claim,
 * Resume, source/job mutation, QC, composition, grant or selector writes. */
import{adminClient}from'../_shared/supabase.ts';
import{assertPublicSupabaseOrigin}from'../_shared/providers/jobtoken.ts';
import{KIE_PROPERTY_IDENTITY,KIE_PROPERTY_PROFILE,kiePropertyIdentityConsistent,sameJsonValue}from'../_shared/property-video-kie.ts';
import{assert}from'../_shared/http.ts';
import{hash}from'../property-video-jobs/runtime.ts';
import{retainAcceptedKieReceipt}from'../ai-video/index.ts';
export const RETENTION_DIRECTIVE_KEY='property_video_accepted_result_retention';
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const KEYS='action,actor_id,approved_at,attempt_id,expires_at,id,job_id,library_org_id,listing_id,manifest_sha256,operation_id,org_id,profile,provider_request_id,receipt_sha256,request_key,schema,source_position,state';
type Row=Record<string,any>;
export function approvedRetentionDirective(value:unknown,now=Date.now()):value is Row{
 if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).sort().join(',')!==KEYS)return false;
 const d=value as Row,a=Date.parse(d.approved_at),e=Date.parse(d.expires_at);
 return d.schema===1&&d.action==='retain_existing_paid_kie_result'&&d.state==='approved'
  &&['id','job_id','operation_id','actor_id','org_id','library_org_id','listing_id','attempt_id'].every(k=>typeof d[k]==='string'&&UUID.test(d[k]))
  &&d.profile===KIE_PROPERTY_PROFILE&&Number.isSafeInteger(d.source_position)&&d.source_position>=0&&d.source_position<100
  &&d.request_key==='bgvideo:'+d.attempt_id&&typeof d.provider_request_id==='string'&&/^[A-Za-z0-9._:-]{1,200}$/.test(d.provider_request_id)
  &&typeof d.manifest_sha256==='string'&&/^[a-f0-9]{64}$/.test(d.manifest_sha256)&&typeof d.receipt_sha256==='string'&&/^[a-f0-9]{64}$/.test(d.receipt_sha256)
  &&typeof d.approved_at==='string'&&typeof d.expires_at==='string'&&Number.isFinite(a)&&Number.isFinite(e)&&a<=now&&now<e&&e>a&&e-a<=600000;
}
export async function stoppedRetentionScope(d:Row,j:Row,s:Row,origin:string){
 assert(approvedRetentionDirective(d),409,'The accepted-result directive is not current.');
 assert(j&&s&&j.id===d.job_id&&j.operation_id===d.operation_id&&j.actor_id===d.actor_id&&j.org_id===d.org_id&&j.library_org_id===d.library_org_id&&j.listing_id===d.listing_id
  &&j.state==='failed'&&j.cancelled_at===null&&j.quality_profile===d.profile&&j.manifest_sha256===d.manifest_sha256
  &&kiePropertyIdentityConsistent()&&!!registeredPropertyPromptIdentity(j.quality_identity),409,'The stopped video recipe differs from its exact directive.');
 const r=s.receipt,m=j.manifest?.sources?.[d.source_position];
 assert(s.job_id===j.id&&s.position===d.source_position&&s.attempt_id===d.attempt_id&&s.request_key===d.request_key&&s.state==='processing'&&s.clip===null
  &&typeof s.provider_terminal_at==='string'&&Number.isFinite(Date.parse(s.provider_terminal_at))&&typeof s.generation_provenance_id==='string'&&UUID.test(s.generation_provenance_id)
  &&m&&m.photo_id===s.photo_id&&m.photo_asset_id===s.asset_id&&(m.photo_version_id??null)===(s.version_id??null)&&(m.photo_provenance_id??null)===(s.photo_provenance_id??null)&&m.motion===s.motion,
 409,'The stopped accepted source differs from its exact directive.');
 assert(r&&typeof r==='object'&&!Array.isArray(r)&&Object.keys(r).sort().join(',')==='model_id,request_id,response_url,seconds,status_url'
  &&r.request_id===d.provider_request_id&&r.model_id===KIE_PROPERTY_IDENTITY.model&&r.seconds===5&&r.response_url===r.status_url&&typeof r.status_url==='string'&&r.status_url.length<=8192,409,'The saved accepted receipt differs from its directive.');
 const url=new URL(r.status_url);assert(url.origin===assertPublicSupabaseOrigin(origin)&&url.pathname==='/functions/v1/ai-video/status'&&!url.username&&!url.password&&!url.hash&&[...url.searchParams.keys()].join(',')==='job'&&!!url.searchParams.get('job'),403,'Use this server-owned accepted receipt.');
 assert(await hash(new TextEncoder().encode(r.status_url))===d.receipt_sha256,409,'The saved accepted receipt fingerprint changed.');
 return{actor:j.actor_id,org:j.org_id,library:j.library_org_id,listing:j.listing_id,attempt:s.attempt_id,requestKey:s.request_key,providerRequest:r.request_id,statusUrl:r.status_url};
}
/** Existing service-authenticated queue is the only production caller. Approved
 * JSONB equality CAS consumes one directive before provider access. No retries:
 * a lost/unknown outcome stays started; an explicit failure stays held. */
export async function consumeAcceptedResultRetention(){
 const admin=adminClient();const found=await admin.from('app_config').select('value').eq('key',RETENTION_DIRECTIVE_KEY).maybeSingle();
 if(found.error||!approvedRetentionDirective(found.data?.value))return;
 const d=found.data.value;const started={...d,state:'started',started_at:new Date().toISOString()};
 const claimed=await admin.from('app_config').update({value:started}).eq('key',RETENTION_DIRECTIVE_KEY).eq('value',JSON.stringify(d)).select('value').maybeSingle();
 if(claimed.error||!sameJsonValue(claimed.data?.value,started))return;
 let outcome:Row;
 try{
  const job=await admin.from('property_video_jobs').select('*').eq('id',d.job_id).maybeSingle();
  const source=await admin.from('property_video_job_sources').select('*').eq('job_id',d.job_id).eq('attempt_id',d.attempt_id).maybeSingle();
  assert(!job.error&&!source.error,503,'The stopped source could not be read.');
  const scope=await stoppedRetentionScope(d,job.data,source.data,Deno.env.get('SUPABASE_URL')??'');
  const result=await retainAcceptedKieReceipt(scope);
  outcome=result.status==='retained'?{state:'retained',asset_key:result.asset_key,quality_accepted:false}:{state:'held',code:result.status==='pending'?'supplier_not_terminal':'supplier_failed'};
 }catch{outcome={state:'held',code:'retention_not_verified'};}
 const final={...started,...outcome,finished_at:new Date().toISOString()};
 // No overwrite after any external configuration change, even by an owner.
 await admin.from('app_config').update({value:final}).eq('key',RETENTION_DIRECTIVE_KEY).eq('value',JSON.stringify(started)).select('value').maybeSingle();
}
