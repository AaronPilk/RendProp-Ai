/** Controller attestation of the reviewed CPU18 producer; never a CPU-emitted digest. */
import type {ExtractAction} from '../../../supabase/functions/property-video-jobs/contracts.ts';

export const CPU18_IMAGE_URI='registry.cloudflare.com/9c332c75b96cc642621dad5d86d4bf18/rendprop-property-video-cpu@sha256:4452a0488ae786dff4e607d11e4711af5a2d59e4d6d26f168d9063db039774bc';
export const CPU18_MOTION_SOURCE_SHA256='5827ff44454719aca90b098760973578c7f6397bf9f365f2258e65a7d54cb51c';
export const CPU18_RENDERER_SOURCE_SHA256='a82b133e13a83e835db7f432f147043680844266538a2e80d8d9144ccdc880bc';
export const TEMPORAL_PROFILE='temporal-motion-v2';
// Exact FINISHED_LIMITS in the retained, actually tested image4452 module5827.
export const CPU18_LIMITS=Object.freeze({bob_pp_px:1.2,sway_pp_px:1.2,cadence_acf:.4,cadence_min_pp_px:.6,roll_wobble_pp_deg:.08,zoom_pump_pp_pct:.11,roll_drift_deg:1,duplicate_ratio:.01,zoom_pct:40,pan_pct:20,invalid_ratio:.1});
export const CPU18_LIMITS_SHA256='244436b765886f537bd6d3b835dc42ca06cc758dc1a3b796028aae448b21d555';
const SHA=/^[a-f0-9]{64}$/;
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const object=(v:unknown):v is Record<string,unknown>=>!!v&&typeof v==='object'&&!Array.isArray(v);
const keys=(v:Record<string,unknown>,expected:readonly string[])=>Object.keys(v).sort().join(',')===[...expected].sort().join(',');
const numeric=['fps','steps','invalid_ratio','bob_pp_px','bob_rms_px','sway_pp_px','sway_rms_px','cadence_acf','roll_wobble_pp_deg','roll_drift_deg','roll_span_deg','zoom_pump_pp_pct','zoom_pct','zoom_excursion_pct','pan_excursion_pct','pan_x_pct','pan_y_pct','speed_px_per_frame','speed_cv','duplicate_ratio'] as const;
const signed=new Set<string>(['zoom_pct','roll_drift_deg','pan_x_pct','pan_y_pct']);
const reasons=new Set(['unmeasurable','vertical_bob','lateral_sway','walking_cadence','roll_wobble','zoom_pumping','horizon_roll','duplicate_frames','walk_through_travel']);

export class TemporalEnvelopeRefusal extends Error {constructor(){super('temporal_producer_attestation_refused');}}
const refuse=():never=>{throw new TemporalEnvelopeRefusal();};
export interface TemporalProducerBinding {
  image_uri:typeof CPU18_IMAGE_URI;
  motion_source_sha256:typeof CPU18_MOTION_SOURCE_SHA256;
  renderer_source_sha256:typeof CPU18_RENDERER_SOURCE_SHA256;
  job_id:string;attempt_id:string;lease_token:string;clip_sha256:string;
}
export interface TemporalAttestation {
  schema:'controller-temporal-attestation-v1';
  authority:'reviewed-controller-configuration-and-retained-image-source-proof';
  mode:'added-legacy-limits'|'preserved-versioned-limits';
  task_id:string;job_id:string;attempt_id:string;lease_token:string;clip_sha256:string;
  producer_image_uri:typeof CPU18_IMAGE_URI;producer_motion_source_sha256:typeof CPU18_MOTION_SOURCE_SHA256;
  producer_renderer_source_sha256:typeof CPU18_RENDERER_SOURCE_SHA256;
  profile:typeof TEMPORAL_PROFILE;limits_sha256:string;metrics_sha256:string;verdict_sha256:string;
}
export type TemporalAttestationDiagnostic=Omit<TemporalAttestation,'lease_token'>;
/** The trigger-key diagnostic audience must never receive the callback lease. */
export function diagnosticTemporalAttestation(value:TemporalAttestation):TemporalAttestationDiagnostic {
  const{lease_token:_lease,...publicFields}=value;
  return publicFields;
}
export function checkedTemporalAttestation(raw:unknown):TemporalAttestation|null {
  if(!object(raw)||!keys(raw,['schema','authority','mode','task_id','job_id','attempt_id','lease_token','clip_sha256','producer_image_uri','producer_motion_source_sha256','producer_renderer_source_sha256','profile','limits_sha256','metrics_sha256','verdict_sha256'])
    ||raw.schema!=='controller-temporal-attestation-v1'||raw.authority!=='reviewed-controller-configuration-and-retained-image-source-proof'
    ||!['added-legacy-limits','preserved-versioned-limits'].includes(String(raw.mode))||raw.producer_image_uri!==CPU18_IMAGE_URI
    ||raw.producer_motion_source_sha256!==CPU18_MOTION_SOURCE_SHA256||raw.producer_renderer_source_sha256!==CPU18_RENDERER_SOURCE_SHA256
    ||raw.profile!==TEMPORAL_PROFILE||raw.limits_sha256!==CPU18_LIMITS_SHA256)return null;
  for(const key of ['job_id','attempt_id','lease_token'])if(typeof raw[key]!=='string'||!UUID.test(raw[key]))return null;
  for(const key of ['task_id','clip_sha256','metrics_sha256','verdict_sha256'])if(typeof raw[key]!=='string'||!SHA.test(raw[key]))return null;
  return raw as unknown as TemporalAttestation;
}
export async function digest(text:string):Promise<string>{return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(text))),x=>x.toString(16).padStart(2,'0')).join('');}
export const limitsCanonical=()=>Object.keys(CPU18_LIMITS).sort().map(k=>`${k}=${CPU18_LIMITS[k as keyof typeof CPU18_LIMITS]}`).join('\n');

/** Validate before a fresh start; persist this binding only after start succeeds. */
export function bindTemporalProducer(task:ExtractAction,configuredImage:unknown,startImage:unknown):TemporalProducerBinding {
  if(configuredImage!==CPU18_IMAGE_URI||startImage!==CPU18_IMAGE_URI||!UUID.test(task.job_id)||!UUID.test(task.attempt_id)||!UUID.test(task.lease_token)
    ||!SHA.test(task.clip.sha256)||!object(task.temporal_qc)||!keys(task.temporal_qc,['profile','aspect'])
    ||task.temporal_qc.profile!==TEMPORAL_PROFILE||!['16:9','9:16'].includes(task.temporal_qc.aspect))return refuse();
  return{image_uri:CPU18_IMAGE_URI,motion_source_sha256:CPU18_MOTION_SOURCE_SHA256,renderer_source_sha256:CPU18_RENDERER_SOURCE_SHA256,
    job_id:task.job_id,attempt_id:task.attempt_id,lease_token:task.lease_token,clip_sha256:task.clip.sha256};
}
function checkedMetrics(raw:unknown,aspect:string):raw is Record<string,unknown> {
  if(!object(raw)||!keys(raw,[...numeric,'profile','frame','static_shot','cadence_hz'])||raw.profile!==TEMPORAL_PROFILE
    ||typeof raw.static_shot!=='boolean'||!Array.isArray(raw.frame)||raw.frame.length!==2
    ||raw.frame[0]!==(aspect==='16:9'?1920:1080)||raw.frame[1]!==(aspect==='16:9'?1080:1920))return false;
  for(const key of numeric){const value=raw[key];if(typeof value!=='number'||!Number.isFinite(value)||!signed.has(key)&&value<0)return false;}
  if(!Number.isInteger(raw.steps)||Number(raw.steps)<8||Number(raw.steps)>=1200||Number(raw.fps)<=0||Number(raw.fps)>120||Number(raw.zoom_pct)<=-100)return false;
  for(const key of ['invalid_ratio','duplicate_ratio','cadence_acf'])if(Number(raw[key])<0||Number(raw[key])>1)return false;
  if(raw.cadence_hz===null)return Number(raw.cadence_acf)===0;
  return typeof raw.cadence_hz==='number'&&Number.isFinite(raw.cadence_hz)&&raw.cadence_hz>0&&raw.cadence_hz<=Number(raw.fps)/2;
}
function checkedVerdict(raw:unknown):raw is Record<string,unknown> {
  return object(raw)&&keys(raw,['profile','pass','reasons'])&&raw.profile===TEMPORAL_PROFILE&&typeof raw.pass==='boolean'
    &&Array.isArray(raw.reasons)&&raw.reasons.length<=reasons.size&&raw.reasons.every(r=>typeof r==='string'&&reasons.has(r))
    &&new Set(raw.reasons).size===raw.reasons.length&&raw.pass===(raw.reasons.length===0);
}
/** The adapter changes only a missing metadata envelope. It never computes or changes a verdict. */
export async function attestTemporalExtract(task:ExtractAction,result:Record<string,unknown>,binding:TemporalProducerBinding|undefined,taskID:string):Promise<{result:Record<string,unknown>;attestation:TemporalAttestation}> {
  if(!binding||!SHA.test(taskID))return refuse();
  const expected=bindTemporalProducer(task,binding.image_uri,binding.image_uri);
  if(JSON.stringify(binding)!==JSON.stringify(expected)||result.job_id!==task.job_id||result.attempt_id!==task.attempt_id
    ||result.lease_token!==task.lease_token||result.clip_sha256!==task.clip.sha256)return refuse();
  const report=result.temporal;
  if(!object(report)||!keys(report,'limits'in report?['metrics','verdict','limits']:['metrics','verdict'])
    ||!checkedMetrics(report.metrics,task.temporal_qc!.aspect)||!checkedVerdict(report.verdict))return refuse();
  const limitsSHA=await digest(limitsCanonical());if(limitsSHA!==CPU18_LIMITS_SHA256)return refuse();
  const present='limits'in report;
  if(present&&(!object(report.limits)||!keys(report.limits,['profile','sha256'])||report.limits.profile!==TEMPORAL_PROFILE||report.limits.sha256!==limitsSHA))return refuse();
  const attestation:TemporalAttestation={schema:'controller-temporal-attestation-v1',authority:'reviewed-controller-configuration-and-retained-image-source-proof',
    mode:present?'preserved-versioned-limits':'added-legacy-limits',task_id:taskID,job_id:task.job_id,attempt_id:task.attempt_id,lease_token:task.lease_token,clip_sha256:task.clip.sha256,
    producer_image_uri:binding.image_uri,producer_motion_source_sha256:binding.motion_source_sha256,producer_renderer_source_sha256:binding.renderer_source_sha256,
    profile:TEMPORAL_PROFILE,limits_sha256:limitsSHA,metrics_sha256:await digest(JSON.stringify(report.metrics)),verdict_sha256:await digest(JSON.stringify(report.verdict))};
  // Preserve both measured value trees, including their JSON property order.
  return{result:present?result:{...result,temporal:{...report,limits:{profile:TEMPORAL_PROFILE,sha256:limitsSHA}}},attestation};
}
