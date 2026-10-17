// Temporal motion QC on the job path (steady profiles only).
//
// The renderer container measures walking bob, sway, cadence, roll, zoom
// pumping, travel and repeated frames in the final frame (motion_qc.py,
// profile temporal-motion-v2) when an extract_frames task carries
// `temporal_qc`. The worker asks for it on every steady-profile shot, verifies
// the report names this exact versioned limit set, records it on the shot
// through property_video_job_temporal, and only then lets the existing paid
// drift QC decide. No report, a malformed report, or foreign limits HOLD the
// shot: the qc callback is refused, the CPU lease lapses and the next extract
// repeats the measurement; nothing is published and nothing is bought.
// Legacy and v1 jobs never request a report and never require one.
import{isSteadyPropertyVideoProfile}from'../ai-video/property-video-quality.ts';
export const TEMPORAL_QC_PROFILE='temporal-motion-v2'as const;
/** Mirror of motion_qc.FINISHED_LIMITS. Change both or the worker holds every steady shot. */
export const TEMPORAL_LIMITS={bob_pp_px:1.2,sway_pp_px:1.2,cadence_acf:.4,cadence_min_pp_px:.6,roll_wobble_pp_deg:.08,zoom_pump_pp_pct:.11,roll_drift_deg:1,duplicate_ratio:.01,zoom_pct:40,pan_pct:20,invalid_ratio:.1}as const;
/** sha256 of temporalLimitsCanonical(); motion_qc.LIMITS_SHA256 must equal it (both test suites pin this text). */
export const TEMPORAL_LIMITS_SHA256='244436b765886f537bd6d3b835dc42ca06cc758dc1a3b796028aae448b21d555';
export function temporalLimitsCanonical(limits:Record<string,number>=TEMPORAL_LIMITS):string{return Object.keys(limits).sort().map(k=>`${k}=${limits[k]}`).join('\n');}
export async function sha256Hex(text:string):Promise<string>{return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(text))),x=>x.toString(16).padStart(2,'0')).join('');}
/** Failures the stabiliser or one safer camera move could cure, versus failures that condemn the clip. */
export const TEMPORAL_RETRYABLE=['vertical_bob','lateral_sway','walking_cadence','roll_wobble','zoom_pumping']as const;
export const TEMPORAL_TERMINAL=['walk_through_travel','horizon_roll','duplicate_frames','unmeasurable']as const;
export type TemporalRoute='pass'|'retry'|'refuse';
export interface TemporalReport{profile:typeof TEMPORAL_QC_PROFILE;limits:{profile:typeof TEMPORAL_QC_PROFILE;sha256:string};metrics:Record<string,unknown>;verdict:{profile:typeof TEMPORAL_QC_PROFILE;pass:boolean;reasons:string[]}}
export const temporalRequired=(profile:unknown)=>isSteadyPropertyVideoProfile(profile);
/** The renderer's extract_frames request for a steady job; absent for every other profile. */
export function temporalTask(profile:unknown,aspect:unknown):{temporal_qc:{profile:typeof TEMPORAL_QC_PROFILE;aspect:'16:9'|'9:16'}}|Record<never,never>{
 if(!temporalRequired(profile))return{};if(aspect!=='16:9'&&aspect!=='9:16')throw new Error('closed aspect required for temporal QC');return{temporal_qc:{profile:TEMPORAL_QC_PROFILE,aspect}};
}
const object=(v:unknown):v is Record<string,unknown>=>!!v&&typeof v==='object'&&!Array.isArray(v);
const KNOWN_REASONS=new Set<string>([...TEMPORAL_RETRYABLE,...TEMPORAL_TERMINAL,'invalid_metrics','invalid_limits']);
/** A closed copy of a well-formed report measured against this limit version, or null (hold). */
export function temporalReport(raw:unknown):TemporalReport|null{
 if(!object(raw)||!object(raw.metrics)||!object(raw.verdict)||!object(raw.limits))return null;
 const{metrics,verdict,limits}=raw;
 if(limits.profile!==TEMPORAL_QC_PROFILE||limits.sha256!==TEMPORAL_LIMITS_SHA256||metrics.profile!==TEMPORAL_QC_PROFILE||verdict.profile!==TEMPORAL_QC_PROFILE)return null;
 if(typeof verdict.pass!=='boolean'||!Array.isArray(verdict.reasons)||!verdict.reasons.every(r=>typeof r==='string'&&KNOWN_REASONS.has(r))||verdict.pass!==(verdict.reasons.length===0))return null;
 if(Object.keys(metrics).length>64||JSON.stringify(metrics).length>8192)return null;
 for(const v of Object.values(metrics))if(!(v===null||typeof v==='boolean'||typeof v==='string'&&v.length<=64||typeof v==='number'&&Number.isFinite(v)||Array.isArray(v)&&v.length<=2&&v.every(n=>Number.isInteger(n))))return null;
 return{profile:TEMPORAL_QC_PROFILE,limits:{profile:TEMPORAL_QC_PROFILE,sha256:TEMPORAL_LIMITS_SHA256},metrics:{...metrics},verdict:{profile:TEMPORAL_QC_PROFILE,pass:verdict.pass,reasons:[...verdict.reasons]}};
}
export function temporalRoute(verdict:TemporalReport['verdict']):TemporalRoute{
 if(verdict.pass)return'pass';
 return verdict.reasons.every(r=>(TEMPORAL_RETRYABLE as readonly string[]).includes(r))?'retry':'refuse';
}
