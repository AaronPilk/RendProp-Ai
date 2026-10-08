import { test } from "node:test";
import assert from "node:assert/strict";
import { readPendingPhotoRequest, photoRequestStorageKey, type PendingPhotoRequest } from "../src/features/creative/photo-request";
const scope = {actor:"11111111-1111-4111-8111-111111111111",org:"22222222-2222-4222-8222-222222222222",listing:"33333333-3333-4333-8333-333333333333"};
const original = "44444444-4444-4444-8444-444444444444", key = "55555555-5555-4555-8555-555555555555";
function fixture(): PendingPhotoRequest {
  const image = {file:new File(["synthetic source"],"source.jpg",{type:"image/jpeg"}),mime:"image/jpeg" as const,base64:"QUFB",preview:"data:image/jpeg;base64,QUFB"};
  return {version:1,scope:{...scope},requestKey:key,source:{...image,original:image,originalVerified:true,originalAssetId:original,edits:[],disclosures:[]},
    body:{listing_id:scope.listing,original_asset_id:original,image_b64:image.base64,mime:image.mime,edit:"custom",space_type:"real_estate",label:"Kitchen",prompt:"Remove movable boxes."}};
}
test("exact account, photo version and custom prompt survive recovery unchanged",()=>{
 const request=fixture();assert.equal(readPendingPhotoRequest(request,scope),request);
 assert.equal(JSON.stringify(readPendingPhotoRequest(request,scope).body),JSON.stringify(request.body));
 assert.deepEqual(request.source.edits,[]);assert.equal(request.source.original?.file.name,"source.jpg");
});
test("stage recovery uses the precise pre-staging version and keeps the original/history",()=>{
 const request=fixture();request.source.stageBase={...request.source,base64:"QkJC",preview:"data:image/jpeg;base64,QkJC",edits:["Digitally decluttered"],disclosures:["Decluttered with AI."]};
 request.body={...request.body,edit:"stage",style:"modern",image_b64:"QkJC"};delete request.body.prompt;
 assert.equal(readPendingPhotoRequest(request,scope).source.stageBase?.base64,"QkJC");
 assert.equal(request.source.originalAssetId,original);
});
test("wrong account/workspace/listing cannot recover a pending request",()=>{
 for(const field of ["actor","org","listing"] as const)assert.throws(()=>readPendingPhotoRequest(fixture(),{...scope,[field]:"99999999-9999-4999-8999-999999999999"}));
 assert.throws(()=>photoRequestStorageKey({...scope,actor:undefined as unknown as string}));
});
test("changed photo bytes, source version or original cannot enter recovery",()=>{
 for(const change of [
  (r:PendingPhotoRequest)=>{r.body.image_b64="QkJC";},
  (r:PendingPhotoRequest)=>{r.source.preview="data:image/jpeg;base64,QkJC";},
  (r:PendingPhotoRequest)=>{r.source.originalAssetId=scope.actor;},
  (r:PendingPhotoRequest)=>{r.source.originalVerified=false;},
  (r:PendingPhotoRequest)=>{r.source.original=null;},
  (r:PendingPhotoRequest)=>{r.body.listing_id=scope.actor;},
  (r:PendingPhotoRequest)=>{r.body.mime="image/png";},
  (r:PendingPhotoRequest)=>{r.source.file=new File([],"empty.jpg");},
 ]){const request=fixture();change(request);assert.throws(()=>readPendingPhotoRequest(request,scope));}
});
test("invalid request settings and unknown input fields refuse before dispatch",()=>{
 for(const change of [
  (r:PendingPhotoRequest)=>{r.requestKey="bad";},
  (r:PendingPhotoRequest)=>{r.body.prompt="";},
  (r:PendingPhotoRequest)=>{r.body.prompt="a".repeat(601);},
  (r:PendingPhotoRequest)=>{r.body.style="modern";},
  (r:PendingPhotoRequest)=>{(r.body as unknown as Record<string,unknown>).staging_reference_b64="QUFB";},
  (r:PendingPhotoRequest)=>{r.body.edit="stage";delete r.body.prompt;},
 ]){const request=fixture();change(request);assert.throws(()=>readPendingPhotoRequest(request,scope));}
});
test("retained completed results require bounded image and disclosure metadata",()=>{
 const request=fixture();request.result={image_b64:"QUFB",mime:"image/jpeg",disclosure:"AI edited.",provenance:{recorded:false,id:null}};
 assert.equal(readPendingPhotoRequest(request,scope).result?.image_b64,"QUFB");
 for(const change of [
  (r:PendingPhotoRequest)=>{r.result!.mime="text/html";},
  (r:PendingPhotoRequest)=>{r.result!.image_b64="bad bytes!";},
  (r:PendingPhotoRequest)=>{r.result!.disclosure="";},
  (r:PendingPhotoRequest)=>{r.result!.provenance.id="not-a-provenance-id";},
 ]){const candidate={...request,result:{...request.result,provenance:{...request.result.provenance}}};change(candidate);assert.throws(()=>readPendingPhotoRequest(candidate,scope));}
});
