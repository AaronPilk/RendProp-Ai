// Run with tools/audit/run_studio_private_media.py; synthetic inputs and fixture-only credentials.
import {assertEquals,assertRejects,assert} from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {settleProjectPart,handleProjectMedia,projectMediaManifest,type ProjectMediaRow} from '../../../services/supabase/functions/studio/project-media.ts';
import {HttpError} from '../../../services/supabase/functions/_shared/http.ts';
import type {StudioContext} from '../../../services/supabase/functions/studio/context.ts';
const actor='11111111-1111-4111-8111-111111111111',org='22222222-2222-4222-8222-222222222222',id='33333333-3333-4333-8333-333333333333',hash='a'.repeat(64),other='b'.repeat(64),bytes=new Uint8Array([1,2,3]);
function setup(state='claimed',attempts=3){
 const calls:string[]=[],row:ProjectMediaRow={id,actor_id:actor,org_id:org,sha256:hash,bytes:3,mime:'video/mp4',filename:'private.mp4',modified:0,parts:1,write_deadline:new Date(Date.now()+60000).toISOString(),receipts:state?{'0':{state,bytes:3,sha256:hash}}:{}};
 const context={userId:actor,orgId:org,admin:{rpc:(name:string,p:Record<string,unknown>)=>({abortSignal:async(signal:AbortSignal)=>{
  signal.throwIfAborted();assertEquals(name,'studio_project_media_write');assertEquals(p.p_actor,actor);assertEquals(p.p_org,org);assertEquals(p.p_id,id);assertEquals(p.p_data,{part:0,bytes:3,sha256:hash});const action=p.p_action as string;calls.push(action);
  if(action==='claim'&&attempts>=3&&row.receipts['0']?.state!=='complete')return {error:{message:'RP409: Upload retry limit reached; existing data is preserved'}};
  if(action==='claim')row.receipts['0']={state:'claimed',bytes:3,sha256:hash};
  if(action==='finish')row.receipts['0']={state:'complete',bytes:3,sha256:hash};
  return {data:{dispatch:action==='claim',media:row},error:null};
 }})}} as unknown as StudioContext;
 return {context,row,calls};
}
Deno.test('three uncertain dispatches settle from exact HEAD proof without fourth PUT',async()=>{
 const f=setup();let heads=0,writes=0;const result=await settleProjectPart(f.context,id,0,bytes,hash,new AbortController().signal,{inspect:async key=>{heads++;assertEquals(key,`studio-project/${org}/${actor}/${id}/0`);return {bytes:3,sha256:hash};},write:async()=>{writes++;}});
 assertEquals(f.calls,['inspect','finish']);assertEquals([heads,writes],[1,0]);assertEquals(result.receipts['0'].state,'complete');
});
Deno.test('exhausted retry with absent stored bytes refuses another dispatch',async()=>{
 const f=setup();let writes=0;await assertRejects(()=>settleProjectPart(f.context,id,0,bytes,hash,new AbortController().signal,{inspect:async()=>null,write:async()=>{writes++;}}),HttpError,'retry limit');assertEquals(f.calls,['inspect','claim']);assertEquals(writes,0);
});
Deno.test('recovery rejects wrong HEAD size or SHA without finish or PUT',async()=>{
 for(const found of [{bytes:4,sha256:hash},{bytes:3,sha256:other}]){const f=setup();let writes=0;await assertRejects(()=>settleProjectPart(f.context,id,0,bytes,hash,new AbortController().signal,{inspect:async()=>found,write:async()=>{writes++;}}),HttpError,'does not match');assertEquals(f.calls,['inspect']);assertEquals(writes,0);}
});
Deno.test('fresh part never probes arbitrary storage and uses one admitted write',async()=>{
 const f=setup('',0);let heads=0,writes=0;await settleProjectPart(f.context,id,0,bytes,hash,new AbortController().signal,{inspect:async()=>{heads++;return null;},write:async()=>{writes++;}});assertEquals(f.calls,['inspect','claim','finish']);assertEquals([heads,writes],[0,1]);
});
Deno.test('client abort after HEAD cannot settle or dispatch a part',async()=>{
 const f=setup(),controller=new AbortController();let writes=0;await assertRejects(()=>settleProjectPart(f.context,id,0,bytes,hash,controller.signal,{inspect:async()=>{controller.abort();return {bytes:3,sha256:hash};},write:async()=>{writes++;}}),DOMException);assertEquals(f.calls,['inspect']);assertEquals(writes,0);
});
Deno.test('uncertain PUT preserves claim; a later request uses HEAD then settles',async()=>{
 const f=setup('',0);let writes=0;await assertRejects(()=>settleProjectPart(f.context,id,0,bytes,hash,new AbortController().signal,{inspect:async()=>null,write:async()=>{writes++;throw new Error('network lost after accepted write');}}),Error,'network lost');assertEquals(f.row.receipts['0'].state,'claimed');
 await settleProjectPart(f.context,id,0,bytes,hash,new AbortController().signal,{inspect:async()=>({bytes:3,sha256:hash}),write:async()=>{writes++;}});assertEquals(writes,1);assertEquals(f.calls,['inspect','claim','inspect','finish']);
});
Deno.test('completed part replays finish with neither HEAD nor PUT',async()=>{
 const f=setup('complete');let storage=0;await settleProjectPart(f.context,id,0,bytes,hash,new AbortController().signal,{inspect:async()=>{storage++;return null;},write:async()=>{storage++;}});assertEquals(storage,0);assertEquals(f.calls,['inspect','finish']);
});
Deno.test('pending request body cancellation cancels reader and reaches no RPC',async()=>{
 const f=setup(),controller=new AbortController();let cancelled=false;
 const body=new ReadableStream<Uint8Array>({cancel(){cancelled=true;}});
 const req=new Request(`https://fixture.invalid/studio/project-media/${id}/0`,{method:'PUT',headers:{'content-type':'application/octet-stream'},body,signal:controller.signal});
 const pending=handleProjectMedia(req,f.context);controller.abort();await assertRejects(()=>pending,DOMException);assert(cancelled);assertEquals(f.calls,[]);
});
Deno.test('oversized streaming body is rejected even when declared length is small',async()=>{
 const f=setup(),body=new ReadableStream<Uint8Array>({start(c){c.enqueue(new Uint8Array(8*1024*1024+1));c.close();}});
 const req=new Request(`https://fixture.invalid/studio/project-media/${id}/0`,{method:'PUT',headers:{'content-type':'application/octet-stream','content-length':'3'},body});
 await assertRejects(()=>handleProjectMedia(req,f.context),HttpError,'too large');assertEquals(f.calls,[]);
});
Deno.test('incomplete and malformed receipts never receive signed URLs',async()=>{
 for(const r of [setup().row,{...setup('complete').row,receipts:{'0':{state:'complete',bytes:4,sha256:hash}}}]){let signs=0;const result=await projectMediaManifest(r,async()=>{signs++;return 'https://fixture.invalid/never';});assertEquals(result.complete,false);assertEquals(signs,0);assertEquals(result.parts[0].url,undefined);}
 const r=setup('complete').row;const result=await projectMediaManifest(r,async(bucket,key,ttl)=>{assertEquals(key,`studio-project/${org}/${actor}/${id}/0`);assertEquals(ttl,120);return 'https://fixture.invalid/signed';});assertEquals(result.complete,true);
});
Deno.test('GET by content SHA applies both account and workspace before signing',async()=>{
 const filters:unknown[][]=[];const builder={select:()=>builder,eq:(key:string,value:unknown)=>{filters.push([key,value]);return builder;},abortSignal:()=>builder,maybeSingle:async()=>({data:null,error:null})};
 const context={userId:actor,orgId:org,admin:{from:(table:string)=>{assertEquals(table,'studio_project_media');return builder;}}} as unknown as StudioContext;
 const response=await handleProjectMedia(new Request('https://fixture.invalid/studio/project-media?sha256='+hash),context);assertEquals(await response.json(),{media:null});assertEquals(filters,[['actor_id',actor],['org_id',org],['sha256',hash]]);
});

function readFixture(){
 const row=setup('complete').row;row.write_deadline='2000-01-01T00:00:00Z';const events:string[]=[];
 let rejection:string|null=null,changed=false;
 const builder={select:()=>builder,eq:()=>builder,abortSignal:()=>builder,maybeSingle:async()=>{events.push('select');return {data:row,error:null};}};
 const context={userId:actor,orgId:org,admin:{from:()=>builder,rpc:(name:string,p:Record<string,unknown>)=>({abortSignal:async()=>{
  events.push('recheck');assertEquals(name,'studio_project_media_write');assertEquals(p,{p_actor:actor,p_org:org,p_id:id,p_action:'read',p_data:{}});
  return rejection?{error:{message:rejection}}:{data:changed?{...row,sha256:other}:row,error:null};
 }})}} as unknown as StudioContext;
 return {row,events,context,revoke:(message:string)=>{rejection=message;},change:()=>{changed=true;}};
}
Deno.test('membership or deletion revocation while signing returns no download response',async()=>{
 for(const reason of ['RP403: Workspace cannot access media','RP404: Original media unavailable']){
  const f=readFixture();let signs=0;
  await assertRejects(()=>handleProjectMedia(new Request('https://fixture.invalid/studio/project-media?id='+id),f.context,async row=>{
   f.events.push('sign');return await projectMediaManifest(row,async()=>{signs++;f.revoke(reason);return 'https://fixture.invalid/private-capability';});
  }),HttpError,reason.slice(7));assertEquals(signs,1);assertEquals(f.events,['select','sign','recheck']);
 }
});
Deno.test('expired upload deadline does not prevent separately authorized original download',async()=>{
 const f=readFixture();const response=await handleProjectMedia(new Request('https://fixture.invalid/studio/project-media?id='+id),f.context,async row=>{
  f.events.push('sign');return await projectMediaManifest(row,async()=> 'https://fixture.invalid/authorized');
 });assertEquals(response.status,200);assertEquals(response.headers.get('Cache-Control'),'private, no-store');assertEquals((await response.json()).media.parts[0].url,'https://fixture.invalid/authorized');assertEquals(f.events,['select','sign','recheck']);
});
Deno.test('row identity changed during signing rejects already prepared URLs',async()=>{
 const f=readFixture();await assertRejects(()=>handleProjectMedia(new Request('https://fixture.invalid/studio/project-media?id='+id),f.context,async row=>{
  f.change();return await projectMediaManifest(row,async()=> 'https://fixture.invalid/stale');
 }),HttpError,'saved original changed');assertEquals(f.events,['select','recheck']);
});
Deno.test('request canceled during signing never returns capability or performs final read',async()=>{
 const f=readFixture(),controller=new AbortController();await assertRejects(()=>handleProjectMedia(new Request('https://fixture.invalid/studio/project-media?id='+id,{signal:controller.signal}),f.context,async row=>{
  controller.abort();return await projectMediaManifest(row,async()=> 'https://fixture.invalid/stale');
 }),DOMException);assertEquals(f.events,['select']);
});
