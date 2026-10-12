// Explicit temporary 2K owner comparison. No public route or allowance change.
import { adminClient } from "../_shared/supabase.ts";
import type { ChainStep } from "../_shared/router.ts";
import type { GenerateInput } from "../_shared/providers/types.ts";
import { HttpError } from "../_shared/http.ts";
import { validatePhotoInput } from "./input-policy.ts";
export const OWNER_PHOTO_QA_KEY = "owner_photo_quality_qa";
export const OWNER_PHOTO_QA_CONSENT = "owner-authorized-2k-media-qa-2026-10-12";
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const canonical=(value:unknown)=>typeof value==="string"&&UUID.test(value)?value.toLowerCase():null;
export async function ownerQaPhotoStep(args:{actorId:string;orgId:string;listingId?:string|null;task:string},db=adminClient(),now=new Date()):Promise<ChainStep|null>{
 const actor=canonical(args.actorId),org=canonical(args.orgId),listing=canonical(args.listingId);
 if(!actor||!org||!listing||!/^photo\.(custom|stage|declutter|sky|lawn|twilight)$/.test(args.task))return null;
 const row=await db.from("app_config").select("value").eq("key",OWNER_PHOTO_QA_KEY).maybeSingle();
 if(row.error||!row.data?.value||typeof row.data.value!=="object"||Array.isArray(row.data.value))return null;
 const grant=row.data.value as Record<string,unknown>;
 if(grant.enabled!==true||canonical(grant.actor_id)!==actor||canonical(grant.org_id)!==org||canonical(grant.listing_id)!==listing||
  canonical(grant.changed_by)!==actor||grant.consent!==OWNER_PHOTO_QA_CONSENT||grant.provider!=="gemini"||grant.model!=="gemini-3.1-flash-image"||grant.image_size!=="2K")return null;
 const start=typeof grant.created_at==="string"?Date.parse(grant.created_at):NaN,end=typeof grant.expires_at==="string"?Date.parse(grant.expires_at):NaN;
 if(![start,end,now.getTime()].every(Number.isFinite)||start>now.getTime()||end<=now.getTime()||end<=start||end-start>24*3600*1000)return null;
 const profile=await db.from("profiles").select("is_admin").eq("id",actor).maybeSingle();
 if(profile.error||profile.data?.is_admin!==true)return null;
 return {route_id:"owner-qa-gemini-flash-2k-20261012",task:args.task,position:1,provider:"gemini",model:"gemini-3.1-flash-image",unit:"image",unit_cents:11.7184,
  capabilities:["prompt-edit","fidelity","2K"],max_latency_s:120,min_plan:"free",same_model_as:null,privacy_tier:"retained_30d",enabled:true,retire_after:null,
  params:{image_size:"2K"}};
}
/** The comparison's 8192 input-token allowance is bounded prospectively.
 * Native prepared sources are <=2048px; reserve a conservative 4096 tokens per
 * image, and one token per UTF-8 text byte including the furniture wrapper.
 * Oversized inputs are refused, never silently reduced or sent to a 1K route. */
export function prepareOwnerQaPhotoInput(input:GenerateInput):GenerateInput{
 const images:[unknown,string][]=[[input.image_b64,String(input.extra?.image_mime??"image/jpeg")]];
 if(input.mask_url)throw new HttpError(400,"The 2K comparison uses unmasked photo edits.","validation");
 if(input.extra?.staging_reference_b64!==undefined)images.push([input.extra.staging_reference_b64,String(input.extra.staging_reference_mime)]);
 let tokenBound=new TextEncoder().encode(input.prompt??"").byteLength;
 for(const [b64,mime]of images){const image=validatePhotoInput(b64,mime);if(Math.max(image.width,image.height)>2048)throw new HttpError(413,"Use a source no larger than 2048 pixels for this 2K comparison.","payload_too_large");tokenBound+=4096;}
 if(images.length>1)tokenBound+=512;
 if(tokenBound>8192)throw new HttpError(413,"This 2K comparison's source and instructions exceed its verified input bound. Try a shorter brief without a furniture reference.","payload_too_large");
 return {...input,extra:{...input.extra,owner_photo_2k:true,owner_photo_input_bound:tokenBound}};
}

/** Never report a 1K-sized supplier response as the requested 2K comparison. */
export function assertOwnerQaPhotoOutput(b64:string,mime:string):void{
 const image=validatePhotoInput(b64,mime);
 if(image.width*image.height<3_800_000||image.width*image.height>4_800_000)throw new HttpError(502,"The image provider returned a size outside the requested 2K resolution. The comparison was not delivered as a verified 2K image.","upstream");
}
