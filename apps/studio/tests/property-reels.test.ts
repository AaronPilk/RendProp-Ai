import test from "node:test";
import assert from "node:assert/strict";
import { newDraft } from "../src/editor/model";
import { earlierReels, propertyReelKey, reelPayload } from "../src/features/sync/property-reels";
import { DocumentSync } from "../src/data/documents";
import type { StudioServices } from "../src/data/services";
const a="20000000-0000-4000-8000-000000000002", b="20000000-0000-4000-8000-000000000003";
const payload={draft:{...newDraft(),title:"Earlier story"},listingId:a,sources:[]};
test("property keys differ and reject unscoped or malformed identities",()=>{
  assert.notEqual(propertyReelKey(a),propertyReelKey(b));
  for(const id of ["", "edit", "../../account", "-".repeat(36)])assert.throws(()=>propertyReelKey(id));
  assert.throws(()=>reelPayload(payload,b));
  assert.throws(()=>reelPayload({...payload,sources:[{sha256:"a".repeat(64),assetId:a,listingId:b}]},a));
});
test("legacy recovery reads copies without changing any key and never offers another property's bound reel",()=>{
  const values=new Map([["scope:edit:cloud-backup",JSON.stringify(payload)],["scope:edit",JSON.stringify(payload.draft)]]);
  const before=[...values];const storage={getItem:(key:string)=>values.get(key)??null};
  const cloud={key:"edit",kind:"edit",listing_id:null,revision:3,payload,updated_at:new Date().toISOString()};
  const recovery=earlierReels(storage,"scope:edit",a,cloud);
  assert.equal(recovery.copies.length,1);assert.deepEqual([...values],before);
  const other=earlierReels({getItem:()=>null},"scope:edit",b,cloud);
  assert.equal(other.copies.length,0);assert.equal(other.unreadable,false);
});
test("unassigned and damaged legacy copies remain explicit without destroying a valid alternative",()=>{
  const storage={getItem:(key:string)=>key.endsWith(":cloud-backup")?"{":key==="scope:edit"?JSON.stringify(payload.draft):null};
  const result=earlierReels(storage,"scope:edit",a,null);
  assert.equal(result.unreadable,true);assert.equal(result.copies.length,1);assert.equal(result.copies[0].payload.listingId,a);
});
test("per-property DocumentSync writes exact listing binding and independent CAS revisions",async()=>{
  const docs=new Map<string,object>(),writes:Record<string,unknown>[]=[];
  const services={api:async(path:string,options:{body?:Record<string,unknown>})=>{
    if(options.body){const body=options.body;writes.push(body);docs.set(String(body.key),{key:body.key,kind:body.kind,listing_id:body.listing_id,revision:Number(body.expected_revision)+1,payload:body.payload,updated_at:new Date().toISOString()});}
    const key=options.body?.key??new URL(path,"https://fixture.invalid").searchParams.get("key");return{document:docs.get(String(key))??null};
  }} as unknown as StudioServices;
  const first=new DocumentSync(services,a,propertyReelKey(a),()=>{}),second=new DocumentSync(services,a,propertyReelKey(b),()=>{});
  await first.open();await second.open();first.queue(payload);second.queue({...payload,listingId:b});await first.flush();await second.flush();
  assert.deepEqual(writes.map(body=>[body.key,body.listing_id,body.expected_revision]),[[`edit:${a}`,a,0],[`edit:${b}`,b,0]]);
  first.dispose();second.dispose();
});
