// Run with tools/audit/run_studio_private_media.py; synthetic inputs and fixture-only credentials.
import {assertEquals,assertRejects,assert} from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {writeStudioChunk} from '../../../services/supabase/functions/_shared/r2.ts';
import {HttpError} from '../../../services/supabase/functions/_shared/http.ts';
const hash='a'.repeat(64),key='studio-project/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333/0';
async function mocked(status:number,head:{size?:number;hash?:string;status?:number}={},fail=false){
 const calls:Request[]=[];const original=globalThis.fetch;
 globalThis.fetch=async(input,init)=>{const req=new Request(input,init);calls.push(req);assert(req.url.startsWith('https://fixture-account.r2.cloudflarestorage.com/fixture-uploads/studio-project/'));assertEquals(req.redirect,'error');assert(req.signal);if(fail)throw new TypeError('synthetic connection lost');
  if(req.method==='PUT'){assertEquals(req.headers.get('if-none-match'),'*');assertEquals(req.headers.get('x-amz-meta-sha256'),hash);assertEquals(new Uint8Array(await req.arrayBuffer()),new Uint8Array([1,2,3]));return new Response(null,{status});}
  assertEquals(req.method,'HEAD');return new Response(null,{status:head.status??200,headers:{'content-length':String(head.size??3),'x-amz-meta-sha256':head.hash??hash}});
 };
 try {await writeStudioChunk(key,new Uint8Array([1,2,3]),hash);return {calls};}catch(error){return {calls,error};}finally{globalThis.fetch=original;}
}
Deno.test('R2 immutable first write and precondition replay require matching HEAD',async()=>{
 for(const status of [200,412]){const result=await mocked(status);assertEquals(result.error,undefined);assertEquals(result.calls.map(r=>r.method),['PUT','HEAD']);}
});
Deno.test('R2 uncertain HTTP or transport failure never auto-retries',async()=>{
 for(const [status,fail] of [[503,false],[200,true]] as const){const result=await mocked(status,{},fail);assert(result.error);assertEquals(result.calls.length,1);}
});
Deno.test('R2 successful PUT cannot settle without exact HEAD length and digest',async()=>{
 for(const head of [{size:4},{hash:'b'.repeat(64)},{status:404},{status:503}]){const result=await mocked(200,head);assert(result.error instanceof HttpError);assertEquals(result.calls.map(r=>r.method),['PUT','HEAD']);}
});
Deno.test('R2 invalid storage key or oversized chunk never dispatches',async()=>{
 const original=globalThis.fetch;let called=0;globalThis.fetch=async()=>{called++;throw new Error('must not dispatch');};
 try{for(const k of ['../outside',key+'/extra',key.replace('/0','/16')])await assertRejects(()=>writeStudioChunk(k,new Uint8Array([1]),hash),HttpError);await assertRejects(()=>writeStudioChunk(key,new Uint8Array(8388609),hash),HttpError);assertEquals(called,0);}finally{globalThis.fetch=original;}
});
