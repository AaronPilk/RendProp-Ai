// _shared/property-video.ts for the Kie native-4K profile: a registered Kie
// master is verified on the exact 24 fps CFR compositor cadence (like FAL
// steady-v2), unknown profiles still refuse, and source verification returns
// the exact verified object's location (additive) for the presigned dispatch.
// Synthetic AVC transport fixture and closed RPC/storage doubles only.
import {assert,assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {HttpError} from "../_shared/http.ts";
import {attestPropertyVideo,verifyPropertyVideoInput,type PropertyVideoDeps} from "../_shared/property-video.ts";
import {propertyMP4Fixture} from "../_shared/property-video-mp4-fixture_test.ts";
import {driftLineageKey} from "../_shared/drift.ts";
import {KIE_PROPERTY_PROFILE} from "../_shared/property-video-kie.ts";
const id=(n:number)=>`e1000000-0000-4000-8000-${String(n).padStart(12,"0")}`;
const actor=id(1),org=id(2),listing=id(3),asset=id(4);
const SHARED=new URL("../_shared/property-video.ts",import.meta.url),SOURCE=await Deno.readTextFile(SHARED);
const enc=(s:string)=>{const b=new TextEncoder().encode(s);let out="";for(let i=0;i<b.length;i+=32768)out+=String.fromCharCode(...b.subarray(i,i+32768));return "data:application/typescript;base64,"+btoa(out);};
const variant=async(a:string,b:string)=>{assertEquals(SOURCE.split(a).length,2,"Mutation anchor must be unique: "+a);
 return await import(enc(SOURCE.replace(a,b).replace(/from\s+(["'])(\.\.?\/[^"']+)\1/g,(_x,_q,path)=>`from ${JSON.stringify(new URL(path,SHARED).href)}`))) as typeof import("../_shared/property-video.ts");};

function master(o:{fps:number;profile:unknown}){
 const f=propertyMP4Fixture({width:1920,height:1080,seconds:15,fps:o.fps}),key=`renders/${org}/${listing}/background/private/master.mp4`;let writes=0;
 const deps:PropertyVideoDeps={rpc:async(name,args)=>{
  if(name==="property_owned_upload")return{error:null,data:{actor_id:actor,org_id:org,listing_id:listing,asset_id:asset,bucket:"renders",storage_key:key,bytes:f.total,etag:'"fixture-version"',content_type:"video/mp4",sha256:"a".repeat(64)}};
  if(name==="background_video_delivery")return{error:null,data:{kind:"registered_background_video",asset_id:asset,bytes:f.total,sha256:"a".repeat(64),quality_profile:o.profile}};
  assertEquals(name,"record_property_video_attestation");writes++;return{error:null,data:{attested:true}};},
  head:async()=>({exists:true,bytes:f.total,etag:'"fixture-version"',contentType:"video/mp4"}),sign:async()=>`https://master.fixture.invalid/${key}`,
  fetch:async(url,init)=>{assertEquals(new Headers((init as RequestInit)?.headers).get("if-match"),'"fixture-version"');return f.fetch(String(url),init!);}};
 return{deps,writes:()=>writes};
}

Deno.test("registered Kie native-4K master publishes only on the exact24 fps CFR verifier, like FAL steady-v2",async()=>{
 for(const profile of[KIE_PROPERTY_PROFILE,"fal-kling3-4k-steady-v2"]){
  const ok=master({fps:24,profile}),r=await attestPropertyVideo(actor,listing,asset,ok.deps);
  assertEquals([r.width,r.height,r.fps,r.duration_s],[1920,1080,24,15]);assertEquals(ok.writes(),1);
  const wrongCadence=master({fps:30,profile});await assertRejects(()=>attestPropertyVideo(actor,listing,asset,wrongCadence.deps),HttpError);assertEquals(wrongCadence.writes(),0);
 }
});

Deno.test("unknown, near-miss and v1 master profiles still refuse before any attestation write",async()=>{
 for(const profile of["fal-kling3-4k-v1","kie-kling3-4k-steady-v2","KIE-KLING3-4K-STEADY-V1","steady-v2-cfr24","legacy",null,24,{profile:KIE_PROPERTY_PROFILE}]){
  const f=master({fps:24,profile});const e=await assertRejects(()=>attestPropertyVideo(actor,listing,asset,f.deps),HttpError);
  assertEquals(e.status,409,JSON.stringify(profile));assertEquals(f.writes(),0);
 }
});

Deno.test("verified input returns the exact owned object location additively; existing fields unchanged",async()=>{
 const bytes=new Uint8Array([1,2,3,4]),base64=btoa(String.fromCharCode(...bytes)),key=`uploads/${org}/${listing}/prepared.jpg`;
 const digest=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",bytes)),b=>b.toString(16).padStart(2,"0")).join("");
 const deps:PropertyVideoDeps={rpc:async(name)=>name==="property_owned_upload"?{error:null,data:{actor_id:actor,org_id:org,listing_id:listing,asset_id:asset,bucket:"uploads",storage_key:key,bytes:4,etag:'"source-etag"',content_type:"image/jpeg",sha256:digest}}:{error:null,data:{}},
  head:async()=>({exists:true,bytes:4,etag:'"source-etag"',contentType:"image/jpeg"}),sign:async()=>`https://source.fixture.invalid/${key}`,
  fetch:async()=>new Response(bytes,{headers:{etag:'"source-etag"'}})};
 const r=await verifyPropertyVideoInput(actor,listing,asset,base64,null,deps);
 assertEquals(r,{asset,listing,photoProvenance:null,sha256:digest,qcHash:await driftLineageKey(base64),org,location:{bucket:"uploads",storage_key:key,etag:'"source-etag"',bytes:4,content_type:"image/jpeg"}});
 const {location:_location,...existing}=r;assertEquals(Object.keys(existing),["asset","listing","photoProvenance","sha256","qcHash","org"]);
 const removed=await variant(",location};","};");const old=await removed.verifyPropertyVideoInput(actor,listing,asset,base64,null,deps);
 assertEquals((old as {location?:unknown}).location,undefined,"Compiled omission exposes a missing dispatch location");
});

Deno.test("compiled defect controls: the Kie CFR24 binding is load-bearing",async()=>{
 const noKie=await variant("['fal-kling3-4k-steady-v2',KIE_PROPERTY_PROFILE]","['fal-kling3-4k-steady-v2']");
 const kie=master({fps:24,profile:KIE_PROPERTY_PROFILE});await assertRejects(()=>noKie.attestPropertyVideo(actor,listing,asset,kie.deps),HttpError);assertEquals(kie.writes(),0);
 const thirty=await variant("},cfr24?24:30);","},30);");
 const k2=master({fps:24,profile:KIE_PROPERTY_PROFILE});await assertRejects(()=>thirty.attestPropertyVideo(actor,listing,asset,k2.deps),HttpError);
 const open=await variant("assert(!master||master.quality_profile===undefined||cfr24,","assert(true,");
 const unknown=master({fps:30,profile:"invented"});const accepted=await open.attestPropertyVideo(actor,listing,asset,unknown.deps);
 assert(accepted.width===1920&&unknown.writes()===1,"Compiled omission exposes an unknown profile publishing");
 console.log("KIE_ATTEST_COMPILED_CONTROLS=4");
});
