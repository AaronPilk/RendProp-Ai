import assert from "node:assert/strict";
import test from "node:test";
import {changeProductionFormat,decodeProductionPlan,newProductionPlan,planProgress} from "../src/features/production/model";
import {commentPosition,decodeReviewBundle,timeLabel} from "../src/features/production/review";
import {newDraft} from "../src/editor/model";
const listing="20000000-0000-4000-8000-000000000002",other="20000000-0000-4000-8000-000000000003",org="10000000-0000-4000-8000-000000000001",user="40000000-0000-4000-8000-000000000004";
test("changing format preserves completed coverage, linked sources and notes",()=>{
  const plan=newProductionPlan(listing);plan.shots[0].status="captured";plan.shots[0].notes="Use the afternoon angle";plan.shots[0].sourceVideoIds=[other];
  const changed=changeProductionFormat(plan,"market-update");
  const preserved=changed.shots.find(shot=>shot.id==="exterior")!;
  assert.equal(preserved.status,"captured");assert.equal(preserved.notes,"Use the afternoon angle");assert.deepEqual(preserved.sourceVideoIds,[other]);assert.equal(preserved.required,false);
  const restored=changeProductionFormat(changed,"listing-highlight").shots.find(shot=>shot.id==="exterior")!;
  assert.equal(restored.required,true);assert.equal(restored.status,"captured");assert.equal(restored.notes,"Use the afternoon angle");assert.deepEqual(restored.sourceVideoIds,[other]);
  assert.equal(plan.recipe,"listing-highlight");assert.equal(decodeProductionPlan(changed,listing).recipe,"market-update");
});
test("checklist never counts a media link alone as captured coverage",()=>{
  const plan=newProductionPlan(listing);plan.shots[0].sourcePhotoIds=[other];assert.equal(planProgress(plan).covered,0);assert.equal(planProgress(plan).linked,1);
  plan.shots[0].status="captured";assert.equal(planProgress(plan).covered,1);
  plan.shots[1].status="not-needed";assert.equal(planProgress(plan).required,5);
});
test("capture plan rejects wrong listing, duplicate shot IDs and duplicate media references",()=>{
  const plan=newProductionPlan(listing);assert.throws(()=>decodeProductionPlan(plan,other));
  const duplicate=structuredClone(plan);duplicate.shots.push(duplicate.shots[0]);assert.throws(()=>decodeProductionPlan(duplicate,listing));
  plan.shots[0].sourcePhotoIds=[other,other];assert.throws(()=>decodeProductionPlan(plan,listing));
});
test("review timestamps stay inside the actual edit",()=>{
  assert.equal(commentPosition("1:05.125",90),65125);assert.equal(commentPosition("",10),null);assert.equal(timeLabel(65125),"1:05");
  for(const value of ["0:60","-1","4:00","12junk"]){assert.throws(()=>commentPosition(value,90));}
  assert.throws(()=>commentPosition("0:12",10));
});
function bundle(){const draft=newDraft();return {review:{document_user_id:user,org_id:org,key:`edit:${listing}`,listing_id:listing,revision:1,document_revision:2,status:"in_review",events:[],updated_at:"2026-09-24T15:00:00Z"},document:{key:`edit:${listing}`,kind:"edit",listing_id:listing,revision:2,payload:{draft,listingId:listing,sources:[]},updated_at:"2026-09-24T15:00:00Z"},source_revision:2,permissions:{can_submit:false,can_comment:true,can_request_changes:true,can_approve:true,can_withdraw:false}};}
test("review decoding rejects cross-workspace, author and revision mismatches",()=>{
  assert.equal(decodeReviewBundle(bundle(),org,listing,user).source_revision,2);
  assert.throws(()=>decodeReviewBundle(bundle(),other,listing,user));assert.throws(()=>decodeReviewBundle(bundle(),org,listing,other));
  const stale=bundle();stale.document.revision=1;assert.throws(()=>decodeReviewBundle(stale,org,listing,user));
  const forged=bundle();(forged.permissions as Record<string,unknown>).can_approve="yes";assert.throws(()=>decodeReviewBundle(forged,org,listing,user));
});
