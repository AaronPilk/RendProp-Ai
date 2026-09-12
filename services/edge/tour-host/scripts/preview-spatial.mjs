// Loopback-only synthetic fixtures routed through the real emitted Worker.
// No transpileModule, alternate page renderer, or browser-source substitution.
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { checkSpatialBrowser } from './build-spatial-browser.mjs';
import { sha, boundedFile, sourceSnapshot, emitWorker, loadEmittedWorker, browserAsset } from './spatial-built-fixture.mjs';

const ROOT=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const [fixturePath,enginePath,videoPath]=process.argv.slice(2);
assert.equal(process.argv.length,5,'Provide synthetic SOG, pinned engine file and synthetic video');
assert.ok(fixturePath?.endsWith('/SYNTHETIC-NOT-A-ROOM.sog'),'Only explicitly named synthetic fixture allowed');
assert.ok(videoPath?.endsWith('/SYNTHETIC-NOT-A-TOUR.mp4'),'Synthetic test-pattern video is required');
const model=boundedFile(fixturePath,32*1024*1024),engine=boundedFile(enginePath),video=boundedFile(videoPath,2*1024*1024);
assert.equal(createHash('sha384').update(engine).digest('base64'),'2sYsYZfrbYhDV41s7X2ecMMRNZ8xTYBbSZcu3t9x0fpAFoqDtCQVeQtiq+mx0Fwz');
const inputs=sourceSnapshot(ROOT),canonical=await checkSpatialBrowser({root:ROOT});
const evidence=mkdtempSync(join(tmpdir(),'rendprop-spatial-preview-'));
const built=emitWorker(ROOT,evidence);
const id='11111111-1111-4111-8111-111111111111',revision='22222222-2222-4222-8222-222222222222';
const manifest={schema_version:1,scene_id:id,artifact_revision:revision,format:'sog',bytes:model.length,sha256:sha(model),gaussian_count:2048,
  bounds:{min:[-5,-2,-5],max:[5,4,5]},floor_y:-1.6,eye_height:1.6,floor_source:'capture_estimate',navigation_bounds_source:'capture_estimate',
  initial_camera:{position:[0,0,3],target:[0,0,0]},rooms:[{id:'synthetic',label:'Synthetic test',position:[1,0,3],target:[0,0,0]}],provenance:'synthetic',privacy_reviewed:true};
const tour={slug:'synthetic-tour',space_type:'real_estate',listing:{address:'Synthetic test — not a property',tagline:'Synthetic fixture',
  beds:0,baths:0,sqft:0,price_cents:0,price:null,lat:null,lng:null,details:{}},
  scrub_url:'/synthetic-video.mp4',video_url:null,hls_url:null,poster:null,duration_s:8,speed_factor:1,
  chapters:[{label:'Synthetic test',sort:0,t_ms:0,spatial_anchor:{scene_id:id,room_id:'synthetic'}},{label:'Second test segment',sort:1,t_ms:4000}],
  agent_card:{},cta:{label:'',mode:'lead_form',url:null,secondary:[],lead_fields:[]},staged:false,staged_disclosure:null,
  disclosure_chip:null,floorplan_url:null,gallery:[]};
const upstream='https://spatial-preview.invalid/functions/v1';
const worker=await loadEmittedWorker(built.path,async(input)=>{
  const url=String(input);
  if(url===upstream+'/tours/synthetic-tour')return Response.json(tour);
  if(url===upstream+'/spatial/'+id+'/manifest')return Response.json(manifest);
  assert.equal(url,upstream+'/spatial/'+id+'/model?revision='+revision,'Unexpected external request');
  return new Response(model,{headers:{'Content-Type':'application/octet-stream','Content-Length':String(model.length)}});
});
const asset=await browserAsset(worker);
assert.equal(asset.sha256,canonical.metadata.browser_sha256,'Preview must serve reviewed generated browser bytes');
assert.deepEqual(sourceSnapshot(ROOT),inputs,'Source changed while preparing preview');
const proof={kind:'actual-emitted-worker-synthetic-preview',built,browser_sha256:asset.sha256,inputs,
  model_sha256:sha(model),engine_sha256:sha(engine),video_sha256:sha(video),synthetic:true};
writeFileSync(join(evidence,'receipt.json'),JSON.stringify(proof,null,2)+'\n');
const server=createServer(async(req,res)=>{
  try{
    const url=new URL(req.url,'http://127.0.0.1:8794');
    if(req.method!=='GET'&&req.method!=='HEAD') {res.writeHead(405);res.end();return;}
    let result;
    if(url.pathname==='/__spatial-proof')result=Response.json(proof);
    // Chromium intercepts the unchanged CDN URL and obtains these SRI-identical
    // local fixture bytes. The shipped browser module itself is not rewritten.
    else if(url.pathname==='/vendor/playcanvas.min.js')result=new Response(engine,{headers:{'Content-Type':'text/javascript'}});
    else if(url.pathname==='/synthetic-video.mp4')result=new Response(video,{headers:{'Content-Type':'video/mp4','Content-Length':String(video.length)}});
    else{
      const path=url.pathname==='/synthetic-tour'?'/u/synthetic-tour':url.pathname+url.search;
      result=await worker.fetch(new Request('http://127.0.0.1:8794'+path,{method:req.method,headers:req.headers}),{SUPABASE_FUNCTIONS_URL:upstream});
      if(path==='/spatial-viewer.js'&&req.method==='GET'){
        const bytes=Buffer.from(await result.arrayBuffer());assert.equal(sha(bytes),asset.sha256,'Emitted module drift');
        result=new Response(bytes,result);
      }
    }
    res.writeHead(result.status,Object.fromEntries(result.headers));res.end(req.method==='HEAD'?undefined:Buffer.from(await result.arrayBuffer()));
  }catch(error){res.writeHead(500);res.end('Preview failed');console.error(error.message);}
});
server.listen(8794,'127.0.0.1',()=>console.log(JSON.stringify({url:'http://127.0.0.1:8794/s/'+id,evidence,
  browser_sha256:asset.sha256,worker_sha256:built.sha256,note:'Prepared only; no browser assertions executed yet'})));
