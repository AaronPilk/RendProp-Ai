import {assert,HttpError,throwRpc} from "../_shared/http.ts";
import {adminClient} from "../_shared/supabase.ts";
import {paramsOf,resolveRoute,type ChainStep,type RouteContext,type RouteStep} from "../_shared/router.ts";
import {ProviderError} from "../_shared/providers/common.ts";
import type {GenerateInput} from "../_shared/providers/types.ts";
import type {PropertySourceLocation} from "../_shared/property-video.ts";
import {KIE_PROPERTY_IDENTITY,KIE_PROPERTY_PROFILE,kiePropertyIdentityConsistent,sameJsonValue,sameKiePropertyIdentity} from "../_shared/property-video-kie.ts";

export const PROPERTY_VIDEO_QUALITY_PROFILE="fal-kling3-4k-v1" as const;
export const PROPERTY_VIDEO_STEADY_PROFILE="fal-kling3-4k-steady-v2" as const;
export const PROPERTY_VIDEO_KIE_PROFILE=KIE_PROPERTY_PROFILE;
export const PROPERTY_VIDEO_QUALITY_TASK="video.property_reel_clip";
export const PROPERTY_VIDEO_QUALITY_MODEL="fal-ai/kling-video/v3/4k/image-to-video";
export type PropertyVideoQualityProfile="legacy"|typeof PROPERTY_VIDEO_QUALITY_PROFILE|typeof PROPERTY_VIDEO_STEADY_PROFILE|typeof PROPERTY_VIDEO_KIE_PROFILE;
export const isPropertyVideoQualityProfile=(value:PropertyVideoQualityProfile)=>value!=="legacy";
export const isKiePropertyVideoProfile=(value:unknown):value is typeof PROPERTY_VIDEO_KIE_PROFILE=>value===PROPERTY_VIDEO_KIE_PROFILE;
/** Both steady profiles share the steady-property-v1 prompt and the native
 * 24 fps CFR composition; every other saved value keeps the 30 fps path. */
export const STEADY_PROPERTY_COMPOSITION_PROFILE="steady-v2-cfr24" as const;
export const isSteadyPropertyVideoProfile=(value:unknown):value is typeof PROPERTY_VIDEO_STEADY_PROFILE|typeof PROPERTY_VIDEO_KIE_PROFILE=>value===PROPERTY_VIDEO_STEADY_PROFILE||value===PROPERTY_VIDEO_KIE_PROFILE;
export const propertyVideoCompositionProfile=(value:unknown):typeof STEADY_PROPERTY_COMPOSITION_PROFILE|undefined=>isSteadyPropertyVideoProfile(value)?STEADY_PROPERTY_COMPOSITION_PROFILE:undefined;
/** The frozen Kie identity is internally consistent and names this module's
 * native-24 composition. Checked on every Kie path, never at module load (a
 * throw there would take down every function importing this module); a
 * broken identity refuses the Kie profile before any read, hold or POST. */
export const kiePropertyProfileReady=():boolean=>kiePropertyIdentityConsistent()&&KIE_PROPERTY_IDENTITY.composition_profile===STEADY_PROPERTY_COMPOSITION_PROFILE;
const KIE_PROFILE_UNAVAILABLE="The native-4K video profile is unavailable. No generation was sent.";
/** Only saved server job metadata enters this parser, never the public body. */
export function propertyVideoQualityProfile(value:unknown):PropertyVideoQualityProfile{
 if(value===undefined||value===null)return "legacy";
 assert(value==="legacy"||value===PROPERTY_VIDEO_QUALITY_PROFILE||value===PROPERTY_VIDEO_STEADY_PROFILE||value===PROPERTY_VIDEO_KIE_PROFILE,409,"The saved video quality profile is unavailable.");
 return value;
}
export async function currentPropertyVideoQualityProfile():Promise<PropertyVideoQualityProfile>{
 const{data,error}=await adminClient().rpc("property_video_quality_profile");
 if(error)throwRpc(error.message);
 return propertyVideoQualityProfile(data);
}

export type PinnedRouteReader=(id:string)=>Promise<unknown>;
const PINNED_ROUTE_COLUMNS="id, task, position, provider, model, unit, unit_cents, capabilities, max_latency_s, min_plan, same_model_as, privacy_tier, enabled, retire_after, note, params";
/** One ai_routes row by primary key: no router flag, plan policy, health
 * reordering or customer-media privacy filter is consulted. */
export async function readPinnedRoute(id:string):Promise<unknown>{
 const{data,error}=await adminClient().from("ai_routes").select(PINNED_ROUTE_COLUMNS).eq("id",id).maybeSingle();
 if(error)throw new Error("The pinned route could not be read.");
 return data;
}
const catalogCents=(value:unknown)=>typeof value==="number"?value:typeof value==="string"&&/^\d+(?:\.\d+)?$/.test(value)?Number(value):Number.NaN;
/** The pinned Kie row as its single adapter step, or null on ANY difference
 * from the frozen identity (same fields and retirement rule as SQL admission). */
export function kiePropertyRouteStep(row:unknown,now:Date=new Date()):ChainStep|null{
 if(!kiePropertyProfileReady()||!row||typeof row!=="object"||Array.isArray(row))return null;
 const r=row as Record<string,unknown>,k=KIE_PROPERTY_IDENTITY,p=r.params;
 const exactParams=!!p&&typeof p==="object"&&!Array.isArray(p)&&Object.keys(p).sort().join(",")==="kie_mode,sound"
  &&(p as Record<string,unknown>).kie_mode===k.mode&&(p as Record<string,unknown>).sound===k.sound;
 const retire=r.retire_after,live=retire===null||typeof retire==="string"&&/^\d{4}-\d{2}-\d{2}$/.test(retire)&&retire>now.toISOString().slice(0,10);
 if(r.id!==k.route_id||r.task!==k.task||r.provider!==k.provider||r.model!==k.model||r.unit!==k.unit||catalogCents(r.unit_cents)!==k.unit_cents
  ||!exactParams||r.enabled!==true||r.privacy_tier!==k.privacy_tier||!live)return null;
 return{route_id:k.route_id,task:"video.reel_clip",position:Number(r.position??0),provider:k.provider,model:k.model,unit:k.unit,unit_cents:k.unit_cents,
  capabilities:Array.isArray(r.capabilities)?r.capabilities.map(String):[],max_latency_s:Number(r.max_latency_s??120),min_plan:String(r.min_plan??"free"),
  same_model_as:typeof r.same_model_as==="string"?r.same_model_as:null,privacy_tier:"trains_by_default",enabled:true,retire_after:typeof retire==="string"?retire:null,
  params:{kie_mode:k.mode,sound:k.sound}};
}
/** Dedicated ordinary task keeps legacy direct video routing byte-independent.
 * The existing resolver still applies enabled/plan/retirement/privacy/health.
 * Adapter task is canonical; model/route/price identity is not changed.
 * The Kie profile never uses that resolver: its privacy rule drops
 * trains_by_default for customer media, and the explicit owner acknowledgement
 * recorded in app_config is that decision. Its pinned row is read by id and
 * must equal the frozen identity. No FAL step is returned for Kie and no Kie
 * step for a FAL profile. */
export async function propertyVideoQualitySteps(plan:string,resolver:(task:string,context:RouteContext)=>Promise<RouteStep[]>=resolveRoute,profile?:PropertyVideoQualityProfile,reader:PinnedRouteReader=readPinnedRoute):Promise<RouteStep[]>{
 if(profile===PROPERTY_VIDEO_KIE_PROFILE){
  assert(kiePropertyProfileReady(),503,KIE_PROFILE_UNAVAILABLE);
  let row:unknown;
  try{row=await reader(KIE_PROPERTY_IDENTITY.route_id);}
  catch{throw new HttpError(503,"High-quality property video is temporarily unavailable. No lower-quality generation was sent.","upstream");}
  const step=kiePropertyRouteStep(row);
  assert(step,503,"The saved property-video route or price is unavailable. No generation was sent.");
  return[step];
 }
 assert(profile===undefined||profile===PROPERTY_VIDEO_QUALITY_PROFILE||profile===PROPERTY_VIDEO_STEADY_PROFILE,503,"The saved property-video route or price is unavailable. No generation was sent.");
 const rows=await resolver(PROPERTY_VIDEO_QUALITY_TASK,{plan,needs:["i2v","1080p","5s","native4k","preserve_photo"],carries_customer_media:true});
 assert(rows.length===1,503,"High-quality property video is temporarily unavailable. No lower-quality generation was sent.");
 const s=rows[0];
 assert(s.task===PROPERTY_VIDEO_QUALITY_TASK&&s.provider==="fal"&&s.model===PROPERTY_VIDEO_QUALITY_MODEL&&s.enabled===true&&s.unit==="second"&&s.unit_cents===42&&["no_retention","retained_30d"].includes(s.privacy_tier),503,"The saved property-video route or price is unavailable. No generation was sent.");
 return[{...s,task:"video.reel_clip"}];
}

/** The one Kie recipe extra, shared by the quote and the reserved dispatch input. */
export function kiePropertyExtra(aspect:"16:9"|"9:16"){
 return{kie_mode:KIE_PROPERTY_IDENTITY.mode,sound:KIE_PROPERTY_IDENTITY.sound,property_video_target_aspect:aspect,property_video_quality_profile:PROPERTY_VIDEO_KIE_PROFILE};
}
/** Additive quote evidence: the identity's exact catalog price (fractional
 * cents kept, four decimals) and its bounded paid attempts per source. */
export function kiePropertyPricedBasis(count:number){
 const k=KIE_PROPERTY_IDENTITY,cents=(value:number)=>Math.round(value*1e4)/1e4;
 return{provider:k.provider,model:k.model,mode:k.mode,unit:k.unit,unit_cents:k.unit_cents,attempt_cents:k.attempt_cents,
  credits_per_second:k.credits_per_second,usd_per_credit:k.usd_per_credit,price_source:k.price_source,price_checked:k.price_checked,
  bonus_credits_excluded:k.bonus_credits_excluded,max_paid_attempts_per_source:k.max_paid_attempts_per_source,
  expected_generation_cents:cents(k.attempt_cents*count),worst_case_generation_cents:cents(k.attempt_cents*k.max_paid_attempts_per_source*count)};
}
/** Before any allowance, hold or provider read: the job's frozen identity must
 * be the canonical Kie identity, and the worker request the one closed recipe. */
export function assertKiePropertyDispatchScope(scope:{qualityIdentity?:unknown;targetAspect?:string}|undefined,request:{aspect:unknown;seconds:number;framing:unknown;presetVersion:unknown;customPrompt:unknown;assetId:unknown;sourceAssetId:unknown}):"16:9"|"9:16"{
 assert(kiePropertyProfileReady(),503,KIE_PROFILE_UNAVAILABLE);
 assert(scope&&sameKiePropertyIdentity(scope.qualityIdentity),409,"The saved native-4K video identity is unavailable. No generation was sent.");
 const aspect=request.aspect;
 assert((aspect==="16:9"||aspect==="9:16")&&scope.targetAspect===aspect&&request.seconds===KIE_PROPERTY_IDENTITY.seconds&&request.framing==="preserve_photo"
  &&request.presetVersion===1&&!request.customPrompt&&!request.assetId&&typeof request.sourceAssetId==="string",409,"The saved native-4K clip request is incomplete. No generation was sent.");
 return aspect;
}
/** Every column a pinned step carries, as plain JSON for an exact comparison. */
const pinnedStepFacts=(s:RouteStep)=>{const c=s as Partial<ChainStep>;return{route_id:s.route_id,task:s.task,position:c.position??null,provider:s.provider,model:s.model,unit:s.unit,unit_cents:s.unit_cents,
 capabilities:s.capabilities,max_latency_s:s.max_latency_s,min_plan:s.min_plan,same_model_as:s.same_model_as,privacy_tier:s.privacy_tier,enabled:s.enabled,retire_after:c.retire_after??null,params:paramsOf(s)};};
/** The pinned row re-read by id after the hold, immediately before dispatch,
 * must still be the frozen identity (same rule as the pre-hold read) AND equal
 * the reserved step in every column; the reserved step must be the identity's
 * and the job's frozen identity must be the canonical one. Nested JSON (route
 * params) compares independently of jsonb key order. This is the only guard on
 * that re-read: any difference is a definite pre-dispatch refusal. */
export function samePinnedKieDispatch(freshRow:unknown,reserved:RouteStep,frozenIdentity:unknown,now:Date=new Date()):boolean{
 const k=KIE_PROPERTY_IDENTITY,fresh=kiePropertyRouteStep(freshRow,now);
 return fresh!==null&&sameKiePropertyIdentity(frozenIdentity)&&reserved.route_id===k.route_id&&reserved.task==="video.reel_clip"&&reserved.provider===k.provider
  &&reserved.model===k.model&&reserved.unit===k.unit&&reserved.unit_cents===k.unit_cents&&reserved.privacy_tier===k.privacy_tier&&reserved.enabled===true
  &&sameJsonValue(paramsOf(reserved),{kie_mode:k.mode,sound:k.sound})&&sameJsonValue(pinnedStepFacts(fresh),pinnedStepFacts(reserved));
}
const KIE_INPUT_KEYS="aspect,extra,framing,image_url,prompt,resolution,seconds,task";
const KIE_EXTRA_KEYS="kie_mode,property_video_quality_profile,property_video_target_aspect,sound";
/** True only for the exact reserved Kie GenerateInput shape (no extra fields). */
export function kiePropertyInputExact(input:GenerateInput):boolean{
 const e=input.extra,aspect=input.aspect;
 return kiePropertyProfileReady()&&Object.keys(input).sort().join(",")===KIE_INPUT_KEYS&&input.task==="video.reel_clip"&&typeof input.prompt==="string"&&input.prompt.length>0
  &&typeof input.image_url==="string"&&input.seconds===KIE_PROPERTY_IDENTITY.seconds&&input.resolution==="1080p"&&input.framing==="preserve_photo"
  &&(aspect==="16:9"||aspect==="9:16")&&!!e&&Object.keys(e).sort().join(",")===KIE_EXTRA_KEYS&&e.kie_mode===KIE_PROPERTY_IDENTITY.mode
  &&e.sound===KIE_PROPERTY_IDENTITY.sound&&e.property_video_target_aspect===aspect&&e.property_video_quality_profile===PROPERTY_VIDEO_KIE_PROFILE;
}
/** Vendor-only source capability, bounded by the same two-hour processing
 * window as the owner QA source; never returned to the app. */
export const KIE_PROPERTY_SOURCE_URL_SECONDS=7200;
type SourceHead={exists:boolean;bytes:number|null;etag:string|null;contentType:string|null};
const mime=(value:string|null|undefined)=>value?.split(";")[0].trim().toLowerCase();
/** Kie fetches URLs only (inline staging fails closed). The reserved recipe is
 * sent with its inline photo replaced by a presigned GET of the exact verified
 * owned object, re-checked immediately before signing. Any gap is a definite
 * pre-dispatch refusal: no POST, the priced hold is released. */
export async function kiePropertyProviderInput(input:GenerateInput,location:PropertySourceLocation|null|undefined,deps:{head:(bucket:"uploads"|"renders",key:string)=>Promise<SourceHead>;sign:(bucket:"uploads"|"renders",key:string,seconds:number)=>Promise<string>}):Promise<GenerateInput>{
 const refuse=()=>new ProviderError(KIE_PROPERTY_IDENTITY.provider,"validation","The owned native-4K property source could not be prepared. No generation was sent.",0,true);
 if(!location||!kiePropertyInputExact(input))throw refuse();
 let url:string;
 try{
  const head=await deps.head(location.bucket,location.storage_key);
  if(!head.exists||head.etag!==location.etag||head.bytes!==location.bytes||mime(head.contentType)!==mime(location.content_type))throw new Error("changed");
  url=await deps.sign(location.bucket,location.storage_key,KIE_PROPERTY_SOURCE_URL_SECONDS);
 }catch{throw refuse();}
 if(typeof url!=="string"||!/^https:\/\/[^\s]+$/.test(url))throw refuse();
 return{...input,image_url:url};
}
