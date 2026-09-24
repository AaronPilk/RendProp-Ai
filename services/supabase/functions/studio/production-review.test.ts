import {assertEquals, assertRejects, assertThrows} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {handleProductionReview, reviewInput} from "./production-review.ts";
import {handleReviewNarration} from "./production-review-narration.ts";
import {HttpError} from "../_shared/http.ts";
import type {StudioContext} from "./context.ts";
const actor='10000000-0000-4000-8000-000000000001', author='10000000-0000-4000-8000-000000000002', org='20000000-0000-4000-8000-000000000001', listing='30000000-0000-4000-8000-000000000001', resultId='40000000-0000-4000-8000-000000000001';
const base={key:'edit:'+listing, action:'submit', expected_document_revision:1, expected_review_revision:0};
const post=(body:unknown,path='production-review')=>new Request('https://fixture.invalid/studio/'+path,{method:'POST',body:JSON.stringify(body)});
Deno.test('review action input binds valid source and both revisions without accepting actor override',()=>{
 const input=reviewInput({...base,actor:author,org_id:author,user_id:author},actor);
 assertEquals(input.owner,actor);assertEquals(input.documentRevision,1);assertEquals(input.reviewRevision,0);
 for(const patch of [{key:'edit'},{key:'edit:'+org+':other'},{document_user_id:'invalid'},{action:'publish'},{expected_document_revision:0},{expected_review_revision:-1},{expected_review_revision:1.2},{action:'comment',message:' '},{action:'request_changes'},{message:'x'.repeat(2001)},{message:'\0'},{position_ms:180001},{position_ms:0.5}]) assertThrows(()=>reviewInput({...base,...patch},actor),HttpError);
 assertEquals(reviewInput({...base,action:'comment',message:'  Intro  ',position_ms:1200},actor).message,'Intro');
});
function context(data:unknown={review:{},permissions:{}},error:unknown=null){
 const calls:{name:string,args:Record<string,unknown>}[]=[];const authorized:string[]=[];
 const ctx={userId:actor,orgId:org,authorizeListing:async(id:string)=>{authorized.push(id);},admin:{rpc(name:string,args:Record<string,unknown>){calls.push({name,args});return {abortSignal:(_signal:AbortSignal)=>Promise.resolve({data,error})};}}} as unknown as StudioContext;
 return {ctx,calls,authorized};
}
Deno.test('review mutation gets actor/org exclusively from authenticated context',async()=>{
 const {ctx,calls,authorized}=context(); const response=await handleProductionReview(post({...base,document_user_id:author,p_actor:author,org_id:author}),ctx);
 assertEquals(response?.status,200);assertEquals(response?.headers.get('Cache-Control'),'private, no-store');assertEquals(authorized,[listing]);
 assertEquals(calls,[{name:'studio_production_review',args:{p_actor:actor,p_org_id:org,p_document_user_id:author,p_key:'edit:'+listing,p_action:'submit',p_expected_document_revision:1,p_expected_review_revision:0,p_message:null,p_position_ms:null}}]);
});
Deno.test('review listing authorization precedes privileged RPC access',async()=>{
 const {ctx,calls}=context();ctx.authorizeListing=()=>Promise.reject(new HttpError(404,'missing'));
 await assertRejects(()=>handleProductionReview(post(base),ctx),HttpError,'missing');assertEquals(calls,[]);
});
Deno.test('review queue preserves current tenant and bounded page, rejects mutation',async()=>{
 const {ctx,calls}=context({reviews:[],next_offset:null});
 await handleProductionReview(new Request('https://fixture.invalid/studio/production-review-queue?listing_id='+listing+'&offset=50'),ctx);
 assertEquals(calls[0],{name:'studio_production_review_queue',args:{p_actor:actor,p_org_id:org,p_listing_id:listing,p_offset:50}});
 for(const query of ['offset=-1','offset=1','offset=10050','offset=01','listing_id=bogus']) await assertRejects(()=>handleProductionReview(new Request('https://fixture.invalid/studio/production-review-queue?'+query),ctx),HttpError);
 await assertRejects(()=>handleProductionReview(post({},'production-review-queue'),ctx),HttpError);assertEquals(calls.length,1);
});
Deno.test('RPC failures preserve known conflicts but hide database details',async()=>{
 for(const [message,status,expected] of [['RP409: This reel changed',409,'This reel changed'],['secret SQL detail: key=hidden',503,'temporarily unavailable'],['RP403: nope\nsecret',503,'temporarily unavailable']] as const){
  const {ctx}=context(null,{message});const err=await assertRejects(()=>handleProductionReview(post(base),ctx),HttpError,expected);assertEquals(err.status,status);
 }
});
function narrationFixture(options:{changed?:boolean;resultId?:string;state?:string;key?:string;status?:string}={}) {
 let reads=0,signs=0;const filters:unknown[][]=[];
 const document={revision:1,payload:{draft:{narration:{resultId:options.resultId??resultId}}}};
 const row={id:resultId,listing_id:listing,kind:'voice',bucket:'uploads',storage_key:options.key??`ai-voice/${org}/${resultId}.mp3`,metadata:{state:options.state??'completed',words:[]},created_at:'2026-09-24T00:00:00Z'};
 const builder={select:()=>builder,eq:(...args:unknown[])=>{filters.push(args);return builder;},abortSignal:()=>builder,maybeSingle:()=>Promise.resolve({data:row,error:null})};
 const ctx={userId:actor,orgId:org,authorizeListing:async()=>{},admin:{from:(name:string)=>{assertEquals(name,'studio_creative_results');return builder;},rpc:()=>({abortSignal:()=>{reads++;return Promise.resolve({data:{review:{status:options.status??'in_review',submitted_at:'2026-09-24'},document,source_revision:options.changed&&reads>1?2:1},error:null});}})}} as unknown as StudioContext;
 return {ctx,filters,sign:async(bucket:string,key:string,seconds:number)=>{signs++;assertEquals(seconds,600);return 'https://fixture.invalid/audio';},count:()=>signs};
}
const narrationBody={key:'edit:'+listing,document_user_id:author,result_id:resultId,expected_document_revision:1};
Deno.test('review narration signs only selected completed author/org/listing voice result',async()=>{
 const f=narrationFixture();const response=await handleReviewNarration(post(narrationBody),f.ctx,f.sign);
 assertEquals((await response.json()).result.url,'https://fixture.invalid/audio');assertEquals(f.filters,[['id',resultId],['user_id',author],['org_id',org],['listing_id',listing],['kind','voice']]);assertEquals(f.count(),1);
});
Deno.test('review narration refuses other results, unfinished audio and cross-org storage before signing',async()=>{
 for(const options of [{resultId:author},{state:'pending'},{key:`ai-voice/${author}/${resultId}.mp3`},{key:`ai-voice/${org}/../${resultId}.mp3`},{status:'draft'}]){
  const f=narrationFixture(options);await assertRejects(()=>handleReviewNarration(post(narrationBody),f.ctx,f.sign),HttpError);assertEquals(f.count(),0);
 }
});
Deno.test('narration capability is not returned if source changes while signing',async()=>{
 const f=narrationFixture({changed:true});await assertRejects(()=>handleReviewNarration(post(narrationBody),f.ctx,f.sign),HttpError,'changed');assertEquals(f.count(),1);
});
