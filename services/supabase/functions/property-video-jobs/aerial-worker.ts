import {aerialCompositeRpc} from './aerial-rpc.ts';
/** Existing service-owned worker only. One supplier POST, GET-only saved polling. */
import {assert,json} from '../_shared/http.ts';
import {adminClient} from '../_shared/supabase.ts';
import {presignGet,ProviderError} from '../_shared/providers/common.ts';
import {persistAerialResult,retainAerialBytes} from './aerial-retention.ts';
import {kieAdapter} from '../_shared/providers/kie.ts';
import {openaiChat} from '../_shared/providers/openai.ts';
import {anthropicMessages,imageBlock} from '../_shared/providers/anthropic.ts';
import {driftRubric,parseDriftVerdict,driftPasses,ESCALATE_BELOW_CONFIDENCE} from '../_shared/drift.ts';
import {R2_BUCKET_RENDERS} from '../_shared/r2.ts';
import {checkedAerialProcessingResult,type AerialProcessingTask} from '../_shared/aerial-processing-contract.ts';
import {AERIAL_EXTERIOR_RUBRIC,aerialGenerationModel,aerialQualityRubric,exteriorAssessment,submitAerialOnce,type AerialReceipt,type AerialStageStore,type AerialProvider} from './aerial-admission.ts';
import {sameAerialJSON} from './aerial-public.ts';
import {rpc,ownedHead,bytesFrom,bucket,base64,hash} from './runtime.ts';
import {putCapability,outputHead} from './storage.ts';
import {uuid} from './input.ts';
import {validatePhotoInput} from '../ai-photo/input-policy.ts';
import {probeComposedMP4Video} from '../ai-video/mp4video.ts';
import type {RouteStep} from '../_shared/router.ts';
const phaseFor=(kind:string)=>kind==='aerial-input'?'input':'qualification';
async function stepFor(j:any,phase:'assessment'|'quality'|'generation'):Promise<RouteStep>{const q=phase==='generation'?{route_id:j.quote.route_id,provider:'kie',model:aerialGenerationModel(j.manifest.profile)}:j.quote[phase];const{data,error}=await adminClient().from('ai_routes').select('*').eq('id',q.route_id).maybeSingle();assert(!error&&data&&data.enabled===true&&(!data.retire_after||Date.parse(data.retire_after)>Date.now())&&data.provider===q.provider&&data.model===q.model,409,'The frozen aerial route is unavailable. No replacement was selected.');return{...data,route_id:data.id,unit_cents:Number(data.unit_cents)} as RouteStep;}
async function checkedImage(d:any){const b=(await bytesFrom(d,8*1024*1024)).bytes;validatePhotoInput(base64(b),'image/jpeg');return b;}
async function judge(step:RouteStep,rubric:string,images:Uint8Array[],maxTokens:number){
 const encoded=images.map(base64);
 if(step.provider==='openai')return await openaiChat(step,[{role:'user',content:[{type:'input_text',text:rubric},...encoded.map(image=>({type:'input_image',image_url:'data:image/jpeg;base64,'+image}))]}],{json:true,maxOutputTokens:maxTokens});
 if(step.provider==='anthropic')return await anthropicMessages({model:step,system:rubric,content:encoded.map(b=>imageBlock(b,'image/jpeg')),maxTokens});
 throw Error('This aerial vision route has no qualified adapter');
}
export async function aerialQueue(){return await rpc('property_video_aerial_queue',{});}
async function task(j:any,phase:'input'|'qualification'):Promise<AerialProcessingTask>{const input=phase==='input',d=input?j.original_source:j.provider_clip;await ownedHead(d);return{state:input?'preparing':'qualifying',action:input?'prepare_image':'compose',job_id:j.id,lease_token:input?j.input_lease:j.qualification_lease,manifest_sha256:j.manifest_sha256,source_mode:'photo_motion_v1',composition_profile:input?'aerial-opening-input-v1':'aerial-opening-qualify-cfr24',producer_identity:j.policy.producer_identity,aspect:j.manifest.aspect,expires_at:new Date(Date.now()+600000).toISOString(),...(input?{source:{url:await presignGet(bucket(d.bucket),d.storage_key,600),sha256:d.sha256,bytes:d.bytes,etag:d.etag},reviewed_crop:j.manifest.reviewed_crop,output:{asset_id:j.input_asset_id,key:j.input_key}}:{clip:{url:await presignGet(bucket(d.bucket),d.storage_key,600),sha256:d.sha256,bytes:d.bytes,etag:d.etag},source_sha256:j.manifest.source.sha256,output:{asset_id:j.output_asset_id,key:j.output_key,poster_asset_id:j.poster_asset_id,poster_key:j.poster_key}})} as AerialProcessingTask;}
async function assess(j:any,lease:string){const step=await stepFor(j,'assessment'),image=await checkedImage(j.input_output);let result;try{result=exteriorAssessment(JSON.parse(await judge(step,AERIAL_EXTERIOR_RUBRIC,[image],300)));}catch(error){if(error instanceof ProviderError)throw error;result={exterior:false,uncertain:true,reason:'uncertain'};}await rpc('property_video_aerial_vision_result',{p_id:j.id,p_phase:'assessment',p_lease:lease,p_result:{...result,source_sha256:j.manifest.source.sha256,input_sha256:j.input_output.sha256}});}
async function quality(j:any,lease:string){const frames=j.qualified_output.review_frames;assert(Array.isArray(frames)&&frames.length===3,409,'The exact three retained review frames are required.');const step=await stepFor(j,'quality'),source=await checkedImage(j.input_output),images=[source];for(let i=0;i<3;i++){assert(frames[i].frame_index===j.qualified_output.frame_indices[i]&&frames[i].sha256===j.qualified_output.frame_sha256s[i],409,'The measured review-frame identity changed.');images.push(await checkedImage(frames[i]));}
 const raw=await judge(step,aerialQualityRubric(j.manifest.profile,()=>driftRubric({kind:'aerial',sceneNoun:'home',motionText:'A restrained continuous forward establishing move without revealing unseen structure.'})),images,400),v=parseDriftVerdict(raw),pass=driftPasses(v)&&v.confidence>=ESCALATE_BELOW_CONFIDENCE,unknown=v.unavailable||v.judgement==='unknown'||v.confidence<ESCALATE_BELOW_CONFIDENCE;
 await rpc('property_video_aerial_vision_result',{p_id:j.id,p_phase:'quality',p_lease:lease,p_result:{action:pass?'accept':unknown?'hold':'refuse',verdict:pass?'pass':unknown?'hold':'fail',publishable:pass,source_sha256:j.manifest.source.sha256,output_sha256:j.qualified_output.sha256,frame_indices:j.qualified_output.frame_indices,frame_sha256s:j.qualified_output.frame_sha256s,scores:v.scores,confidence:v.confidence}});
}
async function generation(j:any){const step=await stepFor(j,'generation');await ownedHead(j.input_output);const inputURL=await presignGet(R2_BUCKET_RENDERS,j.input_output.storage_key,300);let saved:any;
 const store:AerialStageStore={claimGeneration:async()=>{const c=await rpc('property_video_aerial_claim',{p_id:j.id,p_stage:'generation'});saved=c.job;return{claimed:c.claimed,token:c.lease_token,manifest:saved.manifest,eligibility:{exterior:saved.eligibility?.exterior,uncertain:saved.eligibility?.uncertain,reason:saved.eligibility?.reason},prepared:saved.input_output,inputURL:c.claimed?inputURL:''};},receipt:async(id,token,r)=>{await rpc('property_video_aerial_receipt',{p_id:id,p_lease:token,p_receipt:r});},ambiguous:async(id,token)=>{await rpc('property_video_aerial_ambiguous',{p_id:id,p_lease:token});},rejected:async(id,token,status,errorClass)=>{await rpc('property_video_aerial_reject_before_dispatch',{p_id:id,p_lease:token,p_status:status,p_error_class:errorClass});},pollAuthority:async()=>saved?.provider_receipt??null};
 const provider:AerialProvider={submit:async input=>await kieAdapter.submit(step,input) as AerialReceipt,poll:async receipt=>await kieAdapter.poll(receipt),rejection:e=>e instanceof ProviderError&&e.dispatch_rejected&&typeof e.status==='number'&&[0,400,401,402,403,404,405,413,415,422,429].includes(e.status)?{status:e.status,error_class:e.error_class}:null};
 return await submitAerialOnce(j.id,store,provider);
}
async function poll(j:any){const receipt=j.provider_receipt;assert(receipt?.provider==='kie'&&receipt?.model===aerialGenerationModel(j.manifest.profile),409,'Keep the original saved aerial receipt.');const result=await kieAdapter.poll(receipt);if(result.status==='failed'){await rpc('property_video_aerial_failure',{p_id:j.id,p_phase:'generation',p_lease:j.generation_lease});return;}if(result.status!=='done')return;
 const key=`renders/${j.org_id}/${j.listing_id}/aerial-provider/${j.id}.mp4`;
 await persistAerialResult(result,key,async intent=>{const current=await aerialCompositeRpc('property_video_aerial_worker_read',{p_id:j.id});assert(current,404,'This aerial operation is unavailable.');assert(current.cancel_requested_at===null&&intent.bytes<=134217728,409,'This stopped opening cannot create more retained media.');await rpc('media_storage_reserve',{p_org:j.org_id,p_bucket:'renders',p_key:key,p_bytes:intent.bytes});});
 const h=await outputHead('renders',key);assert(h.etag&&h.sha256&&h.bytes>0&&h.bytes<=134217728&&h.contentType==='video/mp4',409,'The retained supplier output needs its exact private receipt.');await rpc('property_video_aerial_clip',{p_id:j.id,p_receipt:receipt,p_clip:{bucket:'renders',storage_key:key,sha256:h.sha256,bytes:h.bytes,etag:h.etag,content_type:'video/mp4'}});
}
type RoutedCPUPhase='input'|'qualification';
/** A CPU-class prefix can only claim its own queued CPU phase. Once that phase
 * hands off, release the class and let the ordinary queue discover later work. */
function routedCPUPhase(j:any,phase?:RoutedCPUPhase):boolean{
 if(phase===undefined)return true;
 const opposite=phase==='input'?['queued_qualification','qualifying']:['queued_input','preparing_input'];
 assert(!opposite.includes(j.state),409,'Keep the aerial CPU work kind for its current phase.');
 return j.state===(phase==='input'?'queued_input':'queued_qualification');
}
export async function aerialTick(id:string,worker:string,routedPhase?:RoutedCPUPhase):Promise<any|null>{const found=await aerialCompositeRpc('property_video_aerial_worker_read',{p_id:id});if(!found)return null;let j=found;assert(worker==='slot-0',400,'Aerial work uses the single Photo motion slot.');
 if(j.cancel_requested_at!==null||['accepted','ready_for_acceptance','failed','cancelled','ineligible','ambiguous'].includes(j.state)){if(['failed','cancelled','ineligible'].includes(j.state))await rpc('property_video_aerial_release_future',{p_id:id});return{job_id:id,state:j.state,action:'done'};}
 if(!routedCPUPhase(j,routedPhase))return{job_id:id,state:j.state,action:'wait'};
 j=await aerialCompositeRpc('property_video_aerial_scope',{p_id:id,p_actor:null});
 if(!routedCPUPhase(j,routedPhase))return{job_id:id,state:j.state,action:'wait'};
 if(j.state==='processing'){await poll(j);return{job_id:id,state:'processing',action:'wait'};}
 const phase=({queued_input:'input',queued_assessment:'assessment',queued_generation:'generation',queued_qualification:'qualification',queued_quality:'quality'} as Record<string,string>)[j.state];if(!phase)return{job_id:id,state:j.state,action:'wait'};
 if(phase==='generation'){await generation(j);return{job_id:id,state:'processing',action:'wait'};}
 if(phase==='quality'&&!Array.isArray(j.qualified_output?.review_frames))return{job_id:id,state:j.state,action:'wait'};
 const c=await rpc('property_video_aerial_claim',{p_id:id,p_stage:phase});if(!c.claimed)return{job_id:id,state:c.job.state,action:'wait'};j=c.job;
 if(phase==='input'||phase==='qualification')return await task(j,phase);
 try{if(phase==='assessment')await assess(j,c.lease_token);else await quality(j,c.lease_token);}catch{await rpc('property_video_aerial_failure',{p_id:id,p_phase:phase,p_lease:c.lease_token});}
 return{job_id:id,state:j.state,action:'wait'};
}
function decodeFrame(v:any){assert(v?.mime==='image/jpeg'&&typeof v.image_b64==='string'&&v.image_b64.length<=524288,400,'Use the bounded measured JPEG review frame.');const bytes=Uint8Array.from(atob(v.image_b64),c=>c.charCodeAt(0));assert(bytes.length>0&&bytes.length<=393216,400,'Keep the bounded measured review frame.');validatePhotoInput(v.image_b64,'image/jpeg');return bytes;}
async function normalize(b:any,phase:'input'|'qualification'){const facts:any={...b};delete facts.processing_wall_ms;if(phase==='qualification'){facts.available_frames=b.total_frames;delete facts.total_frames;facts.frame_indices=b.frames.map((f:any)=>f.frame_index);facts.frame_sha256s=[];for(const frame of b.frames)facts.frame_sha256s.push(await hash(decodeFrame(frame)));delete facts.frames;}return facts;}
async function retainFrames(j:any,b:any){const refs=[];for(let i=0;i<3;i++){const bytes=decodeFrame(b.frames[i]),sha=await hash(bytes),index=j.qualified_output.frame_indices[i];const key=await rpc('property_video_aerial_frame_reserve',{p_id:j.id,p_lease:j.qualification_lease,p_index:index,p_sha:sha,p_bytes:bytes.length});await retainAerialBytes(key,bytes,'image/jpeg');const h=await outputHead('renders',key);assert(h.bytes===bytes.length&&h.sha256===sha&&h.etag&&h.contentType==='image/jpeg',409,'The retained aerial review frame changed.');refs.push({frame_index:index,bucket:'renders',storage_key:key,sha256:sha,bytes:bytes.length,etag:h.etag,content_type:'image/jpeg'});}await rpc('property_video_aerial_frames',{p_id:j.id,p_lease:j.qualification_lease,p_frames:refs});}
export async function aerialWorker(req:Request,seg:string[],b:any):Promise<Response|null>{
 if(seg.length!==2||!['aerial-input','aerial-qualify'].includes(seg[0]))return null;
 const id=uuid(b.job_id),phase=phaseFor(seg[0]),path=seg[1];
 // The existing controller prefixes tick too; no lease exists before claim.
 if(path==='tick'){
  assert(Object.keys(b).sort().join(',')==='job_id,worker_id'&&b.worker_id==='slot-0',400,'Use the exact single-slot aerial tick.');
  const tick=await aerialTick(id,b.worker_id,phase);assert(tick,404,'This aerial CPU operation is unavailable.');return json(tick);
 }
 const lease=uuid(b.lease_token),j=await aerialCompositeRpc('property_video_aerial_worker_read',{p_id:id});assert(j,404,'This aerial CPU operation is unavailable.');
 if(path==='reconcile'){
  const sourceSHA=(j.manifest.source as Record<string,unknown>|undefined)?.sha256;
  assert(Object.keys(b).sort().join(',')==='composition_profile,job_id,lease_token,manifest_sha256,producer_identity,source_sha256'&&b.manifest_sha256===j.manifest_sha256&&b.source_sha256===sourceSHA&&b.composition_profile===(phase==='input'?'aerial-opening-input-v1':'aerial-opening-qualify-cfr24')&&lease===(phase==='input'?j.input_lease:j.qualification_lease)&&sameAerialJSON(b.producer_identity,j.policy.producer_identity),409,'Keep the exact stopped aerial CPU ownership.');
  assert(['cancelled','failed','ineligible'].includes(j.state),409,'Only terminal aerial work can release stopped CPU ownership.');
  return json({job_id:id,lease_token:lease,manifest_sha256:j.manifest_sha256,source_sha256:sourceSHA,composition_profile:b.composition_profile,producer_identity:j.policy.producer_identity,phase,state:j.state,cancel_requested:j.cancel_requested_at!==null,terminal:true});
 }
 if(path==='heartbeat')return json({current:await rpc('property_video_aerial_heartbeat',{p_id:id,p_phase:phase,p_lease:lease})});
 if(path==='failure'){assert(b.manifest_sha256===j.manifest_sha256&&b.code==='cpu_attempt_failed'&&b.phase===(phase==='input'?'prepare_image':'compose')&&b.source_mode==='photo_motion_v1'&&b.composition_profile===(phase==='input'?'aerial-opening-input-v1':'aerial-opening-qualify-cfr24'),409,'Keep the exact sanitized aerial failure.');await rpc('property_video_aerial_observe',{p_id:id,p_phase:phase,p_lease:lease,p_outcome:'failed',p_wall_ms:b.processing_wall_ms,p_producer:b.producer_identity,p_facts:b});await rpc('property_video_aerial_failure',{p_id:id,p_phase:phase,p_lease:lease});return json({recorded:true});}
 const complete=path===(phase==='input'?'prepared-finish':'finish');assert(complete||path===(phase==='input'?'prepared-outputs':'outputs'),405,'Use the exact aerial CPU output lifecycle.');
 const issued=await task(j,phase);checkedAerialProcessingResult(b,issued,complete);assert(sameAerialJSON(b.producer_identity,j.policy.producer_identity),409,'The aerial output producer changed.');const facts=await normalize(b,phase);
 if(!complete){const row=await aerialCompositeRpc('property_video_aerial_cpu_output',{p_id:id,p_phase:phase,p_lease:lease,p_facts:facts,p_complete:false});assert(row.state!=='failed',409,'This opening stopped because its measured output could not be verified. Your source and saved files are kept. No replacement generation was submitted.');const o=phase==='input'?row.input_output:row.qualified_output;const video=await putCapability('renders',o.storage_key,o.bytes,phase==='input'?'image/jpeg':'video/mp4',o.sha256);if(phase==='input')return json({output:{asset_id:o.asset_id,key:o.storage_key,...video},expires_at:video.expires_at});const poster=await putCapability('renders',row.poster_key,b.poster_bytes,'image/jpeg',b.poster_sha256);return json({output:{asset_id:o.asset_id,key:o.storage_key,...video,poster_asset_id:row.poster_asset_id,poster_key:row.poster_key,poster_put_url:poster.put_url,poster_headers:poster.headers},expires_at:video.expires_at});}
 const o=phase==='input'?j.input_output:j.qualified_output,h=await outputHead('renders',o.storage_key);assert(h.etag&&h.sha256===b.sha256&&h.bytes===b.bytes&&h.contentType===(phase==='input'?'image/jpeg':'video/mp4'),409,'The actual aerial upload differs from its measured output.');facts.etag=h.etag;
 if(phase==='input'){const image=await checkedImage({...o,etag:h.etag}),measured=validatePhotoInput(base64(image),'image/jpeg');assert(measured.width===b.width&&measured.height===b.height,409,'The actual prepared JPEG geometry changed.');}
 else{const measured=await probeComposedMP4Video(await presignGet(R2_BUCKET_RENDERS,o.storage_key,300),fetch,24);assert(measured.width===b.width&&measured.height===b.height&&measured.fps===24&&Math.abs(measured.duration_s-b.total_frames/24)<=.001,409,'The actual aerial clip timeline changed.');const ph=await outputHead('renders',j.poster_key);assert(ph.etag&&ph.sha256===b.poster_sha256&&ph.bytes===b.poster_bytes&&ph.contentType==='image/jpeg',409,'The aerial poster upload changed.');facts.poster_etag=ph.etag;}
 const row=await aerialCompositeRpc('property_video_aerial_cpu_output',{p_id:id,p_phase:phase,p_lease:lease,p_facts:facts,p_complete:true});assert(row.state!=='failed',409,'This opening stopped because its measured output could not be verified. Your source and saved files are kept. No replacement generation was submitted.');
 if(phase==='qualification')await retainFrames(row,b);
 await rpc('property_video_aerial_observe',{p_id:id,p_phase:phase,p_lease:lease,p_outcome:'completed',p_wall_ms:b.processing_wall_ms,p_producer:b.producer_identity,p_facts:facts});return json({recorded:true,job_id:id,state:row.state});
}
