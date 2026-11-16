import assert from "node:assert/strict";
import {test} from "node:test";
import {readVideoRecovery,resolveUnreadableVideo} from "../src/features/sync/video-recovery";
import {videoScopeKey,type VideoScope} from "../src/features/sync/property-video";

const actor="11111111-1111-4111-8111-111111111111",org="22222222-2222-4222-8222-222222222222",library="33333333-3333-4333-8333-333333333333",listing="44444444-4444-4444-8444-444444444444",operation="55555555-5555-4555-8555-555555555555",jobID="66666666-6666-4666-8666-666666666666",other="77777777-7777-4777-8777-777777777777";
const scope:VideoScope={actor,org,library,listing,identityVersion:1};
// Actual incompatible release shape: the current recipe reader must not
// silently strip timing/hash fields and submit a changed paid manifest.
const recipe=()=>({schema:1,actor,org,library,listing,job_id:jobID,input:{operation_id:operation,listing_id:listing,expected_org_id:library,source_mode:"photo_motion_v1",composition_profile:"photo-motion-v2-cfr24",sources:[{photo_id:"photo-1",photo_asset_id:other,photo_version_id:`asset:${other}`,photo_provenance_id:null,motion:"push_in",visible_frames:120,source_sha256:"a".repeat(64),source_bytes:100}]}});
const job=()=>({job_id:jobID,operation_id:operation,listing_id:listing,org_id:org,selected_library_org_id:library,source_count:1,manifest_sha256:"a".repeat(64),state:"failed",completed_sources:0,result:null});
function storage(value=JSON.stringify(recipe())){const values=new Map([[videoScopeKey(scope),value]]);return{values,getItem:(key:string)=>values.get(key)??null,setItem:(key:string,value:string)=>{values.set(key,value);},removeItem:(key:string)=>{values.delete(key);}};}
function service(reply:any){const calls:any[]=[];return{calls,api:async(path:string,options:any)=>{calls.push({path,options});return {operation_id:operation,listing_id:listing,selected_library_org_id:library,...(typeof reply==="function"?reply():reply)};},getSnapshot:()=>({status:"signed-in",identityVersion:1,identity:{userId:actor,isAnonymous:false}})} as any;}
const archive=`${videoScopeKey(scope)}:recovered:${operation}`;

test("incompatible recipe exposes only a scoped recovery reference, never paid inputs or permission",()=>{
 const value=readVideoRecovery(storage(),scope);assert.equal(value.journal,null);
 assert.deepEqual(value.unreadable?.reference,{input:{operation_id:operation},job_id:jobID});
 assert.equal(readVideoRecovery(storage("{broken"),scope).unreadable?.reference,null);assert.ok(readVideoRecovery(storage(""),scope).unreadable);
 for(const changed of [{actor:other},{org:other},{library:other},{listing:other},{schema:2},{job_id:"invalid"},{input:{...recipe().input,listing_id:other}},{input:{...recipe().input,expected_org_id:other}},{input:{...recipe().input,operation_id:"invalid"}}]){
  assert.equal(readVideoRecovery(storage(JSON.stringify({...recipe(),...changed})),scope).unreadable?.reference,null);
 }
});

test("complete current recipe is usable; incomplete UI/paid fields downgrade to read-only recovery",()=>{
 const current=recipe() as any;
 delete current.input.source_mode;delete current.input.composition_profile;
 for(const source of current.input.sources){delete source.visible_frames;delete source.source_sha256;delete source.source_bytes;}
 Object.assign(current.input,{purpose:"listing",aspect:"16:9",narration_result_id:null,narration_asset_id:null,narration_words:[],music:null,presentation:{transition:"cut",shot_caption_style:"off",spoken_captions:false,title_card:null,shot_labels:[null]},allow_original_photo_fallback:false});
 assert.deepEqual(readVideoRecovery(storage(JSON.stringify(current)),scope).journal,current);
 for(const [key,value]of [["presentation",undefined],["purpose","future"],["aspect","9:16"],["narration_words",[{}]],["music",{}],["allow_original_photo_fallback",undefined]]){
  const changed=structuredClone(current);changed.input[key as string]=value;
  const recovered=readVideoRecovery(storage(JSON.stringify(changed)),scope);assert.equal(recovered.journal,null);assert.equal(recovered.unreadable?.reference?.job_id,jobID);
 }
});

test("exact accepted job is recovered by GET and original bytes are preserved before pointer removal",async()=>{
 const store=storage(),raw=store.getItem(videoScopeKey(scope)),svc=service({job:job()});
 const result=await resolveUnreadableVideo(svc,scope,readVideoRecovery(store,scope).unreadable!,store);
 assert.equal(result.job?.job_id,jobID);assert.equal(store.getItem(archive),raw);assert.equal(store.getItem(videoScopeKey(scope)),null);
 assert.equal(svc.calls.length,1);assert.equal(svc.calls[0].options.method,undefined);assert.match(svc.calls[0].path,new RegExp(`operation_id=${operation}`));
});

test("stored accepted identity cannot be replaced by missing, closed, wrong-job, or wrong-scope server replies",async()=>{
 for(const reply of [{job:null},{job:null,operation_closed:true,operation_id:operation,listing_id:listing,selected_library_org_id:library},{job:{...job(),job_id:other}},{job:{...job(),operation_id:other}},{job:{...job(),org_id:other}},{job:{...job(),selected_library_org_id:org}},{job:job(),operation_id:undefined},{job:job(),listing_id:other},{job:job(),selected_library_org_id:other}]){
  const store=storage(),raw=store.getItem(videoScopeKey(scope));
  await assert.rejects(()=>resolveUnreadableVideo(service(reply),scope,readVideoRecovery(store,scope).unreadable!,store));
  assert.equal(store.getItem(videoScopeKey(scope)),raw);assert.equal(store.getItem(archive),null);
 }
});

test("open unaccepted operation remains blocked; only explicit C2 discard with exact proof permits archival",async()=>{
 const value=recipe() as any;delete value.job_id;const store=storage(JSON.stringify(value)),request=readVideoRecovery(store,scope).unreadable!;
 const read=service({job:null});assert.deepEqual(await resolveUnreadableVideo(read,scope,request,store),{job:null,closed:false});assert.equal(store.getItem(archive),null);assert.equal(read.calls[0].options.method,undefined);
 const discard=service({job:null,operation_id:operation,listing_id:listing,selected_library_org_id:library,operation_closed:true,closed_reason:"abandoned"});
 assert.equal((await resolveUnreadableVideo(discard,scope,request,store,undefined,true)).abandoned,true);
 assert.equal(discard.calls[0].options.method,"POST");assert.match(discard.calls[0].path,/\/operations\/[^/]+\/abandon$/);assert.equal(store.getItem(archive),request.raw);assert.equal(store.getItem(videoScopeKey(scope)),null);
});

test("failed request, stale account, aborted session, changed pointer, and untrusted reference preserve the saved request",async()=>{
 for(const fault of ["network","identity","abort","pointer","reference"]){
  const store=storage(),request=readVideoRecovery(store,scope).unreadable!,controller=new AbortController();
  const svc=service(()=>{if(fault==="network")throw Error("offline");if(fault==="identity")svc.getSnapshot=()=>({status:"signed-out"});if(fault==="abort")controller.abort();if(fault==="pointer")store.setItem(videoScopeKey(scope),"new request");return{job:job()};});
  if(fault==="reference")request.reference={input:{operation_id:other},job_id:jobID};
  await assert.rejects(()=>resolveUnreadableVideo(svc,scope,request,store,controller.signal));
  assert.equal(store.getItem(archive),null);assert.ok(store.getItem(videoScopeKey(scope)));
 }
});

test("archive collision, quota failure and failed readback never remove the active pointer",async()=>{
 for(const fault of ["collision","quota","readback"]){
  const store=storage(),request=readVideoRecovery(store,scope).unreadable!;
  if(fault==="collision")store.setItem(archive,"earlier evidence");
  if(fault==="quota")store.setItem=()=>{throw Error("quota exceeded");};
  if(fault==="readback")store.setItem=()=>{};
  await assert.rejects(()=>resolveUnreadableVideo(service({job:job()}),scope,request,store));
  assert.equal(store.getItem(videoScopeKey(scope)),request.raw);
 }
});

test("missing operation and unavailable storage never dispatch recovery or paid work",async()=>{
 const store=storage("{broken"),svc=service({job:job()});
 await assert.rejects(()=>resolveUnreadableVideo(svc,scope,readVideoRecovery(store,scope).unreadable!,store),/could not match this saved video request/);
 assert.equal(svc.calls.length,0);
 assert.deepEqual(readVideoRecovery({getItem:()=>{throw Error("storage unavailable");}},scope),{journal:null,unreadable:{raw:null,reference:null}});
});
