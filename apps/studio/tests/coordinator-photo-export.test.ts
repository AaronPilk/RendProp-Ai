import assert from "node:assert/strict";
import test from "node:test";
import { createHash } from "node:crypto";
import { coordinatorCategory, coordinatorPhotoParts, loadCoordinatorPhoto, loadCoordinatorPhotos, type CoordinatorLoaded } from "../src/features/creative/coordinator-photo-export";
import { photoFrame, buildPhotoDownload } from "../src/features/creative/photo-export";
import type { StudioPhoto } from "../src/data/contracts";
const signal=()=>new AbortController().signal,png=new Uint8Array([137,80,78,71,13,10,26,10,1,2,3]);
const master=new File([png],"master.png",{type:"image/png"}),original=new File([new Uint8Array([...png,99])],"source.png",{type:"image/png"});
const photo=(i:number,editKind?:StudioPhoto["editKind"]):StudioPhoto=>({id:`photo-${i}`,listingId:"listing",url:`https://media.invalid/${i}`,expiresAt:"2099-01-01T00:00:00Z",caption:"Exact saved disclosure",isAltered:true,isStaged:true,editKind,originalVerified:true,sort:i});
const load=async(p:StudioPhoto):Promise<CoordinatorLoaded>=>({category:coordinatorCategory(p),delivery:{file:master,original,originalPreview:null,originalVerified:true,edits:[p.editKind||"unknown"],disclosures:[p.caption!],provenanceId:null}});
const render=async(_photo:unknown,options:{ratio:any})=>({blob:new Blob([`jpeg-${options.ratio}`]),...photoFrame(4000,3000,options.ratio)});
const hash=(b:Uint8Array)=>createHash("sha256").update(b).digest("hex");
async function unzip(blob:Blob){const bytes=new Uint8Array(await blob.arrayBuffer()),v=new DataView(bytes.buffer),files=new Map<string,Uint8Array>();let at=0;while(v.getUint32(at,true)===0x04034b50){const size=v.getUint32(at+18,true),n=v.getUint16(at+26,true),extra=v.getUint16(at+28,true),start=at+30+n+extra,path=new TextDecoder().decode(bytes.slice(at+30,at+30+n));assert.ok(!files.has(path));files.set(path,bytes.slice(start,start+size));at=start+size;}return files;}
test("coordinator folders require typed edit identity, not caption or legacy staged flag",()=>{
 assert.equal(coordinatorCategory({...photo(1),caption:"Staged and decluttered"}),"Edited");assert.equal(coordinatorCategory(photo(1,"stage")),"Staged");assert.equal(coordinatorCategory(photo(1,"declutter")),"Decluttered");assert.equal(coordinatorCategory({...photo(1),isAltered:false,isStaged:false}),"Originals");
});
test("100 saved versions retain exact masters, all native destination presets and order across numbered bounded ZIPs",async()=>{
 const photos=Array.from({length:100},(_,i)=>photo(i,i%2?"stage":"declutter")),seen=new Set<string>(),records:any[]=[];let count=0,rendered=0,last=0;
 for await(const part of coordinatorPhotoParts(photos,signal(),()=>{},{load,render:async(...args)=>{rendered++;return render(...args);}})){
  count++;assert.equal(part.part,count);assert.equal(part.from,last+1);last=part.through;assert.ok(part.files<=128);
  const files=await unzip(part.blob),manifest=JSON.parse(new TextDecoder().decode(files.get(`manifest-part-${String(count).padStart(2,"0")}.json`)));assert.equal(manifest.totalPhotos,100);records.push(...manifest.files);
  for(const path of files.keys()){assert.ok(!seen.has(path),`cross-part collision:${path}`);seen.add(path);}
  for(const row of manifest.files){assert.deepEqual(files.get(row.masterPath),png);assert.equal(row.masterSHA256,hash(png));assert.deepEqual(files.get(row.originalPath),new Uint8Array(await original.arrayBuffer()));assert.equal(row.copies.length,4);for(const c of row.copies){assert.ok(files.has(c.path));assert.equal(c.sha256,hash(files.get(c.path)!));assert.ok(c.width<=4000&&c.height<=3000);}}
  assert.equal(part.more,part.through<100);
 }
 assert.ok(count>1);assert.equal(last,100);assert.equal(rendered,400);assert.deepEqual(records.map(r=>r.photoId),photos.map(p=>p.id));
 for(const prefix of ["Originals/","Staged/","Decluttered/","MLS/","Zillow/","Instagram/Feed4x5/","Instagram/Stories9x16/"])assert.ok([...seen].some(p=>p.startsWith(prefix)));
});
test("entry and byte boundaries never omit a photo family or downsample to fit",async()=>{
 const parts=[];for await(const p of coordinatorPhotoParts([photo(1,"stage"),photo(2,"declutter")],signal(),()=>{},{load,render,maxEntries:14}))parts.push(p);
 assert.deepEqual(parts.map(p=>[p.from,p.through,p.more]),[[1,1,true],[2,2,false]]);
 await assert.rejects(async()=>{for await(const _p of coordinatorPhotoParts([photo(1)],signal(),()=>{},{load,render,maxBytes:1024*1024+1})){}},/family exceeds/);
});
test("all media pages are scoped, complete and ordered; missing or conflicting pages fail",async()=>{
 const calls:number[]=[],service={listMedia:async(_org:string,_listing:string,_signal?:AbortSignal,offset=0)=>{calls.push(offset);return{orgId:"org",listingId:"listing",photos:offset?[photo(51)]:Array.from({length:50},(_,i)=>photo(i)),videos:[],nextOffset:offset?null:50,unavailableCount:0};}};
 assert.equal((await loadCoordinatorPhotos(service as any,"org","listing",signal(),()=>{})).length,51);assert.deepEqual(calls,[0,50]);
 for(const bad of [{orgId:"other"},{listingId:"other"},{unavailableCount:1},{nextOffset:1},{photos:[photo(1),photo(1)]}])await assert.rejects(loadCoordinatorPhotos({listMedia:async()=>({orgId:"org",listingId:"listing",photos:[photo(1)],videos:[],nextOffset:null,unavailableCount:0,...bad})} as any,"org","listing",signal(),()=>{}));
});
test("actual streamed saved bytes are retained and unknown paired history never becomes an original",async()=>{
 const saved=globalThis.fetch,requests:string[]=[];globalThis.fetch=async(input,init)=>{requests.push(String(input));assert.equal(init?.credentials,"omit");assert.equal(init?.redirect,"error");return new Response(png,{headers:{"content-length":String(png.length)}});};
 try{const p=await loadCoordinatorPhoto({...photo(1),originalVerified:false,originalUrl:"https://media.invalid/original"},signal(),()=>{});assert.equal(p.category,"Edited");assert.equal(p.delivery.original,null);assert.deepEqual(new Uint8Array(await p.delivery.file.arrayBuffer()),png);assert.equal(requests.length,2);assert.deepEqual(new Uint8Array(await p.earlierSource!.arrayBuffer()),png);
 const first=await coordinatorPhotoParts([photo(1)],signal(),()=>{},{load:async()=>p,render}).next();assert.ok(!first.done);const zip=await unzip(first.value.blob);assert.ok([...zip.keys()].some(path=>path.startsWith("EarlierSources/")));assert.ok(![...zip.keys()].some(path=>path.startsWith("Originals/")));}finally{globalThis.fetch=saved;}
});
test("account changes, cancellation and missing saved sources cannot yield a completed package",async()=>{
 let current=true;await assert.rejects(async()=>{for await(const _p of coordinatorPhotoParts([photo(1)],signal(),()=>{if(!current)throw Error("Account changed");},{load,render:async(...args)=>{current=false;return render(...args);}})){}},/Account changed/);
 const c=new AbortController();c.abort();await assert.rejects(async()=>{for await(const _p of coordinatorPhotoParts([photo(1)],c.signal,()=>{},{load,render})){}},/abort/i);
 await assert.rejects(async()=>{for await(const _p of coordinatorPhotoParts([photo(1)],signal(),()=>{},{load:async()=>{throw Error("Saved source unavailable");},render})){}},/Saved source/);
});
test("ordinary completed-photo export no longer has the arbitrary six-photo ceiling",async()=>{
 const item=(await load(photo(1))).delivery,out=await buildPhotoDownload(Array.from({length:7},()=>item),{destination:"mls",ratio:"original"},signal(),()=>{},render);assert.ok((await unzip(out.blob)).size>14);
});
test("real HEIC original bytes survive when a browser cannot create delivery copies; no JPEG substitute or partial copies",async()=>{
 const {readFile}=await import("node:fs/promises"),heic=new Uint8Array(await readFile(new URL("./fixtures/coordinator-source.heic",import.meta.url))),saved=globalThis.fetch;
 globalThis.fetch=async()=>new Response(heic,{headers:{"content-length":String(heic.length)}});
 try{
  const input={...photo(9),isAltered:false,isStaged:false,originalUrl:null},loaded=await loadCoordinatorPhoto(input,signal(),()=>{});
  assert.equal(loaded.delivery.file.type,"image/heic");assert.deepEqual(new Uint8Array(await loaded.delivery.file.arrayBuffer()),heic);
  const first=await coordinatorPhotoParts([input],signal(),()=>{},{load:async()=>loaded,render:async()=>{throw new DOMException("HEIC unavailable","InvalidStateError");}}).next();assert.ok(!first.done);
  const zip=await unzip(first.value.blob),proof=JSON.parse(new TextDecoder().decode(zip.get("manifest-part-01.json")));
  assert.deepEqual(zip.get(proof.files[0].masterPath),heic);assert.match(proof.files[0].masterPath,/^Originals\/.*\.heic$/);assert.deepEqual(proof.files[0].copies,[]);assert.equal(proof.notes.length,1);assert.ok(![...zip.keys()].some(path=>path.endsWith(".jpg")));
 }finally{globalThis.fetch=saved;}
});
