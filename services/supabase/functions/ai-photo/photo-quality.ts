import type { GenerateInput } from "../_shared/providers/types.ts";
import type { RouteStep } from "../_shared/router.ts";
import { paramsOf } from "../_shared/router.ts";
import { HttpError } from "../_shared/http.ts";
import { PHOTO_2K_INPUT_ALLOWANCES, photo2KInputAllowance } from "../_shared/photo-image-quality.ts";
import { validatePhotoInput } from "./input-policy.ts";

/** Preserve submitted bytes.4096 tokens cover an ordinary <=4:1 source;
 * wider/narrower inputs multiply that allowance by ceil(aspect/4). This
 * dominates the documented rough shorter-edge crop/258-token tile estimate.
 * Exact UTF8 prompt bytes and the reference wrapper select a priced tier.
 * Existing masked edits retain their separate legacy route. */
export function preparePhoto2KInput(input: GenerateInput): GenerateInput {
 if(input.mask_url)throw new HttpError(400,"Masked edits use their existing resolution route.","validation");
 const images:[unknown,string][]=[[input.image_b64,String(input.extra?.image_mime??"image/jpeg")]];
 if(input.extra?.staging_reference_b64!==undefined)images.push([input.extra.staging_reference_b64,String(input.extra.staging_reference_mime)]);
 let used=new TextEncoder().encode(input.prompt??"").byteLength;
 for(const [b64,mime]of images){const image=validatePhotoInput(b64,mime);if(Math.max(image.width,image.height)>2048)throw new HttpError(413,"Use a source no larger than 2048 pixels for this 2K edit.","payload_too_large");used+=4096*Math.ceil((Math.max(image.width,image.height)/Math.min(image.width,image.height))/4);}
 if(images.length>1)used+=512;
 const allowance=PHOTO_2K_INPUT_ALLOWANCES.find(cap=>used<=cap);
 if(allowance===undefined)throw new HttpError(413,"This photo and its instructions exceed the verified 2K input bound. No edit was sent.","payload_too_large");
 return {...input,extra:{...input.extra,photo_quality_2k:true,photo_input_token_bound:used,photo_input_allowance:allowance}};
}

/** Preserve all operator/privacy/plan eligibility. Incompatible1K providers
 * are excluded rather than quietly delivered after a failed2K generation. */
export function photo2KChain(steps:RouteStep[],input:GenerateInput):Array<RouteStep & {params:Record<string,unknown>}>{
 const allowance=photo2KInputAllowance(input);
 if(allowance===null)throw new HttpError(503,"The 2K source bound could not be verified. No edit was sent.","upstream");
 const chain=steps.filter(step=>step.provider==="gemini"&&step.model==="gemini-3.1-flash-image").map(step=>({...step,unit:"image",unit_cents:(allowance*.5+4096*3+1680*60)/10000,params:{...paramsOf(step),image_size:"2K"}}));
 if(!chain.length)throw new HttpError(503,"High-resolution photo edits are unavailable on the active route. No lower-resolution edit was sent.","upstream");
 return chain;
}

/** Supplier liability is recorded before this guard. Never persist or report
 * a1K or4K supplier response as the requested 2K image. Review is still manual. */
export function assertPhoto2KOutput(b64:string,mime:string):void{
 const image=validatePhotoInput(b64,mime);
 if(image.width*image.height<3_800_000||image.width*image.height>4_800_000)throw new HttpError(502,"The provider returned an image outside the requested 2K size. That image was not saved as a high-resolution edit.","upstream");
}
