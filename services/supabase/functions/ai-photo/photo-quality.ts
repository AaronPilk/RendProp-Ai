import type { GenerateInput } from "../_shared/providers/types.ts";
import type { RouteStep } from "../_shared/router.ts";
import { paramsOf } from "../_shared/router.ts";
import { HttpError } from "../_shared/http.ts";
import { PHOTO_2K_INPUT_ALLOWANCES, photo2KInputAllowance, photo4KInputAllowance } from "../_shared/photo-image-quality.ts";
import { validatePhotoInput, decodePhotoOutput, type DecodedStillImage } from "./input-policy.ts";
// Conditioned provider inputs, not the immutable original/master upload cap.
export const PHOTO_4K_PREPARED_INPUT_BYTES = 9_000_000;

/** Preserve submitted bytes.4096 tokens cover an ordinary <=4:1 source;
 * wider/narrower inputs multiply that allowance by ceil(aspect/4). This
 * dominates the documented rough shorter-edge crop/258-token tile estimate.
 * Exact UTF8 prompt bytes and the reference wrapper select a priced tier.
 * Existing masked edits retain their separate legacy route. */
export function preparePhoto2KInput(input: GenerateInput): GenerateInput {
 return preparePhotoInput(input,"2K");
}
/** Generate at the provider's real4K size; no local enlargement is performed.
 * The client's existing2048px conditioning cap and original master are retained. */
export function preparePhoto4KInput(input:GenerateInput):GenerateInput {
 return preparePhotoInput(input,"4K");
}
function preparePhotoInput(input:GenerateInput,size:"2K"|"4K"):GenerateInput {
 if(input.mask_url)throw new HttpError(400,"Masked edits use their existing resolution route.","validation");
 const images:[unknown,string][]=[[input.image_b64,String(input.extra?.image_mime??"image/jpeg")]];
 if(input.extra?.staging_reference_b64!==undefined)images.push([input.extra.staging_reference_b64,String(input.extra.staging_reference_mime)]);
 let used=new TextEncoder().encode(input.prompt??"").byteLength,preparedBytes=0;
 for(const [b64,mime]of images){const image=validatePhotoInput(b64,mime);if(Math.max(image.width,image.height)>2048)throw new HttpError(413,`Use a source no larger than 2048 pixels for this ${size} edit.`,"payload_too_large");preparedBytes+=image.bytes;used+=4096*Math.ceil((Math.max(image.width,image.height)/Math.min(image.width,image.height))/4);}
 if(size==="4K"&&preparedBytes>PHOTO_4K_PREPARED_INPUT_BYTES)throw new HttpError(413,"Keep your original photo. Prepare the editing copy and any furniture reference up to 9 MB combined, with a 2048-pixel longest edge. No edit was sent.","payload_too_large",{failure_phase:"prepared_photo_size",no_provider_dispatch:true});
 if(images.length>1)used+=512;
 const allowance=PHOTO_2K_INPUT_ALLOWANCES.find(cap=>used<=cap);
 if(allowance===undefined)throw new HttpError(413,`This photo and its instructions exceed the verified ${size} input bound. No edit was sent.`,"payload_too_large");
 return {...input,extra:{...input.extra,photo_quality_2k:size==="2K",photo_quality_4k:size==="4K",photo_input_token_bound:used,photo_input_allowance:allowance}};
}

/** Preserve all operator/privacy/plan eligibility. Incompatible1K providers
 * are excluded rather than quietly delivered after a failed high-resolution generation. */
export function photo2KChain(steps:RouteStep[],input:GenerateInput):Array<RouteStep & {params:Record<string,unknown>}>{
 return photoChain(steps,input,"2K");
}
export function photo4KChain(steps:RouteStep[],input:GenerateInput):Array<RouteStep & {params:Record<string,unknown>}>{
 return photoChain(steps,input,"4K");
}
function photoChain(steps:RouteStep[],input:GenerateInput,size:"2K"|"4K"):Array<RouteStep & {params:Record<string,unknown>}>{
 const allowance=size==="4K"?photo4KInputAllowance(input):photo2KInputAllowance(input);
 if(allowance===null)throw new HttpError(503,`The ${size} source bound could not be verified. No edit was sent.`,"upstream");
 // Google standard pricing: $0.50/M input, $3/M text/thinking output,
 // $60/M image output;2K=1680 and4K=2520 image tokens (not an invoice).
 const imageTokens=size==="4K"?2520:1680;
 const chain=steps.filter(step=>step.provider==="gemini"&&step.model==="gemini-3.1-flash-image").map(step=>({...step,unit:"image",unit_cents:(allowance*.5+4096*3+imageTokens*60)/10000,params:{...paramsOf(step),image_size:size}}));
 if(!chain.length)throw new HttpError(503,"High-resolution photo edits are unavailable on the active route. No lower-resolution edit was sent.","upstream");
 return chain;
}

/** Supplier liability is recorded before this guard. Never persist or report
 * a1K or4K supplier response as the requested 2K image. Review is still manual. */
export function assertPhoto2KOutput(b64:string,mime:string):void{
 const image=validatePhotoInput(b64,mime);
 if(image.width*image.height<3_800_000||image.width*image.height>4_800_000)throw new HttpError(502,"The provider returned an image outside the requested 2K size. That image was not saved as a high-resolution edit.","upstream");
}

/** Official Gemini3.1 Flash Image4K dimensions for all supported aspects.
 * Allow1% supplier rounding per edge (the live2K portrait was2390 vs2400).
 * Header/container validation establishes dimensions, not visual fidelity.
 * https://ai.google.dev/gemini-api/docs/generate-content/image-generation */
const PHOTO_4K_DIMENSIONS = [[4096,4096],[2048,8192],[8192,2048],[1536,12288],[12288,1536],[3392,5056],[5056,3392],[3584,4800],[4800,3584],[3712,4608],[4608,3712],[3072,5504],[5504,3072],[6336,2688]] as const;
export function assertPhoto4KOutput(b64:string,mime:string):DecodedStillImage {
 const image=decodePhotoOutput(b64,mime);
 assertPhoto4KGeometry(image);
 return image;
}
export function assertPhoto4KGeometry(image:Pick<DecodedStillImage,"width"|"height">):void {
 if(!PHOTO_4K_DIMENSIONS.some(([width,height])=>Math.abs(image.width-width)<=width*.01&&Math.abs(image.height-height)<=height*.01))
  throw new HttpError(502,"The provider returned an image outside the requested 4K size. That image was not saved as a 4K edit.","upstream");
}

/** Pro4K has ten published aspects; Flash-only1:4/1:8 extremes are excluded.
 * https://ai.google.dev/gemini-api/docs/image-generation#aspect_ratios_and_image_size */
const PHOTO_PRO_4K_DIMENSIONS=[[4096,4096],[3392,5056],[5056,3392],[3584,4800],[4800,3584],[3712,4608],[4608,3712],[3072,5504],[5504,3072],[6336,2688]]as const;
export function assertPhotoPro4KGeometry(image:Pick<DecodedStillImage,"width"|"height">):void{
 if(!PHOTO_PRO_4K_DIMENSIONS.some(([width,height])=>Math.abs(image.width-width)<=width*.01&&Math.abs(image.height-height)<=height*.01))
  throw new HttpError(502,"The provider returned an image outside the requested Pro4K size. That comparison was not saved as a verified4K edit.","upstream");
}
