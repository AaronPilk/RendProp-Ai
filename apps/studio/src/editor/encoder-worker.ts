import {Output,Mp4OutputFormat,StreamTarget,VideoSampleSource,AudioSampleSource,
  VideoSample,AudioSample,Quality,canEncodeVideo,canEncodeAudio} from "mediabunny";
import type {NormalizedEncoderConfig} from "./export-plan";
import {createPagedWritableTarget,MAX_EXTENT} from "./encoder-output";
import {normalizeConfig,requireIdentity,requireEnvelope,createAdmission,verifyEncodedPackets,
  EncoderUnsupportedError,PCM_STRIDE,FPS,RATE,type EncodedPacket} from "./encoder-protocol";

// Capability work lives with the codecs. This is the sole unsupported-codec
// classification seam; failures after admission are never fallback candidates.
export async function isEncoderConfigurationSupported(config: NormalizedEncoderConfig): Promise<boolean> {
  if(typeof VideoEncoder!=="function" || (config.withAudio && typeof AudioEncoder!=="function"))return false;
  return await canEncodeVideo("avc",{width:config.width,height:config.height,frameRate:FPS,
    quality:new Quality({bitrate:5_000_000}),fullCodecString:"avc1.42001f",latencyMode:"quality",
    hardwareAcceleration:"no-preference"}) && (!config.withAudio || await canEncodeAudio("aac",{
    numberOfChannels:2,sampleRate:RATE,quality:new Quality({bitrate:128_000}),fullCodecString:"mp4a.40.2"}));
}
type Identity={runId:string;revision:string};
type InputRow=Identity & {type:string;config:NormalizedEncoderConfig;sequence:number;frame:VideoFrame;
  buffer:ArrayBuffer;startFrame:number;frameCount:number;stride:number};
const scope=globalThis as unknown as {
  postMessage(message:unknown,transfer:Transferable[]):void;
  onmessage:((event:MessageEvent<InputRow>)=>void)|null;
};
let identity:Identity|null=null,phase="new",config:NormalizedEncoderConfig;
let admission:ReturnType<typeof createAdmission>,output:Output|undefined,video:VideoSampleSource;
let audio:AudioSampleSource|undefined,pages:ReturnType<typeof createPagedWritableTarget>|undefined;
let videoTail=Promise.resolve(),audioTail=Promise.resolve(),fatal:Error|null=null;
const encoded:EncodedPacket[]=[];let encodedBytes=0,audioPackets=0;
const send=(type:string,value:Record<string,unknown>={},transfer:Transferable[]=[])=>
  scope.postMessage({...identity,type,...value},transfer);
function live(){if(fatal || phase==="failed")throw fatal??new Error("Encoder worker stopped.");}
function fail(error:unknown){
  if(phase==="failed" || phase==="done")return;
  fatal=error instanceof Error?error:new Error(String(error));phase="failed";pages?.dispose();
  try{send("error",{code:fatal instanceof EncoderUnsupportedError?fatal.code:"ENCODER_REFUSED",
    message:fatal.message.slice(0,500)});}catch{/* Parent also owns error/deadline handling. */}
  // cancel() cannot interrupt finalization. The parent owns hard termination.
  try{void output?.cancel().catch(()=>undefined);}catch{/* Parent terminates. */}
}
function packetBytes(packet:{byteLength:number}){
  if(!Number.isSafeInteger(packet.byteLength) || packet.byteLength<1)throw new Error("Invalid encoded packet size.");
  encodedBytes+=packet.byteLength;
  if(encodedBytes>MAX_EXTENT)throw new Error("Encoded payload exceeds 128 MiB.");
}
async function initialize(row:InputRow){
  if(phase!=="new")throw new Error("Encoder worker may initialize once.");
  requireIdentity(row.runId,row.revision);identity={runId:row.runId,revision:row.revision};
  phase="initializing";config=normalizeConfig(row.config);admission=createAdmission(config);
  if (!await isEncoderConfigurationSupported(config))
    throw new EncoderUnsupportedError("The exact H.264/AAC configuration is unavailable in this browser.");
  live();pages=createPagedWritableTarget();
  output=new Output({format:new Mp4OutputFormat({fastStart:false}),
    target:new StreamTarget(pages.writable,{chunked:true,chunkSize:1024*1024})});
  video=new VideoSampleSource({codec:"avc",quality:new Quality({bitrate:5_000_000}),fullCodecString:"avc1.42001f",
    latencyMode:"quality",hardwareAcceleration:"no-preference",onEncodedPacket(packet){
      packetBytes(packet);
      if(encoded.length>=config.frames || !Number.isFinite(packet.timestamp) ||
          !Number.isFinite(packet.duration) || packet.duration<=0)throw new Error("Invalid encoded video metadata.");
      encoded.push({timestamp:packet.timestamp,duration:packet.duration,bytes:packet.byteLength});
    }});
  // VideoFrame timestamps already define the 30 Hz cadence. Track frameRate
  // snaps durations to full ticks and erases a fractional final frame.
  output.addVideoTrack(video);
  if(config.withAudio){
    audio=new AudioSampleSource({codec:"aac",quality:new Quality({bitrate:128_000}),fullCodecString:"mp4a.40.2",
      onEncodedPacket(packet){packetBytes(packet);audioPackets++;}});
    output.addAudioTrack(audio);
  }
  await output.start();live();phase="ready";
  send("ready",{config,credits:{video:2,audio:8}});
}
function addVideo(row:InputRow){
  if(!(row.frame instanceof VideoFrame))throw new Error("Expected a transferred VideoFrame.");
  if(row.frame.displayWidth!==config.width || row.frame.displayHeight!==config.height)
    throw new Error("Transferred video dimensions changed.");
  admission.video(row.sequence,row.frame.timestamp,row.frame.duration);
  videoTail=videoTail.then(async()=>{
    let sample:VideoSample|undefined;
    try{live();sample=new VideoSample(row.frame);
      await video.add(sample,{keyFrame:row.sequence===0 || row.sequence%60===0});live();
    }finally{if(sample)sample.close();else row.frame.close();}
    admission.ack("video",row.sequence);send("ack",{track:"video",sequence:row.sequence});
  }).catch(fail);
}
function addAudio(row:InputRow){
  if(!(row.buffer instanceof ArrayBuffer))throw new Error("Expected owned PCM ArrayBuffer.");
  admission.audio(row.sequence,row.startFrame,row.frameCount,row.stride,row.buffer.byteLength);
  audioTail=audioTail.then(async()=>{
    let sample:AudioSample|undefined;
    try{
      live();const raw=new Float32Array(row.buffer);
      const exact=row.frameCount===PCM_STRIDE?raw:new Float32Array(row.frameCount*2);
      if(exact!==raw)for(let channel=0;channel<2;channel++)
        exact.set(raw.subarray(channel*PCM_STRIDE,channel*PCM_STRIDE+row.frameCount),channel*row.frameCount);
      for(const value of exact)if(!Number.isFinite(value))throw new Error("Nonfinite PCM sample.");
      sample=new AudioSample({format:"f32-planar",data:exact,numberOfChannels:2,sampleRate:RATE,
        timestamp:row.startFrame/RATE});
      if(!audio)throw new Error("A silent export cannot encode audio.");
      await audio.add(sample);live();
    }finally{sample?.close();}
    admission.ack("audio",row.sequence);
    // ACK returns ownership after add+close; it is not an encode-completion ACK.
    send("ack",{track:"audio",sequence:row.sequence,buffer:row.buffer},[row.buffer]);
  }).catch(fail);
}
async function finish(){
  admission.end();phase="finalizing";await Promise.all([videoTail,audioTail]);live();
  video.close();audio?.close();await output!.finalize();live();
  if(config.withAudio ? audioPackets<1 : audioPackets!==0)throw new Error("Encoded audio metadata is incomplete.");
  const ordered=[...encoded].sort((a,b)=>a.timestamp-b.timestamp);verifyEncodedPackets(config,ordered);
  const result=pages!.claimSuccessfulOutput();
  if(result.extent<1 || result.extent>MAX_EXTENT)throw new Error("Empty or oversized output.");
  send("complete",{...result,encoded:ordered,audioPackets,input:admission.stats()},result.pages.map(page=>page.bytes));
  phase="done";
}
scope.onmessage=({data:row})=>{
  try{
    if(row?.type==="init"){void initialize(row).catch(fail);return;}
    requireEnvelope(row,identity?.runId??"",identity?.revision??"");
    if(phase!=="ready")throw new Error("Encoder worker is not accepting media.");
    if(row.type==="video")addVideo(row);
    else if(row.type==="audio")addAudio(row);
    else if(row.type==="end")void finish().catch(fail);
    else throw new Error("Unknown encoder message.");
  }catch(error){try{row?.frame?.close();}catch{/* Already transferred/closed. */}fail(error);}
};
