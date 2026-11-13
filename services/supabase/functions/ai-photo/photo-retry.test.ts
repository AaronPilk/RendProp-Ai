import {assertEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {HttpError} from "../_shared/http.ts";
import {ProviderError,ProviderHttpError,ProviderResponseLimitError} from "../_shared/providers/common.ts";
import {photoGenerationRetryable,PHOTO_RETRY_MIN_REMAINING_MS} from "./photo-retry.ts";
const ready={remainingMs:PHOTO_RETRY_MIN_REMAINING_MS,clientGone:false,ownerComparison:false};
Deno.test("transient provider failures get one retry; refusals, limits and our own errors never do",()=>{
 for(const error of [new ProviderError("gemini","upstream","Gemini 503",503),new ProviderError("gemini","timeout","timed out"),new ProviderError("gemini","upstream","gemini returned no image bytes"),
  new TypeError("connection reset by peer"),new DOMException("The signal has been aborted","TimeoutError"),
  new ProviderHttpError(new HttpError(502,"Gemini 500","upstream"),new ProviderError("gemini","upstream","Gemini 500",500))])
  assertEquals(photoGenerationRetryable(error,ready),true,String(error));
 for(const error of [new ProviderError("gemini","validation","bad input",400,true),new ProviderError("gemini","nsfw","refused"),new ProviderError("gemini","rate_limit","busy",429,true),
  new ProviderResponseLimitError("gemini",200,35_052_536),new HttpError(403,"The temporary photo comparison authorization ended.","forbidden"),new HttpError(503,"budget","upstream"),
  Object.assign(new Error("funding"),{funding_admission:true})])
  assertEquals(photoGenerationRetryable(error,ready),false,String(error));
});
Deno.test("no retry without time, without a client, or for an explicit owner comparison",()=>{
 const error=new ProviderError("gemini","upstream","Gemini 503",503);
 assertEquals(photoGenerationRetryable(error,{...ready,remainingMs:PHOTO_RETRY_MIN_REMAINING_MS-1}),false);
 assertEquals(photoGenerationRetryable(error,{...ready,remainingMs:Number.NaN}),false);
 assertEquals(photoGenerationRetryable(error,{...ready,clientGone:true}),false);
 assertEquals(photoGenerationRetryable(error,{...ready,ownerComparison:true}),false);
});
