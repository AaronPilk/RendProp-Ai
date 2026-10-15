import {DurableObject,WorkerEntrypoint} from 'cloudflare:workers';
import type {WorkerAction} from '../../../supabase/functions/property-video-jobs/contracts.ts';
import {UUID,capabilities,outputCapabilities,egress,isTerminal,sanitizedFailure} from './controller';
import type {SlotState,EgressProps,CPUAction,PrepareImageAction} from './controller';

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
const json=(value:unknown,status=200)=>Response.json(value,{status,headers:{'Cache-Control':'no-store'}});

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

async function bridge(env:Env,path:string,body?:unknown):Promise<Record<string,unknown>> {
  let base:URL;try {base=new URL(env.EDGE_WORKER_URL);}catch {throw new BridgeFailure('bridge_configuration');}
  if (base.protocol!=='https:'||!base.hostname.endsWith('.supabase.co')||!env.EDGE_SERVICE_ROLE_KEY) throw new BridgeFailure('bridge_configuration');
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
    if (ctx.container?.running) ctx.waitUntil(ctx.container.setInactivityTimeout(60_000));
  }
  private read():SlotState|null {const row=this.ctx.storage.sql.exec<{state:string}>('SELECT state FROM slot WHERE id=1').toArray()[0];return row?JSON.parse(row.state):null;}
  private save(state:SlotState):void {this.ctx.storage.sql.exec('INSERT INTO slot (id,state) VALUES (1,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state',JSON.stringify(state));}
  async wake(jobID:string,slot:'slot-0'|'slot-1'):Promise<boolean> {
    if (this.env.ENABLED!=='true'||!UUID.test(jobID)||!['slot-0','slot-1'].includes(slot)) return false;
    const prior=this.read();
    if (prior&&prior.jobID!==jobID) return false;
    if (!prior) this.save({jobID,slot,token:crypto.randomUUID()+crypto.randomUUID()});
    await this.ctx.storage.setAlarm(Date.now()+1);
    return true;
  }
  private async stop():Promise<void> {
    if (this.ctx.container?.running) await this.ctx.container.destroy();
    this.ctx.storage.sql.exec('DELETE FROM slot WHERE id=1');
    await this.ctx.storage.deleteAlarm();
  }
  private async cpu(path:string,body?:unknown):Promise<Record<string,unknown>> {
    const state=this.read();
    if (!state||!this.ctx.container?.running) throw Error('cpu_not_running');
    const response=await this.ctx.container.getTcpPort(8080).fetch(`http://container/${path}`,{method:body===undefined?'GET':'POST',
      headers:{Authorization:`Bearer ${state.token}`,'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(10_000)});
    if (!response.ok) throw Error('cpu_refused');
    return await response.json() as Record<string,unknown>;
  }
  private async bindEgress(props:EgressProps):Promise<void> {
    if (!this.ctx.container) throw Error('container_binding_missing');
    const exports=this.ctx.exports as unknown as {MediaEgress(options:{props:EgressProps}):Fetcher};
    const binding=exports.MediaEgress({props});
    await this.ctx.container.interceptOutboundHttps('*',binding);
    // HTTP remains un-intercepted, therefore blocked by enableInternet:false.
  }
  private async boot(state:SlotState):Promise<void> {
    const container=this.ctx.container;
    if (!container||!state.capabilities) throw Error('cpu_configuration_missing');
    if (!container.running) {
      container.start({image:container.images.cpu,instance:'standard-3',enableInternet:false,
        env:{CONTAINER_TOKEN:state.token,MEDIA_HOSTS:this.env.MEDIA_HOSTS},labels:{workload:'property-video'}});
      await container.setInactivityTimeout(60_000);
    }
    await this.bindEgress(state.capabilities);
    const deadline=Date.now()+30_000;
    while (Date.now()<deadline) {
      try {await this.cpu('ready');return;} catch {await new Promise(resolve=>setTimeout(resolve,300));}
    }
    throw Error('cpu_start_failed');
  }
  async alarm():Promise<void> {
    if (this.advancing) {await this.ctx.storage.setAlarm(Date.now()+POLL_MS);return;}
    this.advancing=true;
    try {await this.advance();} finally {this.advancing=false;}
  }
  private async advance():Promise<void> {
    let state=this.read();
    if (!state) return;
    if (this.env.ENABLED!=='true') {await this.stop();return;}
    try {
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
        if (status.state==='failed'||status.state==='missing') throw Error('cpu_attempt_failed');
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
      if (error instanceof AuthorityRefusal&&[403,404,409].includes(error.status)) {await this.stop();return;}
      // Only CPU phases can be retried. Never invent a paid supplier retry here.
      state=this.read();
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

export default {
  async fetch(request:Request,env:Env,ctx:ExecutionContext):Promise<Response> {
    const url=new URL(request.url);
    if (request.method==='GET'&&url.pathname==='/health') return json({service:'property-video-render',enabled:env.ENABLED==='true',provider_dispatch:false});
    if (request.method!=='POST'||url.pathname!=='/wake') return json({error:'not_found'},404);
    if (!env.RENDER_TRIGGER_KEY||request.headers.get('Authorization')!==`Bearer ${env.RENDER_TRIGGER_KEY}`) return json({error:'private_controller_only'},403);
    if (env.ENABLED!=='true') return json({error:'renderer_disabled'},503);
    ctx.waitUntil(dispatch(env).catch(error=>console.warn('property_video_dispatch_refused',dispatchDiagnostic(error))));
    return json({accepted:true},202);
  },
  async scheduled(_event:ScheduledController,env:Env,ctx:ExecutionContext):Promise<void> {
    ctx.waitUntil(dispatch(env).catch(error=>console.warn('property_video_dispatch_refused',dispatchDiagnostic(error))));
  }
} satisfies ExportedHandler<Env>;
