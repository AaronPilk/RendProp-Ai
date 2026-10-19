// Explicit QC-only review of an actor-owned, already-paid historical photo.
// Nothing writes/replaces its old serving pointer, provenance or media selection.
import {assert,HttpError,CANONICAL_ID_KEYS,canonicalIds} from "../_shared/http.ts";
import {inputHash} from "../_shared/funded-serving.ts";
import {requireContentWrite,listingLibraryScope} from "../_shared/library-access.ts";
import {decodeBase64Bytes} from "../_shared/base64-bytes.ts";
import {R2_BUCKET_RENDERS,headObject} from "../_shared/r2.ts";
import {presignGet} from "../_shared/providers/common.ts";
import {photoResultKeys,boundedPhotoResultBytes,type PhotoResultIdentity,type PhotoResultPointer} from "./photo-result.ts";
import {validatePhotoInput,inspectPhotoOutputBytes} from "./input-policy.ts";
import {photoUUID,photoQualityRpc,photoEnvelope,photoQualityScope,photoBytesHash,savePhotoJudgeContext,retainPhotoPreparedSource,retainPhotoCandidate,failPhotoQuality,photoEvidenceIO,type PhotoEvidenceIO,type PhotoQualityEnvelope,type PhotoAdmin} from "./photo-qc-store.ts";

export interface HistoricalPhotoBody {image_b64:string;mime:string;edit:string;listing_id:string;original_asset_id:string;style?:string;prompt?:string;[key:string]:unknown}
export interface PhotoCalibrationBody {generation_request_key:string;generation_request_body:HistoricalPhotoBody}
export function calibrationRequest(raw:unknown):PhotoCalibrationBody{
 const data=raw as PhotoCalibrationBody,old=data?.generation_request_body;
 assert(data&&typeof data==="object"&&!Array.isArray(data)&&typeof data.generation_request_key==="string"&&/^[A-Za-z0-9:_-]{8,128}$/.test(data.generation_request_key)
  &&old&&typeof old==="object"&&!Array.isArray(old),400,"Choose an existing saved photo request to check.");
 const body=canonicalIds({...old},CANONICAL_ID_KEYS);
 const mime=String(body.mime??"image/jpeg").split(";")[0].trim().toLowerCase(),edit=String(body.edit??"twilight").trim().toLowerCase();
 assert(typeof body.image_b64==="string"&&(body.mime===undefined||typeof body.mime==="string")&&["image/jpeg","image/png","image/webp"].includes(mime)&&photoUUID(body.listing_id)&&photoUUID(body.original_asset_id)
  &&["stage","declutter","sky","twilight","lawn","custom"].includes(edit)&&(!body.style||typeof body.style==="string"&&body.style.length<=40)&&(!body.prompt||typeof body.prompt==="string"&&body.prompt.length<=600)
  &&body.mask_b64===undefined&&body.staging_reference_b64===undefined,400,"This check requires the exact original photo request and its owned original asset.");
 const source=validatePhotoInput(body.image_b64,mime);
 assert(source.bytes<=9_000_000,413,"The saved editing copy exceeds the 9 MB review bound. Keep the original unchanged.","payload_too_large");
 return{generation_request_key:data.generation_request_key,generation_request_body:body};
}
export interface PhotoCalibrationIO {
 read(key:string,mime:string,bytes:number):Promise<Uint8Array<ArrayBuffer>>;
 evidence:PhotoEvidenceIO;
}
const actual:PhotoCalibrationIO={evidence:photoEvidenceIO,read:async(key,mime,bytes)=>{
 const head=await headObject(R2_BUCKET_RENDERS,key,AbortSignal.timeout(10_000));
 assert(head.exists&&head.bytes===bytes&&head.contentType?.split(";")[0]===mime,503,"The saved historical photo changed.");
 const response=await fetch(await presignGet(R2_BUCKET_RENDERS,key,60),{method:"GET",credentials:"omit",redirect:"error",signal:AbortSignal.timeout(30_000)});
 assert((response.headers.get("content-type")??"").split(";")[0]===mime,503,"The saved historical photo format changed.");
 return await boundedPhotoResultBytes(response,bytes);
}};
async function one(query:any,message:string):Promise<any>{const {data,error}=await query.maybeSingle();assert(!error&&data,404,message,"not_found");return data;}
export async function beginPhotoCalibration(admin:PhotoAdmin,args:{actor:string;org:string;selected:string|null;body:PhotoCalibrationBody},io=actual):Promise<PhotoQualityEnvelope>{
 const old=args.body.generation_request_body,key=args.body.generation_request_key,identity:PhotoResultIdentity={actorId:args.actor,orgId:args.org,requestKey:key,listingId:old.listing_id};
 const edit=String(old.edit??"twilight").trim().toLowerCase(),style=edit==="stage"?String(old.style??"modern").toLowerCase():null,mime=String(old.mime??"image/jpeg").split(";")[0].trim().toLowerCase();
 const scope=await listingLibraryScope(admin,args.actor,old.listing_id,true);
 assert(scope.org_id===args.org&&!!args.selected&&(args.selected===scope.org_id||args.selected===scope.library_org_id),404,"This historical photo is unavailable in the selected library.","not_found");
 await requireContentWrite(admin,args.actor,args.org,old.listing_id);
 const operation=await one(admin.from("serving_operations").select("state,input_sha256,operation").eq("actor_id",args.actor).eq("org_id",args.org).eq("request_key",key),"This saved photo operation is unavailable.");
 const requestSHA=await inputHash(old);
 assert(operation.state==="completed"&&operation.input_sha256===requestSHA&&typeof operation.operation==="string"&&operation.operation.endsWith("/ai-photo"),409,"Use the exact request body for the existing completed photo edit.","conflict");
 const saved=await one(admin.from("serving_operation_results").select("result").eq("actor_id",args.actor).eq("org_id",args.org).eq("request_key",key),"This historical photo has no saved result pointer.");
 const pointer=saved.result as PhotoResultPointer,keys=await photoResultKeys(identity);
 assert(pointer?.kind==="photo_output"&&pointer.bucket==="renders"&&typeof pointer.mime==="string"&&keys[pointer.mime]===pointer.key,409,"Only an exact owned historical photo result can be checked.","conflict");
 const owned=await one(admin.from("private_ai_outputs").select("org_id,user_id,listing_id,bucket,storage_key,bytes").eq("org_id",args.org).eq("user_id",args.actor).eq("listing_id",old.listing_id).eq("bucket","renders").eq("storage_key",pointer.key),"The saved photo is unavailable in this actor's library.");
 const length=Number(owned.bytes);
 assert(owned.org_id===args.org&&owned.user_id===args.actor&&owned.listing_id===old.listing_id&&owned.bucket==="renders"&&owned.storage_key===pointer.key&&Number.isSafeInteger(length)&&length>0&&length<=9_000_000,409,"The historical photo receipt could not be verified.","conflict");
 const {data:costs,error:costError}=await admin.from("cost_ledger").select("provider,model,total_cents,meta").eq("org_id",args.org).eq("feature","photo_edit").eq("meta->>request_key",key).limit(3);
 assert(!costError&&Array.isArray(costs)&&costs.length===1&&Number(costs[0].total_cents)>0,409,"The original photo payment receipt is not confirmed.","conflict");
 const cost=costs[0],stage=cost.meta?.stage;
 assert(typeof stage==="string"&&/^[a-z0-9:._-]{1,80}$/.test(stage)&&typeof cost.provider==="string"&&typeof cost.model==="string",409,"The original photo route receipt is incomplete.","conflict");
 await one(admin.from("serving_cost_reservations").select("id").eq("actor_id",args.actor).eq("org_id",args.org).eq("request_key",key).eq("stage",stage).eq("provider",cost.provider).eq("model",cost.model).eq("state","succeeded"),"The original paid photo attempt could not be confirmed.");
 const source=validatePhotoInput(old.image_b64,mime),inputBytes=decodeBase64Bytes(old.image_b64),candidate=inspectPhotoOutputBytes(await io.read(pointer.key,pointer.mime,length),pointer.mime);
 assert(candidate.bytes===length,503,"The saved historical photo size changed.");
 await requireContentWrite(admin,args.actor,args.org,old.listing_id);
 const {data:_,...output}=candidate;
 let row=photoEnvelope(await photoQualityRpc(admin,"photo_quality_calibration_begin",{p_actor:args.actor,p_org:args.org,p_key:key,p_request_sha256:requestSHA,p_listing:old.listing_id,p_edit:edit,p_style:style,p_original_asset:old.original_asset_id,p_input:{...source,sha256:await photoBytesHash(inputBytes)},p_output:{...output,sha256:await photoBytesHash(candidate.data),generation_stage:stage,provider:cost.provider,model:cost.model,source_key:pointer.key}}),args.actor,identity);
 assert(row.evidence.purpose==="calibration",503,"The saved check did not confirm its calibration-only purpose.");
 await photoQualityScope(admin,row,args.actor,args.selected);
 if(row.created!==true)return row;
 try{
  row=await savePhotoJudgeContext(admin,row,old.prompt);
  row=await retainPhotoPreparedSource(admin,row,inputBytes,io.evidence);
  return await retainPhotoCandidate(admin,row,candidate,{stage,provider:cost.provider,model:cost.model},io.evidence);
 }catch(error){try{await failPhotoQuality(admin,row,"calibration_evidence_persistence",{no_generation_dispatch:true,message:"The historical photo check could not confirm its exact private evidence. The original completed result is unchanged."});}catch{/* The calibration row remains fenced. */}throw error;}
}
