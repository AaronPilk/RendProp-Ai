import assert from "node:assert/strict";
import {buildSrc} from "./build-src.mjs";
const load=buildSrc("media-delivery-check"),{handleMediaDelivery}=process.env.MEDIA_MUTATION_MODULE?await import(process.env.MEDIA_MUTATION_MODULE):await load("media-delivery");
const key="renders/10000000-0000-4000-8000-000000000001/20000000-0000-4000-8000-000000000002/gallery-selected.jpg",slug="fixture-tour",uid="a".repeat(32),body=Buffer.from("selected media bytes");
const brandOrg="10000000-0000-4000-8000-000000000001",brandKey=`renders/${brandOrg}/brand/30000000-0000-4000-8000-000000000003.png`;
let allowed=true,authReads=0,storageReads=0,streamReads=0,fixtureFault=null;
const bucket={head:async k=>{storageReads++;if(fixtureFault==="revoke-head")allowed=false;assert([key,brandKey].includes(k));return {key,size:body.length,etag:"fixture",httpEtag:'"fixture"',uploaded:new Date("2026-10-06T10:00:00Z"),writeHttpMetadata:h=>{h.set("Content-Type","image/jpeg");h.set("Cache-Control","public,max-age=31536000");}};},get:async(k,opt)=>{storageReads++;if(fixtureFault==="revoke-get")allowed=false;assert([key,brandKey].includes(k));assert.deepEqual(opt.onlyIf,{etagMatches:"fixture"});return{body:new ReadableStream({start(c){c.enqueue(opt.range?body.subarray(opt.range.offset,opt.range.offset+opt.range.length):body);c.close();}})};}};
const env={SUPABASE_FUNCTIONS_URL:"https://api.fixture.invalid/functions/v1",SUPABASE_ANON_KEY:"public-fixture",MEDIA_RENDERS:bucket,MEDIA_UPLOADS:bucket,CLOUDFLARE_ACCOUNT_ID:"b".repeat(32),CLOUDFLARE_STREAM_TOKEN:"private-fixture-secret",CLOUDFLARE_STREAM_CUSTOMER_CODE:"fixture",STREAM_PRIVATE_PLAYBACK:"1"};
globalThis.fetch=async(raw,init)=>{
 const url=new URL(raw);
 if(url.hostname==="api.fixture.invalid"){
  authReads++;const brand=url.pathname===`/functions/v1/tours/business-logo/${brandOrg}`;if(brand)assert.equal(url.searchParams.get("key"),brandKey);else assert.equal(url.pathname,`/functions/v1/tours/${slug}/delivery`);assert.equal(init.cf.cacheTtl,0);assert.equal(init.redirect,"manual");
  if(fixtureFault==="outage")return new Response(null,{status:503});
  if(!allowed)return new Response(null,{status:404});
  if(brand)return Response.json({schema:1,slug:brandOrg,objects:{[brandKey]:"renders"},stream_uid:null});
  return Response.json(fixtureFault==="malformed"?{schema:1,slug,objects:{[key]:"secret-bucket"},stream_uid:uid}:{schema:1,slug,objects:{[key]:"renders"},stream_uid:uid});
 }
 if(url.hostname==="api.cloudflare.com"){streamReads++;assert.equal(init.headers.Authorization,"Bearer private-fixture-secret");assert.equal(init.method,"POST");assert(JSON.parse(init.body).exp<=Math.floor(Date.now()/1000)+60);return Response.json({success:true,result:{token:"internal.private.token"}});}
 if(url.hostname==="customer-fixture.cloudflarestream.com"){
  streamReads++;assert.equal(init.redirect,"error");assert.equal(init.cf.cacheTtl,0);
  if(url.pathname.endsWith("video.m3u8"))return new Response(fixtureFault==="external-manifest"?'#EXTM3U\nhttps://attacker.invalid/media.ts':'#EXTM3U\n#EXT-X-MAP:URI="../init.mp4"\n../segment.ts',{headers:{"Content-Type":"application/vnd.apple.mpegurl"}});
  return new Response("protected segment",{headers:{"Content-Type":"video/mp2t"}});
 }
 throw Error("Unexpected network destination");
};
const url=`https://rendprop.com/media/${slug}/r2/${encodeURIComponent(key)}`;
const call=(method="GET",headers={},target=url)=>handleMediaDelivery(new Request(target,{method,headers}),env);
let checks=0;function equal(a,b){assert.deepEqual(a,b);checks++;}
let response=await call();equal(response.status,200);equal(await response.text(),body.toString());equal(response.headers.get("Cache-Control"),"no-store, max-age=0");equal(response.headers.get("CDN-Cache-Control"),"no-store");equal(response.headers.get("Accept-Ranges"),"bytes");
response=await call("HEAD");equal(response.status,200);equal(await response.text(),"");equal(response.headers.get("Content-Length"),String(body.length));
response=await call("GET",{Range:"bytes=3-7"});equal(response.status,206);equal(await response.text(),body.subarray(3,8).toString());equal(response.headers.get("Content-Range"),`bytes 3-7/${body.length}`);
response=await call("GET",{Range:"bytes=-5"});equal(response.status,206);equal(await response.text(),body.subarray(-5).toString());
response=await call("GET",{Range:"bytes=999-"});equal(response.status,416);
response=await call("GET",{Range:"bytes=1-2,4-5"});equal(response.status,416);
response=await call("GET",{"If-None-Match":'"fixture"'});equal(response.status,304);equal(await response.text(),"");
response=await call("GET",{"If-Match":'"wrong"'});equal(response.status,412);equal(response.headers.get("Content-Length"),"0");
response=await call("GET",{Range:"bytes=3-7","If-Range":'"wrong"'});equal(response.status,200);equal(await response.text(),body.toString());
response=await call("GET",{"If-Match":'W/"fixture"'});equal(response.status,412);
response=await call("GET",{"If-Unmodified-Since":"Mon, 05 Oct 2026 10:00:00 GMT"});equal(response.status,412);equal(response.headers.get("Content-Length"),"0");
fixtureFault="revoke-head";response=await call("HEAD");equal(response.status,404);equal(await response.text(),"");allowed=true;fixtureFault="revoke-get";response=await call();equal(response.status,404);equal(await response.text(),"");allowed=true;fixtureFault=null;
const before=storageReads;response=await call("GET",{},url.replace("gallery-selected.jpg","gallery-unselected.jpg"));equal(response.status,404);equal(storageReads,before);
fixtureFault="outage";response=await call();equal(response.status,503);equal(storageReads,before);fixtureFault="malformed";equal((await call()).status,503);equal(storageReads,before);fixtureFault=null;
allowed=false;
for(const method of ["GET","HEAD"])for(const h of [{},{Range:"bytes=0-1"},{"If-None-Match":'"fixture"'},{"If-Match":'"fixture"'},{"If-Modified-Since":"Tue, 06 Oct 2026 10:00:00 GMT"}]){response=await call(method,h);equal(response.status,404);equal(await response.text(),"");equal(storageReads,before);}
allowed=true;
const streamURL=`https://rendprop.com/media/${slug}/stream/${uid}/manifest%2Fvideo.m3u8`;
response=await call("GET",{},streamURL);equal(response.status,200);const manifest=await response.text();assert(!manifest.includes("internal.private.token")&&!manifest.includes("cloudflarestream.com"));checks++;
equal(manifest,'#EXTM3U\n#EXT-X-MAP:URI="/media/fixture-tour/stream/'+uid+'/init.mp4"\n/media/fixture-tour/stream/'+uid+'/segment.ts');
response=await call("GET",{},`https://rendprop.com/media/${slug}/stream/${uid}/segment.ts`);equal(response.status,200);equal(await response.text(),"protected segment");
const streamsBefore=streamReads;allowed=false;response=await call("GET",{Range:"bytes=0-1"},`https://rendprop.com/media/${slug}/stream/${uid}/segment.ts`);equal(response.status,404);equal(streamReads,streamsBefore);
allowed=true;fixtureFault="external-manifest";equal((await call("GET",{},streamURL)).status,503);fixtureFault=null;
for(const target of [url+"?token=x",url.replace(encodeURIComponent(key),"renders%2F..%2Fsecret"),streamURL.replace(uid,"c".repeat(32)),streamURL.replace("manifest%2Fvideo.m3u8","..%2Fsecret")])equal((await call("GET",{},target)).status,404);
const brandURL=`https://rendprop.com/media-brand/${brandKey}`;equal((await call("GET",{},brandURL)).status,200);allowed=false;equal((await call("HEAD",{"If-None-Match":'"fixture"'},brandURL)).status,404);allowed=true;
assert(authReads>20);console.log(JSON.stringify({success:true,checks,authReads,storageReads,streamReads,source:"actual Worker media-delivery.ts",live:false}));
