import {assertEquals, assertRejects, assertThrows} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {productionPlanInput,authorizeProductionPlan} from './production-plan.ts';
import {documentInput} from './documents.ts';
import {HttpError} from '../_shared/http.ts';
import type {StudioContext} from './context.ts';
const actor='10000000-0000-4000-8000-000000000001',org='20000000-0000-4000-8000-000000000001',listing='30000000-0000-4000-8000-000000000001',photo='40000000-0000-4000-8000-000000000001',video='40000000-0000-4000-8000-000000000002';
const shot={id:'front-door',title:'Front door',guidance:'Wide view',required:true,status:'captured' as const,sourcePhotoIds:[],sourceVideoIds:[],notes:''};
const plan={schema:1,listingId:listing,recipe:'listing-highlight',presentation:'music',targetSeconds:30,shots:[shot],notes:''};
Deno.test('capture plan permits honest capture self-report without cloud file claims',()=>{
 assertEquals(productionPlanInput(plan,listing),plan);
 assertEquals(documentInput({key:'production:'+listing,kind:'production',listing_id:listing,expected_revision:0,payload:plan}).payload,plan);
});
Deno.test('capture plan rejects ambiguous types, foreign listing, duplicate IDs and excessive content',()=>{
 for(const patch of [{shots:[]},{schema:2},{listingId:actor},{recipe:['listing-highlight']},{presentation:['music']},{targetSeconds:'30'},{shots:[{...shot,status:['captured']}]},{shots:[shot,shot]},{shots:[{...shot,id:'INVALID'}]},{shots:[{...shot,title:'x'.repeat(121)}]},{shots:[{...shot,sourcePhotoIds:[photo,photo]}]},{shots:[{...shot,sourceVideoIds:['bad']}]},{shots:Array.from({length:17},(_,i)=>({...shot,id:'s-'+i}))},{notes:'x'.repeat(2001)}]) assertThrows(()=>productionPlanInput({...plan,...patch},listing),HttpError);
});
function fake(role:string,rows:Record<string,unknown[]>={},failure=false){
 const filters:{table:string,method:string,args:unknown[]}[]=[];
 const db={from(table:string){const builder={select:()=>builder,eq:(...args:unknown[])=>{filters.push({table,method:'eq',args});return builder;},in:(...args:unknown[])=>{filters.push({table,method:'in',args});return builder;},not:(...args:unknown[])=>{filters.push({table,method:'not',args});return builder;},abortSignal:()=>builder,maybeSingle:()=>Promise.resolve({data:{role},error:null}),then:(resolve:(x:unknown)=>unknown)=>Promise.resolve({data:rows[table]??[],error:failure?{message:'db'}:null}).then(resolve)};return builder;}};
 const admin={rpc:async(name:string,args:any)=>{assertEquals(name,"listing_library_scope");assertEquals(args,{p_actor:actor,p_listing:listing});filters.push({table:name,method:'rpc',args:[args]});return {data:{actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,listing_owner_user_id:actor,library_owner_user_id:actor,role,access_mode:'own',can_read:true,can_write:role!=='marketing',can_manage_subscription:false,billing_org_id:org,team_org_id:null},error:null};}};
 return {ctx:{userId:actor,orgId:org,db,admin} as unknown as StudioContext,filters};
}
Deno.test('capture plan write is denied for marketing before file reads',async()=>{
 const f=fake('marketing');await assertRejects(()=>authorizeProductionPlan(productionPlanInput(plan,listing),f.ctx,new AbortController().signal),HttpError);assertEquals(f.filters.map(f=>f.table),['listing_library_scope']);
});
Deno.test('capture plan checks current property, completed upload and media type for every linked source',async()=>{
 const linked=productionPlanInput({...plan,shots:[{...shot,sourcePhotoIds:[photo],sourceVideoIds:[video]}]},listing);
 const f=fake('agent',{photos:[{id:photo}],capture_assets:[{id:video,kind:'video'}]});
 await authorizeProductionPlan(linked,f.ctx,new AbortController().signal);
 for(const table of ['photos','capture_assets','renders']) assertEquals(f.filters.find(f=>f.table===table&&f.args[0]==='listing_id')?.args,['listing_id',listing]);
 assertEquals(f.filters.find(f=>f.table==='capture_assets'&&f.args[0]==='uploaded')?.args,['uploaded',true]);
 const wrong=fake('agent',{capture_assets:[{id:photo,kind:'video'},{id:video,kind:'photo'}]});await assertRejects(()=>authorizeProductionPlan(linked,wrong.ctx,new AbortController().signal),HttpError,'media type');
 const missing=fake('agent');await assertRejects(()=>authorizeProductionPlan(linked,missing.ctx,new AbortController().signal),HttpError,'property');
 const broken=fake('agent',{},true);await assertRejects(()=>authorizeProductionPlan(linked,broken.ctx,new AbortController().signal),HttpError,'could not be checked');
});

Deno.test('capture plan rejects manually supplied client headshot IDs as property sources',async()=>{
 const linked=productionPlanInput({...plan,shots:[{...shot,sourcePhotoIds:[photo]}]},listing);
 const f=fake('agent',{capture_assets:[{id:photo,kind:'photo',storage_key:`renders/${org}/${listing}/contact-${photo}.jpg`}]});
 await assertRejects(()=>authorizeProductionPlan(linked,f.ctx,new AbortController().signal),HttpError,'property');
});
