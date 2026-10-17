import assert from "node:assert/strict";
import {test} from "node:test";
import {decodeSources,selectedSources,decodeJob,planVideoSources,fallbackVideoMotion,FALLBACK_MOTION_ROTATION,saveVideoJournal,readVideoJournal,enqueueVideo,recoverVideo,inspectVideoOperation,retainRejectedVideo,videoScopeKey,resumeVideo,publishVideo,MUSIC,type VideoScope,type VideoJournal,type VideoInput} from "../src/features/sync/property-video";

const actor="11111111-1111-4111-8111-111111111111",org="22222222-2222-4222-8222-222222222222",library="33333333-3333-4333-8333-333333333333",listing="44444444-4444-4444-8444-444444444444",operation="55555555-5555-4555-8555-555555555555",jobID="66666666-6666-4666-8666-666666666666",asset="77777777-7777-4777-8777-777777777777",poster="88888888-8888-4888-8888-888888888888";
const scope:VideoScope={actor,org,library,listing,identityVersion:1};
function privateURL(which="uploads",who=actor){return `https://rendprop.com/private-media/${Buffer.from(JSON.stringify({v:1,actor:who,org,listing,bucket:which,key:`${which}/${org}/${listing}/owned.jpg`,exp:Math.floor(Date.now()/1000)+300})).toString("base64url")}.${"a".repeat(64)}`;}
const photo=(i:number)=>({photo_id:`photo-${i}`,photo_asset_id:`00000000-0000-4000-8000-${String(i).padStart(12,"0")}`,photo_version_id:`asset:00000000-0000-4000-8000-${String(i).padStart(12,"0")}`,photo_provenance_id:null,preview_url:privateURL(),bytes:100,sha256:"a".repeat(64),eligible:true,reason:null});
const photos=Array.from({length:100},(_,i)=>photo(i+1));
const source=selectedSources(photos,[photos[0]!.photo_id])[0]!;
const input:VideoInput={operation_id:operation,listing_id:listing,expected_org_id:library,purpose:"listing",aspect:"16:9",sources:[source],narration_result_id:null,narration_asset_id:null,narration_words:[],music:null,presentation:{transition:"cut",shot_caption_style:"off",spoken_captions:false,title_card:null,shot_labels:[null]},allow_original_photo_fallback:false};
const journal:VideoJournal={schema:1,actor,org,library,listing,input,preparation:{planned:true,voiceComplete:true,voice:"off",voiceID:"",script:"",automatic:true,camera:"automatic"}};
const queued=()=>({job_id:jobID,operation_id:operation,listing_id:listing,org_id:org,selected_library_org_id:library,source_count:1,manifest_sha256:"a".repeat(64),state:"queued",completed_sources:0,result:null});
const ready=()=>({...queued(),state:"ready",completed_sources:1,result:{asset_id:asset,poster_asset_id:poster,download_url:privateURL("renders"),width:1920,height:1080,duration_s:5,bytes:100,sha256:"b".repeat(64),branding_policy:"unbranded",sources:[{photo_asset_id:source.photo_asset_id,photo_version_id:source.photo_version_id,photo_provenance_id:null,generation_request_id:"provider-request-hex",generation_provenance_id:asset,motion_kind:"ai"}],original_photo_count:0,music:null}});
function storage(){const values=new Map<string,string>();return{getItem:(key:string)=>values.get(key)??null,setItem:(key:string,value:string)=>{values.set(key,value);},values};}
function service(api:(path:string,options:any)=>Promise<unknown>){return{api,getSnapshot:()=>({status:"signed-in" as const,identityVersion:1,identity:{userId:actor,isAnonymous:false}})} as any;}

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

test("all100 photos keep exact input order across20-photo plans, even with reversed responses and a legacy reorder preference",async()=>{
 const batches:number[]=[];
 const api=service(async(_path,options)=>{batches.push(options.body.photos.length);assert.equal(options.aiConsent,"property-video-plan-v1");return{listing_id:listing,org_id:library,photos:[...options.body.photos].reverse().map((p:any)=>({...p,scene:p.photo_id==="photo-100"?"front_exterior":"living",confidence:.9,motion:"side_glide"}))};});
 const frozen=selectedSources(photos,photos.map(s=>s.photo_id));
 const planned=await planVideoSources(api,scope,frozen,operation,true);
 assert.deepEqual(batches,[20,20,20,20,20]);assert.equal(planned.length,100);assert.deepEqual(planned.map(s=>s.photo_id),frozen.map(s=>s.photo_id));assert.equal(new Set(planned.map(s=>s.photo_asset_id)).size,100);
 assert.deepEqual(planned.map(s=>[s.photo_asset_id,s.photo_version_id,s.photo_provenance_id]),frozen.map(s=>[s.photo_asset_id,s.photo_version_id,s.photo_provenance_id]));assert.equal(planned[0]!.motion,"side_glide");
 const ordered=await planVideoSources(api,scope,frozen,operation,false);assert.deepEqual(ordered.map(s=>s.photo_id),frozen.map(s=>s.photo_id));
 await assert.rejects(()=>planVideoSources(service(async()=>({listing_id:listing,org_id:library,photos:[]})),scope,frozen,operation,true),/omitted/);
 for(const fault of ["duplicate","wrong-asset"]){await assert.rejects(()=>planVideoSources(service(async(_path,options)=>({listing_id:listing,org_id:library,photos:options.body.photos.map((p:any,index:number)=>({...p,...(index===1?(fault==="duplicate"?{photo_id:options.body.photos[0].photo_id}:{asset_id:poster}):{}),scene:"living",confidence:.9,motion:"push_in"}))})),scope,frozen,operation,true),/repeats|changed/);}
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

test("only exact durable refusal proof permits a new operation; unknown or accepted requests stay fenced",async()=>{
 const proof={operation_id:operation,listing_id:listing,selected_library_org_id:library,operation_closed:true,job:null};
 assert.deepEqual(await inspectVideoOperation(service(async()=>proof),scope,journal),{job:null,closed:true});
 assert.deepEqual(await inspectVideoOperation(service(async()=>({job:null})),scope,journal),{job:null,closed:false});
 assert.deepEqual(await inspectVideoOperation(service(async()=>({job:queued()})),scope,journal),{job:decodeJob(queued(),scope),closed:false});
 for(const bad of [{...proof,operation_id:poster},{...proof,listing_id:asset},{...proof,selected_library_org_id:org},{...proof,job:queued()}])await assert.rejects(()=>inspectVideoOperation(service(async()=>bad),scope,journal),/proof/);
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
 await assert.rejects(()=>publishVideo(svc,scope,job,pub));assert.equal(await publishVideo(svc,scope,job,pub),"https://rendprop.com/property/owned123");
 assert.deepEqual(calls[0].options.body,calls[1].options.body);assert.equal(calls[1].options.idempotencyKey,`photo-video:${pub}`);assert.equal(calls[1].options.orgId,library);
 await assert.rejects(()=>publishVideo(service(async()=>{throw Error("must not publish social");}),scope,decodeJob({...ready(),result:{...ready().result,width:1080,height:1920,branding_policy:"social"}},scope),pub));
 await assert.rejects(()=>publishVideo(service(async()=>({listing_id:asset})),scope,job,pub),/not confirmed/);
});

test("optional catalog remains Off by default and pins licensed bytes/evidence",()=>{
 assert.equal(input.music,null);assert.deepEqual(MUSIC.map(m=>m.track_id),["calm","upbeat","cinematic"]);
 assert.ok(MUSIC.every(m=>m.asset_sha256.length===64&&m.license_evidence_sha256.length===64&&m.license_id==="CC0-1.0"&&m.gain===.18&&m.duck_gain===.07));
});

 test("only explicit server-authorized partial video resume keeps the same completed work",async()=>{
 const paused=decodeJob({...queued(),consent_revision:"property-video-jobs-v1",processor_consent:null,quality_profile:"legacy",state:"failed",resume_available:true,completed_sources:1},scope);
 let calls=0;const resumed=await resumeVideo(service(async(path,options)=>{calls++;assert.equal(path,`/functions/v1/property-video-jobs/${jobID}/resume`);assert.equal(options.method,"POST");assert.equal(options.aiConsent,"property-video-jobs-v1");assert.deepEqual(options.body,{});return{...queued(),state:"queued",completed_sources:1};}),scope,paused);
 assert.equal(resumed.job_id,jobID);assert.equal(calls,1);
 await assert.rejects(()=>resumeVideo(service(async()=>{throw Error("must not send");}),scope,decodeJob({...queued(),state:"failed"},scope)),/not available/);
 await assert.rejects(()=>resumeVideo(service(async()=>({...queued(),completed_sources:0})),scope,paused),/same saved/);
 assert.throws(()=>decodeJob({...queued(),resume_available:true},scope),/resume state/);
});
