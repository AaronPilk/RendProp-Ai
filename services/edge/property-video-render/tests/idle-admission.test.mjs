import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createRequire} from 'node:module';

const directory=await mkdtemp(path.join(tmpdir(),'rendprop-idle-admission-'));
const savedFetch=globalThis.fetch;
try {
  const target=path.join(directory,'controller.cjs');
  await build({entryPoints:['src/index.ts'],bundle:true,format:'cjs',platform:'node',outfile:target,
    alias:{'cloudflare:workers':path.resolve('tests/cloudflare-stub.ts')}});
  const {PropertyVideoCPU,default:worker}=createRequire(import.meta.url)(target);
  const video='00000000-0000-4000-8000-000000000001',photo='00000000-0000-4000-8000-000000000002';
  const env={ENABLED:'true',EDGE_WORKER_URL:'https://authority.test.supabase.co/functions/v1/property-video-worker',
    EDGE_SERVICE_ROLE_KEY:'fixture-service',MEDIA_HOSTS:'owned.example'};
  let data=null,alarm=null,cpuTouches=0,status=200,calls=[];
  const sql={exec(query,...args){
    if(query.startsWith('CREATE')||query.includes('diagnostic'))return{toArray:()=>[]};
    if(query.startsWith('SELECT'))return{toArray:()=>data?[{state:data}]:[]};
    if(query.startsWith('INSERT'))data=args[0];
    if(query.startsWith('DELETE'))data=null;
    return{toArray:()=>[]};
  }};
  const ctx={storage:{sql,async setAlarm(value){alarm=value;},async deleteAlarm(){alarm=null;}},
    container:{running:false,async destroy(){cpuTouches++;},async setInactivityTimeout(){cpuTouches++;}}};
  globalThis.fetch=async(url,init)=>{
    calls.push(new URL(url).pathname);const body=JSON.parse(init.body);
    return Response.json('check_id'in body?{action:'wait',check_id:photo}:{action:'wait',job_id:video},{status});
  };
  for(const domain of ['video','photo']){
    const cpu=new PropertyVideoCPU(ctx,env);status=503;calls=[];
    assert.equal(domain==='video'?await cpu.wake(video,'slot-0'):await cpu.wakePhoto(photo,'slot-0'),true);
    const admitted=data;
    await cpu.alarm();assert.equal(data,admitted,'unknown bridge outcome retains local identity');assert.ok(alarm);
    status=200;await cpu.alarm();assert.equal(data,null,'acknowledged idle job releases CPU atom');assert.equal(alarm,null);
    assert.equal(cpuTouches,0,'provider wait neither starts nor touches a CPU');
    assert.equal(calls.length,2);assert.ok(calls.every(url=>url.endsWith('/tick')),'no generation/funding/callback manufactured');
    const other=domain==='video'?await cpu.wakePhoto(photo,'slot-0'):await cpu.wake(video,'slot-0');
    assert.equal(other,true,'other workload can immediately use released atom');
    env.ENABLED='false';await cpu.alarm();env.ENABLED='true';assert.equal(data,null);
    // A crash after persisting a CPU action but before saving its task ID is
    // uncertain local work, rather than a proven empty supplier wait.
    data=JSON.stringify(domain==='video'?{jobID:video,slot:'slot-0',token:'fixture',task:{action:'compose'}}:
      {kind:'photo_quality',checkID:photo,slot:'slot-0',token:'fixture',task:{action:'prepare_photo_quality'}});
    const incomplete=data;await cpu.alarm();assert.equal(data,incomplete);assert.ok(alarm);
    env.ENABLED='false';await cpu.alarm();env.ENABLED='true';
  }
  // The real scheduled handler deterministically offers both queues a first
  // turn. A faster provider-queue HTTP response cannot win every cron race.
  for(const [minute,expected] of [[0,'video'],[1,'photo'],[2,'video'],[3,'photo']]){
    let occupant=null,pending;const trace=[];
    globalThis.fetch=async(url)=>{
      const domain=new URL(url).pathname.includes('photo-quality-worker')?'photo':'video';trace.push(domain);
      return Response.json(domain==='photo'?{enabled:true,checks:[{check_id:photo}]}:{enabled:true,jobs:[{job_id:video}]});
    };
    const config={...env,CPU:{getByName(){return{
      async wake(){if(occupant)return false;occupant='video';return true;},
      async wakePhoto(){if(occupant)return false;occupant='photo';return true;},
    };}}};
    await worker.scheduled({scheduledTime:minute*60_000},config,{waitUntil(value){pending=value;}});await pending;
    assert.equal(occupant,expected);assert.deepEqual(trace,expected==='photo'?['photo','video']:['video','photo']);
  }
  console.log('Actual controller: idle waits release atoms; unknown/partial CPU state persists; alternating queue admission passes.');
} finally {globalThis.fetch=savedFetch;await rm(directory,{recursive:true,force:true});}
