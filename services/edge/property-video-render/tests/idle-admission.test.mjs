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
    return Response.json('check_id'in body?{action:'wait',check_id:photo}:{action:'wait',job_id:body.job_id},{status});
  };
  for(const domain of ['video','photo']){
    const cpu=new PropertyVideoCPU(ctx,env);status=503;calls=[];
    assert.equal(domain==='video'?await cpu.wake(video,'slot-0'):await cpu.wakePhoto(photo,'slot-0'),true);
    const admitted=data;
    await cpu.alarm();assert.equal(data,admitted,'unknown bridge outcome retains local identity');assert.ok(alarm);
    status=200;const began=Date.now();await cpu.alarm();
    if(domain==='photo'){assert.equal(data,null,'acknowledged idle check releases CPU atom');assert.equal(alarm,null);}
    else{
      // A video supplier wait keeps nothing but a reminder: no lease, task, capability or process.
      const parked=JSON.parse(data);assert.deepEqual(Object.keys(parked).sort(),['jobID','slot','token','waiting']);assert.equal(parked.jobID,video);
      assert.ok(alarm-began>=19_900&&alarm-began<=21_000,'the supplier is looked at again in about 20 s, not at the next cron minute');
      assert.deepEqual(await cpu.holder(),{id:video,state:'waiting',since:parked.waiting.since});
      // Its own generic wake moments later keeps the scheduled look (no double tick)...
      const scheduled=alarm;assert.equal(await cpu.wake(video,'slot-0'),true);assert.equal(alarm,scheduled);assert.equal(calls.length,2);
      // ...and a later one looks at once.
      {const old=JSON.parse(data);old.waiting.at-=11_000;data=JSON.stringify(old);assert.equal(await cpu.wake(video,'slot-0'),true);assert.ok(alarm-Date.now()<=10);
        await cpu.alarm();assert.equal(calls.length,3);const again=JSON.parse(data);assert.equal(again.waiting.since,old.waiting.since,'continuous waiting keeps its start');assert.ok(again.waiting.at>old.waiting.at);}
      // While its own look is in flight nothing may replace it (the turn would write the old job back).
      {const real=globalThis.fetch;let refused;globalThis.fetch=async(url,init)=>{refused=[await cpu.wakePhoto(photo,'slot-0'),await cpu.prewarmPhoto(photo,'slot-0'),await cpu.wake(photo,'slot-0'),(await cpu.holder()).state];return real(url,init);};
        try{await cpu.alarm();}finally{globalThis.fetch=real;}assert.deepEqual(refused,[false,false,false,'fresh']);assert.equal(JSON.parse(data).jobID,video);assert.ok(JSON.parse(data).waiting);calls.pop();}
      // After ten minutes of continuous waiting the slot lets go and cron takes over.
      {const long=JSON.parse(data);long.waiting.since-=10*60_000;data=JSON.stringify(long);await cpu.alarm();assert.equal(calls.length,4);assert.equal(data,null);assert.equal(alarm,null);}
      // Park again for the admission checks below.
      assert.equal(await cpu.wake(video,'slot-0'),true);await cpu.alarm();assert.ok(JSON.parse(data).waiting);calls=calls.slice(0,2);
      // Another video job takes the waiting slot at once.
      const second='00000000-0000-4000-8000-000000000006';assert.equal(await cpu.wake(second,'slot-0'),true);assert.equal(JSON.parse(data).jobID,second);assert.equal(JSON.parse(data).waiting,undefined);
      assert.deepEqual(await cpu.holder(),{id:second,state:'fresh'});assert.equal(await cpu.wake(video,'slot-0'),false,'an admitted job is not displaced');
      await cpu.alarm();assert.equal(JSON.parse(data).jobID,second);assert.ok(JSON.parse(data).waiting);calls=calls.slice(0,2);
      {const warm='00000000-0000-4000-8000-000000000007';assert.equal(await cpu.prewarmPhoto(warm,'slot-0'),true);assert.equal(JSON.parse(data).checkID,warm);assert.ok(JSON.parse(data).prewarmUntil);assert.deepEqual(await cpu.holder(),{id:warm,state:'warm'});data=null;alarm=null;
        assert.equal(await cpu.wake(video,'slot-0'),true);await cpu.alarm();assert.ok(JSON.parse(data).waiting);calls=calls.slice(0,2);}
    }
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
      async holder(){return occupant?{id:'held',state:'busy'}:null;},
      async wake(){if(occupant)return false;occupant='video';return true;},
      async wakePhoto(){if(occupant)return false;occupant='photo';return true;},
    };}}};
    await worker.scheduled({scheduledTime:minute*60_000},config,{waitUntil(value){pending=value;}});await pending;
    assert.equal(occupant,expected);assert.deepEqual(trace,expected==='photo'?['photo','video']:['video','photo']);
  }

  // The real scheduled handler and wake route over two real slot objects: a
  // job never gains a second copy on a waiting slot, an item without a slot
  // goes first (so a new job starts at once), the longest wait yields, and a
  // photo check prefers the free slot before it takes a waiting one.
  {
    const ids=['a','b','c','d','e'].map(letter=>`00000000-0000-4000-8000-0000000000${letter}0`),[A,B,C,P,E]=ids;
    const make=name=>{let saved=null,due=null;const store={exec(query,...args){
        if(query.startsWith('CREATE')||query.includes('diagnostic'))return{toArray:()=>[]};
        if(query.startsWith('SELECT'))return{toArray:()=>saved?[{state:saved}]:[]};
        if(query.startsWith('INSERT'))saved=args[0];if(query.startsWith('DELETE'))saved=null;return{toArray:()=>[]};}};
      const cpu=new PropertyVideoCPU({storage:{sql:store,async setAlarm(value){due=value;},async deleteAlarm(){due=null;}},container:{running:false,async destroy(){throw Error('no process exists');},async setInactivityTimeout(){throw Error('no process exists');}}},shared);
      return{name,cpu,get state(){return saved?JSON.parse(saved):null;},set state(value){saved=value?JSON.stringify(value):null;if(!value)due=null;},get due(){return due;},async run(){if(due!==null&&due<=Date.now()+1&&saved){due=null;await cpu.alarm();}}};};
    const shared={...env,ENABLED:'true',RENDER_TRIGGER_KEY:'fixture-trigger'};const slots={};shared.CPU={getByName(name){return slots[name].cpu;}};
    for(const name of['slot-0','slot-1'])slots[name]=make(name);
    let queued=[A,B],checks=[],regionSeen=[];const ticks=[];
    globalThis.fetch=async(url,init)=>{
      const pathname=new URL(url).pathname;regionSeen.push(init.headers['x-region']);
      if(pathname.endsWith('/photo-quality-worker/queue'))return Response.json({enabled:true,checks:checks.map(check_id=>({check_id}))});
      if(pathname.endsWith('/queue'))return Response.json({enabled:true,jobs:queued.map(item=>typeof item==='string'?{job_id:item}:item)});
      const body=JSON.parse(init.body);
      if('check_id'in body)return Response.json({action:'wait',check_id:body.check_id});
      ticks.push(`${body.worker_id}:${body.job_id.at(-2)}`);return Response.json({action:'wait',job_id:body.job_id});
    };
    // A fixed clock: rotation turn 0 for any list length (the turn is the 20 s window number modulo the list).
    const realNow=Date.now,T=1_800_000_000_000;assert.equal(Math.floor(T/20_000)%60,0);let now=T;Date.now=()=>now;
    try{
    const pass=async()=>{let pending;await worker.scheduled({scheduledTime:0},shared,{waitUntil(value){pending=value;}});await pending;};
    const owners=()=>['slot-0','slot-1'].map(name=>slots[name].state?.jobID??slots[name].state?.checkID??null);
    const settle=async()=>{for(const name of['slot-0','slot-1'])await slots[name].run();};
    const clear=()=>{for(const name of['slot-0','slot-1'])slots[name].state=null;};
    // Simulate the quiet window having passed since each slot's own look.
    const age=()=>{for(const name of['slot-0','slot-1']){const state=slots[name].state;if(state?.waiting){state.waiting.at-=11_000;slots[name].state=state;}}};
    await pass();assert.deepEqual(owners(),[A,B]);await settle();assert.deepEqual(ticks,['slot-0:a','slot-1:b']);
    assert.ok(slots['slot-0'].state.waiting&&slots['slot-1'].state.waiting,'both jobs wait on their suppliers and keep only a reminder');
    assert.equal(slots['slot-0'].due,T+20_000,'the supplier is looked at again in 20 s');
    // Next pass (cron, or the function's follow-up wake): each job stays on its own slot, one tick each.
    age();await pass();assert.deepEqual(owners(),[A,B]);await settle();assert.deepEqual(ticks,['slot-0:a','slot-1:b','slot-0:a','slot-1:b']);
    // A wake seconds after the slots' own look is absorbed: nothing ticks twice.
    await pass();assert.equal(slots['slot-0'].due,T+20_000);await pass();await settle();assert.equal(ticks.length,4);
    // A third job is not starved by two waiting ones: it has no slot, so it goes first and the longest wait yields.
    {const longest=slots['slot-1'].state;longest.waiting.since-=60_000;slots['slot-1'].state=longest;}
    queued=[A,B,P];age();await pass();assert.deepEqual(owners(),[A,P],'the job without a slot takes the slot that has waited longest, although it is listed last');
    assert.equal(slots['slot-1'].due,T+1,'and is looked at immediately');await settle();assert.deepEqual(ticks.slice(4),['slot-0:a','slot-1:d']);
    // The displaced job is found again on the next pass, and takes the slot that has now waited longest.
    {const longest=slots['slot-0'].state;longest.waiting.since-=60_000;slots['slot-0'].state=longest;}
    age();await pass();assert.deepEqual(owners(),[B,P]);await settle();assert.deepEqual(ticks.slice(6),['slot-0:b','slot-1:d']);
    // More waiting jobs than slots rotate by 20 s window, so none is left out for ever.
    clear();queued=[A,B,C,P,E];await pass();assert.deepEqual(owners(),[A,B]);
    clear();now=T+20_000;await pass();assert.deepEqual(owners(),[B,C]);
    clear();now=T+80_000;await pass();assert.deepEqual(owners(),[E,A]);
    // A photo preparation (flagged by the queue) always leads, whatever the rotation.
    clear();now=T+20_000;queued=[A,B,C,P,{job_id:E,prepare:true}];await pass();assert.deepEqual(owners(),[E,B],'preparation first, then this window\'s turn');
    clear();now=T;await pass();assert.deepEqual(owners(),[E,A]);
    // A photo check takes a waiting slot only when no slot is free.
    clear();queued=[A,B];await pass();await settle();assert.deepEqual(owners(),[A,B]);
    checks=['00000000-0000-4000-8000-0000000000f1'];queued=[];await pass();assert.deepEqual(owners(),[checks[0],B],'no free slot: the check takes a waiting one');
    await settle();assert.deepEqual(owners(),[null,B]);
    await pass();assert.deepEqual(owners(),[checks[0],B],'a free slot is preferred to the waiting one');await settle();checks=[];
    // A job found again goes to the free slot rather than displacing a waiting job.
    queued=[A,B];age();await pass();assert.deepEqual(owners(),[A,B]);await settle();
    // A job busy with CPU work on one slot may also use a free one (its next clip), never a waiting one,
    // and only capacity left over: another queued job has the free slot first.
    {const busy=slots['slot-1'].state;delete busy.waiting;busy.taskID='e'.repeat(64);busy.task={action:'compose'};slots['slot-1'].state=busy;
      queued=[B];age();await pass();assert.deepEqual(owners(),[A,B],'a waiting slot is not taken for a second copy');
      slots['slot-0'].state=null;await pass();assert.deepEqual(owners(),[B,B],'a free slot is');
      slots['slot-0'].state=null;queued=[B,C];await pass();assert.deepEqual(owners(),[C,B],'a distinct queued job comes before a second copy');}
    // The function's wake on create/resume (POST /wake, same private key as /photo-quality/start) starts a new job at
    // once, even while both slots wait on suppliers and although a new job is listed last: no cron minute in between.
    {clear();queued=[A,B];await pass();await settle();assert.deepEqual(owners(),[A,B]);
      queued=[A,B,E];const before=ticks.length;let pending;
      const post=authorization=>worker.fetch(new Request('https://controller.test/wake',{method:'POST',headers:authorization?{Authorization:authorization}:{}}),shared,{waitUntil(value){pending=value;}});
      assert.equal((await post()).status,403);assert.equal((await post('Bearer wrong')).status,403);assert.equal(pending,undefined,'an unauthorized wake reads no queue');
      const reply=await post('Bearer fixture-trigger');assert.equal(reply.status,202);assert.deepEqual(await reply.json(),{accepted:true});await pending;
      assert.deepEqual(owners(),[E,B]);assert.equal(slots['slot-0'].due,T+1,'the new job is looked at immediately');assert.equal(slots['slot-1'].due,T+20_000,'the waiting job keeps its own schedule');
      await settle();assert.deepEqual(ticks.slice(before),['slot-0:e']);clear();}
    assert.ok(regionSeen.length>0&&regionSeen.every(region=>region===undefined),'no region header unless configured');
    regionSeen=[];shared.EDGE_FUNCTION_REGION='us-west-2';queued=[];await pass();assert.deepEqual(regionSeen,['us-west-2','us-west-2'],'both cron queue reads are pinned to the database region');
    regionSeen=[];shared.EDGE_FUNCTION_REGION='moon-1';await pass();assert.deepEqual(regionSeen,[undefined,undefined],'an unknown region is never sent');
    }finally{Date.now=realNow;}
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
    const mixed={...env,CPU:{getByName(){return{async holder(){return null;},async wakePhoto(){cpuOffers++;phase.push('cpu');return true;}};}}};
    for(const minute of[1,2]){await worker.scheduled({scheduledTime:minute*60_000},mixed,{waitUntil(value){scheduled=value;}});await scheduled;}
    assert.deepEqual(phase,['cpu','judge']);assert.equal(cpuOffers,1);assert.deepEqual(posted,[readyA]);assert.equal(warnings.length,1);assert(!JSON.stringify(warnings).includes('private-query'));
    let disabledCalls=0;globalThis.fetch=async()=>{disabledCalls++;throw Error('disabled must not contact authority');};
    await worker.scheduled({scheduledTime:60_000},{...config,ENABLED:'false'},{waitUntil(value){scheduled=value;}});await scheduled;assert.equal(disabledCalls,0);
  }finally{AbortSignal.timeout=previousTimeout;console.warn=previousWarn;}
  console.log('Actual controller: idle/fair CPU admission, 20 s supplier re-check that yields the slot, first turn for items without a slot, immediate wake, plus bounded parallel ready judges, no CPU atom, exact service transport and lost-reply no-repeat pass.');
} finally {globalThis.fetch=savedFetch;await rm(directory,{recursive:true,force:true});}
