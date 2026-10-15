import assert from "node:assert/strict";
import test from "node:test";
import type { Listing, Workspace, StudioPhoto } from "../src/data/contracts";
import { scopedListingWorkspace } from "../src/data/contracts";
import { creativeCoachContext } from "../src/features/creative/coach-context";
const actor="11111111-1111-4111-8111-111111111111",org="22222222-2222-4222-8222-222222222222",id="33333333-3333-4333-8333-333333333333",other="44444444-4444-4444-8444-444444444444";
const workspace={user:{id:actor,email:"PRIVATE_EMAIL"},org:{id:org},memberships:[{orgId:org,role:"owner",accessMode:"own",libraryOwnerUserId:actor,canRead:true}]} as Workspace;
const listing={id,orgId:org,address:"PRIVATE_ADDRESS",tagline:"PRIVATE_TAGLINE",details:{access_code:"PRIVATE_CODE"},status:"ready"} as Listing;
const photo=(listingId:string,isStaged=false)=>({listingId,isStaged,url:"PRIVATE_MEDIA_URL",caption:"PRIVATE_CAPTION"} as StudioPhoto);
const progress={photos:[photo(id,true),photo(other,true)],assets:[{listing_id:id,kind:"video",uploaded:false},{listing_id:other,kind:"video",uploaded:true}],renders:[{listing_id:id,published_at:null},{listing_id:other,published_at:"2026-10-15"}],chapters:3,reels:2};
test("Studio coach carries only selected authorized property, supported screen and closed progress without private labels/media",()=>{
 const context=creativeCoachContext(workspace,listing,progress);
 assert.equal(context.screen,"listing");assert.equal(context.selected_listing_id,id);assert.equal(context.listings.length,1);
 assert.deepEqual(context.listings[0],{id,title:"Selected property",has_video:false,room_tags:3,has_tour:true,published:false,photos:1,edits:1,reels:2});
 assert(!JSON.stringify(context).includes("PRIVATE"));assert(!JSON.stringify(context).includes(other));
 assert(!("plan"in context));assert(!("photo_state"in context));assert(!("reel_state"in context));
});
test("property library, scoped real-org and actor ownership mismatches fail before a coach request can be built",()=>{
 for(const [w,l]of[[workspace,{...listing,orgId:other}],[{...workspace,libraryOrgId:other},listing],[{...workspace,memberships:[]},listing],[{...workspace,user:{...workspace.user,id:other}},listing],[{...workspace,memberships:[{...workspace.memberships[0]!,canRead:false}]},listing]]as const)
  assert.throws(()=>creativeCoachContext(w,l,progress),/Reopen your current property/);
});
test("authorized linked listing keeps its real property id and selected logical library, never the team's other properties",()=>{
 const linked={...listing,orgId:other,libraryOrgId:org};
 const scoped=scopedListingWorkspace(workspace,linked);
 assert.equal(scoped.org.id,other);assert.equal(scoped.libraryOrgId,org);
 assert.equal(creativeCoachContext(scoped,linked,progress).selected_listing_id,id);
 assert.throws(()=>creativeCoachContext(workspace,linked,progress),/Reopen your current property/);
});
test("closed progress cannot advertise another property's upload/publication or invalid counts",()=>{
 const context=creativeCoachContext(workspace,listing,{...progress,chapters:Infinity,reels:-1});
 assert.equal(context.listings[0]!.room_tags,0);assert.equal(context.listings[0]!.reels,0);
 assert.equal(context.listings[0]!.has_video,false);assert.equal(context.listings[0]!.published,false);
});
