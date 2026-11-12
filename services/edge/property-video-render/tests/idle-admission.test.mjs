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
  // The actual scheduled entrypoint services prepared judges without a CPU
  // atom, in two parallel bounded authenticated calls. Repeated IDs/extra rows
  // are not extra paid attempts; later cron only sees the unstarted queue.
  const readyA='00000000-0000-4000-8000-000000000003',readyB='00000000-0000-4000-8000-000000000004',readyC='00000000-0000-4000-8000-000000000005';
  const previousTimeout=AbortSignal.timeout,previousWarn=console.warn;
  try{
    const timers=[],warnings=[],posted=[],trace=[];let completeBoth,active=0,maxActive=0;
    const bothStarted=new Promise(resolve=>completeBoth=resolve);
    AbortSignal.timeout=milliseconds=>{timers.push(milliseconds);return previousTimeout(milliseconds);};
    console.warn=(...args)=>warnings.push(args);
    globalThis.fetch=async(url,init)=>{
      const pathname=new URL(url).pathname;
      assert.equal(init.redirect,'manual');assert.equal(init.headers.apikey,'fixture-service');assert.equal(init.headers.Authorization,'Bearer fixture-service');
      if(pathname.endsWith('/queue'))return Response.json(pathname.includes('photo-quality-worker')?{enabled:true,checks:[],judges:[{check_id:readyA},{check_id:readyA},null,{check_id:'not-a-uuid'},{check_id:readyB},{check_id:readyC}]}:{enabled:true,jobs:[]});
      assert.equal(pathname,'/functions/v1/photo-quality-worker/judge');assert.equal(init.method,'POST');const body=JSON.parse(init.body);assert.deepEqual(Object.keys(body),['check_id']);posted.push(body.check_id);trace.push('judge');
      active++;maxActive=Math.max(maxActive,active);if(active===2)completeBoth();await bothStarted;active--;return Response.json({check_id:body.check_id,evidence_id:photo,state:'accept'});
    };
    let scheduled;const config={...env,CPU:{getByName(){throw Error('A ready judge must never claim a CPU/container atom');}}};
    await worker.scheduled({scheduledTime:60_000},config,{waitUntil(value){scheduled=value;}});
    let timer;try{await Promise.race([scheduled,new Promise((_,reject)=>timer=setTimeout(()=>reject(Error('Ready judges were serialized or not awaited')),2000))]);}finally{clearTimeout(timer);}
    assert.deepEqual(posted,[readyA,readyB]);assert.equal(maxActive,2);assert.equal(timers.filter(n=>n===120_000).length,2);assert.equal(timers.filter(n=>n===50_000).length,2);assert.deepEqual(warnings,[]);
    // CPU preparation admission is offered first. A lost judge reply retains
    // its server dispatch state; the next cron cannot issue another call.
    let started=false,cpuOffers=0;const phase=[];posted.length=0;timers.length=0;
    globalThis.fetch=async(url,init)=>{
      const pathname=new URL(url).pathname;
      if(pathname.endsWith('/queue'))return Response.json(pathname.includes('photo-quality-worker')?{enabled:true,checks:started?[]:[{check_id:photo}],judges:started?[]:[{check_id:readyA}]}:{enabled:true,jobs:[]});
      assert.equal(pathname,'/functions/v1/photo-quality-worker/judge');assert.deepEqual(JSON.parse(init.body),{check_id:readyA});phase.push('judge');posted.push(readyA);started=true;throw Error('Private signed URL must not leave this transport: ?private-query=fixture');
    };
    const mixed={...env,CPU:{getByName(){return{async wakePhoto(){cpuOffers++;phase.push('cpu');return true;}};}}};
    for(const minute of[1,2]){await worker.scheduled({scheduledTime:minute*60_000},mixed,{waitUntil(value){scheduled=value;}});await scheduled;}
    assert.deepEqual(phase,['cpu','judge']);assert.equal(cpuOffers,1);assert.deepEqual(posted,[readyA]);assert.equal(warnings.length,1);assert(!JSON.stringify(warnings).includes('private-query'));
    let disabledCalls=0;globalThis.fetch=async()=>{disabledCalls++;throw Error('disabled must not contact authority');};
    await worker.scheduled({scheduledTime:60_000},{...config,ENABLED:'false'},{waitUntil(value){scheduled=value;}});await scheduled;assert.equal(disabledCalls,0);
  }finally{AbortSignal.timeout=previousTimeout;console.warn=previousWarn;}
  console.log('Actual controller: idle/fair CPU admission plus bounded parallel ready judges, no CPU atom, exact service transport and lost-reply no-repeat pass.');
} finally {globalThis.fetch=savedFetch;await rm(directory,{recursive:true,force:true});}
