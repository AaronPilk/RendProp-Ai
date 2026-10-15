import{assert,assertEquals}from'https://deno.land/std@0.224.0/assert/mod.ts';
const source=await Deno.readTextFile(new URL('./index.ts',import.meta.url)),start=source.indexOf('async function galleryFor('),end=source.indexOf('\n}\n',start);assert(start>0&&end>start);
let rows:any[]=[],visibility:any={},queryFields='',selected:string[]|null=null;
(globalThis as any).__thumbnailGallery=()=>({rows,visibility,field:(v:string)=>queryFields=v,selected:(v:string[])=>selected=v});
const module=await import('data:application/typescript,'+encodeURIComponent(`
import{propertyGalleryKey}from ${JSON.stringify(new URL('../_shared/property-cover.ts',import.meta.url).href)};
const MAX_GALLERY=100,mediaVisibility=async()=>globalThis.__thumbnailGallery().visibility;
const publishedR2Url=(slug,key)=>'https://rendprop.com/media/'+slug+'/r2/'+encodeURIComponent(key);
export ${source.slice(start,end+3)}
`));
const org='10000000-0000-4000-8000-000000000001',listing='20000000-0000-4000-8000-000000000002',slug='fixture',key=(n:number)=>`renders/${org}/${listing}/gallery-${n}.jpg`;
const admin={from:()=>{const q:any={select:(v:string)=>{queryFields=v;return q;},eq:()=>q,like:()=>q,in:(_c:string,v:string[])=>{selected=v;return q;},order:()=>q,limit:async()=>({data:rows,error:null})};return q;}};
Deno.test('only current visible selected gallery master gets fixed preview while full-resolution URL and refs remain exact',async()=>{
 rows=[1,2,3].map(n=>({id:'asset'+n,storage_key:key(n),bytes:8_000_000,content_type:'image/jpeg'}));visibility={assets:{asset1:true,asset2:false,asset3:true},keys:{[key(1)]:true,[key(2)]:true,[key(3)]:true}};const refs={keys:[],assets:[]} as {keys:string[];assets:string[]};
 const result=await module.galleryFor(admin,org,listing,refs,['asset2','asset1'],slug);assert(queryFields.includes('bytes')&&queryFields.includes('content_type'));assertEquals(selected,['asset2','asset1']);assertEquals(result,[{url:`https://rendprop.com/media/fixture/r2/${encodeURIComponent(key(1))}`,thumb_url:`https://rendprop.com/media/fixture/thumb/${encodeURIComponent(key(1))}`}]);assertEquals(refs,{keys:[key(1)],assets:['asset1']});
});
Deno.test('oversize unknown and unsupported master metadata keep master links; explicit empty selection never creates previews',async()=>{
 rows=[{id:'asset1',storage_key:key(1),bytes:20_000_001,content_type:'image/png'},{id:'asset2',storage_key:key(2),bytes:100,content_type:'video/mp4'},{id:'asset3',storage_key:key(3)}];visibility={assets:{asset1:true,asset2:true,asset3:true},keys:{[key(1)]:true,[key(2)]:true,[key(3)]:true}};const result=await module.galleryFor(admin,org,listing,{keys:[],assets:[]},null,slug);assertEquals(result.length,3);assert(result.every((row:any)=>typeof row.url==='string'&&!row.thumb_url));assertEquals(await module.galleryFor(admin,org,listing,{keys:[],assets:[]},[],slug),[]);
});
