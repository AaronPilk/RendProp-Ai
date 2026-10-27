import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createRequire} from 'node:module';

const directory=await mkdtemp(path.join(tmpdir(),'rendprop79-controller-'));
try {
  const target=path.join(directory,'controller.cjs');
  await build({entryPoints:['src/index.ts'],bundle:true,platform:'node',format:'cjs',outfile:target,
    plugins:[{name:'cloudflare-lifecycle-double',setup(api){api.onResolve({filter:/^cloudflare:workers$/},()=>({path:path.resolve('tests/cloudflare-stub.ts')}));}}]});
  const {PropertyVideoCPU,default:worker}=createRequire(import.meta.url)(target);
  const job='00000000-0000-4000-8000-000000000001',lease='00000000-0000-4000-8000-000000000002';
  let task={job_id:job,state:'composing',action:'compose',lease_token:lease,manifest_sha256:'a'.repeat(64),purpose:'listing',aspect:'16:9',
    sources:[{url:'https://media.example.test/owned?sign=one',bytes:12,sha256:'a'.repeat(64),position:0,motion_kind:'ai'}],
    output:{asset_id:job,poster_asset_id:lease},presentation:{transition:'cut',shot_caption_style:'off',spoken_captions:false,shot_labels:[null]},expires_at:new Date(Date.now()+3600000).toISOString()};
  let receipt={job_id:job,lease_token:lease,manifest_sha256:task.manifest_sha256,asset_id:job,poster_asset_id:lease,width:1920,height:1080,duration_s:5,bytes:12,sha256:'b'.repeat(64),poster_bytes:4,poster_sha256:'c'.repeat(64)};
  let observation=null,cpuTouches=0;
  let data=null,alarm=null,status='prepared',finishCount=0,failCount=0,tickCount=0,outputs=0,uploadCount=0,heartbeatStatus=200,failureStatus=200,terminalAfterFailure=false;
  const events=[];let apiFault=null,cpuHTTPFault=null,monitorFault=null,coldDelayMs=0;
  const sql={exec(query,...args){
    if(query.startsWith('SELECT observation'))return{toArray:()=>observation?[{observation}]:[]};
    if(query.startsWith('INSERT INTO diagnostic')){observation=args[0];return{toArray:()=>[]};}
    if(query.startsWith('SELECT'))return{toArray:()=>data?[{state:data}]:[]};
    if(query.startsWith('INSERT')){data=args[0];events.push('persist');}
    if(query.startsWith('DELETE')){data=null;events.push('clear');}
    return{toArray:()=>[]};
  }};
  const container={running:false,images:{cpu:'verified-image@sha256:test'},async setInactivityTimeout(ms){cpuTouches++;assert.ok(ms>0);if(apiFault==='inactivity')throw new TypeError('PRIVATE-inactivity-url');},
    start(options){cpuTouches++;if(apiFault==='start')throw new TypeError('PRIVATE-start-token');assert.equal(options.enableInternet,false);assert.equal(options.instance,'standard-3');assert.ok(!('EDGE_SERVICE_ROLE_KEY' in options.env));this.running=!monitorFault&&!coldDelayMs;events.push('boot');},
    monitor(){cpuTouches++;return monitorFault?Promise.reject(monitorFault):new Promise(()=>{});},
    async destroy(){cpuTouches++;this.running=false;events.push('sleep');},async interceptOutboundHttps(host,binding){cpuTouches++;if(apiFault==='egress')throw new TypeError('PRIVATE-egress-url');assert.equal(host,'*');this.bound=binding;},
    getTcpPort(port){cpuTouches++;assert.equal(port,8080);return{fetch:async(url,init)=>{
      const route=new URL(url).pathname;if(cpuHTTPFault===route)return new Response('PRIVATE-CPU-body',{status:403});
      if(route==='/ready')return Response.json({ready:true});
      if(route==='/execute')return Response.json({task_id:'e'.repeat(64)},{status:202});
      if(route==='/status')return Response.json({state:status,result:receipt});
      if(route==='/upload'){uploadCount++;status='uploaded';return Response.json({accepted:true},{status:202});}
      throw Error('unexpected CPU route');
    }};}};
  const ctx={storage:{sql,async setAlarm(value){alarm=value;},async deleteAlarm(){alarm=null;}},container,waitUntil(promise){void promise;},exports:{MediaEgress:({props})=>({props})}};
  const env={ENABLED:'true',EDGE_WORKER_URL:'https://authority.test.supabase.co/functions/v1/property-video-worker',EDGE_SERVICE_ROLE_KEY:'controller-test-secret',MEDIA_HOSTS:'media.example.test',RENDER_TRIGGER_KEY:'trigger-test'};
  const originalFetch=globalThis.fetch;
  globalThis.fetch=async(url,init)=>{
    const route=new URL(url).pathname.split('/').at(-1);assert.equal(init.headers.Authorization,'Bearer controller-test-secret');
    if(route==='heartbeat'){assert.equal(JSON.parse(init.body).lease_token,lease);return Response.json({current:true},{status:heartbeatStatus});}
    if(route==='tick'){tickCount++;return Response.json(terminalAfterFailure?{job_id:job,state:'failed',action:'done'}:finishCount?{job_id:job,state:'ready',action:'done'}:task);}
    if(route==='prepared-outputs'){outputs++;return Response.json({output:{asset_id:job,put_url:'https://media.example.test/prepared?sign=four',headers:{'content-length':'12','content-type':'image/jpeg','if-none-match':'*','x-amz-meta-sha256':receipt.sha256}},expires_at:task.expires_at});}
    if(route==='outputs'){outputs++;assert.equal(JSON.parse(init.body).sha256,receipt.sha256);return Response.json({output:{asset_id:job,poster_asset_id:lease,put_url:'https://media.example.test/master?sign=two',poster_put_url:'https://media.example.test/poster?sign=three',
      headers:{'content-length':'12','content-type':'video/mp4','if-none-match':'*','x-amz-meta-sha256':receipt.sha256},
      poster_headers:{'content-length':'4','content-type':'image/jpeg','if-none-match':'*','x-amz-meta-sha256':receipt.poster_sha256}},expires_at:task.expires_at});}
    if(route==='finish'||route==='prepared-finish'){finishCount++;assert.equal(JSON.parse(data).pendingCallback.body.sha256,receipt.sha256);events.push('finish');return Response.json({registered:true});}
    if(route==='audio-preflight'){finishCount++;const body=JSON.parse(init.body);assert.equal(body.manifest_sha256,task.manifest_sha256);assert.equal(body.source_sha256,task.source.sha256);assert.equal(body.audio_streams,1);assert.equal(body.duration_s,10);assert.equal(JSON.parse(data).pendingCallback.path,'audio-preflight');events.push('audio-preflight');return Response.json({current:true});}
    if(route==='failure'){failCount++;return Response.json({failed:true},{status:failureStatus});}
    throw Error('unexpected authority route');
  };
  try {
    let cpu=new PropertyVideoCPU(ctx,env);
    assert.equal(await cpu.wake(job,'slot-0'),true);
    assert.equal(await cpu.wake(lease,'slot-0'),false,'one CPU slot cannot admit another job');
    await cpu.alarm();assert.ok(JSON.parse(data).taskID);assert.equal(tickCount,1);
    await cpu.alarm();assert.equal(outputs,1);assert.equal(uploadCount,1);assert.equal(finishCount,0);
    await cpu.alarm();assert.ok(JSON.parse(data).pendingCallback);assert.equal(finishCount,0);
    // Actual production class reconstructs against retained SQL before callback.
    cpu=new PropertyVideoCPU(ctx,env);
    await cpu.alarm();assert.equal(finishCount,1);assert.equal(data,null);assert.equal(container.running,false);
    assert.ok(events.indexOf('persist')<events.indexOf('finish'));
    // Interrupted CPU must take fenced failure, not fake finish or paid dispatch.
    status='working';finishCount=0;await cpu.wake(job,'slot-0');await cpu.alarm();container.running=false;
    await cpu.alarm();assert.equal(failCount,1);assert.equal(finishCount,0);assert.equal(data,null);
    task={job_id:job,state:'preparing',action:'prepare_image',lease_token:lease,source:{url:'https://media.example.test/original?sign=five',sha256:'a'.repeat(64),bytes:12},output:{asset_id:job,key:'prepared/owned.jpg'},expires_at:new Date(Date.now()+3600000).toISOString()};
    receipt={job_id:job,lease_token:lease,source_sha256:'a'.repeat(64),asset_id:job,width:2048,height:1536,bytes:12,sha256:'b'.repeat(64),mime:'image/jpeg'};
    status='prepared';finishCount=0;await cpu.wake(job,'slot-1');await cpu.alarm();await cpu.alarm();await cpu.alarm();
    assert.equal(JSON.parse(data).pendingCallback.path,'prepared-finish');cpu=new PropertyVideoCPU(ctx,env);await cpu.alarm();assert.equal(finishCount,1);assert.equal(data,null);assert.equal(container.running,false);
    const priorTask=task,priorReceipt=receipt,priorOutputs=outputs,priorUploads=uploadCount;
    task={job_id:job,state:'queued',action:'inspect_audio',lease_token:lease,manifest_sha256:'a'.repeat(64),source:{url:'https://media.example.test/voice?sign=six',sha256:'b'.repeat(64),bytes:12},max_duration_s:10,expires_at:new Date(Date.now()+3600000).toISOString()};
    receipt={job_id:job,lease_token:lease,manifest_sha256:task.manifest_sha256,source_sha256:task.source.sha256,duration_s:10,audio_streams:1};
    status='inspected';finishCount=0;await cpu.wake(job,'slot-0');await cpu.alarm();await cpu.alarm();assert.equal(JSON.parse(data).pendingCallback.path,'audio-preflight');assert.equal(container.running,false,'metadata callback sleeps CPU');cpu=new PropertyVideoCPU(ctx,env);await cpu.alarm();assert.equal(finishCount,1);assert.equal(data,null);assert.equal(outputs,priorOutputs);assert.equal(uploadCount,priorUploads,'audio metadata never obtains PUT capabilities');
    task=priorTask;receipt=priorReceipt;
    status='working';finishCount=0;await cpu.wake(job,'slot-1');await cpu.alarm();heartbeatStatus=409;
    const priorFinish=finishCount;await cpu.alarm();assert.equal(data,null);assert.equal(container.running,false);assert.equal(finishCount,priorFinish,'revoked/superseded work cannot finish');heartbeatStatus=200;
    status='failed';finishCount=0;failureStatus=503;await cpu.wake(job,'slot-1');await cpu.alarm();await cpu.alarm();
    assert.equal(JSON.parse(data).pendingCallback.path,'failure');assert.equal(container.running,false,'authority outage must not keep idle CPU billed');assert.equal(finishCount,0);
    failureStatus=200;terminalAfterFailure=true;cpu=new PropertyVideoCPU(ctx,env);await cpu.alarm();assert.equal(data,null);assert.equal(container.running,false);assert.equal(finishCount,0,'failure retry never fabricates a successful output');
    const disabled={...env,ENABLED:'false'};
    assert.equal((await worker.fetch(new Request('https://controller.test/wake',{method:'POST',headers:{Authorization:'Bearer trigger-test'}}),disabled,{waitUntil(){throw Error('disabled dispatch');}})).status,503);
    assert.equal((await worker.fetch(new Request('https://controller.test/wake',{method:'POST'}),env,{waitUntil(){throw Error('unauthorized dispatch');}})).status,403);
    assert.equal((await worker.fetch(new Request('https://controller.test/anything'),env,{})).status,404);
    // Inspection uses the existing trigger key and only the two fixed atoms.
    const noActions={waitUntil(){throw Error('diagnostic dispatched work');}};
    const requested=[];let inspections=0;
    const inspectEnv={...disabled,CPU:{getByName(slot){requested.push(slot);return{
      async diagnostic(){inspections++;return slot==='slot-0'?{phase:'execute',error_name:'Other',reason:'http_refusal',http_status:403,timestamp:123}:null;},
      async temporalAttestations(){return [];},
      async wake(){throw Error('diagnostic woke work');}
    };}}};
    for(const authorization of [undefined,'Bearer wrong-trigger']){
      const headers=authorization?{Authorization:authorization}:{};
      assert.equal((await worker.fetch(new Request('https://controller.test/diagnostic?slot=PRIVATE',{headers}),inspectEnv,noActions)).status,403);
    }
    assert.equal(inspections,0);assert.deepEqual(requested,[],'unauthorized inspection cannot address DOs');
    const readOnlyBefore={tickCount,finishCount,failCount,cpuTouches,alarm,data};
    const inspected=await worker.fetch(new Request('https://controller.test/diagnostic?slot=PRIVATE',{headers:{Authorization:'Bearer trigger-test'}}),inspectEnv,noActions);
    assert.equal(inspected.status,200);assert.equal(inspected.headers.get('Cache-Control'),'no-store');
    assert.deepEqual(await inspected.json(),{slots:[{slot:'slot-0',observation:{phase:'execute',error_name:'Other',reason:'http_refusal',http_status:403,timestamp:123}},{slot:'slot-1',observation:null}]});
    assert.deepEqual(requested,['slot-0','slot-1']);assert.equal(inspections,2);
    assert.deepEqual({tickCount,finishCount,failCount,cpuTouches,alarm,data},readOnlyBefore,'inspection has no queue/tick/callback/CPU/alarm side effects');
    for(const [method,route] of [['POST','/diagnostic'],['GET','/diagnostic/slot-0'],['GET','/wake']])assert.equal((await worker.fetch(new Request('https://controller.test'+route,{method,headers:{Authorization:'Bearer trigger-test'}}),inspectEnv,noActions)).status,404);


    for(const route of ['/startup-probe','/startup-probe-v2'])assert.equal((await worker.fetch(new Request('https://controller.test'+route,{method:'POST',headers:{Authorization:'Bearer trigger-test'}}),env,noActions)).status,404,'retired startup controls have no route');
    // Exercise the actual scheduled entry and its caught bridge, not merely a
    // formatter. Hostile exception/body strings must never enter a log.
    const originalAuthority=globalThis.fetch;
    const warn=console.warn,diagnostics=[];console.warn=(...args)=>diagnostics.push(args);
    const scheduled=async(config,transport)=>{
      diagnostics.length=0;globalThis.fetch=(url,init)=>new URL(url).pathname.includes('/photo-quality-worker/')?Promise.resolve(Response.json({enabled:false,checks:[]})):transport(url,init);let pending;
      await worker.scheduled({},config,{waitUntil(value){assert.equal(pending,undefined);pending=value;}});
      await pending;return structuredClone(diagnostics);
    };
    try {
      let calls=0;
      const noFetch=async()=>{calls++;throw Error('PRIVATE-URL-TOKEN');};
      for(const config of [{...env,EDGE_WORKER_URL:'invalid-private-url'},{...env,EDGE_SERVICE_ROLE_KEY:''}]){
        assert.deepEqual(await scheduled(config,noFetch),[['property_video_dispatch_refused',{category:'bridge_configuration'}],['photo_quality_dispatch_refused',{category:'bridge_configuration'}]]);
      }
      assert.equal(calls,0,'bad bridge config performs no request');
      for(const status of [302,307,401,403,500]){
        assert.deepEqual(await scheduled(env,async(_url,init)=>{
          calls++;assert.equal(init.method,'GET');assert.equal(init.redirect,'manual');assert.equal(init.headers.apikey,env.EDGE_SERVICE_ROLE_KEY);assert.equal(init.headers.Authorization,'Bearer '+env.EDGE_SERVICE_ROLE_KEY);
          return new Response('PRIVATE-RESPONSE-TOKEN',{status});
        }),[['property_video_dispatch_refused',{category:'bridge_http',status}]]);
      }
      assert.equal(calls,5,'one request per scheduled refusal, no retry');
      assert.deepEqual(await scheduled(env,noFetch),[['property_video_dispatch_refused',{category:'bridge_transport',error_name:'Other',reason:'other'}]]);
      for(const [error,expected] of [
        [new TypeError('Redirect PRIVATE-URL-TOKEN'),{error_name:'TypeError',reason:'redirect'}],
        [new TypeError('Invalid header PRIVATE-KEY-TOKEN'),{error_name:'TypeError',reason:'invalid_header'}],
        [new TypeError('DNS ENOTFOUND PRIVATE-HOST'),{error_name:'TypeError',reason:'dns'}],
        [new DOMException('PRIVATE-URL timed out','TimeoutError'),{error_name:'TimeoutError',reason:'timeout'}],
        [new DOMException('PRIVATE-URL','AbortError'),{error_name:'AbortError',reason:'other'}],
        [new TypeError('AbortSignal.timeout is not a function PRIVATE-DATA'),{error_name:'TypeError',reason:'unsupported_api'}],
      ]) assert.deepEqual(await scheduled(env,async()=>{throw error;}),[['property_video_dispatch_refused',{category:'bridge_transport',...expected}]]);

      assert.deepEqual(await scheduled(env,async()=>new Response('PRIVATE-BODY-TOKEN')),[['property_video_dispatch_refused',{category:'bridge_response'}]]);
      assert.deepEqual(await scheduled({...env,CPU:{getByName(){throw Error('PRIVATE-CONTROLLER-TOKEN');}}},async()=>Response.json({enabled:true,jobs:[{job_id:job}]})),[['property_video_dispatch_refused',{category:'controller'}]]);
      assert.ok(!JSON.stringify(diagnostics).includes('PRIVATE-'),'raw thrown data is not logged');
      assert.deepEqual(await scheduled(env,async()=>Response.json({enabled:false,jobs:[]})),[],'disabled DB queue remains quiet');

      globalThis.fetch=originalAuthority;
      terminalAfterFailure=false;failureStatus=200;finishCount=0;
      for(const phase of ['start','inactivity','egress']){
        diagnostics.length=0;apiFault=phase;cpuHTTPFault=null;container.running=false;data=null;
        cpu=new PropertyVideoCPU(ctx,env);await cpu.wake(job,'slot-0');await cpu.alarm();
        assert.deepEqual(diagnostics,[['property_video_cpu_refused',{phase,category:'cpu_api',error_name:'TypeError',reason:'other'}]]);
        assert.equal(data,null,'finite failure callback retains authority rather than faking ready');
        const snapshot=await cpu.diagnostic();
        assert.deepEqual({...snapshot,timestamp:0},{phase,error_name:'TypeError',reason:'other',timestamp:0});
        assert.ok(Number.isSafeInteger(snapshot.timestamp)&&snapshot.timestamp>0);
        assert.ok(!JSON.stringify(snapshot).includes('PRIVATE-'));
        const before={tickCount,finishCount,failCount,cpuTouches,alarm,data};
        cpu=new PropertyVideoCPU(ctx,env);assert.deepEqual(await cpu.diagnostic(),snapshot,'last failure survives stop and instance recreation');
        assert.deepEqual({tickCount,finishCount,failCount,cpuTouches,alarm,data},before,'constructing/reading diagnostics never touches an existing CPU');

      }
      apiFault=null;diagnostics.length=0;data=null;container.running=false;cpuHTTPFault='/execute';
      cpu=new PropertyVideoCPU(ctx,env);await cpu.wake(job,'slot-0');await cpu.alarm();
      assert.deepEqual(diagnostics,[['property_video_cpu_refused',{phase:'execute',category:'cpu_http',status:403}]]);
      assert.ok(!JSON.stringify(diagnostics).includes('PRIVATE-'),'CPU details never log raw body, URL or token');
      const httpObservation=await cpu.diagnostic();
      assert.deepEqual({...httpObservation,timestamp:0},{phase:'execute',error_name:'Other',reason:'http_refusal',http_status:403,timestamp:0});
      for(const invalid of ['invalid-json',JSON.stringify({...httpObservation,token:'PRIVATE-TOKEN'}),JSON.stringify({...httpObservation,phase:'PRIVATE-URL'}),JSON.stringify({...httpObservation,error_name:'PRIVATE-ERROR'}),JSON.stringify({...httpObservation,reason:'PRIVATE-BODY'}),JSON.stringify({...httpObservation,http_status:999}),JSON.stringify({...httpObservation,timestamp:-1}),JSON.stringify({...httpObservation,exit_code:'PRIVATE'}),JSON.stringify({...httpObservation,exit_code:256})]){
        observation=invalid;assert.equal(await cpu.diagnostic(),null,'corrupt/non-closed metadata is never exposed');
      }

      cpuHTTPFault=null;
      // The real platform validates start() synchronously and can reject its
      // image/process later. Observe that promise without leaking raw errors.
      for(const [fault,reason,exit]of [[Object.assign(new Error('PRIVATE-process'),{exitCode:1}),'process_exit',1],[new Error('PRIVATE-image registry reference'),'startup_image',undefined],[new Error('PRIVATE-resource capacity'),'startup_capacity',undefined]]){
        monitorFault=fault;container.running=false;data=null;diagnostics.length=0;
        const beforeFail=failCount,beforeTicks=tickCount,beforeBoots=events.filter(x=>x==='boot').length;
        cpu=new PropertyVideoCPU(ctx,env);await cpu.wake(job,'slot-0');await cpu.alarm();
        const snap=await cpu.diagnostic();assert.equal(snap.phase,'start');assert.equal(snap.reason,reason);assert.equal(snap.exit_code,exit);
        assert.equal(failCount,beforeFail+1);assert.equal(tickCount,beforeTicks+1);assert.equal(events.filter(x=>x==='boot').length,beforeBoots+1);
        assert.equal(data,null);assert.ok(!JSON.stringify(snap).includes('PRIVATE-'));
      }

      monitorFault=null;
      // A cold instance may take longer than30s. One start waits for readiness
      // up to120s, without additional claims, tasks, or supplier activity.
      const realNow=Date.now,realTimer=globalThis.setTimeout;
      for(const delay of [75_000,150_000]){
        let fakeNow=realNow(),elapsed=0;Date.now=()=>fakeNow;coldDelayMs=delay;container.running=false;data=null;status='working';
        const beforeFail=failCount,beforeTicks=tickCount,beforeBoots=events.filter(x=>x==='boot').length;
        globalThis.setTimeout=(callback,ms)=>{assert.equal(ms,300);elapsed+=ms;fakeNow+=ms;if(elapsed>=delay)container.running=true;queueMicrotask(callback);return 0;};
        try{
          cpu=new PropertyVideoCPU(ctx,env);await cpu.wake(job,'slot-0');await cpu.alarm();
          assert.equal(events.filter(x=>x==='boot').length,beforeBoots+1,'only one container start');assert.equal(tickCount,beforeTicks+1,'only one authority claim');
          if(delay<120_000){assert.ok(JSON.parse(data).taskID);assert.equal(failCount,beforeFail);assert.equal(elapsed,delay);}
          else{assert.equal(data,null);assert.equal(failCount,beforeFail+1);assert.equal(elapsed,120_000);assert.equal((await cpu.diagnostic()).phase,'ready_timeout');}
        }finally{Date.now=realNow;globalThis.setTimeout=realTimer;coldDelayMs=0;}
        if(data){container.running=false;await cpu.alarm();}
      }

    } finally {console.warn=warn;}

  } finally {globalThis.fetch=originalFetch;}
  console.log('Actual DO controller with isolated lifecycle doubles: persisted output admission/callback/restart, interrupt failure, sleep, private routes passed. Hosted Container acceptance remains required.');
} finally {await rm(directory,{recursive:true,force:true});}
