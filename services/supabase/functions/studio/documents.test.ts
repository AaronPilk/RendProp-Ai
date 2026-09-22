import {assertEquals,assertRejects,assertThrows} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {documentInput,documentKey,handleDocuments} from './documents.ts';
import {HttpError} from '../_shared/http.ts';
import type {StudioContext} from './context.ts';
const user='10000000-0000-4000-8000-000000000001',org='20000000-0000-4000-8000-000000000002',listing='30000000-0000-4000-8000-000000000003';
Deno.test('document keys and revisions bind to typed listing intent',()=>{
 assertEquals(documentInput({key:'creative:'+listing,kind:'creative',listing_id:listing,expected_revision:0,payload:{}}).listing_id,listing);
 for(const body of [ {key:'random',kind:'edit',expected_revision:0,payload:{}},{key:'edit',kind:'planner',expected_revision:0,payload:{}},{key:'edit',kind:'edit',expected_revision:-1,payload:{}},{key:'creative:'+listing,kind:'creative',listing_id:user,expected_revision:0,payload:{}}])assertThrows(()=>documentInput(body),HttpError);
});
Deno.test('document update atomically compares revision and pins actor workspace and key',async()=>{
 const calls:{method:string,args:unknown[]}[]=[];
 const builder={};for(const method of ['from','update','select','eq','abortSignal'])Object.assign(builder,{[method]:(...args:unknown[])=>{calls.push({method,args});return builder;}});
 Object.assign(builder,{maybeSingle:()=>Promise.resolve({data:null,error:null})});
 const context={userId:user,orgId:org,admin:builder,db:builder,authorizeListing:async()=>{}} as unknown as StudioContext;
 await assertRejects(()=>handleDocuments(new Request('https://fixture.invalid/studio/documents',{method:'POST',body:JSON.stringify({key:'edit',kind:'edit',expected_revision:4,payload:{title:'unsaved'}})}),context),HttpError,'another device');
 assertEquals(calls.filter(c=>c.method==='eq').map(c=>c.args),[['user_id',user],['org_id',org],['key','edit'],['revision',4]]);
});
Deno.test('listing-bound documents authorize the listing before writing',async()=>{
 let writes=0;const context={userId:user,orgId:org,admin:{from(){writes++;}},authorizeListing:()=>Promise.reject(new HttpError(404,'Missing listing'))} as unknown as StudioContext;
 await assertRejects(()=>handleDocuments(new Request('https://fixture.invalid/studio/documents',{method:'POST',body:JSON.stringify({key:'native:'+listing,kind:'native',listing_id:listing,expected_revision:0,payload:{}})}),context),HttpError);assertEquals(writes,0);
});
Deno.test('property edit keys retain legacy documents and reject malformed UUIDs',()=>{
 for(const key of ['edit','planner','creative:'+listing,'native:'+listing,'edit:'+listing])assertEquals(documentKey(key),key);
 for(const key of ['edit:'+'-'.repeat(36),'creative:'+'a'.repeat(36),'native:'+listing+'extra','edit:'+listing+':other'])assertThrows(()=>documentKey(key),HttpError);
 const input=documentInput({key:'edit:'+listing,kind:'edit',listing_id:listing,expected_revision:0,payload:{listingId:listing,title:'Saved property reel'}});
 assertEquals(input.listing_id,listing);assertEquals(input.key,'edit:'+listing);
});
Deno.test('scoped edits reject missing or conflicting property bindings before any database access',async()=>{
 let accesses=0;const context={userId:user,orgId:org,admin:{from(){accesses++;}},authorizeListing:async()=>{accesses++;}} as unknown as StudioContext;
 for(const fields of [{listing_id:null,payload:{listingId:listing}},{listing_id:user,payload:{listingId:listing}},{listing_id:listing,payload:{}},{listing_id:listing,payload:{listingId:user}}]){
  await assertRejects(()=>handleDocuments(new Request('https://fixture.invalid/studio/documents',{method:'POST',body:JSON.stringify({key:'edit:'+listing,kind:'edit',expected_revision:0,...fields})}),context),HttpError);
 }
 assertEquals(accesses,0);
});
Deno.test('property edit saves authorize and preserve separate revision predicates',async()=>{
 const calls:{method:string,args:unknown[]}[]=[];let row:Record<string,unknown>={};
 const builder={};for(const method of ['from','select','eq','abortSignal'])Object.assign(builder,{[method]:(...args:unknown[])=>{calls.push({method,args});return builder;}});
 Object.assign(builder,{update:(value:Record<string,unknown>)=>{row=value;return builder;},maybeSingle:()=>Promise.resolve({data:row,error:null})});
 const authorized:string[]=[];const context={userId:user,orgId:org,admin:builder,authorizeListing:async(id:string)=>{authorized.push(id);}} as unknown as StudioContext;
 for(const id of [listing,user]){
  const response=await handleDocuments(new Request('https://fixture.invalid/studio/documents',{method:'POST',body:JSON.stringify({key:'edit:'+id,kind:'edit',listing_id:id,expected_revision:4,payload:{listingId:id,title:'Property reel'}})}),context);
  assertEquals(response.status,200);assertEquals((await response.json()).document,{...row,key:'edit:'+id,listing_id:id,revision:5});
 }
 assertEquals(authorized,[listing,user]);
 assertEquals(calls.filter(c=>c.method==='eq').map(c=>c.args),[['user_id',user],['org_id',org],['key','edit:'+listing],['revision',4],['user_id',user],['org_id',org],['key','edit:'+user],['revision',4]]);
});
Deno.test('property edit reads stay scoped to the caller workspace and exact property key',async()=>{
 const calls:{method:string,args:unknown[]}[]=[];const builder={};
 for(const method of ['from','select','eq','abortSignal'])Object.assign(builder,{[method]:(...args:unknown[])=>{calls.push({method,args});return builder;}});
 Object.assign(builder,{maybeSingle:()=>Promise.resolve({data:null,error:null})});
 const response=await handleDocuments(new Request('https://fixture.invalid/studio/documents?key=edit:'+listing),{userId:user,orgId:org,db:builder} as unknown as StudioContext);
 assertEquals(await response.json(),{document:null});assertEquals(response.headers.get('Cache-Control'),'private, no-store');
 assertEquals(calls.filter(c=>c.method==='eq').map(c=>c.args),[['user_id',user],['org_id',org],['key','edit:'+listing]]);
});
