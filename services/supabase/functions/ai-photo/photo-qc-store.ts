// Prospective photos are quarantined until the SQL quality journal atomically
// promotes their exact bytes. This module never generates or judges an image.
import {assert,HttpError,throwRpc} from "../_shared/http.ts";
import {listingLibraryScope,requireContentWrite} from "../_shared/library-access.ts";
import {R2_BUCKET_RENDERS,inspectPhotoEvidence,writePhotoEvidence} from "../_shared/r2.ts";
import {bytesToB64,presignGet} from "../_shared/providers/common.ts";
import {decodeBase64Bytes} from "../_shared/base64-bytes.ts";
import {assertHostingAvailable} from "../_shared/hosting-retention.ts";
import {admitMediaRead} from "../_shared/media-delivery-admission.ts";
import {disclosureFallback} from "../_shared/provenance.ts";
import {boundedPhotoResultBytes,photoResultKeys,type PhotoResultIdentity} from "./photo-result.ts";
import {validatePhotoInput,type DecodedStillImage} from "./input-policy.ts";
import {photoJsonResponse} from "./photo-response.ts";
import {PHOTO_QC_POLICY} from "./photo-qc-verdict.ts";

export type PhotoAdmin = any;
export interface PhotoEvidenceFile {bucket:"renders";key:string;sha256:string;bytes:number;mime:string;width:number;height:number}
export interface PhotoEvidence {
 id:string;actor_id:string;org_id:string;library_org_id:string;listing_id:string|null;request_key:string;request_sha256:string;
 policy:string;edit:string;style:string|null;input:PhotoEvidenceFile;output:PhotoEvidenceFile|null;input_etag:string|null;output_etag:string|null;
 state:string;provenance_id:string|null;generation_stage:string|null;generation_provider:string|null;generation_model:string|null;
 failure?:{phase?:string;facts?:Record<string,unknown>}|null;
}
export interface PhotoQualityCheck {id:string;evidence_id:string;policy:string;state:string;lease_token:string|null;lease_until:string|null;judge_started_at:string|null;derivatives:PhotoDerivative[]|null;derivative_manifest_sha256:string|null}
export interface PhotoDerivative extends PhotoEvidenceFile {role:"source"|"candidate";region:"whole"|"tl"|"tr"|"bl"|"br";etag:string}
export interface PhotoQualityEnvelope {evidence:PhotoEvidence;check:PhotoQualityCheck;can_continue:boolean;created?:boolean}
export const photoUUID=(v:unknown):v is string=>typeof v==="string"&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(v);
export const photoSHA=(v:unknown):v is string=>typeof v==="string"&&/^[a-f0-9]{64}$/.test(v);
export async function photoBytesHash(bytes:Uint8Array<ArrayBuffer>):Promise<string>{return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",bytes)),b=>b.toString(16).padStart(2,"0")).join("");}
export async function photoQualityRpc(admin:PhotoAdmin,name:string,args:Record<string,unknown>):Promise<any>{
 let result;try{result=await admin.rpc(name,args);}catch{throw new HttpError(503,"The saved photo review could not be checked safely.","upstream");}
 if(result.error)throwRpc(result.error.message??"Photo review is unavailable");
 return result.data;
}
export function photoEnvelope(raw:any,actor:string,identity?:PhotoResultIdentity):PhotoQualityEnvelope{
 const e=raw?.evidence,q=raw?.check;
 assert(e&&q&&photoUUID(e.id)&&photoUUID(q.id)&&q.evidence_id===e.id&&e.actor_id===actor&&photoUUID(e.org_id)&&photoUUID(e.library_org_id)
  &&(e.listing_id===null||photoUUID(e.listing_id))&&e.policy===PHOTO_QC_POLICY&&q.policy===e.policy&&typeof e.request_key==="string"&&photoSHA(e.request_sha256)
  &&["pending","input_ready","evidence_ready","checking","accept","refuse","hold"].includes(e.state)&&["pending","preparing","derivative_ready","checking","accept","refuse","hold"].includes(q.state)
  &&(!identity||(identity.actorId===e.actor_id&&identity.orgId===e.org_id&&identity.listingId===e.listing_id&&identity.requestKey===e.request_key)),503,"The saved photo review identity could not be verified.","upstream");
 return raw as PhotoQualityEnvelope;
}
/** A fresh selected-library check is mandatory even though the RPC checks the
 * actor again. A valid check ID from another selected library is a404. */
export async function photoQualityScope(admin:PhotoAdmin,row:PhotoQualityEnvelope,actor:string,selected:string|null):Promise<void>{
 const e=row.evidence;let actual=e.org_id,library=e.org_id;
 try{if(e.listing_id){const scope=await listingLibraryScope(admin,actor,e.listing_id,true);actual=scope.org_id;library=scope.library_org_id;}
  else await requireContentWrite(admin,actor,e.org_id,null);
 }catch(error){if(error instanceof HttpError&&[400,403,404].includes(error.status))throw new HttpError(404,"This saved photo check is unavailable in the selected library.","not_found");throw error;}
 assert(e.actor_id===actor&&actual===e.org_id&&library===e.library_org_id&&!!selected&&(selected===actual||selected===library),404,"This saved photo check is unavailable in the selected library.","not_found");
}
export async function lookupPhotoQuality(admin:PhotoAdmin,identity:PhotoResultIdentity):Promise<PhotoQualityEnvelope|null>{
 const raw=await photoQualityRpc(admin,"photo_quality_lookup",{p_actor:identity.actorId,p_org:identity.orgId,p_key:identity.requestKey});
 return raw===null?null:photoEnvelope(raw,identity.actorId,identity);
}
export async function statusPhotoQuality(admin:PhotoAdmin,actor:string,checkId:string,selected:string|null):Promise<PhotoQualityEnvelope>{
 assert(photoUUID(checkId),400,"Choose a valid saved photo check.");
 const row=photoEnvelope(await photoQualityRpc(admin,"photo_quality_status",{p_actor:actor,p_check:checkId}),actor);
 await photoQualityScope(admin,row,actor,selected);return row;
}
export interface PhotoEvidenceIO {
 write(key:string,bytes:Uint8Array<ArrayBuffer>,mime:string,sha:string):Promise<void>;
 inspect(key:string):Promise<{bytes:number;mime:string;sha256:string;etag:string}|null>;
 read(key:string,expected:number):Promise<Uint8Array<ArrayBuffer>>;
}
export const photoEvidenceIO:PhotoEvidenceIO={write:writePhotoEvidence,inspect:inspectPhotoEvidence,read:async(key,expected)=>{
 const response=await fetch(await presignGet(R2_BUCKET_RENDERS,key,60),{method:"GET",credentials:"omit",redirect:"error",signal:AbortSignal.timeout(30_000)});
 return await boundedPhotoResultBytes(response,expected);
}};
export function assertPhotoEvidenceFile(e:PhotoEvidence,file:PhotoEvidenceFile,kind:"input"|"output"):void{
 const ext:{[mime:string]:string}={"image/jpeg":"jpg","image/png":"png","image/webp":"webp"};
 assert(file&&file.bucket==="renders"&&photoSHA(file.sha256)&&Number.isSafeInteger(file.bytes)&&file.bytes>0&&file.bytes<=(kind==="input"?1_000_000:9_000_000)
  &&ext[file.mime]&&file.key===`ai-router/${e.org_id}/photo-evidence/${e.actor_id}/${e.id}/${kind==="input"?"input":"candidate"}.${ext[file.mime]}`,503,"The retained photo identity is inconsistent.","upstream");
}
async function persistEvidence(admin:PhotoAdmin,row:PhotoQualityEnvelope,kind:"input"|"output",bytes:Uint8Array<ArrayBuffer>,io:PhotoEvidenceIO):Promise<PhotoQualityEnvelope>{
 const e=row.evidence,file=kind==="input"?e.input:e.output;assert(file,503,"The retained photo receipt is missing.");assertPhotoEvidenceFile(e,file,kind);
 assert(bytes.byteLength===file.bytes&&await photoBytesHash(bytes)===file.sha256,503,"The retained photo bytes changed.");
 await requireContentWrite(admin,e.actor_id,e.org_id,e.listing_id);
 await io.write(file.key,bytes,file.mime,file.sha256);
 const head=await io.inspect(file.key);
 assert(head&&head.bytes===file.bytes&&head.mime===file.mime&&head.sha256===file.sha256&&head.etag.length>0&&head.etag.length<=200,503,"The exact private photo bytes could not be confirmed.","upstream");
 return photoEnvelope(await photoQualityRpc(admin,"photo_quality_evidence_receipt",{p_actor:e.actor_id,p_evidence:e.id,p_kind:kind,p_etag:head.etag}),e.actor_id);
}
export async function beginPhotoQuality(admin:PhotoAdmin,identity:PhotoResultIdentity,args:{edit:string;style?:string;originalAsset?:string;imageB64:string;mime:string},io=photoEvidenceIO):Promise<PhotoQualityEnvelope>{
 const image=validatePhotoInput(args.imageB64,args.mime);
 if(image.bytes>1_000_000)throw new HttpError(413,"Keep the original photo. Prepare an editing copy up to 1 MB before trying this edit. No edit was sent.","payload_too_large",{no_provider_dispatch:true,failure_phase:"prepared_photo_size"});
 const bytes=decodeBase64Bytes(args.imageB64),input={...image,sha256:await photoBytesHash(bytes)};
 const row=photoEnvelope(await photoQualityRpc(admin,"photo_quality_begin",{p_actor:identity.actorId,p_org:identity.orgId,p_key:identity.requestKey,p_listing:identity.listingId,p_edit:args.edit,p_style:args.style??null,p_original_asset:args.originalAsset??null,p_input:input,p_legacy_keys:Object.values(await photoResultKeys(identity))}),identity.actorId,identity);
 // A concurrent/replayed begin may never become another generation owner.
 if(row.created!==true)return row;
 try{return{...await persistEvidence(admin,row,"input",bytes,io),created:true};}
 catch(error){try{await failPhotoQuality(admin,row,"prepared_source_persistence",{provider_cost_incurred:false,no_provider_dispatch:true,message:"The editing copy could not be retained; the original photo is unchanged."});}catch{/* The existing evidence row still prevents another generator. */}throw error;}
}
export async function retainPhotoCandidate(admin:PhotoAdmin,row:PhotoQualityEnvelope,image:DecodedStillImage,args:{stage:string;provider:string;model:string},io=photoEvidenceIO):Promise<PhotoQualityEnvelope>{
 const {data:bytes,...facts}=image,output={...facts,sha256:await photoBytesHash(bytes),generation_stage:args.stage,provider:args.provider,model:args.model};
 const e=await photoQualityRpc(admin,"photo_quality_evidence_reserve",{p_actor:row.evidence.actor_id,p_evidence:row.evidence.id,p_output:output});
 return await persistEvidence(admin,photoEnvelope({...row,evidence:e},e.actor_id),"output",bytes,io);
}
export async function failPhotoQuality(admin:PhotoAdmin,row:PhotoQualityEnvelope,phase:string,facts:Record<string,unknown>):Promise<PhotoQualityEnvelope>{
 const e=row.evidence;return photoEnvelope(await photoQualityRpc(admin,"photo_quality_failure",{p_actor:e.actor_id,p_evidence:e.id,p_phase:phase,p_facts:facts}),e.actor_id);
}
export function photoQualityIdentity(row:PhotoQualityEnvelope,selected:string):Record<string,unknown>{const e=row.evidence;return{check_id:row.check.id,evidence_id:e.id,org_id:e.org_id,selected_library_org_id:selected,listing_id:e.listing_id,generation_request_key:e.request_key};}
export function throwPhotoQualityState(row:PhotoQualityEnvelope,selected:string):never{
 const state=row.check.state,failure=row.evidence.failure,details={...photoQualityIdentity(row,selected),photo_quality:{policy:row.evidence.policy,check_id:row.check.id,state},retry_existing_job:true,...(failure?.phase?{failure_phase:failure.phase}:{}),...(failure?.facts&&typeof failure.facts.provider_cost_incurred==="boolean"?{provider_cost_incurred:failure.facts.provider_cost_incurred,retained_output:failure.facts.retained_output===true}:{})};
 if(state==="refuse")throw new HttpError(422,"This edit changed fixed property features or failed the photo quality review. The original is unchanged; the generated edit remains private.","photo_quality_refused",details);
 if(state==="hold"||state==="checking"&&row.check.judge_started_at!==null)throw new HttpError(409,failure?.phase==="photo_output_size"?"The generated photo exceeded the safe 9 MB output limit and could not be saved. This generation was already processed. The original is unchanged; no additional edit was started.":"The saved photo operation needs review before its edit can be used. No new edit or repeat quality check was started.","photo_quality_hold",details);
 throw new HttpError(409,"The edit is saved privately while its photo quality review is pending. Check this saved edit again; no new generation is needed.","photo_quality_pending",details);
}
/** Called only after fresh SQL/current-library authority and atomic acceptance.
 * The exact accepted object is re-hashed; a cached/signed URL is never authority. */
export async function photoQualityResponse(admin:PhotoAdmin,row:PhotoQualityEnvelope,actor:string,selected:string|null,extra:Record<string,unknown>={},io=photoEvidenceIO):Promise<Response>{
 await photoQualityScope(admin,row,actor,selected);assert(selected,404,"Select the saved edit's library.","not_found");
 if(row.check.state!=="accept"||row.evidence.state!=="accept")throwPhotoQualityState(row,selected);
 const e=row.evidence,file=e.output;assert(file&&e.provenance_id&&e.output_etag,503,"The accepted photo receipt is incomplete.");assertPhotoEvidenceFile(e,file,"output");
 const {data,error}=await admin.from("private_ai_outputs").select("org_id,user_id,listing_id,bucket,storage_key,bytes").eq("org_id",e.org_id).eq("user_id",actor).eq("bucket","renders").eq("storage_key",file.key).maybeSingle();
 assert(!error&&data&&data.org_id===e.org_id&&data.user_id===actor&&data.listing_id===e.listing_id&&data.bucket==="renders"&&data.storage_key===file.key&&Number(data.bytes)===file.bytes,503,"The accepted photo delivery receipt could not be verified.");
 await assertHostingAvailable(admin,e.org_id);await admitMediaRead(admin,e.org_id,file.bytes,false);
 const head=await io.inspect(file.key);assert(head&&head.bytes===file.bytes&&head.mime===file.mime&&head.sha256===file.sha256&&head.etag===e.output_etag,503,"The accepted photo changed.");
 const bytes=await io.read(file.key,file.bytes);assert(await photoBytesHash(bytes)===file.sha256,503,"The accepted photo bytes changed.");
 const fresh=await statusPhotoQuality(admin,actor,row.check.id,selected);
 assert(fresh.check.state==="accept"&&fresh.evidence.state==="accept"&&fresh.evidence.output?.sha256===file.sha256&&fresh.evidence.output?.key===file.key,409,"The photo quality review changed. Check its status again.","conflict");
 const kind=e.edit==="stage"?"virtual_stage":e.edit==="declutter"?"declutter":"photo_edit";
 return photoJsonResponse({...extra,...photoQualityIdentity(fresh,selected),edit:e.edit,...(e.style?{style:e.style}:{}),disclosure:disclosureFallback(kind,e.edit),provenance:{id:e.provenance_id,recorded:true},photo_quality:{policy:e.policy,check_id:fresh.check.id,state:"accept"}},bytesToB64(bytes),file.mime,file.key);
}
