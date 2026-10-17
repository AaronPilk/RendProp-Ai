import assert from'node:assert/strict';
import{build}from'esbuild';import{mkdtemp,rm}from'node:fs/promises';import{tmpdir}from'node:os';import path from'node:path';import{createRequire}from'node:module';
const directory=await mkdtemp(path.join(tmpdir(),'rendprop-photo-controller-'));
try{
 const target=path.join(directory,'controller.cjs');await build({entryPoints:['src/index.ts'],bundle:true,format:'cjs',platform:'node',alias:{'cloudflare:workers':path.resolve('tests/cloudflare-stub.ts')},outfile:target});
 const{PropertyVideoCPU,default:worker}=createRequire(import.meta.url)(target);
 const check='00000000-0000-4000-8000-000000000001',evidence='00000000-0000-4000-8000-000000000002',lease='00000000-0000-4000-8000-000000000003';
 const expires_at=new Date(Date.now()+590_000).toISOString();
 const input={bucket:'renders',key:'owned/source.jpg',etag:'"owned"',bytes:10,sha256:'a'.repeat(64),mime:'image/jpeg',url:'https://owned.example/source?signature=private'};
 const task={action:'prepare_photo_quality',policy:'photo-fixed-features-v1',check_id:check,evidence_id:evidence,lease_token:lease,expires_at,prepared_source:input,candidate:{...input,key:'owned/candidate.jpg',url:'https://owned.example/candidate?signature=private'}};
 const images=['source','candidate'].flatMap(role=>['whole','tl','tr','bl','br'].map(region=>({role,region,bytes:10,width:2,height:2,sha256:'b'.repeat(64),crop:{left:0,top:0,width:2,height:2}})));
 const manifest={policy:task.policy,prepared_sha256:input.sha256,candidate_sha256:input.sha256,parents:[],images};
 const prepared={check_id:check,evidence_id:evidence,lease_token:lease,manifest};
 const reserved=images.map(row=>({...row,bucket:'renders',key:`comparison/${row.role}/${row.region}.jpg`,mime:'image/jpeg',put_url:`https://owned.example/put/${row.role}/${row.region}?private=cap`,headers:{'content-length':'10','content-type':'image/jpeg','if-none-match':'*','x-amz-meta-sha256':row.sha256}}));
 const uploaded={check_id:check,evidence_id:evidence,lease_token:lease,receipts:reserved.map(({put_url,headers,...row})=>({...row,etag:'"uploaded"'}))};
 let data=null,diagnostic=null,alarm=null,status='prepared',receipt=prepared,heartbeat=200,callback=200,revoked=false;
 let ticks=0,reserves=0,finishes=0,failures=0,uploads=0,cpuExecutes=0,cpuStarts=0;
 const events=[];
 const sql={exec(query,...args){if(query.startsWith('CREATE'))return{toArray:()=>[]};if(query.startsWith('SELECT observation'))return{toArray:()=>diagnostic?[{observation:diagnostic}]:[]};if(query.startsWith('INSERT INTO diagnostic')){diagnostic=args[0];return{toArray:()=>[]};}if(query.startsWith('SELECT'))return{toArray:()=>data?[{state:data}]:[]};if(query.startsWith('INSERT')){data=args[0];events.push('persist');}if(query.startsWith('DELETE')){data=null;events.push('clear');}return{toArray:()=>[]};}};
 const container={running:false,images:{cpu:'verified@sha256:test'},start(options){assert.equal(options.enableInternet,false);assert.equal(options.instance,'standard-3');assert.ok(!('EDGE_SERVICE_ROLE_KEY'in options.env));this.running=true;cpuStarts++;},monitor(){return new Promise(()=>{});},async setInactivityTimeout(){},async destroy(){this.running=false;events.push('sleep');},async interceptOutboundHttps(_host,binding){this.binding=binding;},getTcpPort(){return{fetch:async(url,init)=>{const route=new URL(url).pathname;if(route==='/ready')return Response.json({ready:true});if(route==='/execute'){cpuExecutes++;assert.equal(JSON.parse(init.body).check_id,check);assert.ok(!('job_id'in JSON.parse(init.body)));return Response.json({task_id:'c'.repeat(64)},{status:202});}if(route==='/status')return Response.json({state:status,result:receipt});if(route==='/upload'){uploads++;assert.equal(JSON.parse(init.body).output.images.length,10);status='uploaded';receipt=uploaded;return Response.json({accepted:true},{status:202});}throw Error('unexpectedCPU');}};}};
 const ctx={storage:{sql,async setAlarm(value){alarm=value;},async deleteAlarm(){alarm=null;}},container,waitUntil(){},exports:{MediaEgress:({props})=>({props})}};
 const env={ENABLED:'true',EDGE_WORKER_URL:'https://authority.test.supabase.co/functions/v1/property-video-worker',EDGE_SERVICE_ROLE_KEY:'fixture-service',RENDER_TRIGGER_KEY:'fixture-trigger',MEDIA_HOSTS:'owned.example'};
 const saved=globalThis.fetch;
 globalThis.fetch=async(url,init)=>{
  const path=new URL(url).pathname;assert.ok(path.startsWith('/functions/v1/photo-quality-worker/'),'photo route never calls video authority');assert.equal(init.headers.apikey,'fixture-service');assert.equal(init.redirect,'manual');
  const route=path.split('/').at(-1),body=JSON.parse(init.body);assert.equal(body.check_id,check);assert.ok(!('job_id'in body));
  if(route==='tick'){ticks++;assert.ok(['slot-0','slot-1'].includes(body.worker_id));return Response.json(revoked?{check_id:check,action:'done'}:task);}
  if(route==='heartbeat')return Response.json({current:true},{status:heartbeat});
  if(route==='derivatives'){reserves++;assert.deepEqual(body.manifest,manifest);return Response.json({check_id:check,evidence_id:evidence,images:reserved,expires_at});}
  if(route==='derivatives-finish'){finishes++;assert.deepEqual(body.receipts,uploaded.receipts);assert.equal(JSON.parse(data).pendingCallback.path,'derivatives-finish');assert.equal(container.running,false);return Response.json({accepted:true},{status:callback});}
  if(route==='failure'){failures++;assert.deepEqual(body,{check_id:check,lease_token:lease,code:'cpu_photo_comparison_failed'});return Response.json({recorded:true});}
  throw Error('unexpected authority');
 };
 try{
  let cpu=new PropertyVideoCPU(ctx,env);
  assert.equal(await cpu.wakePhoto(check,'slot-0'),true);assert.equal(await cpu.wake(evidence,'slot-0'),false,'photo work cannot become video work');assert.equal(await cpu.wakePhoto(evidence,'slot-0'),false);
  await cpu.alarm();assert.ok(JSON.parse(data).taskID);assert.equal(ticks,1);assert.equal(cpuStarts,1);assert.equal(cpuExecutes,1);
  await cpu.alarm();assert.equal(reserves,1);assert.equal(uploads,1);assert.ok(container.binding.props.capabilities.every(x=>x.method==='PUT'),'output phase drops all source GET capabilities');
  await cpu.alarm();assert.ok(JSON.parse(data).pendingCallback);assert.equal(container.running,false);assert.equal(finishes,0);
  cpu=new PropertyVideoCPU(ctx,env);await cpu.alarm();assert.equal(finishes,1);assert.equal(data,null);assert.equal(alarm,null);assert.ok(events.indexOf('persist')<events.indexOf('sleep'));
  // Heartbeat authority revocation stops the active CPU without upload/finish.
  receipt=prepared;status='working';heartbeat=409;const before={uploads,finishes};await cpu.wakePhoto(check,'slot-1');await cpu.alarm();await cpu.alarm();assert.equal(data,null);assert.equal(container.running,false);assert.deepEqual({uploads,finishes},before);heartbeat=200;
  // Operational failure is a photo CPU failure, never a visual judgement or paid retry.
  status='failed';await cpu.wakePhoto(check,'slot-1');await cpu.alarm();await cpu.alarm();assert.equal(failures,1);assert.equal(data,null);
  // Persist callback before loss; retry this receipt only, no decode or supplier repeat.
  status='prepared';receipt=prepared;callback=503;await cpu.wakePhoto(check,'slot-1');await cpu.alarm();await cpu.alarm();await cpu.alarm();const beforeTicks=ticks,beforeExecutes=cpuExecutes;
  await cpu.alarm();assert.equal(JSON.parse(data).pendingCallback.path,'derivatives-finish');assert.equal(container.running,false);
  callback=200;cpu=new PropertyVideoCPU(ctx,env);await cpu.alarm();assert.equal(data,null);assert.equal(ticks,beforeTicks);assert.equal(cpuExecutes,beforeExecutes);
  // HTTP start is strict/private, exact identity, fixed two slots, and no broad queue drain.
  let addressed=[];const startEnv={...env,CPU:{getByName(slot){addressed.push(slot);return{async wakePhoto(id,s){assert.equal(id,check);assert.equal(s,slot);return slot==='slot-1';}};}}};
  const req=(body,auth='Bearer fixture-trigger')=>new Request('https://controller.test/photo-quality/start',{method:'POST',headers:{'Content-Type':'application/json',Authorization:auth},body:JSON.stringify(body)});
  const noAsync={waitUntil(){throw Error('kickoff cannot broad-drain a queue');}};
  assert.equal((await worker.fetch(req({check_id:check},'Bearer invalid'),startEnv,noAsync)).status,403);assert.deepEqual(addressed,[]);
  for(const body of[{job_id:check},{check_id:check,actor:'anything'},{check_id:'invalid'},{check_id:check,huge:'x'.repeat(400)}])assert.equal((await worker.fetch(req(body),startEnv,noAsync)).status,400);
  assert.deepEqual(addressed,[]);const accepted=await worker.fetch(req({check_id:check}),startEnv,noAsync);assert.equal(accepted.status,202);assert.deepEqual(await accepted.json(),{accepted:true,check_id:check});assert.deepEqual(addressed,['slot-0','slot-1']);
  addressed=[];assert.equal((await worker.fetch(req({check_id:check}),{...startEnv,ENABLED:'false'},noAsync)).status,503);assert.deepEqual(addressed,[]);
 }finally{globalThis.fetch=saved;}
 console.log('Actual photo DO/source: same2slots, independent identities, measured10object admission/upload/callback, durable restart, revocation, failure, strict kickoff passed.');
}finally{await rm(directory,{recursive:true,force:true});}
