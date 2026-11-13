// Actor-authenticated review of an existing owned paid photo. No generation,
// photo credit consumption, policy activation or historical media promotion.
import {corsHeaders} from "../_shared/cors.ts";
import {assert,pathSegments,readJsonLimited,respondError} from "../_shared/http.ts";
import {adminClient,assertNotDeleting,assertPaidAiIdentity,contentOrgForUser,getUser,preferredOrg,type PaidAiCaller} from "../_shared/supabase.ts";
import {calibrationRequest,beginPhotoCalibration} from "../ai-photo/photo-qc-calibration.ts";
import {waitForPhotoQuality} from "../ai-photo/photo-qc-wait.ts";
import {photoUUID,statusPhotoQuality,photoQualityResponse,type PhotoQualityEnvelope} from "../ai-photo/photo-qc-store.ts";

export const REVIEW_CONSENT="photo-quality-review-v1";
export const REVIEW_REQUEST_BYTES=12_100_000; // 9 MB decoded source plus bounded request context
const reviewCors={...corsHeaders,"Access-Control-Allow-Headers":corsHeaders["Access-Control-Allow-Headers"]+", x-rendprop-ai-consent","Access-Control-Allow-Methods":"GET, POST, OPTIONS","Cache-Control":"no-store"};
// Same current editor/paid-identity gate as ai-photo, without importing its
// generation entrypoint or its feature-credit/burst charge helpers.
async function requireEditorRole(user:PaidAiCaller,req:Request,listing:string):Promise<string>{
 const org=await contentOrgForUser(user.id,preferredOrg(req),listing,true);
 await assertPaidAiIdentity(user,org);return org;
}
function calibrationOnly(row:PhotoQualityEnvelope):void{
 assert(row.evidence.purpose==="calibration",404,"This saved photo review is unavailable.","not_found");
}
function withReviewHeaders(response:Response):Response{
 const headers=new Headers(response.headers);for(const[k,v]of Object.entries(reviewCors))headers.set(k,v);
 return new Response(response.body,{status:response.status,statusText:response.statusText,headers});
}
export async function handler(req:Request):Promise<Response>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:reviewCors});
 try{
  const user=await getUser(req);
  assert(user.is_anonymous===false,403,"Sign in to your own account before checking a saved photo.");
  const selected=preferredOrg(req)??null;
  assert(photoUUID(selected),400,"Select the saved photo's library.");
  const path=pathSegments(req,"photo-quality-review");
  if(req.method==="GET"&&path.join("/")==="status"){
   const query=new URL(req.url).searchParams;
   assert([...query.keys()].every(k=>k==="check_id")&&query.getAll("check_id").length===1,400,"Use one saved photo check identity.");
   const row=await statusPhotoQuality(adminClient(),user.id,query.get("check_id")??"",selected);
   calibrationOnly(row);
   return withReviewHeaders(await photoQualityResponse(adminClient(),row,user.id,selected));
  }
  assert(req.method==="POST"&&path.length===0,405,"Use POST to review a saved photo or GET its status.");
  assert(req.headers.get("x-rendprop-ai-consent")===REVIEW_CONSENT,403,"Allow AI processing of this saved photo pair before checking it.","consent_required");
  assert((req.headers.get("content-type")??"").split(";")[0].trim().toLowerCase()==="application/json",400,"Send the saved photo request as JSON.");
  req.signal.throwIfAborted();await assertNotDeleting(user.id);
  const raw=await readJsonLimited<Record<string,unknown>>(req,REVIEW_REQUEST_BYTES);
  assert(raw&&typeof raw==="object"&&!Array.isArray(raw)&&Object.keys(raw).length===2&&Object.keys(raw).every(k=>["generation_request_key","generation_request_body"].includes(k)),400,"Use only the exact saved photo request and its key.");
  const body=calibrationRequest(raw),org=await requireEditorRole(user,req,body.generation_request_body.listing_id);
  req.signal.throwIfAborted();
  const row=await beginPhotoCalibration(adminClient(),{actor:user.id,org,selected,body});
  calibrationOnly(row);
  const checked=await waitForPhotoQuality(adminClient(),row,{actor:user.id,selected,request:req,instruction:body.generation_request_body.prompt});
  calibrationOnly(checked);
  return withReviewHeaders(await photoQualityResponse(adminClient(),checked,user.id,selected));
 }catch(error){return withReviewHeaders(respondError(error));}
}
if(import.meta.main)Deno.serve(handler);
