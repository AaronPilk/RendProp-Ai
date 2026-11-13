import {startPhotoComparison} from "../photo-quality-worker/client.ts";
import type {continuePhotoQuality} from "./photo-qc-runner.ts";
import {invokeSavedPhotoJudge} from "../photo-quality-worker/judge-client.ts";
import {photoQualityRpc,photoEnvelope,photoQualityScope,type PhotoAdmin,type PhotoQualityEnvelope} from "./photo-qc-store.ts";

export const PHOTO_CHECK_ENDPOINT_BUDGET_MS=120_000;
export const PHOTO_CHECK_JUDGE_RESERVE_MS=45_000;
// Supabase's150s wall limit includes generation, evidence writes and QC. Keep
// ten seconds outside this request's work budget for the saved-state response.
export const PHOTO_MAIN_REQUEST_BUDGET_MS=140_000;
export const PHOTO_MAIN_RESPONSE_RESERVE_MS=10_000;
export const PHOTO_MAIN_PERSIST_RESERVE_MS=20_000;
// A comparison now takes seconds, so look often at first and relax afterwards.
export const PHOTO_STATUS_FAST_MS=750;
export const PHOTO_STATUS_FAST_WINDOW_MS=30_000;
export const PHOTO_STATUS_SLOW_MS=1_500;
// The wake is idempotent in the controller (same check UUID only re-arms its
// alarm; any other owner refuses), so an unacknowledged wake is repeated a
// bounded number of times instead of leaving the check to the minute cron.
export const PHOTO_START_ATTEMPTS=3;
export const PHOTO_START_RETRY_MS=2_000;
export interface PhotoWaitDependencies {
 now():number;
 sleep(milliseconds:number,signal:AbortSignal):Promise<void>;
 start(checkId:string,signal:AbortSignal):Promise<{started:boolean}>;
 status(admin:PhotoAdmin,row:PhotoQualityEnvelope,signal:AbortSignal):Promise<PhotoQualityEnvelope>;
 judge:typeof continuePhotoQuality;
}
const actual:PhotoWaitDependencies={now:Date.now,start:startPhotoComparison,judge:async(admin,row,args)=>{
 await photoQualityScope(admin,row,args.actor,args.selected);args.request.signal.throwIfAborted();
 const deadline=Math.min(args.deadline??Date.now()+PHOTO_CHECK_ENDPOINT_BUDGET_MS,Date.now()+PHOTO_CHECK_ENDPOINT_BUDGET_MS);
 const signal=AbortSignal.any([args.request.signal,AbortSignal.timeout(Math.max(1,deadline-Date.now()))]);
 await invokeSavedPhotoJudge(row.check.id,signal,deadline-Date.now());
 const fresh=photoEnvelope(await photoQualityRpc(admin,"photo_quality_status",{p_actor:args.actor,p_check:row.check.id}),args.actor);
 await photoQualityScope(admin,fresh,args.actor,args.selected);return fresh;
},
 sleep:(milliseconds,signal)=>new Promise<void>((resolve,reject)=>{
  const done=()=>{signal.removeEventListener("abort",abort);resolve();},timer=setTimeout(done,milliseconds);
  const abort=()=>{clearTimeout(timer);signal.removeEventListener("abort",abort);reject(signal.reason);};
  if(signal.aborted)abort();else signal.addEventListener("abort",abort,{once:true});
 }),
 status:async(admin,row,signal)=>photoEnvelope(await photoQualityRpc(admin,"photo_quality_status",{p_actor:row.evidence.actor_id,p_check:row.check.id},signal),row.evidence.actor_id),
};
/** Wake the CPU controller, then only fresh scoped status reads. The wake is
 * repeated only while it is unacknowledged AND the check is still pending
 * (both slots busy, or the reply was lost); it never claims, restarts a running
 * comparison or judges. Leave45s for bounded derivative reads+one judge. */
export async function waitForPhotoQuality(admin:PhotoAdmin,initial:PhotoQualityEnvelope,args:{actor:string;selected:string|null;request:Request;instruction?:string;deadline?:number},deps=actual):Promise<PhotoQualityEnvelope>{
 const now=deps.now(),deadline=Math.min(args.deadline??now+PHOTO_CHECK_ENDPOINT_BUDGET_MS,now+PHOTO_CHECK_ENDPOINT_BUDGET_MS);
 let row=initial;
 if(!Number.isSafeInteger(deadline)||deadline<=now)return row;
 const signal=AbortSignal.any([args.request.signal,AbortSignal.timeout(deadline-now)]);
 try{
  await photoQualityScope(admin,row,args.actor,args.selected);signal.throwIfAborted();
  let acknowledged=true,attempts=0,lastStart=0;
  const wake=async()=>{attempts++;lastStart=deps.now();acknowledged=(await deps.start(row.check.id,signal)).started;};
  if(row.check.state==="pending"&&row.can_continue&&row.check.judge_started_at===null)await wake();
  const began=deps.now();
  while(["pending","preparing"].includes(row.check.state)&&row.check.judge_started_at===null&&deps.now()<deadline-PHOTO_CHECK_JUDGE_RESERVE_MS){
   // Still unacknowledged after every bounded wake: return the saved pending
   // state, exactly as a single lost wake did before. The minute cron and a
   // later explicit check reconcile it; no generation is repeated.
   if(!acknowledged&&row.check.state==="pending"&&attempts>=PHOTO_START_ATTEMPTS)return row;
   const pace=deps.now()-began<PHOTO_STATUS_FAST_WINDOW_MS?PHOTO_STATUS_FAST_MS:PHOTO_STATUS_SLOW_MS;
   await deps.sleep(Math.min(pace,deadline-PHOTO_CHECK_JUDGE_RESERVE_MS-deps.now()),signal);
   signal.throwIfAborted();const next=await deps.status(admin,row,signal);
   // Status IDs and current selected-library authority are checked every time.
   if(next.check.id!==initial.check.id||next.evidence.id!==initial.evidence.id)return row;
   await photoQualityScope(admin,next,args.actor,args.selected);row=next;
   if(row.check.state!=="pending")acknowledged=true; // the controller (or cron) has claimed it
   else if(!acknowledged&&row.can_continue&&row.check.judge_started_at===null&&attempts<PHOTO_START_ATTEMPTS&&deps.now()-lastStart>=PHOTO_START_RETRY_MS){signal.throwIfAborted();await wake();}
  }
  if(row.check.state==="derivative_ready"&&row.can_continue&&row.check.judge_started_at===null&&deps.now()<deadline-PHOTO_CHECK_JUDGE_RESERVE_MS){
   signal.throwIfAborted();return await deps.judge(admin,row,{...args,deadline});
  }
  return row;
 }catch{
  // An aborted/busy/read-timeout request returns its last saved state. The
  // journal/lease fences all uncertain starts; this loop never repeats them.
  return row;
 }
}
/** After an early private release the reply no longer waits for the advisory
 * check, so the check continues here: one controller wake, scoped status
 * reads, then the single funded judge, all inside the SAME request budget the
 * synchronous path used. The client connection and its abort signal end with
 * the reply, so this uses a detached request.
 *
 * The judge is only driven from here when the runtime guarantees the instance
 * outlives the reply (EdgeRuntime.waitUntil). Without that guarantee an
 * instance retired mid-call would cut a dispatched judge and leave a HOLD, so
 * only the controller wake is sent and the per-minute controller queue, which
 * owns every saved pending check and prepared judge, runs the judge itself.
 * Either way the SQL lease/bind journal allows exactly one comparison and one
 * judge. Never throws. */
export function continuePhotoQualityAfterResponse(admin:PhotoAdmin,row:PhotoQualityEnvelope,args:{actor:string;selected:string|null;url:string;instruction?:string;deadline:number},wait:typeof waitForPhotoQuality=waitForPhotoQuality):void{
 const runtime=(globalThis as {EdgeRuntime?:{waitUntil?:(work:Promise<unknown>)=>void}}).EdgeRuntime;
 const durable=!!runtime&&typeof runtime.waitUntil==="function";
 let task:Promise<void>;
 try{
  const request=new Request(args.url,{method:"POST"});
  // A deadline no later than the judge reserve lets waitForPhotoQuality wake
  // the controller and return before any status loop or judge call.
  const deadline=durable?args.deadline:Math.min(args.deadline,Date.now()+PHOTO_CHECK_JUDGE_RESERVE_MS);
  task=wait(admin,row,{actor:args.actor,selected:args.selected,request,instruction:args.instruction,deadline}).then(()=>{},()=>{});
 }catch{return;}
 try{if(durable)runtime!.waitUntil!(task);}catch{/* The controller queue still completes the saved check. */}
}
