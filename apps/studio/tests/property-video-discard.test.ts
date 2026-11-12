import assert from "node:assert/strict";
import {test} from "node:test";
import {abandonVideoOperation,decodeJob,inspectVideoOperation,retainAbandonedVideo,retainRejectedVideo,saveVideoJournal,selectedSources,videoClosure,videoScopeKey,type VideoInput,type VideoJournal,type VideoScope} from "../src/features/sync/property-video";

// C2: discarding a saved video request is decided by the server for the exact
// saved operation. A lost reply, an open reply or a foreign echo never unlocks.
const actor="11111111-1111-4111-8111-111111111111",org="22222222-2222-4222-8222-222222222222",library="33333333-3333-4333-8333-333333333333",listing="44444444-4444-4444-8444-444444444444",operation="55555555-5555-4555-8555-555555555555",jobID="66666666-6666-4666-8666-666666666666",other="88888888-8888-4888-8888-888888888888";
const scope:VideoScope={actor,org,library,listing,identityVersion:1};
const photo={photo_id:"photo-1",photo_asset_id:"00000000-0000-4000-8000-000000000001",photo_version_id:"asset:00000000-0000-4000-8000-000000000001",photo_provenance_id:null,eligible:true};
const input:VideoInput={operation_id:operation,listing_id:listing,expected_org_id:library,purpose:"listing",aspect:"16:9",sources:selectedSources([photo] as any,["photo-1"]),narration_result_id:null,narration_asset_id:null,narration_words:[],music:null,presentation:{transition:"cut",shot_caption_style:"off",spoken_captions:false,title_card:null,shot_labels:[null]},allow_original_photo_fallback:false};
const journal:VideoJournal={schema:1,actor,org,library,listing,input,preparation:{planned:true,voiceComplete:true,voice:"off",voiceID:"",script:"",automatic:false,camera:"automatic"}};
const queued=()=>({job_id:jobID,operation_id:operation,listing_id:listing,org_id:org,selected_library_org_id:library,source_count:1,manifest_sha256:"a".repeat(64),state:"queued",completed_sources:0,result:null});
const closure={operation_id:operation,listing_id:listing,selected_library_org_id:library,operation_closed:true,closed_reason:"abandoned",message:"You discarded this saved request before the server accepted it. No video was started from it.",job:null};
function storage(){const values=new Map<string,string>();return{getItem:(key:string)=>values.get(key)??null,setItem:(key:string,value:string)=>{values.set(key,value);},values};}
function service(api:(path:string,options:any)=>Promise<unknown>){return{api,getSnapshot:()=>({status:"signed-in" as const,identityVersion:1,identity:{userId:actor,isAnonymous:false}})} as any;}

test("discard calls the exact saved operation once, without AI consent, and returns the server closure",async()=>{
 const calls:any[]=[];
 const outcome=await abandonVideoOperation(service(async(path,options)=>{calls.push({path,options});return closure;}),scope,journal);
 assert.deepEqual(outcome,{job:null,closed:true,abandoned:true});assert.equal(videoClosure(outcome),"abandoned");
 assert.equal(calls.length,1);assert.equal(calls[0].path,`/functions/v1/property-video-jobs/operations/${operation}/abandon`);
 assert.deepEqual({method:calls[0].options.method,orgId:calls[0].options.orgId,body:calls[0].options.body,key:calls[0].options.idempotencyKey,consent:calls[0].options.aiConsent},{method:"POST",orgId:library,body:{listing_id:listing,expected_org_id:library},key:`property-video-abandon:${operation}`,consent:undefined});
});

test("an operation accepted before the discard keeps its job; a capacity refusal stays a refusal",async()=>{
 const accepted=await abandonVideoOperation(service(async()=>({operation_id:operation,listing_id:listing,selected_library_org_id:library,operation_closed:false,closed_reason:null,job:queued()})),scope,journal);
 assert.deepEqual(accepted,{job:decodeJob(queued(),scope),closed:false});assert.equal(videoClosure(accepted),null);
 const refused=await abandonVideoOperation(service(async()=>({...closure,closed_reason:"capacity_refused"})),scope,journal);
 assert.deepEqual(refused,{job:null,closed:true});assert.equal(videoClosure(refused),"capacity_refused");
});

test("lost replies, open replies, foreign echoes, unknown reasons and account switches never count as a discard",async()=>{
 await assert.rejects(()=>abandonVideoOperation(service(async()=>{throw Error("unknown network outcome");}),scope,journal),/unknown/);
 await assert.rejects(()=>abandonVideoOperation(service(async()=>({...closure,operation_closed:false,closed_reason:null})),scope,journal),/not confirmed/);
 for(const bad of [{...closure,operation_id:other},{...closure,listing_id:other},{...closure,selected_library_org_id:org}])await assert.rejects(()=>abandonVideoOperation(service(async()=>bad),scope,journal),/another request/);
 await assert.rejects(()=>abandonVideoOperation(service(async()=>({...closure,closed_reason:"forgotten"})),scope,journal),/not recognized/);
 await assert.rejects(()=>abandonVideoOperation(service(async()=>({...closure,job:queued()})),scope,journal),/proof/);
 let version=1;const switching={api:async()=>{version=2;return closure;},getSnapshot:()=>({status:"signed-in",identityVersion:version,identity:{userId:actor,isAnonymous:false}})} as any;
 await assert.rejects(()=>abandonVideoOperation(switching,scope,journal),/account changed/);
 // An accepted journal never reaches the discard route; it keeps normal cancel/recovery.
 await assert.rejects(()=>abandonVideoOperation(service(async()=>{throw Error("must not call");}),scope,{...journal,job_id:jobID}),/already has a server video/);
});

test("lookup after a lost discard reply reports the same closure; pre-C2 replies keep their meaning",async()=>{
 assert.deepEqual(await inspectVideoOperation(service(async()=>closure),scope,journal),{job:null,closed:true,abandoned:true});
 assert.deepEqual(await inspectVideoOperation(service(async()=>({...closure,closed_reason:undefined})),scope,journal),{job:null,closed:true},"a reasonless closure from an older server is a capacity refusal");
 assert.deepEqual(await inspectVideoOperation(service(async()=>({job:null})),scope,journal),{job:null,closed:false},"not found is not proof of anything");
 await assert.rejects(()=>inspectVideoOperation(service(async()=>({job:null,closed_reason:"abandoned"})),scope,journal),/incomplete/);
});

test("a discarded recipe is archived separately from refusals and from the next recipe",()=>{
 const saved=storage();saveVideoJournal(saved,scope,journal);retainAbandonedVideo(saved,scope,journal);
 assert.deepEqual(JSON.parse(saved.values.get(`${videoScopeKey(scope)}:abandoned:${operation}`)!),journal);
 assert.equal(saved.values.has(`${videoScopeKey(scope)}:capacity-refused:${operation}`),false);
 retainRejectedVideo(saved,scope,{...journal,input:{...input,operation_id:other}});
 assert.equal(saved.values.has(`${videoScopeKey(scope)}:capacity-refused:${other}`),true);
 assert.throws(()=>retainAbandonedVideo(saved,scope,{...journal,job_id:jobID}),/accepted/);
});
