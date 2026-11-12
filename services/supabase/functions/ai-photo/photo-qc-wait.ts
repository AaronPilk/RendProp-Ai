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
/** One CPU kickoff, then only fresh scoped status reads. Never restart a CPU
 * or judge in this loop. Leave45s for bounded derivative reads+one judge. */
export async function waitForPhotoQuality(admin:PhotoAdmin,initial:PhotoQualityEnvelope,args:{actor:string;selected:string|null;request:Request;instruction?:string;deadline?:number},deps=actual):Promise<PhotoQualityEnvelope>{
 const now=deps.now(),deadline=Math.min(args.deadline??now+PHOTO_CHECK_ENDPOINT_BUDGET_MS,now+PHOTO_CHECK_ENDPOINT_BUDGET_MS);
 let row=initial;
 if(!Number.isSafeInteger(deadline)||deadline<=now)return row;
 const signal=AbortSignal.any([args.request.signal,AbortSignal.timeout(deadline-now)]);
 try{
  await photoQualityScope(admin,row,args.actor,args.selected);signal.throwIfAborted();
  if(row.check.state==="pending"&&row.can_continue&&row.check.judge_started_at===null){
   const started=await deps.start(row.check.id,signal);
   // A missing/lost acknowledgment authorizes no second start. A later GET or
   // explicit same-operation check reconciles the saved controller state.
   if(!started.started)return row;
  }
  while(["pending","preparing"].includes(row.check.state)&&row.check.judge_started_at===null&&deps.now()<deadline-PHOTO_CHECK_JUDGE_RESERVE_MS){
   await deps.sleep(Math.min(1500,deadline-PHOTO_CHECK_JUDGE_RESERVE_MS-deps.now()),signal);
   signal.throwIfAborted();const next=await deps.status(admin,row,signal);
   // Status IDs and current selected-library authority are checked every time.
   if(next.check.id!==initial.check.id||next.evidence.id!==initial.evidence.id)return row;
   await photoQualityScope(admin,next,args.actor,args.selected);row=next;
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
 * the reply, so this uses a detached request. If the runtime ends the isolate
 * early nothing is lost: the per-minute controller queue owns every saved
 * pending check and prepared judge, and the SQL lease/bind journal still
 * allows exactly one comparison and one judge. Never throws. */
export function continuePhotoQualityAfterResponse(admin:PhotoAdmin,row:PhotoQualityEnvelope,args:{actor:string;selected:string|null;url:string;instruction?:string;deadline:number},wait:typeof waitForPhotoQuality=waitForPhotoQuality):void{
 let task:Promise<void>;
 try{
  const request=new Request(args.url,{method:"POST"});
  task=wait(admin,row,{actor:args.actor,selected:args.selected,request,instruction:args.instruction,deadline:args.deadline}).then(()=>{},()=>{});
 }catch{return;}
 const runtime=(globalThis as {EdgeRuntime?:{waitUntil?:(work:Promise<unknown>)=>void}}).EdgeRuntime;
 try{if(runtime&&typeof runtime.waitUntil==="function")runtime.waitUntil(task);}catch{/* The controller queue still completes the saved check. */}
}
