// One liability hold per paid attempt, shared by every workspace feature.
// A refund of a feature counter is never a refund of an incurred provider bill.
import { HttpError, throwRpc } from "./http.ts";
import type { RouteStep } from "./router.ts";
import { paramsOf } from "./router.ts";
import { ProviderError } from "./providers/common.ts";
import { anthropicMaxTokens } from "./providers/anthropic.ts";
import { openaiChatConfig } from "./providers/openai.ts";
import { geminiImageGenerationConfig } from "./providers/gemini.ts";
import type { GenerateInput } from "./providers/types.ts";

export class FundingAdmissionError extends HttpError { readonly funding_admission = true; }
export class SavedFundingResponse extends HttpError {
 constructor(readonly saved_response:Record<string,unknown>){super(200,"Restored generated result.");}
}
function fundingRpcError(message:string):never {
 // Missing activation is an operator-side availability boundary. Buying a
 // bigger plan cannot repair it. An exhausted funded interval remains quota;
 // neither case permits another provider attempt or loosens the spending gate.
 if (/RP402:\s*(?:This workspace has no funded serving allowance|This paid service interval is not funded)\s*$/.test(message))
  throw new FundingAdmissionError(503,"AI generation is not available for this workspace yet. Please contact support.","upstream");
 if (/RP402:\s*This attempt exceeds the shared funded serving allowance\s*$/.test(message))
  throw new FundingAdmissionError(402,"This workspace's shared AI usage limit has been reached. Wait for its next funded billing interval.","quota_exceeded");
 try { throwRpc(message); } catch(error) {
  if(error instanceof HttpError)throw new FundingAdmissionError(error.status,error.message,error.code,/This operation already started/.test(message)?{funding_operation_replay:true}:undefined);
  throw error;
 }
}
export interface FundingContext {
 actorId: string;
 orgId: string;
 requestKey: string;
 operationBegun?: boolean;
 rpc(name: string, args: Record<string, unknown>): PromiseLike<{data: unknown; error: {message?: string} | null}>;
}
export interface AttemptQuote { cents: number; version: string }
export const TARIFF_VERSION = "published-standard-20261006";

/** New operations use the transport's existing idempotency key. Helpers in old
 * clients have no such key; their request hash is a permanent conservative
 * tombstone, rather than a short timeout that authorizes another paid replay. */
export async function fundingContext(actorId: string,orgId: string,req: Request,input: unknown,
 rpc: FundingContext["rpc"]): Promise<FundingContext> {
 let requestKey=req.headers.get("idempotency-key")?.trim();
 if(requestKey && !/^[A-Za-z0-9:_-]{8,128}$/.test(requestKey))throw new FundingAdmissionError(400,"Use a valid request identifier.");
 requestKey??=await inputHash({path:new URL(req.url).pathname,input});
 const context={actorId,orgId,requestKey,rpc};
 await beginFundingOperation(context,new URL(req.url).pathname,input);
 return context;
}
export async function beginFundingOperation(context:FundingContext,operation:string,input:unknown):Promise<void> {
 let begun;
 try { begun=await context.rpc("serving_operation_begin",{p_actor:context.actorId,p_org:context.orgId,p_key:context.requestKey,p_operation:operation,p_input_sha256:await inputHash(input)}); }
 catch {throw new FundingAdmissionError(503,"This operation could not be journaled safely. Please retry.","upstream");}
 if(begun.error){
  if(/RP(?:400|402|403|409):/.test(begun.error.message??""))fundingRpcError(begun.error.message!);
  throw new FundingAdmissionError(503,"This operation could not be journaled safely. Please retry.","upstream");
 }
 if(begun.data&&typeof begun.data==="object"&&(begun.data as{replay?:unknown}).replay===true){
  const result=(begun.data as{result?:unknown}).result;
  if(result&&typeof result==="object"&&!Array.isArray(result))throw new SavedFundingResponse(result as Record<string,unknown>);
 }
 if(!begun.data||typeof begun.data!=="object"||(begun.data as {begun?:unknown}).begun!==true)throw new FundingAdmissionError(503,"This operation could not be journaled safely. Please retry.","upstream");
 context.operationBegun=true;
}
export async function completeFundingOperation(context:FundingContext,result:Record<string,unknown>):Promise<Record<string,unknown>>{
 try{
  const saved=await context.rpc("serving_operation_complete",{p_actor:context.actorId,p_org:context.orgId,p_key:context.requestKey,p_result:result});
  if(saved.error){if(/RP403:/.test(saved.error.message??""))fundingRpcError(saved.error.message!);console.error("Generated result recovery unavailable; provider liability retained");}
  else if(!saved.data||typeof saved.data!=="object"||(saved.data as{saved?:unknown}).saved!==true)console.error("Generated result recovery unavailable; provider liability retained");
 }catch(error){if(error instanceof FundingAdmissionError)throw error;console.error("Generated result recovery unavailable; provider liability retained");}
 return result;
}
export async function abortFundingOperationBeforeDispatch(context:FundingContext):Promise<void>{
 if(!context.operationBegun)return;
 try{await context.rpc("serving_operation_no_dispatch",{p_actor:context.actorId,p_org:context.orgId,p_key:context.requestKey});}catch{/* An uncertain journal remains fenced. */}
}
export async function inputHash(value: unknown): Promise<string> {
 const bytes=new TextEncoder().encode(JSON.stringify(value));
 return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",bytes)),byte=>byte.toString(16).padStart(2,"0")).join("");
}
async function unlimitedSponsored(context: FundingContext): Promise<boolean> {
 for(const name of ["org_has_internal_testing_grant","org_has_private_internal_testing"]){
  let result;try{result=await context.rpc(name,{p_org:context.orgId});}catch{throw new FundingAdmissionError(503,"Testing sponsorship could not be checked. Please retry.","upstream");}
  if(result.error)throw new FundingAdmissionError(503,"Testing sponsorship could not be checked. Please retry.","upstream");
  if(result.data===true)return true;
 }
 return false;
}

/** Route eligibility/privacy/capability filtering happens first. A finite
 * package permits one pinned primary and at most one priced fallback, while
 * private unlimited QA retains its existing operator chain. */
export async function boundedPhotoChain(context: FundingContext, steps: RouteStep[], input: GenerateInput): Promise<RouteStep[]> {
 if(await unlimitedSponsored(context))return steps;
 const priced=steps.filter(step=>step.task===input.task && (
  (step.provider==="gemini" && step.model==="gemini-3.1-flash-image" && !input.mask_url) ||
  (step.provider==="fal" && step.model.replace(/^fal-ai\//,"")==="flux-pro/kontext" && !input.mask_url)
 ));
 const primary=priced.filter(step=>step.provider==="gemini"),fallback=priced.filter(step=>step.provider==="fal");
 if(primary.length!==1 || fallback.length>1 || priced.some(step=>{
  const quote=mediaAttemptQuote(step,input);
  return !quote || Math.ceil(quote.cents*10000)!==(step.provider==="gemini"?311296:40000);
 }))
  throw new FundingAdmissionError(503,"This photo tool has no complete bounded serving route. No edit was sent.","upstream");
 return [...primary,...fallback];
}

/** The bounded trial's cash belongs to its five image admissions. Paid
 * accounts retain separately metered helpers through the shared funded wallet;
 * private unlimited QA retains its existing sponsorship. */
export async function assertPhotoHelperSponsorship(context: FundingContext): Promise<void> {
 if(await unlimitedSponsored(context))return;
 let trial;
 try { trial=await context.rpc("subscription_trial_context",{p_actor:context.actorId,p_org:context.orgId}); }
 catch {await abortFundingOperationBeforeDispatch(context);throw new FundingAdmissionError(503,"Trial helper availability could not be checked. No generation was submitted.","upstream");}
 const data=trial.data as Record<string,unknown>|null;
 if(trial.error || !data || typeof data!=="object" || Array.isArray(data) || !("trial_usage" in data)){
  await abortFundingOperationBeforeDispatch(context);
  throw new FundingAdmissionError(503,"Trial helper availability could not be checked. No generation was submitted.","upstream");
 }
 if(data.trial_usage===null)return;
 const usage=data.trial_usage as Record<string,unknown>|null;
 await abortFundingOperationBeforeDispatch(context);
 if(!usage || typeof usage!=="object" || Array.isArray(usage) || usage.org_id!==context.orgId || !["active","expired","exhausted"].includes(String(usage.status)))
  throw new FundingAdmissionError(503,"Trial helper availability could not be checked. No generation was submitted.","upstream");
 throw new FundingAdmissionError(503,"Photo suggestions and prompt rewriting are not included in this subscription trial. Choose an edit or write your own instructions; no generation was submitted.","upstream");
}

export async function fundedAttempt<T>(context: FundingContext,stage: string,step: Pick<RouteStep,"provider"|"model">,
 input: unknown,quote: AttemptQuote|null,attempt:()=>Promise<T>): Promise<T> {
 try{
 if(!quote && !await unlimitedSponsored(context))throw new FundingAdmissionError(503,"This operation's complete price could not be verified. No generation was submitted.","upstream");
 // An unpriced private QA attempt is explicitly sponsor expense and never
 // charged to retail/reviewer/trial funds or described as a reconciled cost.
 const admitted=quote??{cents:1,version:"unpriced-private-sponsorship"};
 if(!Number.isFinite(admitted.cents)||admitted.cents<=0||admitted.cents>100000000)
  throw new FundingAdmissionError(503,"This operation could not be priced safely.","upstream");
 const hold=Math.ceil(admitted.cents*10000)/10000;
 let reserved;
 try { reserved=await context.rpc("serving_cost_reserve",{p_actor:context.actorId,p_org:context.orgId,p_key:context.requestKey,
  p_stage:stage,p_provider:step.provider,p_model:step.model,p_input_sha256:await inputHash(input),p_hold_cents:hold,p_tariff_version:admitted.version}); }
 catch {throw new FundingAdmissionError(503,"The shared serving budget could not be reserved. Please retry.","upstream");}
 if(reserved.error){
  if(/RP(?:400|402|403|409):/.test(reserved.error.message??""))fundingRpcError(reserved.error.message!);
  throw new FundingAdmissionError(503,"The shared serving budget could not be reserved. Please retry.","upstream");
 }
 if(!reserved.data||typeof reserved.data!=="object"||(reserved.data as {reserved?:unknown}).reserved!==true)
  throw new FundingAdmissionError(503,"The shared serving budget could not be reserved. Please retry.","upstream");
 }catch(error){if(error instanceof FundingAdmissionError)await abortFundingOperationBeforeDispatch(context);throw error;}
 const finish=async(state:string,rejection:number|null=null)=>{
  try{
   const result=await context.rpc("serving_cost_finish",{p_actor:context.actorId,p_org:context.orgId,p_key:context.requestKey,p_stage:stage,p_state:state,p_rejection_status:rejection});
   if(result.error||!result.data||typeof result.data!=="object"||(result.data as{finished?:unknown}).finished!==true)
    console.error("Provider liability settlement unavailable; funded hold retained");
  }catch{console.error("Provider liability settlement unavailable; funded hold retained");}
 };
 try{
  const result=await attempt();
  // A transport response is not a validated generation/queue receipt. Keep the
  // liability if a future caller forgets to validate HTTP status and payload.
  if(result instanceof Response)throw new HttpError(502,"The generation service did not return a validated receipt.","upstream");
  await finish("succeeded");return result;
 }
 catch(error){
  const details=error instanceof HttpError?error.details:undefined;
  const rejected=error instanceof ProviderError?error.dispatch_rejected:details?.dispatch_rejected===true;
  const status=error instanceof ProviderError?error.status:details?.provider_status;
  if(rejected&&typeof status==="number"&&[0,400,401,402,403,404,405,413,415,422,429].includes(status))await finish("rejected",status);
  else await finish("uncertain");
  throw error;
 }
}

/** Text-only payloads use a byte upper bound and the adapter's ACTUAL output
 * token ceiling, including route params/reasoning. Media uses the published
 * entire model input window until a trusted token/pixel authority exists.
 * Published tariffs: Google pricing/model limits, OpenAI pricing, Claude pricing.
 * Unknown models, image inputs, tools and private rates never use flat averages. */
export function textAttemptQuote(step:RouteStep,system:string,turn:string,maxOutputTokens:number,media=false):AttemptQuote|null {
 let inputRate:number,outputRate:number,output:number;
 if(step.provider==="openai"){
  const rates:Record<string,[number,number]>={"gpt-5.6-terra":[2,12],"gpt-5.6-sol":[4,20],"gpt-6-astra":[20,75],"gpt-6.1-sol":[4,15],"gpt-6-sol":[4,20],"gpt-5.6-luna":[.2,1.2]};
  const rate=rates[step.model];if(!rate||media)return null;[inputRate,outputRate]=rate;
  output=openaiChatConfig(paramsOf(step),maxOutputTokens).maxOutputTokens;
 }else if(step.provider==="anthropic"){
  const rates:Record<string,[number,number]>={"claude-sonnet-5":[2,10],"claude-sonnet-5-5":[2,10],"claude-opus-5":[5,25],"claude-haiku-4-5":[1,5]};
  const rate=rates[step.model];if(!rate)return null;[inputRate,outputRate]=rate;output=anthropicMaxTokens(paramsOf(step),maxOutputTokens);
 }else if(step.provider==="gemini"&&step.model==="gemini-3.6-flash"){
  inputRate=1.5;outputRate=7.5;output=65536;
 }else return null;
 const bytes=new TextEncoder().encode(system+"\n\n---\n\n"+turn).byteLength;
 if(bytes>100000||!Number.isInteger(output)||output<=0||output>65536)return null;
 const tokens=media?1048576:bytes+1024;
 return {cents:(tokens*inputRate+output*outputRate)/10000,version:TARIFF_VERSION};
}

/** Published legacy GenerateContent hard cutoff includes thought tokens:
 * https://ai.google.dev/gemini-api/docs/generate-content/thinking#token-limits
 * Charge every combined output token at the highest image tariff ($60/M),
 * retaining the full 131072 input window ($0.50/M). This is a documentation
 * bound, not evidence of paid-account acceptance or an invoice reconciliation. */
export function geminiImageGenerationQuote(config:Record<string,unknown>):AttemptQuote|null {
 const output=config.maxOutputTokens;
 if(typeof output!=="number"||!Number.isInteger(output)||output<=0||output>32768
  ||config.candidateCount!==1||!Array.isArray(config.responseModalities)
  ||config.responseModalities.length!==1||config.responseModalities[0]!=="IMAGE"
  ||!config.imageConfig||typeof config.imageConfig!=="object"
  ||(config.imageConfig as Record<string,unknown>).imageSize!=="1K")return null;
 return {cents:(131072*.5+output*60)/10000,version:TARIFF_VERSION};
}

export function mediaAttemptQuote(step:RouteStep,input:GenerateInput):AttemptQuote|null {
 if(step.provider==="gemini"&&step.model==="gemini-3.1-flash-image")
  return geminiImageGenerationQuote(geminiImageGenerationConfig(step.model));
 const model=step.model.replace(/^fal-ai\//,"");
 if(step.provider==="fal"&&model==="flux-pro/kontext"&&!input.mask_url)
  return {cents:4,version:TARIFF_VERSION};
 // Other payloads retain their existing route-specific bounded quote authority.
 return null;
}
