import{assert,assertEquals}from'https://deno.land/std@0.224.0/assert/mod.ts';
const id=(n:number)=>`f8200000-0000-4000-8000-${String(n).padStart(12,'0')}`,org=id(1),actor=id(2),evidence=id(3),check=id(4),lease=id(5),secret='sb_secret_'+ 'x'.repeat(24);
for(const[k,v]of Object.entries({SUPABASE_URL:'https://qc-db.fixture.invalid',SUPABASE_ANON_KEY:'public-fixture',SUPABASE_SERVICE_ROLE_KEY:'legacy-fixture',SUPABASE_SECRET_KEYS:JSON.stringify({default:secret}),CLOUDFLARE_ACCOUNT_ID:'a'.repeat(32),R2_ACCESS_KEY_ID:'inert-fixture',R2_SECRET_ACCESS_KEY:'inert-fixture'}))Deno.env.set(k,v);
const{handler}=await import('./index.ts');const{startPhotoComparison}=await import('./client.ts');
// Complete structural JPEG fixture, not a photograph or codec-quality claim.
const jpeg=new Uint8Array([255,216,255,192,0,11,8,0,2,0,2,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]);
const sha=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',jpeg)),x=>x.toString(16).padStart(2,'0')).join('');
const root=`ai-router/${org}/photo-evidence/${actor}/${evidence}/`,file=(kind:string)=>({bucket:'renders',key:root+kind+'.jpg',bytes:jpeg.length,mime:'image/jpeg',width:2,height:2,sha256:sha});
const e={id:evidence,org_id:org,actor_id:actor,input:file('input'),output:file('candidate'),input_etag:'"retained-etag"',output_etag:'"retained-etag"'};
const images=['source','candidate'].flatMap(role=>['whole','tl','tr','bl','br'].map(region=>({...file('unused'),role,region,key:root+`checks/${check}/${role}-${region}.jpg`,crop:{left:0,top:0,width:2,height:2}})));
async function invoke(path:string,body:any={},options:{auth?:string|null;stale?:boolean;changed?:boolean;rawChanged?:boolean;state?:string;sourceBytes?:number;outputBytes?:number;queueUnavailable?:boolean;method?:string}={}){
 const scoped=structuredClone(e);if(options.sourceBytes!==undefined)scoped.input.bytes=options.sourceBytes;if(options.outputBytes!==undefined)scoped.output.bytes=options.outputBytes;
 const old=fetch,calls:string[]=[],rpcs:string[]=[],puts:any[]=[];globalThis.fetch=async(raw,init)=>{
  const req=new Request(raw,init),url=new URL(req.url);calls.push(req.method+' '+url.hostname+url.pathname);const response=(value:unknown,status=200)=>Response.json(value,{status});
  if(url.hostname==='qc-db.fixture.invalid'){
   assertEquals(req.headers.get('apikey'),secret);
   if(url.pathname.endsWith('/photo_quality_checks')){
    assertEquals(url.searchParams.get('select'),'id');assertEquals(url.searchParams.get('judge_started_at'),'is.null');assertEquals(url.searchParams.get('order'),'created_at.asc');
    const since=url.searchParams.get('created_at');assert(since?.startsWith('gt.'));assert(Math.abs(Date.parse(since!.slice(3))-(Date.now()-3600000))<5000);
    if(url.searchParams.get('state')==='eq.derivative_ready'){
     assertEquals(url.searchParams.get('automatic'),'eq.true');assertEquals(url.searchParams.get('limit'),'2');
     return options.queueUnavailable?response({message:'closed queue unavailable'},503):response([{id:id(6)},{id:id(7)}]);
    }
    assertEquals(url.searchParams.get('state'),'in.(pending,preparing)');assertEquals(url.searchParams.get('limit'),'20');return response([{id:check}]);
   }
   if(url.pathname.includes('/rpc/')){const name=url.pathname.split('/').at(-1)!,b=await req.json();rpcs.push(name);
    if(name==='photo_quality_claim')return response({action:options.state==='derivative_ready'?'judge':'prepare_photo_quality',evidence:scoped,check:{id:check,evidence_id:evidence,lease_token:lease,lease_until:new Date(Date.now()+600000).toISOString(),state:options.state??'preparing'}});
    if(name==='photo_quality_worker_scope'){if(options.stale)return response({message:'RP409: Photo comparison lease was superseded',code:'P0001'},400);assertEquals(b.p_check,check);assertEquals(b.p_lease,lease);return response({evidence:scoped,check:{id:check,derivatives:images}});}
    if(name==='photo_quality_derivatives_reserve')return response({check_id:check,evidence_id:evidence,parents:[],images});
    if(name==='photo_quality_derivatives_complete'){assertEquals(b.p_receipts,images.map(f=>({...f,etag:'"retained-etag"'})));return response({evidence:scoped,check:{state:'derivative_ready'}});}
    if(name==='photo_quality_heartbeat')return response(true);
    if(name==='photo_quality_cpu_failure'){assertEquals(b.p_code,'cpu_photo_comparison_failed');return response({check:{state:'pending'}});}
    throw Error('Unexpected RPC '+name);
   }
  }
  if(url.hostname==='a'.repeat(32)+'.r2.cloudflarestorage.com'){
   assertEquals(req.method==='HEAD'||req.method==='GET',true);const headers={'content-type':'image/jpeg','content-length':String(url.pathname.endsWith('/input.jpg')?scoped.input.bytes:url.pathname.endsWith('/candidate.jpg')?scoped.output.bytes:jpeg.length),etag:'"retained-etag"','x-amz-meta-sha256':options.changed?'f'.repeat(64):sha};
   return new Response(req.method==='HEAD'?null:options.rawChanged?new Uint8Array([...jpeg.slice(0,-1),0]):jpeg,{headers});
  }
  puts.push(req);throw Error('External transport forbidden '+url.hostname);
 };
 try{const headers:Record<string,string>={'content-type':'application/json'};const auth=options.auth===undefined?secret:options.auth;if(auth)headers.apikey=auth;const req=new Request('https://private.fixture.invalid/photo-quality-worker/'+path,{method:options.method??'POST',headers,...(options.method==='GET'?{}:{body:JSON.stringify(body)})});const response=await handler(req);return{status:response.status,body:await response.json(),calls,rpcs,puts};}finally{globalThis.fetch=old;}
}
Deno.test('exact modern service credential required before parsing, reads or claim',async()=>{for(const auth of[null,'public-fixture','sb_secret_wrong','eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.fake']){const r=await invoke('tick',{check_id:check,worker_id:'slot-0'},{auth});assertEquals(r.status,403);assertEquals(r.calls,[]);}});
Deno.test('CPU tick signs only exact saved source/candidate and returns separate photo-check identity',async()=>{const r=await invoke('tick',{check_id:check,worker_id:'slot-0'});assertEquals(r.status,200);assertEquals(r.body.action,'prepare_photo_quality');assertEquals(r.body.check_id,check);assertEquals(r.body.evidence_id,evidence);assertEquals(r.body.job_id,undefined);for(const k of['prepared_source','candidate']){assertEquals(Object.keys(r.body[k]).sort(),['bucket','key','etag','bytes','sha256','mime','url'].sort());assertEquals(r.body[k].sha256,sha);assertEquals(new URL(r.body[k].url).hostname,'a'.repeat(32)+'.r2.cloudflarestorage.com');}assert(!r.rpcs.some(n=>n.includes('cost')||n.includes('finish')));const ready=await invoke('tick',{check_id:check,worker_id:'slot-0'},{state:'derivative_ready'});assertEquals(ready.body.action,'done');assert(!ready.calls.some(c=>c.includes('r2.cloudflarestorage')));});
Deno.test('stale lease and changed exact evidence refuse before CPU capability',async()=>{const stale=await invoke('tick',{check_id:check,worker_id:'slot-0'},{stale:true});assertEquals(stale.status,409);assert(!stale.calls.some(c=>c.includes('r2.cloudflarestorage')));const changed=await invoke('tick',{check_id:check,worker_id:'slot-0'},{changed:true});assertEquals(changed.status,409);assert(!changed.calls.some(c=>c.startsWith('GET')));});
Deno.test('derivative capabilities bind exact reserved key,size,MIME,SHA and immutable PUT',async()=>{const r=await invoke('derivatives',{check_id:check,lease_token:lease,manifest:{untrusted_url:'https://evil.invalid'}});assertEquals(r.status,200);assertEquals(r.body.images.length,10);for(const f of r.body.images){assert(f.key.startsWith(root+`checks/${check}/`));assertEquals(f.headers,{'content-type':'image/jpeg','content-length':String(jpeg.length),'x-amz-meta-sha256':sha,'if-none-match':'*'});const url=new URL(f.put_url);assertEquals(url.hostname,'a'.repeat(32)+'.r2.cloudflarestorage.com');for(const h of['content-length','content-type','if-none-match','x-amz-meta-sha256'])assert(url.searchParams.get('X-Amz-SignedHeaders')?.includes(h));}assert(!r.calls.some(c=>c.includes('evil.invalid')));});
Deno.test('all ten measured derivative objects rehashed and header checked before ready callback',async()=>{const r=await invoke('derivatives-finish',{check_id:check,lease_token:lease,receipts:images});assertEquals(r.status,200);assertEquals(r.body.state,'derivative_ready');assertEquals(r.rpcs.at(-1),'photo_quality_derivatives_complete');assertEquals(r.calls.filter(c=>c.startsWith('GET')&&c.includes('r2.cloudflarestorage')).length,10);for(const options of[{changed:true},{rawChanged:true}]){const bad=await invoke('derivatives-finish',{check_id:check,lease_token:lease,receipts:images},options);assertEquals(bad.status,409);assert(!bad.rpcs.includes('photo_quality_derivatives_complete'));}const wrong=structuredClone(images);wrong[0].key=root+'unrelated.jpg';const bad=await invoke('derivatives-finish',{check_id:check,lease_token:lease,receipts:wrong});assertEquals(bad.status,409);assert(!bad.calls.some(c=>c.includes('r2.cloudflarestorage')));});
Deno.test('private queue and heartbeat/failure are bounded CPU-only metadata',async()=>{const q=await invoke('queue',null,{method:'GET'});assertEquals(q.body.checks,[{check_id:check}]);assertEquals(q.body.judges,[{check_id:id(6)},{check_id:id(7)}]);assertEquals(q.calls.length,2);assertEquals(q.rpcs,[]);const h=await invoke('heartbeat',{check_id:check,lease_token:lease});assertEquals(h.body.current,true);const f=await invoke('failure',{check_id:check,lease_token:lease,code:'cpu_photo_comparison_failed'});assertEquals(f.body.recorded,true);const bad=await invoke('failure',{check_id:check,lease_token:lease,code:'model_failed'});assertEquals(bad.status,400);assertEquals(bad.rpcs,[]);});
Deno.test('internal kickoff makes one bounded private request, never retries lost/foreign acknowledgments',async()=>{Deno.env.set('PHOTO_QUALITY_RENDER_URL','https://cpu.fixture.invalid');Deno.env.set('PHOTO_QUALITY_RENDER_TRIGGER_KEY','inert-private-trigger');for(const mode of['ok','lost','foreign']){const old=fetch;let calls=0;globalThis.fetch=async(raw,init)=>{calls++;const req=new Request(raw,init);assertEquals(req.url,'https://cpu.fixture.invalid/photo-quality/start');assertEquals(req.headers.get('authorization'),'Bearer inert-private-trigger');assertEquals(await req.json(),{check_id:check});if(mode==='lost')throw Error('lostack');return Response.json({accepted:true,check_id:mode==='foreign'?id(99):check},{status:202});};try{assertEquals(await startPhotoComparison(check),{started:mode==='ok'});assertEquals(calls,1);}finally{globalThis.fetch=old;}}});

Deno.test('CPU bridge permits exact9MB prepared receipt and refuses the next byte before storage capability',async()=>{
 const at=await invoke('tick',{check_id:check,worker_id:'slot-0'},{sourceBytes:9_000_000});assertEquals(at.status,200);assertEquals(at.body.prepared_source.bytes,9_000_000);
 const above=await invoke('tick',{check_id:check,worker_id:'slot-0'},{sourceBytes:9_000_001});assertEquals(above.status,409);assert(!above.calls.some(c=>c.includes('r2.cloudflarestorage')));
});

Deno.test('ready judge queue remains service-only and never hides a failed metadata read',async()=>{
 for(const auth of[null,'public-fixture','sb_secret_wrong']){const r=await invoke('queue',null,{method:'GET',auth});assertEquals(r.status,403);assertEquals(r.calls,[]);}
 const failed=await invoke('queue',null,{method:'GET',queueUnavailable:true});assertEquals(failed.status,503);assertEquals(failed.rpcs,[]);assert(failed.calls.every(c=>c.startsWith('GET')&&c.includes('qc-db.fixture.invalid')));assertEquals(failed.body.checks,undefined);assertEquals(failed.body.judges,undefined);
});

Deno.test('CPU bridge admits exact25MiB retained candidate without changing9MB source or exact hash authority',async()=>{
 const at=await invoke('tick',{check_id:check,worker_id:'slot-0'},{outputBytes:25*1024*1024});assertEquals(at.status,200);assertEquals(at.body.candidate.bytes,25*1024*1024);assertEquals(at.body.candidate.sha256,sha);
 const above=await invoke('tick',{check_id:check,worker_id:'slot-0'},{outputBytes:25*1024*1024+1});assertEquals(above.status,409);assertEquals(above.body.candidate,undefined);assert(!above.calls.some(c=>c.endsWith('/candidate.jpg')));
 const changed=await invoke('tick',{check_id:check,worker_id:'slot-0'},{outputBytes:25*1024*1024,changed:true});assertEquals(changed.status,409);assertEquals(changed.body.candidate,undefined);
});
