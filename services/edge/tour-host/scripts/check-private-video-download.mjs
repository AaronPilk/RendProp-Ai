import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";
import {buildSrc} from "./build-src.mjs";

const load=buildSrc("private-video-download-check"),{handleMediaDelivery}=await load("media-delivery"),worker=(await load("index")).default;
const video=readFileSync(resolve(import.meta.dirname,"../../../../apps/ios/tests/fixtures/clip-frames-known-good.mp4"));
const key="renders/10000000-0000-4000-8000-000000000001/20000000-0000-4000-8000-000000000002/finished.mp4";
const token="fixture."+"a".repeat(64);
const inline=`https://rendprop.com/private-media/${token}`;
const download=`https://rendprop.com/private-media-download/${token}`;
let allowed=true,selectedKey=key,contentType="video/mp4",reads=0,heads=0,gets=0;
const admissions=[];
const bucket={
 async head(requested){heads++;assert.equal(requested,selectedKey);return{size:video.length,etag:"fixture",httpEtag:'"fixture"',uploaded:new Date("2026-10-27T12:00:00Z"),writeHttpMetadata(h){h.set("Content-Type",contentType);}};},
 async get(requested,options){gets++;assert.equal(requested,selectedKey);assert.deepEqual(options.onlyIf,{etagMatches:"fixture"});const body=options.range?video.subarray(options.range.offset,options.range.offset+options.range.length):video;return{body:new ReadableStream({start(c){c.enqueue(body);c.close();}})};},
};
const env={SUPABASE_FUNCTIONS_URL:"https://api.fixture.invalid/functions/v1",SUPABASE_ANON_KEY:"public-fixture",MEDIA_GATEWAY_SECRET:"d".repeat(64),MEDIA_RENDERS:bucket,MEDIA_UPLOADS:bucket};
globalThis.fetch=async(raw,init)=>{
 const url=new URL(raw);assert.equal(url.href,"https://api.fixture.invalid/functions/v1/tours/private-media");
 assert.equal(init.method,"POST");assert.equal(init.cache,"no-store");assert.equal(init.redirect,"manual");
 const body=JSON.parse(init.body);assert.deepEqual(Object.keys(body).sort(),["bytes","cap"]);assert.equal(body.cap,token);admissions.push(body.bytes);reads++;
 return allowed?Response.json({schema:1,slug:"private",objects:{[selectedKey]:selectedKey.startsWith("uploads/")?"uploads":"renders"},stream_uid:null}):new Response(null,{status:404});
};
const call=(url,method="GET",headers={})=>handleMediaDelivery(new Request(url,{method,headers}),env);
let checks=0;const equal=(actual,expected)=>{assert.deepEqual(actual,expected);checks++;};
let response=await call(inline);equal(response.status,200);equal(response.headers.get("Content-Disposition"),null);equal(response.headers.get("Content-Type"),"video/mp4");equal(Buffer.from(await response.arrayBuffer()),video);
response=await call(download);equal(response.status,200);equal(response.headers.get("Content-Disposition"),'attachment; filename="Rendprop-listing-video.mp4"');equal(response.headers.get("Content-Type"),"video/mp4");equal(Buffer.from(await response.arrayBuffer()),video);equal(admissions.slice(-4),[0,0,video.length,0]);
response=await call(download,"HEAD");equal(response.status,200);equal(response.headers.get("Content-Disposition"),'attachment; filename="Rendprop-listing-video.mp4"');equal(gets,2);
response=await call(download,"GET",{Range:"bytes=0-31"});equal(response.status,206);equal(Buffer.from(await response.arrayBuffer()),video.subarray(0,32));equal(admissions.slice(-4),[0,0,32,0]);
const before=heads;allowed=false;
for(const method of ["GET","HEAD"])for(const headers of [{},{"If-None-Match":'"fixture"'},{Range:"bytes=0-31"}])equal((await call(download,method,headers)).status,404);
equal(heads,before);allowed=true;
contentType="image/jpeg";equal((await call(download)).status,404);contentType="video/mp4";
selectedKey="uploads/10000000-0000-4000-8000-000000000001/unrelated.mp4";equal((await call(download)).status,404);
selectedKey="renders/10000000-0000-4000-8000-000000000001/unrelated.jpg";equal((await call(download)).status,404);
selectedKey=key;
equal((await call(download+"?key=other")).status,404);
response=await worker.fetch(new Request(download),env,{});equal(response.status,200);equal(response.headers.get("Content-Disposition"),'attachment; filename="Rendprop-listing-video.mp4"');equal(Buffer.from(await response.arrayBuffer()),video);
assert(reads>10);console.log(JSON.stringify({success:true,checks,authorityReads:reads,heads,gets,actualWorkerHandler:true,live:false}));
