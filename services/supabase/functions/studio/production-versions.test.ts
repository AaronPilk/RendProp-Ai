import {assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {handleProductionVersions} from './production-versions.ts';
import {HttpError} from '../_shared/http.ts';
import type {StudioContext} from './context.ts';
const actor='10000000-0000-4000-8000-000000000001',author='10000000-0000-4000-8000-000000000002',org='20000000-0000-4000-8000-000000000001',listing='30000000-0000-4000-8000-000000000001';
const base={key:'edit:'+listing,document_user_id:author,document_revision:3,expected_target_revision:7};
function fixture(data:unknown,error:unknown=null){const calls:unknown[]=[];const authorized:string[]=[];return {calls,authorized,ctx:{userId:actor,orgId:org,authorizeListing:async(id:string)=>{authorized.push(id);},admin:{rpc(name:string,args:unknown){calls.push({name,args});return {abortSignal:()=>Promise.resolve({data,error})};}}} as unknown as StudioContext};}
Deno.test('explicit version copy binds actor, source snapshot and exact target CAS',async()=>{
 const f=fixture({document:{},source_version:{}});
 const response=await handleProductionVersions(new Request('https://fixture.invalid/studio/production-review/copy',{method:'POST',body:JSON.stringify({...base,p_actor:author,p_org_id:author})}),f.ctx);
 assertEquals(response?.status,200);assertEquals(response?.headers.get('Cache-Control'),'private, no-store');assertEquals(f.authorized,[listing]);
 assertEquals(f.calls,[{name:'studio_production_copy',args:{p_actor:actor,p_org_id:org,p_document_user_id:author,p_key:'edit:'+listing,p_document_revision:3,p_expected_target_revision:7}}]);
});
Deno.test('version list and selected version use separate bounded RPC projections',async()=>{
 const f=fixture({versions:[],document:{},version:{}});
 await handleProductionVersions(new Request('https://fixture.invalid/studio/production-review/versions?key=edit:'+listing+'&offset=50'),f.ctx);
 await handleProductionVersions(new Request('https://fixture.invalid/studio/production-review/version?key=edit:'+listing+'&document_user_id='+author+'&document_revision=3'),f.ctx);
 assertEquals(f.calls,[{name:'studio_production_versions_read',args:{p_actor:actor,p_org_id:org,p_document_user_id:actor,p_key:'edit:'+listing,p_document_revision:null,p_offset:50}},{name:'studio_production_versions_read',args:{p_actor:actor,p_org_id:org,p_document_user_id:author,p_key:'edit:'+listing,p_document_revision:3,p_offset:0}}]);
});
Deno.test('version routes deny invalid revisions, methods and pagination before RPC',async()=>{
 const f=fixture({versions:[]});
 for(const path of ['version?document_revision=0','version?document_revision=03','version?document_revision=1.5','version?document_revision=2147483647','version?missing=1','versions?offset=1','versions?offset=10050','copy?x=1']) await assertRejects(()=>handleProductionVersions(new Request('https://fixture.invalid/studio/production-review/'+path+'&key=edit:'+listing),f.ctx),HttpError);
 for(const patch of [{document_revision:0},{document_revision:'3'},{expected_target_revision:-1},{expected_target_revision:1.2},{document_user_id:'other'},{key:'edit'}])await assertRejects(()=>handleProductionVersions(new Request('https://fixture.invalid/studio/production-review/copy',{method:'POST',body:JSON.stringify({...base,...patch})}),f.ctx),HttpError);
 assertEquals(f.calls,[]);
});
Deno.test('version errors preserve CAS conflict but never leak database internals',async()=>{
 for(const [message,status] of [['RP409: Your current draft changed',409],['private postgres detail',503]] as const){const f=fixture(null,{message});const error=await assertRejects(()=>handleProductionVersions(new Request('https://fixture.invalid/studio/production-review/copy',{method:'POST',body:JSON.stringify(base)}),f.ctx),HttpError);assertEquals(error.status,status);}
});
