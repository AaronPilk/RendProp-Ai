// photo-feedback edge function: production wiring of handler.ts.
// Deploy with verify_jwt=true (services/supabase/function-jwt-policy.json).
// Contract: docs/handoff/PHOTO-FEEDBACK-DESIGN-20261017.md section 4.
import {adminClient,getUser} from "../_shared/supabase.ts";
import {durableRateLimit} from "../_shared/ratelimit.ts";
import {createPhotoFeedbackHandler} from "./handler.ts";

export const handler=createPhotoFeedbackHandler({
 getUser:async req=>await getUser(req),
 rpc:async(name,args)=>await adminClient().rpc(name,args),
 rateLimit:durableRateLimit,
});
if(import.meta.main)Deno.serve(handler);
