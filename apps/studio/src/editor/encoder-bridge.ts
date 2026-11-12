import type {EncoderConfig,NormalizedEncoderConfig} from "./export-plan";
import {normalizeConfig,requireIdentity,requireEnvelope,createAdmission,verifyEncodedPackets,
  EncoderUnsupportedError,PCM_STRIDE,PCM_BYTES,type EncodedPacket} from "./encoder-protocol";
import {outputBlob,type PagedOutput} from "./encoder-output";
export {EncoderUnsupportedError,isEncoderUnsupportedError} from "./encoder-protocol";

export type EncoderOutput=Readonly<{blob:Blob;config:NormalizedEncoderConfig;encoded:readonly EncodedPacket[]}>;
export type EncoderValidation={config:NormalizedEncoderConfig;encoded:readonly EncodedPacket[];
  signal:AbortSignal;runId:string;revision:string};
export type EncoderWorkerLike=Pick<Worker,"postMessage"|"addEventListener"|"removeEventListener"|"terminate">;
export type EncoderBridgeOptions={
  workerURL:URL|string;runId:string;revision:string;config:EncoderConfig;signal:AbortSignal;
  isCurrent:(revision:string)=>boolean;stopInput:(reason:unknown)=>void;
  validateOutput:(blob:Blob,context:EncoderValidation)=>Promise<void>;
  createWorker?:(url:URL|string)=>EncoderWorkerLike;deadlineMs?:number;
};
function deferred<T>() {
  let resolve!:(value:T|PromiseLike<T>)=>void,reject!:(reason:unknown)=>void;
  const promise=new Promise<T>((a,b)=>{resolve=a;reject=b;});
  void promise.catch(()=>undefined);return {promise,resolve,reject};
}
type Slot=ReturnType<typeof deferred<ArrayBuffer|undefined>>;
type Response=PagedOutput & {runId:string;revision:string;type:string;config:EncoderConfig;
  credits:{video:number;audio:number};track:"audio"|"video";sequence:number;buffer:ArrayBuffer;
  encoded:EncodedPacket[];audioPackets:number;input:ReturnType<ReturnType<typeof createAdmission>["stats"]>;
  code:string;message:string};

/** Owns one module worker, its input credits and its entire finalize lifetime. */
export function createOwnedEncoderBridge(options:EncoderBridgeOptions) {
  const {runId,revision,signal,isCurrent,stopInput,validateOutput}=options;
  requireIdentity(runId,revision);
  const config=normalizeConfig(options.config),admission=createAdmission(config);
  if(!signal || typeof isCurrent!=="function" || typeof stopInput!=="function" || typeof validateOutput!=="function")
    throw new Error("Abort/revision, owned input stop and output validation are required.");
  const limit=options.deadlineMs??(config.durationMicroseconds/1e6*2+60)*1000;
  if(!Number.isFinite(limit) || limit<1 || limit>420000)throw new Error("Invalid encoder deadline.");
  let worker:EncoderWorkerLike;
  try{
    if(!options.createWorker && typeof Worker!=="function")throw new EncoderUnsupportedError("Module workers are unavailable.");
    worker=(options.createWorker??(url=>new Worker(url,{type:"module"})))(options.workerURL);
  }catch(error){
    try{stopInput(error);}catch(cleanup){throw new Error("Owned input cleanup failed.",{cause:cleanup});}
    throw error;
  }
  const ready=deferred<void>(),result=deferred<EncoderOutput>(),pending=new Map<string,Slot>();
  let phase="starting",terminal=false,terminationCalls=0,terminationSucceeded=0;
  let deadline:ReturnType<typeof setTimeout>|undefined;
  const cleanupFailures:string[]=[];
  const current=()=>{
    if(terminal)throw new Error("Owned encoder session is closed.");
    if(signal.aborted)throw signal.reason??new DOMException("Cancelled.","AbortError");
    if(!isCurrent(revision))throw new Error("The edit revision changed.");
  };
  function release(reason:unknown){
    clearTimeout(deadline);signal.removeEventListener("abort",aborted);
    worker.removeEventListener("message",message);worker.removeEventListener("error",workerError);
    worker.removeEventListener("messageerror",messageError);
    terminationCalls++;
    try{worker.terminate();terminationSucceeded++;}catch(error){cleanupFailures.push(String(error).slice(0,500));}
    try{stopInput(reason);}catch(error){cleanupFailures.push(String(error).slice(0,500));}
    return cleanupFailures.length?new Error("Owned input/encoder cleanup failed: "+cleanupFailures.join("; ")):null;
  }
  function refuse(error:unknown){
    if(terminal)return;
    terminal=true;phase="refused";
    const original=error instanceof Error?error:new Error(String(error));
    // Cleanup failure is terminal too; never convert it into codec fallback.
    const cause=release(original)??original;
    ready.reject(cause);result.reject(cause);
    for(const slot of pending.values())slot.reject(cause);pending.clear();
  }
  const aborted=()=>refuse(signal.reason??new DOMException("Cancelled.","AbortError"));
  const workerError=(event:ErrorEvent)=>refuse(event.error??new Error(event.message||"Encoder worker failed."));
  const messageError=()=>refuse(new Error("Encoder worker response could not be decoded."));
  function post(value:Record<string,unknown>,transfer:Transferable[]=[]){worker.postMessage({runId,revision,...value},transfer);}
  async function complete(row:Response){
    if(phase!=="ending" || !admission.stats().ended)throw new Error("Unexpected encoder completion.");
    phase="validating";
    if(!Number.isSafeInteger(row.audioPackets) || (config.withAudio?row.audioPackets<1:row.audioPackets!==0) ||
        JSON.stringify(row.input)!==JSON.stringify(admission.stats()))throw new Error("Encoded input metadata is incomplete.");
    verifyEncodedPackets(config,row.encoded);
    const encoded=Object.freeze(row.encoded.map(packet=>Object.freeze({...packet})));
    const blob=outputBlob(row);row.pages.length=0;
    current();
    await validateOutput(blob,{config,encoded,signal,runId,revision});
    current();terminal=true;phase="complete";
    const cleanupError=release(null);
    if(cleanupError){phase="refused";result.reject(cleanupError);return;}
    result.resolve(Object.freeze({blob,config,encoded}));
  }
  function message(event:MessageEvent<unknown>){
    if(terminal)return;
    const row=event.data as Response;
    // A worker belongs to one run. Stale responses never apply to this run.
    if(!row || row.runId!==runId || row.revision!==revision)return;
    try{
      current();requireEnvelope(row,runId,revision);
      if(row.type==="ready"){
        if(phase!=="starting" || JSON.stringify(row.config)!==JSON.stringify(config) ||
            row.credits?.video!==2 || row.credits?.audio!==8)throw new Error("Unexpected encoder readiness.");
        phase="active";ready.resolve(undefined);
      }else if(row.type==="ack"){
        if(row.track!=="video" && row.track!=="audio")throw new Error("Unknown encoder acknowledgement track.");
        const key=row.track+":"+row.sequence,slot=pending.get(key);
        if(!slot)throw new Error("Unknown or duplicate encoder acknowledgement.");
        if(row.track==="audio" && (!(row.buffer instanceof ArrayBuffer) || row.buffer.byteLength!==PCM_BYTES))
          throw new Error("Returned PCM ownership changed.");
        admission.ack(row.track,row.sequence);pending.delete(key);slot.resolve(row.buffer);
      }else if(row.type==="complete")void complete(row).catch(refuse);
      else if(row.type==="error"){
        const beforeContent=phase==="starting" && admission.stats().videoCount===0 && admission.stats().audioCount===0;
        refuse(row.code==="ENCODER_UNSUPPORTED" && beforeContent?
          new EncoderUnsupportedError(row.message):new Error(row.message||"Encoder worker refused."));
      }else throw new Error("Unknown encoder response.");
    }catch(error){refuse(error);}
  }
  worker.addEventListener("message",message);worker.addEventListener("error",workerError);
  worker.addEventListener("messageerror",messageError);signal.addEventListener("abort",aborted,{once:true});
  deadline=setTimeout(()=>refuse(new Error("Owned encoder export deadline exceeded.")),limit);
  try{current();post({type:"init",config});}catch(error){refuse(error);}
  function send(track:"audio"|"video",row:Record<string,unknown>&{sequence:number},transfer:Transferable[]){
    const key=track+":"+row.sequence,slot=deferred<ArrayBuffer|undefined>();pending.set(key,slot);
    try{post({type:track,...row},transfer);}catch(error){
      if(track==="video")try{(row.frame as VideoFrame).close();}catch{/* Already closed. */}
      pending.delete(key);slot.reject(error);refuse(error);
    }
    return slot.promise;
  }
  return {
    ready:ready.promise,result:result.promise,
    /** Consumes the frame even when admission or postMessage fails. */
    addVideo(frame:VideoFrame):Promise<void>{
      try{
        current();if(phase!=="active")throw new Error("Encoder is not accepting frames.");
        const sequence=admission.stats().videoCount;admission.video(sequence,frame.timestamp,frame.duration);
        return send("video",{sequence,frame},[frame]).then(()=>undefined);
      }catch(error){try{frame?.close();}catch{/* Already closed. */}refuse(error);return Promise.reject(error);}
    },
    /** Always transfers/returns the full fixed-stride worklet credit buffer. */
    async addAudio(buffer:ArrayBuffer,startFrame:number,frameCount:number):Promise<ArrayBuffer>{
      try{
        current();if(phase!=="active")throw new Error("Encoder is not accepting PCM.");
        if(!(buffer instanceof ArrayBuffer))throw new Error("Expected owned PCM buffer.");
        const sequence=admission.stats().audioCount;
        admission.audio(sequence,startFrame,frameCount,PCM_STRIDE,buffer.byteLength);
        const returned=await send("audio",{sequence,startFrame,frameCount,stride:PCM_STRIDE,buffer},[buffer]);
        if(!returned)throw new Error("PCM ownership was not returned.");return returned;
      }catch(error){refuse(error);throw error;}
    },
    async finish():Promise<EncoderOutput>{
      try{
        current();if(phase!=="active")throw new Error("Encoder cannot finish in its current state.");
        phase="ending";await Promise.all([...pending.values()].map(slot=>slot.promise));
        current();admission.end();post({type:"end"});
      }catch(error){refuse(error);}
      return result.promise;
    },
    invalidateRevision(next:string){if(next!==revision)refuse(new Error("The edit revision changed."));},
    abort:refuse,
    stats:()=>({phase,...admission.stats(),pending:pending.size,terminationCalls,terminationSucceeded,
      cleanupFailures:[...cleanupFailures]}),
  };
}
export type OwnedEncoderBridge=ReturnType<typeof createOwnedEncoderBridge>;
