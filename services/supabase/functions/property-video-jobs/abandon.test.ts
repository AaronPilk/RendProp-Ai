// C2 discard route and discarded-operation admission. The actual handler runs;
// only Auth/PostgREST/R2 transports are closed fixtures. No provider or network.
import{assert,assertEquals}from'https://deno.land/std@0.224.0/assert/mod.ts';
const id=(i:number)=>`f6000000-0000-4000-8000-${String(i).padStart(12,'0')}`;const actor=id(1),org=id(2),listing=id(3),operation=id(4),job=id(5),otherOrg=id(6);
for(const[k,v]of Object.entries({SUPABASE_URL:'https://jobs-db.fixture.invalid',SUPABASE_ANON_KEY:'public-fixture',SUPABASE_SERVICE_ROLE_KEY:'service-fixture',CLOUDFLARE_ACCOUNT_ID:'a'.repeat(32),R2_ACCESS_KEY_ID:'inert-fixture',R2_SECRET_ACCESS_KEY:'inert-fixture'}))Deno.env.set(k,v);
const{handler}=await import('./index.ts');
const sources=Array.from({length:3},(_,i)=>({photo_id:'selected-'+i,photo_asset_id:id(100+i),photo_version_id:'exact-'+i,photo_provenance_id:null,motion:'push_in'}));
const body={operation_id:operation,listing_id:listing,expected_org_id:org,purpose:'listing',aspect:'16:9',sources,allow_original_photo_fallback:false};
const DISCARDED='You discarded this saved request before the server accepted it. No video was started from it.';
// Server-side truth for one actor operation; the closed RPC fixture mirrors the SQL contract.
type Server={operation:'open'|'abandoned'|'refused'|'accepted';admission?:'accepted'|'discarded'};
type Options={key?:string|null;consent?:boolean;guest?:boolean;xOrg?:string};
async function invoke(path:string,requestBody:unknown,server:Server,options:Options={}){
 const old=fetch,rpcs:{name:string;args:any}[]=[],requests:string[]=[];
 const j={id:job,operation_id:operation,actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,source_count:3,manifest_sha256:'a'.repeat(64),state:'queued',quality_profile:'legacy',deadline:new Date(Date.now()+3600000).toISOString(),manifest:body,result:null};
 const closure=()=>({operation_id:operation,listing_id:listing,org_id:org,selected_library_org_id:org,operation_closed:server.operation==='abandoned'||server.operation==='refused',closed_reason:server.operation==='abandoned'?'abandoned':server.operation==='refused'?'capacity_refused':null,message:server.operation==='abandoned'?DISCARDED:server.operation==='refused'?'Capacity refused':null,job_id:server.operation==='accepted'?job:null});
 globalThis.fetch=async(raw,init)=>{const req=new Request(raw,init),url=new URL(req.url);requests.push(req.method+' '+url.hostname+url.pathname);const response=(x:unknown,status=200)=>Response.json(x,{status});
  if(url.hostname==='jobs-db.fixture.invalid'){
   if(url.pathname==='/auth/v1/user')return response({id:actor,is_anonymous:options.guest===true});
   if(url.pathname.endsWith('/deletion_requests'))return response(null);
   if(url.pathname.endsWith('/property_video_job_sources'))return response(sources.map(()=>({state:'pending',last_error:null,admission_retries:0,receipt:null,clip:null,generation_provenance_id:null,cpu_recoveries:0,lease_until:null})));
   if(url.pathname.endsWith('/ai_routes'))return response(url.searchParams.get('task')==='eq.video.reel_clip'?[{id:'readonly-catalog-seedance',position:1,task:'video.reel_clip',provider:'fal',model:'bytedance/seedance/v1/pro/fast/image-to-video',unit:'second',unit_cents:4.86,capabilities:['i2v','1080p','5s','16:9','9:16'],max_latency_s:900,min_plan:'free',privacy_tier:'no_retention',enabled:true}]:[]);
   if(url.pathname.endsWith('/app_config'))return response({value:{enabled:false}});
   if(url.pathname.includes('/rpc/')){const name=url.pathname.split('/').at(-1)!,args=await req.json();rpcs.push({name,args});
    if(name==='listing_library_scope')return response({actor_id:actor,org_id:org,listing_id:listing,library_org_id:org,listing_owner_user_id:actor,library_owner_user_id:actor,billing_org_id:org,team_org_id:null,role:'owner',access_mode:'own',can_read:true,can_write:true,can_manage_subscription:true});
    if(name==='property_video_quality_profile')return response('legacy');
    if(name==='org_entitlement')return response({plan:'team',renders_per_month:1000,photo_edits_per_month:1000,reels_per_month:1000,aerials_per_month:1000,topaz_per_month:1000,seats:100,cogs_ceiling_cents:1000000,price_cents:24900});
    if(name==='property_photo_reference')return response({actor_id:actor,org_id:org,listing_id:listing,asset_id:args.p_asset,bucket:'uploads',storage_key:`uploads/${org}/${listing}/${args.p_asset}.jpg`,bytes:4,etag:'"source-etag"',content_type:'image/jpeg',sha256:'a'.repeat(64)});
    if(name==='property_video_operation_lookup')return response(closure());
    // Discard tombstones only an operation the server never accepted or refused.
    if(name==='property_video_operation_abandon'){if(server.operation==='open')server.operation='abandoned';return response(closure());}
    if(name==='property_video_job_admit_v2'){assertEquals([args.p_consent,args.p_test_grant],[{token:'property-video-jobs-v1'},null]);if(server.admission==='discarded')return response({message:'RP409: This saved video request was discarded before the server accepted it. Start a new video instead.',code:'P0001'},400);server.operation='accepted';return response({accepted:true,job:j});}
    if(name==='property_video_job_enqueue'||name==='property_video_job_scope')return response(j);
    if(name==='studio_presenter_media_visibility')return response(Object.fromEntries(['assets','renders','keys'].map(k=>[k,Object.fromEntries((args['p_'+k]??[]).map((v:string)=>[v,true]))])));
    throw Error('Unexpected closed RPC '+name);
   }
  }
  if(url.hostname==='a'.repeat(32)+'.r2.cloudflarestorage.com'){assertEquals(req.method,'HEAD');return new Response(null,{headers:{etag:'"source-etag"','content-length':'4','content-type':'image/jpeg'}});}
  throw Error('No external transport permitted '+url.hostname+url.pathname);};
 try{
  const headers:Record<string,string>={'content-type':'application/json',authorization:'Bearer inert-fixture','x-org-id':options.xOrg??org,...(options.key===null?{}:{'idempotency-key':options.key??'property-video-abandon:'+operation}),...(options.consent?{'x-rendprop-ai-consent':'property-video-jobs-v1'}:{})};
  const response=await handler(new Request('https://app.fixture.invalid/property-video-jobs'+(path?'/'+path:''),{method:'POST',headers,body:JSON.stringify(requestBody)}));
  return{status:response.status,body:await response.json(),rpcs,requests};
 }finally{globalThis.fetch=old;}
}
const discard=(server:Server,options:Options={},path=`operations/${operation}/abandon`,requestBody:unknown={listing_id:listing,expected_org_id:org})=>invoke(path,requestBody,server,options);
const enqueue=(server:Server)=>invoke('',body,server,{key:'property-video:'+operation,consent:true});
const noWork=(rpcs:{name:string}[])=>!rpcs.some(x=>['property_video_job_admit','property_video_job_admit_v2','property_video_job_enqueue','property_video_job_cancel','property_video_job_cancel_all','org_entitlement'].includes(x.name));

Deno.test('discard of an unseen operation closes it durably without consent, quote, admission or media reads',async()=>{
 const server:Server={operation:'open'},r=await discard(server);
 assertEquals(r.status,200);
 assertEquals(r.body,{operation_id:operation,listing_id:listing,org_id:org,selected_library_org_id:org,operation_closed:true,closed_reason:'abandoned',message:DISCARDED,job:null});
 assertEquals(r.rpcs,[{name:'property_video_operation_abandon',args:{p_actor:actor,p_listing:listing,p_expected:org,p_operation:operation}}]);
 assert(!r.requests.some(x=>x.includes('r2.cloudflarestorage.com')),'discard never reads customer media');
 // A lost reply is retried against the same saved operation and gets the same answer.
 const replay=await discard(server);assertEquals(replay.status,200);assertEquals(replay.body,r.body);
});

Deno.test('discard of an accepted operation returns its existing job and never cancels it',async()=>{
 const r=await discard({operation:'accepted'});
 assertEquals(r.status,200);assertEquals(r.body.operation_closed,false);assertEquals(r.body.closed_reason,null);
 assertEquals(r.body.job.job_id,job);assertEquals(r.body.job.operation_id,operation);assertEquals(r.body.job.state,'queued');
 assert(noWork(r.rpcs),'accepted work keeps its normal cancellation/recovery flow');
});

Deno.test('discard reports a durable capacity refusal unchanged',async()=>{
 const r=await discard({operation:'refused'});
 assertEquals(r.status,200);assertEquals(r.body.operation_closed,true);assertEquals(r.body.closed_reason,'capacity_refused');assertEquals(r.body.job,null);assertEquals(r.body.message,'Capacity refused');
});

Deno.test('discard refuses a changed identity before any database decision',async()=>{
 for(const[label,options,path,requestBody,status]of[
  ['create key reused',{key:'property-video:'+operation},undefined,undefined,400],
  ['missing key',{key:null},undefined,undefined,400],
  ['extra recipe body',{},undefined,{listing_id:listing,expected_org_id:org,sources},400],
  ['missing listing',{},undefined,{expected_org_id:org},400],
  ['library switched',{xOrg:otherOrg},undefined,undefined,409],
  ['malformed operation',{key:'property-video-abandon:not-a-uuid'},'operations/not-a-uuid/abandon',undefined,400],
  ['guest',{guest:true},undefined,undefined,403],
 ]as const){
  const r=await discard({operation:'open'},options as Options,path,requestBody);
  assertEquals(r.status,status,label);assert(!r.rpcs.some(x=>x.name==='property_video_operation_abandon'),label+' never reaches the discard RPC');
 }
 // Canonical identity: an upper-case path/key pair names the same lowercase operation.
 const upper=await discard({operation:'open'},{key:'PROPERTY-VIDEO-ABANDON:'+operation.toUpperCase()},`operations/${operation.toUpperCase()}/abandon`);
 assertEquals(upper.status,200);assertEquals(upper.rpcs[0].args.p_operation,operation);
});

Deno.test('a delayed enqueue of a discarded operation is refused before quote or admission',async()=>{
 const r=await enqueue({operation:'abandoned'});
 assertEquals(r.status,409);
 assertEquals(r.body,{error:DISCARDED,code:'operation_abandoned',operation_closed:true,closed_reason:'abandoned',operation_id:operation,listing_id:listing,selected_library_org_id:org});
 assert(noWork(r.rpcs),'no quote, admission or job write');
});

Deno.test('an admission that loses the race to a discard is a conflict, never a job',async()=>{
 const r=await enqueue({operation:'open',admission:'discarded'});
 assertEquals(r.status,409);assert(String(r.body.error).includes('discarded'));assertEquals(r.body.job_id,undefined);
 assert(r.rpcs.some(x=>x.name==='property_video_job_admit_v2'),'the pre-check passed and the database fence decided');
 // The normal open path is unchanged: the same request admits one job.
 const accepted=await enqueue({operation:'open'});assertEquals(accepted.status,202);assertEquals(accepted.body.job_id,job);
});
