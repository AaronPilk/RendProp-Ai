import {assert,assertEquals,assertRejects,AssertionError} from "https://deno.land/std@0.224.0/assert/mod.ts";
const actor="ea100606-0000-4000-8000-000000000001",org="ea100606-0000-4000-8000-000000000002",listing="ea100606-0000-4000-8000-000000000003";
const encode=(source:string)=>`data:application/typescript;base64,${btoa(unescape(encodeURIComponent(source)))}`;
const url=(path:string)=>JSON.stringify(new URL(path,import.meta.url).href);
// Complete structural JPEG geometry fixture, not a decoded/visual quality proof.
const outputJPEG=(width=2048,height=2048)=>btoa(String.fromCharCode(...[255,216,255,192,0,11,8,height>>8,height&255,width>>8,width&255,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]));
const OUTPUT=outputJPEG(4096,4096);
async function fixture(removeFinalAuthority=false,removeAdmission:"input"|"chain"|"intent"|"stage"|"stage_prompt"|"quality"|"masked_price"|"protocol"|"declutter_prompt"|null=null,actualEvidence=false){
 let source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
 if(removeAdmission==="protocol"){
  const anchor="try { assertPhotoRecoveryProtocol(req); }";assertEquals(source.split(anchor).length-1,1);source=source.replace(anchor,"try { /* compiled protocol bypass */ }");
 }
 if(removeAdmission==="input"){
  const anchor='validatePhotoInputs(body.image_b64,mime,body.mask_b64,\n        String(body.mask_mime??"image/png").split(";")[0].trim().toLowerCase());';
  assert(source.includes(anchor));source=source.replace(anchor,"");
  // The4K preparation independently validates the same bytes. The compiled
  // unsafe-admission control must bypass both real input guards, not mistake
  // a still-protected redundant guard removal for an observable vulnerability.
  const second="genInput = preparePhoto4KInput(genInput);";assert(source.includes(second));
  source=source.replace(second,'genInput = {...genInput,extra:{...genInput.extra,photo_quality_4k:true,photo_input_token_bound:4096,photo_input_allowance:8192}};');
 }
 if(removeAdmission==="chain"){
  const anchor="chain = await boundedPhotoChain(funding, chain, genInput);";
  assert(source.includes(anchor));source=source.replace(anchor,"");
 }
 if(removeAdmission==="masked_price"){
  const anchor="if (maskB64) chain = priceMaskedPhotoChain(chain, genInput);";
  assert(source.includes(anchor));source=source.replace(anchor,"");
 }
 if(removeAdmission==="intent"){
  const anchor="const prepared = assertCustomPhotoPrompt(userText, promptSpace);";
  assert(source.includes(anchor));source=source.replace(anchor,"const prepared = {prompt:userText};");
 }
 if(removeAdmission==="stage"){
  const anchor='assertCustomPhotoPrompt(brief, promptSpace, "furnishing");';
  assert(source.includes(anchor));source=source.replace(anchor,"");
 }
 if(removeAdmission==="quality"){
  const anchor="else if(normalPhoto4K)assertPhoto4KGeometry(decoded);";assert(source.includes(anchor));source=source.replace(anchor,"");
 }
 if(removeAdmission==="declutter_prompt"){
  const anchor="buildRealEstateDeclutterPrompt(LOCK,REFLECTION_CLAUSE)";assertEquals(source.split(anchor).length-1,1);source=source.replace(anchor,'"Remove all clutter and personal items. Keep decor identical. " + LOCK');
 }
 if(removeAdmission==="stage_prompt"){
  const anchor="return buildRealEstateStagePrompt(styleDesc);";
  assert(source.includes(anchor));source=source.replace(anchor,'return "Virtually stage this real-estate photo with " + styleDesc + ". " + STAGE_LOCK;');
 }
 const handlerAnchor="export async function handleAIPhoto(req:Request):Promise<Response>{";
 const start=source.indexOf(handlerAnchor)+handlerAnchor.length,end=source.indexOf("\n}\nif(import.meta.main)Deno.serve(handleAIPhoto);",start);
 assert(start>0&&end>start,"Extract actual handler callback");
 const locksStart=source.indexOf("const CONDITION_LOCK ="),locksEnd=source.indexOf("\n/**\n * The photographer",locksStart);
 const customStart=source.indexOf("function customPrompt("),customEnd=source.indexOf("\nexport async function handleAIPhoto(",customStart);
 const stageStart=source.indexOf("const RE_STAGE_STYLES:"),stageEnd=source.indexOf("\nfunction prompts(",stageStart);
 assert(locksStart>0&&locksEnd>locksStart&&customStart>0&&customEnd>customStart,"Extract actual fixed-feature locks and custom compiler wrapper");
 assert(stageStart>0&&stageEnd>stageStart,"Extract actual staging styles and prompt compiler");
 let helper=url("./photo-result.ts");
 if(removeFinalAuthority){
  const original=await Deno.readTextFile(new URL("./photo-result.ts",import.meta.url));
  const anchor=" const bytes=await boundedPhotoResultBytes(response,saved.bytes);\n await authority(admin,identity,saved.key,saved.bytes);";
  assert(original.includes(anchor),"Compile the precise actual final-authority fault");
  const mutant=original.replace(anchor," const bytes=await boundedPhotoResultBytes(response,saved.bytes);").replace(/from "(\.\.\/[^\"]+)"/g,(_all,path)=>`from ${url(path)}`);
  helper=JSON.stringify(encode(mutant));
 }
 const reStart=source.indexOf("const RE_PROMPTS: Record<string, string> = "),reEnd=source.indexOf("\n};",reStart)+3,reflectionStart=source.indexOf("const REFLECTION_CLAUSE =");
 assert(reStart>reflectionStart&&reflectionStart>0&&reEnd>reStart);
 const imported=await import(encode(`// @ts-nocheck
 // Fresh synthetic boundary state ${crypto.randomUUID()}
 import {assert,HttpError,json,readJson,readJsonLimited,respondError} from ${url("../_shared/http.ts")};
 import {requiredIdempotencyKey} from ${url("../_shared/idempotency.ts")};
 import {assertPhotoRecoveryProtocol,hasPhotoRecoveryProtocol} from ${url("./protocol.ts")};
 import {fundingContext,fundedAttempt,mediaAttemptQuote,SavedFundingResponse,completeFundingOperation,abortFundingOperationBeforeDispatch,boundedPhotoChain,assertPhotoHelperSponsorship,inputHash} from ${url("../_shared/funded-serving.ts")};
 import {photoHelperPayload,photoHelperQuote} from ${url("./helper-policy.ts")};
 import {PHOTO_MAIN_REQUEST_BUDGET_MS,PHOTO_MAIN_RESPONSE_RESERVE_MS,PHOTO_MAIN_PERSIST_RESERVE_MS} from ${url("./photo-qc-wait.ts")};
 import {preparePhoto4KInput,photo4KChain,assertPhoto4KGeometry,assertPhotoPro4KGeometry} from ${url("./photo-quality.ts")};
 import {normalPhotoQualityProfile as actualNormalProfile,normalPhotoQualityRoutes as actualNormalRoutes,prepareNormalPhotoPro4KInput,priceNormalPhotoQualityRoute} from ${url("./normal-photo-quality.ts")};
 import {orderSteps} from ${url("../_shared/router.ts")};
 const normalPhotoQualityProfile=(task,masked)=>actualNormalProfile(task,masked,{from:()=>({select:()=>({eq:()=>({maybeSingle:async()=>{state.normalLookups=(state.normalLookups??0)+1;return{data:{value:state.normalWithdraw&&state.normalLookups>1?{enabled:false}:state.normalProfile??null},error:null};}})})})});
 const normalPhotoQualityRoutes=(profile,context)=>actualNormalRoutes(profile,context,async(task,ctx)=>{
  state.normalResolves=(state.normalResolves??0)+1;
  const rows=state.normalRows??[{route_id:"normal-quality-route",task,position:1,provider:"gemini",model:"gemini-3-pro-image",unit:"image",unit_cents:30.5536,capabilities:["prompt-edit","fidelity","4K"],max_latency_s:120,min_plan:"free",same_model_as:null,privacy_tier:"retained_30d",enabled:true,retire_after:null,params:{image_size:"4K"}}];
  return orderSteps(rows.filter(row=>row.enabled===true),ctx,new Map());
 });
 import {priceMaskedPhotoChain,isMaskedFillStep} from ${url("./masked-photo-pricing.ts")};
 import {ownerQaPhotoStep as actualOwnerQaPhotoStep,prepareOwnerQaPhotoInput,assertOwnerQaPhotoOutput,ownerQaPhotoPro4KStep as actualOwnerQaPhotoPro4KStep,prepareOwnerQaPhotoPro4KInput} from ${url("./owner-photo-qa.ts")};
 const ownerQaPhotoStep=(args)=>actualOwnerQaPhotoStep(args,{from:()=>({select:()=>({eq:()=>({maybeSingle:async()=>({data:{value:{enabled:false}},error:null})})})})});
 const ownerQaPhotoPro4KStep=(args)=>actualOwnerQaPhotoPro4KStep(args,{from:(table)=>({select:()=>({eq:()=>({maybeSingle:async()=>{
  if(table==="profiles")return{data:{is_admin:state.proAdmin!==false},error:null};
  state.proLookups=(state.proLookups??0)+1;return{data:{value:state.proExpiresAfterLookup&&state.proLookups>1?null:state.proGrant??null},error:null};
 }})})})});
 import {assertCustomPhotoPrompt,assertCustomPhotoOutput} from ${url("../ai-copy/guard.ts")};
 import {CUSTOM_PHOTO_FIXED_FEATURES} from ${url("../_shared/custom-photo-prompt.ts")};
 import {buildRealEstateStagePrompt} from ${url("../_shared/photo-stage-prompt.ts")};
 import {buildRealEstateDeclutterPrompt} from ${url("../_shared/photo-declutter-prompt.ts")};
 import {MAX_PROMPT_INPUT,MAX_PROMPT_OUTPUT,editPromptInstruction} from ${url("../ai-copy/prompt.ts")};
 import {validatePhotoInputs,validatePhotoPrompt,decodePhotoOutput} from ${url("./input-policy.ts")};
 import {persistOwnedPhotoResult,restorePhotoResult,photoResultKeys} from ${helper};
 import {photoJsonResponse} from ${url("./photo-response.ts")};
 import * as actualQualityStore from ${url("./photo-qc-store.ts")};
 import {inlineImageResult,inlineBase64,ProviderError,BUDGETS} from ${url("../_shared/providers/common.ts")};
 import {runChain} from ${url("../_shared/providers/chain.ts")};
 const actualEvidence=${actualEvidence};
 export const state={objects:new Map(),actor:${JSON.stringify(actor)},org:${JSON.stringify(org)},role:"owner",deleted:false,router:false,qa:false,routes:null,journal:null,object:null,saved:null,quality:null,qualityEnabled:true,qualityPending:false,operationInputHash:null,started:false,completeLost:false,putLost:false,storageFail:false,withdrawOnGet:false,primaryFail:false,output:${JSON.stringify(OUTPUT)},costs:[],holdArguments:[],refunds:0,helperText:"Improve brightness only.",helperDispatch:0,charges:0,holds:0,prompts:[],inputs:[],submits:0,polls:0,puts:0,gets:0,completes:0};
 const GEMINI_KEY="synthetic",MODEL="gemini-3.1-flash-image",MAX_IMAGE_B64_CHARS=12000000,MAX_CUSTOM_PROMPT=600,ALLOWED_MIMES=["image/jpeg","image/png","image/webp","image/heic","image/heif"],PROFILES={real_estate:{}};
 ${source.slice(locksStart,locksEnd)}
 ${source.slice(reflectionStart,reEnd)}
 ${source.slice(customStart,customEnd)}
 ${source.slice(stageStart,stageEnd)}
 const STAGE_STYLES=RE_STAGE_STYLES;
 const assertFairHousing=()=>{},listingSpaceType=async()=>"real_estate",userClient=()=>({});
 const spaceTypeOf=()=>"real_estate",getUser=async()=>({id:state.actor}),requireEditorRole=async()=>state.org,guardrailsFor=()=>"",provenanceKind=()=>"photo_edit",disclosureFallback=()=>"Synthetic disclosure";
 const MAX_IMPROVE_INPUT=MAX_PROMPT_INPUT,TEXT_MODEL="gemini-3.6-flash";
 const guardHelper=async()=>{state.charges++;return{orgId:state.org};},refundHelperCharge=async()=>{},improvePrompt=async()=>{state.helperDispatch++;return state.helperText;};
 const step={route_id:"fixture-route",provider:"gemini",model:MODEL,task:"photo.twilight",unit:"output_image",unit_cents:1,capabilities:[],max_latency_s:60,min_plan:"free",privacy_tier:"retained_30d",enabled:true};
 const routerEnabled=async()=>state.router,resolveChain=async(task)=>state.routes??[{...step,task}],legacyPhotoStep=(task)=>({...step,task}),needsForPhotoEdit=()=>[];
 const guardEdit=async()=>{state.charges++;return{orgId:state.org,plan:state.plan??"pro",monthlyKey:"monthly",burstKey:"burst"};},refundEditCharge=async()=>{state.refunds++;};
 const adapterFor=()=>({submit:async(_step,input)=>{state.submits++;state.prompts.push(input.prompt);state.inputs.push(structuredClone(input));state.afterSubmit?.();if(state.primaryFail&&state.submits===1)throw new ProviderError(_step.provider,"upstream","Synthetic failure");return{id:"synthetic-job"};}}),awaitJob=async()=>{state.polls++;return{status:"done",mime:"image/jpeg",result_url:"data:image/jpeg;base64,"+state.output};};
 const submitPreparedGeminiPhoto4K=(step,input,budget)=>{state.providerDeadline=budget.deadline;state.providerSignal=budget.signal;return adapterFor().submit(step,input);};
 const recordRoutedAiCost=async(_db,args)=>{state.costs.push(structuredClone(args));},recordProvenance=async()=>({id:"synthetic-provenance",recorded:true,disclosure:"Synthetic disclosure"});
 const admin={from:(table)=>{let filters=[];const q={select:()=>q,eq:(key,value)=>{filters.push([key,[value]]);return q;},is:(key,value)=>{filters.push([key,[value]]);return q;},in:(key,value)=>{filters.push([key,value]);return q;},limit:async()=>({data:state.journal&&filters.every(([key,values])=>values.includes(state.journal[key]))?[state.journal]:[],error:null}),maybeSingle:async()=>({data:table==="private_ai_outputs"?state.journal:{user_id:state.actor,org_id:state.org,role:state.role},error:null})};return q;},rpc:async(name,args)=>{
 if(name==="library_access"||name==="listing_library_scope"){
 if(state.deleted||state.role!=="owner"||args.p_actor!==state.actor)return {data:null,error:{message:"RP403: Current editor access is required"}};
 return {data:{actor_id:state.actor,org_id:state.org,library_owner_user_id:state.actor,role:state.role,access_mode:"own",can_read:true,can_write:true,can_manage_subscription:true,billing_org_id:state.org,team_org_id:null,
 ...(name==="listing_library_scope"?{listing_id:args.p_listing,library_org_id:state.org,listing_owner_user_id:state.actor}:{})},error:null};
 }
 if(name==="photo_quality_lookup"||name==="photo_quality_status")return {data:state.quality?structuredClone(state.quality):null,error:null};
 if(name==="photo_quality_begin"){
  if(!state.qualityEnabled)return{data:null,error:{message:"RP503: Photo quality review is not active yet"}};
  if(state.quality)return{data:{...structuredClone(state.quality),created:false},error:null};
  const id="ea100606-0000-4000-8000-000000000004",check="ea100606-0000-4000-8000-000000000005",input=args.p_input;
  state.quality={evidence:{id,actor_id:state.actor,org_id:state.org,library_org_id:state.org,listing_id:args.p_listing,request_key:args.p_key,request_sha256:state.operationInputHash,policy:"photo-fixed-features-v1",edit:args.p_edit,style:args.p_style,input:{...input,bucket:"renders",key:"ai-router/"+state.org+"/photo-evidence/"+state.actor+"/"+id+"/input.jpg"},output:null,input_etag:null,output_etag:null,state:"pending",provenance_id:null},check:{id:check,evidence_id:id,policy:"photo-fixed-features-v1",state:"pending",lease_token:null,lease_until:null,judge_started_at:null,derivatives:null,derivative_manifest_sha256:null},can_continue:false,created:true};
  return{data:structuredClone(state.quality),error:null};
 }
 if(name==="photo_quality_evidence_reserve"){
  const {generation_stage,provider,model,...facts}=args.p_output,e=state.quality.evidence,ext={"image/jpeg":"jpg","image/png":"png","image/webp":"webp"}[facts.mime];
  e.output={...facts,bucket:"renders",key:"ai-router/"+state.org+"/photo-evidence/"+state.actor+"/"+e.id+"/candidate."+ext};e.generation_stage=generation_stage;e.generation_provider=provider;e.generation_model=model;return{data:structuredClone(e),error:null};
 }
 if(name==="photo_quality_set_context"){state.quality.evidence.judge_context=args.p_context;return{data:structuredClone(state.quality),error:null};}
 if(name==="photo_quality_evidence_receipt"){
  const e=state.quality.evidence;if(args.p_kind==="input"){e.input_etag=args.p_etag;e.state="input_ready";}else{e.output_etag=args.p_etag;e.state="evidence_ready";e.provenance_id="ea100606-0000-4000-8000-000000000008";state.quality.can_continue=true;}return{data:structuredClone(state.quality),error:null};
 }
 if(name==="photo_quality_failure"){state.quality.evidence.state="hold";state.quality.evidence.failure={phase:args.p_phase,facts:args.p_facts};state.quality.check.state="hold";return{data:structuredClone(state.quality),error:null};}
 if(name==="serving_operation_begin"){
 if(state.deleted||state.role!=="owner")return{data:null,error:{message:"RP403: Current editor access is required"}};
 if(state.started){if(state.operationInputHash!==args.p_input_sha256)return{data:null,error:{message:"RP409: This request key was used for different input"}};if(state.saved)return{data:{replay:true,result:structuredClone(state.saved)},error:null};return{data:null,error:{message:"RP409: This operation already started. Check its saved result or status before starting another"}};}
 state.started=true;state.operationInputHash=args.p_input_sha256;return{data:{begun:true},error:null};}
 if(name==="serving_cost_reserve"){state.holds++;state.holdArguments.push(structuredClone(args));return{data:{reserved:true},error:null};}
 if(name.startsWith("org_has_"))return{data:state.qa,error:null};
 if(name==="subscription_trial_context")return{data:{trial_usage:null},error:null};
 if(name==="hosting_retention_state")return{data:{org_id:state.org,policy:"preserved",protected:true,retention_ends_at:null,hosting_available:true},error:null};
 if(name==="media_delivery_admit")return{data:{admitted:true,legacy_unbudgeted:true},error:null};
 if(name==="serving_cost_finish"){state.finishStates?.push(args.p_state);return{data:{finished:true},error:null};}
 if(name==="serving_operation_complete"){state.completes++;if(state.completeLost&&state.completes===1)throw Error("lost operation write");state.saved=structuredClone(args.p_result);return{data:{saved:true},error:null};}
 if(name==="register_private_ai_output"){
 if(state.deleted||state.role!=="owner")return{data:null,error:{message:"RP403: gone"}};
 const row={org_id:args.p_org,user_id:args.p_user,listing_id:args.p_listing,bucket:args.p_bucket,storage_key:args.p_key,bytes:args.p_bytes};
 if(state.journal&&JSON.stringify(state.journal)!==JSON.stringify(row))return{data:null,error:{message:"RP409: foreign receipt"}};
 state.journal??=row;return{data:{ok:true,key:args.p_key},error:null};}
 if(name==="serving_operation_no_dispatch")return{data:{retryable:false},error:null};
 throw Error("Unexpected RPC "+name);
 }};
 const adminClient=()=>admin;
 // This existing prompt/ledger/legacy-storage harness supplies a synthetic
 // accepted QC dependency. Actual quarantine/funding/judge/status behavior is
 // tested in photo-qc-runtime.test.ts, never inferred from this dependency.
 const preferredOrg=()=>state.org;
 const lookupPhotoQuality=actualEvidence?actualQualityStore.lookupPhotoQuality:async()=>state.quality;
 const photoQualityScope=actualEvidence?actualQualityStore.photoQualityScope:async()=>{};
 const statusPhotoQuality=actualEvidence?actualQualityStore.statusPhotoQuality:async()=>state.quality;
 const beginPhotoQuality=actualEvidence?actualQualityStore.beginPhotoQuality:async(_admin,identity,args)=>{
  if(!state.qualityEnabled)throw new HttpError(503,"Photo quality review is not active yet.","upstream");
  state.quality={identity,args,created:true,evidence:{id:"synthetic-evidence",request_sha256:state.operationInputHash},check:{state:"pending"}};return state.quality;
 };
 const retainPhotoCandidate=actualEvidence?actualQualityStore.retainPhotoCandidate:async(_admin,row,decoded)=>{
  row.saved=await persistOwnedPhotoResult(admin,row.identity,{status:"done",mime:decoded.mime,result_url:"data:"+decoded.mime+";base64,"+state.output},undefined,decoded.data);
  row.evidence.output_etag="synthetic-confirmed";
  row.evidence.output={key:row.saved.key,mime:decoded.mime,bytes:decoded.bytes,sha256:"a".repeat(64)};
  row.check.state=state.qualityPending?"pending":"accept";return row;
 };
 const failPhotoQuality=actualEvidence?actualQualityStore.failPhotoQuality:async(_admin,row,phase,facts)=>{row.check.state="hold";row.failure={phase,facts};return row;};
 const continuePhotoQuality=async(_admin,row)=>row;
 const waitForPhotoQuality=async(...args)=>{state.waits=(state.waits??0)+1;state.waitDeadline=args[2].deadline;state.waitRemaining=args[2].deadline-Date.now();return await continuePhotoQuality(...args);};
 const calibrationRequest=body=>body;
 const beginPhotoCalibration=async()=>{state.calibrationCalls=(state.calibrationCalls??0)+1;return{evidence:{id:"synthetic-calibration"},check:{state:"pending"}};};
 const photoQualityResponse=actualEvidence?actualQualityStore.photoQualityResponse:async(_admin,row)=>{
  if(row.check.state!=="accept")throw new HttpError(409,"Saved photo is private pending review.",row.check.state==="hold"?"photo_quality_hold":"photo_quality_pending",{check_id:"synthetic-check",evidence_id:"synthetic-evidence",retry_existing_job:true,failure_phase:row.failure?.phase,...row.failure?.facts});
  const metadata={edit:row.args.edit,...(row.args.style?{style:row.args.style}:{}),disclosure:"Synthetic disclosure",provenance:{id:"synthetic-provenance",recorded:true}};
  if(!row.responded){row.responded=true;return photoJsonResponse(metadata,state.output,row.saved.mime,row.saved.key);}
  const saved=await restorePhotoResult(admin,row.identity);if(!saved)throw new HttpError(503,"Saved photo is not available.");
  return photoJsonResponse(metadata,saved.image_b64,saved.mime,saved.key);
 };
 export const run=async(req)=>{${source.slice(start,end)}};
 export async function restore(identity,pointer){return await restorePhotoResult(admin,identity,pointer);}
 export async function withdrawDuringSign(){return await restorePhotoResult(admin,{actorId:state.actor,orgId:state.org,requestKey:"owned-photo-0001",listingId:${JSON.stringify(listing)}},undefined,{head:async()=>({exists:true,bytes:${atob(OUTPUT).length}}),sign:async()=>{state.role="viewer";return"https://synthetic.invalid";},read:async()=>{state.gets++;throw Error("Never read after signing-time withdrawal");}});}
 export {photoResultKeys,inputHash};
 `));
 const previous=globalThis.fetch;
 globalThis.fetch=(async(input:Request|string|URL,init?:RequestInit)=>{
 const request=input instanceof Request?input:new Request(input,init),u=new URL(request.url),method=request.method;
 if(!u.hostname.endsWith(".r2.cloudflarestorage.com"))throw Error("Unexpected vendor/network transport");
 if(actualEvidence){
  const key=decodeURIComponent(u.pathname.split("/").slice(2).join("/")),object=imported.state.objects.get(key);
  if(method==="PUT"){imported.state.puts++;assertEquals(request.headers.get("if-none-match"),"*");if(imported.state.storageFail)return new Response(null,{status:503});if(object)return new Response(null,{status:412});
   const bytes=await request.arrayBuffer();imported.state.objects.set(key,{bytes,mime:request.headers.get("content-type"),sha256:request.headers.get("x-amz-meta-sha256"),etag:'"fixture-etag"'});if(key.includes("/candidate."))imported.state.object=bytes;if(imported.state.putLost)throw Error("lost committed evidence PUT");return new Response(null,{status:200});}
  if(method==="HEAD")return object?new Response(null,{headers:{"content-length":String(object.bytes.byteLength),"content-type":object.mime,"x-amz-meta-sha256":object.sha256,etag:object.etag}}):new Response(null,{status:404});
  if(method==="GET"){imported.state.gets++;return new Response(object.bytes,{headers:{"content-length":String(object.bytes.byteLength),"content-type":object.mime}});}
  throw Error("Unexpected evidence transport");
 }
 if(method==="PUT"){
 imported.state.puts++;assertEquals(request.headers.get("if-none-match"),"*");assertEquals(request.redirect,"error");
 if(imported.state.storageFail)return new Response("",{status:503});
 if(imported.state.object)return new Response(null,{status:412});
 imported.state.object=await request.arrayBuffer();if(imported.state.putLost)throw Error("lost committed PUT");return new Response(null,{status:200});}
 if(method==="HEAD")return imported.state.object?new Response(null,{headers:{"content-length":String(imported.state.object.byteLength),"content-type":"image/jpeg"}}):new Response(null,{status:404});
 if(method==="GET"){
 imported.state.gets++;assertEquals(request.redirect,"error");assertEquals(init?.credentials,"omit");assertEquals([...request.headers],[]);assertEquals(u.searchParams.get("X-Amz-Expires"),"600");assertEquals(u.searchParams.get("X-Amz-SignedHeaders"),"host");
 if(imported.state.withdrawOnGet)imported.state.role="viewer";
 return new Response(imported.state.object,{headers:{"content-length":String(imported.state.object?.byteLength??0),"content-type":"image/jpeg"}});}
 throw Error("Unexpected R2 method");
 }) as typeof fetch;
 const image=btoa(String.fromCharCode(...[255,216,255,192,0,11,8,0,1,0,1,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]));
 return{...imported,close:()=>{globalThis.fetch=previous;},request:(extra:Record<string,unknown>={})=>new Request("https://example.invalid/ai-photo",{method:"POST",headers:{"content-type":"application/json","idempotency-key":"owned-photo-0001","x-rendprop-photo-quality-protocol":"retained-operation-v1"},body:JSON.stringify({image_b64:image,edit:"twilight",mime:"image/jpeg",listing_id:listing,...extra})})};
}
// Load exact production signers only after synthetic test credentials exist.
for(const [key,value] of Object.entries({CLOUDFLARE_ACCOUNT_ID:"a".repeat(32),R2_ACCESS_KEY_ID:"b".repeat(32),R2_SECRET_ACCESS_KEY:"c".repeat(64)}))Deno.env.set(key,value);
const {ProviderResponseLimitError}=await import("../_shared/providers/common.ts");
Deno.test("actual photo handler router-off and router-on persist once and replay inline without another quota or provider",async()=>{
 for(const router of [false,true]){const f=await fixture();try{f.state.router=router;
 const first=await f.run(f.request());assertEquals(first.status,200);const result=await first.json();assertEquals(result.image_b64,OUTPUT);assert(/^ai-router\/.+\/completed-photo\/[a-f0-9]{64}\.jpg$/.test(result.asset_key));
 const second=await f.run(f.request());assertEquals(second.status,200);const restored=await second.json();assertEquals(restored.image_b64,OUTPUT);assertEquals(restored.asset_key,result.asset_key);assertEquals(f.state.charges,1);assertEquals(f.state.submits,1);assertEquals(f.state.polls,1);assertEquals(f.state.puts,1);assertEquals(f.state.gets,1);
 assert(!JSON.stringify(f.state.saved).includes("X-Amz"));assert(!JSON.stringify(f.state.saved).includes(OUTPUT));
 }finally{f.close();}}
});
Deno.test("actual photo handler refuses malformed/animated/oversized prompt input before quota and dispatch",async()=>{
 for(const body of [{image_b64:"QUFB"},{image_b64:"AAAA",mime:"image/heic"},{edit:"custom",prompt:"é".repeat(601)}]){
  const f=await fixture();try{const response=await f.run(f.request(body));assertEquals(response.status,400,await response.text());assertEquals(f.state.charges,0);assertEquals(f.state.submits,0);}finally{f.close();}
 }
});
Deno.test("actual custom photo handler clarifies or refuses before operation admission, holds or image dispatch",async()=>{
 for(const [prompt,status,code] of [["make it nicer",409,"photo_clarification_required"],["clean garage",409,"photo_clarification_required"],["modernize garage",409,"photo_clarification_required"],["repaint garage white",400,"unsupported_edit"],["make the garage door white",400,"unsupported_edit"],["hide wall crack",400,"unsupported_edit"],["re\u200Bpaint the garage and improve lighting",400,"unsupported_edit"],["chànge trím color and improve lighting",400,"unsupported_edit"]] as const){
  const f=await fixture();try{const response=await f.run(f.request({edit:"custom",prompt}));assertEquals(response.status,status);const body=await response.json();assertEquals(body.code,code);assertEquals(body.no_charge,true);if(status===409)assertEquals(body.clarification_options.length,4);assertEquals(f.state.started,false);assertEquals(f.state.holds,0);assertEquals(f.state.charges,0);assertEquals(f.state.submits,0);}finally{f.close();}
 }
});
Deno.test("actual photo handler refuses staging brief and compound custom safety bypasses before any paid work",async()=>{
 for(const [edit,prompts] of [
  ["stage",["modern sofa, and paint the walls white","beige chairs and get rid of the water damage","wood table; new hardwood floors"]],
  ["custom",["remove the boxes and the water stain on the ceiling","declutter the counters and get rid of the water damage","brighten the kitchen and swap the countertops for marble","remove the toys, new hardwood floors"]],
 ] as const){for(const prompt of prompts){const f=await fixture();try{
  const response=await f.run(f.request({edit,prompt}));assert(response.status===400||response.status===409,`${edit}: ${prompt} must be refused before dispatch`);
  const body=await response.json();assertEquals(body.no_charge,true);assertEquals(f.state.started,false);assertEquals(f.state.holds,0);assertEquals(f.state.charges,0);assertEquals(f.state.submits,0);
 }finally{f.close();}}}
});
Deno.test("actual staging handler accepts furniture noun briefs and retains all 600 characters and fixed-feature locks",async()=>{
 const prefix="cream sofa, oak table and wall art. ",tail=" Keep walls, ceilings and floors unchanged.";
 const full=prefix+"soft linen ".repeat(60).slice(0,600-prefix.length-tail.length)+tail;assertEquals(full.length,600);
 for(const prompt of ["modern sofa","a painted white chair and floor lamp; keep all original finishes.",full]){
  for(const router of [false,true]){const f=await fixture();try{f.state.router=router;
   const response=await f.run(f.request({edit:"stage",prompt}));assertEquals(response.status,200,await response.text());
   assertEquals(f.state.charges,1);assertEquals(f.state.holds,1);assertEquals(f.state.submits,1);
   assert(f.state.prompts[0].includes(JSON.stringify(prompt)));assert(f.state.prompts[0].includes("garage-door color and finish"));
   assert(f.state.prompts[0].includes("trim color and finish"));assert(f.state.prompts[0].includes("quoted data for movable furniture only"));
  }finally{f.close();}}
 }
});
Deno.test("actual staging handler delivers furniture-only scope and exact source on all styles and routing modes",async()=>{
 const {prepareOwnerQaPhotoInput}=await import("./owner-photo-qa.ts");
 for(const style of ["modern","rustic","minimalist","contemporary","scandinavian"]){
  for(const router of [false,true]){const f=await fixture();try{f.state.router=router;
   const request=f.request({edit:"stage",style}),input=await request.clone().json();
   const response=await f.run(request);assertEquals(response.status,200,await response.text());
   assertEquals(f.state.charges,1);assertEquals(f.state.holds,1);assertEquals(f.state.submits,1);assertEquals(f.state.helperDispatch,0);
   const sent=f.state.inputs[0],prompt=sent.prompt;
   if(style==="contemporary") {assert(prompt.includes("softly curved seating"));assert(!prompt.includes("Scandinavian furniture"));}
   if(style==="scandinavian") {assert(prompt.includes("Scandinavian furniture"));assert(!prompt.includes("contemporary furniture:"));}
   assertEquals(sent.image_b64,input.image_b64);assertEquals(sent.image_url,`data:image/jpeg;base64,${input.image_b64}`);
   for(const lock of ["edit movable furnishings only","overhead slab","existing open pergolas open","garage-door color and finish","trim color and finish","outdoor furniture on a balcony","No repainting","never copy its architecture or viewpoint","do not repair or hide them","wall-mounted, ceiling-mounted and built-in items","Do not add shelves"])assert(prompt.includes(lock),lock);
   assert(new TextEncoder().encode(prompt).length<4096,"Default staging prompt retains the2K source/text bound");
   const inputBound=prepareOwnerQaPhotoInput(sent).extra?.owner_photo_input_bound;
   assert(typeof inputBound==="number"&&inputBound<=8192);
  }finally{f.close();}}
 }
});
Deno.test("actual staging refuses1K fallback while preserving the surgical prompt, brief and selected source",async()=>{
 const f=await fixture();try{f.state.router=true;f.state.primaryFail=true;f.state.routes=[
  {route_id:"primary",provider:"gemini",model:"gemini-3.1-flash-image",task:"photo.stage",unit:"output_image",unit_cents:6.7},
  {route_id:"fallback",provider:"fal",model:"flux-pro/kontext",task:"photo.stage",unit:"output_image",unit_cents:4}];
  const brief="Outdoor chairs and a small movable table, with natural linen cushions.";
  const request=f.request({edit:"stage",style:"rustic",prompt:brief}),body=await request.clone().json();
  const response=await f.run(request);assertEquals(response.status,409,await response.text());
  assertEquals(f.state.submits,1);assertEquals(f.state.holds,1);assertEquals(f.state.helperDispatch,0);
  assertEquals(f.state.inputs[0].extra.photo_quality_4k,true);assert(f.state.prompts[0].includes(JSON.stringify(brief)));
  assert(f.state.prompts[0].includes("solid slabs solid"));assert(f.state.prompts[0].includes("existing open pergolas open"));
  for(const input of f.state.inputs){assertEquals(input.image_b64,body.image_b64);assertEquals(input.image_url,`data:image/jpeg;base64,${body.image_b64}`);}
 }finally{f.close();}
});
Deno.test("compiled removal of the staging builder fails the unchanged actual-handler furniture/source oracle",async()=>{
 const f=await fixture(false,"stage_prompt");try{
  await assertRejects(async()=>{const response=await f.run(f.request({edit:"stage",style:"rustic"}));assertEquals(response.status,200);assert(f.state.prompts[0].includes("existing open pergolas open"),"Preserve the photographed overhead construction rather than restyling it");},AssertionError);
  assertEquals(f.state.submits,1);assertEquals(f.state.holds,1);assertEquals(f.state.helperDispatch,0);
 }finally{f.close();}
});
Deno.test("actual optional photo polisher refuses compound input before charging and smuggled output after its one helper attempt",async()=>{
 for(const prompt of ["Remove boxes and the water stain on the ceiling.","Improve lighting and swap countertops for marble."]){const f=await fixture();try{
  const response=await f.run(f.request({edit:"improve_prompt",prompt}));assert(response.status===400||response.status===409);assertEquals((await response.json()).no_charge,true);
  assertEquals(f.state.started,false);assertEquals(f.state.holds,0);assertEquals(f.state.charges,0);assertEquals(f.state.helperDispatch,0);
 }finally{f.close();}}
 for(const [prompt,output] of [["Remove boxes only.","Remove boxes and the water stain on the ceiling."],["Improve lighting only.","Improve lighting and swap countertops for marble."]]){const f=await fixture();try{
  f.state.helperText=output;const response=await f.run(f.request({edit:"improve_prompt",prompt}));assertEquals(response.status,502);
  const body=await response.json();assertEquals(body.code,"upstream");assertEquals(body.prompt,undefined);assertEquals(body.no_charge,undefined);
  assertEquals(f.state.helperDispatch,1);assertEquals(f.state.holds,1);assertEquals(f.state.submits,0);
 }finally{f.close();}}
});
Deno.test("compiled removal of staging brief gate fails unchanged pre-charge safety oracle",async()=>{
 const f=await fixture(false,"stage");try{
  await assertRejects(async()=>{const response=await f.run(f.request({edit:"stage",prompt:"modern sofa and paint the walls white"}));assertEquals(response.status,400);assertEquals(f.state.holds,0);assertEquals(f.state.submits,0);},AssertionError);
  assertEquals(f.state.holds,1);assertEquals(f.state.charges,1);assertEquals(f.state.submits,1);
 }finally{f.close();}
});
Deno.test("actual custom handler automatically prepares the complete request and locks garage, trim and paint on both routing modes",async()=>{
 const prefix="Improve brightness and exposure only. ",tail=" Preserve the garage door and trim colors exactly.";
 const prompt=prefix+"natural lighting ".repeat(40).slice(0,600-prefix.length-tail.length)+tail;assertEquals(prompt.length,600);
 for(const router of [false,true]){const f=await fixture();try{f.state.router=router;
  const response=await f.run(f.request({edit:"custom",prompt}));assertEquals(response.status,200,await response.text());assertEquals(f.state.submits,1);assertEquals(f.state.holds,1);
  const prepared=f.state.prompts[0];assert(prepared.includes(JSON.stringify(prompt)));assert(prepared.includes("garage-door color and finish"));assert(prepared.includes("trim color and finish"));assert(prepared.includes("every existing paint color"));assert(prepared.includes("quoted data"));
 }finally{f.close();}}
});
Deno.test("actual custom handler accepts all 600 accented characters without truncating the quoted request",async()=>{
 const prefix="Improve brightness only. ",tail=" Preserve the garage and trim colors.";
 const prompt=prefix+"é".repeat(600-prefix.length-tail.length)+tail;
 const f=await fixture();try{const response=await f.run(f.request({edit:"custom",prompt}));assertEquals(response.status,200,await response.text());assertEquals(f.state.submits,1);assert(f.state.prompts[0].includes(JSON.stringify(prompt)));}
 finally{f.close();}
});
Deno.test("actual custom handler cannot quietly fallback to1K after its prepared4K attempt fails",async()=>{
 const f=await fixture();try{f.state.router=true;f.state.primaryFail=true;f.state.routes=[
  {route_id:"primary",provider:"gemini",model:"gemini-3.1-flash-image",task:"photo.custom",unit:"output_image",unit_cents:6.7},
  {route_id:"fallback",provider:"fal",model:"flux-pro/kontext",task:"photo.custom",unit:"output_image",unit_cents:4}];
  const response=await f.run(f.request({edit:"custom",prompt:"Remove bags from the garage. Do not repaint or change the trim color."}));assertEquals(response.status,409,await response.text());
  assertEquals(f.state.submits,1);assertEquals(f.state.holds,1);assertEquals(f.state.inputs[0].extra.photo_quality_4k,true);assert(f.state.prompts[0].includes("garage-door color and finish"));assert(f.state.prompts[0].includes("trim color and finish"));
 }finally{f.close();}
});
Deno.test("legacy photo polisher clarifies before a paid helper and refuses invented same-category work",async()=>{
 for(const [prompt,status] of [["make garage nicer",409],["repair roof",400]] as const){const f=await fixture();try{
  const response=await f.run(f.request({edit:"improve_prompt",prompt}));assertEquals(response.status,status);assertEquals(f.state.started,false);assertEquals(f.state.holds,0);assertEquals(f.state.charges,0);assertEquals(f.state.helperDispatch,0);
 }finally{f.close();}}
 const f=await fixture();try{f.state.helperText="Remove boxes and movable furniture.";
  const response=await f.run(f.request({edit:"improve_prompt",prompt:"Remove boxes only."}));assertEquals(response.status,502);assertEquals((await response.json()).code,"upstream");assertEquals(f.state.helperDispatch,1);assertEquals(f.state.holds,1);assertEquals(f.state.submits,0);
 }finally{f.close();}
});
Deno.test("compiled missing custom preparation fails unchanged no-spend clarification oracle",async()=>{
 const f=await fixture(false,"intent");try{
  await assertRejects(async()=>{const response=await f.run(f.request({edit:"custom",prompt:"make it nicer"}));assertEquals(response.status,409);assertEquals(f.state.holds,0);assertEquals(f.state.submits,0);},AssertionError);
  assertEquals(f.state.holds,1);assertEquals(f.state.submits,1);
 }finally{f.close();}
});
Deno.test("actual photo handler refuses a duplicated priced primary before any paid dispatch",async()=>{
 const f=await fixture();try{f.state.router=true;f.state.routes=[0,1].map(i=>({route_id:"route-"+i,provider:"gemini",model:"gemini-3.1-flash-image",task:"photo.twilight"}));
  const response=await f.run(f.request());assertEquals(response.status,503);assertEquals(f.state.submits,0);assertEquals(f.state.puts,0);
 }finally{f.close();}
});
Deno.test("actual photo handler recovers a committed output whose result-pointer response was lost",async()=>{
 const f=await fixture();try{f.state.completeLost=true;assertEquals((await f.run(f.request())).status,200);assertEquals(f.state.saved,null);
 const retry=await f.run(f.request());assertEquals(retry.status,200);assertEquals((await retry.json()).image_b64,OUTPUT);assertEquals(f.state.submits,1);assertEquals(f.state.puts,1);assertEquals(f.state.charges,1);assertEquals(f.state.completes,1);assertEquals(f.state.saved,null,"Quality row recovery does not depend on repairing the pointer ACK");
 }finally{f.close();}
});
Deno.test("actual photo handler holds a lost committed evidence PUT without another provider or object write",async()=>{
 const f=await fixture();try{f.state.putLost=true;assertEquals((await f.run(f.request())).status,409);assert(f.state.journal&&f.state.object);
 const retry=await f.run(f.request());assertEquals(retry.status,409);const body=await retry.json();assertEquals(body.code,"photo_quality_hold");assertEquals(body.image_b64,undefined);assertEquals(f.state.submits,1);assertEquals(f.state.puts,1);assertEquals(f.state.charges,1);
 }finally{f.close();}
});
Deno.test("actual completed-image storage failure cannot start paid fallback or regenerate a missing object",async()=>{
 const f=await fixture();try{f.state.storageFail=true;assertEquals((await f.run(f.request())).status,409);assertEquals((await f.run(f.request())).status,409);assertEquals(f.state.submits,1);assertEquals(f.state.puts,1);assertEquals(f.state.charges,1);
 }finally{f.close();}
});
Deno.test("actual photo replay refuses foreign exact receipt and deletion before storage",async()=>{
 for(const mode of ["foreign","deleted"]){const f=await fixture();try{assertEquals((await f.run(f.request())).status,200);if(mode==="foreign")f.state.journal.user_id="foreign";else f.state.deleted=true;
 const retry=await f.run(f.request());assert(retry.status!==200);assertEquals(f.state.gets,0);assertEquals(f.state.submits,1);
 }finally{f.close();}}
});
Deno.test("actual photo replay rechecks access after signing and after the bounded private read",async()=>{
 const f=await fixture();try{assertEquals((await f.run(f.request())).status,200);f.state.withdrawOnGet=true;const retry=await f.run(f.request());assertEquals(retry.status,403);assertEquals(f.state.gets,1);assertEquals(f.state.submits,1);const body=await retry.text();assert(!body.includes(OUTPUT));assert(!body.includes("X-Amz"));
 }finally{f.close();}
});
Deno.test("actual photo replay rejects signing-time access withdrawal before GET",async()=>{
 const f=await fixture();try{assertEquals((await f.run(f.request())).status,200);await assertRejects(()=>f.withdrawDuringSign(),Error,"Current editor access is required");assertEquals(f.state.gets,0);}finally{f.close();}
});
Deno.test("compiled removed final photo-authority check fails the unchanged no-private-bytes boundary",async()=>{
 const verify=async(remove:boolean)=>{const f=await fixture(remove);try{assertEquals((await f.run(f.request())).status,200);f.state.withdrawOnGet=true;const retry=await f.run(f.request());assertEquals(retry.status,403,"Withdrawal during replay must suppress private photo bytes");}finally{f.close();}};
 await verify(false);await assertRejects(()=>verify(true),AssertionError,"Withdrawal during replay must suppress private photo bytes");
});

Deno.test("compiled missing input/finite-chain guards fail unchanged actual-handler admission oracles",async()=>{
 const oracle=async(remove:"input"|"chain"|null,mode:"input"|"chain")=>{
  const f=await fixture(false,remove);try{
   if(mode==="chain"){f.state.router=true;f.state.routes=[0,1].map(i=>({route_id:"route-"+i,provider:"gemini",model:"gemini-3.1-flash-image",task:"photo.twilight"}));}
   const response=await f.run(f.request(mode==="input"?{image_b64:"QUFB"}:{}));
   assertEquals(response.status,mode==="input"?400:503,"Prospective admission must refuse before paid dispatch");assertEquals(f.state.submits,0);
  }finally{f.close();}
 };
 for(const mode of ["input","chain"] as const){await oracle(null,mode);await assertRejects(()=>oracle(mode,mode),AssertionError,"Prospective admission must refuse before paid dispatch");}
});

Deno.test("actual saved2K photo recovery preserves historical size and input now refused for new dispatch",async()=>{
 const f=await fixture();try{
  assertEquals((await f.run(f.request())).status,200);
  const historical2K=outputJPEG(1792,2390);
  f.state.object=Uint8Array.from(atob(historical2K),c=>c.charCodeAt(0)).buffer;
  f.state.saved={kind:"photo_output",bucket:"renders",key:f.state.journal.storage_key,mime:"image/jpeg",metadata:{image_size:"2K"}};f.state.quality=null;
  const request=f.request({image_b64:"QUFB",mime:"image/heic"});
  // Represent an exact immutable old financial input journal, whose saved
  // owned output predates this new dispatch policy. No old provider is called.
  f.state.operationInputHash=await f.inputHash(await request.clone().json());
  const response=await f.run(request);assertEquals(response.status,200);const restored=await response.json();assertEquals(restored.image_b64,historical2K);assertEquals(restored.image_size,"2K");
  assertEquals(f.state.submits,1);assertEquals(f.state.charges,1);assertEquals(f.state.puts,1);assertEquals(f.state.gets,1);
  const changed=await f.run(f.request({image_b64:"QUFB",mime:"image/heic",label:"different"}));assertEquals(changed.status,409);assertEquals(f.state.gets,1);
 }finally{f.close();}
});

Deno.test("actual custom, staging and polishing input refuse preservation evasions before any money or provider work", async()=>{
 const cases={
  custom:["remove the toys, keep the stain hidden","brighten the room; don't show the water stain","Add a grey sofa; keep the vibe and patch the hole in the wall","Improve lighting and remove the fireplace","Brighten exposure; marble on the counters"],
  stage:["grey sofa, keep the vibe and patch the hole in the wall","cream sofa; keep the stain hidden","white chair; take out the bathtub","oak table; lay hardwood","a rug; no mildew"],
  improve_prompt:["remove the toys, keep the stain hidden","brighten the room; don't show the water stain","Add a grey sofa; keep the vibe and patch the hole in the wall","Remove boxes and scratches","Improve lighting; granite instead of laminate"],
 };
 for(const [edit,prompts] of Object.entries(cases))for(const prompt of prompts){const f=await fixture();try{
  const response=await f.run(f.request({edit,prompt}));assert(response.status===400||response.status===409,`${edit}: ${prompt}`);
  const body=await response.json();assertEquals(body.no_charge,true);assertEquals(f.state.started,false);assertEquals(f.state.holds,0);assertEquals(f.state.charges,0);assertEquals(f.state.submits,0);assertEquals(f.state.helperDispatch,0);
  if(edit==="stage"){assert(body.error.includes("furniture")||body.error.includes("staging"));if(response.status===409)assertEquals(body.clarification_options.map((x:{id:string})=>x.id),["furniture"]);}
 }finally{f.close();}}
});
Deno.test("actual polisher suppresses preservation evasions in its response after exactly one paid helper",async()=>{
 for(const [prompt,output] of [
  ["Remove toys.","Remove toys; keep the stain hidden."],
  ["Brighten lighting.","Brighten lighting; don't show the water stain."],
  ["Add a grey sofa.","Add a grey sofa; keep the vibe and patch the hole in the wall."],
 ]){const f=await fixture();try{
  f.state.helperText=output;const response=await f.run(f.request({edit:"improve_prompt",prompt}));assertEquals(response.status,502);
  const body=await response.json();assertEquals(body.code,"upstream");assertEquals(body.prompt,undefined);assertEquals(body.no_charge,undefined);
  assertEquals(f.state.helperDispatch,1);assertEquals(f.state.holds,1);assertEquals(f.state.charges,1);assertEquals(f.state.submits,0);
 }finally{f.close();}}
});
Deno.test("build 57: actual custom, staging and polishing input refuse negated-preservation, renewed-finish and bare-material smuggling before any money or provider work",async()=>{
 const cases={
  custom:["brighten the room, don't leave the stain visible","remove the toys. do not keep the wallpaper","remove the toys, keep the walls freshly painted","remove the toys, keep the ceiling clean and smooth","remove the boxes. white kitchen","remove the boxes. marble worktops","remove the boxes. with hardwood","remove the boxes. put hardwood down","remove the boxes. lighten the wall paint","remove the boxes. brighten the walls so they look new","remove the toys and the dark patch on the ceiling","brighten the kitchen, no water stains","remove the boxes. keep going and take out the crack"],
  stage:["grey sofa and a white kitchen","grey sofa; marble worktops","grey sofa on new hardwood","cream sofa, keep the walls freshly painted","grey sofa; don't show the water stain","grey sofa, stains removed","cream sofa; clean up the scuffs","grey sofa; give the room a fresh coat of white"],
  improve_prompt:["remove the toys. do not keep the carpet","remove the toys, keep the walls freshly painted","remove the boxes. with a marble island","brighten the walls so they appear newer"],
 };
 for(const [edit,prompts] of Object.entries(cases))for(const prompt of prompts){const f=await fixture();try{
  const response=await f.run(f.request({edit,prompt}));assert(response.status===400||response.status===409,`${edit}: ${prompt} => ${response.status}`);
  const body=await response.json();assertEquals(body.no_charge,true);assertEquals(f.state.started,false);assertEquals(f.state.holds,0);assertEquals(f.state.charges,0);assertEquals(f.state.submits,0);assertEquals(f.state.helperDispatch,0);
  assertEquals(f.state.prompts.length,0,"nothing reaches a provider");
  if(edit==="stage"&&response.status===409)assertEquals(body.clarification_options.map((x:{id:string})=>x.id),["furniture"]);
 }finally{f.close();}}
 // The paid polisher cannot launder the same wording into its suggestion.
 for(const [prompt,output] of [["Remove toys.","Remove toys, keep the walls freshly painted."],["Brighten the room.","Brighten the room, don't leave the stain visible."],["Remove boxes.","Remove boxes. with hardwood"]]){const f=await fixture();try{
  f.state.helperText=output;const response=await f.run(f.request({edit:"improve_prompt",prompt}));assertEquals(response.status,502);
  const body=await response.json();assertEquals(body.code,"upstream");assertEquals(body.prompt,undefined);assertEquals(f.state.helperDispatch,1);assertEquals(f.state.submits,0);
 }finally{f.close();}}
 // Honest preservation, kitchen/bathroom declutter and plain furniture briefs still dispatch exactly once.
 for(const [edit,prompt] of [
  ["custom","remove the boxes but don't touch the walls"],
  ["custom","brighten the kitchen. keep the paint color exactly as is."],
  ["custom","add a sofa and preserve the garage door color"],
  ["custom","remove the toys, keep the walls white"],
  ["custom","declutter the kitchen and tidy up the bathroom"],
  ["custom","remove the dishes from the kitchen island"],
  ["stage","modern grey sofa and a rug"],
  ["stage","cream sofa and two armchairs"],
  ["stage","sectional sofa facing the fireplace; keep the hardwood floors as they are"],
 ]){const f=await fixture();try{
  const response=await f.run(f.request({edit,prompt}));assertEquals(response.status,200,`${edit}: ${prompt} => ${await response.text()}`);
  assertEquals(f.state.holds,1);assertEquals(f.state.charges,1);assertEquals(f.state.submits,1);assertEquals(f.state.helperDispatch,0);
  assert(f.state.prompts[0].includes(JSON.stringify(prompt)));assert(f.state.prompts[0].includes("garage-door color and finish"));
 }finally{f.close();}}
});
Deno.test("actual handler still admits safe glass, wood, painted furniture and fixed-feature preservation on both routes",async()=>{
 for(const [edit,prompt] of [
  ["custom","Add a grey sofa; keep the walls white."],
  ["custom","Remove toys from the carpet; keep scratches visible and unchanged."],
  ["custom","Brighten the fireplace with natural illumination; do not change its finish."],
  ["stage","cream sofa, oak table and painted white chairs; preserve all original finishes."],
  ["stage","a rug beside the fireplace and a floor lamp near the staircase; keep walls white."],
 ])for(const router of [false,true]){const f=await fixture();try{f.state.router=router;
  const response=await f.run(f.request({edit,prompt}));assertEquals(response.status,200,await response.text());
  assertEquals(f.state.holds,1);assertEquals(f.state.charges,1);assertEquals(f.state.submits,1);assertEquals(f.state.helperDispatch,0);
  assert(f.state.prompts[0].includes(JSON.stringify(prompt)));assert(f.state.prompts[0].includes("garage-door color and finish"));
 }finally{f.close();}}
});

Deno.test("actual normal4K handler retains wrong-size evidence while withholding1K/2K delivery and keeping incurred cost",async()=>{
 for(const [width,height,valid]of [[4096,4096,true],[3584,4800,true],[1792,2390,false],[896,1195,false]]as const){const f=await fixture();try{
  f.state.output=outputJPEG(width,height);
  const response=await f.run(f.request({edit:"stage",style:"modern"}));assertEquals(response.status,valid?200:409,await response.text());
  assertEquals(f.state.holds,1);assertEquals(f.state.submits,1);assertEquals(f.state.costs.length,1);
  assertEquals(f.state.costs[0].step.params.image_size,"4K");assertEquals(f.state.costs[0].step.unit_cents,16.7584);
  assertEquals(f.state.refunds,0,"A received supplier image cannot erase incurred liability");assertEquals(f.state.costs[0].meta.owner_quality_comparison,false);assertEquals(f.state.costs[0].meta.image_size,"4K");assertEquals(f.state.costs[0].meta.cost_basis,"complete_input_4096_text_2520_image_bound");
  const hold=f.state.holdArguments[0].p_hold_cents;assert(hold>=16.7584&&hold-16.7584<0.00021,"Complete4K liability with conservative four-decimal rounding");
  assertEquals(f.state.puts,1,"Valid still bytes are retained privately even when supplier geometry is wrong");assertEquals(f.state.completes,1);
 }finally{f.close();}}
});
Deno.test("compiled missing normal4K output floor fails unchanged actual-handler no-delivery oracle",async()=>{
 const oracle=async(remove:boolean)=>{const f=await fixture(false,remove?"quality":null);try{
  f.state.output=outputJPEG(1792,2390);const response=await f.run(f.request({edit:"stage",style:"modern"}));
  assertEquals(response.status,409,"Undersized supplier output reached delivery");assertEquals(f.state.puts,1);assertEquals(f.state.costs.length,1);
 }finally{f.close();}};
 await oracle(false);await assertRejects(()=>oracle(true),AssertionError,"Undersized supplier output reached delivery");
});
Deno.test("masked Fill actual handler records rounded source megapixels once and excludes4K claims",async()=>{
 const oracle=async(remove:boolean)=>{const f=await fixture(false,remove?"masked_price":null);try{
  // This boundary fixture explicitly uses existing private sponsorship so it
  // can isolate ledger integration; ordinary ceiling admission is tested
  // independently with the real fundedAttempt helper, not claimed by this mock.
  f.state.qa=true;f.state.router=true;
  f.state.routes=[{route_id:"existing-mask-route",provider:"fal",model:"fal-ai/flux-pro/v1/fill",task:"photo.declutter",unit:"image",unit_cents:5,capabilities:["mask"],max_latency_s:60,min_plan:"free",privacy_tier:"retained_30d",enabled:true}];
  const original=outputJPEG(1536,2048);f.state.output=original;
  const request=()=>f.request({image_b64:original,edit:"declutter",mask_b64:original,mask_mime:"image/jpeg"});
  const response=await f.run(request());assertEquals(response.status,200,await response.text());
  assertEquals(f.state.costs.length,1);assertEquals(f.state.costs[0].step.unit_cents,20,"A3.145728MP Fill edit must not settle as a5-cent image");
  assertEquals(f.state.costs[0].step.route_id,"existing-mask-route");
  assertEquals(f.state.costs[0].meta.cost_basis,"source_megapixels_rounded_up_5_cents_bound");
  assertEquals(f.state.costs[0].meta.priced_megapixels,4);
  assertEquals(f.state.costs[0].meta.image_size,undefined);
  assertEquals(f.state.inputs[0].extra.photo_quality_4k,undefined);
  assertEquals((await f.run(request())).status,200);
  assertEquals(f.state.submits,1);assertEquals(f.state.charges,1);assertEquals(f.state.costs.length,1);assertEquals(f.state.puts,1);
 }finally{f.close();}};
 await oracle(false);
 await assertRejects(()=>oracle(true),AssertionError,"must not settle as a5-cent image");
});
const sizedOutputJPEG=(size:number,width=3584,height=4780)=>{
 const frame=Uint8Array.from(atob(outputJPEG(width,height)),c=>c.charCodeAt(0)),bytes=new Uint8Array(size);
 bytes.set(frame.subarray(0,2));let offset=2,left=size-frame.length;
 while(left){let length=Math.min(65000,left);if(left-length>0&&left-length<4)length-=4;bytes.set([255,224,(length-2)>>8,(length-2)&255],offset);offset+=length;left-=length;}
 bytes.set(frame.subarray(2),offset);let binary="";for(let n=0;n<bytes.length;n+=32768)binary+=String.fromCharCode(...bytes.subarray(n,n+32768));return btoa(binary);
};
Deno.test("actual4K handler refuses one byte over the9MB source bound before quota, hold or provider",async()=>{
 const f=await fixture();try{
  const response=await f.run(f.request({image_b64:sizedOutputJPEG(9_000_001,1536,2048)}));
  assertEquals(response.status,413);assertEquals(f.state.charges,0);assertEquals(f.state.holds,0);assertEquals(f.state.submits,0);assertEquals(f.state.costs.length,0);assertEquals(f.state.puts,0);assertEquals(f.state.refunds,0);
 }finally{f.close();}
});
Deno.test("actual4K handler validates9MB once and reuses those exact bytes for immutable storage and base64 JSON",async()=>{
 const f=await fixture(),decode=globalThis.atob;
 try{
  const image=sizedOutputJPEG(9_000_000);f.state.output=image;let chunks=0;
  globalThis.atob=value=>{if(value.length===32768)chunks++;return decode(value);};
  const response=await f.run(f.request());assertEquals(response.status,200);
  assertEquals(chunks,Math.floor(image.length/32768),"Persistence must not decode another complete output buffer");
  assertEquals(f.state.object.byteLength,9_000_000);assertEquals(f.state.puts,1);assertEquals(f.state.costs.length,1);
  const result=await response.json();assertEquals(result.image_b64,image);assertEquals(result.mime,"image/jpeg");
 }finally{globalThis.atob=decode;f.close();}
});
Deno.test("actual4K handler keeps paid supplier liability for one-byte output overflow and never persists or regenerates",async()=>{
 const f=await fixture();try{
  f.state.output=sizedOutputJPEG(25*1024*1024+1);const response=await f.run(f.request());assertEquals(response.status,409);
  const error=await response.json();assertEquals(error.failure_phase,"photo_output_size");assertEquals(error.provider_cost_incurred,true);
  assertEquals(f.state.costs.length,1);assertEquals(f.state.submits,1);assertEquals(f.state.refunds,0);assertEquals(f.state.puts,0);assertEquals(f.state.completes,1);
  const same=await f.run(f.request());assertEquals(same.status,409);assertEquals(f.state.submits,1);assertEquals(f.state.costs.length,1);
 }finally{f.close();}
});
Deno.test("actual handler policy-disabled boundary prevents every new paid supplier dispatch",async()=>{
 const f=await fixture();try{f.state.qualityEnabled=false;const response=await f.run(f.request());assertEquals(response.status,503);assertEquals(f.state.submits,0);assertEquals(f.state.holds,0);assertEquals(f.state.puts,0);assertEquals(f.state.costs.length,0);assertEquals(f.state.refunds,1);}finally{f.close();}
});
Deno.test("actual same-key pending row resolves before legacy fallback even after lost pointer ACK",async()=>{
 const f=await fixture();try{f.state.qualityPending=true;f.state.completeLost=true;
  const first=await f.run(f.request());assertEquals(first.status,409);assertEquals((await first.json()).code,"photo_quality_pending");assertEquals(f.state.saved,null);
  const replay=await f.run(f.request());assertEquals(replay.status,409);const body=await replay.json();assertEquals(body.code,"photo_quality_pending");assertEquals(body.image_b64,undefined);assertEquals(body.asset_key,undefined);
  assertEquals(f.state.submits,1);assertEquals(f.state.holds,1);assertEquals(f.state.puts,1);assertEquals(f.state.gets,0,"No legacy/private GET may rescue unchecked evidence");
  const changed=await f.run(f.request({label:"different body"}));assertEquals(changed.status,409);assertEquals((await changed.json()).code,"conflict");assertEquals(f.state.submits,1);
 }finally{f.close();}
});
Deno.test("actual GET status cannot consume quota or dispatch generation",async()=>{
 const f=await fixture();try{f.state.qualityPending=true;assertEquals((await f.run(f.request())).status,409);
  const before={charges:f.state.charges,holds:f.state.holds,submits:f.state.submits,puts:f.state.puts};
  const status=await f.run(new Request("https://example.invalid/ai-photo/status?check_id=synthetic-check",{headers:{"X-Org":org}}));assertEquals(status.status,409);assertEquals((await status.json()).code,"photo_quality_pending");assertEquals({charges:f.state.charges,holds:f.state.holds,submits:f.state.submits,puts:f.state.puts},before);
 }finally{f.close();}
});
Deno.test("actual handler plus real quarantine pipeline retains9MB/9MB exact evidence and only returns pending",async()=>{
 const f=await fixture(false,null,true);try{
  const source=sizedOutputJPEG(9_000_000,1536,2048);f.state.output=sizedOutputJPEG(9_000_000);
  const request=()=>f.request({image_b64:source}),response=await f.run(request());assertEquals(response.status,409);const body=await response.json();assertEquals(body.code,"photo_quality_pending");assertEquals(body.image_b64,undefined);assertEquals(body.asset_key,undefined);
  assertEquals(f.state.puts,2);assertEquals(f.state.objects.size,2);assertEquals(f.state.journal,null,"No ordinary delivery registration before accept");assertEquals(f.state.object.byteLength,9_000_000);assertEquals(f.state.quality.evidence.input.bytes,9_000_000);assertEquals(f.state.saved.kind,"photo_quality");assertEquals(f.state.saved.evidence_id,f.state.quality.evidence.id);
  assertEquals((await f.run(request())).status,409);assertEquals(f.state.submits,1);assertEquals(f.state.costs.length,1);assertEquals(f.state.puts,2);assertEquals(f.state.gets,0);
 }finally{f.close();}
});
Deno.test("actual handler plus quarantine records paid output overflow without fake full-output retention",async()=>{
 const f=await fixture(false,null,true);try{f.state.output=sizedOutputJPEG(25*1024*1024+1);const response=await f.run(f.request());assertEquals(response.status,409);const body=await response.json();assertEquals(body.code,"photo_quality_hold");assertEquals(body.failure_phase,"photo_output_size");assertEquals(body.provider_cost_incurred,true);assertEquals(body.retained_output,false);assertEquals(f.state.puts,1,"Only the prepared source is retained");assertEquals(f.state.quality.evidence.output,null);assertEquals(f.state.costs.length,1);assertEquals(f.state.refunds,0);assertEquals((await f.run(f.request())).status,409);assertEquals(f.state.submits,1);}finally{f.close();}
});
Deno.test("actual handler wire overflow holds uncertain supplier liability and feature charge without paid fallback",async()=>{
 const f=await fixture(false,null,true);try{
  f.state.qa=true;f.state.router=true;f.state.finishStates=[];
  f.state.routes=[0,1].map(i=>({route_id:"authorized-"+i,provider:"gemini",model:"gemini-3.1-flash-image",task:"photo.twilight",unit:"image",unit_cents:16.7584}));
  Object.defineProperty(f.state,"primaryFail",{get:()=>{throw new ProviderResponseLimitError("gemini",200,35_052_536);}});
  const response=await f.run(f.request());assertEquals(response.status,409);const body=await response.json();assertEquals(body.code,"photo_quality_hold");assertEquals(body.failure_phase,"photo_provider_wire_size");assertEquals(body.provider_cost_incurred,"possible");assertEquals(body.retained_output,false);
  assertEquals(f.state.submits,1);assertEquals(f.state.holds,1);assertEquals(f.state.finishStates,["uncertain"]);assertEquals(f.state.refunds,0);assertEquals(f.state.puts,1,"Only the prepared source was retained");assertEquals((await f.run(f.request())).status,409);assertEquals(f.state.submits,1);
 }finally{f.close();}
});
Deno.test("explicit check-existing handler route never enters generation quota or supplier admission",async()=>{
 const f=await fixture();try{
  const response=await f.run(new Request("https://example.invalid/ai-photo/check-existing",{method:"POST",headers:{"content-type":"application/json","X-Org":org},body:JSON.stringify({generation_request_key:"old-paid-key",generation_request_body:{listing_id:listing}})}));
  assertEquals(response.status,409);assertEquals((await response.json()).code,"photo_quality_pending");assertEquals(f.state.calibrationCalls,1);assertEquals(f.state.started,false);assertEquals(f.state.charges,0);assertEquals(f.state.holds,0);assertEquals(f.state.submits,0);assertEquals(f.state.puts,0);
 }finally{f.close();}
});

Deno.test("check-existing wire admits the full9MB legacy source but refuses oversized JSON before calibration",async()=>{
 const f=await fixture();try{
  const source=sizedOutputJPEG(9_000_000,1536,2048),body={generation_request_key:"old-paid-key",generation_request_body:{image_b64:source,mime:"image/jpeg",listing_id:listing}};
  const send=(data:unknown)=>f.run(new Request("https://example.invalid/ai-photo/check-existing",{method:"POST",headers:{"content-type":"application/json","X-Org":org},body:JSON.stringify(data)}));
  assertEquals((await send(body)).status,409);assertEquals(f.state.calibrationCalls,1);
  assertEquals((await send({...body,padding:"x".repeat(100_001)})).status,413);assertEquals(f.state.calibrationCalls,1);
  assertEquals(f.state.submits,0);assertEquals(f.state.holds,0);assertEquals(f.state.charges,0);
 }finally{f.close();}
});

Deno.test("legacy masked route retains exact combined9MB source/mask and refuses one byte above without dispatch",async()=>{
 const f=await fixture(false,null,true);try{
  f.state.qa=true;f.state.router=true;f.state.routes=[{route_id:"existing-mask-route",provider:"fal",model:"fal-ai/flux-pro/v1/fill",task:"photo.declutter",unit:"image",unit_cents:5,capabilities:["mask"],max_latency_s:60,min_plan:"free",privacy_tier:"retained_30d",enabled:true}];
  const mask=outputJPEG(1536,2048),source=sizedOutputJPEG(9_000_000-atob(mask).length,1536,2048);f.state.output=outputJPEG(1536,2048);
  const request=()=>f.request({image_b64:source,edit:"declutter",mask_b64:mask,mask_mime:"image/jpeg"});
  assertEquals((await f.run(request())).status,409);assertEquals(f.state.submits,1);assertEquals(f.state.costs.length,1);assertEquals(f.state.quality.evidence.input.bytes,9_000_000-atob(mask).length);
  assertEquals(f.state.inputs[0].image_b64,source);assertEquals(f.state.inputs[0].mask_url,"data:image/jpeg;base64,"+mask);assertEquals(f.state.inputs[0].extra.photo_quality_4k,undefined);
  assertEquals((await f.run(request())).status,409);assertEquals(f.state.submits,1);
 }finally{f.close();}
 const over=await fixture();try{
  const mask=outputJPEG(1536,2048),response=await over.run(over.request({edit:"declutter",image_b64:sizedOutputJPEG(9_000_001-atob(mask).length,1536,2048),mask_b64:mask,mask_mime:"image/jpeg"}));
  assertEquals(response.status,413);assertEquals(over.state.submits,0);assertEquals(over.state.holds,0);assertEquals(over.state.puts,0);assertEquals(over.state.costs.length,0);
 }finally{over.close();}
});

Deno.test("fresh work without exact retained-operation protocol refuses before quota/hold/provider, compiled bypass fails",async()=>{
 const oracle=async(remove:boolean)=>{const f=await fixture(false,remove?"protocol":null);try{
  const original=f.request(),headers=new Headers(original.headers);headers.delete("x-rendprop-photo-quality-protocol");
  const response=await f.run(new Request(original,{headers}));assertEquals(response.status,409);const body=await response.json();assertEquals(body.recovery_protocol_required,true);assertEquals(body.no_provider_dispatch,true);
  assertEquals(f.state.charges,0);assertEquals(f.state.holds,0);assertEquals(f.state.submits,0);assertEquals(f.state.puts,0);assertEquals(f.state.costs.length,0);
 }finally{f.close();}};
 await oracle(false);await assertRejects(()=>oracle(true),AssertionError);
});
Deno.test("historical exact saved photo replays without new protocol while pending replay cannot start a new judge",async()=>{
 const withoutProtocol=(req:Request)=>{const headers=new Headers(req.headers);headers.delete("x-rendprop-photo-quality-protocol");return new Request(req,{headers});};
 const f=await fixture();try{
  assertEquals((await f.run(f.request())).status,200);const saved=f.state.quality.saved,pointer={kind:"photo_output",bucket:"renders",key:saved.key,mime:saved.mime,metadata:{edit:"twilight",disclosure:"Historical saved disclosure",provenance:{id:"synthetic-provenance",recorded:true}}};f.state.saved=pointer;f.state.quality=null;
  const before={charges:f.state.charges,holds:f.state.holds,submits:f.state.submits,puts:f.state.puts};
  const restored=await f.run(withoutProtocol(f.request()));assertEquals(restored.status,200);assertEquals((await restored.json()).image_b64,OUTPUT);assertEquals({charges:f.state.charges,holds:f.state.holds,submits:f.state.submits,puts:f.state.puts},before);
 }finally{f.close();}
 const pending=await fixture();try{
  pending.state.qualityPending=true;assertEquals((await pending.run(pending.request())).status,409);const waits=pending.state.waits;
  const result=await pending.run(withoutProtocol(pending.request()));assertEquals(result.status,409);assertEquals((await result.json()).code,"photo_quality_pending");assertEquals(pending.state.waits,waits);assertEquals(pending.state.submits,1);assertEquals(pending.state.holds,1);
 }finally{pending.close();}
});
Deno.test("actual handler budgets slow4K generation and returns durable pending without restarting the paid operation",async()=>{
 const f=await fixture(false,null,true),clock=Date.now;let now=clock();const entered=now;
 try{
  Date.now=()=>now;f.state.qualityPending=true;f.state.afterSubmit=()=>{now+=90_000;};
  const response=await f.run(f.request({edit:"stage",style:"modern"}));assertEquals(response.status,409);
  const body=await response.json();assertEquals(body.code,"photo_quality_pending");assertEquals(f.state.submits,1);assertEquals(f.state.puts,2);assertEquals(f.state.completes,1);
  assertEquals(f.state.providerDeadline,entered+120_000);assertEquals(f.state.waitDeadline,entered+130_000);assertEquals(f.state.waitRemaining,40_000);
  assertEquals(Object.keys(f.state.inputs[0].extra).some(key=>/deadline|timeout|signal/.test(key)),false,"Request-local timing must not change paid input identity");
  assertEquals(f.state.quality.evidence.state,"evidence_ready");assertEquals(f.state.quality.check.state,"pending");assert(f.state.quality.evidence.output_etag);
  const restored=await f.run(f.request({edit:"stage",style:"modern"}));assertEquals(restored.status,409);assertEquals(f.state.submits,1);assertEquals(f.state.charges,1);assertEquals(f.state.puts,2);
 }finally{Date.now=clock;f.close();}
});

Deno.test("actual quarantine retains exact25MiB candidate with9MB source and replays pending without supplier or ordinarydelivery",async()=>{
 const f=await fixture(false,null,true);try{
  const source=sizedOutputJPEG(9_000_000,1536,2048);f.state.output=sizedOutputJPEG(25*1024*1024);
  const request=()=>f.request({image_b64:source}),response=await f.run(request());assertEquals(response.status,409);assertEquals((await response.json()).code,"photo_quality_pending");
  assertEquals(f.state.puts,2);assertEquals(f.state.object.byteLength,25*1024*1024);assertEquals(f.state.quality.evidence.output.bytes,25*1024*1024);assertEquals(f.state.quality.evidence.input.bytes,9_000_000);assertEquals(f.state.journal,null);
  assertEquals((await f.run(request())).status,409);assertEquals(f.state.submits,1);assertEquals(f.state.costs.length,1);assertEquals(f.state.gets,0);assertEquals(f.state.puts,2);
 }finally{f.close();}
});

function proGrantForHandler(task="photo.stage"){
 const now=Date.now();return{enabled:true,actor_id:actor,org_id:org,listing_id:listing,changed_by:actor,provider:"gemini",model:"gemini-3-pro-image",image_size:"4K",task,consent:"owner-authorized-gemini-pro-4k-media-qa-2026-10-15",created_at:new Date(now-1000).toISOString(),expires_at:new Date(now+3600_000).toISOString()};
}
Deno.test("actual owner Pro4K entrypoint preserves paid private evidence and same-key replay with exact model quote",async()=>{
 for(const edit of ["stage","declutter"]){const f=await fixture(false,null,true);try{
  f.state.proGrant=proGrantForHandler("photo."+edit);f.state.output=outputJPEG(3584,4800);
  const request=()=>f.request({edit,...(edit==="stage"?{style:"contemporary"}:{})});
  assertEquals((await f.run(request())).status,409);assertEquals(f.state.submits,1);assertEquals(f.state.holds,1);assertEquals(f.state.costs.length,1);
  assertEquals(f.state.costs[0].step.model,"gemini-3-pro-image");assertEquals(f.state.costs[0].meta.image_size,"4K");assertEquals(f.state.costs[0].meta.cost_basis,"complete_input_4096_text_2000_pro_image_bound");
  const allowance=f.state.inputs[0].extra.photo_input_allowance,price=(allowance*2+4096*12+2000*120)/10000;
  assertEquals(f.state.costs[0].step.unit_cents,price);assert(Number(f.state.holdArguments[0].p_hold_cents)>=price);
  assertEquals(f.state.quality.evidence.generation_model,"gemini-3-pro-image");assertEquals(f.state.quality.evidence.output.width,3584);assertEquals(f.state.quality.evidence.output.height,4800);
  assert(f.state.providerDeadline>Date.now());assertEquals((await f.run(request())).status,409);assertEquals(f.state.submits,1);assertEquals(f.state.holds,1);assertEquals(f.state.costs.length,1,"Pending replay cannot regenerate or reprice");
 }finally{f.close();}}
});
Deno.test("actual owner Pro4K reauthorizes its exact selector before money/provider dispatch",async()=>{
 const f=await fixture(false,null,true);try{f.state.proGrant=proGrantForHandler();f.state.proExpiresAfterLookup=true;
  const response=await f.run(f.request({edit:"stage",style:"contemporary"}));assert(response.status!==200);assertEquals(f.state.submits,0);assertEquals(f.state.holds,0);assertEquals(f.state.costs.length,0);
 }finally{f.close();}
});
Deno.test("actual owner Pro4K rejects Flash-only extreme output after recording paid liability",async()=>{
 const f=await fixture(false,null,true);try{f.state.proGrant=proGrantForHandler();f.state.output=outputJPEG(2048,8192);
  const response=await f.run(f.request({edit:"stage",style:"contemporary"}));assert(response.status!==200);assertEquals(f.state.submits,1);assertEquals(f.state.costs.length,1);assertEquals(f.state.quality.evidence.state,"hold");assertEquals(f.state.quality.evidence.failure.phase,"photo_output_geometry");
 }finally{f.close();}
});
Deno.test("ordinary nonadmin Starter Stage/Declutter use isolated Pro4K without sponsor or owner grant and preserve replay",async()=>{
 for(const edit of["stage","declutter"]){const f=await fixture(false,null,true);try{
  f.state.plan="starter";f.state.qa=false;f.state.proAdmin=false;f.state.normalProfile={enabled:true,profile:"gemini-pro-4k-preservation-v1",tasks:["photo.stage","photo.declutter"]};f.state.output=outputJPEG(3584,4800);
  const request=()=>f.request({edit,...(edit==="stage"?{style:"contemporary"}:{})});
  const response=await f.run(request());assertEquals(response.status,409);assertEquals((await response.json()).code,"photo_quality_pending");
  assertEquals(f.state.submits,1);assertEquals(f.state.holds,1);assertEquals(f.state.costs[0].step.task,"photo."+edit);assertEquals(f.state.costs[0].step.route_id,"normal-quality-route");assertEquals(f.state.costs[0].step.model,"gemini-3-pro-image");
  assertEquals(f.state.costs[0].meta.owner_quality_comparison,false);assertEquals(f.state.costs[0].meta.quality_profile,"gemini-pro-4k-preservation-v1");assertEquals(f.state.costs[0].meta.cost_basis,"complete_input_4096_text_2000_pro_image_bound");
  assertEquals(f.state.inputs[0].extra.owner_photo_pro_4k,undefined);assertEquals(f.state.inputs[0].extra.photo_preservation_profile,"gemini-pro-4k-preservation-v1");
  assertEquals(f.state.holdArguments[0].p_tariff_version,"photo-preservation-pro4k-standard-20261015");assertEquals(f.state.quality.evidence.generation_model,"gemini-3-pro-image");
  f.state.normalProfile={enabled:false};assertEquals((await f.run(request())).status,409);assertEquals(f.state.submits,1,"A pending old operation cannot switch model or regenerate after policy changes");
 }finally{f.close();}}
});
Deno.test("ordinary disabled profile leaves normal Flash path; enabled missing or withdrawn Pro never sends cheap fallback",async()=>{
 for(const kind of["off","missing","withdrawn"]){const f=await fixture(false,null,true);try{
  f.state.normalProfile={enabled:kind!=="off",profile:"gemini-pro-4k-preservation-v1",tasks:["photo.stage","photo.declutter"]};if(kind==="missing")f.state.normalRows=[];if(kind==="withdrawn")f.state.normalWithdraw=true;
  const response=await f.run(f.request({edit:"stage",style:"modern"}));assert(response.status!==200);
  assertEquals(f.state.submits,kind==="off"?1:0);assertEquals(f.state.costs.length,kind==="off"?1:0);
  if(kind==="off")assertEquals(f.state.costs[0].step.model,"gemini-3.1-flash-image");
  else assertEquals(f.state.refunds,1,"Pre-dispatch refusal returns the feature meter; it does not buy a fallback");
 }finally{f.close();}}
});
Deno.test("ordinary Pro geometry guard retains paid Flash-only extreme privately and refuses delivery",async()=>{
 const f=await fixture(false,null,true);try{f.state.normalProfile={enabled:true,profile:"gemini-pro-4k-preservation-v1",tasks:["photo.stage","photo.declutter"]};f.state.output=outputJPEG(2048,8192);
  assertEquals((await f.run(f.request({edit:"stage",style:"modern"}))).status,409);assertEquals(f.state.submits,1);assertEquals(f.state.costs.length,1);assertEquals(f.state.quality.evidence.failure.phase,"photo_output_geometry");assertEquals(f.state.quality.evidence.state,"hold");
 }finally{f.close();}
});
Deno.test("customer body cannot select Pro, forge profile authority or change unrelated photo edits",async()=>{
 for(const edit of["stage","twilight"]){const f=await fixture(false,null,true);try{
  f.state.normalProfile={enabled:edit==="twilight",profile:"gemini-pro-4k-preservation-v1",tasks:["photo.stage","photo.declutter"]};
  await f.run(f.request({edit,...(edit==="stage"?{style:"modern"}:{}),model:"gemini-3-pro-image",quality_profile:"gemini-pro-4k-preservation-v1",extra:{owner_photo_pro_4k:true,photo_preservation_profile:"gemini-pro-4k-preservation-v1"}}));
  assertEquals(f.state.submits,1);assertEquals(f.state.costs[0].step.model,"gemini-3.1-flash-image");assertEquals(f.state.inputs[0].extra.photo_preservation_profile,undefined);assertEquals(f.state.inputs[0].extra.owner_photo_pro_4k,undefined);
 }finally{f.close();}}
});
Deno.test("ordinary Stage-only policy does not activate Declutter Pro",async()=>{
 for(const edit of["stage","declutter"]){const f=await fixture(false,null,true);try{
  f.state.normalProfile={enabled:true,profile:"gemini-pro-4k-preservation-v1",tasks:["photo.stage"]};f.state.output=outputJPEG(3584,4800);
  await f.run(f.request({edit,...(edit==="stage"?{style:"modern"}:{})}));assertEquals(f.state.submits,1);assertEquals(f.state.costs[0].step.model,edit==="stage"?"gemini-3-pro-image":"gemini-3.1-flash-image");
 }finally{f.close();}}
});
async function removalPromptHandlerOracle(remove=false){
 const f=await fixture(false,remove?"declutter_prompt":null,true);try{
  f.state.proGrant=proGrantForHandler("photo.declutter");f.state.output=outputJPEG(3584,4800);
  const req=f.request({edit:"declutter"}),body=await req.clone().json();assertEquals((await f.run(req)).status,409);assertEquals(f.state.submits,1);assertEquals(f.state.holds,1);
  const actual=f.state.inputs[0],prompt=actual.prompt;assertEquals(actual.task,"photo.declutter");assertEquals(actual.image_b64,body.image_b64);
  for(const text of["REMOVE-ONLY cleanup","DO NOT ADD ANY OBJECT","Never replace, restyle or relocate existing furniture","If an object's purpose or whether it is clutter is uncertain, leave it unchanged","Fill only the small image areas directly occupied","including the photographer","CRITICAL — MATERIAL FACTS","No crop, zoom, wider view"]){assert(prompt.includes(text),text);}
  assertEquals(f.state.quality.evidence.edit,"declutter");assertEquals(f.state.costs[0].meta.edit,"declutter");assert(f.state.holdArguments[0].p_input_sha256===await f.inputHash(actual));
  assertEquals((await f.run(f.request({edit:"declutter"}))).status,409);assertEquals(f.state.submits,1,"A pending result does not rerun under the new instructions");
 }finally{f.close();}
}
Deno.test("actual real-estate Declutter dispatches the new remove-only prompt with exact source/funding and no replay generation",()=>removalPromptHandlerOracle());
Deno.test("compiled old broad Declutter prompt cannot pass actual new request/source oracle",async()=>{await assertRejects(()=>removalPromptHandlerOracle(true),AssertionError);});
