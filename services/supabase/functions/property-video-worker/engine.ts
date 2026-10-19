import {PROPERTY_VIDEO_STEADY_PROFILE} from "../ai-video/property-video-quality.ts";
import{KIE_PROPERTY_PROFILE,kieProperty4KFacts}from'../_shared/property-video-kie.ts';
import{assert,HttpError}from'../_shared/http.ts';
import{validatePhotoInput}from'../ai-photo/input-policy.ts';
import{driftLineageKey}from'../_shared/drift.ts';
import{adminClient}from'../_shared/supabase.ts';
import{handleAiVideo,type AiVideoWorkerScope}from'../ai-video/index.ts';
import{probeRetainedProviderMP4Video}from'../ai-video/mp4video.ts';
import{presignGet}from'../_shared/providers/common.ts';
import{headObject,R2_BUCKET_RENDERS}from'../_shared/r2.ts';
import{rpc,bucket,bytesFrom,base64}from'../property-video-jobs/runtime.ts';
import type{WorkerAction,ComposeAction}from'../property-video-jobs/contracts.ts';
import{temporalReport,temporalRequired,temporalRoute,temporalTask}from'./temporal.ts';
const seconds=(n:number)=>new Date(Date.now()+n*1000).toISOString();
export async function scope(job:string,lease:string,attempt?:string){return await rpc('property_video_job_worker_scope',{p_job:job,p_lease:lease,p_attempt:attempt??null});}
// kieDispatchAuthority: ai-video calls it at the prospective Kie POST boundary,
// after preparation and reservation. SQL re-checks this lease/attempt, the frozen recipe,
// the saved processor permission and any owner quality-test grant (one create per attempt);
// its RPnnn refusal maps through rpc() -> throwRpc to the same HTTP status.
async function aiScope(ctx:any):Promise<AiVideoWorkerScope>{const j=ctx.job,s=ctx.source;return{user:{id:j.actor_id,is_anonymous:false},listing:j.listing_id,targetAspect:j.manifest.aspect,qualityProfile:j.quality_profile??'legacy',qualityIdentity:j.quality_identity??null,accepted:async accepted=>{await rpc('property_video_job_receipt',{p_job:j.id,p_attempt:s.attempt_id,p_receipt:accepted});},authorize:async()=>{await scope(j.id,s.lease_token,s.attempt_id);},kieDispatchAuthority:async()=>{
 const evidence=await rpc('property_video_kie_dispatch_authority',{p_job:j.id,p_lease:s.lease_token,p_attempt:s.attempt_id});
 const object=evidence&&typeof evidence==='object'&&!Array.isArray(evidence);
 const keys=object?Object.keys(evidence).sort().join(','):'';
 const activated=object&&evidence.authority==='activated_profile'&&keys==='attempt_id,authority,job_id'&&evidence.job_id===j.id;
 const owner=object&&evidence.authority==='owner_quality_test'&&keys==='attempt_id,authority,cents_used,creates_used,grant_id,replayed'
  &&typeof evidence.grant_id==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(evidence.grant_id)
  &&typeof evidence.replayed==='boolean'&&Number.isSafeInteger(evidence.creates_used)&&evidence.creates_used>=1&&evidence.creates_used<=20
  &&Number.isFinite(evidence.cents_used)&&Number.isFinite(j.quality_identity?.attempt_cents)
  &&evidence.cents_used===evidence.creates_used*j.quality_identity.attempt_cents;
 assert(object&&evidence.attempt_id===s.attempt_id&&(activated||owner),503,'The video dispatch permission could not be confirmed. No generation was sent.');
 return evidence;
},provenance:async args=>{const found=await adminClient().from('app_video_cost_reservations').select('provider_request_id,model').eq('actor_id',j.actor_id).eq('org_id',j.org_id).eq('idempotency_key',s.request_key).maybeSingle();assert(!found.error&&found.data?.provider_request_id,503,'Accepted payment recovery is pending.');const p=await rpc('property_video_job_provenance',{p_job:j.id,p_attempt:s.attempt_id,p_request:found.data.provider_request_id,p_model:found.data.model});return{id:p.id,recorded:true,disclosure:p.disclosure};}};}
async function callAI(ctx:any,method:string,path:string,body?:unknown){const req=new Request('https://functions.rendprop.invalid/ai-video/'+path,{method,headers:{'x-org-id':ctx.job.library_org_id,'idempotency-key':ctx.source.request_key,'content-type':'application/json'},...(body!==undefined?{body:JSON.stringify(body)}:{})});const response=await handleAiVideo(req,await aiScope(ctx));const value=await response.json();return{status:response.status,value};}
async function fail(ctx:any,code:string,ambiguous=false){await rpc('property_video_job_failure',{p_job:ctx.job.id,p_lease:ctx.source.lease_token,p_attempt:ctx.source.attempt_id,p_code:code,p_ambiguous:ambiguous});}
export async function dispatch(ctx:any){const j=ctx.job,s=ctx.source;let entered=false;try{const{bytes}=await bytesFrom(s.source);const info=validatePhotoInput(base64(bytes),s.source.content_type);assert(Math.max(info.width,info.height)<=2048,409,'Prepare this exact photo within the video input geometry before generating.');await scope(j.id,s.lease_token,s.attempt_id);entered=true;const out=await callAI(ctx,'POST','reel-clip',{image_b64:base64(bytes),mime:s.source.content_type,listing_id:j.listing_id,source_asset_id:s.asset_id,source_provenance_id:s.photo_provenance_id,seconds:5,preset_version:1,framing:'preserve_photo',aspect:j.manifest.aspect,motion:s.motion});
 if(out.status===202&&out.value.request_id)return;const accepted=await adminClient().from('property_video_job_sources').select('receipt').eq('job_id',j.id).eq('attempt_id',s.attempt_id).maybeSingle();if(!accepted.error&&accepted.data?.receipt)return;const paid=await adminClient().from('app_video_cost_reservations').select('released_at').eq('actor_id',j.actor_id).eq('org_id',j.org_id).eq('idempotency_key',s.request_key).maybeSingle();const ambiguous=!!paid.error||!!paid.data&&!paid.data.released_at;await fail(ctx,!ambiguous&&[402,429].includes(out.status)?'capacity_before_dispatch':'provider_submit_refused',ambiguous);
 }catch(error){const accepted=await adminClient().from('property_video_job_sources').select('receipt').eq('job_id',j.id).eq('attempt_id',s.attempt_id).maybeSingle();if(!accepted.error&&accepted.data?.receipt)return;await fail(ctx,entered?'provider_acceptance_unconfirmed':'source_unavailable',entered);}}
export type PropertyVideoPollPhase='receipt'|'provider_status'|'status_response'|'private_output'|'clip_head'|'clip_url'|'mp4_probe'|'clip_bytes'|'paid_receipt'|'provenance'|'source_bytes'|'source_lineage'|'fresh_scope'|'clip_commit'|'poll_release';
/** The poll's one bounded read of a retained generated clip (bytes). */
export const PROPERTY_VIDEO_CLIP_READ_BYTES=64*1024*1024;
/** Closed operational facts only: never a provider body, URL, token or ID. */
export function propertyVideoPollDiagnostic(phase:PropertyVideoPollPhase,error:unknown){
 const name=error instanceof Error?error.name:'';
 return{event:'property_video_poll_failure',phase,error_name:['HttpError','TypeError','RangeError','SyntaxError','TimeoutError','AbortError','Error'].includes(name)?name:'Other',http_status:error instanceof HttpError&&Number.isInteger(error.status)&&error.status>=400&&error.status<=599?error.status:null};
}
export async function poll(ctx:any){
 // A saved Kie job never enters FAL result recovery and never trusts a provider
 // echo (mode/resolution/duration): only actual probed MP4 facts decide below.
 const j=ctx.job,s=ctx.source,kie=j.quality_profile===KIE_PROPERTY_PROFILE;let phase:PropertyVideoPollPhase='receipt';
 try{
  assert(s.receipt?.status_url,503,'Saved video receipt is unavailable.');
  const link=new URL(s.receipt.status_url);assert(link.searchParams.has('job'),403,'Use the server-owned signed provider receipt.');
  phase='provider_status';const out=await callAI(ctx,'GET','status?'+link.searchParams.toString());
  const issue=out.value.delivery_issue;
  if(!kie&&out.status===200&&out.value.status==='processing'&&issue?.phase==='status_and_result_read'&&issue.provider==='fal'&&issue.provider_state==='unavailable'&&issue.provider_status===404&&issue.result_status===404&&issue.reason==='not_found'){
   await rpc('property_video_job_result_missing',{p_job:j.id,p_lease:s.lease_token,p_attempt:s.attempt_id});return;
  }
  if(!kie&&out.status===200&&out.value.status==='processing'&&issue?.phase==='result_read'&&issue.provider==='fal'&&issue.provider_state==='completed'&&issue.provider_status===403&&['balance_exhausted','account_locked','auth','permission','unknown'].includes(issue.reason)){
   await rpc('property_video_job_result_read_failure',{p_job:j.id,p_lease:s.lease_token,p_attempt:s.attempt_id,p_reason:issue.reason});return;
  }
  if(out.status!==200||out.value.status==='processing'){
   if(out.status!==200)console.warn(JSON.stringify(propertyVideoPollDiagnostic('status_response',new HttpError(out.status,'Provider status is unavailable.'))));
   await rpc('property_video_job_poll_release',{p_job:j.id,p_lease:s.lease_token,p_attempt:s.attempt_id});return;
  }
  // Kie: a completed result that could never be retained (image extension, over the
  // persist limit) is the same terminal unverifiable outcome as the stored-object gate below.
  if(out.value.status==='failed'){await fail(ctx,out.value.error_class==='nsfw'?'provider_safety_refused':kie&&out.value.result_unretainable===true?'source_video_unverifiable':'provider_terminal_failed');return;}
  phase='status_response';assert(out.value.status==='completed'&&out.value.persisted===true&&typeof out.value.asset_key==='string',503,'Completed private media could not be retained.');
  phase='private_output';const saved=await adminClient().from('private_ai_outputs').select('storage_key,bytes').eq('org_id',j.org_id).eq('user_id',j.actor_id).eq('listing_id',j.listing_id).eq('bucket','renders').eq('storage_key',out.value.asset_key).maybeSingle();
  assert(!saved.error&&saved.data,503,'The generated clip is not owned by this property.');
  phase='clip_head';const h=await headObject(R2_BUCKET_RENDERS,saved.data.storage_key,AbortSignal.timeout(10000));
  // Kie: the retained object exists unchanged (same bytes, an etag) yet can never
  // pass this poll: a stored type other than video/mp4, or more bytes than its
  // bounded read. Terminal below, before any byte is read, instead of re-polling
  // to the deadline in a supplier slot. A missing or changed object and transport
  // errors keep the retry loop; FAL and legacy profiles are unchanged.
  const unreadable=kie&&h.exists&&h.bytes===saved.data.bytes&&!!h.etag&&(h.contentType!=='video/mp4'||saved.data.bytes>PROPERTY_VIDEO_CLIP_READ_BYTES);
  assert(unreadable||h.exists&&h.bytes===saved.data.bytes&&h.etag&&h.contentType==='video/mp4',503,'The generated clip bytes could not be verified.');
  const clip={bucket:'renders',storage_key:saved.data.storage_key,bytes:saved.data.bytes,etag:h.etag,content_type:'video/mp4'};
  phase='paid_receipt';const paid=await adminClient().from('app_video_cost_reservations').select('provider_request_id,model').eq('actor_id',j.actor_id).eq('org_id',j.org_id).eq('idempotency_key',s.request_key).maybeSingle();
  assert(!paid.error&&paid.data&&paid.data.provider_request_id===s.receipt.request_id,503,'Accepted video payment recovery is pending.');
  if(unreadable){await fail(ctx,'source_video_unverifiable');return;}
  phase='clip_url';const signed=await presignGet(R2_BUCKET_RENDERS,clip.storage_key,300);
  phase='mp4_probe';const facts=await probeRetainedProviderMP4Video(signed,fetch);
  const[w,ht]=j.manifest.aspect==='16:9'?[1920,1080]:[1080,1920];
  if(j.quality_profile===PROPERTY_VIDEO_STEADY_PROFILE&&(facts.fps!==24||![120,121].includes(Math.round(facts.duration_s*24)))){await fail(ctx,'source_video_unverifiable');return;}
  // Native 4K, CFR24, 120/121 frames from the probe alone; a substituted Pro-tier
  // clip is a terminal unverifiable result, never a commit or another paid attempt.
  if(kie&&!kieProperty4KFacts(facts)){await fail(ctx,'source_video_unverifiable');return;}
  if(facts.width<w||facts.height<ht||Math.abs(facts.duration_s-5)>.1){await fail(ctx,'source_quality_below_1080');return;}
  phase='clip_bytes';const observed=await bytesFrom(clip,PROPERTY_VIDEO_CLIP_READ_BYTES);
  phase='provenance';const prov=await rpc('property_video_job_provenance',{p_job:j.id,p_attempt:s.attempt_id,p_request:s.receipt.request_id,p_model:paid.data.model});
  phase='source_bytes';const input=await bytesFrom(s.source);
  phase='source_lineage';await rpc('bind_property_video_source',{p_actor:j.actor_id,p_listing:j.listing_id,p_asset:s.asset_id,p_photo_provenance:s.photo_provenance_id,p_request:s.receipt.request_id,p_generation_provenance:prov.id,p_sha256:input.sha256,p_qc_hash:await driftLineageKey(base64(input.bytes))});
  phase='fresh_scope';await scope(j.id,s.lease_token,s.attempt_id);
  phase='clip_commit';await rpc('property_video_job_clip',{p_job:j.id,p_attempt:s.attempt_id,p_clip:{...clip,sha256:observed.sha256,width:facts.width,height:facts.height,duration_s:facts.duration_s}});
  phase='poll_release';await rpc('property_video_job_poll_release',{p_job:j.id,p_lease:s.lease_token,p_attempt:s.attempt_id});
 }catch(error){
  console.warn(JSON.stringify(propertyVideoPollDiagnostic(phase,error)));
  // A400 is deterministic unsupported/malformed owned MP4 metadata. Do not
  // relabel it as an hour of provider processing or buy another generation.
  // Timeouts/changed ranges409 and transport failures keep the accepted receipt.
  if(phase==='mp4_probe'&&error instanceof HttpError&&error.status===400){await fail(ctx,'source_video_unverifiable');return;}
  await rpc('property_video_job_poll_release',{p_job:j.id,p_lease:s.lease_token,p_attempt:s.attempt_id}).catch(()=>{});
 }
}
export async function quality(ctx:any,raw:any){const j=ctx.job,s=ctx.source;assert(raw.clip_sha256===s.clip?.sha256&&Array.isArray(raw.frames)&&raw.frames.length===3,409,'Use the retained generated clip and all three review frames.');
 // Steady profiles: the CPU's temporal motion report (temporal.ts) is verified
 // against this limit version and recorded on the shot BEFORE the paid drift
 // judge. A HOLD is the existing CPU review pause (cpu_extract_failed): two more
 // immediate extracts, then the job pauses as a resumable quality pause with its
 // paid clip retained and the verdict recorded. Never a pass, never a purchase.
 if(temporalRequired(j.quality_profile)){const report=temporalReport(raw.temporal);
  if(!report){await fail(ctx,'cpu_extract_failed',false);return;}
  // The recorded verdict decides (first measurement of this attempt under this limit version wins; SQL returns it on a repeat).
  const recorded=temporalReport(await rpc('property_video_job_temporal',{p_job:j.id,p_lease:s.lease_token,p_attempt:s.attempt_id,p_clip_sha256:raw.clip_sha256,p_report:report}));
  assert(recorded,503,'The recorded temporal verdict could not be read.');const route=temporalRoute(recorded.verdict);
  // Not a still-photo substitution: with no paid structural drift rejection,
  // property_video_job_failure makes this the resumable quality pause (paid clip
  // retained) and property_video_fallback_source_guard refuses original_photo.
  if(route==='refuse'){await fail(ctx,'quality_check_refused',false);return;}
  // FOLLOW-UP (V2 retry routing): the single paid retry, property_video_job_quality_retry
  // (20261015040518), is granted only on a persisted paid DRIFT verdict
  // (property_video_quality_retry_evidence). A temporal-only bob/sway/cadence
  // failure has no such grant yet, so it holds here with its verdict recorded
  // instead of buying a retry or publishing; see quality.test.ts (ignored case).
  if(route==='retry'){await fail(ctx,'cpu_extract_failed',false);return;}
 }
 const{bytes}=await bytesFrom(s.source);const frames=raw.frames.map((frame:any,i:number)=>{assert(frame&&typeof frame.image_b64==='string'&&frame.image_b64.length<=524288&&frame.mime==='image/jpeg',400,'Use bounded actual JPEG review frames.');return{at:['first','middle','last'][i],b64:frame.image_b64,mime:frame.mime};});const out=await callAI(ctx,'POST','drift',{request_id:s.receipt.request_id,kind:'reel',source_b64:base64(bytes),source_mime:s.source.content_type,frames,seconds:5,motion:s.motion,listing_id:j.listing_id,asset_id:s.asset_id,provenance_id:s.generation_provenance_id,attempt:(s.quality_retries??0)>0?1:0});
 if(out.status===200&&out.value.drift?.action==='accept'&&out.value.drift.publishable===true){await rpc('property_video_job_qc',{p_job:j.id,p_lease:s.lease_token,p_attempt:s.attempt_id});return;}
 // The drift gate's single paid retry grant is not a pass or a still fallback.
 // SQL verifies its persisted paid verdict and archives the superseded attempt
 // before one new normal dispatch; an HTTP retry cannot mint another grant.
 if(out.status===200&&out.value.drift?.action==='retry'&&out.value.drift.publishable===false){const next=await rpc('property_video_job_quality_retry',{p_job:j.id,p_lease:s.lease_token,p_attempt:s.attempt_id});assert(next?.retry_scheduled===true,503,'The saved safe retry could not be scheduled.');return;}
 await fail(ctx,out.status>=500?'quality_check_unconfirmed':'quality_check_refused',out.status>=500);}
async function media(c:any,ttl=600){return{url:await presignGet(bucket(c.bucket),c.storage_key,ttl),sha256:c.sha256,bytes:c.bytes,etag:c.etag};}
export async function action(ctx:any):Promise<WorkerAction>{const j=ctx.job,s=ctx.source;
 // Both steady profiles reuse the renderer's exact native-24 strict-CFR contract.
 const steady=j.quality_profile===PROPERTY_VIDEO_STEADY_PROFILE||j.quality_profile===KIE_PROPERTY_PROFILE;
 if(ctx.action==='inspect_audio'){await scope(j.id,j.audio_lease);let c:any;if(j.manifest.narration_asset_id){const n=await adminClient().from('property_video_audio_assets').select('*').eq('id',j.manifest.narration_asset_id).eq('actor_id',j.actor_id).eq('listing_id',j.listing_id).eq('state','ready').maybeSingle();assert(!n.error&&n.data,409,'Saved narration is unavailable.');c={bucket:'renders',storage_key:n.data.storage_key,bytes:n.data.bytes,sha256:n.data.sha256,etag:n.data.etag,content_type:n.data.mime};await bytesFrom(c,20*1024*1024);}else{const n=await adminClient().from('studio_creative_results').select('*').eq('id',j.manifest.narration_result_id).eq('user_id',j.actor_id).eq('listing_id',j.listing_id).eq('kind','voice').maybeSingle();assert(!n.error&&n.data,409,'Saved AI narration is unavailable.');const h=await headObject(bucket(n.data.bucket),n.data.storage_key,AbortSignal.timeout(10000));assert(h.exists&&h.bytes&&h.etag,409,'Saved AI narration is unavailable.');c={bucket:n.data.bucket,storage_key:n.data.storage_key,bytes:h.bytes,etag:h.etag,content_type:h.contentType};const observed=await bytesFrom(c,20*1024*1024);c.sha256=observed.sha256;}await rpc('property_video_job_audio_source',{p_job:j.id,p_lease:j.audio_lease,p_source:c});const transition=j.manifest.presentation?.transition,fps=steady?24:30,joinFrames=transition==='dissolve'?(steady?6:8):transition==='whip'?(steady?4:5):0;return{job_id:j.id,state:'queued',action:'inspect_audio',lease_token:j.audio_lease,manifest_sha256:j.manifest_sha256,source:await media(c),max_duration_s:5*j.source_count-(j.source_count-1)*joinFrames/fps,expires_at:seconds(240)};}

 if(ctx.action==='extract_frames'){await scope(j.id,s.lease_token,s.attempt_id);return{job_id:j.id,state:'quality_review',action:'extract_frames',attempt_id:s.attempt_id,lease_token:s.lease_token,source:{...await media(s.source),asset_id:s.asset_id},clip:await media(s.clip),...temporalTask(j.quality_profile,j.manifest.aspect),expires_at:seconds(240)};}
 if(ctx.action==='compose'){await scope(j.id,j.compose_lease);const m=j.manifest;let narration:any=null,music:any=null;
 if(m.narration_asset_id){const n=await adminClient().from('property_video_audio_assets').select('*').eq('id',m.narration_asset_id).eq('actor_id',j.actor_id).eq('listing_id',j.listing_id).eq('state','ready').maybeSingle();assert(!n.error&&n.data,409,'Saved narration is unavailable.');narration={...await media({...n.data,bucket:'renders'},1800),words:m.narration_words??[],kind:'own'};}
 if(m.narration_result_id){const n=await adminClient().from('studio_creative_results').select('*').eq('id',m.narration_result_id).eq('user_id',j.actor_id).eq('listing_id',j.listing_id).eq('kind','voice').maybeSingle();assert(!n.error&&n.data,409,'Saved AI narration is unavailable.');const h=await headObject(bucket(n.data.bucket),n.data.storage_key,AbortSignal.timeout(10000));assert(h.exists&&h.bytes&&h.etag,409,'Saved AI narration bytes are unavailable.');const c={bucket:n.data.bucket,storage_key:n.data.storage_key,bytes:h.bytes,etag:h.etag,content_type:h.contentType};const observed=await bytesFrom(c,20*1024*1024);narration={...await media({...c,sha256:observed.sha256},1800),words:n.data.metadata?.words??[],kind:'ai'};}
 if(m.music){const n=await adminClient().from('property_video_music_catalog').select('*').eq('track_id',m.music.track_id).eq('enabled',true).maybeSingle();assert(!n.error&&n.data&&n.data.sha256===m.music.asset_sha256&&n.data.license_evidence_sha256===m.music.license_evidence_sha256,409,'The licensed soundtrack is unavailable.');music={...await media({...n.data,bucket:'renders'},1800),...m.music,license_revision:n.data.license_evidence_sha256,credit:n.data.credit};}
 const sources=[];for(const row of ctx.sources){const original=row.state==='original_photo';let fullSource=row.source;if(original){const prepared=await adminClient().from('property_video_preparations').select('id').eq('asset_id',row.asset_id).eq('actor_id',j.actor_id).eq('listing_id',j.listing_id).eq('state','ready').maybeSingle();assert(!prepared.error,503,'The selected original master could not be read.');if(prepared.data){const p=await rpc('property_video_preparation_scope',{p_id:prepared.data.id,p_actor:j.actor_id});fullSource=p.original_source;}}sources.push({...await media(original?fullSource:row.clip,1800),position:row.position,motion_kind:original?'original_photo':'ai',motion:row.motion});}
 return{job_id:j.id,state:'composing',action:'compose',lease_token:j.compose_lease,manifest_sha256:j.manifest_sha256,purpose:m.purpose,aspect:m.aspect,...(steady?{composition_profile:'steady-v2-cfr24' as const}:{}),sources,narration,music,presentation:m.presentation,output:{asset_id:j.output_asset_id,key:`renders/${j.org_id}/${j.listing_id}/background/${j.id}/${j.compose_lease}/master.mp4`,poster_asset_id:j.poster_asset_id,poster_key:`renders/${j.org_id}/${j.listing_id}/background/${j.id}/${j.compose_lease}/first-clip.jpg`},expires_at:seconds(1800)}as ComposeAction;}
 return{job_id:j.id,state:j.state,action:['ready','cancelled','failed','needs_reconciliation'].includes(j.state)?'done':'wait'};
}
