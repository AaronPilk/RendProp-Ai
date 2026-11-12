import assert from "node:assert/strict";
import {test} from "node:test";
import {normalizeConfig,createAdmission,videoTiming,verifyEncodedPackets,PCM_BYTES} from "../src/editor/encoder-protocol";

const config=(withAudio=true)=>normalizeConfig({width:1280,height:720,frames:165,durationMicroseconds:5500000,
  withAudio,audioFrames:withAudio?264000:0,windowFrameCounts:withAudio?[24000,96000,24000,96000,24000]:[]});
test("five declared PCM windows admit 260 exact blocks without padding or loss",()=>{
  const c=config(),a=createAdmission(c);let seq=0,start=0;const tails:number[]=[];
  for(const count of c.windowFrameCounts){
    let remaining=count;
    while(remaining){const size=Math.min(1024,remaining);
      a.audio(seq,start,size,1024,PCM_BYTES);a.ack("audio",seq++);start+=size;remaining-=size;
      if(!remaining)tails.push(size);
    }
  }
  assert.equal(seq,260);assert.equal(start,264000);assert.deepEqual(tails,[448,768,448,768,448]);
  for(let i=0;i<c.frames;i++){const t=videoTiming(c,i);a.video(i,t.timestamp,t.duration);a.ack("video",i);}
  a.end();assert.equal(a.stats().ended,true);assert.throws(()=>a.end());
});
test("short blocks only occur at declared window ends; rejection never advances state",()=>{
  const a=createAdmission(config());
  for(const [start,count,stride,bytes] of [[0,512,1024,PCM_BYTES],[1,1024,1024,PCM_BYTES],[0,1024,512,PCM_BYTES],[0,1024,1024,8]]){
    const before=a.stats();assert.throws(()=>a.audio(0,start,count,stride,bytes));assert.deepEqual(a.stats(),before);
  }
  assert.throws(()=>a.end(),/incomplete/);
});
test("admission enforces exactly two video and eight audio ownership credits",()=>{
  const c=config(),a=createAdmission(c);
  for(let i=0;i<2;i++){const t=videoTiming(c,i);a.video(i,t.timestamp,t.duration);}
  const t=videoTiming(c,2);assert.throws(()=>a.video(2,t.timestamp,t.duration),/credit/);
  a.ack("video",0);a.video(2,t.timestamp,t.duration);assert.throws(()=>a.ack("video",0));
  assert.throws(()=>a.ack("video",2),/reordered/);a.ack("video",1);a.ack("video",2);
  for(let i=0;i<8;i++)a.audio(i,i*1024,1024,1024,PCM_BYTES);
  assert.throws(()=>a.audio(8,8192,1024,1024,PCM_BYTES),/credit/);
  a.ack("audio",0);a.audio(8,8192,1024,1024,PCM_BYTES);
});
test("normalization freezes a copied plan and refuses invalid independent audio plans",()=>{
  const input={width:1280,height:720,frames:15,durationMicroseconds:500000,withAudio:true,audioFrames:24000,windowFrameCounts:[24000]};
  const c=normalizeConfig(input);input.windowFrameCounts[0]=1;assert.deepEqual(c.windowFrameCounts,[24000]);
  assert(Object.isFrozen(c.windowFrameCounts));
  for(const patch of [{frames:14},{audioFrames:24001},{windowFrameCounts:[0,24000]},
    {windowFrameCounts:[24000,1]},{withAudio:false},{durationMicroseconds:180000001}])
    assert.throws(()=>normalizeConfig({...input,windowFrameCounts:[24000],...patch}));
  const silent=config(false);assert.throws(()=>createAdmission(silent).audio(0,0,1024,1024,PCM_BYTES));
});
test("encoded metadata checks exact unique PTS and partial final duration",()=>{
  const c=normalizeConfig({width:960,height:960,frames:4,durationMicroseconds:125000,withAudio:false,audioFrames:0,windowFrameCounts:[]});
  const packets=Array.from({length:4},(_,i)=>{const t=videoTiming(c,i);return{timestamp:t.timestamp/1e6,duration:t.duration/1e6,bytes:100};});
  verifyEncodedPackets(c,packets);
  assert.throws(()=>verifyEncodedPackets(c,packets.slice(1)));
  assert.throws(()=>verifyEncodedPackets(c,packets.map((p,i)=>i===3?{...p,duration:1/30}:p)));
  assert.throws(()=>verifyEncodedPackets(c,packets.map((p,i)=>i===1?{...p,timestamp:0}:p)));
});
