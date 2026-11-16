// Whole deployed handler with actual bounded MP4 parser and closed transports.
// The local PostgreSQL suite separately verifies the publication RPC itself.
import {assert,assertEquals} from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {propertyMP4Fixture} from '../_shared/property-video-mp4-fixture_test.ts';
const id=(i:number)=>`e6000000-0000-4000-8000-${String(i).padStart(12,'0')}`;
const actor=id(1),org=id(2),listing=id(3),asset=id(4),poster=id(5),source=id(6),operation=id(7),render=id(8);
for(const[k,v]of Object.entries({SUPABASE_URL:'https://photo-publication.fixture.invalid',SUPABASE_SERVICE_ROLE_KEY:'inert-fixture',SUPABASE_ANON_KEY:'inert-public',CLOUDFLARE_ACCOUNT_ID:'b'.repeat(32),R2_ACCESS_KEY_ID:'inert-fixture',R2_SECRET_ACCESS_KEY:'inert-fixture'}))Deno.env.set(k,v);
let handler!:(req:Request)=>Promise<Response>;const old=Object.getOwnPropertyDescriptor(Deno,'serve')!;Object.defineProperty(Deno,'serve',{configurable:true,value:(h:typeof handler)=>{handler=h;return{};}});try{await import('./index.ts');}finally{Object.defineProperty(Deno,'serve',old);}
async function invoke(options:{superseded?:boolean;posterMissing?:boolean;keyMismatch?:boolean;portrait?:boolean;changed?:boolean;withdrawn?:boolean;route?:'ordinary-create'|'ordinary-publish';sourceKey?:string;posterKey?:string;photoProfile?:'photo-motion-v1-cfr24'|'photo-motion-v2-cfr24'|'photo-motion-v2-opening-cfr24';photoTimelineMismatch?:boolean}={}){
 const previous=globalThis.fetch,rpcs:Array<{name:string;args:Record<string,unknown>}>=[],
 f=propertyMP4Fixture({width:options.portrait?1080:1920,height:options.portrait?1920:1080,seconds:options.photoProfile?(options.photoTimelineMismatch?3:options.photoProfile==='photo-motion-v2-opening-cfr24'?7:2):15,fps:options.photoProfile?24:30}),
 key=`renders/${org}/${listing}/finished.mp4`;let heads=0;
 globalThis.fetch=async(raw,init)=>{const req=new Request(raw,init),url=new URL(req.url);
 if(url.hostname==='photo-publication.fixture.invalid'){
 if(url.pathname==='/auth/v1/user')return Response.json({id:actor,is_anonymous:false});if(url.pathname.endsWith('/deletion_requests'))return Response.json(null);
 if(url.pathname.endsWith('/capture_assets'))return Response.json({id:asset,listing_id:listing,storage_key:url.searchParams.get('id')===`eq.${poster}`?(options.posterKey??`renders/${org}/${listing}/poster.jpg`):(options.sourceKey??key)});if(url.pathname.endsWith('/listings'))return Response.json({org_id:org});
 if(url.pathname.endsWith('/render_jobs'))return Response.json({id:operation,listing_id:listing,capture_asset_id:asset});
 if(url.pathname.endsWith('/renders'))return Response.json({id:render});
 if(url.pathname.includes('/rpc/')){const name=url.pathname.split('/').at(-1)!,args=await req.json();rpcs.push({name,args});
 if(name==='listing_library_scope')return Response.json({actor_id:actor,org_id:org,listing_id:listing,library_org_id:org,listing_owner_user_id:actor,library_owner_user_id:actor,billing_org_id:org,team_org_id:null,role:'owner',access_mode:'own',can_read:true,can_write:true,can_manage_subscription:true});
 if(name==='subscription_trial_video_context')return Response.json({required:false});
 if(name==='property_owned_upload')return Response.json({actor_id:actor,org_id:org,listing_id:listing,asset_id:asset,bucket:'renders',storage_key:key,bytes:f.total,etag:'"fixture-version"',content_type:'video/mp4',...(options.photoProfile?{sha256:'a'.repeat(64)}:{})});
 if(name==='background_video_delivery'){
 assertEquals(args,{p_actor:actor,p_org:org,p_listing:listing,p_key:key,p_bytes:0});
 return options.photoProfile?Response.json({kind:'registered_background_video',asset_id:asset,bytes:f.total,sha256:'a'.repeat(64),quality_profile:options.photoProfile}):Response.json(null); // Native fixture has no registered server-master receipt.
 }
 if(name==='record_property_video_attestation')return Response.json({attested:true});
 if(name==='create_render_job')return Response.json({id:operation});
 if(name==='publish_recorded_render')return Response.json({id:render,job_id:operation,listing_id:listing,slug:'synthetic-recorded-tour',poster_key:`renders/${org}/${listing}/poster.jpg`});
 if(name==='publish_property_video')return options.superseded?Response.json({message:'RP409: publication_superseded: A newer selection replaced this request'},{status:400}):Response.json({id:render,listing_id:listing,slug:'synthetic-property-video',published_at:'2026-10-14T00:00:00Z'});
 if(name==='studio_presenter_media_visibility')return Response.json(Object.fromEntries(['assets','renders','keys'].map(k=>[k,Object.fromEntries(args[`p_${k}`].map((x:string)=>[x,!options.withdrawn]))])));
 throw Error('Unexpected closed RPC '+name);}
 }
 if(url.hostname==='b'.repeat(32)+'.r2.cloudflarestorage.com'){
 if(req.method==='HEAD'){heads++;return new Response(null,{headers:{etag:options.changed&&heads>1?'"changed"':'"fixture-version"','content-length':String(f.total),'content-type':'video/mp4'}});}
 assertEquals(req.method,'GET');const h=req.headers;assertEquals(h.get('if-match'),'"fixture-version"');return f.fetch(String(url),{method:'GET',redirect:'error',headers:h});
 }
 throw Error('No external transport permitted '+url.hostname);};
 try{const path=options.route==='ordinary-create'?'renders':options.route==='ordinary-publish'?`renders/${operation}/publish`:'renders/republish-app';
 const photoComposition=options.photoProfile?{schema:1,purpose:'listing',aspect:'16:9',branding_policy:'unbranded',source_mode:'photo_motion_v1',composition_profile:options.photoProfile,fps:24,total_frames:options.photoProfile==='photo-motion-v2-opening-cfr24'?168:48,sources:[{photo_asset_id:source,photo_version_id:`asset:${source}`,motion_kind:'photo_motion',source_bound:true,source_sha256:'a'.repeat(64),source_bytes:4,visible_frames:48,motion:'push_in'}],...(options.photoProfile==='photo-motion-v2-opening-cfr24'?{opening:{kind:'aerial_opening',position:0,aspect:'16:9',fps:24,visible_frames:120,available_frames:120}}:{})}:null;
 const body=options.route==='ordinary-create'?{listing_id:listing,asset_id:asset,tier:'smooth'}:options.route==='ordinary-publish'?{poster_asset_id:poster}:{listing_id:listing,asset_id:asset,poster_asset_id:options.posterMissing?null:poster,presentation_kind:'photo_video',publication_id:operation,composition:photoComposition??{schema:1,purpose:'listing',aspect:'16:9',branding_policy:'unbranded',sources:[{photo_asset_id:source,photo_version_id:'selected-staged-version.jpg',motion_kind:'original_photo'}]}};
 const req=new Request(`https://app.fixture.invalid/${path}`,{method:'POST',headers:{authorization:'Bearer inert','content-type':'application/json','x-org-id':org,'idempotency-key':`photo-video:${options.keyMismatch?id(99):operation}`},body:JSON.stringify(body)});
 const result=await handler(req);return{status:result.status,body:await result.json(),rpcs};}finally{globalThis.fetch=previous;}
}
Deno.test('actual photo publish acknowledges exact operation/output/property/private-library and verified geometry',async()=>{
 const r=await invoke();assertEquals(r.status,200);assertEquals([r.body.publication_id,r.body.presentation_asset_id,r.body.presentation_kind,r.body.listing_id,r.body.org_id,r.body.library_org_id],[operation,asset,'photo_video',listing,org,org]);
 const publish=r.rpcs.find(x=>x.name==='publish_property_video')!;assertEquals(publish.args.p_poster,poster);assertEquals(publish.args.p_key,`photo-video:${operation}`);assertEquals((publish.args.p_manifest as any).sources[0].photo_version_id,'selected-staged-version.jpg');
 const registered=r.rpcs.findIndex(x=>x.name==='background_video_delivery'),attested=r.rpcs.findIndex(x=>x.name==='record_property_video_attestation');
 assert(registered>=0&&registered<attested);assert(attested<r.rpcs.findIndex(x=>x.name==='publish_property_video'));assert(r.body.share_url.endsWith('/f/synthetic-property-video'));
});
Deno.test('missing poster,mismatched operation,portrait and changed source refuse before publication; revoked media never acknowledges success',async()=>{
 for(const[o,status]of [[{posterMissing:true},400],[{keyMismatch:true},400],[{portrait:true},400],[{changed:true},409]]as const){const r=await invoke(o);assertEquals(r.status,status);assert(!r.rpcs.some(x=>x.name==='publish_property_video'));}
 assertEquals((await invoke({withdrawn:true})).status,404);
});
Deno.test('only definitive superseded operation returns publication_superseded for native pending-intent retirement',async()=>{
 const r=await invoke({superseded:true});assertEquals(r.status,409);assertEquals(r.body.code,'publication_superseded');assert(!Object.hasOwn(r.body,'presentation_asset_id'));
});
Deno.test('ordinary render creation accepts walkthroughs and refuses allocated aerial sources before job creation',async()=>{
 const ordinary=await invoke({route:'ordinary-create'});assertEquals(ordinary.status,201);assert(ordinary.rpcs.some(x=>x.name==='create_render_job'));
 const aerial=await invoke({route:'ordinary-create',sourceKey:`renders/${org}/${listing}/aerial-opening/${operation}.mp4`});
 assertEquals(aerial.status,409);assert(!aerial.rpcs.some(x=>x.name==='create_render_job'));
});
Deno.test('recorded render publication refuses an allocated aerial poster before its publication RPC',async()=>{
 const aerial=await invoke({route:'ordinary-publish',posterKey:`renders/${org}/${listing}/aerial-review/${operation}/frame-0.jpg`});
 assertEquals(aerial.status,409);assert(!aerial.rpcs.some(x=>x.name==='publish_recorded_render'));
 const ordinary=await invoke({route:'ordinary-publish'});assertEquals(ordinary.status,201);assert(ordinary.rpcs.some(x=>x.name==='publish_recorded_render'));
});
Deno.test('Photo motion v1, v2 and opening publish only with their registered 24 fps timeline',async()=>{
 for(const profile of ['photo-motion-v1-cfr24','photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24'] as const){
  const ok=await invoke({photoProfile:profile});assertEquals(ok.status,200);
  assertEquals((ok.rpcs.find(x=>x.name==='publish_property_video')!.args.p_manifest as Record<string,unknown>).composition_profile,profile);
  const changed=await invoke({photoProfile:profile,photoTimelineMismatch:true});assertEquals(changed.status,409);
  assert(!changed.rpcs.some(x=>x.name==='publish_property_video'));
 }
});
