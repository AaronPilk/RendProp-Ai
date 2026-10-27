import{aerialPublic}from'./aerial-public.ts';
import{PHOTO_MOTION_MODE}from'../_shared/photo-motion.ts';
import{propertyVideoPromptQuote}from'./prompt-admission.ts';
import{privatePreparationPublic}from'./private-prepared.ts';
import{corsHeaders}from'../_shared/cors.ts';
const jobCors={...corsHeaders,'Access-Control-Allow-Headers':corsHeaders['Access-Control-Allow-Headers']+', x-rendprop-ai-consent, x-rendprop-ai-consent-disclosure, x-rendprop-quality-test-grant, x-rendprop-photo-motion-quote','Access-Control-Allow-Methods':'GET, POST, PUT, OPTIONS'};
import{assert,HttpError,json,pathSegments,readJsonLimited,respondError,throwRpc}from'../_shared/http.ts';
import{adminClient,assertNotDeleting,contentOrgForUser,getUser,preferredOrg}from'../_shared/supabase.ts';
import{putCapability}from'./storage.ts';
import{selectedSources,pastJobs,operationJob,abandonOperation}from'./selected.ts';
import{selectedVideoDownload}from'./selected-download.ts';
import{savedVersionSources}from'./saved-versions.ts';
import{privateMediaUrl}from'../_shared/private-media.ts';
import{withVisibleMedia}from'../_shared/media-source-access.ts';
import{propertyVideoRecipeQuote}from'../ai-video/index.ts';
import{admitFundedReelRecipe}from'../ai-video/reel-provider-admission.ts';
import{KIE_PROPERTY_PROFILE}from'../_shared/property-video-kie.ts';
import{preparationPublic}from'./prepared.ts';
import{completeAudio,uploadAudio}from'./audio.ts';
import{jobInput,audioInput,uuid}from'./input.ts';
import{admissionJobInput}from'./variety.ts';
import{ownedHead,rpc,reply,cpuRecoverable,qualityResumeAvailable,deliveryResumeAvailable,composeResumeAvailable,sourceReadResumeProof,terminalTemporalResumeBlocked,TERMINAL_TEMPORAL_ATTENTION}from'./runtime.ts';
import{preflightSourceReadRecovery}from'./source-read-recovery.ts';
// AI processor permission. v1 is the original permission (legacy/FAL work and its frozen
// recovery). v2 names the published processor disclosure revision the user accepted; a
// native-4K Kie video needs the current one. These are fast, clear refusals only:
// property_video_job_admit_v2 re-enforces every rule in SQL and persists the permission.
const CONSENT_V1='property-video-jobs-v1',CONSENT_V2='property-video-jobs-v2';
type AiConsent={token:typeof CONSENT_V1}|{token:typeof CONSENT_V2;disclosure_revision:string};
function aiConsent(req:Request):AiConsent|null{const token=req.headers.get('x-rendprop-ai-consent'),revision=req.headers.get('x-rendprop-ai-consent-disclosure');if(token===CONSENT_V1)return{token:CONSENT_V1};if(token===CONSENT_V2&&revision!==null&&/^[!-~]{1,200}$/.test(revision))return{token:CONSENT_V2,disclosure_revision:revision};return null;}
// Owner-only quality test (optional). SQL pins its actor, listing, sources, expiry and budget.
function qualityTestGrant(req:Request):string|null{const raw=req.headers.get('x-rendprop-quality-test-grant');if(raw===null)return null;assert(/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(raw),400,'Use a valid owner quality-test permission.');return raw.toLowerCase();}
/** The published processor disclosure contract, or null while none is published. */
async function processorConsentCurrent():Promise<{token:string;disclosure_revision:string;processors:string[];profiles:string[]}|null>{const{data,error}=await adminClient().rpc('property_video_processor_consent_current',{});if(error)throwRpc(error.message);const c:any=data;return c&&typeof c==='object'&&c.token===CONSENT_V2&&typeof c.disclosure_revision==='string'&&Array.isArray(c.processors)&&Array.isArray(c.profiles)?{token:c.token,disclosure_revision:c.disclosure_revision,processors:c.processors,profiles:c.profiles}:null;}
/** Kie always needs the current v2 permission; any v2 must name the current disclosure. */
async function processorConsentRefusal(consent:AiConsent,kie:boolean,context:Record<string,unknown>):Promise<Response|null>{
 if(!kie&&consent.token!==CONSENT_V2)return null;
 const current=await processorConsentCurrent(),headers={'cache-control':'no-store'};
 if(!current)return json({error:'The AI processor disclosure for this video is not published yet. No video was created.',code:'processor_disclosure_unpublished',...context},403,headers);
 if(consent.token===CONSENT_V2&&consent.disclosure_revision===current.disclosure_revision)return null;
 return json({error:consent.token===CONSENT_V1?'Allow the listed AI processors for this native-4K video before creating it.':'Allow the current AI processor disclosure before creating this video.',code:'processor_consent_required',...context,processor_consent:{token:current.token,disclosure_revision:current.disclosure_revision,processors:current.processors}},403,headers);
}
export async function handler(req:Request):Promise<Response>{if(req.method==='OPTIONS')return new Response('ok',{headers:jobCors});try{
 const user=await getUser(req);assert(user.is_anonymous===false,403,'Sign in to your own account before creating a video.');const seg=pathSegments(req,'property-video-jobs');const aerial=await aerialPublic(req,user.id,seg);if(aerial)return aerial;const chosen=await privatePreparationPublic(req,user.id,seg);if(chosen)return chosen;const prepared=await preparationPublic(req,user.id,seg);if(prepared)return prepared;
 if(req.method==='GET'&&seg.join('/')==='sources/versions'){
  const q=new URL(req.url).searchParams;assert([...q.keys()].every(k=>['listing_id','expected_org_id','offset'].includes(k)&&q.getAll(k).length===1),400,'Use one exact saved-photo catalog page.');
  const listing=uuid(q.get('listing_id')),expected=uuid(q.get('expected_org_id')??preferredOrg(req)),value=q.get('offset')??'0';assert(/^(0|[1-9][0-9]{0,4})$/.test(value)&&Number(value)<=10000&&(!preferredOrg(req)||preferredOrg(req)===expected),400,'Keep the saved-photo page and selected library.');
  return json(await savedVersionSources(user.id,listing,expected,Number(value),{db:adminClient(),scope:contentOrgForUser,rpc,head:ownedHead,preview:s=>withVisibleMedia(adminClient(),s.listing,{assets:[s.asset_id],keys:[s.key]},()=>privateMediaUrl({actor:s.actor,org:s.org,listing:s.listing,bucket:s.bucket,key:s.key}))}),200,{'cache-control':'no-store'});
 }
 if(req.method==='GET'&&seg.join('/')==='selected-download'){
  const q=new URL(req.url).searchParams;
  assert([...q.keys()].length===2&&['listing_id','expected_org_id'].every(k=>q.getAll(k).length===1),400,'Choose one selected listing video.');
  const listing=uuid(q.get('listing_id')),expected=uuid(q.get('expected_org_id'));
  assert(!preferredOrg(req)||preferredOrg(req)===expected,409,'The selected library changed.');
  return json(await selectedVideoDownload(user.id,listing,expected),200,{'cache-control':'no-store'});
 }
 if(req.method==='GET'&&(seg.length===0||seg.join('/')==='sources')){const url=new URL(req.url),listing=uuid(url.searchParams.get('listing_id')),expected=uuid(url.searchParams.get('expected_org_id')??preferredOrg(req));const value=url.searchParams.get('offset')??'0';assert(/^(0|[1-9][0-9]{0,4})$/.test(value)&&Number(value)<=10000,400,'Use a bounded saved-video page.');if(!seg.length&&url.searchParams.has('operation_id'))return json(await operationJob(user.id,listing,expected,uuid(url.searchParams.get('operation_id'))),200,{'cache-control':'no-store'});return json(seg.length?await selectedSources(user.id,listing,expected,Number(value)):await pastJobs(user.id,listing,expected,Number(value)),200,{'cache-control':'no-store'});}
 // Read-only: the published processor disclosure a client shows before sending v2.
 if(req.method==='GET'&&seg.join('/')==='processor-consent'){const current=await processorConsentCurrent();if(!current)return json({error:'The AI processor disclosure is not published yet.',code:'processor_disclosure_unpublished'},404,{'cache-control':'no-store'});return json(current,200,{'cache-control':'no-store'});}
 if(req.method==='POST'&&seg.join('/')==='cancel-all'){const b=await readJsonLimited<Record<string,unknown>>(req,4096);assert(Object.keys(b).every(k=>['operation_id','reason'].includes(k))&&['ai_consent_revoked','local_data_erasure'].includes(String(b.reason)),400,'Use a saved video cancellation request.');const operation=uuid(b.operation_id);assert(req.headers.get('idempotency-key')?.toLowerCase()==='property-video-stop:'+operation,400,'Keep this saved cancellation operation identity.');return json(await rpc('property_video_job_cancel_all',{p_actor:user.id,p_operation:operation,p_reason:b.reason}));}
 // C2 discard: no AI consent or new work. The DB resolves the exact operation under its admission lock.
 if(req.method==='POST'&&seg.length===3&&seg[0]==='operations'&&seg[2]==='abandon'){const operation=uuid(seg[1]);const b=await readJsonLimited<Record<string,unknown>>(req,4096);assert(Object.keys(b).every(k=>['listing_id','expected_org_id'].includes(k)),400,'Use a saved video discard request.');const listing=uuid(b.listing_id),expected=uuid(b.expected_org_id);assert(req.headers.get('idempotency-key')?.toLowerCase()==='property-video-abandon:'+operation,400,'Keep this saved video operation identity.');assert(!preferredOrg(req)||preferredOrg(req)===expected,409,'The selected listing library changed.');return json(await abandonOperation(user.id,listing,expected,operation),200,{'cache-control':'no-store'});}
 // Exact Review quote is read-only. Both the saved source bytes and the whole
 // manifest are checked before any credit price is shown. No job or hold is
 // created here, and supplier cost is deliberately absent from the reply.
 if(req.method==='POST'&&seg.join('/')==='credit-quote'){
  const body=jobInput(await readJsonLimited<Record<string,unknown>>(req,512*1024));
  assert(body.source_mode===PHOTO_MOTION_MODE,400,'Only Photo motion has a quoted credit review.');
  assert(!preferredOrg(req)||preferredOrg(req)===body.expected_org_id,409,'The selected listing library changed.');
  await assertNotDeleting(user.id);
  await contentOrgForUser(user.id,body.expected_org_id,body.listing_id,true);
  for(const s of body.sources){const ref=await rpc('property_photo_reference',{p_actor:user.id,p_listing:body.listing_id,p_asset:s.photo_asset_id,p_provenance:s.photo_provenance_id??null});assert(ref.sha256===s.source_sha256&&ref.bytes===s.source_bytes,409,'The selected full master changed.');await ownedHead(ref);}
  if(body.opening){const org=await contentOrgForUser(user.id,body.expected_org_id,body.listing_id,true);const library=await rpc('listing_library_scope',{p_actor:user.id,p_listing:body.listing_id});assert(library&&library.org_id===org&&library.can_write===true,404,'The aerial opening property library is unavailable.');const saved=await rpc('property_video_aerial_opening_scope',{p_ref:body.opening,p_actor:user.id,p_org:org,p_selected_library:library.library_org_id,p_listing:body.listing_id,p_aspect:body.aspect});await ownedHead(saved.media);}
  return json(await rpc('credit_photo_motion_review_quote',{p_actor:user.id,p_manifest:body}),200,{'cache-control':'no-store'});
 }
 // New explicit mode has no supplier consent/planner/quote/grant. The old branch below is retained.
 if(req.method==='POST'&&seg.length===0){const raw=await readJsonLimited<Record<string,unknown>>(req.clone(),512*1024);if(Object.prototype.hasOwnProperty.call(raw,'source_mode')){
  const body=jobInput(raw);assert(body.source_mode===PHOTO_MOTION_MODE&&!req.headers.has('x-rendprop-quality-test-grant'),400,'Photo motion does not use an AI quality-test permission.');
  assert(req.headers.get('idempotency-key')?.toLowerCase()==='property-video:'+body.operation_id,400,'Keep this saved video operation identity.');assert(!preferredOrg(req)||preferredOrg(req)===body.expected_org_id,409,'The selected listing library changed.');await assertNotDeleting(user.id);await contentOrgForUser(user.id,body.expected_org_id,body.listing_id,true);
  const old=await operationJob(user.id,body.listing_id,body.expected_org_id,body.operation_id);
  if(old.job){const replay=await rpc('property_video_job_admit_photo_motion',{p_actor:user.id,p_manifest:body});assert(replay.accepted===true&&replay.job,409,'The saved Photo motion operation changed.');return json(await reply(replay.job),202,{'cache-control':'no-store'});}
  if(old.operation_closed)return json({error:old.message,code:'capacity_refused',operation_closed:true,operation_id:body.operation_id,listing_id:body.listing_id,selected_library_org_id:body.expected_org_id},402,{'cache-control':'no-store'});
  for(const s of body.sources){const ref=await rpc('property_photo_reference',{p_actor:user.id,p_listing:body.listing_id,p_asset:s.photo_asset_id,p_provenance:s.photo_provenance_id??null});assert(ref.sha256===s.source_sha256&&ref.bytes===s.source_bytes,409,'The selected full master changed.');await ownedHead(ref);}
  if(body.opening){const org=await contentOrgForUser(user.id,body.expected_org_id,body.listing_id,true);const library=await rpc('listing_library_scope',{p_actor:user.id,p_listing:body.listing_id});assert(library&&library.org_id===org&&library.can_write===true,404,'The aerial opening property library is unavailable.');const saved=await rpc('property_video_aerial_opening_scope',{p_ref:body.opening,p_actor:user.id,p_org:org,p_selected_library:library.library_org_id,p_listing:body.listing_id,p_aspect:body.aspect});await ownedHead(saved.media);}
  const creditQuote=await rpc('credit_photo_motion_review_quote',{p_actor:user.id,p_manifest:body});
  const displayed=req.headers.get('x-rendprop-photo-motion-quote');
  if(creditQuote.mode==='credits'){
   if(!displayed||displayed!==creditQuote.quote_sha256)return json({error:'The Photo motion credit quote changed. Review the exact charge again.',code:'credit_quote_changed',operation_closed:false,admission_attempted:false,operation_id:body.operation_id,listing_id:body.listing_id,selected_library_org_id:body.expected_org_id},409,{'cache-control':'no-store'});
   if(creditQuote.affordable!==true)return json({error:'Add credits before starting Photo motion.',code:'credit_balance_low',operation_closed:false,admission_attempted:false,credits:creditQuote.credits,available_credits:creditQuote.available_credits,manifest_sha256:creditQuote.manifest_sha256,operation_id:body.operation_id,listing_id:body.listing_id,selected_library_org_id:body.expected_org_id},402,{'cache-control':'no-store'});
  }else if(displayed)return json({error:'The Photo motion payment route changed. Review before creating.',code:'credit_quote_changed',operation_closed:false,admission_attempted:false,operation_id:body.operation_id,listing_id:body.listing_id,selected_library_org_id:body.expected_org_id},409,{'cache-control':'no-store'});
  let admitted;
  try { admitted=await rpc('property_video_job_admit_photo_motion_quoted',{
    p_actor:user.id,p_manifest:body,p_quote_sha256:displayed,
  }); } catch(error) {
    if(error instanceof HttpError&&error.status===409&&
      /^Photo Motion credit (quote|route) changed before admission$/.test(error.message))
      return json({error:'The Photo motion credit quote changed. Review the exact charge again.',
        code:'credit_quote_changed',operation_closed:false,admission_attempted:false,
        operation_id:body.operation_id,listing_id:body.listing_id,
        selected_library_org_id:body.expected_org_id},409,{'cache-control':'no-store'});
    throw error;
  }
  if(!admitted.accepted){const depleted=admitted.operation_closed===false&&/^RP402: Add credits before starting Photo Motion/.test(String(admitted.message));const refreshed=depleted?await rpc('credit_photo_motion_review_quote',{p_actor:user.id,p_manifest:body}):null;return json({error:depleted?'Add credits before starting Photo motion.':admitted.message,code:depleted?'credit_balance_low':'capacity_refused',operation_closed:admitted.operation_closed===true,admission_attempted:true,...(refreshed?.mode==='credits'?{credits:refreshed.credits,available_credits:refreshed.available_credits,manifest_sha256:refreshed.manifest_sha256}:{}),operation_id:body.operation_id,listing_id:body.listing_id,selected_library_org_id:body.expected_org_id},402,{'cache-control':'no-store'});}return json(await reply(admitted.job),202,{'cache-control':'no-store'});
 }}
 if(req.method==='POST'&&seg.length===2&&seg[1]==='resume'){const saved=await rpc('property_video_job_scope',{p_job:uuid(seg[0]),p_actor:user.id,p_active:false});if(saved.manifest?.source_mode===PHOTO_MOTION_MODE)return json({error:'This Photo motion request stopped. Your photos and saved files are kept. Review the setup before creating a new request.',code:'conflict',job_id:saved.id,operation_id:saved.operation_id},409,{'cache-control':'no-store'});}
 if(req.method==='POST'&&seg.length===0){const consent=aiConsent(req);assert(consent,403,'Allow AI processing of these selected photos before creating the video.','consent_required');const grant=qualityTestGrant(req);const requested=jobInput(await readJsonLimited(req,512*1024));
  // Automatic keeps the deterministic variety pass. A validated explicit camera
  // choice keeps every source move; both freeze their full request identity.
  const body=admissionJobInput(requested);assert(req.headers.get('idempotency-key')?.toLowerCase()==='property-video:'+body.operation_id,400,'Keep this saved video operation identity.');assert(!preferredOrg(req)||preferredOrg(req)===body.expected_org_id,409,'The selected listing library changed.');await assertNotDeleting(user.id);await contentOrgForUser(user.id,body.expected_org_id,body.listing_id,true);
  for(const s of body.sources)await ownedHead(await rpc('property_photo_reference',{p_actor:user.id,p_listing:body.listing_id,p_asset:s.photo_asset_id,p_provenance:s.photo_provenance_id??null}));const existing=await operationJob(user.id,body.listing_id,body.expected_org_id,body.operation_id);if(existing.job){let j;try{j=await rpc('property_video_job_enqueue',{p_actor:user.id,p_manifest:body});}catch(error){
    // A job admitted before the variety pass froze the client's exact manifest; its lost-reply replay keeps that identity.
    if(requested.motion_override!==undefined||!(error instanceof HttpError&&error.status===409&&/different saved inputs/.test(error.message)))throw error;j=await rpc('property_video_job_enqueue',{p_actor:user.id,p_manifest:requested});}
   return json(await reply(j),202,{'cache-control':'no-store'});}
  if(existing.operation_closed)return existing.closed_reason==='abandoned'?json({error:existing.message,code:'operation_abandoned',operation_closed:true,closed_reason:'abandoned',operation_id:body.operation_id,listing_id:body.listing_id,selected_library_org_id:body.expected_org_id},409,{'cache-control':'no-store'}):json({error:existing.message,code:'capacity_refused',operation_closed:true,closed_reason:'capacity_refused',operation_id:body.operation_id,listing_id:body.listing_id,selected_library_org_id:body.expected_org_id},402,{'cache-control':'no-store'});
  // An owner quality-test grant can only narrow this recipe to its exact Kie scope (SQL decides and quotes that saved profile); without one the selector path is unchanged.
  const quote=grant?await propertyVideoRecipeQuote(user.id,await contentOrgForUser(user.id,body.expected_org_id,body.listing_id,true),body.listing_id,body.aspect,body.sources.length,await rpc('property_video_quality_profile_for',{p_actor:user.id,p_manifest:body,p_grant:grant})):await propertyVideoRecipeQuote(user.id,await contentOrgForUser(user.id,body.expected_org_id,body.listing_id,true),body.listing_id,body.aspect,body.sources.length);
  const refused=await processorConsentRefusal(consent,quote.quality_profile===KIE_PROPERTY_PROFILE,{operation_id:body.operation_id,listing_id:body.listing_id,selected_library_org_id:body.expected_org_id});if(refused)return refused;
  await admitFundedReelRecipe(quote);
  const prompt=quote.quality_profile===KIE_PROPERTY_PROFILE?await propertyVideoPromptQuote(user.id,body,grant):null;
  const admission=await rpc('property_video_job_admit_v2',{p_actor:user.id,p_manifest:body,p_quote:quote.estimated_cents,p_quality_profile:prompt?.quote_profile??quote.quality_profile,p_consent:consent,p_test_grant:grant});if(!admission.accepted)return json({error:admission.message,code:'capacity_refused',operation_closed:admission.operation_closed===true,operation_id:body.operation_id,listing_id:body.listing_id,selected_library_org_id:body.expected_org_id},402,{'cache-control':'no-store'});return json(await reply(admission.job),202,{'cache-control':'no-store'});}
 if(req.method==='POST'&&seg.length===2&&seg[1]==='resume'){const token=req.headers.get('x-rendprop-ai-consent');assert(token===CONSENT_V1||token===CONSENT_V2,403,'Allow AI processing before resuming the saved video.','consent_required');const j=await rpc('property_video_job_scope',{p_job:uuid(seg[0]),p_actor:user.id,p_active:false});
  // v1 resumes only work admitted under v1 (legacy/FAL frozen recovery); a v2 (native-4K Kie) job needs v2.
  if(token===CONSENT_V1&&j.consent_revision!==CONSENT_V1)return json({error:'Allow the listed AI processors for this native-4K video before resuming it.',code:'processor_consent_required',job_id:j.id,required_consent:CONSENT_V2},403,{'cache-control':'no-store'});
  await contentOrgForUser(user.id,preferredOrg(req)??j.library_org_id,j.listing_id,true);const unfinished=await adminClient().from('property_video_job_sources').select('state,last_error,receipt,clip,generation_provenance_id,cpu_recoveries,lease_until').eq('job_id',j.id);assert(!unfinished.error,503,'Saved clips could not be read.');
  if(await terminalTemporalResumeBlocked(j))throw new HttpError(409,TERMINAL_TEMPORAL_ATTENTION,'conflict',{attention_code:'terminal_motion_quality_refused'});
  if(j.state==='failed'&&(unfinished.data??[]).some(s=>s.state==='failed'&&s.last_error==='source_unavailable')){
   const proof=await sourceReadResumeProof(j);assert(proof,409,'This saved photo read is not safely resumable.');
   const fingerprint=await preflightSourceReadRecovery(j,proof);
   const unpaid=(unfinished.data??[]).filter(s=>['pending','failed'].includes(s.state)).length,review=(unfinished.data??[]).filter(s=>!['ready','original_photo'].includes(s.state)).length;
   const q=await propertyVideoRecipeQuote(user.id,j.org_id,j.listing_id,j.manifest.aspect,Math.max(unpaid,review),j.quality_profile??'legacy');
   const estimate=q.reel_cents*unpaid/Math.max(unpaid,review)+q.qc_cents;
   await admitFundedReelRecipe(q,q.reel_cents*unpaid/Math.max(unpaid,review));
   const resumed=await rpc('property_video_job_resume_source_read',{p_actor:user.id,p_job:j.id,p_quote:estimate,p_proof_sha:fingerprint});
   return json(await reply(resumed),200,{'cache-control':'no-store'});
  }
  if((unfinished.data??[]).some(cpuRecoverable)||await qualityResumeAvailable(j)||await deliveryResumeAvailable(j)||await composeResumeAvailable(j)){const resumed=await rpc('property_video_job_resume',{p_actor:user.id,p_job:j.id,p_quote:0});return json(await reply(resumed),200,{'cache-control':'no-store'});}if(['queued','generating','quality_review','composing','ready'].includes(j.state))return json(await reply(j),200,{'cache-control':'no-store'});const unpaid=(unfinished.data??[]).filter(s=>['pending','failed'].includes(s.state)).length,review=(unfinished.data??[]).filter(s=>!['ready','original_photo'].includes(s.state)).length;assert(unpaid>0,409,'This saved work has no safely unpaid clips to resume.');const q=await propertyVideoRecipeQuote(user.id,j.org_id,j.listing_id,j.manifest.aspect,Math.max(unpaid,review),j.quality_profile??'legacy');const estimate=q.reel_cents*unpaid/Math.max(unpaid,review)+q.qc_cents;await admitFundedReelRecipe(q,q.reel_cents*unpaid/Math.max(unpaid,review));const resumed=await rpc('property_video_job_resume',{p_actor:user.id,p_job:j.id,p_quote:estimate});return json(await reply(resumed),200,{'cache-control':'no-store'});}
 if(req.method==='GET'&&seg.length===1)return json(await reply(await rpc('property_video_job_scope',{p_job:uuid(seg[0]),p_actor:user.id,p_active:false})),200,{'cache-control':'no-store'});
 if(req.method==='POST'&&seg.length===2&&seg[1]==='cancel'){const job=uuid(seg[0]);await rpc('property_video_job_cancel',{p_actor:user.id,p_job:job});await rpc('credit_photo_motion_reconcile',{p_job:job}).catch(()=>{});return json(await reply(await rpc('property_video_job_scope',{p_job:job,p_actor:user.id,p_active:false})));}
 if(req.method==='POST'&&seg.join('/')==='audio/prepare'){await assertNotDeleting(user.id);const body=audioInput(await readJsonLimited<Record<string,unknown>>(req,4096));await contentOrgForUser(user.id,String(body.expected_org_id),String(body.listing_id),true);const a=await rpc('property_video_audio_prepare',{p_actor:user.id,p_body:body});return json({narration_asset_id:a.id,listing_id:a.listing_id,selected_library_org_id:a.library_org_id,ready:a.state==='ready',sha256:a.sha256,...(a.state!=='ready'?{...await putCapability('renders',a.storage_key,a.bytes,a.mime,a.sha256)}: {})});}
 if(req.method==='POST'&&seg.length===3&&seg[0]==='audio'&&seg[2]==='complete')return json(await completeAudio(user.id,seg[1],req));
 if(req.method==='PUT'&&seg.length===3&&seg[0]==='audio'&&seg[2]==='content')return json(await uploadAudio(user.id,seg[1],req));
 assert(false,405,'Use a supported saved-video route.');
 }catch(error){return respondError(error);}}
if(import.meta.main)Deno.serve(handler);
