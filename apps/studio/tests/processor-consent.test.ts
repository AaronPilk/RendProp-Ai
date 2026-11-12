import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";
import {StudioError} from "../src/data/config";
import {CONSENT_V1,CONSENT_V2,PROCESSOR_DISCLOSURE,decodeProcessorContract,decodeVideoPermission,fetchProcessorAvailability,knownVideoPermission,permissionBeforePaidWork,permissionForSavedJob,videoPermissionHeaders,readVideoStops,reconcileVideoStop,saveVideoStop} from "../src/features/sync/processor-consent";
import {decodeJob,enqueueVideo,readVideoJournal,resumeVideo,saveVideoJournal,type VideoJournal,type VideoScope} from "../src/features/sync/property-video";
const actor="11111111-1111-4111-8111-111111111111",org="22222222-2222-4222-8222-222222222222",listing="33333333-3333-4333-8333-333333333333",operation="44444444-4444-4444-8444-444444444444",jobID="55555555-5555-4555-8555-555555555555",asset="66666666-6666-4666-8666-666666666666";
const scope:VideoScope={actor,org,library:org,listing,identityVersion:1};
const contract=()=>({token:CONSENT_V2,disclosure_revision:PROCESSOR_DISCLOSURE.disclosure_revision,processors:[...PROCESSOR_DISCLOSURE.processors],profiles:[...PROCESSOR_DISCLOSURE.profiles]});
const availability=()=>({kind:"known"as const,contract:contract()});
const permission=()=>knownVideoPermission(contract());
const queued=(extra={})=>({job_id:jobID,operation_id:operation,listing_id:listing,org_id:org,selected_library_org_id:org,source_count:1,manifest_sha256:"a".repeat(64),state:"failed",completed_sources:0,resume_available:true,result:null,...extra});
const stored=()=>({token:CONSENT_V2,disclosure_revision:PROCESSOR_DISCLOSURE.disclosure_revision,processors:[...PROCESSOR_DISCLOSURE.processors],recorded_at:"2026-10-16T12:00:00.123+00:00"});
const journal=():VideoJournal=>({schema:1,actor,org,library:org,listing,permission:permission(),input:{operation_id:operation,listing_id:listing,expected_org_id:org,purpose:"listing",aspect:"16:9",sources:[{photo_id:"photo-1",photo_asset_id:asset,photo_version_id:`asset:${asset}`,photo_provenance_id:null,motion:"push_in"}],narration_result_id:null,narration_asset_id:null,narration_words:[],music:null,presentation:{transition:"cut",shot_caption_style:"off",spoken_captions:false,title_card:null,shot_labels:[null]},allow_original_photo_fallback:false}});
function storage(){const entries=new Map<string,string>();return{get length(){return entries.size;},key:(index:number)=>[...entries.keys()][index]??null,removeItem:(key:string)=>void entries.delete(key),getItem:(key:string)=>entries.get(key)??null,setItem:(key:string,value:string)=>void entries.set(key,value),entries};}
function service(api:(path:string,options:any)=>Promise<unknown>){return{api,getSnapshot:()=>({status:"signed-in"as const,identityVersion:1,identity:{userId:actor,isAnonymous:false}})}as any;}

test("compiled processor copy, exact revision and digest equal every canonical draft JSON field",async()=>{
 const canonical=JSON.parse(await readFile(new URL("../../../packages/client-contracts/property-video-processor-disclosure.json",import.meta.url),"utf8"));
 assert.deepEqual(PROCESSOR_DISCLOSURE,canonical);assert.equal(PROCESSOR_DISCLOSURE.disclosure_revision,"rendprop-property-video-kie-20261016-r1");assert.equal(PROCESSOR_DISCLOSURE.copy_sha256,"11d500972be541f0c34f1ccd96f1a2d79d15c9827a4a010e934ca6b534f9ef9c");assert.equal(PROCESSOR_DISCLOSURE.publication_state,"draft_not_published");
});
test("only the exact closed known contract is recognized; future/reordered/extra/partial metadata cannot authorize Kie",()=>{
 assert.deepEqual(decodeProcessorContract(contract()),contract());
 for(const raw of [null,{}, {...contract(),token:"property-video-jobs-v1"},{...contract(),disclosure_revision:"future"},{...contract(),processors:["fal","kie"]},{...contract(),profiles:[]},{...contract(),extra:true}])assert.throws(()=>decodeProcessorContract(raw));
 assert.deepEqual(decodeVideoPermission(permission()),permission());assert.throws(()=>decodeVideoPermission({...permission(),copy_sha256:"0".repeat(64)}));
});
test("precise unpublished404 preserves basev1, every other404/error/unknown current contract fails closed",async()=>{
 const legacy=service(async()=>{throw new StudioError("processor_disclosure_unpublished","unpublished",404);});assert.deepEqual(await fetchProcessorAvailability(legacy,scope),{kind:"legacy"});
 for(const error of [new StudioError("request-failed","missing",404),new StudioError("processor_disclosure_unpublished","forbidden",403),new StudioError("request-failed","offline",503)])await assert.rejects(()=>fetchProcessorAvailability(service(async()=>{throw error;}),scope),e=>e===error);
 await assert.rejects(()=>fetchProcessorAvailability(service(async()=>({...contract(),disclosure_revision:"future"})),scope));
 let v=1;const changed=service(async()=>{v++;return contract();});changed.getSnapshot=()=>({status:"signed-in",identityVersion:v,identity:{userId:actor,isAnonymous:false}});await assert.rejects(()=>fetchProcessorAvailability(changed,scope),/account changed/);
});
test("permission is required before any paid work and a saved request never upgrades/downgrades its snapshot",()=>{
 assert.throws(()=>permissionBeforePaidWork(availability(),null),/Review and allow/);assert.deepEqual(permissionBeforePaidWork(availability(),permission()),permission());
 assert.deepEqual(permissionBeforePaidWork({kind:"legacy"},null),{token:CONSENT_V1});
 assert.throws(()=>permissionBeforePaidWork(availability(),permission(),{}),/original AI permission/);
 assert.throws(()=>permissionBeforePaidWork(availability(),permission(),{permission:{token:CONSENT_V1}}),/original AI permission/);
 assert.throws(()=>permissionBeforePaidWork({kind:"legacy"},permission(),{permission:permission()}),/original AI permission/);
 assert.throws(()=>permissionBeforePaidWork(availability(),null,{permission:permission()}),/before resuming/);
 assert.deepEqual(permissionBeforePaidWork(availability(),permission(),{permission:permission()}),permission());
});
test("journal keeps consent outside the closed manifest, immutable for the same op and exact across lostreply/relaunch",async()=>{
 const store=storage(),saved=journal();await assert.rejects(()=>enqueueVideo(service(async(_p,o)=>{assert.deepEqual(o.body,saved.input);assert.equal(o.body.permission,undefined);assert.equal(o.aiConsent,CONSENT_V2);assert.equal(o.aiConsentDisclosure,PROCESSOR_DISCLOSURE.disclosure_revision);assert.equal(JSON.parse([...store.entries.values()][0]).permission.copy_sha256,PROCESSOR_DISCLOSURE.copy_sha256);throw Error("lost reply");}),scope,saved,store),/lost reply/);
 const reloaded=readVideoJournal(store,scope)!;assert.deepEqual(reloaded,saved);assert.deepEqual(reloaded.input,saved.input);
 assert.throws(()=>saveVideoJournal(store,scope,{...reloaded,permission:{token:CONSENT_V1}}),/original AI permission/);assert.deepEqual(readVideoJournal(store,scope),saved);
 const old={...saved};delete old.permission;const legacyStore=storage();saveVideoJournal(legacyStore,scope,old);assert.throws(()=>saveVideoJournal(legacyStore,scope,saved),/original AI permission/);
 assert.deepEqual(videoPermissionHeaders(permission()),{aiConsent:CONSENT_V2,aiConsentDisclosure:PROCESSOR_DISCLOSURE.disclosure_revision});
});
test("unknown/allnull/partial/future job metadata remains readable but cannot authorize paidresume",()=>{
 for(const meta of [{},{consent_revision:null,processor_consent:null,quality_profile:null},{consent_revision:CONSENT_V1,quality_profile:"legacy"},{consent_revision:CONSENT_V1,processor_consent:null,quality_profile:"future-profile"},{consent_revision:CONSENT_V2,processor_consent:{...stored(),disclosure_revision:"future"},quality_profile:PROCESSOR_DISCLOSURE.profiles[0]},{consent_revision:CONSENT_V2,processor_consent:{...stored(),recorded_at:"invalid"},quality_profile:PROCESSOR_DISCLOSURE.profiles[0]}]){
  const job=decodeJob(queued(meta),scope);assert.equal(job.job_id,jobID);assert.equal(permissionForSavedJob(job),null);
 }
 assert.deepEqual(permissionForSavedJob(decodeJob(queued(),scope),true),{token:CONSENT_V1});
 assert.equal(permissionForSavedJob(decodeJob(queued({consent_revision:null,processor_consent:null,quality_profile:null}),scope),true),null);
});
test("accepted legacy/FAL resume uses frozenv1 even while knownKie disclosure is published",async()=>{
 const current=await fetchProcessorAvailability(service(async()=>contract()),scope);assert.equal(current.kind,"known");
 for(const profile of ["legacy","fal-kling3-4k-v1","fal-kling3-4k-steady-v2"]){
  const job=decodeJob(queued({consent_revision:CONSENT_V1,processor_consent:null,quality_profile:profile}),scope);let n=0;
  await resumeVideo(service(async(_p,o)=>{n++;assert.equal(o.aiConsent,CONSENT_V1);assert.equal(o.aiConsentDisclosure,undefined);return{...job,state:"queued",resume_available:false};}),scope,job);assert.equal(n,1);
 }
});
test("accepted v2 resume uses original recorded revision without current-disclosure fetch or permission upgrade",async()=>{
 for(const profile of ["legacy","fal-kling3-4k-v1","fal-kling3-4k-steady-v2",PROCESSOR_DISCLOSURE.profiles[0]]){
 const job=decodeJob(queued({consent_revision:CONSENT_V2,processor_consent:stored(),quality_profile:profile}),scope);let n=0;
 await resumeVideo(service(async(p,o)=>{n++;assert.ok(p.endsWith("/resume"));assert.equal(o.aiConsent,CONSENT_V2);assert.equal(o.aiConsentDisclosure,stored().disclosure_revision);return{...job,state:"queued",resume_available:false};}),scope,job);assert.equal(n,1);}
 let sent=0;await assert.rejects(()=>resumeVideo(service(async()=>{sent++;return queued();}),scope,decodeJob(queued({consent_revision:null,processor_consent:null,quality_profile:null}),scope)),/could not be verified/);assert.equal(sent,0);
});

test("revocation is exact scoped durable intent; unknown reads and changed physical/account scope cannot retire it",async()=>{
 const store=storage(),intent=saveVideoStop(store,scope,operation);assert.deepEqual(readVideoStops(store,scope),[intent]);let calls=0;
 await assert.rejects(()=>reconcileVideoStop(service(async()=>{calls++;throw Error("read unavailable");}),scope,intent,store),/read unavailable/);assert.equal(calls,1);assert.equal(store.length,1);
 assert.throws(()=>readVideoStops(store,{...scope,org:asset}),/could not be read/);
 calls=0;await assert.rejects(()=>reconcileVideoStop(service(async()=>{calls++;return null;}),{...scope,org:asset},intent,store),/another workspace/);assert.equal(calls,0);assert.equal(store.length,1);
 let version=1;const late=service(async()=>{version++;return{job:queued(),operation_closed:false};});late.getSnapshot=()=>({status:"signed-in",identityVersion:version,identity:{userId:actor,isAnonymous:false}});await assert.rejects(()=>reconcileVideoStop(late,scope,intent,store),/account changed/);assert.equal(store.length,1);
});
test("never-accepted revoke uses operation GET then abandon; accepted race returns original job then cancel, never create/resume",async()=>{
 for(const race of [false,true]){
  const store=storage(),intent=saveVideoStop(store,scope,operation),calls:{path:string;options:any}[]=[];
  const api=service(async(path,options)=>{calls.push({path,options});assert.equal(options.aiConsent,undefined);assert.equal(options.aiConsentDisclosure,undefined);if(calls.length===1){assert.equal(options.method,undefined);assert(path.includes(`operation_id=${operation}`));return{job:null,operation_closed:false};}if(path.endsWith("/abandon")){assert.equal(options.idempotencyKey,`property-video-abandon:${operation}`);assert.deepEqual(options.body,{listing_id:listing,expected_org_id:org});return{operation_id:operation,listing_id:listing,selected_library_org_id:org,operation_closed:!race,...(!race?{closed_reason:"abandoned"}:{}),job:race?queued({state:"queued",resume_available:false}):null};}assert(path.endsWith(`/${jobID}/cancel`));return queued({state:"cancelled",resume_available:false});});
  const result=await reconcileVideoStop(api,scope,intent,store);assert.equal(result?.state??null,race?"cancelled":null);assert.equal(calls.length,race?3:2);assert.equal(store.length,0);assert(calls.every(c=>!c.path.endsWith("/resume")&&!(c.path.endsWith("/property-video-jobs")&&c.options.method==='POST')));
 }
});
test("lost accepted cancel and abandon replies remain pending; a fresh same-scope relaunch GET clears only actual terminal state",async()=>{
 for(const accepted of [false,true]){
  const store=storage(),intent=saveVideoStop(store,scope,operation);let stopped=false,posts=0,reads=0;
  const api=service(async(path,options)=>{if(!options.method){reads++;return{operation_id:operation,listing_id:listing,selected_library_org_id:org,job:accepted?queued({state:stopped?"cancelled":"queued",resume_available:false}):null,operation_closed:!accepted&&stopped,...(!accepted&&stopped?{closed_reason:"abandoned"}:{})};}posts++;stopped=true;throw Error("reply lost after atomic stop");});
  await assert.rejects(()=>reconcileVideoStop(api,scope,intent,store),/reply lost/);assert.equal(store.length,1);assert.equal(posts,1);
  const relaunched={...scope,identityVersion:2};api.getSnapshot=()=>({status:"signed-in",identityVersion:2,identity:{userId:actor,isAnonymous:false}});await reconcileVideoStop(api,relaunched,readVideoStops(store,relaunched)[0]!,store);assert.equal(reads,2);assert.equal(posts,1);assert.equal(store.length,0);
 }
});
test("unmatched closure/cancel reply and pending server status never clear durable stop evidence",async()=>{
 for(const bad of ["wrong-closure","wrong-job","not-cancelled"]){
  const store=storage(),intent=saveVideoStop(store,scope,operation);let n=0;
  const api=service(async(_path,options)=>{n++;if(!options.method){if(bad==="wrong-closure")return{operation_id:asset,listing_id:listing,selected_library_org_id:org,operation_closed:true,job:null};return{operation_closed:false,job:queued({state:"queued",resume_available:false})};}return queued({job_id:bad==="wrong-job"?asset:jobID,state:bad==="not-cancelled"?"queued":"cancelled",resume_available:false});});
  await assert.rejects(()=>reconcileVideoStop(api,scope,intent,store));assert.equal(store.length,1);assert.equal(n,bad==="wrong-closure"?1:2);
 }
 const store=storage(),intent=saveVideoStop(store,scope,operation);assert.throws(()=>saveVideoStop({setItem(){throw Error("storage blocked");}},scope,operation),/storage blocked/);assert.equal(store.length,1);assert.equal(intent.operation_id,operation);
});
