import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {Miniflare} from 'miniflare';
import {mkdtemp,rm,readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';

// Exercise the shipping Worker in workerd with Container activation disabled.
// CPU hardware/egress TLS/image lifecycle require root's real deployment gate.
const directory=await mkdtemp(path.join(tmpdir(),'rendprop79-workerd-'));
let runtime;
try {
  const file=path.join(directory,'worker.mjs');
  await build({entryPoints:['src/index.ts'],bundle:true,format:'esm',platform:'browser',external:['cloudflare:workers'],outfile:file});
  runtime=new Miniflare({workers:[{config:{name:'renderer',compatibilityDate:'2026-10-14',
    manifest:{mainModule:'worker.mjs',modules:{'worker.mjs':{type:'esm',contents:await readFile(file,'utf8')}}},
    env:{ENABLED:{type:'text',value:'false'},RENDER_TRIGGER_KEY:{type:'text',value:'isolated-test'},
      EDGE_WORKER_URL:{type:'text',value:'https://authority.test.supabase.co/functions/v1/property-video-worker'},MEDIA_HOSTS:{type:'text',value:'media.example.test'},
      CPU:{type:'durable-object',worker:'renderer',exportName:'PropertyVideoCPU'}},
    exports:{PropertyVideoCPU:{type:'durable-object',storage:'sqlite'}}}}]});
  let response=await runtime.dispatchFetch('https://private-renderer.test/health');
  assert.equal(response.status,200);assert.deepEqual(await response.json(),{service:'property-video-render',enabled:false,provider_dispatch:false});
  response=await runtime.dispatchFetch('https://private-renderer.test/wake',{method:'POST'});assert.equal(response.status,403);
  response=await runtime.dispatchFetch('https://private-renderer.test/diagnostic');assert.equal(response.status,403);
  response=await runtime.dispatchFetch('https://private-renderer.test/startup-probe',{method:'POST',headers:{Authorization:'Bearer isolated-test'}});assert.equal(response.status,503,'disabled synthetic control cannot boot');
  response=await runtime.dispatchFetch('https://private-renderer.test/diagnostic?slot=untrusted',{headers:{Authorization:'Bearer isolated-test'}});
  assert.equal(response.status,200);assert.equal(response.headers.get('Cache-Control'),'no-store');
  assert.deepEqual(await response.json(),{slots:[{slot:'slot-0',observation:null},{slot:'slot-1',observation:null}]},'actual SQLite diagnostic works while disabled, without a CPU');

  response=await runtime.dispatchFetch('https://private-renderer.test/wake',{method:'POST',headers:{Authorization:'Bearer isolated-test'}});assert.equal(response.status,503);
  for(const route of ['/execute','/status','/upload','/queue','/finish']){
    response=await runtime.dispatchFetch('https://private-renderer.test'+route,{method:'POST'});assert.equal(response.status,404);
  }
  // Exercise the actual enabled bridge in workerd with a closed outbound
  // authority transport. No production host, credential, queue or CPU is used.
  await runtime.dispose();runtime=undefined;
  const hits=[],logs=[];let status=200,resolveHit,resolveLog;
  const config={name:'renderer',compatibilityDate:'2026-10-14',
    manifest:{mainModule:'worker.mjs',modules:{'worker.mjs':{type:'esm',contents:await readFile(file,'utf8')}}},
    env:{ENABLED:{type:'text',value:'true'},RENDER_TRIGGER_KEY:{type:'text',value:'isolated-test'},EDGE_SERVICE_ROLE_KEY:{type:'text',value:'fixture-authority-secret'},
      EDGE_WORKER_URL:{type:'text',value:'https://authority.test.supabase.co/functions/v1/property-video-worker'},MEDIA_HOSTS:{type:'text',value:'media.example.test'},
      CPU:{type:'durable-object',worker:'renderer',exportName:'PropertyVideoCPU'}},exports:{PropertyVideoCPU:{type:'durable-object',storage:'sqlite'}}};
  runtime=new Miniflare({handleStructuredLogs(log){logs.push(log.message);resolveLog?.(log.message);},workers:[{config,dev:{outboundService:{type:'fetcher',handler(request){
    const url=new URL(request.url);assert.equal(url.hostname,'authority.test.supabase.co');assert.equal(url.pathname,'/functions/v1/property-video-worker/queue');
    assert.equal(request.method,'GET');assert.equal(request.headers.get('Authorization'),'Bearer fixture-authority-secret');assert.equal(request.headers.get('apikey'),'fixture-authority-secret');
    hits.push({url:request.url,status});resolveHit?.();
    return status===200?Response.json({enabled:false,jobs:[]}):new Response('PRIVATE-BODY',{status,headers:{Location:'https://private-redirect.invalid/never'}});
  }}}}]});
  const bounded=async(promise,label)=>{let timer;try{return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error(label+'; '+logs.join(' '))),2000);})]);}finally{clearTimeout(timer);}};

  response=await runtime.dispatchFetch('https://private-renderer.test/diagnostic',{headers:{Authorization:'Bearer isolated-test'}});assert.equal(response.status,200);
  assert.deepEqual(await response.json(),{slots:[{slot:'slot-0',observation:null},{slot:'slot-1',observation:null}]});
  assert.equal(hits.length,0,'enabled authenticated diagnostic makes no authority queue/tick/media requests');
  response=await runtime.dispatchFetch('https://private-renderer.test/startup-probe',{method:'POST'});assert.equal(response.status,403);
  response=await runtime.dispatchFetch('https://private-renderer.test/startup-probe',{method:'POST',headers:{Authorization:'Bearer isolated-test'},body:'{}'});assert.equal(response.status,400);
  response=await runtime.dispatchFetch('https://private-renderer.test/startup-probe',{method:'POST',headers:{Authorization:'Bearer isolated-test'}});assert.equal(response.status,503,'workerd fixture has no physical Container');assert.equal(hits.length,0);
  response=await runtime.dispatchFetch('https://private-renderer.test/startup-probe-v2',{method:'POST'});assert.equal(response.status,403);
  response=await runtime.dispatchFetch('https://private-renderer.test/startup-probe-v2',{method:'POST',headers:{Authorization:'Bearer isolated-test'}});assert.equal(response.status,503);assert.equal(hits.length,0);
  let reached=new Promise(resolve=>{resolveHit=resolve;});
  response=await runtime.dispatchFetch('https://private-renderer.test/wake',{method:'POST',headers:{Authorization:'Bearer isolated-test'}});assert.equal(response.status,202);
  await bounded(reached,'actual enabled bridge failed before its one authority request');assert.equal(hits.length,1);
  for(const redirect of [302,307]){
    status=redirect;const prior=hits.length;let matched;const logged=new Promise(resolve=>{matched=resolve;});
    resolveLog=message=>{if(message.includes('bridge_http')&&message.includes(String(redirect)))matched();};
    response=await runtime.dispatchFetch('https://private-renderer.test/wake',{method:'POST',headers:{Authorization:'Bearer isolated-test'}});assert.equal(response.status,202);
    await bounded(logged,'redirect must be refused as exact HTTP status');assert.equal(hits.length,prior+1,'no redirect follow and no credential forwarding');
  }
  console.log('Actual workerd: enabled private bridge reaches exact closed authority; 302/307 refused without following; disabled/private route guards passed.');
}finally{if(runtime)await runtime.dispose();await rm(directory,{recursive:true,force:true});}
