import assert from "node:assert/strict";
import {test} from "node:test";
import {decodeSources,selectedSources,decodeJob,planVideoSources,fallbackVideoMotion,FALLBACK_MOTION_ROTATION,saveVideoJournal,readVideoJournal,enqueueVideo,recoverVideo,inspectVideoOperation,retainRejectedVideo,videoScopeKey,resumeVideo,publishVideo,MUSIC,type VideoScope,type VideoJournal,type VideoInput} from "../src/features/sync/property-video";
import {PROCESSOR_DISCLOSURE} from "../src/features/sync/processor-consent";

const actor="11111111-1111-4111-8111-111111111111",org="22222222-2222-4222-8222-222222222222",library="33333333-3333-4333-8333-333333333333",listing="44444444-4444-4444-8444-444444444444",operation="55555555-5555-4555-8555-555555555555",jobID="66666666-6666-4666-8666-666666666666",asset="77777777-7777-4777-8777-777777777777",poster="88888888-8888-4888-8888-888888888888";
const scope:VideoScope={actor,org,library,listing,identityVersion:1};
function privateURL(which="uploads",who=actor){return `https://rendprop.com/private-media/${Buffer.from(JSON.stringify({v:1,actor:who,org,listing,bucket:which,key:`${which}/${org}/${listing}/owned.jpg`,exp:Math.floor(Date.now()/1000)+300})).toString("base64url")}.${"a".repeat(64)}`;}
// Production's free-media transport is a path-style R2 SigV4 GET. These are
// synthetic URLs; the frontend checks their structure and scope, while R2
// verifies the real signature when the browser fetches one.
function directURL(which:"uploads"|"renders"="uploads",key=`${which}/${org}/${listing}/owned.jpg`):string {
 const url=new URL(`https://${"a".repeat(32)}.r2.cloudflarestorage.com/rendprop-${which}/${key}`);
 url.searchParams.set("X-Amz-Algorithm","AWS4-HMAC-SHA256");
 url.searchParams.set("X-Amz-Credential","synthetic/20261111/auto/s3/aws4_request");
 url.searchParams.set("X-Amz-Date",new Date().toISOString().slice(0,19).replace(/[-:]/g,"")+"Z");
 url.searchParams.set("X-Amz-Expires","600");
 url.searchParams.set("X-Amz-SignedHeaders","host");
 url.searchParams.set("X-Amz-Signature","f".repeat(64));
 return url.toString();
}
const photo=(i:number)=>({photo_id:`photo-${i}`,photo_asset_id:`00000000-0000-4000-8000-${String(i).padStart(12,"0")}`,photo_version_id:`asset:00000000-0000-4000-8000-${String(i).padStart(12,"0")}`,photo_provenance_id:null,preview_url:privateURL(),bytes:100,sha256:"a".repeat(64),eligible:true,reason:null});
const photos=Array.from({length:100},(_,i)=>photo(i+1));
const source=selectedSources(photos,[photos[0]!.photo_id])[0]!;
const input:VideoInput={operation_id:operation,listing_id:listing,expected_org_id:library,purpose:"listing",aspect:"16:9",sources:[source],narration_result_id:null,narration_asset_id:null,narration_words:[],music:null,presentation:{transition:"cut",shot_caption_style:"off",spoken_captions:false,title_card:null,shot_labels:[null]},allow_original_photo_fallback:false};
const journal:VideoJournal={schema:1,actor,org,library,listing,input,preparation:{planned:true,voiceComplete:true,voice:"off",voiceID:"",script:"",automatic:true,camera:"automatic"}};
const queued=()=>({job_id:jobID,operation_id:operation,listing_id:listing,org_id:org,selected_library_org_id:library,source_count:1,manifest_sha256:"a".repeat(64),state:"queued",completed_sources:0,result:null});
const ready=()=>({...queued(),state:"ready",completed_sources:1,result:{asset_id:asset,poster_asset_id:poster,download_url:privateURL("renders"),width:1920,height:1080,duration_s:5,bytes:100,sha256:"b".repeat(64),branding_policy:"unbranded",sources:[{photo_asset_id:source.photo_asset_id,photo_version_id:source.photo_version_id,photo_provenance_id:null,generation_request_id:"provider-request-hex",generation_provenance_id:asset,motion_kind:"ai"}],original_photo_count:0,music:null}});
const photoMotionReady=(profile:"photo-motion-v1-cfr24"|"photo-motion-v2-cfr24"|"photo-motion-v2-opening-cfr24"="photo-motion-v2-cfr24")=>{
 const modern=profile!=="photo-motion-v1-cfr24",opening=profile==="photo-motion-v2-opening-cfr24"?{kind:"aerial_opening",position:0,aspect:"16:9",fps:24,visible_frames:120,available_frames:120,asset_id:asset,sha256:"c".repeat(64)}:undefined;
 const receipt={photo_asset_id:source.photo_asset_id,photo_version_id:source.photo_version_id,photo_provenance_id:null,generation_request_id:null,generation_provenance_id:null,motion_kind:"photo_motion",source_bound:true,source_sha256:"a".repeat(64),source_bytes:4096,visible_frames:48,...(modern?{motion:"push_in"}:{})};
 return{...queued(),state:"ready",completed_sources:1,source_mode:"photo_motion_v1",composition_profile:profile,quality_profile:profile,consent_revision:"photo-motion-v1",processor_consent:null,resume_available:false,result:{asset_id:asset,poster_asset_id:poster,download_url:privateURL("renders"),width:1920,height:1080,duration_s:opening?7:2,bytes:100,sha256:"b".repeat(64),branding_policy:"unbranded",sources:[receipt],original_photo_count:0,music:null,source_mode:"photo_motion_v1",composition_profile:profile,fps:24,total_frames:opening?168:48,source_frames:[48],source_sha256s:["a".repeat(64)],...(modern?{source_motions:["push_in"]}:{}),...(opening?{opening}:{})}};
};
function storage(){const values=new Map<string,string>();return{getItem:(key:string)=>values.get(key)??null,setItem:(key:string,value:string)=>{values.set(key,value);},values};}
function service(api:(path:string,options:any)=>Promise<unknown>){return{api,getSnapshot:()=>({status:"signed-in" as const,identityVersion:1,identity:{userId:actor,isAnonymous:false}}),listingReadScope:async()=>()=>{}} as any;}

test("exact selected staged version, empty gallery and ineligible source stay explicit",()=>{
 const raw={listing_id:listing,org_id:org,selected_library_org_id:library,selected_count:100,sources:photos,next_offset:null};
 assert.equal(decodeSources(raw,scope).length,100);
 assert.deepEqual(decodeSources({...raw,selected_count:0,sources:[]},scope),[]);
 assert.deepEqual(selectedSources(photos,[photos[9]!.photo_id,photos[0]!.photo_id]).map(s=>s.photo_asset_id),[photos[9]!.photo_asset_id,photos[0]!.photo_asset_id]);
 const bad=photos.map((p,i)=>i===0?{...p,eligible:false,reason:"selected PNG needs preparation"}:p);
 assert.equal(decodeSources({...raw,sources:bad},scope)[0]!.eligible,false);
 assert.throws(()=>selectedSources(bad,[bad[0]!.photo_id]));
 assert.throws(()=>selectedSources(photos,["photo-1","photo-1"]));
 assert.throws(()=>decodeSources({...raw,org_id:library},scope));
 assert.throws(()=>decodeSources({...raw,sources:[{...photo(1),preview_url:privateURL("uploads",asset)}],selected_count:1},scope));
 assert.throws(()=>decodeSources({...raw,sources:[{...photo(1),photo_version_id:`asset:${asset}`}],selected_count:1},scope));
});

test("video sources and finished renders accept both scoped private transports",()=>{
 const raw={listing_id:listing,org_id:org,selected_library_org_id:library,selected_count:1,sources:[photo(1)],next_offset:null};
 for(const preview of [directURL("uploads"),directURL("renders"),privateURL("uploads"),privateURL("renders")]){
  assert.equal(decodeSources({...raw,sources:[{...photo(1),preview_url:preview}]},scope)[0]!.preview_url,preview);
 }
 for(const download of [directURL("renders",`renders/${org}/${listing}/background/master.mp4`),privateURL("renders")]){
  const result={...ready().result,download_url:download};
  assert.equal(decodeJob({...ready(),result},scope).result!.download_url,download);
 }
});

test("direct video URLs reject wrong path, transport, expiry and result bucket before use",()=>{
 const raw={listing_id:listing,org_id:org,selected_library_org_id:library,selected_count:1,sources:[photo(1)],next_offset:null};
 const broken=(mutate:(url:URL)=>void)=>{const url=new URL(directURL());mutate(url);return url.toString();};
 const badPreviews=[
  directURL("uploads",`uploads/${library}/${listing}/owned.jpg`),
  directURL("uploads",`uploads/${org}/${asset}/owned.jpg`),
  broken(url=>{url.hostname="example.com";}),
  broken(url=>{url.protocol="http:";}),
  broken(url=>{url.searchParams.set("X-Amz-Expires","601");}),
  broken(url=>{url.searchParams.set("X-Amz-Date",new Date(Date.now()-700_000).toISOString().slice(0,19).replace(/[-:]/g,"")+"Z");}),
  broken(url=>{url.searchParams.append("x-amz-signature","f".repeat(64));}),
  broken(url=>{url.searchParams.set("X-Amz-Signature","invalid");}),
  broken(url=>{url.username="other";}),
  privateURL("uploads",asset),
 ];
 for(const preview of badPreviews)assert.throws(()=>decodeSources({...raw,sources:[{...photo(1),preview_url:preview}]},scope),preview);
 assert.throws(()=>decodeJob({...ready(),result:{...ready().result,download_url:directURL("uploads")}},scope),/points to the wrong place/);
 assert.throws(()=>decodeJob({...ready(),result:{...ready().result,download_url:privateURL("uploads")}},scope),/does not belong to this account or home/);
});

test("all100 photos keep exact input order across20-photo plans, even with reversed responses and a legacy reorder preference",async()=>{
 const batches:number[]=[];
 const api=service(async(_path,options)=>{batches.push(options.body.photos.length);assert.equal(options.aiConsent,"property-video-plan-v1");return{listing_id:listing,org_id:library,photos:[...options.body.photos].reverse().map((p:any)=>({...p,scene:p.photo_id==="photo-100"?"front_exterior":"living",confidence:.9,motion:"side_glide"}))};});
 const frozen=selectedSources(photos,photos.map(s=>s.photo_id));
 const planned=await planVideoSources(api,scope,frozen,operation,true);
 assert.deepEqual(batches,[20,20,20,20,20]);assert.equal(planned.length,100);assert.deepEqual(planned.map(s=>s.photo_id),frozen.map(s=>s.photo_id));assert.equal(new Set(planned.map(s=>s.photo_asset_id)).size,100);
 assert.deepEqual(planned.map(s=>[s.photo_asset_id,s.photo_version_id,s.photo_provenance_id]),frozen.map(s=>[s.photo_asset_id,s.photo_version_id,s.photo_provenance_id]));assert.equal(planned[0]!.motion,"side_glide");
 const ordered=await planVideoSources(api,scope,frozen,operation,false);assert.deepEqual(ordered.map(s=>s.photo_id),frozen.map(s=>s.photo_id));
 await assert.rejects(()=>planVideoSources(service(async()=>({listing_id:listing,org_id:library,photos:[]})),scope,frozen,operation,true),/left out one of your photos/);
 for(const fault of ["duplicate","wrong-asset"]){await assert.rejects(()=>planVideoSources(service(async(_path,options)=>({listing_id:listing,org_id:library,photos:options.body.photos.map((p:any,index:number)=>({...p,...(index===1?(fault==="duplicate"?{photo_id:options.body.photos[0].photo_id}:{asset_id:poster}):{}),scene:"living",confidence:.9,motion:"push_in"}))})),scope,frozen,operation,true),/used one photo twice|swapped one of your photos/);}
 assert.deepEqual(frozen,selectedSources(photos,photos.map(s=>s.photo_id)),"planning cannot mutate selected source/version identity");
});

test("planner-unavailable fallback rotates push_in → side_glide → pull_back by index, keeps order and never fly_through",()=>{
 const frozen=selectedSources(photos,photos.slice(0,14).map(s=>s.photo_id));
 assert(frozen.every(s=>s.motion==="push_in"),"selectedSources still freezes push_in before planning");
 const fallback=fallbackVideoMotion(frozen);
 assert.deepEqual(fallback.map(s=>s.motion),["push_in","side_glide","pull_back","push_in","side_glide","pull_back","push_in","side_glide","pull_back","push_in","side_glide","pull_back","push_in","side_glide"]);
 assert.deepEqual(fallback.map(s=>s.photo_id),frozen.map(s=>s.photo_id),"photo order is preserved");
 assert.deepEqual(fallback.map(s=>[s.photo_asset_id,s.photo_version_id,s.photo_provenance_id]),frozen.map(s=>[s.photo_asset_id,s.photo_version_id,s.photo_provenance_id]),"identity is untouched");
 assert(fallback.every((s,i)=>i===0||s.motion!==fallback[i-1]!.motion),"no two adjacent shots share a move");
 assert(!fallback.some(s=>s.motion==="fly_through"));assert.equal(new Set(fallback.map(s=>s.motion)).size,3);
 assert.deepEqual(fallbackVideoMotion(frozen),fallback,"deterministic for retry safety");
 assert(frozen.every(s=>s.motion==="push_in"),"fallback does not mutate its input");
 assert.deepEqual(fallbackVideoMotion([]),[]);assert.deepEqual(fallbackVideoMotion(frozen.slice(0,1)).map(s=>s.motion),["push_in"]);
 assert.deepEqual(FALLBACK_MOTION_ROTATION,["push_in","side_glide","pull_back"]);
});

test("late identity and aborted planner replies cannot populate a new account",async()=>{
 let version=1;const svc=service(async(_path,options)=>{version=2;return{listing_id:listing,org_id:library,photos:options.body.photos.map((p:any)=>({...p,scene:"living",confidence:.9,motion:"push_in"}))};});svc.getSnapshot=()=>({status:"signed-in",identityVersion:version,identity:{userId:actor,isAnonymous:false}});
 await assert.rejects(()=>planVideoSources(svc,scope,[source],operation,true),/account changed/);
 const controller=new AbortController();controller.abort();await assert.rejects(()=>planVideoSources(service(async()=>{throw Error("must not dispatch");}),scope,[source],operation,true,controller.signal),/account changed/);
});

test("lost enqueue reply preserves exact frozen operation; reload GET recovers with no paid POST",async()=>{
 const saved=storage();let submits=0,reads=0;
 await assert.rejects(()=>enqueueVideo(service(async(_path,options)=>{submits++;assert.equal(options.idempotencyKey,`property-video:${operation}`);assert.equal(options.aiConsent,"property-video-jobs-v1");assert.ok(saved.values.size===1,"persist before dispatch");throw Error("lost reply");}),scope,journal,saved));
 const reloaded=readVideoJournal(saved,scope)!;assert.deepEqual(reloaded.input,input);
 assert.ok(![...saved.values.values()][0]!.includes("https://"),"no capability URLs stored in recovery");
 const recovered=await recoverVideo(service(async(path,options)=>{reads++;assert.ok(path.includes(`operation_id=${operation}`));assert.equal(options.method,undefined);return{job:queued()};}),scope,reloaded);
 assert.equal(recovered!.job_id,jobID);assert.equal(submits,1);assert.equal(reads,1);
 assert.equal(readVideoJournal(saved,{...scope,actor:poster}),null);
 await assert.rejects(()=>recoverVideo(service(async()=>({job:{...queued(),operation_id:poster}})),scope,reloaded));
 assert.equal(await recoverVideo(service(async()=>({job:null})),scope,reloaded),null);
});

test("ready receipt needs actual geometry/all sources/current actor capability; cancellation does not fabricate ready",()=>{
 assert.equal(decodeJob(ready(),scope).result!.width,1920);
 assert.equal(decodeJob({...queued(),state:"cancelled"},scope).state,"cancelled");
 for(const bad of [{...ready(),listing_id:asset},{...ready(),result:{...ready().result,width:1280}},{...ready(),result:{...ready().result,sources:[]}},{...ready(),result:{...ready().result,download_url:privateURL("renders",asset)}},{...queued(),state:"ready"}])assert.throws(()=>decodeJob(bad,scope));
});

test("saved Photo Motion v1, v2 and opening jobs retain exact read-only source and timeline receipts",()=>{
 for(const profile of ["photo-motion-v1-cfr24","photo-motion-v2-cfr24","photo-motion-v2-opening-cfr24"] as const){
  const raw=photoMotionReady(profile),job=decodeJob(raw,scope),result=job.result!;
  assert.equal(job.source_mode,"photo_motion_v1");assert.equal(job.composition_profile,profile);assert.equal(result.composition_profile,profile);
  assert.equal(result.fps,24);assert.equal(result.total_frames,raw.result.total_frames);
  assert.deepEqual(result.sources,raw.result.sources);assert.equal(result.sources[0]!.motion_kind,"photo_motion");
  assert.deepEqual(result.opening,raw.result.opening);assert.equal(job.resume_available,false,"an incompatible paid resume is never offered");
 }
});

test("all seven production video row shapes for one listing decode with identities and hashes redacted",()=>{
 // Read-only projection of the seven rows on 2026-11-11. All UUIDs, hashes,
 // media capabilities and recorded consent times below are synthetic. The
 // profile/state/order, dimensions, frame counts and byte sizes are retained.
 const rows=[
  {state:"failed",profile:"fal-kling3-4k-v1",consent:"property-video-jobs-v1"},
  {state:"failed",profile:"kie-kling3-4k-steady-v1",consent:"property-video-jobs-v2"},
  {state:"failed",profile:"kie-kling3-4k-steady-v1",consent:"property-video-jobs-v2"},
  {state:"ready",profile:"photo-motion-v1-cfr24",consent:"photo-motion-v1",width:1080,height:1920,bytes:4026120},
  {state:"failed",profile:"photo-motion-v2-cfr24",consent:"photo-motion-v1"},
  {state:"ready",profile:"photo-motion-v2-cfr24",consent:"photo-motion-v1",width:1080,height:1920,bytes:4484200},
  {state:"ready",profile:"photo-motion-v2-cfr24",consent:"photo-motion-v1",width:1920,height:1080,bytes:3983411},
 ] as const;
 const uuid=(n:number)=>`00000000-0000-4000-8000-${String(n).padStart(12,"0")}`;
 const consentRecord={token:"property-video-jobs-v2",disclosure_revision:PROCESSOR_DISCLOSURE.disclosure_revision,processors:["kie"],recorded_at:"2026-10-01T00:00:00Z"};
 const decoded=rows.map((row,index)=>{
  const photoMotion=row.profile.startsWith("photo-motion-");
  const raw:any={...queued(),job_id:uuid(100+index),operation_id:uuid(200+index),source_count:3,completed_sources:row.state==="ready"?3:0,state:row.state,quality_profile:row.profile,consent_revision:row.consent,processor_consent:row.consent==="property-video-jobs-v2"?consentRecord:null,resume_available:false};
  if(photoMotion){raw.source_mode="photo_motion_v1";raw.composition_profile=row.profile;}
  if(row.state==="ready"){
   const frames=[48,72,72],hashes=frames.map((_,i)=>String(i+1).repeat(64));
   const sources=frames.map((frame,i)=>({photo_asset_id:uuid(300+i),photo_version_id:`asset:${uuid(300+i)}`,photo_provenance_id:uuid(400+i),generation_request_id:null,generation_provenance_id:null,motion_kind:"photo_motion",source_bound:true,source_sha256:hashes[i],source_bytes:[6710736,7363183,7389550][i],visible_frames:frame,...(row.profile==="photo-motion-v1-cfr24"?{}:{motion:"push_in"})}));
   raw.result={asset_id:uuid(500+index),poster_asset_id:uuid(600+index),download_url:privateURL("renders"),width:row.width,height:row.height,duration_s:8,bytes:row.bytes,sha256:"f".repeat(64),branding_policy:row.width===1920?"unbranded":"social",sources,original_photo_count:0,music:null,source_mode:"photo_motion_v1",composition_profile:row.profile,fps:24,total_frames:192,source_frames:frames,source_sha256s:hashes,...(row.profile==="photo-motion-v1-cfr24"?{}:{source_motions:["push_in","push_in","push_in"]})};
  }
  return decodeJob(raw,scope);
 });
 assert.equal(decoded.length,7);
 assert.deepEqual(decoded.map(job=>job.state),rows.map(row=>row.state));
 assert.deepEqual(decoded.map(job=>job.result?.width??null),[null,null,null,1080,null,1080,1920]);
 assert(decoded.filter(job=>job.source_mode==="photo_motion_v1"&&job.result).every(job=>job.result!.sources.every(source=>source.motion_kind==="photo_motion"&&source.photo_provenance_id!==null)));
 assert(decoded.every(job=>job.resume_available!==true),"historical failed work never creates a new paid resume path");
});

test("Photo Motion decode refuses altered profile, source, physical receipt and timeline before publication",()=>{
 const base=photoMotionReady();
 for(const mutate of [
  (j:any)=>j.composition_profile="photo-motion-v1-cfr24",
  (j:any)=>j.quality_profile="legacy",
  (j:any)=>j.resume_available=true,
  (j:any)=>j.result.source_mode="ai",
  (j:any)=>j.result.composition_profile="photo-motion-v1-cfr24",
  (j:any)=>j.result.fps=30,
  (j:any)=>j.result.total_frames=49,
  (j:any)=>j.result.source_frames=[72],
  (j:any)=>j.result.source_sha256s=["b".repeat(64)],
  (j:any)=>j.result.source_motions=["slide_left"],
  (j:any)=>j.result.sources[0].motion="spiral",
  (j:any)=>j.result.sources[0].visible_frames=47,
  (j:any)=>j.result.sources[0].source_sha256="bad",
  (j:any)=>j.result.sources[0].source_bytes=0,
  (j:any)=>j.result.sources[0].source_bound=false,
  (j:any)=>j.result.sources[0].generation_request_id="provider-request",
  (j:any)=>j.result.sources[0].photo_version_id="other",
 ]){const j=structuredClone(base);mutate(j);assert.throws(()=>decodeJob(j,scope));}
 const v1=photoMotionReady("photo-motion-v1-cfr24") as any;v1.result.sources[0].motion="push_in";assert.throws(()=>decodeJob(v1,scope),"the v1 publication receipt never adds a motion field");
 const opening=photoMotionReady("photo-motion-v2-opening-cfr24") as any;opening.result.opening.visible_frames=121;assert.throws(()=>decodeJob(opening,scope));
});

test("only exact durable refusal proof permits a new operation; unknown or accepted requests stay fenced",async()=>{
 const proof={operation_id:operation,listing_id:listing,selected_library_org_id:library,operation_closed:true,job:null};
 assert.deepEqual(await inspectVideoOperation(service(async()=>proof),scope,journal),{job:null,closed:true});
 assert.deepEqual(await inspectVideoOperation(service(async()=>({job:null})),scope,journal),{job:null,closed:false});
 assert.deepEqual(await inspectVideoOperation(service(async()=>({job:queued()})),scope,journal),{job:decodeJob(queued(),scope),closed:false});
 for(const bad of [{...proof,operation_id:poster},{...proof,listing_id:asset},{...proof,selected_library_org_id:org},{...proof,job:queued()}])await assert.rejects(()=>inspectVideoOperation(service(async()=>bad),scope,journal),/for a different video request/);
 await assert.rejects(()=>inspectVideoOperation(service(async()=>{throw Error('unknown network outcome');}),scope,journal),/unknown/);
 const saved=storage();saveVideoJournal(saved,scope,journal);retainRejectedVideo(saved,scope,journal);
 const archive=`${videoScopeKey(scope)}:capacity-refused:${operation}`;
 assert.deepEqual(JSON.parse(saved.values.get(archive)!),journal);
 saveVideoJournal(saved,scope,{...journal,input:{...input,operation_id:poster}});
 assert.deepEqual(JSON.parse(saved.values.get(archive)!),journal,'new operation does not overwrite the rejected recipe evidence');
 assert.throws(()=>retainRejectedVideo(saved,scope,{...journal,job_id:jobID}),/accepted/);
});

test("website selection is explicit, scoped and repeats the same publication identity after a lost reply",async()=>{
 const job=decodeJob(ready(),scope),calls:any[]=[];const pub=poster;
 const svc=service(async(path,options)=>{calls.push({path,options});if(calls.length===1)throw Error("lost publication reply");return{listing_id:listing,org_id:org,library_org_id:library,presentation_kind:"photo_video",presentation_asset_id:asset,publication_id:pub,slug:"owned123",share_url:"https://rendprop.com/f/owned123"};});
 const address="https://rendprop.com/property/10-oak-street/20261027.owned123";
 const resolve=async(slug:string,options:{signal?:AbortSignal})=>{assert.equal(slug,"owned123");assert.equal(options.signal,undefined);return{links:{branded:address,unbranded:"https://rendprop.com/u/owned123"},verified:true,addressOnly:false};};
 await assert.rejects(()=>publishVideo(svc,scope,job,pub,undefined,resolve));const published=await publishVideo(svc,scope,job,pub,undefined,resolve);assert.equal(published.url,address);published.assertCurrent();
 assert.deepEqual(calls[0].options.body,calls[1].options.body);assert.equal(calls[1].options.idempotencyKey,`photo-video:${pub}`);assert.equal(calls[1].options.orgId,library);
 assert.equal((await publishVideo(svc,scope,job,pub,undefined,async()=>null)).url,"https://rendprop.com/f/owned123",'a published token remains usable when the address read is unavailable');
 assert.equal((await publishVideo(svc,scope,job,pub,undefined,async()=>false)).url,null,'an authoritative 404 withholds the link after a publish reply');
 assert.equal((await publishVideo(svc,scope,job,pub,undefined,async()=>({links:{branded:"https://rendprop.com/property/10-oak-street/20261027.other",unbranded:"https://rendprop.com/u/owned123"},verified:true,addressOnly:false}))).url,"https://rendprop.com/f/owned123",'a different publication is never opened');
 await assert.rejects(()=>publishVideo(service(async()=>{throw Error("must not publish social");}),scope,decodeJob({...ready(),result:{...ready().result,width:1080,height:1920,branding_policy:"social"}},scope),pub));
 await assert.rejects(()=>publishVideo(service(async()=>({listing_id:asset})),scope,job,pub),/could not confirm this video was put on the website/);
});

test("reviewed Photo Motion publication carries the exact server profile and source receipts",async()=>{
 for(const profile of ["photo-motion-v1-cfr24","photo-motion-v2-cfr24","photo-motion-v2-opening-cfr24"] as const){
  const job=decodeJob(photoMotionReady(profile),scope);let calls=0;
  const svc=service(async(path,options)=>{calls++;assert.equal(path,"/functions/v1/renders/publish-app");const body=options.body;
   assert.equal(body.publication_id,poster);assert.equal(body.composition.source_mode,"photo_motion_v1");assert.equal(body.composition.composition_profile,profile);
   assert.equal(body.composition.fps,24);assert.equal(body.composition.total_frames,job.result!.total_frames);
   assert.deepEqual(body.composition.sources,job.result!.sources);assert.deepEqual(body.composition.opening,job.result!.opening);
   assert.equal(JSON.stringify(body.composition).includes("download_url"),false,"private capability does not enter the publication manifest");
   return{listing_id:listing,org_id:org,library_org_id:library,presentation_kind:"photo_video",presentation_asset_id:asset,publication_id:poster,slug:"owned123",share_url:"https://rendprop.com/f/owned123"};});
  const out=await publishVideo(svc,scope,job,poster,undefined,async()=>null);assert.equal(out.url,"https://rendprop.com/f/owned123");assert.equal(calls,1);
 }
 let sends=0;const svc=service(async()=>{sends++;throw Error("An unsupported Photo Motion receipt must not publish.");});
 const incomplete=decodeJob(photoMotionReady(),scope) as any;incomplete.result.source_frames=[72];
 await assert.rejects(()=>publishVideo(svc,scope,incomplete,poster));assert.equal(sends,0);
});

test("a refreshed listing read or changed account cannot surface a stale post-publish website link",async()=>{
 const reply={listing_id:listing,org_id:org,library_org_id:library,presentation_kind:"photo_video",presentation_asset_id:asset,publication_id:poster,slug:"owned123",share_url:"https://rendprop.com/f/owned123"};
 const proof={links:{branded:"https://rendprop.com/property/10-oak-street/20261027.owned123",unbranded:"https://rendprop.com/u/owned123"},verified:true,addressOnly:false};
 const job=decodeJob(ready(),scope);
 let generation=1;
 const refreshed=service(async()=>reply);
 refreshed.listingReadScope=async(selectedOrg:string,selectedListing:string,selectedLibrary:string)=>{
  assert.deepEqual([selectedOrg,selectedListing,selectedLibrary],[org,listing,library]);
  const saved=generation;return()=>{if(generation!==saved)throw Error("Your property selection changed. Reopen this property.");};
 };
 await assert.rejects(()=>publishVideo(refreshed,scope,job,poster,undefined,async()=>{generation++;return proof;}),/selection changed/);
 generation=1;
 const published=await publishVideo(refreshed,scope,job,poster,undefined,async()=>proof);
 generation++;
 assert.throws(published.assertCurrent,/selection changed/,'a completed link is not clickable after a same-account directory refresh');
 let identityVersion=1;
 const switched=service(async()=>reply);
 switched.getSnapshot=()=>({status:"signed-in",identityVersion,identity:{userId:actor,isAnonymous:false}});
 await assert.rejects(()=>publishVideo(switched,scope,job,poster,undefined,async()=>{identityVersion++;return proof;}),/account changed/);
});

test("optional catalog remains Off by default and pins licensed bytes/evidence",()=>{
 assert.equal(input.music,null);assert.deepEqual(MUSIC.map(m=>m.track_id),["calm","upbeat","cinematic"]);
 assert.ok(MUSIC.every(m=>m.asset_sha256.length===64&&m.license_evidence_sha256.length===64&&m.license_id==="CC0-1.0"&&m.gain===.18&&m.duck_gain===.07));
});

 test("only explicit server-authorized partial video resume keeps the same completed work",async()=>{
 const paused=decodeJob({...queued(),consent_revision:"property-video-jobs-v1",processor_consent:null,quality_profile:"legacy",state:"failed",resume_available:true,completed_sources:1},scope);
 let calls=0;const resumed=await resumeVideo(service(async(path,options)=>{calls++;assert.equal(path,`/functions/v1/property-video-jobs/${jobID}/resume`);assert.equal(options.method,"POST");assert.equal(options.aiConsent,"property-video-jobs-v1");assert.deepEqual(options.body,{});return{...queued(),state:"queued",completed_sources:1};}),scope,paused);
 assert.equal(resumed.job_id,jobID);assert.equal(calls,1);
 await assert.rejects(()=>resumeVideo(service(async()=>{throw Error("must not send");}),scope,decodeJob({...queued(),state:"failed"},scope)),/cannot be resumed/);
 await assert.rejects(()=>resumeVideo(service(async()=>({...queued(),completed_sources:0})),scope,paused),/right video was resumed/);
 assert.throws(()=>decodeJob({...queued(),resume_available:true},scope),/could not tell whether this video can be resumed/);
});
