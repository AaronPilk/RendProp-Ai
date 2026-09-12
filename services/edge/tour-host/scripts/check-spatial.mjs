import assert from 'node:assert/strict';
import { buildSrc } from './build-src.mjs';
const load = buildSrc('spatial-product-check');
const { decodeSpatialManifest, spatialAnchor } = await load('spatial-manifest');
const { spatialData, spatialPage, spatialModule } = await load('spatial');
const { inspectSpatialSog } = await load('spatial-sog');
const { renderTourPage, unbrandedSelfCheck } = await load('player');
const { buildDemoTour } = await load('demo');
const id = '11111111-1111-4111-8111-111111111111', revision = '22222222-2222-4222-8222-222222222222';
export const fixture = {schema_version:1,scene_id:id,artifact_revision:revision,format:'sog',bytes:4,sha256:'a'.repeat(64),gaussian_count:2048,bounds:{min:[-5,-2,-5],max:[5,4,5]},floor_y:-1.6,eye_height:1.6,floor_source:'capture_estimate',navigation_bounds_source:'capture_estimate',initial_camera:{position:[0,0,3],target:[0,0,0]},rooms:[{id:'kitchen',label:'Synthetic kitchen',position:[0,0,3],target:[0,0,0]}],provenance:'synthetic',privacy_reviewed:true};
let assertions = 0;
const check = (condition, message) => { assertions++; assert.ok(condition, message); };
// Envelope-only fixtures, deliberately not real image bitstreams. The separate
// Chromium harness must render an actual converted SOG; this cannot prove that.
const sogMeta = {version:2,count:2048,means:{files:['means_l.webp','means_u.webp']},quats:{files:['quats.webp']},scales:{files:['scales.webp']},sh0:{files:['sh0.webp']}};
function webp(width=64,height=32) {
  const b=Buffer.alloc(26); b.write('RIFF');b.writeUInt32LE(18,4);b.write('WEBPVP8L',8);b.writeUInt32LE(5,16);b[20]=0x2f;b.writeUInt32LE(((width-1)|((height-1)<<14))>>>0,21);return b;
}
function sogFiles(meta=sogMeta) {return [['meta.json',Buffer.from(JSON.stringify(meta))],...['means_l.webp','means_u.webp','quats.webp','scales.webp','sh0.webp'].map(name=>[name,webp()])];}
function storedZip(files) {
  const chunks=[],directory=[];let cursor=0;
  for(const [name,body] of files) {
    const n=Buffer.from(name), local=Buffer.alloc(30), central=Buffer.alloc(46);
    local.writeUInt32LE(0x04034b50);local.writeUInt32LE(body.length,18);local.writeUInt32LE(body.length,22);local.writeUInt16LE(n.length,26);
    central.writeUInt32LE(0x02014b50);central.writeUInt32LE(body.length,20);central.writeUInt32LE(body.length,24);central.writeUInt16LE(n.length,28);central.writeUInt32LE(cursor,42);
    chunks.push(local,n,body);directory.push(central,n);cursor+=30+n.length+body.length;
  }
  const central=Buffer.concat(directory),end=Buffer.alloc(22);end.writeUInt32LE(0x06054b50);end.writeUInt16LE(files.length,8);end.writeUInt16LE(files.length,10);end.writeUInt32LE(central.length,12);end.writeUInt32LE(cursor,16);
  return Buffer.concat([...chunks,central,end]);
}
check(inspectSpatialSog(storedZip(sogFiles()),2048).texturePixels===10240,'bounded stored SOG envelope accepted');
const rejectSog=(body,count=2048)=>{assertions++;assert.throws(()=>inspectSpatialSog(body,count));};
for(const count of [-1,0,2.5,500001,2049]) rejectSog(storedZip(sogFiles()),count);
for(const mutate of [
  files=>files.push(['other.webp',webp()]), files=>files.push(files[1]),files=>files[1][0]='../means_l.webp',
  files=>files[1][1]=webp(2049,1),files=>files.forEach((f,i)=>{if(i)f[1]=webp(2048,2048);}),
  files=>files[1][1][20]=0,files=>files[1][1].write('VP8X',12),files=>files[1][1].writeUInt32LE(0xe0000000,21),
  files=>files[0][1]=Buffer.alloc(131073,32),files=>files[1][1].writeUInt32LE(4,16),
]) {const files=sogFiles();mutate(files);rejectSog(storedZip(files));}
for(const mutate of [m=>m.version=1,m=>m.count=500001,m=>m.means.files[0]='https://outside.invalid/model.webp',m=>m.means.files[0]='quats.webp',m=>delete m.scales]) {
  const meta=structuredClone(sogMeta);mutate(meta);rejectSog(storedZip(sogFiles(meta)));
}
for(const mutate of [
  b=>b.writeUInt16LE(1,b.length-18),b=>b.writeUInt16LE(1,b.length-2),
  b=>b.writeUInt16LE(8,b.readUInt32LE(b.length-6)+10),b=>b.writeUInt16LE(8,8),
  b=>b.writeUInt32LE(0xffffffff,b.readUInt32LE(b.length-6)+42),b=>b.writeUInt32LE(0xffffffff,b.readUInt32LE(b.length-6)+20),
]) {const b=storedZip(sogFiles());mutate(b);rejectSog(b);}
rejectSog(new Uint8Array(21));
check(decodeSpatialManifest(fixture).rooms[0].id === 'kitchen', 'actual manifest accepted');
for (const change of [m=>m.bytes=33554433,m=>m.bytes=-1,m=>m.bytes=NaN,m=>m.gaussian_count=500001,m=>m.gaussian_count=2.5,m=>m.bounds.min=[0,0],m=>m.bounds.max=[Infinity,4,5],m=>m.bounds.max=[300,4,5],m=>m.floor_y=4,m=>m.eye_height=0,m=>m.initial_camera.position=[10,0,0],m=>m.initial_camera.target=[0,0,3],m=>m.rooms.push({...m.rooms[0]}),m=>m.rooms[0].label='x'.repeat(81),m=>m.scene_id='../a',m=>m.format='ply',m=>m.provenance='room',m=>m.privacy_reviewed='true',m=>m.floor_source='measured',m=>m.navigation_bounds_source='collision',m=>m.sha256='bad']) {
  const m=structuredClone(fixture); change(m); assertions++; assert.throws(()=>decodeSpatialManifest(m));
}
check(!('output_key' in decodeSpatialManifest({...fixture,output_key:'must-not-be-returned'})), 'unknown private fields not forwarded');
check(spatialAnchor({scene_id:id,room_id:'kitchen'}), 'anchor accepted');
check(!spatialAnchor({scene_id:'https://elsewhere',room_id:'kitchen'}), 'arbitrary source rejected');
check(!spatialAnchor({scene_id:id,room_id:'" onclick="x'}), 'attribute injection rejected');
const source=await spatialModule().text();
check(source.includes('sha384-2sYsYZfrb'), 'engine SRI pinned');
check(source.includes('playcanvas@2.22.1'), 'engine version pinned');
check(source.includes('crypto.subtle.digest'), 'artifact integrity check present');
check(source.includes('transfer.signal.addEventListener'), 'decode abort cannot retain pending load');
check(source.includes('app.destroy()'), 'context destroy implemented');
// Parse and import the complete ESM artifact, including its declared exports.
// Stripping a lexical declaration can accidentally hide missing dependencies.
const browserModule = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
check(typeof browserModule.mountSpatial === 'function' &&
  typeof browserModule.decodeSpatialManifest === 'function' &&
  typeof browserModule.inspectSpatialSog === 'function', 'browser exports load without Worker scope');
const page=await spatialPage(id).text();
check(page.includes('history.replaceState'), 'fragment credential removed');
check(!page.includes('access=') && !page.includes('output_key'), 'shell contains no artifact access credential');
const tour=buildDemoTour();
const original=renderTourPage(tour,'https://example.test','');
check(!original.includes('data-spatial-scene="'), 'no scan means no entry control');
tour.chapters[0].spatial_anchor={scene_id:id,room_id:'kitchen'};
tour.floorplan_url='/synthetic-floorplan.png';
for(const unbranded of [false,true]) {
  const html=renderTourPage(tour,'https://example.test','', '', {unbranded});
  check((html.match(/data-spatial-scene="/g)||[]).length >= 2, 'rail/room list offer entry');
  check(html.includes('video.removeAttribute'), 'video source detached before WebGL');
  check(html.includes('if (hlsJs){ hlsJs.destroy()'), 'HLS destroyed before WebGL');
  check(html.includes('window.scrollTo(saved.x, saved.y)'), 'scroll restored');
  check(html.includes('saved.time'), 'video time restored');
  if(unbranded) check(unbrandedSelfCheck(html,tour).length === 0, 'spatial controls preserve unbranded gate');
}
const env={SUPABASE_FUNCTIONS_URL:'https://spatial-upstream.invalid/functions/v1',SUPABASE_ANON_KEY:'synthetic-public-key'};
const request=(kind,auth)=>new Request('https://rendprop.com/s/'+id+'/'+kind+(kind==='model'?'?revision='+revision:''), {headers:auth?{Authorization:'Bearer synthetic.capability'}:{}});
const originalFetch=globalThis.fetch;
try {
  let calls=0;
  globalThis.fetch=async(url,options)=>{calls++; check(url===env.SUPABASE_FUNCTIONS_URL+'/spatial/'+id+'/manifest','exact upstream route'); check(options.headers.Authorization==='Bearer synthetic.capability','private cap forwarded'); check(options.redirect==='manual','no redirect credential leak');check(options.cf.cacheTtl===0,'upstream no cache');return Response.json({...fixture,privacy_reviewed:false});};
  let response=await spatialData(request('manifest',true),env,id,'manifest');
  check(response.status===200,'private unreviewed manifest allowed for review');check(response.headers.get('Cache-Control')==='no-store','private no cache');check(calls===1,'one authoritative lookup');
  globalThis.fetch=async()=>Response.json({...fixture,privacy_reviewed:false});
  response=await spatialData(request('manifest'),env,id,'manifest');check(response.status!==200,'unreviewed public manifest rejected');
  for(const status of [301,401,403,404,409,429,500]) {
    globalThis.fetch=async()=>new Response('must-not-leak',{status,headers:{Location:'https://foreign.invalid'}});
    response=await spatialData(request('manifest',true),env,id,'manifest');check(response.status!==200,'upstream failure closed '+status);check(!(await response.text()).includes('must-not-leak'),'raw failure not echoed');
  }
  globalThis.fetch=async()=>new Response(new Uint8Array(65537));
  check((await spatialData(request('manifest'),env,id,'manifest')).status!==200,'manifest bytes bounded');
  globalThis.fetch=async()=>new Response('1234',{headers:{'Content-Length':'4','Content-Type':'application/octet-stream'}});
  response=await spatialData(request('model',true),env,id,'model');check(response.status===200 && await response.text()==='1234','model stream delivered');
  for(const body of ['123','12345']) {
    globalThis.fetch=async()=>new Response(body,{headers:{'Content-Length':'4','Content-Type':'application/octet-stream'}});
    response=await spatialData(request('model',true),env,id,'model');assertions++;await assert.rejects(response.arrayBuffer(),'short/long body rejected');
  }
  globalThis.fetch=async()=>new Response('large',{headers:{'Content-Length':'33554433','Content-Type':'application/octet-stream'}});
  check((await spatialData(request('model',true),env,id,'model')).status!==200,'model header cap');
  globalThis.fetch=async()=>{throw new Error('unexpected real network request');};
  check((await spatialData(new Request('https://rendprop.com/s/'+id+'/model'),env,id,'model')).status===400,'missing revision rejected before network');
  const cancelled=new AbortController();cancelled.abort();
  check((await spatialData(new Request('https://rendprop.com/s/'+id+'/manifest',{signal:cancelled.signal}),env,id,'manifest')).status===503,'aborted request makes no upstream call');
} finally { globalThis.fetch=originalFetch; }
if(process.argv.includes('--negative-control')) { assertions++; assert.equal(decodeSpatialManifest({...fixture,bytes:33554433}).bytes,33554433,'deliberate oversized manifest must fail'); }
console.log('Spatial product: '+assertions+' assertions, 0 skipped; actual decoder/proxy/rendered HTML; synthetic fixtures, no room or production proof.');
