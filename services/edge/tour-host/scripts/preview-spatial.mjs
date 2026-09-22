// Loopback-only verification: explicit synthetic fixture, never customer media.
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import { buildSrc } from './build-src.mjs';
const [fixturePath, enginePath, videoPath] = process.argv.slice(2);
assert.ok(fixturePath?.endsWith('/SYNTHETIC-NOT-A-ROOM.sog'), 'Only explicitly named synthetic fixture allowed');
const model=readFileSync(fixturePath), engine=readFileSync(enginePath);
assert.ok(!videoPath || videoPath.endsWith('/SYNTHETIC-NOT-A-TOUR.mp4'));
const video=videoPath ? readFileSync(videoPath) : null;
assert.ok(!video || video.length < 2 * 1024 * 1024);
assert.equal(createHash('sha384').update(engine).digest('base64'),'2sYsYZfrbYhDV41s7X2ecMMRNZ8xTYBbSZcu3t9x0fpAFoqDtCQVeQtiq+mx0Fwz');
const load=buildSrc('spatial-browser-preview');
const {default:worker}=await load('index');
const {renderTourPage}=await load('player');
const {buildDemoTour}=await load('demo');
const id='11111111-1111-4111-8111-111111111111', revision='22222222-2222-4222-8222-222222222222';
const manifest={schema_version:1,scene_id:id,artifact_revision:revision,format:'sog',bytes:model.length,sha256:createHash('sha256').update(model).digest('hex'),gaussian_count:2048,bounds:{min:[-5,-2,-5],max:[5,4,5]},floor_y:-1.6,eye_height:1.6,floor_source:'capture_estimate',navigation_bounds_source:'capture_estimate',initial_camera:{position:[0,0,3],target:[0,0,0]},rooms:[{id:'synthetic',label:'Synthetic test',position:[1,0,3],target:[0,0,0]}],provenance:'synthetic',privacy_reviewed:true};
globalThis.fetch=async(url,options)=>{
  assert.ok(String(url).startsWith('https://spatial-preview.invalid/functions/v1/spatial/'+id+'/'), 'Unexpected external request');
  if(String(url).endsWith('/manifest')) return Response.json(manifest);
  assert.equal(String(url),'https://spatial-preview.invalid/functions/v1/spatial/'+id+'/model?revision='+revision);
  return new Response(model,{headers:{'Content-Type':'application/octet-stream','Content-Length':String(model.length)}});
};
const server=createServer(async(req,res)=>{
  try {
    const path=new URL(req.url,'http://127.0.0.1').pathname;
    let result;
    if(path==='/vendor/playcanvas.min.js') result=new Response(engine,{headers:{'Content-Type':'text/javascript'}});
    else if(path==='/synthetic-video.mp4' && video) result=new Response(video,{headers:{'Content-Type':'video/mp4','Content-Length':String(video.length)}});
    else if(path==='/synthetic-tour') {
      const tour=buildDemoTour(); tour.chapters[0].spatial_anchor={scene_id:id,room_id:'synthetic'};
      // Optional generated test-pattern MP4 proves real media detach/restore.
      // It is not a customer video or a physical-device codec compatibility run.
      tour.scrub_url=video?'/synthetic-video.mp4':null; tour.hls_url=null; tour.video_url=null; tour.poster=null;
      tour.duration_s=8; tour.chapters=[{label:'Synthetic test',sort:0,t_ms:0,spatial_anchor:{scene_id:id,room_id:'synthetic'}},{label:'Second test segment',sort:1,t_ms:4000}];
      tour.floorplan_url=null; tour.listing.details={}; tour.gallery=[];
      result=new Response(renderTourPage(tour,'https://spatial-preview.invalid/functions/v1','','',{unbranded:true}),{headers:{'Content-Type':'text/html'}});
    } else result=await worker.fetch(new Request('http://127.0.0.1:8794'+req.url,{headers:req.headers}),{SUPABASE_FUNCTIONS_URL:'https://spatial-preview.invalid/functions/v1'},{waitUntil(){}});
    if(path==='/spatial-viewer.js') result=new Response((await result.text()).replace('https://cdn.jsdelivr.net/npm/playcanvas@2.22.1/build/playcanvas.min.js','/vendor/playcanvas.min.js'),result);
    res.writeHead(result.status,Object.fromEntries(result.headers));res.end(Buffer.from(await result.arrayBuffer()));
  }catch(error){res.writeHead(500);res.end('Preview failed');console.error(error.message);}
});
server.listen(8794,'127.0.0.1',()=>console.log('Synthetic-only spatial preview http://127.0.0.1:8794/s/'+id));
