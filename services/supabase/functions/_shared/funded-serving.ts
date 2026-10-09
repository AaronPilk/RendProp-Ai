// One liability hold per paid attempt, shared by every workspace feature.
// A refund of a feature counter is never a refund of an incurred provider bill.
import { HttpError, throwRpc } from "./http.ts";
import { adminClient } from "./supabase.ts";
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
/** Ceiling-mode refusals name their kind so the customer hears the right thing:
 * a free sample never refills, a personal trial window ends on its own, the
 * shared sponsor pool is ours (never the customer's fault), and a paid period
 * resets on a date. */
export function ceilingRefusalCopy(message:string):string|null {
 const kind=/RP402:\s*AI usage limit reached \[kind=([a-z_]+)\]/.exec(message)?.[1];
 if(kind==="free")return "Your free AI sample is used up. Subscribe to keep using AI tools.";
 if(kind==="trial")return "Your trial's AI allowance is used up. Your plan's full allowance starts with the paid period.";
 if(kind==="grace")return "AI tools are paused while Apple retries your subscription payment. They resume as soon as the renewal goes through.";
 if(kind)return "This workspace has used its AI allowance for the current billing period. It resets with the next period, or upgrade for more.";
 const pool=/RP402:\s*Free-trial AI limit reached \[pool=([a-z]+)\]/.exec(message)?.[1];
 if(pool)return "Free-trial AI is paused right now: the shared trial allowance is used up on our side. Nothing was charged. Your plan's own allowance starts with its paid period.";
 return null;
}
function fundingRpcError(message:string):never {
 // Ceiling mode (2026-10-08): the workspace's serving envelope is spent for
 // this window, or the shared trial sponsor pool is. Both are quota: nothing
 // more dispatches, and the copy says which it was.
 const copy=ceilingRefusalCopy(message);
 if(copy)throw new FundingAdmissionError(402,copy,"quota_exceeded");
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

/** Launch cost model switch (app_config.serving_mode, 2026-10-08).
 * `ceiling`: per-feature meters plus a per-workspace serving envelope
 * (plan_serving_ceiling) that serving_cost_reserve enforces atomically before
 * every paid attempt; holds are priced from the route catalog the ledger bills
 * against. `funded`: Codex's certified-funding model (serving_funding,
 * schedules, pools). A missing, malformed or unreadable setting fails CLOSED to
 * `funded`, which refuses an unfunded workspace rather than spending without a
 * ceiling (serving_mode() in SQL applies the same rule). */
export type ServingMode = "ceiling" | "funded";
let servingModeCache: { mode: ServingMode; at: number } | null = null;
export async function servingMode(): Promise<ServingMode> {
 if (servingModeCache && Date.now() - servingModeCache.at < 30_000) return servingModeCache.mode;
 try {
  const result = await adminClient().rpc("serving_mode", {});
  const mode: ServingMode = !result.error && result.data === "ceiling" ? "ceiling" : "funded";
  servingModeCache = { mode, at: Date.now() };
  return mode;
 } catch { return "funded"; }
}
/** Test seam only: forget the cached mode so a fixture can flip it. */
export function resetServingModeCache(): void { servingModeCache = null; }

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
 // Ceiling mode keeps the operator chain: each step is priced from the
 // catalog and admitted against the workspace envelope in fundedAttempt.
 if(await servingMode()==="ceiling")return steps;
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
 // Ceiling mode: helpers are ordinary priced attempts against the envelope.
 if(await servingMode()==="ceiling")return;
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

/** Ceiling mode prices a hold from the route catalog (ai_routes.unit_cents),
 * the same figure recordRoutedAiCost() bills to the ledger, so a burst of
 * admitted attempts never double-reserves against the documentation bound the
 * funded model holds. Units come from the input when it states them and are
 * otherwise the largest the route can produce. A step that carries no catalog
 * price (bare provider/model) returns null and keeps the caller's quote. */
export const ROUTE_CATALOG_TARIFF=`route-catalog-${TARIFF_VERSION}`;
export function routeCatalogQuote(step:Pick<RouteStep,"provider"|"model">&Partial<Pick<RouteStep,"unit"|"unit_cents">>,input:unknown):AttemptQuote|null {
 const cents=step.unit_cents;
 if(typeof cents!=="number"||!Number.isFinite(cents)||cents<0||cents>100000000||typeof step.unit!=="string")return null;
 const data=input&&typeof input==="object"&&!Array.isArray(input)?input as Record<string,unknown>:{};
 const positive=(value:unknown,max:number)=>typeof value==="number"&&Number.isFinite(value)&&value>0&&value<=max?value:null;
 let units:number;
 switch(step.unit){
  case "call":case "image":case "world":units=1;break;
  case "second":units=positive(data.seconds,600)??12;break;
  case "minute":{const seconds=positive(data.seconds,36000);units=seconds?Math.ceil(seconds/60):10;break;}
  case "1k_chars":{const text=typeof data.text==="string"?data.text:typeof data.script==="string"?data.script:null;units=text?Math.max(1,Math.ceil(text.length/1000)):5;break;}
  default:return null;
 }
 // Round at six decimals before the four-decimal ceiling so 4.86 x 12 is 58.32, not 58.3201.
 return {cents:Math.ceil(Math.round(cents*units*1000000)/100)/10000,version:ROUTE_CATALOG_TARIFF};
}
/** Catalog routes that cost nothing (on-device Apple speech, the fair-housing
 * regex) have no money to admit; everything else is priced or refused. */
function freeCatalogRoute(step:Pick<RouteStep,"provider"|"model">&Partial<Pick<RouteStep,"unit_cents">>):boolean {
 return step.unit_cents===0&&(step.provider==="apple"||step.provider==="rendprop");
}

/** Pixel count of a JPEG or PNG carried as a data URL / base64 string, from
 * its header only (SOFn for JPEG, IHDR for PNG). Null when unknown. */
export function imagePixelsFromBase64(value:unknown):number|null {
 if(typeof value!=="string")return null;
 const b64=value.startsWith("data:")?value.slice(value.indexOf(",")+1):value;
 if(b64.length<64)return null;
 let bytes:Uint8Array;
 try{bytes=Uint8Array.from(atob(b64.slice(0,Math.min(b64.length,262144))),c=>c.charCodeAt(0));}catch{return null;}
 if(bytes[0]===0x89&&bytes[1]===0x50&&bytes[2]===0x4e&&bytes[3]===0x47&&bytes.length>=24){
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
  const w=view.getUint32(16),h=view.getUint32(20);return w>0&&h>0?w*h:null;
 }
 if(bytes[0]===0xff&&bytes[1]===0xd8){
  let i=2;
  while(i+9<bytes.length){
   if(bytes[i]!==0xff){i++;continue;}
   const marker=bytes[i+1];
   if(marker===0xd8||marker===0x01||(marker>=0xd0&&marker<=0xd7)){i+=2;continue;}
   const length=(bytes[i+2]<<8)|bytes[i+3];
   if(marker>=0xc0&&marker<=0xcf&&marker!==0xc4&&marker!==0xc8&&marker!==0xcc){
    const h=(bytes[i+5]<<8)|bytes[i+6],w=(bytes[i+7]<<8)|bytes[i+8];return w>0&&h>0?w*h:null;
   }
   if(length<2)return null;
   i+=2+length;
  }
 }
 return null;
}

/** Ceiling mode holds the DOCUMENTED complete bound of the attempt, not the
 * provider's whole context window and not the catalog estimate:
 *  - Gemini image models: Google bills image OUTPUT at a fixed token count per
 *    image (1K = 1120 tokens; ai.google.dev/gemini-api/docs/pricing) and the
 *    request pins imageSize 1K with one candidate; image INPUT is tiled at 258
 *    tokens per 768px tile, so two ≤2048px images plus the prompt stay far
 *    under the 8,192-token input bound used here; text/thinking output is
 *    bounded by maxOutputTokens at the text rate.
 *  - gpt-image-2: $8/M input, $30/M output image tokens (developers.openai.com
 *    pricing, standard tier, the higher of the two published rate cards); a
 *    medium 1536x1024 output is 1,584 tokens; input bounded at 8,192 tokens.
 *  - FLUX.1 [pro] Fill: $0.05 per output megapixel, rounded UP (fal model page);
 *    priced from the input image's own pixel count, else the app's 2048px cap.
 *  - FLUX.1 Kontext [pro]: $0.04 per image (fal model page).
 * Anything else keeps the caller's bounded quote. Returns null when there is
 * no documented bound for this step, which refuses the attempt (see below). */
export function ceilingVerifiedQuote(step:Pick<RouteStep,"provider"|"model">,input:unknown,quote:AttemptQuote|null):AttemptQuote|null {
 const data=input&&typeof input==="object"&&!Array.isArray(input)?input as Record<string,unknown>:{};
 const model=step.model.replace(/^fal-ai\//,"");
 const bound=(cents:number)=>({cents:Math.ceil(cents*10000)/10000,version:"documented-bound-20261008"});
 if(step.provider==="gemini"&&model==="gemini-3.1-flash-image")return bound((8192*0.5+4096*3+1120*60)/10000);
 if(step.provider==="gemini"&&model==="gemini-3.1-flash-lite-image")return bound((8192*0.25+4096*1.5+1120*30)/10000);
 if(step.provider==="openai"&&model==="gpt-image-2")return bound((8192*8+1584*30)/10000);
 if(step.provider==="fal"&&model==="flux-pro/kontext")return bound(4);
 if(step.provider==="fal"&&model==="flux-pro/v1/fill"){
  const pixels=imagePixelsFromBase64(data.image_url)??imagePixelsFromBase64(data.image_b64)??2048*2048;
  return bound(5*Math.max(1,Math.ceil(pixels/1000000)));
 }
 return quote;
}

export async function fundedAttempt<T>(context: FundingContext,stage: string,step: Pick<RouteStep,"provider"|"model">,
 input: unknown,quote: AttemptQuote|null,attempt:()=>Promise<T>): Promise<T> {
 let admittedQuote=quote;
 if(await servingMode()==="ceiling"){
  // Ceiling mode (2026-10-08): every paid attempt — primaries, fallbacks,
  // helpers, judges — reserves money against the workspace's serving envelope
  // before dispatch (serving_cost_reserve → serving_envelope_admit). The hold
  // is the documented complete bound, never below the catalog price the ledger
  // bills; a step with no documented bound is refused unless privately sponsored.
  if(freeCatalogRoute(step)){
   const result=await attempt();
   if(result instanceof Response)throw new HttpError(502,"The generation service did not return a validated receipt.","upstream");
   return result;
  }
  const verified=ceilingVerifiedQuote(step,input,quote);
  const catalog=routeCatalogQuote(step,input);
  if(verified&&catalog&&catalog.cents>verified.cents)admittedQuote={cents:catalog.cents,version:verified.version};
  else admittedQuote=verified;
 }
 try{
 if(!admittedQuote && !await unlimitedSponsored(context))throw new FundingAdmissionError(503,"This operation's complete price could not be verified. No generation was submitted.","upstream");
 // An unpriced private QA attempt is explicitly sponsor expense and never
 // charged to retail/reviewer/trial funds or described as a reconciled cost.
 const admitted=admittedQuote??{cents:1,version:"unpriced-private-sponsorship"};
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
export function textAttemptQuote(step:RouteStep,system:string,turn:string,maxOutputTokens:number,media=false,inputTokens?:number):AttemptQuote|null {
 let inputRate:number,outputRate:number,output:number;
 if(step.provider==="openai"){
  const rates:Record<string,[number,number]>={"gpt-5.6-terra":[2,12],"gpt-5.6-sol":[4,20],"gpt-6-astra":[20,75],"gpt-6.1-sol":[4,15],"gpt-6-sol":[4,20],"gpt-5.6-luna":[.2,1.2]};
  const rate=rates[step.model];if(!rate||(media&&inputTokens===undefined))return null;[inputRate,outputRate]=rate;
  output=openaiChatConfig(paramsOf(step),maxOutputTokens).maxOutputTokens;
 }else if(step.provider==="anthropic"){
  const rates:Record<string,[number,number]>={"claude-sonnet-5":[2,10],"claude-sonnet-5-5":[2,10],"claude-opus-5":[5,25],"claude-haiku-4-5":[1,5]};
  const rate=rates[step.model];if(!rate)return null;[inputRate,outputRate]=rate;output=anthropicMaxTokens(paramsOf(step),maxOutputTokens);
 }else if(step.provider==="gemini"&&step.model==="gemini-3.6-flash"){
  inputRate=1.5;outputRate=7.5;output=65536;
 }else if(step.provider==="gemini"&&step.model==="gemini-3.8-flash"){
  // ai.google.dev/gemini-api/docs/pricing: $0.75/$3.75 through 2026, $1.50/$7.50 from 2027 — hold the higher.
  inputRate=1.5;outputRate=7.5;output=Math.min(65536,Math.max(1,Math.floor(maxOutputTokens)));
 }else if(step.provider==="gemini"&&step.model==="gemini-3.1-flash-lite"){
  // ai.google.dev/gemini-api/docs/pricing: $0.25 input (text/image/video), $1.50 output.
  inputRate=0.25;outputRate=1.5;output=Math.min(65536,Math.max(1,Math.floor(maxOutputTokens)));
 }else return null;
 const bytes=new TextEncoder().encode(system+"\n\n---\n\n"+turn).byteLength;
 if(bytes>100000||!Number.isInteger(output)||output<=0||output>65536)return null;
 // Media calls take the caller's DOCUMENTED input bound (frames x per-image
 // tokens, or seconds x per-second tokens) and otherwise the whole window.
 const tokens=media?(Number.isInteger(inputTokens)&&inputTokens!>0?Math.min(1048576,inputTokens!):1048576):bytes+1024;
 return {cents:(tokens*inputRate+output*outputRate)/10000,version:TARIFF_VERSION};
}

/** Documented input-token bound for a vision call: Anthropic images cost about
 * (width x height) / 750 tokens and are downscaled to ≤1.15 MP (≈1,600 tokens);
 * OpenAI high-detail images are ≤ ~1,600 tokens; Gemini tiles 768px at 258
 * tokens each (a 2048px image ≈ 2,322). 2,048 tokens per image covers all three. */
export function visionInputTokenBound(images:number,textBytes:number):number {
 return Math.max(1,Math.ceil(images))*2048+Math.ceil(Math.max(0,textBytes)/2)+1024;
}
/** Documented input-token bound for a Gemini video call: 263 tokens per second at
 * default media resolution (ai.google.dev/gemini-api/docs/video-understanding). */
export function videoInputTokenBound(seconds:number,textBytes:number):number {
 return Math.ceil(Math.max(1,seconds)*263)+Math.ceil(Math.max(0,textBytes)/2)+1024;
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
