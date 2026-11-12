// AI processor permission (v1/v2), the owner-only quality-test grant header and the
// published-disclosure route through the actual property-video-jobs handler and the
// actual whole-recipe quote (including the pinned native-4K Kie row). The new
// supplier-funding preflight is isolated in this historical permission fixture;
// handler.test.ts runs the unmodified handler to prove the FAL-only refusal.
// Auth/PostgREST/R2 transports are closed fixtures. The property_video_job_admit_v2
// answer applies the same permission rule as SQL (20261016110000), so a removed
// TypeScript fast path still meets the database refusal. No provider or network.
import{assert,assertEquals}from'https://deno.land/std@0.224.0/assert/mod.ts';
const id=(i:number)=>`f7000000-0000-4000-8000-${String(i).padStart(12,'0')}`;const actor=id(1),org=id(2),listing=id(3),operation=id(4),job=id(5),grant=id(6);
for(const[k,v]of Object.entries({SUPABASE_URL:'https://jobs-db.fixture.invalid',SUPABASE_ANON_KEY:'public-fixture',SUPABASE_SERVICE_ROLE_KEY:'service-fixture',CLOUDFLARE_ACCOUNT_ID:'a'.repeat(32),R2_ACCESS_KEY_ID:'inert-fixture',R2_SECRET_ACCESS_KEY:'inert-fixture'}))Deno.env.set(k,v);
const{handler:realHandler}=await import('./index.ts');const{variedJobInput}=await import('./variety.ts');const{jobInput}=await import('./input.ts');
const{KIE_PROPERTY_IDENTITY:KIE,KIE_PROPERTY_PROFILE:KIE_PROFILE}=await import('../_shared/property-video-kie.ts');
const handlerURL=new URL('./index.ts',import.meta.url);
const legacyHandlerText=(await Deno.readTextFile(handlerURL))
 .replace("import{admitFundedReelRecipe}from'../ai-video/reel-provider-admission.ts';","const admitFundedReelRecipe=async()=>{};")
 .replace(/from'([^']+)'/g,(_all,path:string)=>`from'${new URL(path,handlerURL).href}'`);
const{handler:legacyContractHandler}=await import('data:application/typescript,'+encodeURIComponent(legacyHandlerText));
let handler=legacyContractHandler;
const V1='property-video-jobs-v1',V2='property-video-jobs-v2',REVISION='processors-2026-10-16.1',STALE='processors-2026-10-01.0';
const CONTRACT={token:V2,disclosure_revision:REVISION,processors:['kie','anthropic'],profiles:[KIE_PROFILE]};
const sources=Array.from({length:3},(_,i)=>({photo_id:'selected-'+i,photo_asset_id:id(100+i),photo_version_id:'exact-staged-'+i,photo_provenance_id:null,motion:'push_in'}));
const body={operation_id:operation,listing_id:listing,expected_org_id:org,purpose:'listing',aspect:'16:9',sources,allow_original_photo_fallback:true};
// The pinned native-4K route row, exactly the frozen identity (the Kie quote reads it by id).
const KIE_ROW={id:KIE.route_id,task:KIE.task,position:1,provider:KIE.provider,model:KIE.model,unit:KIE.unit,unit_cents:KIE.unit_cents,capabilities:['i2v','1080p','5s','native4k','preserve_photo'],max_latency_s:1800,min_plan:'free',same_model_as:'kling_3_pro',privacy_tier:KIE.privacy_tier,enabled:true,retire_after:null,note:'pinned',params:{kie_mode:KIE.mode,sound:KIE.sound}};
type Options={consent?:string|null;disclosure?:string;grantHeader?:string;selector?:string;contract?:unknown;grantRefusal?:string;jobConsent?:string;jobProfile?:string;resume?:boolean;replay?:boolean;guest?:boolean};
type Result={status:number;body:any;headers:Headers;rpcs:{name:string;args:any}[];requests:string[]};
async function invoke(path='',method='POST',requestBody:unknown=body,options:Options={}):Promise<Result>{
 let resumed=false;const old=fetch,rpcs:{name:string;args:any}[]=[],requests:string[]=[];const current=options.contract===undefined?CONTRACT:options.contract as any;
 const j={id:job,operation_id:operation,actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,source_count:3,manifest_sha256:'a'.repeat(64),state:options.resume?'failed':'queued',consent_revision:options.jobConsent??V1,processor_consent:options.jobConsent===V2?{token:V2,disclosure_revision:REVISION,processors:CONTRACT.processors,recorded_at:'2026-10-16T00:00:00Z'}:null,kie_test_grant_id:null,quality_profile:options.jobProfile??'legacy',deadline:new Date(Date.now()+3600000).toISOString(),manifest:body,result:null};
 globalThis.fetch=async(raw,init)=>{const req=new Request(raw,init),url=new URL(req.url);requests.push(req.method+' '+url.pathname+url.search);const response=(x:unknown,status=200)=>Response.json(x,{status});
  if(url.hostname==='jobs-db.fixture.invalid'){
   if(url.pathname==='/auth/v1/user')return response({id:actor,is_anonymous:options.guest===true});
   if(url.pathname.endsWith('/deletion_requests'))return response(null);
   // Resume fixture: one retained, already-paid clip paused by CPU extraction (no new quote needed).
   if(url.pathname.endsWith('/property_video_job_sources'))return response(sources.map((_,i)=>options.resume&&i===0?{state:resumed?'processing':'failed',last_error:resumed?null:'cpu_extract_failed',receipt:{request_id:'paid-existing'},clip:{sha256:'e'.repeat(64)},generation_provenance_id:id(99),cpu_recoveries:resumed?1:0}:{state:options.resume?'ready':'pending'}));
   if(url.pathname.endsWith('/ai_routes')){if(url.searchParams.get('id')==='eq.'+KIE.route_id&&!url.searchParams.has('task'))return response([KIE_ROW]);return response(url.searchParams.get('task')==='eq.video.reel_clip'?[{id:'readonly-catalog-seedance',position:1,task:'video.reel_clip',provider:'fal',model:'bytedance/seedance/v1/pro/fast/image-to-video',unit:'second',unit_cents:4.86,capabilities:['i2v','1080p','5s','16:9','9:16'],max_latency_s:900,min_plan:'free',privacy_tier:'no_retention',enabled:true}]:[]);}
   if(url.pathname.endsWith('/app_config'))return response({value:{enabled:false}});
   if(url.pathname.includes('/rpc/')){const name=url.pathname.split('/').at(-1)!,args=await req.json();rpcs.push({name,args});
    if(name==='listing_library_scope')return response({actor_id:actor,org_id:org,listing_id:listing,library_org_id:org,listing_owner_user_id:actor,library_owner_user_id:actor,billing_org_id:org,team_org_id:null,role:'owner',access_mode:'own',can_read:true,can_write:true,can_manage_subscription:true});
    if(name==='property_video_quality_profile')return response(options.selector??'legacy');
    if(name==='org_entitlement')return response({plan:'team',renders_per_month:1000,photo_edits_per_month:1000,reels_per_month:1000,aerials_per_month:1000,topaz_per_month:1000,seats:100,cogs_ceiling_cents:1000000,price_cents:24900});
    if(name==='property_video_operation_lookup')return response({operation_id:operation,listing_id:listing,org_id:org,selected_library_org_id:org,operation_closed:false,message:null,job_id:options.replay?job:null});
    if(name==='property_photo_reference')return response({actor_id:actor,org_id:org,listing_id:listing,asset_id:args.p_asset,bucket:'uploads',storage_key:`uploads/${org}/${listing}/${args.p_asset}.jpg`,bytes:4,etag:'"source-etag"',content_type:'image/jpeg',sha256:'a'.repeat(64)});
    if(name==='property_video_quality_profile_for')return options.grantRefusal?response({message:options.grantRefusal,code:'P0001'},400):response(KIE_PROFILE);
    if(name==='property_video_prompt_recipe_quote')return response({profile:KIE_PROFILE,quality_identity:KIE,quote_profile:KIE_PROFILE,revision:'v1'});
    if(name==='property_video_processor_consent_current')return response(current);
    if(name==='property_video_job_admit_v2'){
     // The SQL permission rule: admit_v2's exact token shapes, then property_video_processor_consent_record.
     const c=args.p_consent;
     if(!c||typeof c!=='object'||![V1,V2].includes(c.token)||c.token===V1&&JSON.stringify(c)!==JSON.stringify({token:V1}))return response({message:'RP403: Allow AI processing of these selected photos before creating the video',code:'P0001'},400);
     if(c.token===V1&&args.p_quality_profile===KIE_PROFILE)return response({message:'RP403: Allow the listed AI processors for this native-4K video before creating it',code:'P0001'},400);
     if(c.token===V2&&(!current||Object.keys(c).sort().join(',')!=='disclosure_revision,token'||c.disclosure_revision!==current.disclosure_revision))return response({message:'RP403: Allow the current AI processor disclosure before creating this video',code:'P0001'},400);
     return response({accepted:true,job:j});
    }
    if(name==='property_video_job_enqueue'||name==='property_video_job_scope')return response(j);
    if(['property_video_compose_resume_available','property_video_missing_result_resume_available','property_video_submit_resume_available','property_video_delivery_resume_available','property_video_job_quality_resume_available','property_video_job_terminal_temporal_resume_block'].includes(name))return response(false);
    if(name==='property_video_job_resume'){resumed=true;return response({...j,state:'generating'});}
    throw Error('Unexpected closed RPC '+name);
   }
  }
  if(url.hostname==='a'.repeat(32)+'.r2.cloudflarestorage.com'){assertEquals(req.method,'HEAD');return new Response(null,{headers:{etag:'"source-etag"','content-length':'4','content-type':'image/jpeg'}});}
  throw Error('No external transport permitted '+url.hostname);};
 try{
  const headers:Record<string,string>={'content-type':'application/json',authorization:'Bearer inert-fixture','x-org-id':org,'idempotency-key':'property-video:'+operation};
  const consent=options.consent===undefined?V1:options.consent;if(consent!==null)headers['x-rendprop-ai-consent']=consent;
  if(options.disclosure!==undefined)headers['x-rendprop-ai-consent-disclosure']=options.disclosure;
  if(options.grantHeader!==undefined)headers['x-rendprop-quality-test-grant']=options.grantHeader;
  const response=await handler(new Request('https://app.fixture.invalid/property-video-jobs'+(path?'/'+path:''),{method,headers,...(method==='GET'||method==='OPTIONS'?{}:{body:JSON.stringify(requestBody)})}));
  return{status:response.status,body:method==='OPTIONS'?null:await response.json(),headers:response.headers,rpcs,requests};
 }finally{globalThis.fetch=old;}
}
const admits=(r:Result)=>r.rpcs.filter(x=>x.name.startsWith('property_video_job_admit'));
const named=(r:Result,name:string)=>r.rpcs.filter(x=>x.name===name);
const context={operation_id:operation,listing_id:listing,selected_library_org_id:org};
const KIE_V1_COPY='Allow the listed AI processors for this native-4K video before creating it.',STALE_COPY='Allow the current AI processor disclosure before creating this video.';
/** The fast refusal: 403 processor_consent_required with the current contract, and no admission. */
function refusedWithContract(r:Result,error:string){
 assertEquals(r.status,403);
 assertEquals(r.body,{error,code:'processor_consent_required',...context,processor_consent:{token:V2,disclosure_revision:REVISION,processors:CONTRACT.processors}});
 assertEquals(r.headers.get('cache-control'),'no-store');assertEquals(admits(r),[]);
}
function refusedUnpublished(r:Result){
 assertEquals(r.status,403);assertEquals(r.body,{error:'The AI processor disclosure for this video is not published yet. No video was created.',code:'processor_disclosure_unpublished',...context});assertEquals(admits(r),[]);
}
/** Exactly one admit_v2 with exactly these arguments (never the old admit RPC). */
function admitted(r:Result,profile:string,consent:unknown,testGrant:string|null){
 assertEquals(r.status,202,JSON.stringify(r.body));assertEquals(r.body.job_id,job);
 const a=admits(r);assertEquals(a.map(x=>x.name),['property_video_job_admit_v2']);
 assertEquals(Object.keys(a[0].args).sort(),['p_actor','p_consent','p_manifest','p_quality_profile','p_quote','p_test_grant']);
 assertEquals([a[0].args.p_actor,a[0].args.p_quality_profile,a[0].args.p_consent,a[0].args.p_test_grant],[actor,profile,consent,testGrant]);
 // Identity and order pass through; the server freezes varied camera moves (variety.ts).
 assertEquals(a[0].args.p_manifest.sources.map((s:any)=>({...s,motion:undefined})),sources.map(s=>({...s,motion:undefined})));assertEquals(a[0].args.p_manifest.sources,variedJobInput(jobInput(body)).sources);assertEquals(a[0].args.p_manifest.operation_id,operation);
 return a[0].args;
}

Deno.test('v1 creates legacy/FAL work as before: admit_v2 gets exactly {token:v1} and no grant; no disclosure, grant or Kie read',async()=>{
 for(const options of[{},{disclosure:REVISION},{contract:null}]as Options[]){
  const r=await invoke('','POST',body,options);admitted(r,'legacy',{token:V1},null);
  assert(r.rpcs.some(x=>x.name==='property_video_quality_profile'),'the global selector decides');
  assert(!r.rpcs.some(x=>['property_video_processor_consent_current','property_video_quality_profile_for'].includes(x.name)));
  assert(!r.requests.some(x=>x.includes('id=eq.'+KIE.route_id)),'no pinned Kie read for a FAL recipe');
 }
});

Deno.test('v2 naming the current disclosure is passed through exactly for FAL work after one disclosure read',async()=>{
 const r=await invoke('','POST',body,{consent:V2,disclosure:REVISION});admitted(r,'legacy',{token:V2,disclosure_revision:REVISION},null);
 const names=r.rpcs.map(x=>x.name);assertEquals(named(r,'property_video_processor_consent_current').map(x=>x.args),[{}]);
 assert(names.indexOf('property_video_processor_consent_current')<names.indexOf('property_video_job_admit_v2'));
 // Boundary: a 200-character visible-ASCII revision is a valid permission.
 const long='r'.repeat(200),edge=await invoke('','POST',body,{consent:V2,disclosure:long,contract:{...CONTRACT,disclosure_revision:long}});
 admitted(edge,'legacy',{token:V2,disclosure_revision:long},null);
});

Deno.test('any other permission header is 403 consent_required before any database read',async()=>{
 for(const[label,options]of[['no permission',{consent:null}],['v2 without disclosure',{consent:V2}],['v2 empty disclosure',{consent:V2,disclosure:''}],
  ['v2 disclosure with a space',{consent:V2,disclosure:'rev 1'}],['v2 disclosure over 200',{consent:V2,disclosure:'r'.repeat(201)}],
  ['unknown token',{consent:'property-video-jobs-v3',disclosure:REVISION}],['case-changed token',{consent:'Property-Video-Jobs-V2',disclosure:REVISION}],
  ['disclosure without token',{consent:null,disclosure:REVISION}]]as [string,Options][]){
  const r=await invoke('','POST',body,options);assertEquals([r.status,r.body.code],[403,'consent_required'],label);assertEquals(r.rpcs,[],label);
 }
});

Deno.test('native-4K Kie recipe without v2 is refused 403 processor_consent_required with the current contract before admission',async()=>{
 const r=await invoke('','POST',body,{selector:KIE_PROFILE});refusedWithContract(r,KIE_V1_COPY);
 assert(r.requests.some(x=>x.includes('id=eq.'+KIE.route_id)),'the actual Kie whole-recipe quote decided the profile');
 assertEquals(named(r,'property_video_processor_consent_current').length,1);
});

Deno.test('a stale v2 revision is refused with the current contract, for Kie and FAL alike',async()=>{
 for(const selector of[KIE_PROFILE,'legacy'])refusedWithContract(await invoke('','POST',body,{selector,consent:V2,disclosure:STALE}),STALE_COPY);
});

Deno.test('no published disclosure: Kie (v1 or v2) and any v2 create are refused 403 processor_disclosure_unpublished',async()=>{
 for(const options of[{selector:KIE_PROFILE},{selector:KIE_PROFILE,consent:V2,disclosure:REVISION},{consent:V2,disclosure:REVISION}]as Options[])refusedUnpublished(await invoke('','POST',body,{...options,contract:null}));
 // A malformed published value is no disclosure (fail closed), never a pass.
 refusedUnpublished(await invoke('','POST',body,{selector:KIE_PROFILE,consent:V2,disclosure:REVISION,contract:{...CONTRACT,token:V1}}));
});

Deno.test('native-4K Kie with the current v2 permission is admitted with that exact permission and the Kie recipe quote',async()=>{
 const a=admitted(await invoke('','POST',body,{selector:KIE_PROFILE,consent:V2,disclosure:REVISION}),KIE_PROFILE,{token:V2,disclosure_revision:REVISION},null);
 assert(a.p_quote>=KIE.attempt_cents*sources.length,'priced at the native-4K attempt per shot plus QC');
});

Deno.test('owner quality-test grant: SQL picks the profile, the saved Kie profile is quoted and admit_v2 carries the grant',async()=>{
 const r=await invoke('','POST',body,{grantHeader:grant.toUpperCase(),consent:V2,disclosure:REVISION});
 const a=admitted(r,KIE_PROFILE,{token:V2,disclosure_revision:REVISION},grant);
 assertEquals(named(r,'property_video_quality_profile_for').map(x=>x.args),[{p_actor:actor,p_manifest:a.p_manifest,p_grant:grant}]);
 assert(!r.rpcs.some(x=>x.name==='property_video_quality_profile'),'the grant path quotes the SQL-chosen saved profile');
 const names=r.rpcs.map(x=>x.name);
 assert(names.indexOf('property_video_quality_profile_for')<names.indexOf('property_video_processor_consent_current')&&names.indexOf('property_video_processor_consent_current')<names.indexOf('property_video_job_admit_v2'));
 assert(r.requests.some(x=>x.includes('id=eq.'+KIE.route_id)));
 // A grant never replaces the permission: v1 under a grant is refused with the contract.
 const v1=await invoke('','POST',body,{grantHeader:grant});refusedWithContract(v1,KIE_V1_COPY);assertEquals(named(v1,'property_video_quality_profile_for').length,1);
 // SQL refuses a grant outside its scope (RP403): no quote, no admission.
 const outside=await invoke('','POST',body,{grantHeader:grant,consent:V2,disclosure:REVISION,grantRefusal:'RP403: This video is outside the owner quality-test permission'});
 assertEquals([outside.status,outside.body.error,outside.body.code],[403,'This video is outside the owner quality-test permission','forbidden']);
 assertEquals(admits(outside),[]);assert(!outside.requests.some(x=>x.includes('/ai_routes')));
});

Deno.test('a malformed grant header is 400 before any database read',async()=>{
 for(const value of['','not-a-grant',grant+'0',grant.slice(1),grant.replaceAll('-','')]){
  const r=await invoke('','POST',body,{grantHeader:value,consent:V2,disclosure:REVISION});
  assertEquals([r.status,r.body.error],[400,'Use a valid owner quality-test permission.'],value);assertEquals(r.rpcs,[],value);
 }
});

Deno.test('a lost-reply replay of an accepted operation is unchanged: saved job, no quote, disclosure read or admission',async()=>{
 for(const options of[{},{consent:V2,disclosure:STALE},{grantHeader:grant,consent:V2,disclosure:REVISION}]as Options[]){
  const r=await invoke('','POST',body,{...options,replay:true});assertEquals([r.status,r.body.job_id],[202,job]);
  assert(r.rpcs.some(x=>x.name==='property_video_job_enqueue'));
  assert(!r.rpcs.some(x=>['property_video_quality_profile','property_video_quality_profile_for','property_video_processor_consent_current'].includes(x.name)||x.name.startsWith('property_video_job_admit')));
 }
});

Deno.test('resume: v1 only for work saved under v1; v2 resumes any job; v1 never resumes a v2 native-4K job',async()=>{
 const RESUMED={p_actor:actor,p_job:job,p_quote:0};
 for(const[label,options]of[['v1 job, v1',{}],['v1 job, v2',{consent:V2}],['v2 job, v2',{consent:V2,jobConsent:V2,jobProfile:KIE_PROFILE}],
  ['v2 job, v2 with disclosure',{consent:V2,disclosure:REVISION,jobConsent:V2,jobProfile:KIE_PROFILE}]]as [string,Options][]){
  const r=await invoke(job+'/resume','POST',{},{...options,resume:true});
  assertEquals([r.status,r.body.job_id],[200,job],label);assertEquals(named(r,'property_video_job_resume').map(x=>x.args),[RESUMED],label);
 }
 const refused=await invoke(job+'/resume','POST',{},{resume:true,jobConsent:V2,jobProfile:KIE_PROFILE});
 assertEquals(refused.status,403);
 assertEquals(refused.body,{error:'Allow the listed AI processors for this native-4K video before resuming it.',code:'processor_consent_required',job_id:job,required_consent:V2});
 assertEquals(refused.rpcs.map(x=>x.name),['property_video_job_scope','property_video_job_scope'],'the photo-motion guard and consent check only read the saved job');
 for(const consent of[null,'property-video-jobs-v3']){const r=await invoke(job+'/resume','POST',{},{resume:true,consent});assertEquals([r.status,r.body.code],[403,'consent_required']);assertEquals(r.rpcs.map(x=>x.name),['property_video_job_scope']);}
});

Deno.test('GET /processor-consent returns the published contract or 404, for signed-in named users only',async()=>{
 const r=await invoke('processor-consent','GET',null,{consent:null});
 assertEquals(r.status,200);assertEquals(r.body,CONTRACT);assertEquals(r.headers.get('cache-control'),'no-store');
 assertEquals(r.rpcs,[{name:'property_video_processor_consent_current',args:{}}]);
 for(const contract of[null,{...CONTRACT,token:V1},{...CONTRACT,disclosure_revision:7},{...CONTRACT,processors:'kie'}]){
  const u=await invoke('processor-consent','GET',null,{consent:null,contract});
  assertEquals(u.status,404);assertEquals(u.body,{error:'The AI processor disclosure is not published yet.',code:'processor_disclosure_unpublished'});
 }
 const guest=await invoke('processor-consent','GET',null,{guest:true});assertEquals(guest.status,403);assertEquals(guest.rpcs,[]);
});

Deno.test('browser preflight allows the permission, disclosure and quality-test headers',async()=>{
 const pre=await invoke('','OPTIONS');const allowed=(pre.headers.get('access-control-allow-headers')??'').split(',').map(x=>x.trim());
 for(const header of['x-rendprop-ai-consent','x-rendprop-ai-consent-disclosure','x-rendprop-quality-test-grant'])assert(allowed.includes(header),header);
 assertEquals(pre.requests,[]);
});

Deno.test('compiled defect controls: each new permission guard is load-bearing',async()=>{
 const source=legacyHandlerText;
 const compiled=async(before:string,after:string)=>{assertEquals(source.split(before).length,2,'exact actual guard: '+before);return(await import('data:application/typescript,'+encodeURIComponent(source.replace(before,()=>after)))).handler;};
 const fails=(oracle:()=>void,label:string)=>{let caught=false;try{oracle();}catch{caught=true;}assert(caught,'control: '+label);};
 try{
  // 1. v1 accepted for Kie: the native-4K recipe reaches admission without v2 (only SQL is left).
  handler=await compiled('if(!kie&&consent.token!==CONSENT_V2)return null;','if(consent.token!==CONSENT_V2)return null;');
  const kie=await invoke('','POST',body,{selector:KIE_PROFILE});fails(()=>refusedWithContract(kie,KIE_V1_COPY),'v1 accepted for Kie');
  assertEquals(admits(kie).map(x=>x.args.p_consent),[{token:V1}]);assertEquals([kie.status,kie.body.code],[403,'forbidden']);
  // 2. Stale revision accepted: any v2 skips the current-disclosure comparison.
  handler=await compiled('if(consent.token===CONSENT_V2&&consent.disclosure_revision===current.disclosure_revision)return null;','if(consent.token===CONSENT_V2)return null;');
  const stale=await invoke('','POST',body,{selector:KIE_PROFILE,consent:V2,disclosure:STALE});fails(()=>refusedWithContract(stale,STALE_COPY),'stale revision accepted');
  assertEquals(admits(stale).length,1);
  // 3. Resume v1 for a v2 job: a native-4K job resumes under the original permission.
  handler=await compiled('if(token===CONSENT_V1&&j.consent_revision!==CONSENT_V1)return json(','if(false)return json(');
  const resumed=await invoke(job+'/resume','POST',{},{resume:true,jobConsent:V2,jobProfile:KIE_PROFILE});
  assertEquals(resumed.status,200,'control: v2 job resumed under v1');assertEquals(named(resumed,'property_video_job_resume').length,1);
  // 4. Grant header ignored: the owner-test scope never reaches SQL or admission.
  handler=await compiled('const grant=qualityTestGrant(req);','const grant=null;');
  const ignored=await invoke('','POST',body,{grantHeader:grant,consent:V2,disclosure:REVISION});
  assertEquals(named(ignored,'property_video_quality_profile_for'),[]);assertEquals(admits(ignored)[0].args.p_test_grant,null);
 }finally{handler=legacyContractHandler;}
 console.log('PROCESSOR_CONSENT_COMPILED_CONTROLS=4');
});
