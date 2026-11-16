import assert from "node:assert/strict";
import test from "node:test";
import {definitivePhotoRefusal} from "../src/features/creative/creative-request";
import {photoRequestScope,photoRequestHash,photoUploadOperation,validateSavedPhotoRequest,type SavedPhotoRequest} from "../src/features/creative/photo-request-journal";
import {StudioError} from "../src/data/config";
test("saved output upload binds operation and identity while keeping selected library distinct from physical org",async()=>{
 const id=(n:number)=>`f8600000-0000-4000-8000-${String(n).padStart(12,"0")}`,identity={actor:id(1),library:id(2),listing:id(3)},physical=id(9),key=`studio-photo:${id(4)}`;
 const file=new File(["original"],"original.jpg",{type:"image/jpeg"}),source={file,base64:"c291cmNl",mime:"image/jpeg"as const,preview:"data:image/jpeg;base64,c291cmNl"};
 const sourceId=await photoRequestHash("original"),requestJSON=JSON.stringify({listing_id:identity.listing,original_asset_id:id(5),edit:"declutter",image_b64:source.base64,mime:source.mime}),resultJSON=JSON.stringify({image_b64:"b3V0",mime:"image/jpeg",disclosure:"AI edited"});
 const row:SavedPhotoRequest={schema:1,slot:photoRequestScope(identity)+":"+sourceId,scope:photoRequestScope(identity),identity,sourceId,versionId:await photoRequestHash(source.base64),requestKey:key,requestJSON,requestSHA:await photoRequestHash(requestJSON),context:{channel:"single",source:{...source,original:source,originalVerified:true,disclosures:[],edits:[]},edit:"declutter",style:"modern",prompt:"",originalAssetId:id(5)},state:"ready",resultJSON,resultSHA:await photoRequestHash(resultJSON),createdAt:1,outputUpload:{version:1,userId:identity.actor,orgId:physical,listingId:identity.listing,role:"gallery",filename:"result.jpg",contentType:"image/jpeg",bytes:3,fingerprint:"a".repeat(64),operationId:id(4),assetId:id(6),parts:[],updatedAt:"now"}};
 assert.equal((await validateSavedPhotoRequest(row,identity)).outputUpload?.orgId,physical);assert.equal(photoUploadOperation(key),id(4));
 for(const k of["studio-photo:------------------------------------",`studio-photo-batch:${id(4)}`,"",key+"x"])assert.throws(()=>photoUploadOperation(k));
 for(const field of["actor","library","listing"]as const)await assert.rejects(validateSavedPhotoRequest(row,{...identity,[field]:id(8)}));
 for(const change of[{userId:id(7)},{listingId:id(7)},{role:"original"as const},{operationId:id(7)},{assetId:"invalid"}])await assert.rejects(validateSavedPhotoRequest({...row,outputUpload:{...row.outputUpload!,...change}},identity));
 await assert.rejects(validateSavedPhotoRequest({...row,state:"pending"},identity));
 assert.equal((await validateSavedPhotoRequest({...row,outputUpload:undefined},identity)).outputUpload,undefined);
});
test("only definite no-dispatch/terminal refusal releases a saved photo operation",()=>{
 for(const error of[new Error("lost"),new StudioError("photo_quality_pending","saved",409),new StudioError("photo_quality_hold","uncertain",409),new StudioError("request-failed","access changed",403),new StudioError("request-failed","missing",404),new StudioError("request-failed","provider failed",503),new StudioError("request-failed","possibly paid",402,{provider_cost_incurred:"possible",no_provider_dispatch:true})])assert.equal(definitivePhotoRefusal(error),false);
 for(const error of[new StudioError("photo_quality_refused","refused",422),new StudioError("request-failed","quota before dispatch",402),new StudioError("request-failed","invalid before dispatch",400),new StudioError("request-failed","too large",413),new StudioError("request-failed","no dispatch",409,{no_provider_dispatch:true})])assert.equal(definitivePhotoRefusal(error),true);
});
test("photo recovery scope binds canonical actor/library/property without adopting another identity",()=>{
 const id=(n:number)=>`f8600000-0000-4000-8000-${String(n).padStart(12,"0")}`,scope={actor:id(1),library:id(2),listing:id(3)};
 assert.equal(photoRequestScope({...scope,actor:scope.actor.toUpperCase()}),photoRequestScope(scope));
 for(const key of["actor","library","listing"]as const)assert.notEqual(photoRequestScope({...scope,[key]:id(4)}),photoRequestScope(scope));
 assert.throws(()=>photoRequestScope({...scope,actor:""}));
});

test("only authoritative closed422 may release a paid HOLD; active/unknown and marker mismatches remain retained",()=>{
 for(const cost of[true,"possible",false])assert.equal(definitivePhotoRefusal(new StudioError("photo_quality_closed","Closed; another edit may use allowance",422,{operation_closed:true,provider_cost_incurred:cost})),true);
 for(const error of[
  new StudioError("photo_quality_closed","Wrong status",409,{operation_closed:true}),
  new StudioError("photo_quality_closed","Missing marker",422),
  new StudioError("photo_quality_closed","Not closed",422,{operation_closed:false,no_provider_dispatch:true}),
  new StudioError("photo_quality_hold","Still checking",409,{operation_closed:true,provider_cost_incurred:"possible"}),
  new StudioError("photo_quality_pending","Still pending",409,{provider_cost_incurred:true}),
  new StudioError("request-failed","Unknown network",503,{operation_closed:true}),
 ])assert.equal(definitivePhotoRefusal(error),false);
});
