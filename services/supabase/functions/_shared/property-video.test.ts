import {assert,assertEquals,assertRejects} from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {HttpError} from './http.ts';
import {propertyVideoManifest,verifyPropertyVideoInput,attestPropertyVideo,type PropertyVideoDeps} from './property-video.ts';
import {propertyPublicPresentation} from './property-public-presentation.ts';
import {propertyMP4Fixture} from './property-video-mp4-fixture_test.ts';
import {driftLineageKey} from './drift.ts';
const id=(n:number)=>`e1000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const actor=id(1),org=id(2),listing=id(3),asset=id(4),poster=id(5),source=id(6),composition=id(7);
const manifest={schema:1,purpose:'listing',aspect:'16:9',branding_policy:'unbranded',sources:[{photo_asset_id:source,photo_version_id:'retained-version.jpg',motion_kind:'original_photo'}]};
Deno.test('manifest permits original-photo motion without successful generation,100 items, and filename version IDs',()=>{
 assertEquals(propertyVideoManifest(manifest),manifest);
 assertEquals((propertyVideoManifest({...manifest,sources:Array(100).fill(manifest.sources[0])}).sources as unknown[]).length,100);
});
Deno.test('manifest rejects wrong purpose/aspect, unbounded sources, empty source identity and unverified AI claims',()=>{
 for(const value of [{...manifest,purpose:'social'}, {...manifest,aspect:'9:16'}, {...manifest,branding_policy:'branded'}, {...manifest,sources:[]}, {...manifest,sources:Array(101).fill(manifest.sources[0])},
 {...manifest,sources:[{...manifest.sources[0],photo_asset_id:'private-url'}]}, {...manifest,sources:[{...manifest.sources[0],photo_version_id:'x'.repeat(201)}]},
 {...manifest,sources:[{...manifest.sources[0],motion_kind:'ai',source_bound:true}]}, {...manifest,sources:[{...manifest.sources[0],generation_request_id:'x'.repeat(257)}]}]){
 let refused=false;try{propertyVideoManifest(value);}catch(error){assert(error instanceof HttpError);refused=true;}assert(refused);
 }
});
const hex=async(bytes:Uint8Array)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new Uint8Array(bytes))),b=>b.toString(16).padStart(2,'0')).join('');
async function inputFixture(change:'inline'|'object'|'etag'|'head'|'provenance'|'scope'|null=null){
 const bytes=new Uint8Array([1,2,3,4]),base64=btoa(String.fromCharCode(...bytes)),digest=await hex(bytes),key=`uploads/${org}/${listing}/private-prepared.jpg`;
 let reads=0,heads=0,paidDispatches=0;
 const deps:PropertyVideoDeps={rpc:async(name)=>name==='property_owned_upload'?{error:null,data:{actor_id:change==='scope'?id(99):actor,org_id:org,listing_id:listing,asset_id:asset,bucket:'uploads',storage_key:key,bytes:4,etag:'"source-etag"',content_type:'image/jpeg',sha256:digest}}:{error:change==='provenance'?{message:'RP404: Photo source provenance is unavailable'}:null,data:{}},
 head:async()=>({exists:true,bytes:4,etag:change==='head'&&++heads>1?'"changed"':'"source-etag"',contentType:'image/jpeg'}),
 sign:async()=>`https://source.fixture.invalid/${key}`,fetch:async(_url,init)=>{reads++;assertEquals((init as RequestInit)?.redirect,'error');assertEquals(new Headers((init as RequestInit)?.headers).get('if-match'),'"source-etag"');return new Response(change==='object'?new Uint8Array([1,2,3,8]):bytes,{headers:{etag:change==='etag'?'"changed"':'"source-etag"'}});}};
 const result=verifyPropertyVideoInput(actor,listing,asset,change==='inline'?btoa('wrong'):base64,null,deps).then(x=>{paidDispatches++;return x;});return{result,counts:()=>({reads,paidDispatches}),base64,digest};
}
Deno.test('private source is checked against actual retained bytes before dispatch and carries separate exact-byte and existing QC hashes',async()=>{
 const f=await inputFixture(),r=await f.result;assertEquals(r.sha256,f.digest);assertEquals(r.qcHash,await driftLineageKey(f.base64));assertEquals(r.qcHash.length,32);assertEquals(r.sha256.length,64);assertEquals(f.counts(),{reads:1,paidDispatches:1});
});
Deno.test('inline/source/object/version/provenance substitution never reaches paid dispatch',async()=>{
 for(const kind of ['inline','object','etag','head','provenance','scope']as const){const f=await inputFixture(kind);await assertRejects(()=>f.result,HttpError);assertEquals(f.counts().paidDispatches,0);if(['inline','provenance','scope'].includes(kind))assertEquals(f.counts().reads,0);}
});
function outputFixture(o:{width?:number;height?:number;seconds?:number;changed?:boolean;receipt?:boolean}={}){
 const f=propertyMP4Fixture({width:o.width??1920,height:o.height??1080,seconds:o.seconds??15,fps:30}),key=`renders/${org}/${listing}/finished.mp4`;
 let writes=0,heads=0;
 const deps:PropertyVideoDeps={rpc:async(name,args)=>{if(name==='property_owned_upload')return{error:null,data:{actor_id:actor,org_id:org,listing_id:listing,asset_id:asset,bucket:'renders',storage_key:key,bytes:f.total,etag:'"fixture-version"',content_type:'video/mp4'}};
 writes++;assertEquals(args.p_width,o.width??1920);assertEquals(args.p_height,o.height??1080);return{error:null,data:{attested:o.receipt!==false}};},
 head:async()=>({exists:true,bytes:f.total,etag:o.changed&&++heads>1?'"changed"':'"fixture-version"',contentType:'video/mp4'}),sign:async()=>`https://video.fixture.invalid/${key}`,fetch:async(url,init)=>{assertEquals(new Headers((init as RequestInit)?.headers).get('if-match'),'"fixture-version"');return f.fetch(String(url),init!);}};
 return{result:()=>attestPropertyVideo(actor,listing,asset,deps),writes:()=>writes};
}
Deno.test('actual bounded AVC parser binds landscape1080p finished bytes instead of client metadata',async()=>{const f=outputFixture(),r=await f.result();assertEquals([r.width,r.height,r.duration_s],[1920,1080,15]);assertEquals(f.writes(),1);});
Deno.test('portrait,720p,too-long,and changed object cannot attest; missing positive receipt cannot acknowledge',async()=>{
 for(const o of [{width:1080,height:1920},{width:1280,height:720},{seconds:601},{changed:true},{receipt:false}]){const f=outputFixture(o);await assertRejects(f.result,HttpError);if(o.receipt!==false)assertEquals(f.writes(),0);}
});
const serverVideo={composition_id:composition,asset_id:asset,poster_asset_id:poster,poster_key:`renders/${org}/${listing}/first-clip.jpg`,storage_key:`renders/${org}/${listing}/finished.mp4`,width:1920,height:1080,duration_s:15,branding_policy:'unbranded',disclosure:'Movement from photographs; not recorded footage.',source_asset_ids:[source]};
async function project(value:unknown,error:null|{message:string;code?:string}=null){const refs={assets:[]as string[],keys:[]as string[]};const result=await propertyPublicPresentation({rpc:async()=>({data:value,error})},{id:listing,org_id:org},'fixture-slug',refs,(slug,key)=>key?`https://media.fixture.invalid/${slug}/${encodeURIComponent(key)}`:null);return{result,refs};}
Deno.test('public projection uses independent first-clip poster and includes every source in fresh privacy refs',async()=>{
 const {result,refs}=await project({listing_video:serverVideo,website_theme:'signature-estate'});assert(result.listing_video);assert(result.listing_video.poster_url?.includes('first-clip.jpg'));assertEquals(refs.assets,[asset,poster,source]);assertEquals(refs.keys,[serverVideo.storage_key,serverVideo.poster_key]);assert(!JSON.stringify(result).includes('transaction'));
});
Deno.test('public projection refuses foreign video/poster,wrong dimensions,missing poster and missing disclosure',async()=>{
 for(const delta of [{storage_key:`renders/${id(99)}/${listing}/finished.mp4`},{poster_key:`renders/${org}/${id(99)}/first-clip.jpg`},{poster_key:undefined},{width:1280,height:720},{disclosure:''},{source_asset_ids:[]}])await assertRejects(()=>project({listing_video:{...serverVideo,...delta},website_theme:'basic'}),HttpError);
});
Deno.test('pre-migration projection is closed basic; unexpected SQL failure never grants premium',async()=>{
 assertEquals((await project(null)).result,{listing_video:null,website_theme:'basic'});assertEquals((await project(null,{code:'PGRST202',message:'absent'})).result,{listing_video:null,website_theme:'basic'});await assertRejects(()=>project(null,{message:'private database failure'}),HttpError);
});
