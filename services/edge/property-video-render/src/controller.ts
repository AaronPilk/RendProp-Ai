/** Pure controller helpers shared by the actual Worker and executable tests. */
import type {WorkerAction, ComposeAction, ExtractAction, PrepareImageAction, InspectAudioAction} from '../../../supabase/functions/property-video-jobs/contracts.ts';

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export type {PrepareImageAction};
export type CPUAction = ComposeAction | ExtractAction | PrepareImageAction | InspectAudioAction;
export interface Capability {url: string; method: 'GET'|'PUT'; bytes: number;headers?:Record<string,string>}
export interface EgressProps {capabilities: Capability[]; expiresAt: number}
export interface SlotState {
  jobID: string;
  slot: 'slot-0'|'slot-1';
  token: string;
  task?: CPUAction;
  taskID?: string;
  capabilities?: EgressProps;
  pendingCallback?: {path:'qc'|'finish'|'prepared-finish'|'audio-preflight'|'failure'; body: Record<string,unknown>};
  outputs?: Record<string, unknown>;
  startedAt?: number;
  heartbeatAt?: number;
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
  const inputs = task.action === 'prepare_image' || task.action === 'inspect_audio' ? [task.source] : task.action === 'extract_frames' ? [task.clip] : [...task.sources, ...(task.narration ? [task.narration] : []), ...(task.music ? [task.music] : [])];
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
