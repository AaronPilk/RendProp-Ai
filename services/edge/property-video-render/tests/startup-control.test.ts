import assert from 'node:assert/strict';
import {startupControl,startupStderrReason} from '../src/startup-control.ts';
for(const [text,reason]of [['private_renderer_configuration_missing PRIVATE','configuration'],["ModuleNotFoundError: PRIVATE",'import'],["can't open file PRIVATE",'path'],['PermissionError PRIVATE','permission'],['SSLCertVerificationError PRIVATE','ssl'],['SyntaxError PRIVATE','syntax'],['Address already in use PRIVATE','listen'],['PRIVATE-TOKEN-URL','unknown']] as const)assert.equal(startupStderrReason(text),reason);
const original=globalThis.fetch;globalThis.fetch=async()=>{throw Error('No external transport in synthetic control');};
try{
 for(const scenario of ['ready','import','large','boot_exit','cleanup']as const){
  const calls:string[]=[];let finish:(value:number)=>void=()=>{};
  const exit=new Promise<number>(resolve=>{finish=resolve;});
  const text=scenario==='import'?'ModuleNotFoundError: PRIVATE-TOKEN-URL':scenario==='large'?'ImportError '+ 'PRIVATE'.repeat(9000):'';
  const container={running:false,images:{cpu:'approved-image@sha256:fixed'},
   start(options:any){calls.push('start');assert.equal(options.image,this.images.cpu);assert.equal(options.instance,'standard-3');assert.equal(options.enableInternet,false);assert.deepEqual(options.entrypoint,['/usr/bin/sleep','infinity']);assert.deepEqual(Object.keys(options.env).sort(),['CONTAINER_TOKEN','MEDIA_HOSTS']);assert.equal(options.env.MEDIA_HOSTS,'media.invalid');assert.ok(options.env.CONTAINER_TOKEN.includes('synthetic'));this.running=scenario!=='boot_exit';},
   monitor(){return scenario==='boot_exit'?Promise.reject(Object.assign(new Error('PRIVATE'),{exitCode:1})):new Promise<void>(()=>{});},
   async setInactivityTimeout(ms:number){assert.equal(ms,15_000);},
   async exec(command:string[],options:any){calls.push('exec');assert.deepEqual(command,['/usr/bin/timeout','--kill-after=2','8','/usr/local/bin/python3','/app/http_adapter.py']);assert.equal(options.cwd,'/app');assert.equal(options.user,'10001:10001');assert.equal(options.env.MEDIA_HOSTS,'media.invalid');assert.deepEqual(Object.keys(options.env).sort(),['CONTAINER_TOKEN','MEDIA_HOSTS']);if(scenario!=='ready'&&scenario!=='cleanup')finish(1);return{stdout:new Response('').body,stderr:new Response(text).body,exitCode:exit};},
   getTcpPort(port:number){assert.equal(port,8080);return{async fetch(url:string){calls.push('ready');assert.equal(url,'http://container/ready');finish(scenario==='ready'||scenario==='cleanup'?124:1);return scenario==='ready'||scenario==='cleanup'?Response.json({ready:true,provider_dispatch:false}):new Response('unavailable',{status:503});}};},
   async destroy(){calls.push('destroy');this.running=false;if(scenario==='cleanup')throw Error('PRIVATE-CLEANUP');}
  };
  const result=await startupControl(container as unknown as Container);
  assert.equal(calls.filter(x=>x==='start').length,1);assert.equal(calls.filter(x=>x==='destroy').length,1);
  if(scenario==='boot_exit'){assert.equal(result.reason,'process_exit');assert.equal(result.exit_code,1);assert.ok(!calls.includes('exec'));}
  else if(scenario==='ready'){assert.equal(result.reason,'ready');assert.equal(result.python_ready,true);assert.equal(result.exit_code,124);}
  else if(scenario==='cleanup'){assert.equal(result.phase,'cleanup');assert.equal(result.cleanup_complete,false);}
  else {assert.equal(result.reason,'import');assert.equal(result.exit_code,1);if(scenario==='large')assert.equal(result.output_truncated,true);}
  assert.equal(result.cleanup_complete,scenario!=='cleanup');assert.ok(!JSON.stringify(result).includes('PRIVATE'),'no raw subprocess content leaves control');
 }
}finally{globalThis.fetch=original;}
console.log('Fixed synthetic startup control: exact image/network/env/commands, bounded closed stderr, process exit, cleanup and no external transport passed.');
