import{assertEquals,assertRejects}from'https://deno.land/std@0.224.0/assert/mod.ts';
import{backgroundObjectLimits,GENERIC_MEDIA_BYTES,REGISTERED_BACKGROUND_BYTES}from'./background-media-delivery.ts';
import{deliveryBytes}from'./media-delivery-admission.ts';
import{HttpError}from'./http.ts';
const org='10000000-0000-4000-8000-000000000001',listing='20000000-0000-4000-8000-000000000002',actor='30000000-0000-4000-8000-000000000003',asset='40000000-0000-4000-8000-000000000004';
const key=`renders/${org}/${listing}/background/job/lease/master.mp4`,bytes=350*1024*1024;
const bound={kind:'registered_background_video',asset_id:asset,bytes,sha256:'a'.repeat(64),max_object_bytes:REGISTERED_BACKGROUND_BYTES}as const;
Deno.test('registered background metadata requires exact ready RPC authority rather than path',async()=>{
 const calls:any[]=[];const db={rpc:(name:string,args:any)=>{calls.push({name,args});return Promise.resolve({data:bound,error:null});}};
 assertEquals(await backgroundObjectLimits(db,{orgId:org,listingId:listing,actorId:actor},{[key]:'renders'},bytes,key),{[key]:bound});
 assertEquals(calls,[{name:'background_video_delivery',args:{p_actor:actor,p_org:org,p_listing:listing,p_key:key,p_bytes:bytes}}]);
 const absent={rpc:()=>Promise.resolve({data:null,error:null})};
 assertEquals(await backgroundObjectLimits(absent,{orgId:org,listingId:listing},{[key]:'renders'}),{});
 await assertRejects(()=>backgroundObjectLimits(absent,{orgId:org,listingId:listing},{[key]:'renders'},bytes,key),HttpError);
});
Deno.test('large request cannot borrow another admitted object or widen ordinary/foreign media',async()=>{
 let reads=0;const db={rpc:()=>{reads++;return Promise.resolve({data:bound,error:null});}};
 for(const objects of([{ordinary:'renders'},{[key]:'uploads'}]as Array<Record<string,'renders'|'uploads'>>))await assertRejects(()=>backgroundObjectLimits(db,{orgId:org,listingId:listing},objects,bytes,key),HttpError);
 assertEquals(reads,0);
 await assertRejects(()=>backgroundObjectLimits(db,{orgId:org,listingId:listing},{[key]:'renders'},bytes+1,key),HttpError);
 const foreign={rpc:()=>Promise.resolve({data:null,error:{message:'RP404: withdrawn source'}})};
 await assertRejects(()=>backgroundObjectLimits(foreign,{orgId:org,listingId:listing},{[key]:'renders'},bytes,key),HttpError);
});
Deno.test('malformed claimed background metadata never authorizes a larger HEAD or read',async()=>{
 for(const data of[{...bound,kind:'ordinary'},{...bound,asset_id:'not-a-uuid'},{...bound,sha256:'x'}, {...bound,max_object_bytes:2_000_000_000},{...bound,bytes:REGISTERED_BACKGROUND_BYTES+1},{...bound,extra:true}]){
  await assertRejects(()=>backgroundObjectLimits({rpc:()=>Promise.resolve({data,error:null})},{orgId:org,listingId:listing},{[key]:'renders'}),HttpError);
 }
});
Deno.test('ordinary byte parser remains256MiB; larger parsed admission needs explicit registered bound',()=>{
 assertEquals(deliveryBytes(new Request('https://fixture.invalid?bytes='+GENERIC_MEDIA_BYTES)),GENERIC_MEDIA_BYTES);
 let refused=false;try{deliveryBytes(new Request('https://fixture.invalid?bytes='+bytes));}catch{refused=true;}assertEquals(refused,true);
 assertEquals(deliveryBytes(new Request('https://fixture.invalid?bytes='+REGISTERED_BACKGROUND_BYTES),REGISTERED_BACKGROUND_BYTES),REGISTERED_BACKGROUND_BYTES);
});
Deno.test('saved steady-v2 receipt preserves exact registered delivery authority without accepting arbitrary profile fields',async()=>{
 const steady={...bound,quality_profile:'fal-kling3-4k-steady-v2'}as const;
 const run=(data:unknown)=>backgroundObjectLimits({rpc:()=>Promise.resolve({data,error:null})},{orgId:org,listingId:listing,actorId:actor},{[key]:'renders'},bytes,key);
 assertEquals(await run(steady),{[key]:steady});assertEquals(await run(bound),{[key]:bound});
 for(const data of[{...steady,quality_profile:null},{...steady,quality_profile:'fal-kling3-4k-v1'},{...steady,quality_profile:'customer24'},{...steady,extra:true},{...steady,bytes:1}])await assertRejects(()=>run(data),HttpError);
});
