// A ready Kie master's background_video_delivery receipt keeps the exact closed
// shape rules; only the profile allowlist grows. Defect controls compile the
// actual module with the allowlist removed or without the Kie profile.
import{assertEquals,assertRejects}from'https://deno.land/std@0.224.0/assert/mod.ts';
import{backgroundObjectLimits,REGISTERED_BACKGROUND_BYTES}from'./background-media-delivery.ts';
import{KIE_PROPERTY_PROFILE}from'./property-video-kie.ts';
import{HttpError}from'./http.ts';
const org='10000000-0000-4000-8000-000000000001',listing='20000000-0000-4000-8000-000000000002',actor='30000000-0000-4000-8000-000000000003',asset='40000000-0000-4000-8000-000000000004';
const key=`renders/${org}/${listing}/background/job/lease/master.mp4`,bytes=350*1024*1024;
const bound={kind:'registered_background_video',asset_id:asset,bytes,sha256:'a'.repeat(64),max_object_bytes:REGISTERED_BACKGROUND_BYTES}as const;
const kie={...bound,quality_profile:KIE_PROPERTY_PROFILE}as const,steady={...bound,quality_profile:'fal-kling3-4k-steady-v2'}as const;
const run=(limits:typeof backgroundObjectLimits,data:unknown,requested=bytes)=>limits({rpc:()=>Promise.resolve({data,error:null})},{orgId:org,listingId:listing,actorId:actor},{[key]:'renders'},requested,key);
const NOT_A_PROFILE:unknown[]=[null,undefined,'','legacy','fal-kling3-4k-v1','customer24','kie','kling-3.0/video','kie-kling3-4k-steady-v2','kie-kling3-4k-v1','KIE-KLING3-4K-STEADY-V1',' kie-kling3-4k-steady-v1','kie-kling3-4k-steady-v1 ',[KIE_PROPERTY_PROFILE],{profile:KIE_PROPERTY_PROFILE},24,true];

async function acceptsKieExactly(limits:typeof backgroundObjectLimits){
 assertEquals(await run(limits,kie),{[key]:kie});assertEquals(await run(limits,kie,0),{[key]:kie});
 assertEquals(await run(limits,steady),{[key]:steady});assertEquals(await run(limits,bound),{[key]:bound});
}
async function refusesEverythingElse(limits:typeof backgroundObjectLimits){
 for(const quality_profile of NOT_A_PROFILE)await assertRejects(()=>run(limits,{...bound,quality_profile}),HttpError,undefined,String(JSON.stringify(quality_profile)));
 for(const data of[{...kie,extra:true},{...kie,kind:'ordinary'},{...kie,asset_id:'not-a-uuid'},{...kie,sha256:'x'},{...kie,max_object_bytes:2_000_000_000},{...kie,bytes:REGISTERED_BACKGROUND_BYTES+1},{...kie,bytes:0}])await assertRejects(()=>run(limits,data),HttpError);
 await assertRejects(()=>run(limits,{...kie,bytes:bytes-1}),HttpError,'Large delivery needs its exact registered background receipt.');
}
Deno.test('a ready Kie master receipt carries the same registered delivery authority as FAL steady',async()=>{await acceptsKieExactly(backgroundObjectLimits);});
Deno.test('unknown, near-miss and malformed profiles are still refused with the exact closed shape',async()=>{await refusesEverythingElse(backgroundObjectLimits);});
Deno.test('compiled defect controls: dropping the allowlist admits arbitrary profiles; omitting Kie refuses Kie masters',async()=>{
 const url=new URL('./background-media-delivery.ts',import.meta.url),source=(await Deno.readTextFile(url)).replace(/from'(\.\/[^']+)'/g,(_m,path)=>`from'${new URL(path,url).href}'`);
 const check='STEADY_PROFILES.includes(data.quality_profile)';assertEquals(source.split(check).length,2,'exact actual allowlist check');
 const load=async(code:string)=>(await import('data:application/typescript,'+encodeURIComponent(code))).backgroundObjectLimits as typeof backgroundObjectLimits;
 await assertRejects(async()=>await refusesEverythingElse(await load(source.replace(check,'true'))),Error,undefined,'control: no allowlist');
 await assertRejects(async()=>await acceptsKieExactly(await load(source.replace(check,"data.quality_profile==='fal-kling3-4k-steady-v2'"))),Error,undefined,'control: pre-Kie allowlist');
});
