import {assert} from "../_shared/http.ts";
import {photoUUID,statusPhotoQuality,type PhotoAdmin,type PhotoQualityEnvelope} from "../ai-photo/photo-qc-store.ts";
import {continuePhotoQuality} from "../ai-photo/photo-qc-runner.ts";
/** The caller may choose only a retained check UUID. Actor/library/instructions
 * come from fresh service-scoped evidence, never from the private HTTP body. */
export async function judgeSavedPhoto(admin:PhotoAdmin,checkId:string,request:Request,run=continuePhotoQuality):Promise<PhotoQualityEnvelope>{
 assert(photoUUID(checkId),400,"Use the retained photo check identity.");
 const {data:check,error:checkError}=await admin.from("photo_quality_checks").select("evidence_id").eq("id",checkId).maybeSingle();
 assert(!checkError&&check&&photoUUID(check.evidence_id),404,"This saved photo check is unavailable.","not_found");
 const {data:e,error}=await admin.from("photo_edit_evidence").select("actor_id,library_org_id").eq("id",check.evidence_id).maybeSingle();
 assert(!error&&e&&photoUUID(e.actor_id)&&photoUUID(e.library_org_id),404,"This saved photo evidence is unavailable.","not_found");
 const row=await statusPhotoQuality(admin,e.actor_id,checkId,e.library_org_id);
 return await run(admin,row,{actor:e.actor_id,selected:e.library_org_id,request,deadline:Date.now()+45_000});
}
