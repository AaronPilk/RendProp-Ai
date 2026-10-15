import assert from 'node:assert/strict';
import {mkdtempSync,readFileSync,writeFileSync,rmSync}from'node:fs';
import {tmpdir}from'node:os';
import {join,resolve}from'node:path';
import {fileURLToPath}from'node:url';
import {build}from'esbuild';
import {Miniflare,convertV4MiniflareOptions}from'miniflare';
import sharp from'sharp';
const ROOT=resolve(fileURLToPath(import.meta.url),'../..'),temp=mkdtempSync(join(tmpdir(),'rendprop-thumb-runtime-'));
const key='renders/10000000-0000-4000-8000-000000000001/20000000-0000-4000-8000-000000000002/gallery-fixture.jpg',slug='runtime-thumb';let allowed=true,requests=0;const admissions=[];
const built=await build({stdin:{contents:'import{handleMediaDelivery}from'+JSON.stringify(join(ROOT,'src/media-delivery.ts'))+';export default{fetch(req,env){return handleMediaDelivery(req,env)}};',resolveDir:ROOT,sourcefile:'thumbnail-runtime.ts',loader:'ts'},bundle:true,format:'esm',platform:'browser',target:'es2022',write:false});writeFileSync(join(temp,'worker.mjs'),built.outputFiles[0].contents);
const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:"thumb-runtime",modules:true,script:built.outputFiles[0].text,compatibilityDate:'2026-09-07',r2Buckets:['MEDIA_RENDERS','MEDIA_UPLOADS'],images:{binding:'IMAGES'},bindings:{SUPABASE_FUNCTIONS_URL:'https://authority.fixture.invalid',SUPABASE_ANON_KEY:'public-fixture',MEDIA_GATEWAY_SECRET:'d'.repeat(64)},outboundService:async req=>{requests++;const u=new URL(req.url);assert.equal(u.origin,'https://authority.fixture.invalid');assert.equal(u.pathname,`/tours/${slug}/photo-delivery`);assert.deepEqual(u.searchParams.getAll('key'),[key]);admissions.push(Number(u.searchParams.get('bytes')||0));return allowed?Response.json({schema:1,slug,objects:{[key]:'renders'},stream_uid:null}):new Response(null,{status:404});}}]}));
try{
 const bucket=await mf.getR2Bucket('MEDIA_RENDERS'),results=[];
 for(const [width,height,orientation]of[[2400,2400,1]]){
  let source=sharp({create:{width,height,channels:3,background:'#b5a38d'}}).jpeg({quality:97});if(orientation!==1)source=source.withMetadata({orientation});const bytes=await source.toBuffer();await bucket.put(key,bytes,{httpMetadata:{contentType:'image/jpeg'}});
  const response=await mf.dispatchFetch(`https://rendprop.com/media/${slug}/thumb/${encodeURIComponent(key)}`);assert.equal(response.status,200,await response.clone().text());const preview=Buffer.from(await response.arrayBuffer()),metadata=await sharp(preview).metadata();
  assert.equal(metadata.format,'jpeg');assert(metadata.width<=1280&&metadata.height<=1280);assert(metadata.width<=Math.max(width,height)&&metadata.height<=Math.max(width,height));
  const original=Buffer.from(await(await bucket.get(key)).arrayBuffer());assert.deepEqual(original,bytes,'Master bytes unchanged');
  const ratio=orientation===6?height/width:width/height;assert(Math.abs(metadata.width/metadata.height-ratio)<.004,'Preserve full frame aspect and EXIF orientation');
  assert(metadata.width<=Math.min(1280,orientation===6?height:width)&&metadata.height<=Math.min(1280,orientation===6?width:height),'No preview upscaling');
  results.push({source:[width,height],orientation,sourceBytes:bytes.length,preview:[metadata.width,metadata.height],previewBytes:preview.length,masterExact:true});
 }
 allowed=false;assert.equal((await mf.dispatchFetch(`https://rendprop.com/media/${slug}/thumb/${encodeURIComponent(key)}`)).status,404,'Fresh publication denies cached pixels');
 console.log(JSON.stringify({passed:true,scope:'Actual workerd/R2/Cache/Images offline binding and JPEG decode on square source; no external network/provider usage. Offline fit/quality/EXIF unsupported; full-frame geometry and q82 tested separately, hosted readback still required.',requests,admissions,results}));
}finally{await mf.dispose();rmSync(temp,{recursive:true,force:true});}
