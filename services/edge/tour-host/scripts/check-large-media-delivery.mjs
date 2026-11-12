import assert from "node:assert/strict";
import {buildSrc} from "./build-src.mjs";

// Exercise the real Worker with admitted immutable master metadata and lazy R2
// streams. Fake time changes only timer scheduling; byte/control code is real.
const load=buildSrc("large-media-delivery-check"),{handleMediaDelivery}=process.env.MEDIA_LARGE_MUTATION_MODULE?await import(process.env.MEDIA_LARGE_MUTATION_MODULE):await load("media-delivery");
const key="renders/10000000-0000-4000-8000-000000000001/20000000-0000-4000-8000-000000000002/master.mp4";
const slug="large-fixture",asset="30000000-0000-4000-8000-000000000003",MAX=1610612736,ordinary=256*1024*1024;
const limit=()=>({kind:"registered_background_video",asset_id:asset,bytes:size,sha256:"a".repeat(64),max_object_bytes:MAX});
let size=ordinary+1,allowed=true,limits=true,metadataFault=null,authReads=0,heads=0,gets=0,cancelled=0,reads=0,streamFactory=null;
const charged=[];
const env={SUPABASE_FUNCTIONS_URL:"https://api.fixture.invalid/functions/v1",SUPABASE_ANON_KEY:"public-fixture",MEDIA_GATEWAY_SECRET:"d".repeat(64)};
const bucket={
 async head(){heads++;return {size,etag:"immutable",httpEtag:'"immutable"',uploaded:new Date("2026-10-14T00:00:00Z"),writeHttpMetadata(h){h.set("Content-Type","video/mp4");}};},
 async get(_key,opts){gets++;assert.deepEqual(opts.onlyIf,{etagMatches:"immutable"});return {body:streamFactory?.(opts)??lazyBytes(opts.range?.length??size)};},
};
env.MEDIA_RENDERS=bucket;env.MEDIA_UPLOADS=bucket;
function lazyBytes(total){let sent=0;const chunk=new Uint8Array(65536);return new ReadableStream({pull(c){reads++;if(sent===total){c.close();return;}const n=Math.min(chunk.length,total-sent);sent+=n;c.enqueue(n===chunk.length?chunk:chunk.subarray(0,n));},cancel(){cancelled++;}});}
globalThis.fetch=async(raw,init)=>{
 const url=new URL(raw);assert.equal(url.hostname,"api.fixture.invalid");assert.equal(init.cache,"no-store");assert.equal(init.redirect,"manual");
 assert.equal(init.headers["X-Rendprop-Media-Gateway"],"d".repeat(64));authReads++;
 const privateRead=url.pathname.endsWith("/private-media"),bytes=privateRead?JSON.parse(init.body).bytes:Number(url.searchParams.get("bytes")??0);charged.push(bytes);
 if(!privateRead&&bytes>0)assert.equal(url.searchParams.get("key"),key,"Public byte admission binds the exact selected object");
 if(!allowed)return new Response(null,{status:404});
 const objects={[key]:"renders"},metadata=limit();
 if(metadataFault==="mismatch")metadata.bytes--;
 if(metadataFault==="extra")metadata.client_unlimited=true;
 if(metadataFault==="changed"&&authReads>1)metadata.sha256="b".repeat(64);
 if(metadataFault==="bucket")objects[key]="uploads";
 const object_limits=metadataFault==="unmapped"?{"renders/unselected.mp4":metadata}:{[key]:metadata};
 return Response.json({schema:1,slug:privateRead?"private":slug,objects,stream_uid:null,...(limits?{object_limits}:{})});
};
const publicURL=`https://rendprop.com/media/${slug}/r2/${encodeURIComponent(key)}`,privateURL="https://rendprop.com/private-media/fixture."+"a".repeat(64);
const call=(method="GET",headers={},url=publicURL)=>handleMediaDelivery(new Request(url,{method,headers}),env);
let checks=0;const equal=(a,b)=>{assert.deepEqual(a,b);checks++;};
let r=await call("HEAD");equal(r.status,200);equal(r.headers.get("Content-Length"),String(size));equal(gets,0);
r=await call("GET",{Range:"bytes=0-31"});equal(r.status,206);equal((await r.arrayBuffer()).byteLength,32);equal(charged.slice(-4),[0,0,32,0]);
// Consume >256MiB incrementally; no fixture or Worker buffers the full master.
const oldReads=reads;r=await call();equal(r.status,200);const reader=r.body.getReader();let received=0,maxChunk=0;
while(true){const p=await reader.read();if(p.done)break;received+=p.value.byteLength;maxChunk=Math.max(maxChunk,p.value.byteLength);}
equal(received,size);equal(maxChunk,65536);assert(reads-oldReads>4096);checks++;equal(charged.slice(-4),[0,0,size,0]);
size=MAX;r=await call("HEAD",{},privateURL);equal(r.status,200);equal(r.headers.get("Content-Length"),String(MAX));
r=await call("GET",{Range:`bytes=${MAX-16}-${MAX-1}`},privateURL);equal(r.status,206);equal((await r.arrayBuffer()).byteLength,16);equal(charged.slice(-4),[0,0,16,0]);
size=MAX+1;const beforeGet=gets;r=await call("HEAD");equal(r.status,503);equal(gets,beforeGet);
size=ordinary+1;limits=false;r=await call("HEAD");equal(r.status,503);equal(gets,beforeGet);
// A matching name/private cap does not grant a bigger limit without authority.
r=await call("GET",{Range:"bytes=0-1"},privateURL);equal(r.status,503);equal(gets,beforeGet);limits=true;
for(const f of ["mismatch","extra","bucket","unmapped"]){metadataFault=f;r=await call("HEAD");equal(r.status,503);equal(gets,beforeGet);}metadataFault=null;
metadataFault="changed";authReads=0;r=await call("HEAD");equal(r.status,404);equal(gets,beforeGet);metadataFault=null;
allowed=false;const priorHeads=heads;
for(const url of [publicURL,privateURL])for(const method of ["GET","HEAD"])for(const h of [{Range:"bytes=0-15"},{"If-None-Match":'"immutable"'}]){r=await call(method,h,url);equal(r.status,404);equal(heads,priorHeads);equal(gets,beforeGet);}allowed=true;

const realSet=setTimeout,realClear=clearTimeout;
let now=0,sequence=0;const timers=new Map();
globalThis.setTimeout=(fn,delay)=>{const id=++sequence;timers.set(id,{at:now+delay,fn});return id;};globalThis.clearTimeout=id=>timers.delete(id);
const flush=async()=>{for(let i=0;i<10;i++)await Promise.resolve();};
async function advance(ms){const end=now+ms;while(true){const due=[...timers].filter(([,v])=>v.at<=end).sort((a,b)=>a[1].at-b[1].at)[0];if(!due)break;now=due[1].at;timers.delete(due[0]);due[1].fn();await flush();}now=end;await flush();}
function resetClock(){assert.equal(timers.size,0);now=0;}
try{
 // The larger total budget permits an actively progressing download past60s.
 size=3;let source;streamFactory=()=>new ReadableStream({start(c){source=c;},cancel(){cancelled++;}});
 resetClock();r=await call();const rr=r.body.getReader();let pending=rr.read();await flush();equal([...timers.values()].some(v=>v.at===1800000),true);
 for(let i=0;i<3;i++){await advance(45000);source.enqueue(new Uint8Array([i]));equal((await pending).value.byteLength,1);if(i<2)pending=rr.read();}
 source.close();equal((await rr.read()).done,true);await flush();equal(now,135000);equal(timers.size,0);
 // A stalled pending storage read is cancelled after60s, never clean success.
 resetClock();r=await call();const stalled=r.body.getReader().read();const rejected=assert.rejects(stalled,/no progress/);await flush();const cancels=cancelled;await advance(60000);await rejected;checks++;equal(cancelled,cancels+1);equal(timers.size,0);
 // Progress resets idle but never extends the fixed30minute overall deadline.
 resetClock();size=100;r=await call();const bounded=r.body.getReader();pending=bounded.read();await flush();
 for(let i=0;i<39;i++){await advance(45000);source.enqueue(new Uint8Array([1]));await pending;pending=bounded.read();await flush();}
 const deadlineReject=assert.rejects(pending,/deadline/);await advance(45000);await deadlineReject;checks++;equal(now,1800000);equal(timers.size,0);
 // Existing ordinary objects retain their60second total ceiling.
 resetClock();limits=false;size=100;r=await call();const regular=r.body.getReader().read();const regularReject=assert.rejects(regular,/deadline/);await flush();await advance(60000);await regularReject;checks++;equal(timers.size,0);
}finally{globalThis.setTimeout=realSet;globalThis.clearTimeout=realClear;streamFactory=null;}
console.log(JSON.stringify({success:true,checks,incrementalBytes:ordinary+1,maxMasterBytes:MAX,ordinaryMaxBytes:ordinary,largeOverallMs:1800000,idleMs:60000,actualWorker:true,hosted:false}));
