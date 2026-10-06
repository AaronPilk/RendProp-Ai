import { assert, HttpError } from "./http.ts";
import type { AppleTransaction } from "./applejws.ts";
const products = ["com.rendprop.app.starter.monthly","com.rendprop.app.starter.annual","com.rendprop.app.pro.monthly","com.rendprop.app.pro.annual","com.rendprop.app.team.monthly"];
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
export type HeldTrialPurchase = { reservation_id:string; actor_id:string; app_account_token:string; org_id:string; product_id:string; held_at:string; trial_offer:{enabled:true;walkthroughs:1;photo_edits:5;published_listings:1;max_days:number;max_video_seconds:number;upload_budget_bytes:number} };
const unavailable = "Your trial funding reservation could not be verified. Please retry before purchasing.";
function held(value:unknown,actor:string,org:string,product?:string):HeldTrialPurchase {
 const h=value as HeldTrialPurchase|null, o=h?.trial_offer;
 assert(h && uuid.test(h.reservation_id) && h.actor_id===actor && h.app_account_token===actor && h.org_id===org && products.includes(h.product_id) && (!product||h.product_id===product) && typeof h.held_at==="string" && Number.isFinite(Date.parse(h.held_at)) && o?.enabled===true && o.walkthroughs===1 && o.photo_edits===5 && o.published_listings===1 && o.max_days===7 && Number.isSafeInteger(o.max_video_seconds)&&o.max_video_seconds>=1&&o.max_video_seconds<=90 && Number.isSafeInteger(o.upload_budget_bytes)&&o.upload_budget_bytes>0&&o.upload_budget_bytes<=1073741824,503,unavailable);
 return {reservation_id:h.reservation_id,actor_id:actor,app_account_token:actor,org_id:org,product_id:h.product_id,held_at:h.held_at,trial_offer:{enabled:true,walkthroughs:1,photo_edits:5,published_listings:1,max_days:o.max_days,max_video_seconds:o.max_video_seconds,upload_budget_bytes:o.upload_budget_bytes}};
}
export async function heldTrialPurchase(admin:any,actor:string,org:string):Promise<HeldTrialPurchase|null> {
 const {data,error}=await admin.rpc("subscription_trial_held_offer",{p_actor:actor,p_org:org});
 assert(!error,503,unavailable);return data===null?null:held(data,actor,org);
}
export async function prepareTrialPurchase(admin:any,actor:string,org:string,body:unknown):Promise<HeldTrialPurchase> {
 const request=body as {actor_id?:unknown;app_account_token?:unknown;org_id?:unknown;product_id?:unknown}|null;
 assert(request&&request.actor_id===actor&&request.app_account_token===actor,403,"The trial must be prepared by its authenticated buying account.");
 assert(request.org_id===org,409,"Your workspace changed. Refresh before preparing a trial purchase.");
 assert(typeof request.product_id==="string"&&products.includes(request.product_id),400,"Choose a supported subscription product.");
 const {data,error}=await admin.rpc("prepare_subscription_trial_purchase",{p_actor:actor,p_org:org,p_product:request.product_id});
 if(error) {
  const match=/RP(\d{3}):\s*(.*)/.exec(String(error.message??""));
  if(match && [402,403,409].includes(Number(match[1])))throw new HttpError(Number(match[1]),match[2]);
  throw new HttpError(503,unavailable,"upstream");
 }
 return held(data,actor,org,request.product_id);
}
/** Only a verified signed zero-price Production introductory transaction may
 * recover a previously held exact actor/SKU workspace. No new hold is acquired. */
export async function reservedTrialWorkspace(admin:any,tx:AppleTransaction|null):Promise<string|null> {
 if(!tx||tx.environment!=="Production"||tx.priceMilliunits!==0||tx.offerType!==1||tx.offerDiscountType!=="FREE_TRIAL"||tx.currency!=="USD"||tx.storefront!=="USA"||!tx.appAccountToken||!uuid.test(tx.appAccountToken)||!products.includes(tx.productId))return null;
 const {data,error}=await admin.rpc("subscription_trial_reserved_workspace",{p_actor:tx.appAccountToken,p_product:tx.productId});
 assert(!error,503,"The admitted trial workspace could not be recovered. Please retry.");
 assert(data===null||(typeof data==="string"&&uuid.test(data)),503,"The admitted trial workspace could not be recovered. Please retry.");
 return data;
}
