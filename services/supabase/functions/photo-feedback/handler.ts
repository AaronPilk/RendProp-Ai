// photo-feedback: optional Useful / Needs work feedback, separate signals and
// consented regression cases for one exact AI photo output version.
// Contract: docs/handoff/PHOTO-FEEDBACK-DESIGN-20261017.md section 4 (+ Amendments).
//
//   POST /photo-feedback                   submit or revise explicit feedback
//   POST /photo-feedback/signal            acknowledgment / selection / export / publication signal
//   POST /photo-feedback/regression-case   keep or withdraw a private evaluation case
//   GET  /photo-feedback?provenance_id=…   the caller's current state for one output
//
// Auth: the user's bearer JWT; the selected library is X-Org-Id, read with the
// shared preferredOrg() exactly like every other library-scoped function (no
// other header is read). Every decision about the photo is made by the
// service-only SQL RPCs under the same library authorization as the media
// itself; this handler only validates shapes and maps refusals.
//
// Nothing here generates, judges, publishes or charges anything, and feedback
// never triggers a regeneration: the only side effects are rows in the three
// feedback tables. No provider is reachable from this function.
import {corsHeaders} from "../_shared/cors.ts";
import {HttpError,json,pathSegments,readJsonLimited} from "../_shared/http.ts";
import {preferredOrg} from "../_shared/supabase.ts";

export const FEEDBACK_REASONS=["changed_permanent_features","moved_or_changed_appliance","blocked_doorway_or_opening","inconsistent_furniture_between_views",
 "visible_visual_artifacts","requested_edit_incomplete","personal_style_preference","other"] as const;
export const REGRESSION_DEFECTS=FEEDBACK_REASONS.filter(r=>r!=="personal_style_preference");
export const SIGNALS=["accuracy_ack","manual_selection","automatic_selection","export","publication"] as const;
export const SIGNAL_DETAILS=["staging_review","custom_review","gallery_save","listing_selection","kit_export","download","published_tour"] as const;
export const PLATFORMS=["ios","studio","other"] as const;
export const SUBMITS_PER_WINDOW=120,SUBMIT_WINDOW_SECONDS=600;      // contract 4.5: 120 submits / 10 min / user
export const READS_PER_WINDOW=600,READ_WINDOW_SECONDS=600;          // state re-sync on a new device
export const MAX_BODY_BYTES=16_384;
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CLIENT_KEY=/^[A-Za-z0-9:_-]{8,128}$/;
const SHA256=/^[a-f0-9]{64}$/;

// The shared allow-list (it already carries x-org-id); only the methods are narrowed.
const headers={...corsHeaders,"Access-Control-Allow-Methods":"GET, POST, OPTIONS","Cache-Control":"no-store"};

export type FeedbackCode="invalid_request"|"unauthorized"|"forbidden"|"evaluation_consent_required"|"output_not_found"|"feedback_key_conflict"
 |"feedback_revision_conflict"|"feedback_exists"|"output_mismatch"|"evidence_unavailable"|"conflict"|"rate_limited"|"upstream"|"not_found"|"method_not_allowed";
export class FeedbackError extends Error{
 constructor(readonly status:number,readonly code:FeedbackCode,message:string,readonly details:Record<string,unknown>={}){super(message);}
}
const invalid=(message:string)=>new FeedbackError(400,"invalid_request",message);

export interface FeedbackUser{id:string;is_anonymous?:boolean}
export interface FeedbackDeps{
 /** Supabase Auth: the caller behind the bearer JWT (throws HttpError 401). */
 getUser(req:Request):Promise<FeedbackUser>;
 /** Service-role RPC. */
 rpc(name:string,args:Record<string,unknown>):Promise<{data:unknown;error:{message?:string}|null}>;
 /** Durable per-user limiter: true = admitted (throws HttpError 503 when unavailable). */
 rateLimit(key:string,max:number,windowSeconds:number):Promise<boolean>;
}

/** The selected library: X-Org-Id via the shared preferredOrg() (trimmed and
 * lowercased when it is a uuid). Missing or not a uuid is a 400. */
export function selectedLibrary(req:Request):string{
 const org=preferredOrg(req);
 if(!org||!UUID.test(org))throw invalid("Select the photo's library (X-Org-Id).");
 return org;
}

function object(value:unknown,field:string):Record<string,unknown>{
 if(!value||typeof value!=="object"||Array.isArray(value))throw invalid(`${field} must be an object.`);
 return value as Record<string,unknown>;
}
function only(body:Record<string,unknown>,allowed:string[],field="The request"):void{
 const extra=Object.keys(body).filter(k=>!allowed.includes(k));
 if(extra.length)throw invalid(`${field} has unsupported fields: ${extra.sort().join(", ")}.`);
}
function outputOf(body:Record<string,unknown>,allowSha:boolean):{provenance:string;sha:string|null}{
 const output=object(body.output,"output");only(output,allowSha?["provenance_id","output_sha256"]:["provenance_id"],"output");
 const provenance=typeof output.provenance_id==="string"?output.provenance_id.toLowerCase():"";
 if(!UUID.test(provenance))throw invalid("output.provenance_id must be the exact output version id.");
 const sha=output.output_sha256??null;
 if(sha!==null&&(typeof sha!=="string"||!SHA256.test(sha)))throw invalid("output.output_sha256 must be 64 lowercase hex characters.");
 return {provenance,sha:sha as string|null};
}
function clientKey(body:Record<string,unknown>):string{
 if(typeof body.client_key!=="string"||!CLIENT_KEY.test(body.client_key))throw invalid("client_key must be 8-128 characters of A-Z, a-z, 0-9, colon, underscore or hyphen.");
 return body.client_key;
}
function platform(body:Record<string,unknown>):string|null{
 if(body.platform===undefined||body.platform===null)return null;
 if(typeof body.platform!=="string"||!(PLATFORMS as readonly string[]).includes(body.platform))throw invalid("platform must be ios, studio or other.");
 return body.platform;
}

export function parseSubmit(body:Record<string,unknown>){
 only(body,["output","client_key","revision","verdict","reasons","note","platform"]);
 const {provenance,sha}=outputOf(body,true);
 const key=clientKey(body);
 if(typeof body.revision!=="number"||!Number.isInteger(body.revision)||body.revision<1||body.revision>1_000_000)throw invalid("revision must be an integer from 1.");
 if(body.verdict!=="useful"&&body.verdict!=="needs_work")throw invalid("verdict must be useful or needs_work.");
 const reasons=body.reasons===undefined?[]:body.reasons;
 if(!Array.isArray(reasons)||reasons.some(r=>typeof r!=="string"||!(FEEDBACK_REASONS as readonly string[]).includes(r))||new Set(reasons).size!==reasons.length)
  throw invalid("reasons must be distinct values from the documented list.");
 if(body.verdict==="useful"&&reasons.length)throw invalid("A Useful verdict carries no reasons.");
 if(body.verdict==="needs_work"&&!reasons.length)throw invalid("Needs work requires at least one reason.");
 if(body.note!==undefined&&body.note!==null&&(typeof body.note!=="string"||body.note.length>500))throw invalid("note must be text of at most 500 characters.");
 return {p_provenance:provenance,p_output_sha256:sha,p_client_key:key,p_revision:body.revision,p_verdict:body.verdict,p_reasons:reasons as string[],
  p_note:typeof body.note==="string"?body.note:null,p_platform:platform(body)};
}
export function parseSignal(body:Record<string,unknown>){
 only(body,["output","client_key","signal","detail","platform"]);
 const {provenance}=outputOf(body,false);
 const key=clientKey(body);
 if(typeof body.signal!=="string"||!(SIGNALS as readonly string[]).includes(body.signal))throw invalid("signal must be one of the documented signals.");
 const detail=body.detail??null;
 if(detail!==null&&(typeof detail!=="string"||!(SIGNAL_DETAILS as readonly string[]).includes(detail)))throw invalid("detail must be one of the documented details or null.");
 return {p_provenance:provenance,p_client_key:key,p_signal:body.signal,p_detail:detail as string|null,p_platform:platform(body)};
}
export function parseCase(body:Record<string,unknown>){
 only(body,["output","defect","expected_behavior","retain_for_evaluation","withdraw"]);
 const {provenance}=outputOf(body,false);
 if(body.withdraw!==undefined&&typeof body.withdraw!=="boolean")throw invalid("withdraw must be true or false.");
 if(body.retain_for_evaluation!==undefined&&typeof body.retain_for_evaluation!=="boolean")throw invalid("retain_for_evaluation must be true or false.");
 const withdraw=body.withdraw===true;
 if(withdraw)return {p_provenance:provenance,p_defect:null,p_expected:null,p_retain:body.retain_for_evaluation===true,p_withdraw:true};
 if(typeof body.defect!=="string"||!(REGRESSION_DEFECTS as readonly string[]).includes(body.defect))throw invalid("defect must be a property-fidelity reason or other.");
 const expected=typeof body.expected_behavior==="string"?body.expected_behavior.trim():"";
 if(expected.length<10||expected.length>1000)throw invalid("expected_behavior must describe the expected result in 10-1000 characters.");
 if(body.retain_for_evaluation!==true)throw new FeedbackError(403,"evaluation_consent_required","Keeping this photo for evaluation needs explicit permission (retain_for_evaluation: true).");
 return {p_provenance:provenance,p_defect:body.defect,p_expected:expected,p_retain:true,p_withdraw:false};
}

/** Deliberate SQL refusals (RPnnn[: TAG] message) become contract codes; any
 * other database text is never shown to a client. */
export function mapRpcError(message:string|undefined):FeedbackError{
 const m=/RP(\d{3}):\s*(?:([A-Z][A-Z_]+[A-Z])\s+)?([\s\S]*)/.exec(message??"");
 if(!m)return new FeedbackError(503,"upstream","Feedback is temporarily unavailable. Nothing was lost; please retry.");
 const status=Number(m[1]),tag=m[2]??"",text=(m[3]||"").trim()||"The request was refused.";
 if(status===400)return new FeedbackError(400,"invalid_request",text);
 if(status===403)return tag==="CONSENT"?new FeedbackError(403,"evaluation_consent_required",text):new FeedbackError(403,"forbidden",text);
 if(status===404)return new FeedbackError(404,"output_not_found","This photo is unavailable in the selected library.");
 if(status===409){
  const code=({FEEDBACK_KEY_CONFLICT:"feedback_key_conflict",FEEDBACK_REVISION_CONFLICT:"feedback_revision_conflict",OUTPUT_MISMATCH:"output_mismatch",EVIDENCE_UNAVAILABLE:"evidence_unavailable"} as Record<string,FeedbackCode>)[tag];
  return new FeedbackError(409,code??"conflict",text);
 }
 return new FeedbackError(503,"upstream","Feedback is temporarily unavailable. Nothing was lost; please retry.");
}

async function call(deps:FeedbackDeps,name:string,args:Record<string,unknown>):Promise<Record<string,unknown>>{
 let result;
 try{result=await deps.rpc(name,args);}catch{throw new FeedbackError(503,"upstream","Feedback is temporarily unavailable. Nothing was lost; please retry.");}
 if(result.error)throw mapRpcError(result.error.message);
 if(!result.data||typeof result.data!=="object"||Array.isArray(result.data))throw new FeedbackError(503,"upstream","Feedback could not be confirmed. Please retry with the same request.");
 return result.data as Record<string,unknown>;
}
const respond=(body:unknown,status=200)=>json(body,status,headers);
function fail(error:unknown):Response{
 if(error instanceof FeedbackError)return respond({...error.details,error:error.message,code:error.code},error.status);
 if(error instanceof HttpError){
  if(error.status===401)return respond({error:error.message,code:"unauthorized"},401);
  if(error.status===429)return respond({error:"Too many feedback requests. Your choice is kept and will be sent shortly.",code:"rate_limited"},429);
  if(error.status===400||error.status===413)return respond({error:error.status===413?"The feedback request is too large.":error.message,code:"invalid_request"},400);
  if(error.status===403)return respond({error:error.message,code:"forbidden"},403);
 }
 console.error(JSON.stringify({event:"photo_feedback_error",kind:error instanceof HttpError?"handled":"unexpected"}));
 return respond({error:"Feedback is temporarily unavailable. Nothing was lost; please retry.",code:"upstream"},503);
}

export function createPhotoFeedbackHandler(deps:FeedbackDeps){
 return async function handler(req:Request):Promise<Response>{
  if(req.method==="OPTIONS")return new Response("ok",{headers});
  try{
   // Authenticate before the route is even looked at.
   const user=await deps.getUser(req);
   const path=pathSegments(req,"photo-feedback").join("/");
   const route=req.method==="GET"&&path===""?"state":req.method==="POST"&&path===""?"submit":req.method==="POST"&&path==="signal"?"signal":req.method==="POST"&&path==="regression-case"?"case":null;
   if(!route){
    if(["","signal","regression-case"].includes(path))throw new FeedbackError(405,"method_not_allowed","Use POST to send feedback or GET to read it.");
    throw new FeedbackError(404,"not_found","Unknown photo feedback route.");
   }
   if(user.is_anonymous!==false)throw new FeedbackError(403,"forbidden","Sign in to your own account before rating a photo.");
   const selected=selectedLibrary(req);
   const limited=route==="state"?await deps.rateLimit(`photo-feedback-read:${user.id}`,READS_PER_WINDOW,READ_WINDOW_SECONDS)
    :await deps.rateLimit(`photo-feedback:${user.id}`,SUBMITS_PER_WINDOW,SUBMIT_WINDOW_SECONDS);
   if(!limited)throw new FeedbackError(429,"rate_limited","Too many feedback requests. Your choice is kept and will be sent shortly.");
   const identity={p_actor:user.id,p_selected:selected};
   if(route==="state"){
    const query=new URL(req.url).searchParams;
    const provenance=(query.get("provenance_id")??"").toLowerCase();
    if([...query.keys()].some(k=>k!=="provenance_id")||query.getAll("provenance_id").length!==1||!UUID.test(provenance))throw invalid("Use exactly one provenance_id.");
    const data=await call(deps,"photo_feedback_state",{...identity,p_provenance:provenance});
    if(data.provenance_id!==provenance)throw new FeedbackError(503,"upstream","Feedback state could not be confirmed. Please retry.");
    return respond(data);
   }
   if((req.headers.get("content-type")??"").split(";")[0].trim().toLowerCase()!=="application/json")throw invalid("Send JSON (content-type: application/json).");
   const body=object(await readJsonLimited(req,MAX_BODY_BYTES),"The request body");
   if(route==="submit"){
    const args=parseSubmit(body);
    const data=await call(deps,"photo_feedback_submit",{...identity,...args});
    // Top-level adoption fields (shared error body {...details, error, code}):
    // the key to adopt, its revision, and the caller's own stored verdict so an
    // identical resend can be skipped.
    if(data.state==="conflict"&&data.code==="feedback_exists")
     throw new FeedbackError(409,"feedback_exists","Feedback for this photo already exists under another key; adopt it and send a higher revision.",
      {client_key:data.client_key,revision:data.revision,revision_count:data.revision_count,feedback_id:data.feedback_id,provenance_id:data.provenance_id,
       verdict:data.verdict,reasons:data.reasons,note:data.note??null});
    if(!["recorded","replayed","revised"].includes(String(data.state))||data.provenance_id!==args.p_provenance||typeof data.feedback_id!=="string")
     throw new FeedbackError(503,"upstream","Feedback could not be confirmed. Please retry with the same request.");
    return respond(data);
   }
   if(route==="signal"){
    const args=parseSignal(body);
    const data=await call(deps,"photo_feedback_signal",{...identity,...args});
    if(!["recorded","replayed"].includes(String(data.state))||data.provenance_id!==args.p_provenance||typeof data.signal_id!=="string")
     throw new FeedbackError(503,"upstream","The signal could not be confirmed. Please retry with the same request.");
    return respond(data);
   }
   const args=parseCase(body);
   const data=await call(deps,"photo_regression_case_mark",{...identity,...args});
   if(!["recorded","replayed","withdrawn"].includes(String(data.state)))throw new FeedbackError(503,"upstream","The evaluation case could not be confirmed. Please retry.");
   return respond(data);
  }catch(error){return fail(error);}
 };
}
