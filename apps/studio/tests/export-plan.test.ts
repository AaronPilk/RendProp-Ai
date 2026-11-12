import assert from "node:assert/strict";
import {test} from "node:test";
import {planExport} from "../src/editor/export-plan";
import {normalizeConfig,videoTiming} from "../src/editor/encoder-protocol";
import type {EditDraft} from "../src/editor/model";

function draft(durations:number[],speed=1):EditDraft {
  return {schema:1,id:"plan",revision:0,ratio:"16:9",title:"",audio:"original",clips:durations.map((duration,index)=>({
    id:String(index),source:{name:"clip.mp4",size:1,lastModified:0,sha256:"a".repeat(64),kind:"video",
      width:1280,height:720,duration:Math.max(.5,duration*speed)},start:0,end:duration*speed,speed,
    caption:"",focusX:.5,focusY:.5}))};
}
test("fractional duration plans independent audio and a positive final partial video frame",()=>{
  const plan=planExport(draft([.125],4),true),config=normalizeConfig(plan.config);
  assert.equal(config.frames,4);assert.equal(config.audioFrames,6000);
  assert.deepEqual(videoTiming(config,3),{timestamp:100000,duration:25000});
  assert.deepEqual(plan.windows.map(w=>[w.startFrame,w.frameCount]),[[0,6000]]);
});
test("audio uses original seconds independently of rounded video microseconds",()=>{
  const plan=planExport(draft([.5000104167]),true),config=normalizeConfig(plan.config);
  assert.equal(config.durationMicroseconds,500010);assert.equal(config.audioFrames,24001);
  assert.notEqual(config.audioFrames,Math.round(config.durationMicroseconds*48000/1e6));
});
test("cumulative window rounding conserves every sample for arbitrary fractional clips",()=>{
  for(let count=1;count<=12;count++){
    const durations=Array.from({length:count},(_,i)=>.5+(i*173+count*31)%997/1000);
    const plan=planExport(draft(durations),true),config=normalizeConfig(plan.config);
    let at=0,seconds=0;
    for(const window of plan.windows){
      seconds+=window.durationSeconds;
      assert.equal(window.startFrame,at);at+=window.frameCount;assert.equal(at,Math.round(seconds*48000));
    }
    assert.equal(at,config.audioFrames);assert.equal(plan.windows.length,count);
    let end=0;
    for(let i=0;i<config.frames;i++){
      const row=videoTiming(config,i);assert.equal(row.timestamp,end);assert(row.duration>0);end+=row.duration;
    }
    assert.equal(end,config.durationMicroseconds);
  }
});
test("silent plans require no PCM windows and all exposed planning data is frozen",()=>{
  const input=draft([.625,.999]),plan=planExport(input,false);
  assert.equal(plan.config.audioFrames,0);assert.deepEqual(plan.windows,[]);assert.deepEqual(plan.config.windowFrameCounts,[]);
  assert(Object.isFrozen(plan));assert(Object.isFrozen(plan.config));assert(Object.isFrozen(plan.windows));
  assert(Object.isFrozen(plan.config.windowFrameCounts));
  const audible=planExport(input,true);assert(Object.isFrozen(audible.windows[0]));
  input.clips[0]!.end=4;assert.equal(audible.windows[0]!.durationSeconds,.625);
});
test("planning refuses invalid ratios, source geometry, trim, speed and duration bounds",()=>{
  for(const mutate of [
    (d:EditDraft)=>{d.ratio="other" as EditDraft["ratio"];},
    (d:EditDraft)=>{d.clips[0]!.end=NaN;},
    (d:EditDraft)=>{d.clips[0]!.source.width=0;},
    (d:EditDraft)=>{d.clips[0]!.speed=0;},
    (d:EditDraft)=>{d.clips[0]!.end=301;d.clips[0]!.source.duration=301;},
    (d:EditDraft)=>{d.clips[0]!.start=-1;},
    (d:EditDraft)=>{d.clips[0]!.end=.1;},
  ]){const d=draft([1]);mutate(d);assert.throws(()=>planExport(d,true));}
  assert.throws(()=>planExport(draft([90,90.000001]),true),/three-minute/);
  assert.throws(()=>planExport(draft([]),false));
  assert.throws(()=>planExport(draft(Array(13).fill(1)),false));
  assert.equal(planExport(draft([90,90]),true).config.frames,5400);
});
