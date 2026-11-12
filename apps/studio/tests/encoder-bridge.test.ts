import assert from "node:assert/strict";
import {test} from "node:test";
import {createOwnedEncoderBridge,EncoderUnsupportedError,type EncoderWorkerLike,type EncoderBridgeOptions} from "../src/editor/encoder-bridge";
import {createAdmission,normalizeConfig,videoTiming,PCM_BYTES,type EncodedPacket} from "../src/editor/encoder-protocol";
import {PAGE_BYTES} from "../src/editor/encoder-output";
import type {NormalizedEncoderConfig} from "../src/editor/export-plan";

const config=(withAudio=false)=>normalizeConfig({width:1280,height:720,frames:4,durationMicroseconds:125000,
  withAudio,audioFrames:withAudio?6000:0,windowFrameCounts:withAudio?[6000]:[]});
type FakeFrame=VideoFrame & {closed:number};
function frame(c:NormalizedEncoderConfig,index:number):FakeFrame {
  return {...videoTiming(c,index),closed:0,close(){this.closed++;}} as FakeFrame;
}
/** Native codecs are not invoked. This exercises ownership and result fencing. */
class FakeWorker extends EventTarget {
  config!:NormalizedEncoderConfig;admission!:ReturnType<typeof createAdmission>;
  runId="";revision="";terminateCount=0;autoReady=true;autoAck=true;autoComplete=true;
  frames:FakeFrame[]=[];posted:string[]=[];packets:EncodedPacket[]=[];lastPCM:ArrayBuffer|undefined;
  emit(value:Record<string,unknown>){this.dispatchEvent(new MessageEvent("message",{data:{runId:this.runId,revision:this.revision,...value}}));}
  postMessage(value:Record<string,unknown>,_transfer:Transferable[]){
    this.posted.push(value.type as string);
    if(value.type==="init"){
      this.runId=value.runId as string;this.revision=value.revision as string;
      this.config=normalizeConfig(value.config as NormalizedEncoderConfig);this.admission=createAdmission(this.config);
      if(this.autoReady)queueMicrotask(()=>this.emit({type:"ready",config:this.config,credits:{video:2,audio:8}}));
    }else if(value.type==="video"){
      const f=value.frame as FakeFrame,sequence=value.sequence as number;this.frames.push(f);
      this.admission.video(sequence,f.timestamp,f.duration);
      this.packets.push({timestamp:f.timestamp/1e6,duration:f.duration!/1e6,bytes:100});
      if(this.autoAck)queueMicrotask(()=>{f.close();this.admission.ack("video",sequence);this.emit({type:"ack",track:"video",sequence});});
    }else if(value.type==="audio"){
      const sequence=value.sequence as number,buffer=value.buffer as ArrayBuffer;
      this.admission.audio(sequence,value.startFrame as number,value.frameCount as number,value.stride as number,buffer.byteLength);
      // Exercise real ArrayBuffer detach/return transfer without a codec worker.
      this.lastPCM=structuredClone(buffer,{transfer:[buffer]});
      if(this.autoAck){const owned=this.lastPCM;queueMicrotask(()=>{
        this.admission.ack("audio",sequence);
        const returned=structuredClone(owned,{transfer:[owned]});
        this.emit({type:"ack",track:"audio",sequence,buffer:returned});
      });}
    }else if(value.type==="end"){
      this.admission.end();if(this.autoComplete)queueMicrotask(()=>this.complete());
    }
  }
  complete(){this.emit({type:"complete",extent:4,pages:[{index:0,bytes:new ArrayBuffer(PAGE_BYTES)}],
    encoded:this.packets,audioPackets:this.config.withAudio?6:0,input:this.admission.stats()});}
  terminate(){this.terminateCount++;for(const f of this.frames)if(!f.closed)f.close();}
}
function setup(worker=new FakeWorker(),extra:Partial<EncoderBridgeOptions>={}){
  const controller=new AbortController();let stops=0,validations=0;
  const bridge=createOwnedEncoderBridge({workerURL:"worker.js",runId:"owned",revision:"r1",config:config(),
    signal:controller.signal,isCurrent:()=>true,stopInput:()=>{stops++;},
    validateOutput:async(blob)=>{validations++;assert.equal(blob.size,4);},
    createWorker:()=>worker as unknown as EncoderWorkerLike,...extra});
  return {bridge,worker,controller,stops:()=>stops,validations:()=>validations};
}
async function feedVideo(state:ReturnType<typeof setup>){
  for(let i=0;i<state.worker.config.frames;i++)await state.bridge.addVideo(frame(state.worker.config,i));
}
test("silent output is offered only after mandatory validator and exactly one owned termination",async()=>{
  const state=setup();await state.bridge.ready;await feedVideo(state);
  const output=await state.bridge.finish();assert.equal(output.blob.type,"video/mp4");
  assert.equal(state.validations(),1);assert.equal(state.stops(),1);assert.equal(state.worker.terminateCount,1);
  assert.equal(state.bridge.stats().phase,"complete");assert.equal(state.worker.posted.includes("audio"),false);
  assert(state.worker.frames.every(f=>f.closed===1));
  assert(!("partialPrototype" in output));
});
test("PCM ACK returns transferred fixed-stride credit even for an exact partial tail",async()=>{
  const state=setup(undefined,{config:config(true)});await state.bridge.ready;
  let start=0;
  while(start<6000){
    const count=Math.min(1024,6000-start),buffer=new ArrayBuffer(PCM_BYTES);new Float32Array(buffer)[0]=.25;
    const pending=state.bridge.addAudio(buffer,start,count);assert.equal(buffer.byteLength,0);
    const returned=await pending;assert.equal(returned.byteLength,PCM_BYTES);assert.equal(new Float32Array(returned)[0],.25);
    assert.equal(state.worker.lastPCM!.byteLength,0);start+=count;
  }
  await feedVideo(state);await state.bridge.finish();assert.equal(state.bridge.stats().audioFrames,6000);
});
test("typed codec fallback is confined to actual pre-content unsupported response",async()=>{
  const worker=new FakeWorker();worker.autoReady=false;const state=setup(worker);
  worker.emit({type:"error",code:"ENCODER_UNSUPPORTED",message:"Exact codec unavailable"});
  await assert.rejects(state.bridge.ready,EncoderUnsupportedError);assert.equal(worker.terminateCount,1);
  const after=setup();await after.bridge.ready;
  after.worker.emit({type:"error",code:"ENCODER_UNSUPPORTED",message:"Late failure"});
  await assert.rejects(after.bridge.result,error=>error instanceof Error && !(error instanceof EncoderUnsupportedError));
});
test("abort during final validation rejects immediately and a late validation cannot publish",async()=>{
  let enter!:()=>void,done!:()=>void;const entered=new Promise<void>(resolve=>{enter=resolve;});
  const validation=new Promise<void>(resolve=>{done=resolve;});
  const state=setup(undefined,{validateOutput:async()=>{enter();await validation;}});
  await state.bridge.ready;await feedVideo(state);const finishing=state.bridge.finish();await entered;
  state.controller.abort(new Error("Owner cancelled"));await assert.rejects(finishing,/Owner cancelled/);
  done();await Promise.resolve();await Promise.resolve();
  assert.equal(state.bridge.stats().phase,"refused");assert.equal(state.worker.terminateCount,1);assert.equal(state.stops(),1);
});
test("deadline owns termination even while mux/finalize never replies",async(context)=>{
  let expire!:()=>void;
  context.mock.method(globalThis,"setTimeout",((callback:()=>void)=>{expire=callback;return 1;}) as unknown as typeof setTimeout);
  context.mock.method(globalThis,"clearTimeout",()=>undefined);
  const worker=new FakeWorker();worker.autoComplete=false;const state=setup(worker,{deadlineMs:15});
  await state.bridge.ready;await feedVideo(state);const finishing=state.bridge.finish();
  await Promise.resolve();assert.equal(worker.posted.at(-1),"end");expire();await assert.rejects(finishing,/deadline/);
  assert.equal(state.worker.terminateCount,1);assert.equal(state.bridge.stats().terminationSucceeded,1);
});
test("stale response is ignored, revision change closes the worker and rejects all owners",async()=>{
  const worker=new FakeWorker();worker.autoReady=false;const state=setup(worker);
  worker.emit({type:"error",revision:"older",message:"Stale"});assert.equal(worker.terminateCount,0);
  worker.emit({type:"ready",config:worker.config,credits:{video:2,audio:8}});await state.bridge.ready;
  state.bridge.invalidateRevision("r2");await assert.rejects(state.bridge.result,/edit revision changed/);
  assert.equal(worker.terminateCount,1);state.bridge.abort(new Error("Again"));assert.equal(worker.terminateCount,1);
});
test("extra in-flight input refuses and consumes all frame ownership",async()=>{
  const worker=new FakeWorker();worker.autoAck=false;const state=setup(worker);await state.bridge.ready;
  const a=state.bridge.addVideo(frame(worker.config,0)),b=state.bridge.addVideo(frame(worker.config,1));
  const third=frame(worker.config,2);await assert.rejects(state.bridge.addVideo(third),/credit/);
  assert.equal(third.closed,1);await Promise.allSettled([a,b]);assert.equal(worker.terminateCount,1);
});
test("cleanup failure never produces an unsupported fallback or successful result",async()=>{
  const worker=new FakeWorker();worker.autoReady=false;
  const state=setup(worker,{stopInput:()=>{throw new Error("Stop failed");}});
  worker.emit({type:"error",code:"ENCODER_UNSUPPORTED",message:"Codec"});
  await assert.rejects(state.bridge.ready,error=>error instanceof Error && !(error instanceof EncoderUnsupportedError) && /cleanup/.test(error.message));
  assert.equal(worker.terminateCount,1);
});
