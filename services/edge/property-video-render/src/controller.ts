import type{AerialWorkKind}from'./aerial-processing';
import type {AerialOpeningTask} from '../../../supabase/functions/_shared/aerial-opening-contract.ts';
/** Pure controller helpers shared by the actual Worker and executable tests. */
import type {TemporalProducerBinding,TemporalAttestation} from './temporal-envelope';
import type {WorkerAction, ComposeAction, ExtractAction, PrepareImageAction, InspectAudioAction} from '../../../supabase/functions/property-video-jobs/contracts.ts';
import type {PhotoMotionTask,PhotoMotionProducer} from './photo-motion';

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export type {PrepareImageAction};
export type CPUAction = ComposeAction | PhotoMotionTask | ExtractAction | PrepareImageAction | InspectAudioAction;
export interface Capability {url: string; method: 'GET'|'PUT'; bytes: number;headers?:Record<string,string>}
export interface EgressProps {capabilities: Capability[]; expiresAt: number}
export interface PhotoMotionStartup {
  begunAt:number;
  deadline:number;
  stage:'claimed'|'lease'|'start'|'inactivity'|'egress'|'ready'|'process'|'execute'|'accepted'|'stop';
  executeIssued:boolean;
  startIssued:boolean;
  nativePending?:true;
  /** Fulfilled destroy acknowledgement, saved atomically with pending removal. */
  nativeStopAcknowledgedAt?:number;
  uncertain?:true;
  held?:true;
}
export interface SlotState {
  jobID: string;
  workKind?:AerialWorkKind;
  slot: 'slot-0'|'slot-1';
  token: string;
  task?: CPUAction;
  taskID?: string;
  capabilities?: EgressProps;
  pendingCallback?: {path:'qc'|'finish'|'prepared-finish'|'audio-preflight'|'failure'; body: Record<string,unknown>};
  outputs?: Record<string, unknown>;
  startedAt?: number;
  heartbeatAt?: number;
  temporalProducer?: TemporalProducerBinding;
  temporalAttestation?: TemporalAttestation;
  temporalRawResult?: Record<string,unknown>;
  /** Legacy only: set by controller releases before the motion check became advisory. Never set now; a saved hold is released on its next alarm. */
  temporalHold?: true;
  /** Advisory motion check: this task's measurement could not be attested; its frames go without a report. */
  temporalUnattested?: true;
  /** When the current wait on the CPU began (task accepted, or its upload issued). */
  pollSince?: number;
  /** This ownership ran a CPU task; only then does a finished job look for the next queued item. */
  worked?: true;
  /** Set only while the job waits on its supplier: no lease, task or process is held, and any other work may take the slot. */
  waiting?: {since:number;at:number};
  photoMotionImage?: string;
  photoMotionStartedAt?: number;
  photoMotionProducer?: PhotoMotionProducer;
  photoMotionStartup?: PhotoMotionStartup;
  /** Validated completed output is durable before an un-cancelable stop. */
  photoMotionTerminal?: {stoppedAt?:number};
}

/** How soon a supplier wait is looked at again. Matches the function's own
 * follow-up cadence (PROPERTY_VIDEO_FOLLOW_UP_WAKE_MS) instead of the minute cron. */
export const WAIT_RECHECK_MS=20_000;
/** A generic wake this soon after the slot's own look keeps the scheduled one. */
export const WAIT_QUIET_MS=10_000;
/** After this much continuous waiting the slot lets go and cron takes over. */
export const WAIT_PARK_MS=10*60_000;
/** A job that is only waiting on its supplier. It holds nothing a CPU or the
 * authority could lose, so the slot counts as available to other work. */
export function videoWaitOnly(state:unknown):state is SlotState&{waiting:{since:number;at:number}} {
  const value=state as SlotState|null;
  return !!value&&typeof value==='object'&&'jobID'in value&&value.waiting!==undefined&&!value.task&&!value.taskID&&!value.pendingCallback&&!value.photoMotionStartup&&!value.temporalHold;
}
/** A CPU phase is usually seconds of work (a photo preparation is 1 to 2 s), so
 * the fixed slow poll was most of its wall time. Look closely at first, then
 * back off; the slow poll stays the ceiling. `gentle` is for the Photo Motion
 * class, whose every look re-issues recorded native calls: seven early looks
 * (2, 6, 10, 15, 20, 25, 30 s), then the slow poll as before. */
export function cpuPollDelay(since:number|undefined,now:number,slow:number,gentle=false):number {
  const elapsed=Math.max(0,now-(since??now));
  if(gentle)return Math.min(slow,elapsed<2_000?2_000:elapsed<10_000?4_000:elapsed<30_000?5_000:slow);
  return Math.min(slow,elapsed<20_000?500:elapsed<60_000?1_000:elapsed<180_000?3_000:slow);
}

export function mediaURL(raw: string, hosts: Set<string>): string {
  if (typeof raw !== 'string' || raw.length > 8192) throw Error('media_capability_invalid');
  const url = new URL(raw);
  if (url.protocol !== 'https:' || url.username || url.password || url.hash || (url.port && url.port !== '443')
    || !hosts.has(url.hostname) || /^\[|^\d+(\.\d+){3}$/.test(url.hostname)) throw Error('media_capability_invalid');
  return raw;
}

export function capabilities(task: CPUAction, hosts: Set<string>): EgressProps {
  const expiresAt = Date.parse(task.expires_at);
  if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) throw Error('stale_cpu_lease');
  if (!UUID.test(task.job_id) || !UUID.test(task.lease_token)) throw Error('invalid_cpu_identity');
  const inputs = task.action==='compose'&&'clip'in task?[task.clip]:task.action === 'prepare_image' || task.action === 'inspect_audio' ? [task.source] : task.action === 'extract_frames' ? [task.clip] : [...task.sources, ...(('opening'in task&&task.composition_profile==='photo-motion-v2-opening-cfr24')?[((task as unknown as {opening:AerialOpeningTask}).opening).media]:[]), ...(task.narration ? [task.narration] : []), ...(task.music ? [task.music] : [])];
  return {expiresAt, capabilities: inputs.map(item => {
    if (!Number.isSafeInteger(item.bytes) || item.bytes < 1 || item.bytes > 128*1024*1024) throw Error('bounded_media_required');
    if (task.action === 'inspect_audio' && item.bytes > 20*1024*1024) throw Error('bounded_narration_required');
    return {url: mediaURL(item.url,hosts), method:'GET', bytes:item.bytes};
  })};
}

export function outputCapabilities(output: Record<string,unknown>, receipt: Record<string,unknown>, hosts:Set<string>): EgressProps {
  const expiresAt = Date.parse(String(output.expires_at));
  if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) throw Error('stale_output_lease');
  const preparation=receipt.mime==='image/jpeg'&&receipt.poster_asset_id===undefined;
  if (output.asset_id !== receipt.asset_id || !preparation&&output.poster_asset_id !== receipt.poster_asset_id) throw Error('output_identity_conflict');
  return {expiresAt,capabilities:(preparation?[['put_url','bytes','headers','sha256','image/jpeg']]:[['put_url','bytes','headers','sha256','video/mp4'],['poster_put_url','poster_bytes','poster_headers','poster_sha256','image/jpeg']]).map(([key,size,headerKey,shaKey,mime])=>{
    const bytes=receipt[size];
    if (typeof bytes!=='number'||!Number.isSafeInteger(bytes)||bytes<1||bytes>1536*1024*1024) throw Error('bounded_output_required');
    const headers=output[headerKey] as Record<string,string>;
    if (!headers||Object.keys(headers).sort().join(',')!=='content-length,content-type,if-none-match,x-amz-meta-sha256'
      ||headers['content-length']!==String(bytes)||headers['content-type']!==mime||headers['if-none-match']!=='*'
      ||headers['x-amz-meta-sha256']!==receipt[shaKey]||!/^[a-f0-9]{64}$/.test(headers['x-amz-meta-sha256'])) throw Error('output_header_identity_conflict');
    return {url:mediaURL(String(output[key]),hosts),method:'PUT',bytes,headers};
  })};
}

export async function egress(request:Request,props:EgressProps,transport:typeof fetch=fetch):Promise<Response> {
  const cap=props.capabilities.find(value=>value.url===request.url&&value.method===request.method);
  if (!cap||props.expiresAt<=Date.now()) return new Response('capability_refused',{status:403});
  if (request.method==='PUT'&&request.headers.get('content-length')!==String(cap.bytes)) return new Response('size_refused',{status:403});
  const headers=new Headers({'accept-encoding':'identity'});
  if (request.method==='PUT') {
    if (!cap.headers) return new Response('header_capability_refused',{status:403});
    for (const [key,value] of Object.entries(cap.headers)) {
      if(request.headers.get(key)!==value)return new Response('header_capability_refused',{status:403});
      headers.set(key,value);
    }
    const mime=request.headers.get('content-type');
    if (mime!=='video/mp4'&&mime!=='image/jpeg') return new Response('type_refused',{status:403});
  }
  // Redirects cannot widen a presigned media capability to a new host/object.
  const response=await transport(new Request(request,{headers,redirect:'manual'}));
  if (response.status>=300&&response.status<400) return new Response('redirect_refused',{status:502});
  if (request.method==='GET'&&response.ok) {
    const length=response.headers.get('content-length');
    if (length!==String(cap.bytes)) return new Response('source_size_conflict',{status:502});
  }
  return response;
}

export function sanitizedFailure(task:CPUAction):Record<string,unknown> {
  return {job_id:task.job_id,lease_token:task.lease_token,
    ...(task.action==='extract_frames'?{attempt_id:task.attempt_id}:{}),phase:task.action,code:'cpu_attempt_failed'};
}

export function isTerminal(action:WorkerAction|PrepareImageAction):boolean {
  return action.action==='done'||['ready','failed','cancelled','needs_reconciliation'].includes(action.state);
}
