import {DurableObject,WorkerEntrypoint} from 'cloudflare:workers';
import type {WorkerAction} from '../../../supabase/functions/property-video-jobs/contracts.ts';
import {UUID,capabilities,outputCapabilities,egress,isTerminal,sanitizedFailure} from './controller';
import type {SlotState,EgressProps,CPUAction,PrepareImageAction} from './controller';
import {photoCapabilities,photoOutputCapabilities,checkedPhotoResult,photoFailure} from './photo-quality';
import type {PhotoSlotState,PhotoAction} from './photo-quality';
type WorkState=SlotState|PhotoSlotState;

interface Env {
  CPU:DurableObjectNamespace<PropertyVideoCPU>;
  ENABLED:string;
  EDGE_WORKER_URL:string;
  EDGE_SERVICE_ROLE_KEY:string;
  RENDER_TRIGGER_KEY:string;
  MEDIA_HOSTS:string;
}

const POLL_MS=15_000;
const CPU_TIMEOUT_MS=20*60_000;
const COLD_READY_MS=120_000;
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
  return error instanceof CPUFailure?{phase:error.phase,category:error.category,...(error.status===undefined?{}:{status:error.status}),...(error.transport?{error_name:error.transport.name,reason:error.transport.reason}:{}),...(error.startup?{reason:error.startup.reason,...(error.startup.exitCode===undefined?{}:{exit_code:error.startup.exitCode})}:{})}:dispatchDiagnostic(error);
}
function cpuAPIFailure(phase:CPUPhase,error:unknown):CPUFailure {return new CPUFailure(phase,'cpu_api',undefined,transportFailure(error).transport);}
const DIAGNOSTIC_PHASES=new Set(['start','inactivity','egress','ready','ready_timeout','execute','status','upload','bridge','controller']);
const DIAGNOSTIC_REASONS=new Set(['redirect','invalid_header','dns','timeout','unsupported_api','other','http_refusal','configuration','response','not_running','task_failed','task_missing','process_exit','startup_image','startup_capacity','startup_configuration','startup_unknown']);
type ClosedDiagnostic={phase:string;error_name:TransportName;reason:string;http_status?:number;exit_code?:number;timestamp:number};
function checkedDiagnostic(value:unknown):ClosedDiagnostic|null {
  if(!value||typeof value!=='object'||Array.isArray(value))return null;
  const v=value as Record<string,unknown>;
  if(Object.keys(v).some(k=>!['phase','error_name','reason','http_status','exit_code','timestamp'].includes(k))||!DIAGNOSTIC_PHASES.has(String(v.phase))||!['TypeError','TimeoutError','AbortError','Other'].includes(String(v.error_name))||!DIAGNOSTIC_REASONS.has(String(v.reason))||!Number.isSafeInteger(v.timestamp)||Number(v.timestamp)<0||!(v.http_status===undefined||Number.isInteger(v.http_status)&&Number(v.http_status)>=100&&Number(v.http_status)<=599)||!(v.exit_code===undefined||Number.isInteger(v.exit_code)&&Number(v.exit_code)>=0&&Number(v.exit_code)<=255))return null;
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
    method:body===undefined?'GET':'POST',headers:{Authorization:`Bearer ${env.EDGE_SERVICE_ROLE_KEY}`,apikey:env.EDGE_SERVICE_ROLE_KEY,'Content-Type':'application/json'},
    // workerd rejects redirect:'error' before issuing this subrequest. Manual
    // mode never follows/forwards credentials; non-2xx stays a closed refusal.
    body:body===undefined?undefined:JSON.stringify(body),redirect:'manual',signal:AbortSignal.timeout(50_000)});}catch(error) {throw transportFailure(error);}
  if (!response.ok) throw new AuthorityRefusal(response.status);
  try {return await response.json() as Record<string,unknown>;}catch {throw new BridgeFailure('bridge_response');}
}

export class MediaEgress extends WorkerEntrypoint<Env,EgressProps> {
  fetch(request:Request):Promise<Response> {return egress(request,this.ctx.props);}
}

/** Exactly two configured CPU atoms. Database remains job/cost/privacy authority. */
export class PropertyVideoCPU extends DurableObject<Env> {
  private advancing=false;
  constructor(ctx:DurableObjectState,env:Env) {
    super(ctx,env);
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS slot (id INTEGER PRIMARY KEY CHECK(id=1), state TEXT NOT NULL)');
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS diagnostic (id INTEGER PRIMARY KEY CHECK(id=1), observation TEXT NOT NULL)');
  }
  /** Fixed-slot private inspection does not wake work, change leases or touch a CPU. */
  async diagnostic():Promise<ClosedDiagnostic|null> {
    const row=this.ctx.storage.sql.exec<{observation:string}>('SELECT observation FROM diagnostic WHERE id=1').toArray()[0];
    if(!row)return null;try{return checkedDiagnostic(JSON.parse(row.observation));}catch{return null;}
  }
  private read():WorkState|null {const row=this.ctx.storage.sql.exec<{state:string}>('SELECT state FROM slot WHERE id=1').toArray()[0];return row?JSON.parse(row.state):null;}
  private save(state:WorkState):void {this.ctx.storage.sql.exec('INSERT INTO slot (id,state) VALUES (1,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state',JSON.stringify(state));}
  async wake(jobID:string,slot:'slot-0'|'slot-1'):Promise<boolean> {
    if (this.env.ENABLED!=='true'||!UUID.test(jobID)||!['slot-0','slot-1'].includes(slot)) return false;
    const prior=this.read();
    if (prior&&('kind'in prior&&prior.kind==='photo_quality'||!('jobID'in prior)||prior.jobID!==jobID)) return false;
    if (!prior) this.save({jobID,slot,token:crypto.randomUUID()+crypto.randomUUID()});
    await this.ctx.storage.setAlarm(Date.now()+1);
    return true;
  }
  async wakePhoto(checkID:string,slot:'slot-0'|'slot-1'):Promise<boolean> {
    if(this.env.ENABLED!=='true'||!UUID.test(checkID)||!['slot-0','slot-1'].includes(slot))return false;
    const prior=this.read();
    if(prior&&(!('kind'in prior)||prior.kind!=='photo_quality'||prior.checkID!==checkID))return false;
    if(!prior)this.save({kind:'photo_quality',checkID,slot,token:crypto.randomUUID()+crypto.randomUUID()});
    await this.ctx.storage.setAlarm(Date.now()+1);return true;
  }
  private async stop():Promise<void> {
    if (this.ctx.container?.running) await this.ctx.container.destroy();
    this.ctx.storage.sql.exec('DELETE FROM slot WHERE id=1');
    await this.ctx.storage.deleteAlarm();
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
  private async boot(state:WorkState):Promise<void> {
    const container=this.ctx.container;
    if (!container||!state.capabilities) throw Error('cpu_configuration_missing');
    let startup:CPUFailure|undefined;
    if (!container.running) {
      try {container.start({image:container.images.cpu,instance:'standard-3',enableInternet:false,
        env:{CONTAINER_TOKEN:state.token,MEDIA_HOSTS:this.env.MEDIA_HOSTS},labels:{workload:'property-video'}});}catch(error){throw cpuAPIFailure('start',error);}
      // start() only validates options. Its later image/process failures are
      // observable through monitor(), not through the synchronous return.
      try {this.ctx.waitUntil(container.monitor().then(
        ()=>{startup=new CPUFailure('start','cpu_start_failed',undefined,undefined,{reason:'process_exit',exitCode:0});},
        error=>{startup=startupFailure(error);},
      ));}catch(error){throw startupFailure(error);}
      try {await container.setInactivityTimeout(60_000);}catch(error){throw cpuAPIFailure('inactivity',error);}
    }
    await this.bindEgress(state.capabilities);
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
    try {
      // Refresh an already-running process only when executing its work alarm,
      // never as a side effect of a read-only diagnostic RPC/constructor.
      if(this.ctx.container?.running)try{await this.ctx.container.setInactivityTimeout(60_000);}catch(error){throw cpuAPIFailure('inactivity',error);}
      if (state.pendingCallback) {
        // The receipt is durable and uploads/extraction are done. An authority
        // outage must not leave an idle CPU billed while callback retries sleep.
        if (this.ctx.container?.running) await this.ctx.container.destroy();
        await bridge(this.env,state.pendingCallback.path,state.pendingCallback.body);
        state.pendingCallback=undefined;
        state.task=undefined;state.taskID=undefined;state.outputs=undefined;state.capabilities=undefined;state.startedAt=undefined;state.heartbeatAt=undefined;
        this.save(state);
      }
      if (state.taskID&&state.task) {
        if (!this.ctx.container?.running||Date.now()-(state.startedAt??0)>CPU_TIMEOUT_MS) throw Error('cpu_interrupted');
        if (Date.now()-(state.heartbeatAt??0)>=60_000) {
          const current=await bridge(this.env,'heartbeat',{job_id:state.jobID,lease_token:state.task.lease_token,
            ...(state.task.action==='extract_frames'?{attempt_id:state.task.attempt_id}:{})});
          if (current.current!==true) {await this.stop();return;}
          state.heartbeatAt=Date.now();this.save(state);
        }
        await this.bindEgress(state.capabilities!);
        const status=await this.cpu('status',{task_id:state.taskID});
        if (status.state==='working') {await this.ctx.storage.setAlarm(Date.now()+POLL_MS);return;}
        if (status.state==='failed'||status.state==='missing') throw new CPUFailure('status',status.state==='failed'?'cpu_task_failed':'cpu_task_missing');
        const result=status.result as Record<string,unknown>;
        if (!result||result.job_id!==state.jobID||result.lease_token!==state.task.lease_token) throw Error('cpu_receipt_identity_conflict');
        if (status.state==='prepared') {
          if(state.task.action!=='compose'&&state.task.action!=='prepare_image')throw Error('cpu_protocol_refused');
          const raw=await bridge(this.env,state.task.action==='prepare_image'?'prepared-outputs':'outputs',result);
          const output=(raw.output??raw) as Record<string,unknown>;
          const expiresAt=raw.expires_at??output.expires_at;
          const granted={...output,expires_at:expiresAt};
          state.outputs=granted;
          state.capabilities=outputCapabilities(granted,result,new Set(this.env.MEDIA_HOSTS.split(',')));
          this.save(state);
          await this.bindEgress(state.capabilities);
          await this.cpu('upload',{task_id:state.taskID,output:granted});
          await this.ctx.storage.setAlarm(Date.now()+POLL_MS);return;
        }
        if (!(status.state==='inspected'&&state.task.action==='inspect_audio'||status.state==='extracted'&&state.task.action==='extract_frames'||status.state==='uploaded'&&(state.task.action==='compose'||state.task.action==='prepare_image'))) throw Error('cpu_protocol_refused');
        if (state.task.action==='inspect_audio'&&result.manifest_sha256!==state.task.manifest_sha256)throw Error('cpu_manifest_identity_conflict');
        state.pendingCallback={path:status.state==='inspected'&&state.task.action==='inspect_audio'?'audio-preflight':status.state==='extracted'?'qc':state.task.action==='prepare_image'?'prepared-finish':'finish',body:result};
        this.save(state); // Save measured receipt before the fenced callback.
        if (this.ctx.container?.running) await this.ctx.container.destroy();
        await this.ctx.storage.setAlarm(Date.now()+1);return;
      }
      const action=await bridge(this.env,'tick',{job_id:state.jobID,worker_id:state.slot}) as unknown as WorkerAction|PrepareImageAction;
      if (action.job_id!==state.jobID) throw Error('job_identity_conflict');
      if (isTerminal(action)) {await this.stop();return;}
      if (action.action==='wait') {
        // SQL owns the admitted supplier receipt and its polling lease. An
        // acknowledged idle tick must not reserve a scarce CPU slot while a
        // supplier renders. Cron will rediscover the same durable job. Keep
        // incomplete local CPU/callback evidence until it is reconciled.
        if (!state.task&&!state.taskID&&!state.pendingCallback) {await this.stop();return;}
        if (this.ctx.container?.running) await this.ctx.container.destroy();
        await this.ctx.storage.setAlarm(Date.now()+POLL_MS);return;
      }
      if (action.action!=='extract_frames'&&action.action!=='compose'&&action.action!=='prepare_image'&&action.action!=='inspect_audio') throw Error('closed_action_required');
      const task=action as CPUAction;
      state.task=task;state.startedAt=Date.now();
      state.capabilities=capabilities(task,new Set(this.env.MEDIA_HOSTS.split(',')));
      this.save(state);
      await this.boot(state);
      const accepted=await this.cpu('execute',action);
      if (typeof accepted.task_id!=='string'||!/^[0-9a-f]{64}$/.test(accepted.task_id)) throw Error('cpu_receipt_invalid');
      state.taskID=accepted.task_id;this.save(state);
      await this.ctx.storage.setAlarm(Date.now()+POLL_MS);
    } catch (error) {
      console.warn('property_video_cpu_refused',cpuDiagnostic(error));
      this.ctx.storage.sql.exec('INSERT INTO diagnostic (id,observation) VALUES (1,?) ON CONFLICT(id) DO UPDATE SET observation=excluded.observation',JSON.stringify(closedDiagnostic(error)));
      if (error instanceof AuthorityRefusal&&[403,404,409].includes(error.status)) {await this.stop();return;}
      // Only CPU phases can be retried. Never invent a paid supplier retry here.
      state=this.read() as SlotState|null;
      if (state?.task&&!state.pendingCallback) {
        state.pendingCallback={path:'failure',body:sanitizedFailure(state.task)};
        this.save(state);
        if (this.ctx.container?.running) await this.ctx.container.destroy();
        try {await bridge(this.env,'failure',state.pendingCallback.body);await this.stop();}
        catch (failure) {
          if (failure instanceof AuthorityRefusal&&[403,404,409].includes(failure.status)) await this.stop();
          else await this.ctx.storage.setAlarm(Date.now()+POLL_MS);
        }
      } else {
        await this.ctx.storage.setAlarm(Date.now()+POLL_MS);
      }
    }
  }
  private async advancePhoto(state:PhotoSlotState):Promise<void> {
    if(this.env.ENABLED!=='true'){await this.stop();return;}
    const call=(path:string,body?:unknown)=>bridge(this.env,path,body,'photo');
    try{
      if(this.ctx.container?.running)await this.ctx.container.setInactivityTimeout(60_000);
      if(state.pendingCallback){
        if(this.ctx.container?.running)await this.ctx.container.destroy();
        await call(state.pendingCallback.path,state.pendingCallback.body);
        await this.stop();return;
      }
      if(state.taskID&&state.task){
        if(!this.ctx.container?.running||Date.now()-(state.startedAt??0)>CPU_TIMEOUT_MS)throw Error('cpu_interrupted');
        if(Date.now()-(state.heartbeatAt??0)>=60_000){
          const current=await call('heartbeat',{check_id:state.checkID,lease_token:state.task.lease_token});
          if(current.current!==true){await this.stop();return;}
          state.heartbeatAt=Date.now();this.save(state);
        }
        await this.bindEgress(state.capabilities!);
        const status=await this.cpu('status',{task_id:state.taskID});
        if(status.state==='working'){await this.ctx.storage.setAlarm(Date.now()+POLL_MS);return;}
        if(status.state==='failed'||status.state==='missing')throw new CPUFailure('status',status.state==='failed'?'cpu_task_failed':'cpu_task_missing');
        const result=checkedPhotoResult(status.result,state.task);
        if(status.state==='prepared'){
          const output=await call('derivatives',{check_id:state.checkID,lease_token:state.task.lease_token,manifest:result.manifest});
          state.capabilities=photoOutputCapabilities(output,result,new Set(this.env.MEDIA_HOSTS.split(',')));
          this.save(state);await this.bindEgress(state.capabilities);
          await this.cpu('upload',{task_id:state.taskID,output});
          await this.ctx.storage.setAlarm(Date.now()+POLL_MS);return;
        }
        if(status.state!=='uploaded'||!Array.isArray(result.receipts)||result.receipts.length!==10)throw Error('photo_quality_protocol_refused');
        state.pendingCallback={path:'derivatives-finish',body:{check_id:state.checkID,lease_token:state.task.lease_token,receipts:result.receipts}};
        this.save(state);
        if(this.ctx.container?.running)await this.ctx.container.destroy();
        await this.ctx.storage.setAlarm(Date.now()+1);return;
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
      state.task=action as unknown as PhotoAction;state.startedAt=Date.now();
      state.capabilities=photoCapabilities(state.task,new Set(this.env.MEDIA_HOSTS.split(',')));this.save(state);
      await this.boot(state);
      const accepted=await this.cpu('execute',action);
      if(typeof accepted.task_id!=='string'||!/^[0-9a-f]{64}$/.test(accepted.task_id))throw Error('cpu_receipt_invalid');
      state.taskID=accepted.task_id;this.save(state);await this.ctx.storage.setAlarm(Date.now()+POLL_MS);
    }catch(error){
      console.warn('photo_quality_cpu_refused',cpuDiagnostic(error));
      this.ctx.storage.sql.exec('INSERT INTO diagnostic (id,observation) VALUES (1,?) ON CONFLICT(id) DO UPDATE SET observation=excluded.observation',JSON.stringify(closedDiagnostic(error)));
      if(error instanceof AuthorityRefusal&&[403,404,409].includes(error.status)){await this.stop();return;}
      if(state.task&&!state.pendingCallback){
        state.pendingCallback={path:'failure',body:photoFailure(state.task)};this.save(state);
        if(this.ctx.container?.running)await this.ctx.container.destroy();
        try{await call('failure',state.pendingCallback.body);await this.stop();}
        catch(failure){if(failure instanceof AuthorityRefusal&&[403,404,409].includes(failure.status))await this.stop();else await this.ctx.storage.setAlarm(Date.now()+POLL_MS);}
      }else await this.ctx.storage.setAlarm(Date.now()+POLL_MS);
    }
  }

}

async function dispatch(env:Env):Promise<void> {
  if (env.ENABLED!=='true') return;
  const queue=await bridge(env,'queue');
  if (queue.enabled!==true||!Array.isArray(queue.jobs)) return;
  const jobs=queue.jobs.slice(0,32) as Array<{job_id:string}>;
  for (const job of jobs) {
    if (!UUID.test(job.job_id)) continue;
    if (await env.CPU.getByName('slot-0').wake(job.job_id,'slot-0')) continue;
    await env.CPU.getByName('slot-1').wake(job.job_id,'slot-1');
  }
}

async function dispatchPhoto(env:Env):Promise<void>{
  if(env.ENABLED!=='true')return;
  const queue=await bridge(env,'queue',undefined,'photo');
  if(queue.enabled!==true||!Array.isArray(queue.checks))return;
  for(const item of queue.checks.slice(0,32) as Array<{check_id:string}>){
    if(!UUID.test(item.check_id))continue;
    if(await env.CPU.getByName('slot-0').wakePhoto(item.check_id,'slot-0'))continue;
    await env.CPU.getByName('slot-1').wakePhoto(item.check_id,'slot-1');
  }
}
export default {
  async fetch(request:Request,env:Env,ctx:ExecutionContext):Promise<Response> {
    const url=new URL(request.url);
    if (request.method==='GET'&&url.pathname==='/health') return json({service:'property-video-render',enabled:env.ENABLED==='true',provider_dispatch:false});
    const inspect=request.method==='GET'&&url.pathname==='/diagnostic';
    const photoStart=request.method==='POST'&&url.pathname==='/photo-quality/start';
    if (!inspect&&!photoStart&&(request.method!=='POST'||url.pathname!=='/wake')) return json({error:'not_found'},404);
    if (!env.RENDER_TRIGGER_KEY||request.headers.get('Authorization')!==`Bearer ${env.RENDER_TRIGGER_KEY}`) return json({error:'private_controller_only'},403);
    if(inspect)return json({slots:await Promise.all((['slot-0','slot-1'] as const).map(async slot=>({slot,observation:await env.CPU.getByName(slot).diagnostic()})))});
    if (env.ENABLED!=='true') return json({error:'renderer_disabled'},503);
    if(photoStart){
      const body=await photoStartBody(request);if(!body)return json({error:'bounded_check_required'},400);
      const checkID=body.check_id;
      const accepted=await env.CPU.getByName('slot-0').wakePhoto(checkID,'slot-0')||await env.CPU.getByName('slot-1').wakePhoto(checkID,'slot-1');
      return json(accepted?{accepted:true,check_id:checkID}:{accepted:false,check_id:checkID},accepted?202:503);
    }
    ctx.waitUntil(dispatch(env).catch(error=>console.warn('property_video_dispatch_refused',dispatchDiagnostic(error))));
    return json({accepted:true},202);
  },
  async scheduled(_event:ScheduledController,env:Env,ctx:ExecutionContext):Promise<void> {
    // Both queues share exactly two CPU atoms. Alternate admission priority by
    // cron minute instead of racing the queues for whichever RPC wins first.
    const video=()=>dispatch(env).catch(error=>console.warn('property_video_dispatch_refused',dispatchDiagnostic(error)));
    const photo=()=>dispatchPhoto(env).catch(error=>console.warn('photo_quality_dispatch_refused',dispatchDiagnostic(error)));
    const photoFirst=Number.isFinite(_event.scheduledTime)&&Math.floor(_event.scheduledTime/60_000)%2===1;
    ctx.waitUntil((async()=>{for(const run of photoFirst?[photo,video]:[video,photo])await run();})());
  }
} satisfies ExportedHandler<Env>;
