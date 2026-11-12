// admin/photo-feedback.ts — GET /admin/photo-feedback?window=7d|30d|90d
//
// The internal AI photo quality report (contract
// docs/handoff/PHOTO-FEEDBACK-DESIGN-20261017.md section 5 + Amendments): how
// many photos were generated, how many were explicitly reviewed, the useful
// rate among explicit reviews only, coverage, the most common defect reasons
// with property fidelity kept apart from personal taste, breakdowns by edit,
// provider/model and recipe revision, and attributable attempts and recorded
// cost per explicitly useful result.
//
// index.ts owns the gate: requireAdmin() and the per-admin durable rate limit
// run before the route switch, exactly like every other /admin route, and the
// console stays GET-only. This module does no auth of its own.
//
// HONESTY. All wording comes from the SQL report and is rendered verbatim:
// ledger amounts are internal modeled estimates, never supplier invoices;
// breakdowns are observational, never proof that a setting is better; every
// cell carries its own n; rates are null (never 0) when nothing was reviewed.
//
// PRIVACY. Aggregates only: the RPC returns counts, rates and cents — no ids,
// request keys, notes, prompts or media keys — so this route creates no new
// access to any customer image. No provider is called, nothing is generated.
import {HttpError,json} from "../_shared/http.ts";
import {adminClient} from "../_shared/supabase.ts";

export const PHOTO_FEEDBACK_WINDOWS:Readonly<Record<string,number>>=Object.freeze({"7d":7,"30d":30,"90d":90});
export const PHOTO_FEEDBACK_REPORT_KEYS=["from","to","basis","data_range","generated","explicit","historical","signals","reasons","fidelity_vs_taste",
 "by_edit","by_provider_model","by_recipe_revision","cost","regression_cases","sample_note"] as const;
const ARRAY_KEYS=["reasons","by_edit","by_provider_model","by_recipe_revision"];
export type ReportRpc=(name:string,args:Record<string,unknown>)=>Promise<{data:unknown;error:{message?:string}|null}>;

export async function handlePhotoFeedback(req:Request,rpc:ReportRpc=async(name,args)=>await adminClient().rpc(name,args),now:()=>Date=()=>new Date()):Promise<Response>{
 const query=new URL(req.url).searchParams;
 if([...query.keys()].some(k=>k!=="window")||query.getAll("window").length>1)throw new HttpError(400,"Use ?window=7d, 30d or 90d.");
 const window=query.get("window")??"30d";
 const days=Object.hasOwn(PHOTO_FEEDBACK_WINDOWS,window)?PHOTO_FEEDBACK_WINDOWS[window]:undefined;
 if(!days)throw new HttpError(400,"Use ?window=7d, 30d or 90d.");
 const to=now(),from=new Date(to.getTime()-days*86_400_000);
 let result;
 try{result=await rpc("photo_feedback_report",{p_from:from.toISOString(),p_to:to.toISOString()});}
 catch{throw new HttpError(503,"The photo feedback report is temporarily unavailable.","upstream");}
 if(result.error){
  console.error(JSON.stringify({event:"admin_photo_feedback_report_failed"}));
  throw new HttpError(503,"The photo feedback report is temporarily unavailable.","upstream");
 }
 const report=result.data as Record<string,unknown>|null;
 if(!report||typeof report!=="object"||Array.isArray(report)||PHOTO_FEEDBACK_REPORT_KEYS.some(k=>!(k in report))||ARRAY_KEYS.some(k=>!Array.isArray(report[k]))
  ||typeof report.basis!=="string"||typeof report.sample_note!=="string")throw new HttpError(503,"The photo feedback report could not be verified.","upstream");
 return json({generated_at:to.toISOString(),window,...report},200,{"Cache-Control":"no-store"});
}
