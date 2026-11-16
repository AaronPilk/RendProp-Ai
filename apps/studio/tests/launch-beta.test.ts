import test from "node:test";
import assert from "node:assert/strict";
import { listingFactsPayload, listingFactsConfirmed } from "../src/features/listings/model";
import { detailChanges, detailInputs, industryFields } from "../src/features/listings/industry";
import { decodePersonalCard, personalCardBody, personalCardConfirmed, personalCardValues } from "../src/features/business/personal-card";
import { decodePortfolioSelection } from "../src/features/business/HostedPortfolioEditor";
import type { Listing } from "../src/data/contracts";
const actor="11111111-1111-4111-8111-111111111111",org="22222222-2222-4222-8222-222222222222",id="33333333-3333-4333-8333-333333333333";
const row:Listing={id,orgId:org,agentId:actor,spaceType:"venue",address:"Fixture venue",tagline:null,details:{capacitySeated:20,hours:null,bookingUrl:"https://old.fixture.invalid",floorplan_native:{schema:2,rooms:[]},unrecognized:{value:true}},status:"ready",createdAt:"2026-10-06T00:00:00Z",mainPhotoKey:null,beds:3,baths:2.3,sqft:2100,priceCents:12345};
const form=()=>new FormData();
test("business detail edits retain exact presence and JSON types while ignoring untouched formatted values",()=>{
 const f=form();f.set("detail.capacitySeated","20");f.set("detail.hours","");f.set("detail.bookingUrl","https://new.fixture.invalid");f.set("detail.capacityStanding","45");
 assert.deepEqual(detailChanges(f,row.details),{expected:{bookingUrl:{present:true,value:"https://old.fixture.invalid"},capacityStanding:{present:false,value:null}},changes:{bookingUrl:"https://new.fixture.invalid",capacityStanding:"45"}});
 f.set("detail.capacitySeated","25");assert.deepEqual(detailChanges(f,row.details).expected.capacitySeated,{present:true,value:20});
 assert.equal(detailInputs(row.details)["detail.hours"],"");assert(industryFields("venue").some(field=>field.key==="bookingUrl"));
});
test("industry facts contract merges only deliberate details and validates their accepted receipt",()=>{
 const f=form();for(const [key,value]of Object.entries({address:row.address,tagline:"",space_type:row.spaceType,price:"123.45",beds:"3",baths:"2.3",sqft:"2100","detail.capacitySeated":"25"}))f.set(key,String(value));
 const body=listingFactsPayload(f,row);assert.deepEqual(body.changes,{});assert.deepEqual(body.details_changes,{capacitySeated:"25"});assert.deepEqual(body.details_expected,{capacitySeated:{present:true,value:20}});
 assert(listingFactsConfirmed({...row,details:{...row.details,capacitySeated:"25",hours:"Changed on phone"}},body));assert(!listingFactsConfirmed(row,body));assert.deepEqual(row.details.floorplan_native,{schema:2,rooms:[]});
});
test("industry detail links and counts reject unsafe input before any API request",()=>{
 for(const value of["javascript:alert(1)","https://user@unsafe.fixture.invalid","https://unsafe.fixture.invalid/a b"]){const f=form();f.set("detail.bookingUrl",value);assert.throws(()=>detailChanges(f,{}),/https/);}
 const f=form();f.set("detail.capacitySeated","-1");assert.throws(()=>detailChanges(f,{}),/non-negative/);f.delete("detail.capacitySeated");f.set("detail.unrecognized","x");assert.throws(()=>detailChanges(f,{}),/cannot/);
});
test("personal card save remains account-owned and confirms only deliberate fields",()=>{
 const saved=decodePersonalCard({ok:true,user_id:actor,space_type:"real_estate",public_card:{name:"My name",phone:""}},actor),values=personalCardValues(saved);values.name="New name";
 const body=personalCardBody(saved,values,"real_estate");assert.deepEqual(body,{changes:{name:"New name"},expected:{name:{present:true,value:"My name"}}});
 const next=decodePersonalCard({ok:true,user_id:actor,space_type:"real_estate",public_card:{name:"New name",phone:"",website:"https://phone.fixture.invalid"}},actor);assert(personalCardConfirmed(next,body.changes));assert(!personalCardConfirmed(saved,body.changes));
 assert.throws(()=>decodePersonalCard({ok:true,user_id:org,space_type:null,public_card:null},actor),/confirmed/);assert.throws(()=>decodePersonalCard({ok:true,user_id:actor,space_type:null,public_card:{headshot_url:"https://inviter.fixture.invalid"}},actor),/read/);
});
test("hosted selection never infers listings and rejects wrong account, workspace, duplicates and unsafe URL",()=>{
 const raw={ok:true,user_id:actor,org_id:org,id:null,revision:0,listing_ids:[],portfolio_url:null};assert.deepEqual(decodePortfolioSelection(raw,actor,org).ids,[]);
 for(const changed of[{user_id:org},{org_id:actor},{listing_ids:[id,id]},{portfolio_url:"javascript:alert(1)"},{revision:-1}])assert.throws(()=>decodePortfolioSelection({...raw,...changed},actor,org),/confirmed/);
});
