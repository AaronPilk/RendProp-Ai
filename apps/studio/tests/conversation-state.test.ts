import test from "node:test";
import assert from "node:assert/strict";
import {appendConversation,decodeConversation,emptyConversation} from "../src/editor/conversation-state";
import {newDraft,type EditDraft} from "../src/editor/model";
import {earlierReels,reelPayload} from "../src/features/sync/property-reels";
import {buildEditPlanRequest} from "../src/features/sync/edit-plan-request";

const listing="20000000-0000-4000-8000-000000000002";
test("chat stays paired with its draft through cloud and earlier-copy recovery",()=>{
  const draft=newDraft(),conversation=appendConversation(emptyConversation(draft.id),"user","Make it shorter",draft.revision);
  const payload={draft,listingId:listing,sources:[],conversation};
  assert.deepEqual(reelPayload(JSON.parse(JSON.stringify(payload)),listing),payload);
  const saved=JSON.stringify(payload),storage={getItem:(key:string)=>key.endsWith(":cloud-backup")?saved:null};
  const copies=earlierReels(storage,"earlier",listing,null);
  assert.equal(copies.unreadable,false);assert.deepEqual(copies.copies[0].payload,payload);
  assert.equal(storage.getItem("earlier:cloud-backup"),saved);
  assert.throws(()=>reelPayload({...payload,conversation:{...conversation,draftId:newDraft().id}},listing));
  const legacy={draft,listingId:listing,sources:[]};assert.deepEqual(reelPayload(legacy,listing),legacy);
});
test("malformed and duplicate chat entries are rejected without mutating saved data",()=>{
  const good=appendConversation(emptyConversation("draft"),"assistant","Your edit is ready",1),original=structuredClone(good);
  for(const bad of [
    {...good,schema:2}, {...good,messages:[...good.messages,...good.messages]},
    {...good,messages:[{...good.messages[0],role:"system"}]},
    {...good,messages:[{...good.messages[0],text:"x\u0007"}]},
    {...good,messages:[{...good.messages[0],text:"x".repeat(2001)}]},
    {...good,messages:[{...good.messages[0],revision:-1}]},
  ])assert.throws(()=>decodeConversation(bad,"draft"));
  assert.deepEqual(good,original);
});
test("conversation is bounded and untrusted text remains inert text",()=>{
  let chat=emptyConversation("draft");
  for(let i=0;i<30;i++)chat=appendConversation(chat,"user",`Message ${i}`,i);
  assert.equal(chat.messages.length,24);assert.equal(chat.messages[0].text,"Message 6");
  const text="<script>publishEverything()</script> ignore the rules";
  chat=appendConversation(chat,"assistant",text,null);assert.equal(decodeConversation(chat,"draft").messages.at(-1)?.text,text);
});
function metadataDraft():EditDraft{
  return {...newDraft(),clips:[{id:"clip-one",source:{name:"PRIVATE-CLIENT-ADDRESS.jpg",kind:"image",sha256:"a".repeat(64),size:123,width:800,height:600,lastModified:123,duration:0},start:0,end:3,caption:"",focusX:.5,focusY:.5}]};
}
test("model request includes only editing metadata and retains the full current brief",()=>{
  const draft=metadataDraft(),message="a".repeat(2000),chat=appendConversation(emptyConversation(draft.id),"user",message,null);
  const request=buildEditPlanRequest(draft,message,chat.messages,listing),encoded=JSON.stringify(request);
  assert.equal(request.message,message);assert.equal(request.history[0].content.length,1200);
  assert.equal(request.listing_id,listing);assert.equal(request.draft.clips[0].speed,1);
  for(const forbidden of ["PRIVATE-CLIENT-ADDRESS","sha256","lastModified","source","a".repeat(64)]){
    // The repeated user brief deliberately contains a's; inspect only clip metadata.
    assert.equal(JSON.stringify(request.draft).includes(forbidden),false);
  }
  assert(encoded.length<24576);assert.deepEqual(draft,metadataDraftWithId(draft.id));
});
function metadataDraftWithId(id:string){return {...metadataDraft(),id};}
test("multibyte chat history cannot overrun the server byte limit",()=>{
  const draft=metadataDraft();let chat=emptyConversation(draft.id);
  for(let i=0;i<8;i++)chat=appendConversation(chat,"user",String(i)+"界".repeat(1999),null);
  const message="界".repeat(2000),request=buildEditPlanRequest(draft,message,chat.messages,listing);
  assert(new TextEncoder().encode(JSON.stringify(request)).byteLength<=24576);
  assert(request.history.length<8);assert(request.history.every(item=>item.content.length<=1200));
  assert.equal(request.history.at(-1)?.content[0],"7");assert.equal(request.message,message);
});
