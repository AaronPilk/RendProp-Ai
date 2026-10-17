import type { RouteStep } from "../_shared/router.ts";
import type { GenerateInput } from "../_shared/providers/types.ts";
import { validatePhotoInput } from "./input-policy.ts";

export function isMaskedFillStep(step:Pick<RouteStep,"provider"|"model">):boolean {
 return step.provider==="fal"&&step.model.replace(/^fal-ai\//,"")==="flux-pro/v1/fill";
}
/** FLUX Fill is $0.05 per output megapixel, rounded up, with one image by
 * documented default. The adapter supplies the source and equal-size mask,
 * without a resize override. Use the same source-size liability bound as the
 * existing ceiling quote so a3.15MP edit cannot settle as a flat5-cent image.
 * This remains a conservative catalog bound, not a measured provider invoice.
 * https://fal.ai/models/fal-ai/flux-pro/v1/fill */
export function priceMaskedPhotoChain(steps:RouteStep[],input:GenerateInput):RouteStep[] {
 if(!input.mask_url)return steps;
 const source=validatePhotoInput(input.image_b64,String(input.extra?.image_mime??"image/jpeg"));
 const cents=5*Math.max(1,Math.ceil(source.width*source.height/1_000_000));
 return steps.map(step=>isMaskedFillStep(step)?{...step,unit:"image",unit_cents:cents}:step);
}
