import {assert, assertEquals} from 'jsr:@std/assert@1';
const id = (n: number) => `f8000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const actor=id(1), org=id(2), listing=id(3);
const fixtureEnv={SUPABASE_URL:'https://selection-db.fixture.invalid', SUPABASE_ANON_KEY:'public-fixture', SUPABASE_SERVICE_ROLE_KEY:'service-fixture', CLOUDFLARE_ACCOUNT_ID:'a'.repeat(32), R2_ACCESS_KEY_ID:'inert-fixture', R2_SECRET_ACCESS_KEY:'inert-fixture', PRIVATE_MEDIA_DELIVERY:'off'};
function environment(){const before=new Map(Object.keys(fixtureEnv).map(key=>[key,Deno.env.get(key)]));for(const[key,value]of Object.entries(fixtureEnv))Deno.env.set(key,value);return()=>{for(const[key,value]of before)value===undefined?Deno.env.delete(key):Deno.env.set(key,value);};}
const restoreImport=environment();
const {handler}=await import('./index.ts').finally(restoreImport);
const key=(n:number,kind='gallery')=>`renders/${org}/${listing}/${kind}-${n}.jpg`;
const asset=(n:number,storage_key=key(n))=>({id:id(n),kind:'photo',bucket:'renders',storage_key,bytes:4,sha256:'a'.repeat(64),content_type:'image/jpeg'});
const photo=(n:number,enhanced_key:string|null=null)=>({id:id(n),original_key:key(n),enhanced_key,sort:n});
type Fixture={gallery?:string[]|null;photos:ReturnType<typeof photo>[];assets:ReturnType<typeof asset>[];refused?:string[]};

async function sources(f:Fixture,offset=0){
 const restoreEnv=environment(),originalFetch=globalThis.fetch, requests:Request[]=[],references:string[]=[];
 const list=(value:string|null)=>value?.slice(4,-1).split(',').map(s=>s.replace(/^"|"$/g,''))??[];
 globalThis.fetch=async(raw,init)=>{
  const request=new Request(raw,init),url=new URL(request.url);requests.push(request);
  assert(['selection-db.fixture.invalid','a'.repeat(32)+'.r2.cloudflarestorage.com'].includes(url.hostname),'No external transport permitted');
  if(url.hostname.endsWith('.r2.cloudflarestorage.com')){assertEquals(request.method,'HEAD');return new Response(null,{headers:{etag:'"source-etag"','content-length':'4','content-type':'image/jpeg'}});}
  if(url.pathname==='/auth/v1/user')return Response.json({id:actor,is_anonymous:false});
  if(url.pathname.endsWith('/rpc/listing_library_scope'))return Response.json({actor_id:actor,org_id:org,listing_id:listing,library_org_id:org,listing_owner_user_id:actor,library_owner_user_id:actor,billing_org_id:org,team_org_id:null,role:'owner',access_mode:'own',can_read:true,can_write:true,can_manage_subscription:true});
  if(url.pathname.endsWith('/rpc/property_photo_reference')){
   const body=await request.json();references.push(body.p_asset);
   const found=f.assets.find(a=>a.id===body.p_asset);
   if(!found||f.refused?.includes(body.p_asset))return Response.json({message:'RP404: Selected photo unavailable',code:'P0001'},{status:400});
   return Response.json({...found,asset_id:found.id,actor_id:actor,org_id:org,listing_id:listing,etag:'"source-etag"'});
  }
  if(url.pathname.endsWith('/listings')){assertEquals(url.searchParams.get('id'),'eq.'+listing);return Response.json([{gallery_asset_ids:f.gallery??null}]);}
  assertEquals(url.searchParams.get('listing_id'),'eq.'+listing,'Every source catalog read remains on the exact property');
  if(url.pathname.endsWith('/photos')){assertEquals(url.searchParams.get('order'),'sort.asc,created_at.asc,id.asc');return Response.json(f.photos);}
  if(url.pathname.endsWith('/media_provenance')||url.pathname.endsWith('/property_video_preparations'))return Response.json([]);
  if(url.pathname.endsWith('/capture_assets')){
   let rows=f.assets;
   if(url.searchParams.has('id'))rows=rows.filter(a=>list(url.searchParams.get('id')).includes(a.id));
   else if(url.searchParams.has('storage_key')&&url.searchParams.get('storage_key')!.startsWith('in.'))rows=rows.filter(a=>list(url.searchParams.get('storage_key')).includes(a.storage_key));
   else{assertEquals(url.searchParams.get('order'),request.method==='HEAD'?null:'created_at.asc,id.asc');rows=rows.filter(a=>a.storage_key.includes('/gallery-'));}
   if(request.method==='HEAD')return new Response(null,{headers:{'content-range':`*/${rows.length}`}});
   const start=Number(url.searchParams.get('offset')??0),limit=Number(url.searchParams.get('limit')??1000);
   return Response.json(rows.slice(start,start+limit));
  }
  throw Error('Unexpected closed source request '+url.pathname);
 };
 try{
  const response=await handler(new Request(`https://app.fixture.invalid/property-video-jobs/sources?listing_id=${listing}&expected_org_id=${org}&offset=${offset}`,{headers:{authorization:'Bearer inert-fixture','x-org-id':org}}));
  return {status:response.status,body:await response.json(),requests,references};
 }finally{globalThis.fetch=originalFetch;restoreEnv();}
}

Deno.test('new video reads saved gallery order across batches; no operation, provider or source write',async()=>{
 const result=await sources({photos:[photo(10),photo(11),photo(20),photo(21)],assets:[asset(21),asset(20),asset(11),asset(10)]});
 assertEquals(result.status,200);assertEquals(result.body.sources.map((s:any)=>s.photo_id),[10,11,20,21].map(id));
 assertEquals(result.body.sources.map((s:any)=>s.photo_asset_id),[10,11,20,21].map(id));
 assert(result.requests.every(r=>r.method==='GET'||r.method==='HEAD'||r.url.endsWith('/rpc/listing_library_scope')||r.url.endsWith('/rpc/property_photo_reference')));
 assert(!result.requests.some(r=>/job_admit|job_enqueue|job_resume|ai-video/.test(r.url)));
});
Deno.test('explicit listing IDs keep their own order even when photo row order differs',async()=>{
 const result=await sources({gallery:[id(21),id(10)],photos:[photo(10),photo(21)],assets:[asset(10),asset(21)]});
 assertEquals(result.status,200);assertEquals(result.body.sources.map((s:any)=>s.photo_asset_id),[id(21),id(10)]);
 const empty=await sources({gallery:[],photos:[photo(10)],assets:[asset(10)]});assertEquals(empty.body.sources,[]);assertEquals(empty.body.selected_count,0);
});
Deno.test('a saved edit with a non-gallery key is the source; Original is never silently substituted',async()=>{
 const edited=key(10,'saved-stage');const result=await sources({photos:[photo(10,edited)],assets:[asset(10),asset(110,edited)]});
 assertEquals(result.status,200);assertEquals(result.body.sources[0].photo_id,id(10));assertEquals(result.body.sources[0].photo_asset_id,id(110));
 assertEquals(result.body.sources[0].photo_version_id,'asset:'+id(110));assertEquals(result.references,[id(110)]);
 assert(result.body.sources[0].needs_preparation);
 const missing=await sources({photos:[photo(10,edited)],assets:[asset(10)]});
 assertEquals(missing.status,200);assertEquals(missing.body.sources[0].photo_id,id(10));assertEquals(missing.body.sources[0].photo_asset_id,null);
 assertEquals(missing.body.sources[0].eligible,false);assertEquals(missing.body.sources[0].needs_preparation,false);assertEquals(missing.references,[]);
});
Deno.test('an unavailable saved edit stays unavailable and blank enhanced keys retain Original',async()=>{
 const result=await sources({photos:[photo(10,key(10,'edit'))],assets:[asset(10),asset(110,key(10,'edit'))],refused:[id(110)]});
 assertEquals(result.status,200);assertEquals(result.references,[id(110)]);assertEquals(result.body.sources[0].eligible,false);assertEquals(result.body.sources[0].preview_url,null);assertEquals(result.body.sources[0].needs_preparation,false);
 const blank=await sources({photos:[photo(10,'')],assets:[asset(10)]});assertEquals(blank.body.sources[0].photo_asset_id,id(10));
});
Deno.test('legacy capture chronology is used only when no saved photo rows exist',async()=>{
 const result=await sources({photos:[],assets:[asset(10),asset(11),asset(99,key(99,'processing-copy'))]});
 assertEquals(result.status,200);assertEquals(result.body.sources.map((s:any)=>s.photo_id),[id(10),id(11)]);assertEquals(result.body.selected_count,2);
 assert(result.requests.some(r=>r.method==='HEAD'&&r.url.includes('/capture_assets')));
});
Deno.test('saved gallery paging follows its order before slicing rather than capture creation order',async()=>{
 const photos=Array.from({length:105},(_,i)=>photo(1000+i)),assets=photos.map((_,i)=>asset(1000+i)).reverse();
 const result=await sources({photos,assets},100);assertEquals(result.status,200);assertEquals(result.body.selected_count,105);assertEquals(result.body.next_offset,null);
 assertEquals(result.body.sources.map((s:any)=>s.photo_id),[1100,1101,1102,1103,1104].map(id));
 assertEquals(result.references,[1100,1101,1102,1103,1104].map(id));
});
