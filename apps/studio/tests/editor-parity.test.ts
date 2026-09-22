import test from "node:test";
import assert from "node:assert/strict";
import {clipDuration, locateTime, narrationCaption, validateDraft, newDraft, transitionSeconds, parseDraft, serializeDraft, EDIT_LIMITS, draftMedia, type EditClip} from "../src/editor/model";
import {createHistory, editHistory, undoHistory, redoHistory, releasedMediaIds} from "../src/editor/history";
import {mapShotMotion, reviewShotPlan} from "../src/features/sync/shot-plan";
const video: EditClip = {id:"source",source:{name:"phone.mp4",size:64*1024**2,lastModified:0,sha256:"a".repeat(64),kind:"video",width:1920,height:1080,duration:20},start:4,end:12,caption:"Kitchen",focusX:.5,focusY:.5};
const voice = {resultId:"10000000-0000-4000-8000-000000000001",label:"Saved narration",offset:2,volume:.8,wordCaptions:true,words:[{text:"Welcome",start:0,end:.5},{text:"home",start:.5,end:1}]};
test("phone footage larger than 32 MiB is accepted within bounded 128/512 MiB limits",()=>{
  assert.equal(EDIT_LIMITS.fileBytes,128*1024**2); assert.equal(EDIT_LIMITS.totalBytes,512*1024**2);
  assert.equal(validateDraft({...newDraft(),clips:[video]}).clips[0].source.size,64*1024**2);
  assert.throws(()=>validateDraft({...newDraft(),clips:[{...video,source:{...video.source,size:EDIT_LIMITS.fileBytes+1}}]}),/file bytes/);
});
test("speed changes timeline duration and source seeks together, including exact cut boundaries",()=>{
  const fast={...video,speed:2},slow={...video,id:"slow",speed:.5};
  assert.equal(clipDuration(fast),4);assert.equal(clipDuration(slow),16);
  assert.equal(locateTime([fast,slow],2)?.sourceTime,8);
  assert.equal(locateTime([fast,slow],4)?.clip.id,"slow");
  assert.equal(locateTime([fast,slow],6)?.sourceTime,5);
  assert.throws(()=>validateDraft({...newDraft(),clips:[{...video,speed:0}]}),/clip speed/);
});
test("styles, transition timing and narration survive a saved plan while untrusted URLs are discarded",()=>{
  const clip={...video,speed:2,captionStyle:"center" as const,transition:"dissolve" as const};
  const checked=validateDraft({...newDraft(),clips:[clip],narration:{...voice,url:"https://untrusted.invalid/audio"}});
  assert.equal(transitionSeconds(checked.clips[0]),.28);assert.equal(transitionSeconds({...clip,transition:"whip"}),.18);
  assert.deepEqual(parseDraft(serializeDraft(checked)),checked);assert(!serializeDraft(checked).includes("untrusted"));
  assert.throws(()=>validateDraft({...checked,clips:[{...clip,transition:"spin"}]}),/transition/);
});
test("narration captions honor selected offset and timed gaps rather than burning all words throughout",()=>{
  assert.equal(narrationCaption(voice,1.99),"");assert.equal(narrationCaption(voice,2.2),"Welcome home");assert.equal(narrationCaption(voice,3),"");
  assert.equal(narrationCaption({...voice,wordCaptions:false},2.2),"");
  assert.throws(()=>validateDraft({...newDraft(),narration:{...voice,words:[{text:"late",start:5,end:6},{text:"early",start:2,end:3}]}}),/word start/);
});
test("undo and redo restore removed narration and speed without restoring an old export revision",()=>{
  let history=createHistory({...newDraft(),clips:[video]});history=editHistory(history,{narration:voice,clips:[{...video,speed:2} ]},"voice and timing");
  const revision=history.present.revision;history=undoHistory(history);assert.equal(history.present.narration,undefined);assert.equal(history.present.clips[0].speed,undefined);assert(history.present.revision>revision);
  history=redoHistory(history);assert.deepEqual(history.present.narration,voice);assert.equal(history.present.clips[0].speed,2);
});
test("shot handoff orders exact photos, bounds each duration and rejects missing or repeated identities",()=>{
  const id="20000000-0000-4000-8000-000000000002", shot={photoId:id,order:1,room:"Kitchen",seconds:4,caption:"Kitchen",motion:"slow push in",voiceLine:""};
  const plan={listingId:id,shots:[shot],script:"",narrationResultId:null};
  assert.equal(reviewShotPlan(plan)[0].seconds,4);assert.equal(mapShotMotion("slow push in"),"push_in");assert.equal(mapShotMotion("pan left"),"pan_left");assert.equal(mapShotMotion("360-degree orbit"),"still");
  assert.throws(()=>reviewShotPlan({...plan,shots:[shot,shot]}),/repeats/);
  assert.throws(()=>reviewShotPlan({...plan,shots:[{...shot,seconds:40}]}),/timing/);
});

test("overlay media participates in persistence, exact identity retention, undo and combined source limits",()=>{
 const overlay={id:"cutaway",source:{name:"detail.png",size:128*1024**2,lastModified:0,sha256:"f".repeat(64),kind:"image" as const,width:1000,height:1000,duration:0},start:1,end:2,caption:"A detail",focusX:.5,focusY:.5};
 const draft=validateDraft({...newDraft(),clips:[video],overlays:[overlay]});assert.equal(draftMedia(draft).length,2);assert.deepEqual(parseDraft(serializeDraft(draft)).overlays,[overlay]);
 const live=new Map(draftMedia(draft).map(item=>[item.id,item.source]));assert.deepEqual(releasedMediaIds(draft,live),[]);
 let history=editHistory(createHistory(draft),{overlays:[]},"remove cutaway");assert.deepEqual(releasedMediaIds(history.present,live),["cutaway"]);history=undoHistory(history);assert.deepEqual(history.present.overlays,[overlay]);
 const large=Array.from({length:4},(_,index)=>({...video,id:`base-${index}`,source:{...video.source,size:128*1024**2,sha256:String(index).repeat(64)}}));
 assert.throws(()=>validateDraft({...newDraft(),clips:large,overlays:[overlay]}),/Base footage/);
});
