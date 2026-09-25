import test from "node:test";
import assert from "node:assert/strict";
import type {StudioServices} from "../src/data";
import type {EditClip} from "../src/editor/model";
import {requestSourceAnalysis} from "../src/features/sync/cloud-finishing";

const clip: EditClip = {id:"clip",source:{name:"video.mp4",size:100,lastModified:1,sha256:"a".repeat(64),kind:"video",duration:10,width:1280,height:720},start:0,end:10,caption:"",focusX:.5,focusY:.5};
test("speech analysis requires saved original and bounded video before capability or paid request",async()=>{
 let calls=0;const services={api:async()=>{calls++;}} as unknown as StudioServices;
 await assert.rejects(()=>requestSourceAnalysis(services,"org",clip,undefined,new AbortController().signal),/Save this original/);
 await assert.rejects(()=>requestSourceAnalysis(services,"org",{...clip,source:{...clip.source,size:24_000_001}},{assetId:"asset",listingId:"listing"},new AbortController().signal),/24 MB/);
 assert.equal(calls,0);
});
test("disabled speech capability performs no paid request and offers timed-subtitle import",async()=>{
 const calls:string[]=[];const services={api:async(path:string)=>{calls.push(path);return {available:false};}} as unknown as StudioServices;
 await assert.rejects(()=>requestSourceAnalysis(services,"org",clip,{assetId:"asset",listingId:"listing"},new AbortController().signal),/SRT or WebVTT/);
 assert.deepEqual(calls,["/functions/v1/studio/media-analysis"]);
});
test("enabled speech request sends only authorized source IDs and a unique idempotency key; errors are not retried",async()=>{
 const calls:unknown[]=[];const services={api:async(_path:string,options:Record<string,unknown>)=>{calls.push(options);if(options.method==="POST")throw new Error("Unknown result");return {available:true};}} as unknown as StudioServices;
 await assert.rejects(()=>requestSourceAnalysis(services,"org",clip,{assetId:"asset",listingId:"listing"},new AbortController().signal),/Unknown result/);
 assert.equal(calls.length,2);const sent=calls[1] as Record<string,unknown>;
 assert.deepEqual(sent.body,{listing_id:"listing",source_id:"asset",source_kind:"asset"});assert.match(sent.idempotencyKey as string,/^[a-f0-9-]{36}$/);
 assert.equal(JSON.stringify(sent).includes(clip.source.name),false);assert.equal(JSON.stringify(sent).includes(clip.source.sha256),false);
});
