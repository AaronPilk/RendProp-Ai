// One automatic retry of a failed photo generation, on the same route.
//
// Owner decision (12 Nov 2026): a transient provider failure should not cost
// the user a tap and an error. The retry is a second funded attempt under the
// SAME customer charge: the edit quota or credit hold was taken once and is
// settled once, the cost ledger gets one row for the attempt that produced the
// image, and a first attempt whose outcome is uncertain keeps its reservation
// journaled exactly as a failed chain step always has.
import {HttpError} from "../_shared/http.ts";
import {ProviderHttpError,ProviderResponseLimitError,errorClassOf} from "../_shared/providers/common.ts";

/** A second full generation needs about this long before the persist reserve. */
export const PHOTO_RETRY_MIN_REMAINING_MS=45_000;

/** Retry only what a second identical request can plausibly fix: provider 5xx,
 * timeouts, dropped connections and an answer with no image bytes. Never a
 * validation or safety refusal (the same photo would be refused again, and
 * shopping it around is not ours to do), a rate limit (an immediate repeat
 * fails the same way), an oversize reply, one of our own refusals (auth,
 * funding, replay), an explicit owner comparison, a request whose client has
 * gone, or one without the time left to finish. */
export function photoGenerationRetryable(error:unknown,context:{remainingMs:number;clientGone:boolean;ownerComparison:boolean}):boolean{
 if(context.ownerComparison||context.clientGone||!(context.remainingMs>=PHOTO_RETRY_MIN_REMAINING_MS))return false;
 if(error&&typeof error==="object"&&"funding_admission"in error&&error.funding_admission===true)return false;
 if(error instanceof ProviderResponseLimitError)return false;
 const failure=error instanceof ProviderHttpError?error.providerFailure:error;
 if(failure instanceof HttpError)return false;
 const kind=errorClassOf(failure);
 return kind==="upstream"||kind==="timeout"||kind==="other";
}
