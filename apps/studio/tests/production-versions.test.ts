import test from "node:test";
import assert from "node:assert/strict";
import {canCopyVersion,decodeCopyResult,decodeVersionPage,decodeVersionSnapshot,versionPath} from "../src/features/production/versions";
import {newDraft} from "../src/editor/model";
import {newProductionPlan} from "../src/features/production/model";
import type {Workspace} from "../src/data/contracts";
const org="10000000-0000-4000-8000-000000000001",listing="20000000-0000-4000-8000-000000000002",author="40000000-0000-4000-8000-000000000004",actor="40000000-0000-4000-8000-000000000099";
const choice={listingId:listing,authorId:author,revision:3};
function metadata(user=author,revision=3){return {id:"90000000-0000-4000-8000-000000000001",document_user_id:user,org_id:org,key:`edit:${listing}`,listing_id:listing,document_revision:revision,reason:"submitted" as const,created_at:"2026-09-24T12:00:00Z"};}
function doc(revision=3){return {key:`edit:${listing}`,kind:"edit",listing_id:listing,revision,payload:{draft:{...newDraft(),title:"An actual saved title"},listingId:listing,sources:[]},updated_at:"2026-09-24T12:00:00Z"};}
test("only a current editable membership exposes copy controls",()=>{
  const workspace={org:{id:org},memberships:[{orgId:org,role:"agent"}]} as Pick<Workspace,"org"|"memberships">;assert.equal(canCopyVersion(workspace),true);
  workspace.memberships[0].role="marketing";assert.equal(canCopyVersion(workspace),false);workspace.memberships=[];assert.equal(canCopyVersion(workspace),false);
});
test("immutable version paths bind the exact author, listing, revision and page",()=>{
  const path=new URL(versionPath("version",choice),"https://fixture.invalid");assert.equal(path.searchParams.get("key"),`edit:${listing}`);assert.equal(path.searchParams.get("document_user_id"),author);assert.equal(path.searchParams.get("document_revision"),"3");
  assert.equal(new URL(versionPath("versions",choice,50),"https://fixture.invalid").searchParams.get("offset"),"50");
});
test("history rejects cross-scope metadata, duplicate revision rows and unbounded paging",()=>{
  const page={versions:[metadata()],next_offset:null};assert.equal(decodeVersionPage(page,org,choice,0).versions.length,1);
  for(const patch of [{org_id:actor},{listing_id:actor},{document_user_id:actor},{document_revision:0}])assert.throws(()=>decodeVersionPage({...page,versions:[{...metadata(),...patch}]},org,choice,0));
  assert.throws(()=>decodeVersionPage({...page,next_offset:51},org,choice,0));assert.throws(()=>decodeVersionPage({...page,versions:[metadata(),metadata()]},org,choice,0));
});
test("snapshot validates frozen brief and exact document revision without changing caller state",()=>{
  const raw={version:metadata(),document:doc(),brief:newProductionPlan(listing)},before=structuredClone(raw);const parsed=decodeVersionSnapshot(raw,org,choice);assert.equal(parsed.document.payload.draft!==undefined,true);assert.equal(parsed.brief?.listingId,listing);assert.deepEqual(raw,before);
  assert.throws(()=>decodeVersionSnapshot({...raw,document:doc(4)},org,choice));assert.throws(()=>decodeVersionSnapshot({...raw,brief:newProductionPlan(actor)},org,choice));assert.equal(decodeVersionSnapshot({version:metadata(),document:doc()},org,choice).brief,null);
});
test("copy confirmation requires target CAS increment and preservation of actor's exact previous revision",()=>{
  const raw={document:doc(8),source_version:metadata(),preserved_version:{...metadata(actor,7),reason:"before_replace"}};
  assert.equal(decodeCopyResult(raw,org,actor,choice,7).document.revision,8);
  for(const changed of [{...raw,document:doc(9)},{...raw,preserved_version:null},{...raw,preserved_version:metadata(author,7)},{...raw,preserved_version:metadata(actor,6)},{...raw,source_version:metadata(author,2)}])assert.throws(()=>decodeCopyResult(changed,org,actor,choice,7));
});
test("first copy accepts no prior target while malformed saved edit remains unconfirmed",()=>{
  const raw={document:doc(1),source_version:metadata(),preserved_version:null};assert.equal(decodeCopyResult(raw,org,actor,choice,0).preservedVersion,null);
  assert.throws(()=>decodeCopyResult({...raw,preserved_version:metadata(actor,1)},org,actor,choice,0));
  assert.throws(()=>decodeCopyResult({...raw,document:{...doc(1),payload:{draft:{schema:99},listingId:listing,sources:[]}}},org,actor,choice,0));
});
