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
  response=await runtime.dispatchFetch('https://private-renderer.test/wake',{method:'POST',headers:{Authorization:'Bearer isolated-test'}});assert.equal(response.status,503);
  for(const route of ['/execute','/status','/upload','/queue','/finish']){
    response=await runtime.dispatchFetch('https://private-renderer.test'+route,{method:'POST'});assert.equal(response.status,404);
  }
  console.log('Actual workerd: disabled health, private wake, no exposed CPU/authority routes passed.');
}finally{if(runtime)await runtime.dispose();await rm(directory,{recursive:true,force:true});}
