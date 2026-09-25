import assert from "node:assert/strict";
import {test} from "node:test";
import {newDraft} from "../src/editor/model";
import {decodeProject,decodeProjectIndex,projectKey,projectName,type VideoProject} from "../src/features/projects/model";
import {decodeSavedMedia,downloadSavedMedia,saveCloudOriginal,type SavedMedia} from "../src/features/projects/cloud-media";
import {preserveProjectRecovery,readProjectRecovery,readProjectRecoveries,removeProjectRecovery} from "../src/features/projects/recovery";
import {DocumentSync} from "../src/data/documents";
import type {StudioServices} from "../src/data";
const ID="11111111-1111-4111-8111-111111111111",ORG="22222222-2222-4222-8222-222222222222",HASH="a".repeat(64),CHUNK=8388608;
const project=():VideoProject=>({schema:1,name:"Sunday walkthrough",archived:false,listingId:null,draft:newDraft(),sources:[]});
const media=(patch:Partial<SavedMedia>={}):SavedMedia=>({id:ID,sha256:HASH,bytes:4,mime:"video/mp4",filename:"room.mp4",modified:123,complete:true,parts:[{index:0,bytes:4,sha256:HASH,complete:true,url:"https://fixture.r2.cloudflarestorage.com/private"}],...patch});
test("project decoding bounds names, references and editor schema without inventing property identity",()=>{
 const p=project();assert.equal(decodeProject(p).listingId,null);assert.equal(projectName("  Kitchen  "),"Kitchen");assert.equal(projectKey(ID),`project:${ID}`);
 for(const patch of [{name:" "},{name:"a".repeat(81)},{name:"bad\nname"},{listingId:ID.toUpperCase().replace("1","z")},{draft:{schema:99}},{sources:[{sha256:HASH,assetId:ID,listingId:ORG},{sha256:HASH,assetId:ID,listingId:ORG}]}])assert.throws(()=>decodeProject({...p,...patch}));
 assert.throws(()=>projectKey("../../foreign"));
});
test("project index rejects malformed or unbounded metadata",()=>{
 const row={key:projectKey(ID),name:"Saved",archived:false,listingId:null,revision:1,updatedAt:"2026-09-24T00:00:00Z"};
 assert.equal(decodeProjectIndex({projects:[row]})[0].name,"Saved");
 for(const patch of [{key:"edit:"+ID},{revision:0},{archived:"false"},{updatedAt:"bad"}])assert.throws(()=>decodeProjectIndex({projects:[{...row,...patch}]}));
 assert.throws(()=>decodeProjectIndex({projects:Array(101).fill(row)}));
});
test("project CAS uses explicit null property binding and reconciles a lost confirmation once",async()=>{
 let remote:any=null,writes=0;const key=projectKey(ID);
 const services={api:async(_path:string,options:any)=>{if(options.method==="POST"){assert.equal(options.body.listing_id,null);writes++;remote={...options.body,revision:1,updated_at:new Date().toISOString()};throw new Error("lost response");}return {document:remote};}} as StudioServices;
 const sync=new DocumentSync(services,ORG,key,()=>{},{listingId:null});await sync.open();sync.queue(project() as any);await sync.flush();assert.equal(sync.state,"offline");await sync.retry();assert.equal(sync.state,"saved");assert.equal(writes,1);sync.dispose();
});
test("recovery is an independent scoped snapshot that regular autosaves cannot replace",()=>{
 const map=new Map<string,string>(),storage={setItem:(k:string,v:string)=>{map.set(k,v);},getItem:(k:string)=>map.get(k)??null};
 const original=project();preserveProjectRecovery(storage,"actorA:orgA",original);original.name="Changed";
 storage.setItem("actorA:orgA:project:"+ID+":backup",JSON.stringify(original));
 assert.equal(readProjectRecovery(storage,"actorA:orgA")?.name,"Sunday walkthrough");assert.equal(readProjectRecovery(storage,"actorB:orgA"),null);
 preserveProjectRecovery(storage,"actorA:orgA",original);assert.deepEqual(readProjectRecoveries(storage,"actorA:orgA").map(p=>p.name),["Changed","Sunday walkthrough"]);
 preserveProjectRecovery(storage,"actorA:orgA",original);assert.equal(readProjectRecoveries(storage,"actorA:orgA").length,2);
 removeProjectRecovery(storage,"actorA:orgA",0);assert.equal(readProjectRecovery(storage,"actorA:orgA")?.name,"Sunday walkthrough");
 storage.setItem("actorA:orgA:project-recoveries","not json");assert.equal(readProjectRecovery(storage,"actorA:orgA"),null);
});
test("original manifests require exact contiguous complete chunk receipts and safe metadata",()=>{
 assert.equal(decodeSavedMedia({media:null},HASH),null);assert.equal(decodeSavedMedia({media:media()},HASH)?.complete,true);
 for(const patch of [{id:"not an id"},{filename:""},{filename:"bad\nfile"},{mime:"text/html"},{bytes:134217729},{parts:[]},{parts:[{index:1,bytes:4,sha256:HASH,complete:true,url:"x"}]},{parts:[{index:0,bytes:4,sha256:null,complete:true,url:"x"}]}])assert.throws(()=>decodeSavedMedia({media:media(patch as any)},HASH));
});
test("chunk resume skips confirmed bytes and never retries an uncertain PUT automatically",async()=>{
 const file=new File([new Uint8Array(CHUNK+1)],"source.mp4",{type:"video/mp4",lastModified:123});let calls:string[]=[],lost=true;
 const receipt=media({bytes:file.size,complete:false,parts:[{index:0,bytes:CHUNK,sha256:HASH,complete:true},{index:1,bytes:1,sha256:null,complete:false}]});
 const services={api:async(path:string,o:any)=>{calls.push(`${o.method??"GET"} ${path}`);if(o.method==="PUT"){assert.ok(path.endsWith("/1"));assert.equal(o.binary.size,1);receipt.parts[1]={index:1,bytes:1,sha256:HASH,complete:true,url:"https://fixture.r2.cloudflarestorage.com/1"};receipt.parts[0].url="https://fixture.r2.cloudflarestorage.com/0";receipt.complete=true;if(lost){lost=false;throw new Error("connection lost");}}return {media:structuredClone(receipt)};}} as StudioServices;
 await assert.rejects(saveCloudOriginal(services,ORG,file,HASH,new AbortController().signal),/connection lost/);assert.equal(calls.filter(c=>c.startsWith("PUT")).length,1);
 await saveCloudOriginal(services,ORG,file,HASH,new AbortController().signal);assert.equal(calls.filter(c=>c.startsWith("PUT")).length,1);
});
test("download verifies actual chunk bytes and full file hash, with no credentials or redirects",async()=>{
 const old=globalThis.fetch,data=new Uint8Array([1,2,3,4]),hash=Buffer.from(await crypto.subtle.digest("SHA-256",data)).toString("hex");let calls=0;
 globalThis.fetch=async(_url,options)=>{calls++;assert.equal(options?.credentials,"omit");assert.equal(options?.redirect,"error");return new Response(data);};
 try{
  const good=media({sha256:hash,parts:[{index:0,bytes:4,sha256:hash,complete:true,url:"https://fixture.r2.cloudflarestorage.com/0"}]});
  assert.equal((await downloadSavedMedia(good,new AbortController().signal)).size,4);
  await assert.rejects(downloadSavedMedia({...good,sha256:HASH},new AbortController().signal),/differs/);
  await assert.rejects(downloadSavedMedia({...good,parts:[{...good.parts[0],sha256:HASH}]},new AbortController().signal),/integrity/);
  for(const url of ["https://attacker.invalid/private","https://fixture.r2.cloudflarestorage.com.attacker.invalid/x","http://fixture.r2.cloudflarestorage.com/x","https://user:pass@fixture.r2.cloudflarestorage.com/x"]){await assert.rejects(downloadSavedMedia({...good,parts:[{...good.parts[0],url}]},new AbortController().signal),/address/);}
  assert.equal(calls,3);
 }finally{globalThis.fetch=old;}
});
test("download rejects truncated and oversized streamed bytes before any file can be used",async()=>{
 const old=globalThis.fetch;
 try{for(const length of [3,5]){globalThis.fetch=async()=>new Response(new Uint8Array(length));await assert.rejects(downloadSavedMedia(media(),new AbortController().signal),/incomplete|too large/);}}
 finally{globalThis.fetch=old;}
});
