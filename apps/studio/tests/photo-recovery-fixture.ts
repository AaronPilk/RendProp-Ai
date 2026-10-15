import {beginPhotoRequest,savedPhotoRequests,finishPhotoRequest,type SavedPhotoRequest} from "../src/features/creative/photo-request-journal";
import {retainedPhotoRequest,resumePhotoRequest} from "../src/features/creative/creative-request";
import {importedPhoto} from "../src/features/creative/photo-lineage";
import {prepareImage} from "../src/features/creative/media";
import {StudioError} from "../src/data/config";
import type {StudioServices} from "../src/data/services";
const id=(n:number)=>`f8600000-0000-4000-8000-${String(n).padStart(12,"0")}`,identity={actor:id(1),library:id(2),listing:id(3)};
let current=true,control=new AbortController();const assertScope=()=>{if(!current)throw new Error("Account/library changed");};
const api=async(_path:string,options:any)=>{
 const r=await fetch("/fixture/photo",{method:"POST",headers:{"content-type":"application/json","idempotency-key":options.idempotencyKey,"x-org-id":options.orgId,"x-rendprop-photo-quality-protocol":options.photoQualityProtocol},body:JSON.stringify(options.body),signal:options.signal});
 const body=await r.json();if(!r.ok)throw new StudioError(body.code,body.error,r.status,body);return body;
};
const services={api}as unknown as StudioServices;
async function source(){const c=document.createElement("canvas");c.width=1600;c.height=1200;const ctx=c.getContext("2d")!,pixels=ctx.createImageData(c.width,c.height);let seed=17;for(let n=0;n<pixels.data.length;n+=4){seed=(1664525*seed+1013904223)>>>0;pixels.data[n]=seed&255;pixels.data[n+1]=(seed>>>8)&255;pixels.data[n+2]=(seed>>>16)&255;pixels.data[n+3]=255;}ctx.putImageData(pixels,0,0);const data=await(await fetch(c.toDataURL("image/jpeg",.95))).blob();return importedPhoto(await prepareImage(new File([data],"immutable-master.jpg",{type:"image/jpeg",lastModified:1})));}
const original=await source(),context={channel:"single"as const,source:original,edit:"declutter"as const,style:"modern",prompt:"",originalAssetId:id(4)},body={listing_id:identity.listing,original_asset_id:id(4),image_b64:original.base64,mime:original.mime,edit:"declutter"};
Object.assign(window,{photoRecovery:{
 identity,masterBytes:original.file.size,preparedBytes:original.base64.length,
 begin:()=>beginPhotoRequest(identity,body,context),
 rows:()=>savedPhotoRequests(identity),
 send:()=>retainedPhotoRequest(services,identity,body,context,assertScope,control.signal),
 resume:async()=>{const row=(await savedPhotoRequests(identity))[0];if(!row)throw Error("No saved row");return resumePhotoRequest(services,identity,row,assertScope,control.signal);},
 resumeAs:async(key:"actor"|"library"|"listing")=>{const row=(await savedPhotoRequests(identity))[0]!;return resumePhotoRequest(services,{...identity,[key]:id(9)},row,assertScope,control.signal);},
 foreignRows:()=>savedPhotoRequests({...identity,actor:id(9)}),
 clear:async()=>{for(const row of await savedPhotoRequests(identity))await finishPhotoRequest(row,true);},
 finishUnknown:async()=>finishPhotoRequest((await savedPhotoRequests(identity))[0]!),
 abort:()=>control.abort(),renew:()=>{control=new AbortController();current=true;},switch:()=>{current=false;},
 quota:async()=>{const put=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(){throw new DOMException("Full","QuotaExceededError");};try{return await retainedPhotoRequest(services,identity,body,context,assertScope,control.signal);}finally{IDBObjectStore.prototype.put=put;}},
 quotaAfter:async()=>{const put=IDBObjectStore.prototype.put;IDBObjectStore.prototype.put=function(value:any,key?:IDBValidKey){if(value?.state==="ready")throw new DOMException("Full after paid reply","QuotaExceededError");return key===undefined?put.call(this,value):put.call(this,value,key);};try{return await retainedPhotoRequest(services,identity,body,context,assertScope,control.signal);}finally{IDBObjectStore.prototype.put=put;}},
 corrupt:async()=>{const open=indexedDB.open("rendprop-photo-requests-v1",1);await new Promise<void>((resolve,reject)=>{open.onerror=()=>reject(open.error);open.onsuccess=()=>{const db=open.result,tx=db.transaction("requests","readwrite"),s=tx.objectStore("requests"),get=s.getAll();get.onsuccess=()=>s.put({...get.result[0],requestJSON:get.result[0].requestJSON+" "});tx.oncomplete=()=>{db.close();resolve();};tx.onerror=()=>reject(tx.error);};});},
}});document.querySelector("#state")!.textContent="ready";
