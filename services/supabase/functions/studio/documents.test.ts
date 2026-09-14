import {assertEquals,assertRejects,assertThrows} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {documentInput,handleDocuments} from './documents.ts';
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
