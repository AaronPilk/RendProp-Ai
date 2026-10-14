// Selected-photo-only automatic scene/motion planning. No account-wide scan,
// client URLs, address/facts, generation request, or arbitrary model/prompt.
import {handleOptions} from '../_shared/cors.ts';
import {assert,HttpError,json,pathSegments,readJsonLimited,respondError,throwRpc} from '../_shared/http.ts';
import {adminClient,assertNotDeleting,assertPaidAiIdentity,contentOrgForUser,getUser,preferredOrg} from '../_shared/supabase.ts';
import {assertMediaVisible} from '../_shared/media-source-access.ts';
import {durableRateLimit} from '../_shared/ratelimit.ts';
import {headObject,R2_BUCKET_UPLOADS,R2_BUCKET_RENDERS} from '../_shared/r2.ts';
import {ProviderError,presignGet} from '../_shared/providers/common.ts';
import {openaiChat} from '../_shared/providers/openai.ts';
import {recordRoutedAiCost} from '../_shared/ledger.ts';
import {fundingContext,fundedAttempt,textAttemptQuote,abortFundingOperationBeforeDispatch,completeFundingOperation,type FundingContext} from '../_shared/funded-serving.ts';
import {reportOutcome,type RouteStep} from '../_shared/router.ts';
import {planInput,planOutput,planSchema,PLAN_CONSENT,PLAN_INSTRUCTION} from './plan.ts';
const MODEL='gpt-5.6-terra',MAX_OUTPUT=2000,STAGE='property.video_plan:initial';
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return handleOptions();let funding:FundingContext|undefined,dispatched=false;
 try{
  assert(req.method==='POST'&&pathSegments(req,'property-video-plan').length===0,405,'Use POST to plan selected property photos.');
  const user=await getUser(req);assert(user.is_anonymous===false,403,'Sign in to your own account before planning property photos.');assert(req.headers.get('x-rendprop-ai-consent')===PLAN_CONSENT,403,'Allow AI processing of these selected property photos before planning.','consent_required');
  const key=req.headers.get('idempotency-key');assert(typeof key==='string'&&/^[A-Za-z0-9:_-]{8,128}$/.test(key),400,'Keep the saved selected-photo planning identity.');
  const body=planInput(await readJsonLimited<Record<string,unknown>>(req,24*1024));
  assert(!preferredOrg(req)||preferredOrg(req)===body.expected_org_id,409,'The selected workspace changed. Reopen the property.');
  await assertNotDeleting(user.id);
  const org=await contentOrgForUser(user.id,body.expected_org_id,body.listing_id,true);await assertPaidAiIdentity(user,org);
  const admin=adminClient(),saved:Array<{asset:string;key:string;bucket:string;bytes:number;etag:string;contentType:string}>=[];
  // Serial checks/signing bound memory, concurrency and customer identifiers.
  for(const photo of body.photos){const {data,error}=await admin.rpc('property_owned_upload',{p_actor:user.id,p_listing:body.listing_id,p_asset:photo.asset_id,p_kind:'photo'});if(error)throwRpc(error.message);
   assert(data&&data.actor_id===user.id&&data.listing_id===body.listing_id&&data.org_id===org&&data.asset_id===photo.asset_id&&['uploads','renders'].includes(data.bucket)
    &&typeof data.storage_key==='string'&&data.storage_key.startsWith(`${data.bucket}/${org}/${body.listing_id}/`)&&!data.storage_key.includes('..')
    &&data.content_type==='image/jpeg'&&Number.isSafeInteger(data.bytes)&&data.bytes>0&&data.bytes<=8*1024*1024&&typeof data.etag==='string'&&data.etag.length>0,409,'Use the exact saved JPEG source for each selected photo.');
   saved.push({asset:photo.asset_id,key:data.storage_key,bucket:data.bucket==='uploads'?R2_BUCKET_UPLOADS:R2_BUCKET_RENDERS,bytes:data.bytes,etag:data.etag,contentType:data.content_type});
  }
  const checkSaved=async()=>{for(const s of saved){const h=await headObject(s.bucket,s.key,AbortSignal.timeout(10000));assert(h.exists&&h.bytes===s.bytes&&h.etag===s.etag&&h.contentType?.split(';')[0].trim().toLowerCase()===s.contentType,409,'A selected source photo changed. Upload it again.');}await assertMediaVisible(admin,body.listing_id,{assets:saved.map(s=>s.asset)});};
  await checkSaved();
  // Durable result replay happens before presigned URL creation/provider work.
  funding=await fundingContext(user.id,org,req,body,(name,args)=>admin.rpc(name,args));
  assert(await durableRateLimit(`propertyvideoplan:${org}`,60,300),429,'Too many photo plans for now. Try again shortly.','rate_limited');
  const content:Array<Record<string,unknown>>=[];
  for(let i=0;i<saved.length;i++){content.push({type:'input_text',text:`Photo index ${i+1}`});content.push({type:'input_image',detail:'low',image_url:await presignGet(saved[i].bucket,saved[i].key,300)});}
  const step:RouteStep&{params:Record<string,unknown>}={route_id:'property-video-plan-openai-v1',task:'property.video_plan',provider:'openai',model:MODEL,unit:'call',unit_cents:1,
   capabilities:['text','vision','compliant'],max_latency_s:60,min_plan:'free',same_model_as:null,privacy_tier:'retained_30d',enabled:true,params:{effort:'none',max_output_tokens:MAX_OUTPUT}};
  // Official low detail fits512px (≤256patches);2048tokens/image is a
  // conservative multi-model bound, plus prompt/schema bytes and output cap.
  const textBytes=new TextEncoder().encode(PLAN_INSTRUCTION+JSON.stringify(planSchema(saved.length))).byteLength;
  const quote=textAttemptQuote(step,PLAN_INSTRUCTION,'Selected property-photo scene classification',MAX_OUTPUT,true,saved.length*2048+textBytes+1024);
  assert(quote,503,'Photo planning price is temporarily unavailable.');step.unit_cents=quote.cents;
  let measured:{inputTokens:number;outputTokens:number}|undefined;
  let response:string,answered=false;
  try{response=await fundedAttempt(funding,STAGE,step,{photos:body.photos,listing_id:body.listing_id,system:PLAN_INSTRUCTION,image_detail:'low',max_output_tokens:MAX_OUTPUT},quote,async()=>{
    await assertNotDeleting(user.id);await contentOrgForUser(user.id,body.expected_org_id,body.listing_id,true);await checkSaved();dispatched=true;
    const started=Date.now();try{const text=await openaiChat(step,[{role:'system',content:PLAN_INSTRUCTION},{role:'user',content}],{maxOutputTokens:MAX_OUTPUT,jsonSchema:planSchema(saved.length),onUsage:u=>{measured=u;}});answered=true;await reportOutcome(step,{ok:true,latency_ms:Date.now()-started});return text;}catch(error){await reportOutcome(step,{ok:false,latency_ms:Date.now()-started,error_class:error instanceof ProviderError?error.error_class:'other',...(error instanceof ProviderError&&error.status?{status:error.status}:{})});throw error;}
  });}finally{if(dispatched&&(measured||answered)){const cents=measured?(measured.inputTokens*2+measured.outputTokens*12)/10000:quote.cents;
    await recordRoutedAiCost(admin,{orgId:org,feature:'video_plan',step,unitCentsOverride:Math.max(.0001,cents),meta:{kind:'selected_photo_scene_plan',photo_count:body.photos.length,request_key:funding.requestKey,stage:STAGE,image_detail:'low',cost_basis:measured?'provider_reported_tokens_standard_rate_estimate':'bounded_attempt_estimate',...(measured?{input_tokens:measured.inputTokens,output_tokens:measured.outputTokens}:{}),tariff:quote.version}});
  }}
  const photos=planOutput(response,body.photos);await assertNotDeleting(user.id);await contentOrgForUser(user.id,body.expected_org_id,body.listing_id,true);await checkSaved();
  return json(await completeFundingOperation(funding,{schema:1,listing_id:body.listing_id,org_id:body.expected_org_id,photos,model:MODEL}),200,{'cache-control':'no-store'});
 }catch(error){if(funding&&!dispatched)await abortFundingOperationBeforeDispatch(funding);return respondError(error instanceof HttpError?error:new HttpError(503,'The selected photos could not be planned. Keep your selected order or try again.'));}
});
