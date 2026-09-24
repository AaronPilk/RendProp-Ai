import { assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { handlePresenter, handlePresenterMedia, presenterInput, presenterCall } from "./presenter.ts";
import { HttpError } from "../_shared/http.ts";
import type { StudioContext } from "./context.ts";
const actor='10000000-0000-4000-8000-000000000001',other='10000000-0000-4000-8000-000000000002',org='20000000-0000-4000-8000-000000000001',listing='30000000-0000-4000-8000-000000000001',profile='40000000-0000-4000-8000-000000000001',asset='50000000-0000-4000-8000-000000000001',draft='60000000-0000-4000-8000-000000000001';
const post=(body:unknown,path='presenter')=>new Request('https://fixture.invalid/studio/'+path,{method:'POST',body:JSON.stringify(body)});
const envelope={org_id:org,listing_id:listing,profiles:[],drafts:[],permissions:{can_save_profile:true,can_create_draft:true}};
const save={listing_id:listing,action:'save_profile',expected_revision:0,display_name:'My agent profile',reference_asset_ids:[asset]};
const draftSave={listing_id:listing,action:'save_draft',draft_id:draft,expected_revision:0,profile_id:profile,expected_profile_revision:2,title:'Intro',script:'A recording guide.',source_asset_id:asset,format:'listing_intro',resolution:'720p'};
function context(data:unknown=envelope,error:unknown=null){
 const calls:{name:string,args:Record<string,unknown>}[]=[];const authorized:string[]=[];
 const ctx={userId:actor,orgId:org,authorizeListing:async(id:string)=>{authorized.push(id);},admin:{rpc(name:string,args:Record<string,unknown>){calls.push({name,args});return {abortSignal:(_signal:AbortSignal)=>Promise.resolve({data,error})};}}} as unknown as StudioContext;
 return {ctx,calls,authorized};
}
Deno.test('presenter input preserves only allowlisted subject-free fields',()=>{
 assertEquals(presenterInput({...save,p_actor:other,subject_user_id:other,org_id:other,approved:true}),save);
 assertEquals(presenterInput({...draftSave,url:'https://attacker.invalid/file',author_user_id:other}),draftSave);
});
Deno.test('presenter input rejects unsupported operations, URLs, duplicate references and bad revisions',()=>{
 for(const patch of [{action:'claim'},{action:'prepare'},{listing_id:'bad'},{expected_revision:-1},{expected_revision:0.5},{expected_revision:2147483647},{display_name:''},{display_name:'x'.repeat(81)},{reference_asset_ids:[]},{reference_asset_ids:[asset,asset]},{reference_asset_ids:['https://attacker.invalid/photo']},{reference_asset_ids:Array(9).fill(asset)}])assertThrows(()=>presenterInput({...save,...patch}),HttpError);
 for(const patch of [{expected_profile_revision:0},{script:''},{script:'x'.repeat(2001)},{script:'bad\0script'},{source_asset_id:'url'},{resolution:'1080p'},{format:'clone_voice'}])assertThrows(()=>presenterInput({...draftSave,...patch}),HttpError);
});
Deno.test('profile and video approval require explicit scope-specific consent',()=>{
 const approve={listing_id:listing,action:'approve_profile',profile_id:profile,expected_revision:1};
 const video={listing_id:listing,action:'approve_draft',draft_id:draft,expected_revision:1,expected_profile_revision:2};
 for(const v of [undefined,false,'true',1]){
  assertThrows(()=>presenterInput({...approve,likeness_consent:v}),HttpError);
  assertThrows(()=>presenterInput({...video,source_performance_consent:v}),HttpError);
 }
 assertEquals(presenterInput({...approve,likeness_consent:true}),{...approve,likeness_consent:true});
 assertEquals(presenterInput({...video,source_performance_consent:true}),{...video,source_performance_consent:true});
});
Deno.test('workspace request binds actor and organization only from authenticated context',async()=>{
 const {ctx,calls,authorized}=context();const response=await handlePresenter(post({...save,p_actor:other,org_id:other}),ctx);
 assertEquals(response?.status,200);assertEquals(authorized,[listing]);assertEquals(calls,[{name:'studio_presenter_workspace',args:{p_actor:actor,p_org_id:org,p_listing_id:listing,p_action:'save_profile',p_payload:save}}]);
 const body=await response!.json();assertEquals(body.runtime.available,false);assertEquals(response?.headers.get('Cache-Control'),'private, no-store');
 // Defense in depth even if a future internal caller accidentally includes actor keys.
 await presenterCall(ctx,post(save),'test_rpc',{p_actor:other,p_org_id:other});assertEquals(calls[1].args,{p_actor:actor,p_org_id:org});
});
Deno.test('GET has no mutation action and enforces exact listing response',async()=>{
 const {ctx,calls}=context();await handlePresenter(new Request('https://fixture.invalid/studio/presenter?listing_id='+listing),ctx);
 assertEquals(calls[0].args.p_action,'get');assertEquals(calls[0].args.p_payload,{});
 for(const bad of [{...envelope,org_id:other},{...envelope,listing_id:other},{...envelope,profiles:null}])await assertRejects(()=>handlePresenter(new Request('https://fixture.invalid/studio/presenter?listing_id='+listing),context(bad).ctx),HttpError);
});
Deno.test('generation public action fails closed without RPC or provider work',async()=>{
 const {ctx,calls,authorized}=context();const response=await handlePresenter(post({listing_id:listing,action:'generate',draft_id:draft,expected_revision:2,expected_profile_revision:2}),ctx);
 assertEquals(response?.status,409);assertEquals((await response!.json()).code,'enterprise_contract_required');assertEquals(calls,[]);assertEquals(authorized,[listing]);
});
Deno.test('authorization, method and body failures precede privileged access',async()=>{
 const f=context();f.ctx.authorizeListing=()=>Promise.reject(new HttpError(404,'missing'));
 await assertRejects(()=>handlePresenter(post(save),f.ctx),HttpError,'missing');assertEquals(f.calls,[]);
 const g=context();await assertRejects(()=>handlePresenter(new Request('https://fixture.invalid/studio/presenter',{method:'DELETE'}),g.ctx),HttpError);
 await assertRejects(()=>handlePresenter(post({...save,extra:'x'.repeat(17000)}),g.ctx),HttpError);assertEquals(g.calls,[]);
 assertEquals(await handlePresenter(new Request('https://fixture.invalid/studio/unrelated'),g.ctx),null);
});
Deno.test('RPC conflict is preserved and unexpected database details are hidden',async()=>{
 for(const [message,status,expected] of [['RP409: Profile changed',409,'Profile changed'],['SQL secret connection details',503,'temporarily unavailable'],['RP403: allowed-looking\nsecret',503,'temporarily unavailable']] as const){
  const error=await assertRejects(()=>handlePresenter(post(save),context(null,{message}).ctx),HttpError,expected);assertEquals(error.status,status);
 }
});
function mediaFixture(options:{changed?:boolean;key?:string;scope?:string;assets?:unknown[]}={}){
 let reads=0,signs=0;const calls:Record<string,unknown>[]=[];
 const entry={id:asset,listing_id:listing,bucket:'uploads',storage_key:options.key??`uploads/${org}/${listing}/${asset}.jpg`,sha256:'a'.repeat(64),bytes:1000,duration_s:12};
 const ctx={userId:actor,orgId:org,authorizeListing:async()=>{},admin:{rpc(_name:string,args:Record<string,unknown>){calls.push(args);return {abortSignal(){reads++;return Promise.resolve({data:{org_id:org,listing_id:options.scope??listing,profile_id:profile,profile_revision:options.changed&&reads>1?3:2,assets:options.assets??[entry]},error:null});}};}}} as unknown as StudioContext;
 return {ctx,calls,count:()=>signs,sign:async(_bucket:string,_key:string,seconds:number)=>{signs++;assertEquals(seconds,300);return 'https://signed.fixture.invalid/reference';}};
}
Deno.test('reference preview returns only expiring URLs after exact profile revalidation',async()=>{
 const f=mediaFixture();const response=await handlePresenterMedia(post({listing_id:listing,profile_id:profile,expected_profile_revision:2}),f.ctx,f.sign);
 const body=await response.json();assertEquals(body.profile_revision,2);assertEquals(body.references[0].asset_id,asset);assertEquals(body.references[0].url,'https://signed.fixture.invalid/reference');assertEquals('storage_key' in body.references[0],false);assertEquals(f.count(),1);assertEquals(f.calls.length,2);assertEquals(f.calls[0].p_payload,{profile_id:profile,expected_profile_revision:2});
});
Deno.test('media preview refuses changed consent before returning capabilities',async()=>{
 const f=mediaFixture({changed:true});await assertRejects(()=>handlePresenterMedia(post({listing_id:listing,profile_id:profile,expected_profile_revision:2}),f.ctx,f.sign),HttpError,'changed');assertEquals(f.count(),1);
});
Deno.test('media preview refuses malformed or cross-scope storage before signing',async()=>{
 for(const options of [{key:`uploads/${other}/${listing}/private.jpg`},{key:`uploads/${org}/${listing}/../private.jpg`},{key:`uploads/${org}/${listing}/private.jpg?leak`},{scope:other},{assets:[]}]){
  const f=mediaFixture(options);await assertRejects(()=>handlePresenterMedia(post({listing_id:listing,asset_ids:[asset]}),f.ctx,f.sign),HttpError);assertEquals(f.count(),0);
 }
});
Deno.test('source preview preserves original asset identity and duration metadata',async()=>{
 const f=mediaFixture();const response=await handlePresenterMedia(post({listing_id:listing,source_asset_id:asset}),f.ctx,f.sign);const body=await response.json();assertEquals(body.source.asset_id,asset);assertEquals(body.source.duration_s,12);assertEquals(body.references,undefined);
});
