import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createRequire} from 'node:module';

const directory=await mkdtemp(path.join(tmpdir(),'rendprop-photo-scheduler-'));
const previousFetch=globalThis.fetch,previousWarn=console.warn;
try {
  const target=path.join(directory,'controller.cjs');
  await build({entryPoints:['src/index.ts'],bundle:true,platform:'node',format:'cjs',outfile:target,
    plugins:[{name:'inert-cloudflare',setup(api){api.onResolve({filter:/^cloudflare:workers$/},()=>({path:path.resolve('tests/cloudflare-stub.ts')}));}}]});
  const worker=createRequire(import.meta.url)(target).default;
  const id='00000000-0000-4000-8000-000000000001';
  const calls=[],offers=[],warnings=[];
  const binding=lane=>({getByName(name){return{
    async reconcileHeldOnly(){offers.push([lane,name,'reconcile']);return null;},
    async wake(jobID,slot){offers.push([lane,name,'wake',jobID,slot]);return true;},
    async wakePhoto(checkID,slot){offers.push([lane,name,'photo',checkID,slot]);return true;}
  };}});
  const env={ENABLED:'true',EDGE_WORKER_URL:'https://authority.test.supabase.co/functions/v1/property-video-worker',
    EDGE_SERVICE_ROLE_KEY:'fixture-service',MEDIA_HOSTS:'media.test',CPU:binding('AI'),PHOTO_MOTION_CPU:binding('PM'),
    CPU_PHOTO_MOTION_SLOT_NAME:'slot-0-fixture'};
  let videoQueue={enabled:true,jobs:[{job_id:id,source_mode:'photo_motion_v1'}]};
  let photoQueue={enabled:true,checks:[]};
  globalThis.fetch=async(url,init)=>{
    const pathname=new URL(url).pathname;
    calls.push([pathname,init.method]);
    assert.equal(init.headers.Authorization,'Bearer fixture-service');
    return Response.json(pathname.includes('photo-quality')?photoQueue:videoQueue);
  };
  console.warn=(...args)=>warnings.push(args);
  async function tick(minute=0){const pending=[];await worker.scheduled({scheduledTime:minute*60_000},env,{waitUntil(p){pending.push(p);}});
    assert.equal(pending.length,1);await Promise.all(pending);}

  await tick();
  assert.deepEqual(calls.map(x=>x[1]),['GET','GET']);
  assert.deepEqual(offers.find(x=>x[2]==='wake'),['PM','slot-0-fixture','wake',id,'slot-0']);
  assert.deepEqual(offers.find(x=>x[2]==='reconcile'),['PM','slot-0-fixture','reconcile']);
  assert.deepEqual(warnings,[]);

  calls.length=offers.length=warnings.length=0;
  const normalFetch=globalThis.fetch;
  let releasePhoto;
  const pendingPhoto=new Promise(resolve=>{releasePhoto=resolve;});
  globalThis.fetch=async(url,init)=>{
    const pathname=new URL(url).pathname;
    calls.push([pathname,init.method]);
    return pathname.includes('photo-quality')?pendingPhoto:Response.json(videoQueue);
  };
  const pending=[];
  await worker.scheduled({scheduledTime:60_000},env,{waitUntil(p){pending.push(p);}});
  for(let i=0;i<40;i++)await Promise.resolve();
  assert.equal(calls.length,2,'video queue must start while photo queue remains pending');
  assert.ok(offers.some(x=>x[2]==='wake'),'video wake must not wait for the photo queue');
  releasePhoto(Response.json(photoQueue));
  await Promise.all(pending);
  globalThis.fetch=normalFetch;

  calls.length=offers.length=warnings.length=0;
  delete env.CPU_PHOTO_MOTION_SLOT_NAME;
  await tick();
  assert.equal(calls.length,1,'missing private slot must refuse before the video queue request');
  assert.ok(calls[0][0].includes('photo-quality'),'independent quality queue still runs');
  assert.deepEqual(offers,[]);
  assert.equal(warnings.length,1);
  assert.equal(warnings[0][0],'property_video_dispatch_refused');
  assert.ok(!JSON.stringify(warnings).includes('slot-0-fixture'));

  calls.length=offers.length=warnings.length=0;
  env.ENABLED='false';
  await tick();
  assert.deepEqual(calls,[]);
  assert.deepEqual(offers,[]);
  assert.deepEqual(warnings,[]);
  console.log('Photo Motion scheduler: configured atom, missing-slot refusal and disabled no-op passed.');
} finally {
  globalThis.fetch=previousFetch;
  console.warn=previousWarn;
  await rm(directory,{recursive:true,force:true});
}
