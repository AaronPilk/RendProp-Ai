import{aerialWorkKind,checkedAerialWorkKind,AERIAL_INPUT_PROFILE,AERIAL_QUALIFY_PROFILE,type AerialWorkKind}from'./aerial-processing';
import {DurableObject,WorkerEntrypoint} from 'cloudflare:workers';
import type {WorkerAction} from '../../../supabase/functions/property-video-jobs/contracts.ts';
import {UUID,capabilities,outputCapabilities,egress,isTerminal,sanitizedFailure,cpuPollDelay,videoWaitOnly,WAIT_RECHECK_MS,WAIT_QUIET_MS,WAIT_PARK_MS} from './controller';
import type {SlotState,EgressProps,CPUAction,PrepareImageAction} from './controller';
import {photoCapabilities,photoOutputCapabilities,checkedPhotoResult,photoFailure,photoPrewarmOnly,photoPollDelay,photoCallbackDelay,PHOTO_PREWARM_HOLD_MS} from './photo-quality';
import type {PhotoSlotState,PhotoAction} from './photo-quality';
import {bindTemporalProducer,attestTemporalExtract,checkedTemporalAttestation,diagnosticTemporalAttestation,TemporalEnvelopeRefusal} from './temporal-envelope';
import type {TemporalAttestation,TemporalAttestationDiagnostic} from './temporal-envelope';
import {photoMotionTask,photoMotionProducer,samePhotoMotionProducer,checkedPhotoMotionResult,photoMotionWall,photoMotionCallbackPath,PHOTO_MODE,PHOTO_PROFILE} from './photo-motion';
import {isV1PhotoMotionTask,checkedV1PhotoMotionCallback} from './photo-motion-v1-replay';
import{isHistoricalV2PhotoMotionTask,checkedHistoricalV2Callback}from'./photo-motion-v2-replay';
import {photoMotionSlotName,heldPhotoMotionCompatibility,type PhotoMotionRuntimeConfiguration} from './photo-motion-config';
type WorkState=SlotState|PhotoSlotState;

interface Env extends PhotoMotionRuntimeConfiguration {
  CPU:DurableObjectNamespace<PropertyVideoCPU>;
  PHOTO_MOTION_CPU?:DurableObjectNamespace<PhotoMotionCPU>;
  ENABLED:string;
  EDGE_WORKER_URL:string;
  EDGE_SERVICE_ROLE_KEY:string;
  /** Optional Supabase region for every authority call (deployment setting). */
  EDGE_FUNCTION_REGION?:string;
  RENDER_TRIGGER_KEY:string;
  MEDIA_HOSTS:string;
  CPU_TEMPORAL_PRODUCER_IMAGE_URI?:string;
  CPU_PHOTO_MOTION_IMAGE_URI?:string;
  CPU_PHOTO_MOTION_CONTROLLER_SHA256?:string;
  CPU_PHOTO_MOTION_RENDERER_SHA256?:string;
}

const POLL_MS=15_000;
const CPU_TIMEOUT_MS=20*60_000;
const COLD_READY_MS=120_000;
// Cron runs in whichever Cloudflare location is free, so without a pinned
// region each minute's queue read lands on a different, cold Supabase region
// far from the database. This is deployment configuration, never caller input.
const EDGE_REGIONS=new Set(['ap-northeast-1','ap-northeast-2','ap-south-1','ap-southeast-1','ap-southeast-2','ca-central-1','us-east-1','us-west-1','us-west-2','eu-central-1','eu-west-1','eu-west-2','eu-west-3','sa-east-1']);
const json=(value:unknown,status=200)=>Response.json(value,{status,headers:{'Cache-Control':'no-store'}});
async function photoStartBody(request:Request):Promise<{check_id:string}|null>{
  if(request.headers.get('Content-Type')?.split(';')[0].trim()!=='application/json'||Number(request.headers.get('Content-Length')??0)>256||!request.body)return null;
  const reader=request.body.getReader();let text='';const decoder=new TextDecoder();let bytes=0;
  try{for(;;){const part=await reader.read();if(part.done)break;bytes+=part.value.byteLength;if(bytes>256){await reader.cancel();return null;}text+=decoder.decode(part.value,{stream:true});}text+=decoder.decode();
    const value=JSON.parse(text);return value&&typeof value==='object'&&!Array.isArray(value)&&Object.keys(value).join(',')==='check_id'&&typeof value.check_id==='string'&&UUID.test(value.check_id)?value:null;
  }catch{return null;}finally{reader.releaseLock();}
}

class AuthorityRefusal extends Error {constructor(readonly status:number){super("authority_refused");}}
type TransportName='TypeError'|'TimeoutError'|'AbortError'|'Other';
type TransportReason='redirect'|'invalid_header'|'dns'|'timeout'|'unsupported_api'|'other';
class BridgeFailure extends Error {constructor(readonly category:'bridge_configuration'|'bridge_transport'|'bridge_response',readonly transport?:{name:TransportName;reason:TransportReason}){super(category);}}
function transportFailure(error:unknown):BridgeFailure {
  const value=error as {name?:unknown;message?:unknown}|null;
  const name:TransportName=value?.name==='TypeError'||value?.name==='TimeoutError'||value?.name==='AbortError'?value.name:'Other';
  const message=typeof value?.message==='string'?value.message:'';
  // Only closed categories leave the process. Raw error text can contain a
  // private signed URL or header value and is never logged or retained.
  const reason:TransportReason=/redirect/i.test(message)?'redirect':/header|HTTP token|invalid character/i.test(message)?'invalid_header'
    :/DNS|ENOTFOUND|EAI_AGAIN|resolve host/i.test(message)?'dns'
    :/not (?:a function|implemented)|unsupported (?:API|option)/i.test(message)?'unsupported_api':/timeout|timed out/i.test(message)?'timeout':'other';
  return new BridgeFailure('bridge_transport',{name,reason});
}
function dispatchDiagnostic(error:unknown):Record<string,string|number> {
  return error instanceof AuthorityRefusal ? {category:'bridge_http',status:error.status}
    : error instanceof BridgeFailure ? {category:error.category,...(error.transport?{error_name:error.transport.name,reason:error.transport.reason}:{})} : {category:'controller'};
}
type CPUPhase='start'|'inactivity'|'egress'|'ready'|'ready_timeout'|'execute'|'status'|'upload';
type StartupReason='process_exit'|'startup_image'|'startup_capacity'|'startup_configuration'|'startup_unknown';
class CPUFailure extends Error {constructor(readonly phase:CPUPhase,readonly category:'cpu_api'|'cpu_transport'|'cpu_http'|'cpu_response'|'cpu_not_running'|'cpu_task_failed'|'cpu_task_missing'|'cpu_start_failed',readonly status?:number,readonly transport?:{name:TransportName;reason:TransportReason},readonly startup?:{reason:StartupReason;exitCode?:number}){super(category);}}
function startupFailure(error:unknown):CPUFailure {
  const value=error as {exitCode?:unknown;message?:unknown}|null;
  const exitCode=Number.isInteger(value?.exitCode)&&Number(value?.exitCode)>=0&&Number(value?.exitCode)<=255?Number(value?.exitCode):undefined;
  const message=typeof value?.message==='string'?value.message:'';
  const reason:StartupReason=exitCode!==undefined?'process_exit':/image|registry|manifest|pull/i.test(message)?'startup_image':/capacity|resource|quota|limit|placement/i.test(message)?'startup_capacity':/configuration|not permitted|not enabled|permission/i.test(message)?'startup_configuration':'startup_unknown';
  return new CPUFailure('start','cpu_start_failed',undefined,undefined,{reason,...(exitCode===undefined?{}:{exitCode})});
}
function cpuDiagnostic(error:unknown):Record<string,string|number> {
  if(error instanceof TemporalEnvelopeRefusal)return{phase:'controller',category:'temporal_attestation',reason:'temporal_attestation'};
  return error instanceof CPUFailure?{phase:error.phase,category:error.category,...(error.status===undefined?{}:{status:error.status}),...(error.transport?{error_name:error.transport.name,reason:error.transport.reason}:{}),...(error.startup?{reason:error.startup.reason,...(error.startup.exitCode===undefined?{}:{exit_code:error.startup.exitCode})}:{})}:dispatchDiagnostic(error);
}
function cpuAPIFailure(phase:CPUPhase,error:unknown):CPUFailure {return new CPUFailure(phase,'cpu_api',undefined,transportFailure(error).transport);}
const DIAGNOSTIC_PHASES=new Set(['start','inactivity','egress','ready','ready_timeout','execute','status','upload','bridge','controller']);
const DIAGNOSTIC_REASONS=new Set(['redirect','invalid_header','dns','timeout','unsupported_api','other','http_refusal','configuration','response','not_running','task_failed','task_missing','process_exit','startup_image','startup_capacity','startup_configuration','startup_unknown','temporal_attestation']);
type ClosedDiagnostic={phase:string;error_name:TransportName;reason:string;http_status?:number;exit_code?:number;timestamp:number;startup_stage?:string;startup_elapsed_ms?:number;startup_uncertain?:boolean};
function checkedDiagnostic(value:unknown):ClosedDiagnostic|null {
  if(!value||typeof value!=='object'||Array.isArray(value))return null;
  const v=value as Record<string,unknown>;
  if(Object.keys(v).some(k=>!['phase','error_name','reason','http_status','exit_code','timestamp','startup_stage','startup_elapsed_ms','startup_uncertain'].includes(k))||!DIAGNOSTIC_PHASES.has(String(v.phase))||!['TypeError','TimeoutError','AbortError','Other'].includes(String(v.error_name))||!DIAGNOSTIC_REASONS.has(String(v.reason))||!Number.isSafeInteger(v.timestamp)||Number(v.timestamp)<0||!(v.http_status===undefined||Number.isInteger(v.http_status)&&Number(v.http_status)>=100&&Number(v.http_status)<=599)||!(v.exit_code===undefined||Number.isInteger(v.exit_code)&&Number(v.exit_code)>=0&&Number(v.exit_code)<=255))return null;
  if(v.startup_stage!==undefined&&(!['claimed','lease','start','inactivity','egress','ready','process','execute','accepted','stop'].includes(String(v.startup_stage))||!Number.isSafeInteger(v.startup_elapsed_ms)||Number(v.startup_elapsed_ms)<0||Number(v.startup_elapsed_ms)>CPU_TIMEOUT_MS||typeof v.startup_uncertain!=='boolean'))return null;
  if(v.startup_stage===undefined&&(v.startup_elapsed_ms!==undefined||v.startup_uncertain!==undefined))return null;
  return v as ClosedDiagnostic;
}
function closedDiagnostic(error:unknown):ClosedDiagnostic {
  const d=cpuDiagnostic(error),category=String(d.category);
  const reason=typeof d.reason==='string'?d.reason:category.endsWith('_http')?'http_refusal':category.endsWith('_configuration')?'configuration':category.endsWith('_response')?'response':category==='cpu_not_running'?'not_running':category==='cpu_task_failed'?'task_failed':category==='cpu_task_missing'?'task_missing':'other';
  return checkedDiagnostic({phase:typeof d.phase==='string'?d.phase:category.startsWith('bridge_')?'bridge':'controller',error_name:typeof d.error_name==='string'?d.error_name:'Other',reason,...(typeof d.status==='number'?{http_status:d.status}:{}),...(typeof d.exit_code==='number'?{exit_code:d.exit_code}:{}),timestamp:Date.now()})!;
}

async function bridge(env:Env,path:string,body?:unknown,domain:'video'|'photo'='video'):Promise<Record<string,unknown>> {
  let base:URL;try {base=new URL(env.EDGE_WORKER_URL);}catch {throw new BridgeFailure('bridge_configuration');}
  if (base.protocol!=='https:'||!base.hostname.endsWith('.supabase.co')||!env.EDGE_SERVICE_ROLE_KEY) throw new BridgeFailure('bridge_configuration');
  if(domain==='photo')base=new URL('/functions/v1/photo-quality-worker',base.origin);
  let response:Response;try {response=await fetch(`${base.toString().replace(/\/$/,'')}/${path}`,{
    method:body===undefined?'GET':'POST',headers:{Authorization:`Bearer ${env.EDGE_SERVICE_ROLE_KEY}`,apikey:env.EDGE_SERVICE_ROLE_KEY,'Content-Type':'application/json',...(env.EDGE_FUNCTION_REGION&&EDGE_REGIONS.has(env.EDGE_FUNCTION_REGION)?{'x-region':env.EDGE_FUNCTION_REGION}:{})},
    // workerd rejects redirect:'error' before issuing this subrequest. Manual
    // mode never follows/forwards credentials; non-2xx stays a closed refusal.
    body:body===undefined?undefined:JSON.stringify(body),redirect:'manual',signal:AbortSignal.timeout(domain==='photo'&&path==='judge'?120_000:50_000)});}catch(error) {throw transportFailure(error);}
  if (!response.ok) throw new AuthorityRefusal(response.status);
  try {return await response.json() as Record<string,unknown>;}catch {throw new BridgeFailure('bridge_response');}
}

export class MediaEgress extends WorkerEntrypoint<Env,EgressProps> {
  fetch(request:Request):Promise<Response> {return egress(request,this.ctx.props);}
}

/** Exactly two configured CPU atoms. Database remains job/cost/privacy authority. */
export class PropertyVideoCPU extends DurableObject<Env> {
  protected photoMotionOnly=false;
  private advancing=false;
  private reconcilingHeld=false;
  /** In-memory only: the capability set this instance last bound for its process. */
  private egressBound?:string;
  constructor(ctx:DurableObjectState,env:Env) {
    super(ctx,env);
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS slot (id INTEGER PRIMARY KEY CHECK(id=1), state TEXT NOT NULL)');
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS diagnostic (id INTEGER PRIMARY KEY CHECK(id=1), observation TEXT NOT NULL)');
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS temporal_attestation (task_id TEXT PRIMARY KEY, observation TEXT NOT NULL)');
  }
  /** Fixed-slot private inspection does not wake work, change leases or touch a CPU. */
  async diagnostic():Promise<ClosedDiagnostic|null> {
    const row=this.ctx.storage.sql.exec<{observation:string}>('SELECT observation FROM diagnostic WHERE id=1').toArray()[0];
    if(!row)return null;try{return checkedDiagnostic(JSON.parse(row.observation));}catch{return null;}
  }
  /** Existing private fixed-slot diagnostic; bounded metadata, no pixels, URLs or secrets. */
  async temporalAttestations():Promise<TemporalAttestationDiagnostic[]> {
    return this.ctx.storage.sql.exec<{observation:string}>('SELECT observation FROM temporal_attestation ORDER BY rowid DESC LIMIT 100').toArray().flatMap(row=>{
      try{if(row.observation.length>2048)return[];const value=checkedTemporalAttestation(JSON.parse(row.observation));return value?[diagnosticTemporalAttestation(value)]:[];}catch{return[];}
    });
  }
  private retainTemporalAttestation(value:TemporalAttestation):void {
    const body=JSON.stringify(value);
    const prior=this.ctx.storage.sql.exec<{observation:string}>('SELECT observation FROM temporal_attestation WHERE task_id=?',value.task_id).toArray()[0];
    if(prior&&prior.observation!==body)throw new TemporalEnvelopeRefusal();
    if(!prior)this.ctx.storage.sql.exec('INSERT INTO temporal_attestation (task_id,observation) VALUES (?,?)',value.task_id,body);
  }
  private async checkedPendingTemporal(state:SlotState):Promise<void> {
    if(state.pendingCallback?.path!=='qc'||!('temporal'in state.pendingCallback.body)&&!(state.task?.action==='extract_frames'&&state.task.temporal_qc))return;
    if(state.task?.action!=='extract_frames'||!state.taskID||!state.temporalAttestation)throw new TemporalEnvelopeRefusal();
    const checked=await attestTemporalExtract(state.task,state.pendingCallback.body,state.temporalProducer,state.taskID);
    const{mode:currentMode,...current}=checked.attestation;const{mode:savedMode,...saved}=state.temporalAttestation;
    if(!['added-legacy-limits','preserved-versioned-limits'].includes(savedMode)||JSON.stringify(current)!==JSON.stringify(saved))throw new TemporalEnvelopeRefusal();
    const row=this.ctx.storage.sql.exec<{observation:string}>('SELECT observation FROM temporal_attestation WHERE task_id=?',state.taskID).toArray()[0];
    if(row?.observation!==JSON.stringify(state.temporalAttestation))throw new TemporalEnvelopeRefusal();
  }
  /** Advisory motion check (owner decision 12 Nov 2026): an unattestable
   * measurement is an unknown verdict, never a hold. The frames go to the
   * authority without a report; no verdict is computed, changed or upgraded. */
  private dropTemporal(state:SlotState):void {
    if(state.task?.action==='extract_frames')delete (state.task as {temporal_qc?:unknown}).temporal_qc;
    if(state.pendingCallback?.path==='qc')delete (state.pendingCallback.body as Record<string,unknown>).temporal;
    state.temporalProducer=undefined;state.temporalAttestation=undefined;state.temporalUnattested=true;this.save(state);
  }
  /** What this slot holds, for the dispatcher's admission order. Read-only:
   * no alarm, lease, process or saved state is touched. */
  async holder():Promise<{id:string;state:'fresh'|'waiting'|'warm'|'busy';since?:number}|null> {
    const state=this.read();
    if(!state)return null;
    if(!('jobID'in state))return{id:state.checkID,state:photoPrewarmOnly(state)?'warm':'busy'};
    if(this.waitingIdle(state))return{id:state.jobID,state:'waiting',since:state.waiting.since};
    return{id:state.jobID,state:state.task||state.taskID||state.pendingCallback||state.photoMotionStartup||state.temporalHold?'busy':'fresh'};
  }
  /** A supplier wait may be replaced only between its looks. While its own
   * look is in flight the alarm turn still owns the saved state, and replacing
   * it there would let that turn write the old job back over the new owner. */
  private waitingIdle(state:WorkState|null):state is SlotState&{waiting:{since:number;at:number}} {
    return !this.advancing&&videoWaitOnly(state);
  }
  private read():WorkState|null {const row=this.ctx.storage.sql.exec<{state:string}>('SELECT state FROM slot WHERE id=1').toArray()[0];return row?JSON.parse(row.state):null;}
  private save(state:WorkState):void {this.ctx.storage.sql.exec('INSERT INTO slot (id,state) VALUES (1,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state',JSON.stringify(state));}
  /** Normal dispatch can reconcile a stopped aerial operation. It never
   * retries the denied output path, starts a process or changes SQL cost holds. */
  private async reconcileHeldTerminal(state:SlotState):Promise<boolean> {
    const startup=state.photoMotionStartup,task=state.task;
    if(!this.photoMotionOnly||this.advancing||this.reconcilingHeld||!startup?.held||startup.stage!=='stop'||startup.nativePending||startup.uncertain||!startup.startIssued||!startup.executeIssued||state.pendingCallback||state.photoMotionTerminal||state.temporalHold||!task||!state.taskID||!aerialWorkKind(state.workKind)||!photoMotionTask(task)||!('composition_profile'in task)||![AERIAL_INPUT_PROFILE,AERIAL_QUALIFY_PROFILE].includes(task.composition_profile as any))return false;
    const kind=task.composition_profile===AERIAL_INPUT_PROFILE?'aerial_opening_input_v1':'aerial_opening_qualify_v1';
    if(state.slot!=='slot-0'||state.workKind!==kind||state.jobID!==task.job_id||!/^[a-f0-9]{64}$/.test(state.taskID)||!Number.isSafeInteger(startup.begunAt)||startup.begunAt<=0||startup.begunAt>Date.now()||startup.begunAt!==state.startedAt||startup.begunAt!==state.photoMotionStartedAt||startup.deadline!==startup.begunAt+COLD_READY_MS)return false;
    try{
      const current=photoMotionProducer(this.ctx.container?.images.cpu,this.env.CPU_PHOTO_MOTION_IMAGE_URI,this.env.CPU_PHOTO_MOTION_CONTROLLER_SHA256,this.env.CPU_PHOTO_MOTION_RENDERER_SHA256);
      samePhotoMotionProducer(state.photoMotionProducer,task.producer_identity);
      if(state.photoMotionImage!==task.producer_identity.image_uri)return false;
      const held=heldPhotoMotionCompatibility(this.env);
      let compatible=false;
      if(held&&state.jobID===held.jobID&&kind==='aerial_opening_input_v1')try{samePhotoMotionProducer(task.producer_identity,held.producer);compatible=true;}catch{ /* Not this one approved historical ownership. */ }
      if(compatible){if(current.image_uri!==held!.producer.image_uri||current.renderer_source_sha256!==held!.producer.renderer_source_sha256)return false;}
      else{samePhotoMotionProducer(task.producer_identity,current);if(!Number.isSafeInteger(startup.nativeStopAcknowledgedAt)||startup.nativeStopAcknowledgedAt!<startup.begunAt||startup.nativeStopAcknowledgedAt!>Date.now())return false;}
    }catch{return false;}
    this.reconcilingHeld=true;
    try{
      const original=JSON.stringify(state),phase=kind==='aerial_opening_input_v1'?'input':'qualification';
      const sourceSHA='source'in task?task.source.sha256:('source_sha256'in task?task.source_sha256:undefined);
      const body={job_id:state.jobID,lease_token:task.lease_token,manifest_sha256:task.manifest_sha256,source_sha256:sourceSHA,composition_profile:task.composition_profile,producer_identity:task.producer_identity};
      const terminal=await this.bridgeFor(state,'reconcile',body);
      if(Object.keys(terminal).sort().join(',')!=='cancel_requested,composition_profile,job_id,lease_token,manifest_sha256,phase,producer_identity,source_sha256,state,terminal'||terminal.terminal!==true||!['cancelled','failed','ineligible'].includes(String(terminal.state))||typeof terminal.cancel_requested!=='boolean'||terminal.job_id!==body.job_id||terminal.lease_token!==body.lease_token||terminal.manifest_sha256!==body.manifest_sha256||terminal.source_sha256!==sourceSHA||terminal.composition_profile!==body.composition_profile||terminal.phase!==phase)return false;
      samePhotoMotionProducer(terminal.producer_identity,task.producer_identity);
      if(JSON.stringify(this.read())!==original)return false;
      // The old stage/pending tuple proves only settlement, not fulfillment.
      // Require a fresh genuine destroy ACK even for the approved old job.
      if(startup.nativeStopAcknowledgedAt===undefined&&!await this.stopPhotoStartup(state))return false;
      if(startup.nativePending||startup.uncertain||!Number.isSafeInteger(startup.nativeStopAcknowledgedAt)||startup.nativeStopAcknowledgedAt!<startup.begunAt||startup.nativeStopAcknowledgedAt!>Date.now())return false;
      const digest=async(value:string)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value))),v=>v.toString(16).padStart(2,'0')).join('');
      const audit=JSON.stringify({schema:1,job_id:state.jobID,work_kind:kind,phase,manifest_sha256:task.manifest_sha256,lease_sha256:await digest(task.lease_token),task_sha256:await digest(JSON.stringify(task)),producer_identity:task.producer_identity,authority_state:terminal.state,cancel_requested:terminal.cancel_requested,original_started_at:state.photoMotionStartedAt,original_process_stop_at:state.photoMotionStartedAt!+CPU_TIMEOUT_MS,native_stop_acknowledged_at:startup.nativeStopAcknowledgedAt,reconciled_at:Date.now(),cost_liability_unchanged:true});
      const stopped=JSON.stringify(state);
      this.ctx.storage.transactionSync(()=>{
        if(JSON.stringify(this.read())!==stopped)throw Error('held_reconciliation_state_changed');
        this.ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS terminal_reconciliation (job_id TEXT NOT NULL, lease_sha256 TEXT NOT NULL, observation TEXT NOT NULL, PRIMARY KEY(job_id,lease_sha256))');
        const leaseHash=JSON.parse(audit).lease_sha256;
        this.ctx.storage.sql.exec('INSERT INTO terminal_reconciliation (job_id,lease_sha256,observation) VALUES (?,?,?)',state.jobID,leaseHash,audit);
        this.ctx.storage.sql.exec('DELETE FROM slot WHERE id=1');
      });
      await this.ctx.storage.deleteAlarm();return true;
    }catch{return false;}finally{this.reconcilingHeld=false;}
  }
  /** Internal housekeeping only: derive the saved owner, never admit work. */
  async reconcileHeldOnly():Promise<string|null> {
    if(!this.photoMotionOnly||this.env.ENABLED!=='true')return null;
    const prior=this.read();
    if(!prior||!('jobID'in prior)||!prior.photoMotionStartup?.held)return null;
    return await this.reconcileHeldTerminal(prior)?prior.jobID:null;
  }
  async wake(jobID:string,slot:'slot-0'|'slot-1',workKind?:AerialWorkKind):Promise<boolean> {
    if(workKind!==undefined&&(!this.photoMotionOnly||!aerialWorkKind(workKind)))return false;
    if (this.env.ENABLED!=='true'||!UUID.test(jobID)||!['slot-0','slot-1'].includes(slot)) return false;
    if(this.reconcilingHeld)return false;
    let prior=this.read();
    // An unused photo warm-up never delays video work: release it (stop()
    // destroys that process, so this job still boots its own fresh one).
    if(photoPrewarmOnly(prior)){await this.stop();prior=null;}
    if(!this.photoMotionOnly&&videoWaitOnly(prior)){
      // A supplier wait holds no lease, task or process, so another job takes
      // the slot at once (between its looks). For the waiting job itself, a
      // generic wake moments after its own look keeps the scheduled one.
      if(prior.jobID===jobID){if(Date.now()-prior.waiting.at<WAIT_QUIET_MS)return true;}
      else if(this.waitingIdle(prior))prior=null;
    }
    if(prior&&'jobID'in prior&&this.photoMotionOnly&&prior.photoMotionStartup?.held){
      const same=prior.jobID===jobID&&prior.workKind===workKind;
      if(!await this.reconcileHeldTerminal(prior))return same;
      // A terminal saved job is only reconciled, never rearmed by this wake.
      if(prior.jobID===jobID)return true;
      prior=this.read();
    }
    if(prior&&'jobID'in prior&&prior.workKind!==workKind)return false;
    // A hold saved by an earlier controller release is let go on its own alarm.
    if(prior&&'jobID'in prior&&prior.temporalHold&&prior.jobID!==jobID){await this.ctx.storage.setAlarm(Date.now()+1);return false;}
    if (prior&&('kind'in prior&&prior.kind==='photo_quality'||!('jobID'in prior)||prior.jobID!==jobID)) return false;
    if(prior&&'jobID'in prior&&this.photoMotionOnly&&prior.photoMotionStartup?.held)return true; // no automatic rearm of uncertain startup
    if (!prior) this.save({jobID,slot,token:crypto.randomUUID()+crypto.randomUUID(),...(workKind?{workKind}:{} )});
    await this.ctx.storage.setAlarm(Date.now()+1);
    return true;
  }
  async wakePhoto(checkID:string,slot:'slot-0'|'slot-1'):Promise<boolean> {
    if(this.env.ENABLED!=='true'||!UUID.test(checkID)||!['slot-0','slot-1'].includes(slot))return false;
    let prior=this.read();
    // A slot that only waits on a video supplier holds nothing and is
    // available. (The dispatcher offers a free slot first.)
    if(this.waitingIdle(prior))prior=null;
    if(photoPrewarmOnly(prior)){
      // The warm process has never held a lease, a task or customer bytes, so a
      // ready check may use it instead of waiting for the check it was started
      // for. It keeps the token that process was started with.
      this.save({kind:'photo_quality',checkID,slot:prior.slot,token:prior.token});
      await this.ctx.storage.setAlarm(Date.now()+1);return true;
    }
    if(prior&&(!('kind'in prior)||prior.kind!=='photo_quality'||prior.checkID!==checkID))return false;
    if(!prior)this.save({kind:'photo_quality',checkID,slot,token:crypto.randomUUID()+crypto.randomUUID()});
    await this.ctx.storage.setAlarm(Date.now()+1);return true;
  }
  /** Best effort: start this slot's process while the edit is still generating,
   * so the comparison does not wait for a cold start. Never displaces work (a
   * slot that only waits on a video supplier holds none), issues no lease and
   * binds no egress; any real work may take the slot. */
  async prewarmPhoto(checkID:string,slot:'slot-0'|'slot-1'):Promise<boolean> {
    if(this.env.ENABLED!=='true'||!UUID.test(checkID)||!['slot-0','slot-1'].includes(slot))return false;
    let prior=this.read();
    if(this.waitingIdle(prior))prior=null;
    if(prior){const owner=prior as PhotoSlotState;return owner.kind==='photo_quality'&&owner.checkID===checkID;}
    if(this.ctx.container?.running)return false;
    this.save({kind:'photo_quality',checkID,slot,token:crypto.randomUUID()+crypto.randomUUID(),prewarmUntil:Date.now()+PHOTO_PREWARM_HOLD_MS});
    await this.ctx.storage.setAlarm(Date.now()+1);return true;
  }
  private bridgeFor(state:SlotState,path:string,body?:unknown):Promise<Record<string,unknown>>{
    if(state.workKind!==undefined&&!this.photoMotionOnly)throw Error('aerial_work_class_conflict');
    const prefix=state.workKind==='aerial_opening_input_v1'?'aerial-input/':state.workKind==='aerial_opening_qualify_v1'?'aerial-qualify/':'';
    if(state.workKind!==undefined&&!prefix)throw Error('aerial_work_kind_conflict');
    return bridge(this.env,prefix+path,body);
  }
  private async stop():Promise<void> {
    if (this.ctx.container?.running) await this.ctx.container.destroy();
    this.egressBound=undefined;
    this.ctx.storage.sql.exec('DELETE FROM slot WHERE id=1');
    await this.ctx.storage.deleteAlarm();
  }
  /** SQL owns the supplier receipt and its polling lease. While a supplier
   * renders this slot keeps no lease, task or process, and any other work may
   * take it (wake, wakePhoto, prewarmPhoto). It only remembers to look again at
   * the function's own re-check cadence instead of at the next cron minute.
   * After WAIT_PARK_MS of continuous waiting it lets go and cron takes over. */
  private async park(state:SlotState):Promise<void> {
    const now=Date.now(),since=state.waiting?.since??now;
    if(now-since>=WAIT_PARK_MS){await this.stop();return;}
    if(this.ctx.container?.running)await this.ctx.container.destroy();
    this.egressBound=undefined;
    state.waiting={since,at:now};this.save(state);
    await this.ctx.storage.setAlarm(now+WAIT_RECHECK_MS);
  }
  /** A finished job frees this slot between cron minutes. Read the durable
   * queue once and take the next item now, so a run of short tasks (ten photo
   * preparations, say) goes back to back instead of two per minute. Called only
   * after this ownership ran a CPU task, so an idle or already-terminal queue
   * item cannot loop. SQL claims still decide every action of the next job. */
  private async continueQueue(done:SlotState):Promise<void> {
    if(this.photoMotionOnly||this.env.ENABLED!=='true'||!this.env.CPU)return;
    try{
      const queue=await bridge(this.env,'queue');
      const jobs=queue.enabled===true&&Array.isArray(queue.jobs)?queue.jobs.slice(0,32) as Array<{job_id?:unknown;source_mode?:unknown;work_kind?:unknown}|null>:[];
      const sibling=jobs.length?await this.env.CPU.getByName(done.slot==='slot-0'?'slot-1':'slot-0').holder():null;
      for(const job of jobs){
        // Photo Motion and aerial work belong to their own separately budgeted atom.
        if(!job||typeof job.job_id!=='string'||!UUID.test(job.job_id)||job.source_mode!=null||job.work_kind!==undefined)continue;
        if(job.job_id===done.jobID||sibling?.id===job.job_id)continue;
        if(!this.read())this.save({jobID:job.job_id,slot:done.slot,token:crypto.randomUUID()+crypto.randomUUID()});
        break;
      }
    }catch(error){console.warn('property_video_continue_refused',dispatchDiagnostic(error));}
    // Whoever holds the slot now (the item taken above, or a wake that arrived
    // while the queue was read) is looked at immediately.
    if(this.read())await this.ctx.storage.setAlarm(Date.now()+1);
  }
  private async cpu(path:string,body?:unknown):Promise<Record<string,unknown>> {
    const state=this.read();
    const phase:CPUPhase=path==='ready'?'ready':path==='execute'?'execute':path==='upload'?'upload':'status';
    if (!state||!this.ctx.container?.running) throw new CPUFailure(phase,'cpu_not_running');
    let response:Response;try {response=await this.ctx.container.getTcpPort(8080).fetch(`http://container/${path}`,{method:body===undefined?'GET':'POST',
      headers:{Authorization:`Bearer ${state.token}`,'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(10_000)});}catch(error){throw new CPUFailure(phase,'cpu_transport',undefined,transportFailure(error).transport);}
    if (!response.ok) throw new CPUFailure(phase,'cpu_http',response.status);
    try {return await response.json() as Record<string,unknown>;}catch {throw new CPUFailure(phase,'cpu_response');}
  }
  private async bindEgress(props:EgressProps):Promise<void> {
    if (!this.ctx.container) throw Error('container_binding_missing');
    const exports=this.ctx.exports as unknown as {MediaEgress(options:{props:EgressProps}):Fetcher};
    const binding=exports.MediaEgress({props});
    try {await this.ctx.container.interceptOutboundHttps('*',binding);}catch(error){throw cpuAPIFailure('egress',error);}
    // HTTP remains un-intercepted, therefore blocked by enableInternet:false.
  }
  /** One absolute startup clock. Racing a native RPC is NOT cancellation. */
  private async photoStartupWait<T>(state:SlotState,stage:NonNullable<SlotState['photoMotionStartup']>['stage'],operation:()=>Promise<T>,native=false,deadline=state.photoMotionStartup!.deadline,interrupted?:Promise<never>):Promise<T> {
    const startup=state.photoMotionStartup!;
    startup.stage=stage;
    if(native){startup.nativePending=true;delete startup.nativeStopAcknowledgedAt;}
    this.save(state);
    const remaining=deadline-Date.now();
    if(!Number.isSafeInteger(deadline)||remaining<=0){
      if(native)startup.uncertain=true;
      this.save(state);
      throw new CPUFailure('ready_timeout','cpu_api',undefined,{name:'TimeoutError',reason:'timeout'});
    }
    let timer:ReturnType<typeof setTimeout>|undefined;
    let settled=false,fulfilled=false;
    try {
      const pending=operation().then(value=>{settled=true;fulfilled=true;return value;},error=>{settled=true;throw error;});
      return await Promise.race([pending,...(interrupted?[interrupted]:[]),new Promise<never>((_,reject)=>{timer=setTimeout(()=>reject(new CPUFailure('ready_timeout','cpu_api',undefined,{name:'TimeoutError',reason:'timeout'})),remaining);})]);
    } finally {
      if(timer!==undefined)clearTimeout(timer);
      if(native){
        if(settled){
          if(stage==='stop'&&!fulfilled)startup.uncertain=true;
          delete startup.nativePending;
          if(stage==='stop'&&fulfilled&&!startup.uncertain)startup.nativeStopAcknowledgedAt=Date.now();
          // Terminal stop acknowledgement and pending removal are one durable write.
          // A reset before this save still retains pending/unknown ownership.
          if(this.photoMotionOnly&&stage==='stop'&&fulfilled&&state.photoMotionTerminal&&!startup.uncertain)
            state.photoMotionTerminal.stoppedAt=Date.now();
        }else startup.uncertain=true;
        this.save(state);
      }
    }
  }
  private async photoStartupLease(state:SlotState,deadline?:number):Promise<void> {
    const current=await this.photoStartupWait(state,'lease',()=>this.bridgeFor(state,'heartbeat',{job_id:state.jobID,lease_token:state.task!.lease_token}),false,deadline);
    if(current.current!==true)throw new AuthorityRefusal(409);
    state.heartbeatAt=Date.now();this.save(state);
  }
  private async photoStartupProcess(state:SlotState):Promise<void> {
    // GET /ready is not authenticated in the existing image. This POST proves
    // possession of this operation's private token before an unissued execute.
    const probe=await this.photoStartupWait(state,'process',()=>this.cpu('status',{task_id:'startup-process-probe'}));
    if(probe.state!=='missing')throw new CPUFailure('start','cpu_start_failed',undefined,undefined,{reason:'startup_unknown'});
  }
  private async photoStartup(state:SlotState,recovering:boolean):Promise<void> {
    const container=this.ctx.container,task=state.task;
    if(!container||!photoMotionTask(task)||!this.photoMotionOnly)throw Error('photo_motion_process_binding_refused');
    if(recovering){
      const saved=state.photoMotionStartup;
      if(!saved){
        const begunAt=Number.isSafeInteger(state.photoMotionStartedAt)?state.photoMotionStartedAt!:Number.isSafeInteger(state.startedAt)?state.startedAt!:Date.now();
        state.photoMotionStartup={begunAt,deadline:begunAt+COLD_READY_MS,stage:'execute',executeIssued:true,startIssued:true,uncertain:true};this.save(state);
      }
      if(saved?.nativePending){saved.uncertain=true;this.save(state);}
      // Historical ambiguous startup has no issued marker. Never infer that an
      // accepted execute did not happen, and never start a replacement process.
      if(!saved||saved.nativePending||saved.uncertain||saved.startIssued!==true||saved.executeIssued!==false||!Number.isSafeInteger(saved.begunAt)||saved.begunAt<0||saved.begunAt>Date.now()||saved.begunAt!==state.startedAt||saved.deadline!==saved.begunAt+COLD_READY_MS||state.photoMotionStartedAt!==saved.begunAt||!container.running)
        throw new CPUFailure('start','cpu_start_failed',undefined,undefined,{reason:'startup_unknown'});
      const producer=photoMotionProducer(container.images.cpu,this.env.CPU_PHOTO_MOTION_IMAGE_URI,this.env.CPU_PHOTO_MOTION_CONTROLLER_SHA256,this.env.CPU_PHOTO_MOTION_RENDERER_SHA256);
      samePhotoMotionProducer(state.photoMotionProducer,producer);samePhotoMotionProducer(task.producer_identity,producer);
      if(state.photoMotionImage!==producer.image_uri)throw Error('photo_motion_process_binding_refused');
      await this.photoStartupLease(state);
      await this.photoStartupProcess(state);
    }else{
      if(container.running)throw Error('photo_motion_requires_fresh_process');
      const begunAt=state.startedAt!;
      state.photoMotionStartup={begunAt,deadline:begunAt+COLD_READY_MS,stage:'claimed',executeIssued:false,startIssued:false};
      state.photoMotionProducer=photoMotionProducer(container.images.cpu,this.env.CPU_PHOTO_MOTION_IMAGE_URI,this.env.CPU_PHOTO_MOTION_CONTROLLER_SHA256,this.env.CPU_PHOTO_MOTION_RENDERER_SHA256);
      samePhotoMotionProducer(task.producer_identity,state.photoMotionProducer);
      state.photoMotionImage=state.photoMotionProducer.image_uri;state.photoMotionStartedAt=begunAt;this.save(state);
      await this.photoStartupLease(state);
      state.photoMotionStartup.stage='start';state.photoMotionStartup.startIssued=true;this.save(state);
      try{container.start({image:state.photoMotionImage,instance:'standard-3',enableInternet:false,env:{CONTAINER_TOKEN:state.token,MEDIA_HOSTS:this.env.MEDIA_HOSTS,PHOTO_MOTION_STOP_AT_MS:String(begunAt+CPU_TIMEOUT_MS),PHOTO_MOTION_PRODUCER_IDENTITY:JSON.stringify(state.photoMotionProducer)},labels:{workload:'property-video'}});}catch(error){throw cpuAPIFailure('start',error);}
    }
    let exited:CPUFailure|undefined;
    let startupFailureSignal:Promise<never>;
    try{
      startupFailureSignal=container.monitor().then(()=>{exited=new CPUFailure('start','cpu_start_failed',undefined,undefined,{reason:'process_exit',exitCode:0});throw exited;},error=>{exited=startupFailure(error);throw exited;});
      this.ctx.waitUntil(startupFailureSignal.catch(()=>{}));
    }catch(error){throw startupFailure(error);}
    await this.photoStartupWait(state,'inactivity',async()=>{try{await container.setInactivityTimeout(60_000);}catch(error){throw cpuAPIFailure('inactivity',error);}},true,state.photoMotionStartup!.deadline,startupFailureSignal);
    await this.photoStartupWait(state,'egress',()=>this.bindEgress(state.capabilities!),true,state.photoMotionStartup!.deadline,startupFailureSignal);
    for(;;){
      if(exited)throw exited;
      try{await this.photoStartupWait(state,'ready',()=>this.cpu('ready'));break;}
      catch(error){if(Date.now()>=state.photoMotionStartup!.deadline)throw error;await this.photoStartupWait(state,'ready',()=>new Promise(resolve=>setTimeout(resolve,300)));}
    }
    await this.photoStartupProcess(state);
    await this.photoStartupLease(state); // Never execute with an expired claim.
    state.photoMotionStartup!.executeIssued=true;state.photoMotionStartup!.stage='execute';this.save(state);
    const accepted=await this.photoStartupWait(state,'execute',()=>this.cpu('execute',task));
    if(typeof accepted.task_id!=='string'||!/^[0-9a-f]{64}$/.test(accepted.task_id))throw Error('cpu_receipt_invalid');
    state.taskID=accepted.task_id;state.photoMotionStartup!.stage='accepted';state.pollSince=Date.now();this.save(state);
    await this.ctx.storage.setAlarm(Date.now()+this.pollDelay(state));
  }
  private async stopPhotoStartup(state:SlotState):Promise<boolean> {
    if(!state.photoMotionStartup!.startIssued&&!this.ctx.container?.running)return true;
    try{
      // destroy() itself cannot be aborted. Until it acknowledges, retain the
      // slot and funding uncertainty; a late destroy must not hit a new task.
      await this.photoStartupWait(state,'stop',()=>this.ctx.container!.destroy(),true,Date.now()+60_000);
      return true;
    }catch{state.photoMotionStartup!.uncertain=true;this.save(state);return false;}
  }
  /** A validated uploaded/inspected receipt survives stop/reset independently of the process. */
  private async completePhotoMotion(state:SlotState):Promise<void> {
    const task=state.task,terminal=state.photoMotionTerminal,pending=state.pendingCallback,startup=state.photoMotionStartup;
    if(!this.photoMotionOnly||!photoMotionTask(task)||!terminal||!pending||!startup||
      pending.path!==photoMotionCallbackPath(task))throw Error('photo_motion_terminal_binding_refused');
    samePhotoMotionProducer(state.photoMotionProducer,photoMotionProducer(this.ctx.container?.images.cpu,this.env.CPU_PHOTO_MOTION_IMAGE_URI,this.env.CPU_PHOTO_MOTION_CONTROLLER_SHA256,this.env.CPU_PHOTO_MOTION_RENDERER_SHA256));
    checkedPhotoMotionResult(pending.body,task);
    if(terminal.stoppedAt===undefined){
      // A native RPC that outlived its isolate is not acknowledged cancellation.
      // Keep the completed receipt, exact ownership and an unknown/full liability.
      if(startup.nativePending||startup.uncertain){startup.uncertain=true;this.save(state);}
      else await this.stopPhotoStartup(state); // acknowledged time is persisted with nativePending removal
    }
    const result={...pending.body,...photoMotionWall(state.photoMotionStartedAt,terminal.stoppedAt!==undefined&&!startup.uncertain,terminal.stoppedAt??Date.now()),producer_identity:state.photoMotionProducer};
    checkedPhotoMotionResult(result,task,true);
    state.pendingCallback={path:pending.path,body:result};state.photoMotionTerminal=undefined;
    this.save(state);
    await this.ctx.storage.setAlarm(Date.now()+1);
  }
  private async boot(state:WorkState):Promise<void> {
    const container=this.ctx.container;
    if (!container||!state.capabilities) throw Error('cpu_configuration_missing');
    let startup:CPUFailure|undefined;
    const temporal='task'in state&&state.task?.action==='extract_frames'&&state.task.temporal_qc;
    const photoTask='task'in state&&photoMotionTask(state.task)?state.task:undefined;
    const photo=!!photoTask;
    if(photo!==this.photoMotionOnly)throw Error('photo_motion_class_conflict');
    if(photoTask&&'jobID'in state){
      if(container.running)throw Error('photo_motion_requires_fresh_process');
      state.photoMotionProducer=photoMotionProducer(container.images.cpu,this.env.CPU_PHOTO_MOTION_IMAGE_URI,this.env.CPU_PHOTO_MOTION_CONTROLLER_SHA256,this.env.CPU_PHOTO_MOTION_RENDERER_SHA256);
      samePhotoMotionProducer(photoTask.producer_identity,state.photoMotionProducer);
      state.photoMotionImage=state.photoMotionProducer.image_uri;
      state.photoMotionStartedAt=Date.now();this.save(state);
    }
    const startImage=container.images.cpu;
    let producer:ReturnType<typeof bindTemporalProducer>|undefined;
    if(temporal&&'jobID'in state)try{
      // A deployment never retroactively binds an already-running old process.
      if(container.running)throw new TemporalEnvelopeRefusal();
      producer=bindTemporalProducer(state.task as Extract<CPUAction,{action:'extract_frames'}>,this.env.CPU_TEMPORAL_PRODUCER_IMAGE_URI,startImage);
    }catch(error){
      // Advisory motion check: a producer that cannot be attested measures
      // nothing. The same task object is executed, now without the request.
      if(!(error instanceof TemporalEnvelopeRefusal))throw error;this.dropTemporal(state);
    }
    if (!container.running) {
      try {container.start({image:startImage,instance:'standard-3',enableInternet:false,
        env:{CONTAINER_TOKEN:state.token,MEDIA_HOSTS:this.env.MEDIA_HOSTS,...(photo&&'jobID'in state?{PHOTO_MOTION_STOP_AT_MS:String(state.photoMotionStartedAt!+CPU_TIMEOUT_MS),PHOTO_MOTION_PRODUCER_IDENTITY:JSON.stringify(state.photoMotionProducer)}:{})},labels:{workload:'property-video'}});}catch(error){throw cpuAPIFailure('start',error);}
      if(producer&&'jobID'in state){state.temporalProducer=producer;this.save(state);}
      // start() only validates options. Its later image/process failures are
      // observable through monitor(), not through the synchronous return.
      try {this.ctx.waitUntil(container.monitor().then(
        ()=>{startup=new CPUFailure('start','cpu_start_failed',undefined,undefined,{reason:'process_exit',exitCode:0});},
        error=>{startup=startupFailure(error);},
      ));}catch(error){throw startupFailure(error);}
      try {await container.setInactivityTimeout(60_000);}catch(error){throw cpuAPIFailure('inactivity',error);}
    }
    await this.bindEgress(state.capabilities);
    // Bound for this process: close status looks do not re-issue the same
    // interceptor while the task is downloading its inputs.
    this.egressBound=JSON.stringify(state.capabilities);
    const deadline=Date.now()+COLD_READY_MS;
    let last:unknown;
    while (Date.now()<deadline) {
      if(startup)throw startup;
      try {await this.cpu('ready');return;} catch(error) {last=error;await new Promise(resolve=>setTimeout(resolve,300));}
    }
    throw new CPUFailure('ready_timeout',last instanceof CPUFailure?last.category:'cpu_not_running',last instanceof CPUFailure?last.status:undefined,last instanceof CPUFailure?last.transport:undefined);
  }
  async alarm():Promise<void> {
    if (this.advancing) {await this.ctx.storage.setAlarm(Date.now()+POLL_MS);return;}
    this.advancing=true;
    try {await this.advance();} finally {this.advancing=false;}
  }
  private async advance():Promise<void> {
    const current=this.read();
    if(current&&'kind'in current&&current.kind==='photo_quality'){await this.advancePhoto(current);return;}
    let state=current as SlotState|null;
    if (!state) return;
    if (this.env.ENABLED!=='true') {await this.stop();return;}
    if(state.temporalHold){
      // Saved by a controller release from before the motion check became
      // advisory. Let it go: the retained work continues without a report (a
      // long-expired lease is then refused by the authority and frees the slot).
      delete state.temporalHold;this.dropTemporal(state);
    }
    try {
      if(this.photoMotionOnly&&state.photoMotionStartup?.held){await this.ctx.storage.deleteAlarm();return;}
      if(this.photoMotionOnly&&state.photoMotionTerminal){await this.completePhotoMotion(state);return;}
      if(this.photoMotionOnly&&state.taskID&&!state.pendingCallback&&state.photoMotionStartup&&(state.photoMotionStartup.nativePending||state.photoMotionStartup.uncertain)){state.photoMotionStartup.uncertain=true;this.save(state);throw new CPUFailure('start','cpu_start_failed',undefined,undefined,{reason:'startup_unknown'});}
      if(this.photoMotionOnly&&state.task&&!state.taskID&&!state.pendingCallback){await this.photoStartup(state,true);return;}
      // Refresh an already-running process only when executing its work alarm,
      // never as a side effect of a read-only diagnostic RPC/constructor.
      if((!this.photoMotionOnly||!state.photoMotionStartup)&&this.ctx.container?.running)try{await this.ctx.container.setInactivityTimeout(60_000);}catch(error){throw cpuAPIFailure('inactivity',error);}
      if (state.pendingCallback) {
        if(['finish','audio-preflight','prepared-finish'].includes(state.pendingCallback.path)){
          if(isV1PhotoMotionTask(state.task)){
            if(!this.photoMotionOnly)throw Error('photo_motion_process_binding_refused');
            // Completed old uploads keep their original fixed producer and clock.
            // No V1 task may boot/execute on the V2 image; only this saved receipt replays.
            checkedV1PhotoMotionCallback(state.task,state.pendingCallback,state.photoMotionImage,state.photoMotionProducer);
          }else if(isHistoricalV2PhotoMotionTask(state.task)){
            if(!this.photoMotionOnly||state.workKind!==undefined)throw Error('photo_motion_process_binding_refused');
            checkedHistoricalV2Callback(state.task,state.pendingCallback,state.photoMotionImage,state.photoMotionProducer);
          }else if(photoMotionTask(state.task)){
            if(!this.photoMotionOnly)throw Error('photo_motion_process_binding_refused');
            samePhotoMotionProducer(state.photoMotionProducer,photoMotionProducer(this.ctx.container?.images.cpu,this.env.CPU_PHOTO_MOTION_IMAGE_URI,this.env.CPU_PHOTO_MOTION_CONTROLLER_SHA256,this.env.CPU_PHOTO_MOTION_RENDERER_SHA256));
            checkedPhotoMotionResult(state.pendingCallback.body,state.task,true);
          }
        }
        try{await this.checkedPendingTemporal(state);}catch(error){if(!(error instanceof TemporalEnvelopeRefusal))throw error;this.dropTemporal(state);}
        // The receipt is durable and uploads/extraction are done. An authority
        // outage must not leave an idle CPU billed while callback retries sleep.
        if (this.ctx.container?.running&&!(this.photoMotionOnly&&state.photoMotionStartup?.uncertain)) await this.ctx.container.destroy();
        await this.bridgeFor(state,state.pendingCallback.path,state.pendingCallback.body);
        if(this.photoMotionOnly&&state.photoMotionStartup?.uncertain){state.photoMotionStartup.held=true;this.save(state);await this.ctx.storage.deleteAlarm();return;}
        state.pendingCallback=undefined;
        state.photoMotionStartup=undefined;state.photoMotionTerminal=undefined;
        state.task=undefined;state.taskID=undefined;state.outputs=undefined;state.capabilities=undefined;state.startedAt=undefined;state.heartbeatAt=undefined;state.pollSince=undefined;state.temporalUnattested=undefined;state.temporalProducer=undefined;state.temporalAttestation=undefined;state.temporalRawResult=undefined;state.photoMotionImage=undefined;state.photoMotionStartedAt=undefined;state.photoMotionProducer=undefined;
        this.save(state);
      }
      if (state.taskID&&state.task) {
        if(photoMotionTask(state.task)){
          if(!this.photoMotionOnly)throw Error('photo_motion_process_binding_refused');
          samePhotoMotionProducer(state.photoMotionProducer,photoMotionProducer(this.ctx.container?.images.cpu,this.env.CPU_PHOTO_MOTION_IMAGE_URI,this.env.CPU_PHOTO_MOTION_CONTROLLER_SHA256,this.env.CPU_PHOTO_MOTION_RENDERER_SHA256));
        }
        if (!this.ctx.container?.running||Date.now()-(state.startedAt??0)>CPU_TIMEOUT_MS) throw Error('cpu_interrupted');
        if (Date.now()-(state.heartbeatAt??0)>=60_000) {
          const current=await this.bridgeFor(state,'heartbeat',{job_id:state.jobID,lease_token:state.task.lease_token,
            ...(state.task.action==='extract_frames'?{attempt_id:state.task.attempt_id}:{})});
          if (current.current!==true) {await this.stop();return;}
          state.heartbeatAt=Date.now();this.save(state);
        }
        if(this.photoMotionOnly&&state.photoMotionStartup){
          const deadline=Math.min(Date.now()+COLD_READY_MS,state.photoMotionStartedAt!+CPU_TIMEOUT_MS);
          await this.photoStartupWait(state,'inactivity',()=>this.ctx.container!.setInactivityTimeout(60_000),true,deadline);
          await this.photoStartupWait(state,'egress',()=>this.bindEgress(state!.capabilities!),true,deadline);
          state.photoMotionStartup.stage='accepted';this.save(state);
        }else await this.bindEgressOnce(state.capabilities!);
        const status=await this.cpu('status',{task_id:state.taskID});
        if (status.state==='working') {await this.ctx.storage.setAlarm(Date.now()+this.pollDelay(state));return;}
        if (status.state==='failed'||status.state==='missing') throw new CPUFailure('status',status.state==='failed'?'cpu_task_failed':'cpu_task_missing');
        let result=status.result as Record<string,unknown>;
        if (!result||result.job_id!==state.jobID||result.lease_token!==state.task.lease_token) throw Error('cpu_receipt_identity_conflict');
        if(photoMotionTask(state.task))checkedPhotoMotionResult(result,state.task);
        if (status.state==='prepared') {
          if(state.task.action!=='compose'&&state.task.action!=='prepare_image')throw Error('cpu_protocol_refused');
          const raw=await this.bridgeFor(state,state.task.action==='prepare_image'?'prepared-outputs':'outputs',result);
          const output=(raw.output??raw) as Record<string,unknown>;
          const expiresAt=raw.expires_at??output.expires_at;
          const granted={...output,expires_at:expiresAt};
          state.outputs=granted;
          state.capabilities=outputCapabilities(granted,result,new Set(this.env.MEDIA_HOSTS.split(',')));
          state.pollSince=Date.now(); // the upload is a new, usually short, wait
          this.save(state);
          if(this.photoMotionOnly&&photoMotionTask(state.task)){
            if(!state.photoMotionStartup)throw Error('photo_motion_startup_binding_refused');
            const deadline=Math.min(Date.now()+COLD_READY_MS,state.photoMotionStartedAt!+CPU_TIMEOUT_MS);
            await this.photoStartupWait(state,'egress',()=>this.bindEgress(state!.capabilities!),true,deadline);
            state.photoMotionStartup.stage='accepted';this.save(state);
          }else await this.bindEgressOnce(state.capabilities);
          await this.cpu('upload',{task_id:state.taskID,output:granted});
          await this.ctx.storage.setAlarm(Date.now()+this.pollDelay(state));return;
        }
        if (!(status.state==='inspected'&&state.task.action==='inspect_audio'||status.state==='extracted'&&state.task.action==='extract_frames'||status.state==='uploaded'&&(state.task.action==='compose'||state.task.action==='prepare_image'))) throw Error('cpu_protocol_refused');
        if (state.task.action==='inspect_audio'&&result.manifest_sha256!==state.task.manifest_sha256)throw Error('cpu_manifest_identity_conflict');
        if(state.task.action==='extract_frames'&&state.task.temporal_qc){
          state.temporalRawResult=result;this.save(state); // retain original measurement before any metadata adapter
          try{
            const adapted=await attestTemporalExtract(state.task,result,state.temporalProducer,state.taskID);
            this.retainTemporalAttestation(adapted.attestation);state.temporalAttestation=adapted.attestation;result=adapted.result;
          }catch(error){
            // Advisory motion check: an unreadable or unattestable measurement
            // is an unknown verdict. Send the frames without it and carry on.
            if(!(error instanceof TemporalEnvelopeRefusal))throw error;
            const{temporal:_unattested,...frames}=result;result=frames;this.dropTemporal(state);
          }
        }
        if(photoMotionTask(state.task)){
          // Retain the validated terminal receipt BEFORE any native stop await.
          state.pendingCallback={path:photoMotionCallbackPath(state.task),body:result};
          state.photoMotionTerminal={};this.save(state);
          await this.completePhotoMotion(state);return;
        }
        state.pendingCallback={path:status.state==='inspected'&&state.task.action==='inspect_audio'?'audio-preflight':status.state==='extracted'?'qc':state.task.action==='prepare_image'?'prepared-finish':'finish',body:result};
        this.save(state); // Save measured receipt before the fenced callback.
        if (this.ctx.container?.running) await this.ctx.container.destroy();
        await this.ctx.storage.setAlarm(Date.now()+1);return;
      }
      const action=await this.bridgeFor(state,'tick',{job_id:state.jobID,worker_id:state.slot}) as unknown as WorkerAction|PrepareImageAction;
      if (action.job_id!==state.jobID) throw Error('job_identity_conflict');
      if (isTerminal(action)) {const worked=state.worked===true;await this.stop();if(worked)await this.continueQueue(state);return;}
      if (action.action==='wait') {
        // SQL owns the admitted supplier receipt and its polling lease. An
        // acknowledged idle tick must not reserve a scarce CPU slot while a
        // supplier renders: the shared class parks (holds nothing, yields to
        // any other work, looks again in WAIT_RECHECK_MS); the Photo Motion
        // atom releases and cron rediscovers the same durable job. Keep
        // incomplete local CPU/callback evidence until it is reconciled.
        if (!state.task&&!state.taskID&&!state.pendingCallback) {if(this.photoMotionOnly)await this.stop();else await this.park(state);return;}
        if (this.ctx.container?.running) await this.ctx.container.destroy();
        await this.ctx.storage.setAlarm(Date.now()+POLL_MS);return;
      }
      if (action.action!=='extract_frames'&&action.action!=='compose'&&action.action!=='prepare_image'&&action.action!=='inspect_audio') throw Error('closed_action_required');
      const task=action as CPUAction;
      checkedAerialWorkKind(state.workKind,task);
      state.task=task;state.startedAt=Date.now();state.worked=true;delete state.waiting;
      // The tick has just issued this lease: its first renewal is due a minute
      // from now, not on the first status look. (Photo Motion renews in startup.)
      if(!this.photoMotionOnly)state.heartbeatAt=state.startedAt;
      state.capabilities=capabilities(task,new Set(this.env.MEDIA_HOSTS.split(',')));
      this.save(state);
      if(this.photoMotionOnly&&photoMotionTask(task)){await this.photoStartup(state,false);return;}
      await this.boot(state);
      const accepted=await this.cpu('execute',action);
      if (typeof accepted.task_id!=='string'||!/^[0-9a-f]{64}$/.test(accepted.task_id)) throw Error('cpu_receipt_invalid');
      state.taskID=accepted.task_id;state.pollSince=Date.now();this.save(state);
      await this.ctx.storage.setAlarm(Date.now()+this.pollDelay(state));
    } catch (error) {
      console.warn('property_video_cpu_refused',cpuDiagnostic(error));
      const startup=this.photoMotionOnly?(this.read() as SlotState|null)?.photoMotionStartup:undefined;
      const observation={...closedDiagnostic(error),...(startup?{startup_stage:startup.stage,startup_elapsed_ms:Math.max(0,Math.min(CPU_TIMEOUT_MS,Date.now()-startup.begunAt)),startup_uncertain:!!startup.uncertain}:{} )};
      this.ctx.storage.sql.exec('INSERT INTO diagnostic (id,observation) VALUES (1,?) ON CONFLICT(id) DO UPDATE SET observation=excluded.observation',JSON.stringify(observation));
      this.egressBound=undefined;
      if(error instanceof TemporalEnvelopeRefusal){
        // Last resort (every known site already handles its own refusal). The
        // motion check is advisory: never hold the slot. Drop the measurement
        // once and look again; a second refusal takes the ordinary fenced CPU
        // failure below. No verdict upgrade, provider retry or paid action.
        const unattested=this.read() as SlotState|null;
        if(unattested&&!unattested.temporalUnattested){this.dropTemporal(unattested);await this.ctx.storage.setAlarm(Date.now()+1);return;}
      }
      if(error instanceof AuthorityRefusal&&[403,404,409].includes(error.status)){
        if(this.photoMotionOnly&&state?.photoMotionStartup){
          await this.stopPhotoStartup(state);
          // Permission/not-found denial is final: no failure bridge, retry or
          // alternate authority action. A lease409 also never retries authority.
          if(error.status!==409||state.photoMotionStartup.uncertain){state.photoMotionStartup.held=true;this.save(state);await this.ctx.storage.deleteAlarm();}
          else await this.stop();
        }else await this.stop();
        return;
      }
      // Only CPU phases can be retried. Never invent a paid supplier retry here.
      state=this.read() as SlotState|null;
      if (state?.task&&!state.pendingCallback) {
        const photo=this.photoMotionOnly||'source_mode'in state.task;
        let stopped=false;
        if(photo&&state.photoMotionStartup)stopped=await this.stopPhotoStartup(state);
        else if(photo)try{if(this.ctx.container?.running)await this.ctx.container.destroy();stopped=true;}catch{ /* Unknown stop keeps the funding hold. */ }
        state.pendingCallback={path:'failure',body:{...sanitizedFailure(state.task),...(photo?{source_mode:PHOTO_MODE,composition_profile:('composition_profile'in state.task&&(state.task as {composition_profile?:unknown}).composition_profile==='photo-motion-v1-cfr24'?'photo-motion-v1-cfr24':('composition_profile'in state.task&&[AERIAL_INPUT_PROFILE,AERIAL_QUALIFY_PROFILE].includes((state.task as {composition_profile?:unknown}).composition_profile as any)?(state.task as {composition_profile:unknown}).composition_profile:('composition_profile'in state.task&&(state.task as {composition_profile?:unknown}).composition_profile==='photo-motion-v2-opening-cfr24'?'photo-motion-v2-opening-cfr24':PHOTO_PROFILE))),manifest_sha256:('manifest_sha256'in state.task?state.task.manifest_sha256:undefined),...photoMotionWall(state.photoMotionStartedAt,stopped&&!state.photoMotionStartup?.uncertain,Date.now()),producer_identity:state.photoMotionProducer??null}:{})}};
        this.save(state);
        if (!photo&&this.ctx.container?.running) await this.ctx.container.destroy();
        try {await this.bridgeFor(state,'failure',state.pendingCallback.body);if(state.photoMotionStartup?.uncertain){state.photoMotionStartup.held=true;this.save(state);await this.ctx.storage.deleteAlarm();return;}await this.stop();}
        catch (failure) {
          if (failure instanceof AuthorityRefusal&&[403,404,409].includes(failure.status)){if(state.photoMotionStartup&&(failure.status!==409||state.photoMotionStartup.uncertain)){state.photoMotionStartup.held=true;this.save(state);await this.ctx.storage.deleteAlarm();}else await this.stop();}
          else await this.ctx.storage.setAlarm(Date.now()+POLL_MS);
        }
      } else {
        await this.ctx.storage.setAlarm(Date.now()+POLL_MS);
      }
    }
  }
  private async bindEgressOnce(props:EgressProps):Promise<void> {
    // Polls are frequent, so re-issue the interceptor only when the capability
    // set changed or this instance restarted (the marker is not persisted).
    const key=JSON.stringify(props);
    if(this.egressBound===key)return;
    await this.bindEgress(props);this.egressBound=key;
  }
  private pollDelay(state:SlotState):number {return cpuPollDelay(state.pollSince??state.startedAt,Date.now(),POLL_MS,this.photoMotionOnly);}
  /** Start, but do not use, the process a generating edit's check will need. */
  private async prewarmPhotoContainer(state:PhotoSlotState):Promise<void> {
    const container=this.ctx.container;
    if(!container)throw Error('cpu_configuration_missing');
    // No await between reading the slot (caller) and start(): a wake that
    // replaces this slot either sees the process and destroys it, or runs first.
    if(!container.running){
      try{container.start({image:container.images.cpu,instance:'standard-3',enableInternet:false,env:{CONTAINER_TOKEN:state.token,MEDIA_HOSTS:this.env.MEDIA_HOSTS},labels:{workload:'property-video'}});}catch(error){throw cpuAPIFailure('start',error);}
      try{this.ctx.waitUntil(container.monitor().then(()=>{},()=>{}));}catch{ /* boot() observes a dead process itself. */ }
    }
    try{await container.setInactivityTimeout(PHOTO_PREWARM_HOLD_MS+30_000);}catch(error){throw cpuAPIFailure('inactivity',error);}
  }
  /** The measured receipt is already durable: release the CPU while the
   * authority confirms it, instead of waiting for the stop and another alarm. */
  private async finishPhoto(state:PhotoSlotState,call:(path:string,body?:unknown)=>Promise<Record<string,unknown>>):Promise<void> {
    const released=this.ctx.container?.running?this.ctx.container.destroy().catch(()=>{}):Promise.resolve();
    await call(state.pendingCallback!.path,state.pendingCallback!.body);
    await released;
    await this.stop();
  }
  private async advancePhoto(state:PhotoSlotState):Promise<void> {
    if(this.env.ENABLED!=='true'){await this.stop();return;}
    const call=(path:string,body?:unknown)=>bridge(this.env,path,body,'photo');
    if(photoPrewarmOnly(state)){
      try{
        if(Date.now()>=state.prewarmUntil!){await this.stop();return;}
        await this.prewarmPhotoContainer(state);
        // A real start or other work may have taken the slot meanwhile and has
        // already set its own alarm; only an untouched warm-up schedules release.
        const latest=this.read();
        if(photoPrewarmOnly(latest)&&latest.checkID===state.checkID&&latest.prewarmUntil===state.prewarmUntil)await this.ctx.storage.setAlarm(state.prewarmUntil!);
      }catch(error){
        console.warn('photo_quality_prewarm_refused',cpuDiagnostic(error));
        const latest=this.read();
        if(photoPrewarmOnly(latest)&&latest.checkID===state.checkID)await this.stop();
      }
      return;
    }
    try{
      if(this.ctx.container?.running)await this.ctx.container.setInactivityTimeout(60_000);
      if(state.pendingCallback){await this.finishPhoto(state,call);return;}
      if(state.taskID&&state.task){
        if(!this.ctx.container?.running||Date.now()-(state.startedAt??0)>CPU_TIMEOUT_MS)throw Error('cpu_interrupted');
        if(Date.now()-(state.heartbeatAt??0)>=60_000){
          const current=await call('heartbeat',{check_id:state.checkID,lease_token:state.task.lease_token});
          if(current.current!==true){await this.stop();return;}
          state.heartbeatAt=Date.now();this.save(state);
        }
        await this.bindEgressOnce(state.capabilities!);
        const status=await this.cpu('status',{task_id:state.taskID});
        if(status.state==='working'){await this.ctx.storage.setAlarm(Date.now()+photoPollDelay(state.startedAt,Date.now(),POLL_MS));return;}
        if(status.state==='failed'||status.state==='missing')throw new CPUFailure('status',status.state==='failed'?'cpu_task_failed':'cpu_task_missing');
        const result=checkedPhotoResult(status.result,state.task);
        if(status.state==='prepared'){
          const output=await call('derivatives',{check_id:state.checkID,lease_token:state.task.lease_token,manifest:result.manifest});
          state.capabilities=photoOutputCapabilities(output,result,new Set(this.env.MEDIA_HOSTS.split(',')));
          this.save(state);await this.bindEgressOnce(state.capabilities);
          await this.cpu('upload',{task_id:state.taskID,output});
          await this.ctx.storage.setAlarm(Date.now()+photoPollDelay(state.startedAt,Date.now(),POLL_MS));return;
        }
        if(status.state!=='uploaded'||!Array.isArray(result.receipts)||result.receipts.length!==10)throw Error('photo_quality_protocol_refused');
        state.pendingCallback={path:'derivatives-finish',body:{check_id:state.checkID,lease_token:state.task.lease_token,receipts:result.receipts}};
        this.save(state); // Save the measured receipt before the fenced callback.
        await this.finishPhoto(state,call);return;
      }
      const action=await call('tick',{check_id:state.checkID,worker_id:state.slot});
      if(action.check_id!==state.checkID||'job_id'in action)throw Error('photo_quality_identity_conflict');
      if(action.action==='done'){await this.stop();return;}
      if(action.action==='wait'){
        if(!state.task&&!state.taskID&&!state.pendingCallback){await this.stop();return;}
        if(this.ctx.container?.running)await this.ctx.container.destroy();
        await this.ctx.storage.setAlarm(Date.now()+POLL_MS);return;
      }
      if(action.action!=='prepare_photo_quality')throw Error('photo_quality_action_required');
      // The tick has just issued this lease; the first renewal is due a minute
      // from now, not on the first status poll.
      state.task=action as unknown as PhotoAction;state.startedAt=Date.now();state.heartbeatAt=state.startedAt;delete state.prewarmUntil;
      state.capabilities=photoCapabilities(state.task,new Set(this.env.MEDIA_HOSTS.split(',')));this.save(state);
      this.egressBound=undefined;
      await this.boot(state);
      const accepted=await this.cpu('execute',action);
      if(typeof accepted.task_id!=='string'||!/^[0-9a-f]{64}$/.test(accepted.task_id))throw Error('cpu_receipt_invalid');
      state.taskID=accepted.task_id;this.save(state);await this.ctx.storage.setAlarm(Date.now()+photoPollDelay(state.startedAt,Date.now(),POLL_MS));
    }catch(error){
      console.warn('photo_quality_cpu_refused',cpuDiagnostic(error));
      this.egressBound=undefined;
      this.ctx.storage.sql.exec('INSERT INTO diagnostic (id,observation) VALUES (1,?) ON CONFLICT(id) DO UPDATE SET observation=excluded.observation',JSON.stringify(closedDiagnostic(error)));
      if(error instanceof AuthorityRefusal&&[403,404,409].includes(error.status)){await this.stop();return;}
      if(state.task&&!state.pendingCallback){
        state.pendingCallback={path:'failure',body:photoFailure(state.task)};this.save(state);
        if(this.ctx.container?.running)await this.ctx.container.destroy();
        try{await call('failure',state.pendingCallback.body);await this.stop();}
        catch(failure){if(failure instanceof AuthorityRefusal&&[403,404,409].includes(failure.status))await this.stop();else await this.ctx.storage.setAlarm(Date.now()+POLL_MS);}
      }else if(state.pendingCallback){
        // Only this saved receipt is replayed: no decode, upload or new lease.
        if(this.ctx.container?.running)await this.ctx.container.destroy().catch(()=>{});
        const retries=state.callbackRetries??0;state.callbackRetries=retries+1;this.save(state);
        await this.ctx.storage.setAlarm(Date.now()+photoCallbackDelay(retries,POLL_MS));
      }else await this.ctx.storage.setAlarm(Date.now()+POLL_MS);
    }
  }

}

/** A separate namespace/container mapping; the AI class keeps image4452. */
export class PhotoMotionCPU extends PropertyVideoCPU {
  protected override photoMotionOnly=true;
  override async wake(jobID:string,slot:'slot-0'|'slot-1',workKind?:AerialWorkKind):Promise<boolean>{return slot==='slot-0'?super.wake(jobID,slot,workKind):false;}
  override async wakePhoto(_checkID:string,_slot:'slot-0'|'slot-1'):Promise<boolean>{return false;}
  override async prewarmPhoto(_checkID:string,_slot:'slot-0'|'slot-1'):Promise<boolean>{return false;}
}

type Holder=Awaited<ReturnType<PropertyVideoCPU['holder']>>;
const SHARED_SLOTS=['slot-0','slot-1'] as const;
/** One read of what the two shared CPU atoms hold; it only orders offers. */
const sharedHolders=(env:Env):Promise<Holder[]>=>Promise.all(SHARED_SLOTS.map(slot=>env.CPU.getByName(slot).holder()));
/** Offer one item that no shared atom holds. Each atom still decides for
 * itself; the read above only orders the offers: a slot that already holds the
 * item first (a photo start or warm-up repeated for the same check), then a
 * free slot, then one that only waits on a video supplier (it holds nothing;
 * the longest wait yields first), then, for video, an unused photo warm-up. A
 * slot this pass has already given or re-armed is not offered again. */
async function offer(env:Env,id:string,holders:Holder[],kind:'video'|'photo'|'warm'):Promise<boolean> {
  const call=async(index:number)=>{
    const slot=SHARED_SLOTS[index],cpu=env.CPU.getByName(slot);
    const admitted=kind==='video'?await cpu.wake(id,slot):kind==='photo'?await cpu.wakePhoto(id,slot):await cpu.prewarmPhoto(id,slot);
    if(admitted&&(holders[index]?.id!==id||holders[index]?.state==='waiting'))holders[index]={id,state:kind==='warm'?'warm':'fresh'};
    return admitted;
  };
  const own=holders.flatMap((holder,index)=>holder?.id===id?[index]:[]);
  let kept=false;for(const index of own)kept=await call(index)||kept;
  if(kept)return true;
  // A ready check may use an unused warm-up as it may a free slot (that
  // process never held a lease or customer bytes); a warm-up displaces none.
  const rank=(holder:Holder)=>holder===null?0:holder.state==='waiting'?1:holder.state==='warm'?(kind==='photo'?0:kind==='video'?2:3):3;
  const since=(holder:Holder)=>holder?.since??0;
  for(const index of [0,1].sort((a,b)=>rank(holders[a])-rank(holders[b])||since(holders[a])-since(holders[b])))if(rank(holders[index])<3&&await call(index))return true;
  return false;
}
/** Give this pass's queued video items their turn on the two shared atoms.
 * Items that no slot holds go first, so a new job, a resumed job or a photo
 * preparation starts now even while both slots only wait on suppliers; such a
 * slot holds nothing, and its job is found again on a later pass. Preparations
 * (short CPU work a user is waiting on) lead; the rest rotate so that more
 * waiting jobs than slots still each get their look. Then the jobs that do
 * hold a slot are re-armed there, never copied onto a second waiting slot. */
async function offerShared(env:Env,items:Array<{id:string;prepare:boolean}>):Promise<void> {
  if(!items.length)return;
  if(!env.CPU)throw Error('cpu_binding_missing');
  const holders=await sharedHolders(env),seen=[...holders];
  const holds=(id:string)=>seen.some(holder=>holder?.id===id);
  const waiting=items.filter(item=>!holds(item.id)),first=waiting.filter(item=>item.prepare),rest=waiting.filter(item=>!item.prepare);
  const turn=rest.length?Math.floor(Date.now()/WAIT_RECHECK_MS)%rest.length:0;
  for(const item of [...first,...rest.slice(turn),...rest.slice(0,turn)])await offer(env,item.id,holders,'video');
  for(const item of items)for(const index of [0,1]){
    if(seen[index]?.id!==item.id||holders[index]?.id!==item.id)continue; // not its slot, or given away above
    if(await env.CPU.getByName(SHARED_SLOTS[index]).wake(item.id,SHARED_SLOTS[index])&&holders[index]!.state==='waiting')holders[index]={id:item.id,state:'fresh'};
  }
  // Capacity left after every queued item had its turn: while a job's one
  // holder runs a CPU task, its next clip may be polled or reviewed on a slot
  // that is still free (never by displacing anything).
  for(const item of items){
    const own=seen.filter(holder=>holder?.id===item.id),spare=holders.findIndex(holder=>holder===null);
    if(spare<0)break;
    if(own.length!==1||own[0]!.state!=='busy')continue;
    // A refusal means something else took the slot meanwhile; stop offering it.
    holders[spare]={id:item.id,state:await env.CPU.getByName(SHARED_SLOTS[spare]).wake(item.id,SHARED_SLOTS[spare])?'fresh':'busy'};
  }
}

async function dispatch(env:Env):Promise<void> {
  if (env.ENABLED!=='true') return;
  // A missing configured photo namespace fails before any queue request.
  const photoSlot=env.PHOTO_MOTION_CPU?photoMotionSlotName(env.CPU_PHOTO_MOTION_SLOT_NAME):null;
  const queue=await bridge(env,'queue');
  if (queue.enabled!==true||!Array.isArray(queue.jobs)) return;
  // Terminal cancellation can remove the queue item before cleanup is deployed.
  // Inspect only the configured object's saved owner, including empty queues.
  const reconciledJob=env.PHOTO_MOTION_CPU?await env.PHOTO_MOTION_CPU.getByName(photoSlot!).reconcileHeldOnly():null;
  const jobs=queue.jobs.slice(0,32) as Array<{job_id:string;source_mode?:string|null;work_kind?:AerialWorkKind;prepare?:unknown}>;
  const shared:Array<{id:string;prepare:boolean}>=[];let refusal:unknown;
  try{
    for (const job of jobs) {
      if (!UUID.test(job.job_id)) continue;
      if(job.source_mode!=null&&job.source_mode!==PHOTO_MODE)throw Error('source_mode_refused');
      if(job.work_kind!==undefined&&(job.source_mode!==PHOTO_MODE||!aerialWorkKind(job.work_kind)))throw Error('aerial_work_kind_conflict');
      if(job.source_mode===PHOTO_MODE&&job.job_id===reconciledJob)continue; // Never rearm the just-reconciled terminal owner.
      if(job.source_mode===PHOTO_MODE){
        if(!env.PHOTO_MOTION_CPU)throw Error('photo_motion_binding_missing');
        await env.PHOTO_MOTION_CPU.getByName(photoSlot!).wake(job.job_id,'slot-0',job.work_kind); // One separately budgeted photo atom.
        continue;
      }
      if(!shared.some(item=>item.id===job.job_id))shared.push({id:job.job_id,prepare:job.prepare===true});
    }
  }catch(error){refusal=error;}
  // As before, a refused row stops the pass but the rows listed ahead of it still get their turn.
  await offerShared(env,shared);
  if(refusal)throw refusal;
}

async function dispatchPhoto(env:Env):Promise<void>{
  if(env.ENABLED!=='true')return;
  const queue=await bridge(env,'queue',undefined,'photo');
  if(queue.enabled!==true||!Array.isArray(queue.checks))return;
  let holders:Holder[]|undefined;
  for(const item of queue.checks.slice(0,32) as Array<{check_id:string}>){
    if(!UUID.test(item.check_id))continue;
    if(!holders)holders=await sharedHolders(env);
    await offer(env,item.check_id,holders,'photo');
  }
  // Judges use the existing service-only Edge route, not a CPU/container atom.
  // A lost reply never causes a local retry: the SQL funding/bind journal owns
  // dispatch, and the next queue excludes checks whose judge already started.
  const judges=Array.isArray(queue.judges)?[...new Set(queue.judges.flatMap(item=>{
    if(!item||typeof item!=='object'||!('check_id'in item)||typeof item.check_id!=='string'||!UUID.test(item.check_id))return[];
    return[item.check_id];
  }))].slice(0,2):[];
  await Promise.all(judges.map(async checkID=>{
    try{
      const result=await bridge(env,'judge',{check_id:checkID},'photo');
      if(result.check_id!==checkID)throw new BridgeFailure('bridge_response');
    }catch(error){console.warn('photo_quality_judge_refused',dispatchDiagnostic(error));}
  }));
}
export default {
  async fetch(request:Request,env:Env,ctx:ExecutionContext):Promise<Response> {
    const url=new URL(request.url);
    if (request.method==='GET'&&url.pathname==='/health') return json({service:'property-video-render',enabled:env.ENABLED==='true',provider_dispatch:false});
    const inspect=request.method==='GET'&&url.pathname==='/diagnostic';
    const photoStart=request.method==='POST'&&url.pathname==='/photo-quality/start';
    const photoPrewarm=request.method==='POST'&&url.pathname==='/photo-quality/prewarm';
    if (!inspect&&!photoStart&&!photoPrewarm&&(request.method!=='POST'||url.pathname!=='/wake')) return json({error:'not_found'},404);
    if (!env.RENDER_TRIGGER_KEY||request.headers.get('Authorization')!==`Bearer ${env.RENDER_TRIGGER_KEY}`) return json({error:'private_controller_only'},403);
    if(inspect)return json({slots:await Promise.all((['slot-0','slot-1'] as const).map(async slot=>{
      const cpu=env.CPU.getByName(slot);const[observation,attestations]=await Promise.all([cpu.diagnostic(),cpu.temporalAttestations()]);
      return{slot,observation,...(attestations.length?{temporal_attestations:attestations}:{})};
    }))});
    if (env.ENABLED!=='true') return json({error:'renderer_disabled'},503);
    if(photoPrewarm){
      // Optional head start for a check whose edit is still generating. A
      // refusal is normal (both slots busy) and changes nothing for the check.
      const body=await photoStartBody(request);if(!body)return json({error:'bounded_check_required'},400);
      const checkID=body.check_id;
      const accepted=await offer(env,checkID,await sharedHolders(env),'warm');
      return json({accepted,check_id:checkID},accepted?202:200);
    }
    if(photoStart){
      const body=await photoStartBody(request);if(!body)return json({error:'bounded_check_required'},400);
      const checkID=body.check_id;
      const accepted=await offer(env,checkID,await sharedHolders(env),'photo');
      return json(accepted?{accepted:true,check_id:checkID}:{accepted:false,check_id:checkID},accepted?202:503);
    }
    ctx.waitUntil(dispatch(env).catch(error=>console.warn('property_video_dispatch_refused',dispatchDiagnostic(error))));
    return json({accepted:true},202);
  },
  async scheduled(_event:ScheduledController,env:Env,ctx:ExecutionContext):Promise<void> {
    // Legacy AI/photo-quality queues share their original two CPU atoms.
    // Explicit photo motion has one separately budgeted namespace/container.
    // Alternate launch order, while neither queue waits for the other.
    const video=()=>dispatch(env).catch(error=>console.warn('property_video_dispatch_refused',dispatchDiagnostic(error)));
    const photo=()=>dispatchPhoto(env).catch(error=>console.warn('photo_quality_dispatch_refused',dispatchDiagnostic(error)));
    const photoFirst=Number.isFinite(_event.scheduledTime)&&Math.floor(_event.scheduledTime/60_000)%2===1;
    ctx.waitUntil(Promise.all((photoFirst?[photo,video]:[video,photo]).map(run=>run())).then(()=>{}));
  }
} satisfies ExportedHandler<Env>;
