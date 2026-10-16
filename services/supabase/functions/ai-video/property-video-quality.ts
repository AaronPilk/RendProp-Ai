import {assert,throwRpc} from "../_shared/http.ts";
import {adminClient} from "../_shared/supabase.ts";
import {resolveRoute,type RouteContext,type RouteStep} from "../_shared/router.ts";

export const PROPERTY_VIDEO_QUALITY_PROFILE="fal-kling3-4k-v1" as const;
export const PROPERTY_VIDEO_STEADY_PROFILE="fal-kling3-4k-steady-v2" as const;
export const PROPERTY_VIDEO_QUALITY_TASK="video.property_reel_clip";
export const PROPERTY_VIDEO_QUALITY_MODEL="fal-ai/kling-video/v3/4k/image-to-video";
export type PropertyVideoQualityProfile="legacy"|typeof PROPERTY_VIDEO_QUALITY_PROFILE|typeof PROPERTY_VIDEO_STEADY_PROFILE;
export const isPropertyVideoQualityProfile=(value:PropertyVideoQualityProfile)=>value!=="legacy";
/** Only saved server job metadata enters this parser, never the public body. */
export function propertyVideoQualityProfile(value:unknown):PropertyVideoQualityProfile{
 if(value===undefined||value===null)return "legacy";
 assert(value==="legacy"||value===PROPERTY_VIDEO_QUALITY_PROFILE||value===PROPERTY_VIDEO_STEADY_PROFILE,409,"The saved video quality profile is unavailable.");
 return value;
}
export async function currentPropertyVideoQualityProfile():Promise<PropertyVideoQualityProfile>{
 const{data,error}=await adminClient().rpc("property_video_quality_profile");
 if(error)throwRpc(error.message);
 return propertyVideoQualityProfile(data);
}
/** Dedicated ordinary task keeps legacy direct video routing byte-independent.
 * The existing resolver still applies enabled/plan/retirement/privacy/health.
 * Adapter task is canonical; model/route/price identity is not changed. */
export async function propertyVideoQualitySteps(plan:string,resolver:(task:string,context:RouteContext)=>Promise<RouteStep[]>=resolveRoute):Promise<RouteStep[]>{
 const rows=await resolver(PROPERTY_VIDEO_QUALITY_TASK,{plan,needs:["i2v","1080p","5s","native4k","preserve_photo"],carries_customer_media:true});
 assert(rows.length===1,503,"High-quality property video is temporarily unavailable. No lower-quality generation was sent.");
 const s=rows[0];
 assert(s.task===PROPERTY_VIDEO_QUALITY_TASK&&s.provider==="fal"&&s.model===PROPERTY_VIDEO_QUALITY_MODEL&&s.enabled===true&&s.unit==="second"&&s.unit_cents===42&&["no_retention","retained_30d"].includes(s.privacy_tier),503,"The saved property-video route or price is unavailable. No generation was sent.");
 return[{...s,task:"video.reel_clip"}];
}
