import assert from 'node:assert/strict';
import {test} from 'node:test';
import {prepareVideoSources} from '../src/features/sync/source-preparation';
import {decodeSources,type VideoScope,type VideoSource} from '../src/features/sync/property-video';
const actor='11111111-1111-4111-8111-111111111111',org='22222222-2222-4222-8222-222222222222',listing='44444444-4444-4444-8444-444444444444',master='55555555-5555-4555-8555-555555555555',derived='66666666-6666-4666-8666-666666666666',prep='77777777-7777-4777-8777-777777777777';
const scope:VideoScope={actor,org,library:org,listing,identityVersion:1};
const original:VideoSource={photo_id:'selected-staged',photo_asset_id:master,photo_version_id:`asset:${master}`,photo_provenance_id:prep,preview_url:null,bytes:12*1024*1024,sha256:'a'.repeat(64),eligible:false,needs_preparation:true,reason:null};
const prepared={...original,photo_asset_id:derived,bytes:100,sha256:'b'.repeat(64),eligible:true,needs_preparation:false,preparation:{preparation_id:prep,source_asset_id:master,source_sha256:'a'.repeat(64),width:2048,height:1365,policy:'video-jpeg-v1'}};
const storage=()=>{const values=new Map<string,string>();return{getItem:(key:string)=>values.get(key)??null,setItem:(key:string,value:string)=>values.set(key,value),values};};
const service=(api:(path:string,options:any)=>Promise<unknown>)=>({api,getSnapshot:()=>({status:'signed-in',identityVersion:1,identity:{userId:actor,isAnonymous:false}})}) as any;
const reply=(operation:string,state='ready',source:unknown=prepared)=>({preparation_id:prep,operation_id:operation,listing_id:listing,org_id:org,selected_library_org_id:org,state,source:state==='ready'?source:null});
test('lost preparation reply retries identical durable op; ready derivative preserves exact staged master and orientation geometry',async()=>{
 const saved=storage();const calls:any[]=[];let operation='',lost=true;
 const svc=service(async(path,options)=>{calls.push({path,options});if(options.method==='POST'){operation=options.body.operation_id;assert.ok(saved.values.size===1);assert.equal(options.body.photo_asset_id,master);assert.equal(options.body.photo_version_id,original.photo_version_id);assert.equal(options.idempotencyKey,`property-video-source:${operation}`);if(lost){lost=false;throw Error('lost prepared response');}}return reply(operation);});
 await assert.rejects(prepareVideoSources(svc,scope,[original],saved),/lost prepared/);const result=await prepareVideoSources(svc,scope,[original],saved);assert.equal(calls[0].options.body.operation_id,calls[1].options.body.operation_id);assert.equal(result[0]!.photo_asset_id,derived);assert.equal(result[0]!.photo_version_id,original.photo_version_id);assert.equal(result[0]!.photo_provenance_id,prep);assert.equal(result[0]!.preparation!.source_asset_id,master);assert.ok(![...saved.values.values()][0]!.includes('https://'));
 await prepareVideoSources(svc,scope,[original],saved);assert.equal(calls.at(-1).options.method,undefined);assert.ok(calls.at(-1).path.endsWith(prep));
});
test('pending source prep polls only saved ID and refuses wrong property/changed original SHA/alias',async()=>{
 for(const source of[{...prepared,preparation:{...prepared.preparation,source_sha256:'c'.repeat(64)}},{...prepared,photo_version_id:`asset:${derived}`},{...prepared,preparation:{...prepared.preparation,width:4096}}])await assert.rejects(prepareVideoSources(service(async(_path,options)=>reply(options.body.operation_id,'ready',source)),scope,[original],storage()));
 let polls=0,operation='';const svc=service(async(_path,options)=>{if(options.body){operation=options.body.operation_id;return reply(operation,'queued');}polls++;return reply(operation);});assert.equal((await prepareVideoSources(svc,scope,[original],storage(),undefined,undefined,async()=>{}))[0]!.photo_asset_id,derived);assert.equal(polls,1);
 const controller=new AbortController();controller.abort();await assert.rejects(prepareVideoSources(svc,scope,[original],storage(),controller.signal),/account changed/);
});
test('source decoder accepts only explicit prepared master lineage and preserves raw50MB eligibility for preparation',()=>{
 const payload=(source:unknown)=>({listing_id:listing,org_id:org,selected_library_org_id:org,selected_count:1,sources:[source],next_offset:null});assert.equal(decodeSources(payload(original),scope)[0]!.needs_preparation,true);assert.equal(decodeSources(payload(prepared),scope)[0]!.eligible,true);
 const missing={...prepared};delete (missing as any).preparation;assert.throws(()=>decodeSources(payload(missing),scope));assert.throws(()=>decodeSources(payload({...original,bytes:50*1024*1024+1}),scope));
});
