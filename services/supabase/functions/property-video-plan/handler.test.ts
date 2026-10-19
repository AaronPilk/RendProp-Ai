// Actual route + real Responses adapter + real funded-attempt helpers. Auth,
// PostgREST,R2 and OpenAI transport are isolated synthetic boundaries.
import {assert,assertEquals} from 'https://deno.land/std@0.224.0/assert/mod.ts';

const id=(i:number)=>`e5000000-0000-4000-8000-${String(i).padStart(12,'0')}`;
const actor=id(1),org=id(2),listing=id(3),photos=Array.from({length:20},(_,i)=>({photo_id:`PRIVATE-ADDRESS-SENTINEL-${i}`,asset_id:id(i+10)}));
for(const[k,v]of Object.entries({SUPABASE_URL:'https://plan-db.fixture.invalid',SUPABASE_ANON_KEY:'public-fixture',SUPABASE_SERVICE_ROLE_KEY:'service-fixture',CLOUDFLARE_ACCOUNT_ID:'a'.repeat(32),R2_ACCESS_KEY_ID:'inert-fixture',R2_SECRET_ACCESS_KEY:'inert-fixture',OPENAI_API_KEY:'inert-fixture'}))Deno.env.set(k,v);
const {resetServingModeCache}=await import('../_shared/funded-serving.ts');
let handler!:(req:Request)=>Promise<Response>;const old=Object.getOwnPropertyDescriptor(Deno,'serve')!;Object.defineProperty(Deno,'serve',{configurable:true,value:(h:typeof handler)=>{handler=h;return{};}});try{await import('./index.ts');}finally{Object.defineProperty(Deno,'serve',old);}
async function invoke(options:{consent?:boolean;guest?:boolean;scope?:boolean;source?:boolean;changed?:boolean;invalid?:boolean;zero?:boolean;replay?:boolean;providerReject?:boolean;rate?:boolean;changedAfterResponse?:boolean;count?:number}={}){
 const selected=Array.from({length:options.count??20},(_,i)=>({photo_id:`PRIVATE-ADDRESS-SENTINEL-${i}`,asset_id:id(i+10)}));const original=globalThis.fetch,rpcs:Array<{name:string;args:Record<string,unknown>}>=[],ledgers:Record<string,unknown>[]=[],providerBodies:Record<string,unknown>[]=[],events:string[]=[];let heads=0;
 const response=(x:unknown,status=200)=>Response.json(x,{status});resetServingModeCache();
 globalThis.fetch=async(raw,init)=>{const req=new Request(raw,init),u=new URL(req.url);
 if(u.hostname==='plan-db.fixture.invalid'){
 if(u.pathname==='/auth/v1/user')return response({id:actor,is_anonymous:options.guest===true});
 if(u.pathname.endsWith('/deletion_requests'))return response(null);
 if(u.pathname.endsWith('/cost_ledger')){ledgers.push(await req.json());return new Response(null,{status:201});}
 if(u.pathname.includes('/rpc/')){const name=u.pathname.split('/').at(-1)!,args=await req.json();rpcs.push({name,args});events.push(name);
 if(name==='listing_library_scope')return response({actor_id:actor,org_id:org,listing_id:listing,library_org_id:org,listing_owner_user_id:actor,library_owner_user_id:actor,billing_org_id:org,team_org_id:null,role:'owner',access_mode:'own',can_read:!options.scope,can_write:!options.scope,can_manage_subscription:true});
 if(name==='property_owned_upload')return response({actor_id:actor,org_id:org,listing_id:options.source?id(99):listing,asset_id:args.p_asset,bucket:'uploads',storage_key:`uploads/${org}/${listing}/${args.p_asset}.jpg`,bytes:4,etag:'"source-etag"',content_type:'image/jpeg'});
 if(name==='studio_presenter_media_visibility')return response(Object.fromEntries(['assets','renders','keys'].map(k=>[k,Object.fromEntries((args[`p_${k}`]??[]).map((v:string)=>[v,true]))])));
 if(name==='serving_operation_begin')return response(options.replay?{replay:true,result:{schema:1,listing_id:listing,org_id:org,photos:[],model:'saved-fixture'}}:{begun:true});
 if(name==='report_provider_outcome')return response(null);if(name==='serving_mode')return response('ceiling');if(name==='bump_rate')return response(options.rate!==false);
 if(name==='serving_cost_reserve')return response({reserved:true});if(name==='serving_cost_finish')return response({finished:true});if(name==='serving_operation_complete')return response({saved:true});if(name==='serving_operation_no_dispatch')return response({finished:true});
 throw Error('Unexpected closed RPC '+name);}
 }
 if(u.hostname==='a'.repeat(32)+'.r2.cloudflarestorage.com'){assertEquals(req.method,'HEAD');heads++;return new Response(null,{headers:{etag:(options.changed&&heads>20||options.changedAfterResponse&&heads>40)?'"changed"':'"source-etag"','content-length':'4','content-type':'image/jpeg'}});}
 if(u.hostname==='api.openai.com'){assertEquals(u.pathname,'/v1/responses');assertEquals(req.method,'POST');const body=await req.json();providerBodies.push(body);events.push('provider');
 if(options.providerReject)return response({error:{message:'private-sentinel'}},401);
 return response({status:'completed',output_text:JSON.stringify({photos:options.invalid?[]:selected.slice(0,options.zero?0:selected.length).map((_,i)=>({index:i+1,scene:i===0?'unknown':'living',confidence:i===0?.2:.9,motion:i===0?'fly_through':'side_glide'}))}),usage:{input_tokens:1000,output_tokens:1000}});
 }
 throw Error('No external transport permitted '+u.hostname);};
 try{const headers={'content-type':'application/json',authorization:'Bearer inert-fixture','x-org-id':org,'idempotency-key':'plan-operation-fixture-1',...(options.consent===false?{}:{'x-rendprop-ai-consent':'property-video-plan-v1'})};
 const res=await handler(new Request('https://app.fixture.invalid/property-video-plan',{method:'POST',headers,body:JSON.stringify({listing_id:listing,expected_org_id:org,photos:options.zero?[]:selected})}));return{status:res.status,body:await res.json(),providerBodies,ledgers,rpcs,events,heads};}finally{globalThis.fetch=original;}
}
Deno.test('real route sends20 actual-owned low-detail images with strict schema after funded admission and returns all IDs safely',async()=>{
 const r=await invoke();assertEquals(r.status,200);assertEquals(r.body.photos.length,20);assertEquals(r.body.photos.map((p:{photo_id:string})=>p.photo_id),photos.map(p=>p.photo_id));assertEquals(r.body.photos[0].motion,'push_in');assertEquals(r.providerBodies.length,1);
 const body=r.providerBodies[0]as any;assertEquals(body.model,'gpt-5.6-terra');assertEquals(body.reasoning,{effort:'none'});assertEquals(body.max_output_tokens,1792);assertEquals(body.text.format.type,'json_schema');assertEquals(body.text.format.strict,true);const imageInputs=body.input[1].content.filter((x:any)=>x.type==='input_image');assertEquals(imageInputs.length,20);assert(imageInputs.every((x:any)=>x.detail==='low'&&new URL(x.image_url).hostname==='a'.repeat(32)+'.r2.cloudflarestorage.com'));assert(!JSON.stringify(body).includes('PRIVATE-ADDRESS-SENTINEL'));
 assert(r.events.indexOf('serving_cost_reserve')<r.events.indexOf('provider'));assertEquals(r.ledgers.length,1);assertEquals(r.ledgers[0].total_cents,1.4);assertEquals((r.ledgers[0].meta as any).cost_basis,'provider_reported_tokens_standard_rate_estimate');assertEquals(r.body.org_id,org);
});
Deno.test('missing consent,anonymous actor,scope/source/etag changes and empty source set never reach paid supplier',async()=>{
 for(const [o,status]of [[{consent:false},403],[{guest:true},403],[{scope:true},404],[{source:true},409],[{changed:true},409],[{zero:true},400],[{rate:false},429]]as const){const r=await invoke(o);assertEquals(r.status,status);assertEquals(r.providerBodies.length,0);assertEquals(r.ledgers.length,0);}
});
Deno.test('durable completed replay avoids another provider call and quote; invalid plan still accounts actual billed response',async()=>{
 const replay=await invoke({replay:true});assertEquals(replay.status,200);assertEquals(replay.providerBodies.length,0);assert(!replay.rpcs.some(r=>r.name==='serving_cost_reserve'));
 const invalid=await invoke({invalid:true});assertEquals(invalid.status,503);assertEquals(invalid.providerBodies.length,1);assertEquals(invalid.ledgers.length,1);assert(!invalid.rpcs.some(r=>r.name==='serving_operation_complete'));
 const refused=await invoke({providerReject:true});assertEquals(refused.status,503);assertEquals(refused.providerBodies.length,1);assertEquals(refused.ledgers.length,0,'401 is not invented billed AI usage');
});

Deno.test('compiled actual-route fault controls detect consent,source identity,replay,final freshness and plan-completeness removal',async()=>{
 const url=new URL('./index.ts',import.meta.url),source=await Deno.readTextFile(url);
 const originals=source.replace(/from '([^']+)'/g,(_all,path)=>`from '${new URL(path,url).href}'`);
 const changes:[string,string,string,Parameters<typeof invoke>[0],(r:Awaited<ReturnType<typeof invoke>>)=>boolean][]=[
  ['consent',"req.headers.get('x-rendprop-ai-consent')===PLAN_CONSENT",'true',{consent:false},r=>r.status===200&&r.providerBodies.length===1],
  ['source-listing','data.listing_id===body.listing_id','true',{source:true},r=>r.status===200&&r.providerBodies.length===1],
  ['durable-replay','funding=await fundingContext(user.id,org,req,body,(name,args)=>admin.rpc(name,args));','funding={actorId:user.id,orgId:org,requestKey:key!,operationBegun:true,rpc:(name,args)=>admin.rpc(name,args)};',{replay:true},r=>r.status===200&&r.providerBodies.length===1],
  ['final-source-fence','const photos=planOutput(response,body.photos);await assertNotDeleting(user.id);await contentOrgForUser(user.id,body.expected_org_id,body.listing_id,true);await checkSaved();','const photos=planOutput(response,body.photos);await assertNotDeleting(user.id);await contentOrgForUser(user.id,body.expected_org_id,body.listing_id,true);',{changedAfterResponse:true},r=>r.status===200&&r.providerBodies.length===1],
  ['all-photo-plan','const photos=planOutput(response,body.photos);','const photos=JSON.parse(response).photos;',{invalid:true},r=>r.status===200&&r.body.photos.length===0]
 ];
 const baseline=handler;
 for(const[name,before,after,options,leaked]of changes){assertEquals(originals.split(before).length,2,name+' exact compiled source guard');const d=Object.getOwnPropertyDescriptor(Deno,'serve')!;
 Object.defineProperty(Deno,'serve',{configurable:true,value:(h:typeof handler)=>{handler=h;return{};}});
 try{await import('data:application/typescript,'+encodeURIComponent(originals.replace(before,after)));}finally{Object.defineProperty(Deno,'serve',d);}
 try{assert(leaked(await invoke(options)),name+' control failed to reproduce specific unsafe behavior');}finally{handler=baseline;}}
});

Deno.test('real100-photo Responses request reserves and requests6912 outputtokens and validates every photo',async()=>{const r=await invoke({count:100});assertEquals(r.status,200);assertEquals(r.body.photos.length,100);const b=r.providerBodies[0]as any;assertEquals(b.max_output_tokens,6912);assertEquals(b.input[1].content.filter((x:any)=>x.type==='input_image').length,100);assertEquals(r.body.photos[99].photo_id,'PRIVATE-ADDRESS-SENTINEL-99');assertEquals(r.body.photos[99].asset_id,id(109));const cap=r.rpcs.find(x=>x.name==='serving_cost_reserve')!.args;const small=await invoke();assert(Number(cap.p_hold_cents)>Number(small.rpcs.find(x=>x.name==='serving_cost_reserve')!.args.p_hold_cents)*4,'100-photo reservation scales actual image and matching output bounds');const refused=await invoke({count:101});assertEquals(refused.status,400);assertEquals(refused.providerBodies.length,0);});
