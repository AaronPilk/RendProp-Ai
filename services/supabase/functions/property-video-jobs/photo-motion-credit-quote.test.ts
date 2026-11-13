import {assert,assertEquals} from 'https://deno.land/std@0.224.0/assert/mod.ts';
for(const [key,value] of Object.entries({
  SUPABASE_URL:'https://pm-credit-db.fixture.invalid',
  SUPABASE_ANON_KEY:'public-fixture',SUPABASE_SERVICE_ROLE_KEY:'service-fixture',
  CLOUDFLARE_ACCOUNT_ID:'a'.repeat(32),R2_ACCESS_KEY_ID:'inert-fixture',
  R2_SECRET_ACCESS_KEY:'inert-fixture',
})) Deno.env.set(key,value);
const {handler}=await import('./index.ts');
const {jobInput}=await import('./input.ts');
const {definitelyUndersized,photoMotionPreflightBudget,preflightPhotoMotionSource}=await import('./photo-motion-preflight.ts');
const id=(n:number)=>`f6000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const actor=id(1),org=id(2),listing=id(3),operation=id(4),job=id(5);
function pngChunk(kind:string,data:Uint8Array):Uint8Array{
  const bytes=new Uint8Array(12+data.length),view=new DataView(bytes.buffer);
  view.setUint32(0,data.length);for(let i=0;i<4;i++)bytes[4+i]=kind.charCodeAt(i);
  bytes.set(data,8);let crc=0xffffffff;
  for(let i=4;i<8+data.length;i++){
    crc^=bytes[i];for(let bit=0;bit<8;bit++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);
  }
  view.setUint32(8+data.length,(crc^0xffffffff)>>>0);return bytes;
}
async function png(width:number,height:number):Promise<Uint8Array<ArrayBuffer>>{
  const rows=new Uint8Array(height*(1+width*3));
  const compressed=new Uint8Array(await new Response(new Blob([rows]).stream().pipeThrough(new CompressionStream('deflate'))).arrayBuffer());
  const ihdr=new Uint8Array(13);new DataView(ihdr.buffer).setUint32(0,width);new DataView(ihdr.buffer).setUint32(4,height);ihdr[8]=8;ihdr[9]=2;
  const chunks=[new Uint8Array([137,80,78,71,13,10,26,10]),pngChunk('IHDR',ihdr),pngChunk('IDAT',compressed),pngChunk('IEND',new Uint8Array())];
  const result=new Uint8Array(chunks.reduce((n,c)=>n+c.length,0));let at=0;for(const chunk of chunks){result.set(chunk,at);at+=chunk.length;}return result;
}
const adequate=await png(2400,1340),small=await png(1400,1050);
const changedBody=adequate.slice();changedBody[changedBody.length-20]^=1;
const sha=async(bytes:Uint8Array)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new Uint8Array(bytes))),n=>n.toString(16).padStart(2,'0')).join('');
const adequateSHA=await sha(adequate),smallSHA=await sha(small);
const sources=[0,1,2].map((i)=>({photo_id:'photo-'+i,
  photo_asset_id:id(10+i),photo_version_id:'asset:'+id(10+i),
  photo_provenance_id:null,motion:'push_in',visible_frames:i?72:48,
  source_sha256:adequateSHA,source_bytes:adequate.length}));
const manifest={source_mode:'photo_motion_v1',composition_profile:'photo-motion-v2-cfr24',
  operation_id:operation,listing_id:listing,expected_org_id:org,purpose:'listing',
  aspect:'16:9',sources,allow_original_photo_fallback:false};
const manifestHash='a'.repeat(64),quoteHash='b'.repeat(64);
type Case={balance?:number;mode?:'credits'|'plan';planBlocked?:boolean;header?:string|null;oldJob?:boolean;
  changedSource?:boolean;changedBody?:boolean;admissionLowBalance?:boolean;admissionQuoteChanged?:boolean;undersizedSource?:boolean;abortDuringRead?:boolean};
async function call(path:string,options:Case={}){
  const seen:string[]=[];const oldFetch=globalThis.fetch;let quoteCalls=0,reads=0;
  const controller=new AbortController();
  const credit=options.mode!=='plan';
  const requestSources=options.undersizedSource?sources.map((source,i)=>i?source:{...source,source_sha256:smallSHA,source_bytes:small.length}):sources;
  const requestManifest={...manifest,sources:requestSources};
  globalThis.fetch=async(input,init)=>{
    const req=new Request(input,init),url=new URL(req.url);
    const response=(value:unknown,status=200)=>Response.json(value,{status});
    if(url.hostname==='pm-credit-db.fixture.invalid'){
      if(url.pathname==='/auth/v1/user')return response({id:actor,is_anonymous:false});
      if(url.pathname.endsWith('/deletion_requests'))return response(null);
      if(url.pathname.endsWith('/property_video_job_sources'))return response(sources.map(()=>({state:'photo_motion'})));
      if(url.pathname.includes('/rpc/')){
        const name=url.pathname.split('/').at(-1)!;
        seen.push(name);const args=await req.json();
        if(name==='listing_library_scope')return response({actor_id:actor,org_id:org,
          listing_id:listing,library_org_id:org,listing_owner_user_id:actor,
          library_owner_user_id:actor,billing_org_id:org,team_org_id:null,
          role:'owner',access_mode:'own',can_read:true,can_write:true,
          can_manage_subscription:true});
        if(name==='property_video_operation_lookup')return response({operation_id:operation,
          listing_id:listing,org_id:org,selected_library_org_id:org,
          operation_closed:false,job_id:options.oldJob?job:null});
        if(name==='property_photo_reference'){
          const source=requestSources.find(s=>s.photo_asset_id===args.p_asset)!;
          return response({actor_id:actor,org_id:org,listing_id:listing,
            asset_id:source.photo_asset_id,bucket:'uploads',
            storage_key:`uploads/${org}/${listing}/${source.photo_asset_id}.png`,
            bytes:source.source_bytes,etag:'"photo"',content_type:'image/png',
            sha256:options.changedSource?'0'.repeat(64):source.source_sha256});
        }
        if(name==='credit_photo_motion_review_quote'){quoteCalls++;
          const balance=options.admissionLowBalance&&quoteCalls>1?0:options.balance??10;
          return response(credit?{
          mode:'credits',active:true,credits:8,available_credits:balance,
          affordable:balance>=8,environment:'Production',
          manifest_sha256:manifestHash,quote_sha256:quoteHash,
        }:{mode:'plan',active:false,...(options.planBlocked?{affordable:false}:{})});}
        if(name==='property_video_job_admit_photo_motion_quoted')
          assertEquals(args.p_quote_sha256,options.header??null);
        if(name==='property_video_job_admit_photo_motion_quoted'&&options.admissionQuoteChanged)
          return response({message:'RP409: Photo Motion credit quote changed before admission'},400);
        if(name==='property_video_job_admit_photo_motion_quoted'&&options.admissionLowBalance)
          return response({accepted:false,operation_closed:false,message:'RP402: Add credits before starting Photo Motion'});
        if(name==='property_video_job_admit_photo_motion_quoted'||
           name==='property_video_job_admit_photo_motion')return response({accepted:true,job:{
          id:job,operation_id:operation,actor_id:actor,org_id:org,library_org_id:org,
          listing_id:listing,source_count:3,manifest:args.p_manifest,
          manifest_sha256:manifestHash,state:'queued',quality_profile:'photo-motion-v2-cfr24',
          result:null,
        }});
        if(name==='property_video_job_scope')return response({id:job,operation_id:operation,
          actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,source_count:3,
          manifest:jobInput(manifest),manifest_sha256:manifestHash,state:'queued',
          quality_profile:'photo-motion-v2-cfr24',result:null});
        throw Error('Unexpected RPC '+name);
      }
    }
    if(url.hostname==='a'.repeat(32)+'.r2.cloudflarestorage.com'){
      const image=options.undersizedSource&&url.pathname.includes(id(10))?small:req.method==='GET'&&options.changedBody?changedBody:adequate;
      assert(['HEAD','GET'].includes(req.method));
      if(req.method==='GET')assertEquals(req.headers.get('if-match'),'"photo"');
      if(req.method==='GET')reads++;
      if(req.method==='GET'&&options.abortDuringRead)controller.abort();
      return new Response(req.method==='GET'?image:null,{headers:{etag:'"photo"','content-length':String(image.length),
        'content-type':'image/png'}});
    }
    throw Error('No external request permitted: '+url.hostname);
  };
  try{
    const req=new Request('https://app.fixture.invalid/property-video-jobs'+path,{
      method:'POST',headers:{authorization:'Bearer inert-fixture','content-type':'application/json',
        'x-org-id':org,'idempotency-key':'property-video:'+operation,
        ...(options.header?{'x-rendprop-photo-motion-quote':options.header}:{})},
      body:JSON.stringify(requestManifest),signal:controller.signal,
    });
    const result=await handler(req);
    const parsed=await result.json();
    return {status:result.status,body:parsed,seen,reads};
  }finally{globalThis.fetch=oldFetch;}
}

Deno.test('Review quote exposes credits and balance, never supplier cost or a job',async()=>{
  const r=await call('/credit-quote');
  assertEquals(r.status,200);assertEquals(r.body.mode,'credits');
  assertEquals(r.body.credits,8);assertEquals(r.body.available_credits,10);
  assertEquals(r.body.affordable,true);assertEquals(r.body.manifest_sha256,manifestHash);
  assert(!('maximum_supplier_cents' in r.body));
  assert(!r.seen.includes('property_video_job_admit_photo_motion_quoted'));
});
Deno.test('low wallet still shows exact Review charge and final Make does not admit',async()=>{
  const q=await call('/credit-quote',{balance:1});
  assertEquals(q.status,200);assertEquals(q.body.affordable,false);
  const final=await call('',{balance:1,header:quoteHash});
  assertEquals(final.status,402);assertEquals(final.body.code,'credit_balance_low');
  assertEquals(final.body.operation_closed,false);
  assert(!final.seen.includes('property_video_job_admit_photo_motion_quoted'));
});
Deno.test('final Make needs the displayed exact SHA and preserves plan path',async()=>{
  const absent=await call('');assertEquals(absent.status,409);
  assertEquals(absent.body.code,'credit_quote_changed');
  assertEquals(absent.body.admission_attempted,false);
  const changed=await call('',{header:'0'.repeat(64)});assertEquals(changed.status,409);
  assert(!changed.seen.includes('property_video_job_admit_photo_motion_quoted'));
  const accepted=await call('',{header:quoteHash});assertEquals(accepted.status,202);
  assertEquals(accepted.body.manifest_sha256,manifestHash);
  assert(accepted.seen.includes('property_video_job_admit_photo_motion_quoted'));
  const plan=await call('',{mode:'plan'});assertEquals(plan.status,202);
  const changedRoute=await call('',{mode:'plan',header:quoteHash});
  assertEquals(changedRoute.status,409);
});
Deno.test('exhausted legacy plan refuses before admission without closing the saved operation',async()=>{
  const review=await call('/credit-quote',{mode:'plan',planBlocked:true});
  assertEquals(review.status,200);
  assertEquals(review.body,{mode:'plan',active:false,affordable:false});
  const final=await call('',{mode:'plan',planBlocked:true});
  assertEquals(final.status,402);assertEquals(final.body.code,'plan_capacity');
  assertEquals(final.body.operation_closed,false);
  assertEquals(final.body.admission_attempted,false);
  assert(!final.seen.includes('property_video_job_admit_photo_motion_quoted'));
});
Deno.test('accepted lost-reply replay cannot be blocked by spent balance',async()=>{
  const replay=await call('',{oldJob:true,balance:0,header:quoteHash});
  assertEquals(replay.status,202);
  assertEquals(replay.reads,0);
  assertEquals(replay.seen.filter(s=>s==='property_video_job_admit_photo_motion').length,1);
  assert(!replay.seen.includes('credit_photo_motion_review_quote'));
});
Deno.test('wallet race after final preflight returns a retryable refreshed charge',async()=>{
  const race=await call('',{header:quoteHash,admissionLowBalance:true});
  assertEquals(race.status,402);assertEquals(race.body.code,'credit_balance_low');
  assertEquals(race.body.operation_closed,false);assertEquals(race.body.admission_attempted,true);
  assertEquals(race.body.credits,8);assertEquals(race.body.available_credits,0);
  assertEquals(race.body.manifest_sha256,manifestHash);
  assertEquals(race.seen.filter(s=>s==='credit_photo_motion_review_quote').length,2);
});
Deno.test('atomic admission route change reopens Review without starting a job',async()=>{
  const race=await call('',{header:quoteHash,admissionQuoteChanged:true});
  assertEquals(race.status,409);assertEquals(race.body.code,'credit_quote_changed');
  assertEquals(race.body.operation_closed,false);
  assertEquals(race.body.admission_attempted,false);
  assert(race.seen.includes('property_video_job_admit_photo_motion_quoted'));
});
Deno.test('changed source refuses before quoting or billing',async()=>{
  const r=await call('/credit-quote',{changedSource:true});
  assertEquals(r.status,409);
  assert(!r.seen.includes('credit_photo_motion_review_quote'));
});
Deno.test('actual undersized master refuses Review and fresh Make before quote, hold or admission',async()=>{
  for(const path of ['/credit-quote','']){
    const r=await call(path,{undersizedSource:true,header:quoteHash});
    assertEquals(r.status,422);
    assertEquals(r.body.code,'validation');
    assert(String(r.body.error).includes('too small for a 1080p Photo motion video'));
    assert(!r.seen.includes('credit_photo_motion_review_quote'));
    assert(!r.seen.includes('property_video_job_admit_photo_motion_quoted'));
  }
});
Deno.test('same ETag with different actual source bytes refuses before quote or admission',async()=>{
  for(const path of ['/credit-quote','']){
    const r=await call(path,{changedBody:true,header:quoteHash});
    assertEquals(r.status,409);
    assert(!r.seen.includes('credit_photo_motion_review_quote'));
    assert(!r.seen.includes('property_video_job_admit_photo_motion_quoted'));
  }
});
Deno.test('cancelled client during guarded source GET cannot quote or admit paid work',async()=>{
  for(const path of ['/credit-quote','']){
    const r=await call(path,{abortDuringRead:true,header:quoteHash});
    assertEquals(r.status,409);
    assertEquals(r.body.code,'conflict');
    assert(String(r.body.error).includes('request stopped before creating a video'));
    assert(!r.seen.includes('credit_photo_motion_review_quote'));
    assert(!r.seen.includes('property_video_job_admit_photo_motion_quoted'));
  }
});
Deno.test('the renderer crop and EXIF uncertainty admit adequate sources without a false size refusal',()=>{
  assertEquals(definitelyUndersized(1400,1050,'16:9'),true);
  assertEquals(definitelyUndersized(1400,782,'16:9'),true);
  assertEquals(definitelyUndersized(1400,1050,'9:16'),true);
  assertEquals(definitelyUndersized(2400,1340,'16:9'),false);
  assertEquals(definitelyUndersized(1340,2400,'9:16'),false);
  assertEquals(definitelyUndersized(2400,1340,'9:16'),false);
});
Deno.test('bounded preflight leaves overbound sources and fourth source to final renderer authority',async()=>{
  const budget=photoMotionPreflightBudget();let reads=0;
  const read=async(_source:any,_maximum=8*1024*1024)=>{reads++;return{bytes:adequate,sha256:adequateSHA};};
  await preflightPhotoMotionSource({bytes:9*1024*1024,content_type:'image/png'},'16:9',budget,undefined,read);
  assertEquals(reads,0);
  for(let i=0;i<4;i++)await preflightPhotoMotionSource({bytes:adequate.length,content_type:'image/png'},'16:9',budget,undefined,read);
  assertEquals(reads,3);
  assertEquals(budget.remainingReads,0);
});
Deno.test('a parser-unknown image is not falsely certified or refused by the early size check',async()=>{
  const unknown=adequate.slice();unknown[30]^=1;
  const unknownSHA=await sha(unknown);
  let reads=0;
  await preflightPhotoMotionSource({bytes:unknown.length,content_type:'image/png'},'16:9',photoMotionPreflightBudget(),undefined,
    async()=>{reads++;return{bytes:unknown,sha256:unknownSHA};});
  assertEquals(reads,1);
});
