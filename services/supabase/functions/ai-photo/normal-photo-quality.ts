// Ordinary preservation-sensitive edits use an isolated, opt-in route task.
// No owner grant/admin/sponsorship is needed; normal funding and QC still apply.
import {adminClient} from "../_shared/supabase.ts";
import {resolveRoute,paramsOf,type RouteStep,type RouteContext} from "../_shared/router.ts";
import {HttpError} from "../_shared/http.ts";
import {mediaAttemptQuote} from "../_shared/funded-serving.ts";
import {NORMAL_PHOTO_PRO4K_PROFILE,normalPhotoPro4KInputAllowance} from "../_shared/photo-image-quality.ts";
import {preparePhoto4KInput} from "./photo-quality.ts";
import type {GenerateInput} from "../_shared/providers/types.ts";

export const NORMAL_PHOTO_QUALITY_KEY="photo_preservation_quality";
const TASKS={"photo.stage":"photo.quality_stage","photo.declutter":"photo.quality_declutter"} as const;
export interface NormalPhotoQualityProfile {profile:typeof NORMAL_PHOTO_PRO4K_PROFILE;task:keyof typeof TASKS;routeTask:typeof TASKS[keyof typeof TASKS]}
const unavailable=()=>new HttpError(503,"Preservation-quality photo editing is temporarily unavailable. No alternative model was sent.","upstream");
export async function normalPhotoQualityProfile(task:string,masked:boolean,db=adminClient()):Promise<NormalPhotoQualityProfile|null>{
 if(masked||!Object.hasOwn(TASKS,task))return null;
 const result=await db.from("app_config").select("value").eq("key",NORMAL_PHOTO_QUALITY_KEY).maybeSingle();
 if(result.error)throw unavailable();
 const value=result.data?.value;
 if(value===null||value===undefined||value.enabled===false)return null;
 if(!value||typeof value!=="object"||Array.isArray(value)||value.enabled!==true||value.profile!==NORMAL_PHOTO_PRO4K_PROFILE)throw unavailable();
 if(!Array.isArray(value.tasks)||value.tasks.length<1||value.tasks.length>2||new Set(value.tasks).size!==value.tasks.length||!value.tasks.every((t:unknown)=>typeof t==="string"&&Object.hasOwn(TASKS,t)))throw unavailable();
 if(!value.tasks.includes(task))return null;
 return{profile:NORMAL_PHOTO_PRO4K_PROFILE,task:task as keyof typeof TASKS,routeTask:TASKS[task as keyof typeof TASKS]};
}
export async function normalPhotoQualityRoutes(profile:NormalPhotoQualityProfile,context:RouteContext,resolve=resolveRoute):Promise<RouteStep[]>{
 if(profile.profile!==NORMAL_PHOTO_PRO4K_PROFILE||!Object.hasOwn(TASKS,profile.task)||profile.routeTask!==TASKS[profile.task])throw unavailable();
 const rows=await resolve(profile.routeTask,{...context,needs:[...new Set([...(context.needs??[]),"4K"])],carries_customer_media:true});
 const step=rows.find(row=>row.task===profile.routeTask&&row.provider==="gemini"&&row.model==="gemini-3-pro-image"&&paramsOf(row)?.image_size==="4K");
 if(!step)throw unavailable();
 // Keep route identity/operator eligibility, canonicalize only the actual edit
 // task used by the adapter, immutable paid input and feature-meter ledger.
 return[{...step,task:profile.task}];
}
export function prepareNormalPhotoPro4KInput(input:GenerateInput,profile:NormalPhotoQualityProfile):GenerateInput{
 if(input.task!==profile.task||!Object.hasOwn(TASKS,input.task)||profile.profile!==NORMAL_PHOTO_PRO4K_PROFILE||profile.routeTask!==TASKS[profile.task])throw unavailable();
 const prepared=preparePhoto4KInput(input);
 return{...prepared,extra:{...prepared.extra,photo_preservation_profile:NORMAL_PHOTO_PRO4K_PROFILE}};
}
export function priceNormalPhotoQualityRoute(steps:RouteStep[],input:GenerateInput):RouteStep[]{
 if(steps.length!==1||steps[0].task!==input.task||steps[0].provider!=="gemini"||steps[0].model!=="gemini-3-pro-image"||normalPhotoPro4KInputAllowance(input)===null)throw unavailable();
 const quote=mediaAttemptQuote(steps[0],input);if(!quote)throw unavailable();
 return[{...steps[0],unit:"image",unit_cents:quote.cents}];
}
