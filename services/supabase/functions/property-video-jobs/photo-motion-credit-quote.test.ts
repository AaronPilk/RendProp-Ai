import {assert,assertEquals} from 'https://deno.land/std@0.224.0/assert/mod.ts';
for(const [key,value] of Object.entries({
  SUPABASE_URL:'https://pm-credit-db.fixture.invalid',
  SUPABASE_ANON_KEY:'public-fixture',SUPABASE_SERVICE_ROLE_KEY:'service-fixture',
  CLOUDFLARE_ACCOUNT_ID:'a'.repeat(32),R2_ACCESS_KEY_ID:'inert-fixture',
  R2_SECRET_ACCESS_KEY:'inert-fixture',
})) Deno.env.set(key,value);
const {handler}=await import('./index.ts');
const {jobInput}=await import('./input.ts');
const id=(n:number)=>`f6000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const actor=id(1),org=id(2),listing=id(3),operation=id(4),job=id(5);
const sources=[0,1,2].map((i)=>({photo_id:'photo-'+i,
  photo_asset_id:id(10+i),photo_version_id:'asset:'+id(10+i),
  photo_provenance_id:null,motion:'push_in',visible_frames:i?72:48,
  source_sha256:String(i+1).repeat(64),source_bytes:4096}));
const manifest={source_mode:'photo_motion_v1',composition_profile:'photo-motion-v2-cfr24',
  operation_id:operation,listing_id:listing,expected_org_id:org,purpose:'listing',
  aspect:'16:9',sources,allow_original_photo_fallback:false};
const manifestHash='a'.repeat(64),quoteHash='b'.repeat(64);
type Case={balance?:number;mode?:'credits'|'plan';header?:string|null;oldJob?:boolean;
  changedSource?:boolean;admissionLowBalance?:boolean;admissionQuoteChanged?:boolean};
async function call(path:string,options:Case={}){
  const seen:string[]=[];const oldFetch=globalThis.fetch;let quoteCalls=0;
  const credit=options.mode!=='plan';
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
          const source=sources.find(s=>s.photo_asset_id===args.p_asset)!;
          return response({actor_id:actor,org_id:org,listing_id:listing,
            asset_id:source.photo_asset_id,bucket:'uploads',
            storage_key:`uploads/${org}/${listing}/${source.photo_asset_id}.jpg`,
            bytes:4096,etag:'"photo"',content_type:'image/jpeg',
            sha256:options.changedSource?'0'.repeat(64):source.source_sha256});
        }
        if(name==='credit_photo_motion_review_quote'){quoteCalls++;
          const balance=options.admissionLowBalance&&quoteCalls>1?0:options.balance??10;
          return response(credit?{
          mode:'credits',active:true,credits:8,available_credits:balance,
          affordable:balance>=8,environment:'Production',
          manifest_sha256:manifestHash,quote_sha256:quoteHash,
        }:{mode:'plan',active:false});}
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
      assertEquals(req.method,'HEAD');
      return new Response(null,{headers:{etag:'"photo"','content-length':'4096',
        'content-type':'image/jpeg'}});
    }
    throw Error('No external request permitted: '+url.hostname);
  };
  try{
    const req=new Request('https://app.fixture.invalid/property-video-jobs'+path,{
      method:'POST',headers:{authorization:'Bearer inert-fixture','content-type':'application/json',
        'x-org-id':org,'idempotency-key':'property-video:'+operation,
        ...(options.header?{'x-rendprop-photo-motion-quote':options.header}:{})},
      body:JSON.stringify(manifest),
    });
    const result=await handler(req);
    const parsed=await result.json();
    return {status:result.status,body:parsed,seen};
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
Deno.test('accepted lost-reply replay cannot be blocked by spent balance',async()=>{
  const replay=await call('',{oldJob:true,balance:0,header:quoteHash});
  assertEquals(replay.status,202);
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
