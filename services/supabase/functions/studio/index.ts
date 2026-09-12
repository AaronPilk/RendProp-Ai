// Browser owner media bridge. Same Supabase identity, membership and RLS as iOS;
// no storage key, role, org membership or publication state is accepted from the client.
import { createStudioHandler } from "./handler.ts";
import { createStudioRepository } from "./repository.ts";
import {
  adminClient,
  assertNotDeleting,
  getUser,
  orgForUser,
  userClient,
} from "../_shared/supabase.ts";
import { HttpError } from "../_shared/http.ts";
import { presignGet } from "../_shared/providers/common.ts";
import { R2_BUCKET_RENDERS, R2_BUCKET_UPLOADS } from "../_shared/r2.ts";

// Keep request-local RLS client ownership explicit: no global current-user client.
Deno.serve(async (req) => {
  return await createStudioHandler({
    ...createStudioRepository(req, {
      getUser,
      assertNotDeleting,
      orgForUser,
      userClient,
    }),
    async rateLimit(scope) {
      const { data, error } = await adminClient().rpc("bump_rate", {
        p_key: `studio-read:${scope.userId}`,
        p_window_seconds: 60,
        p_max: 60,
        p_cost: 1,
      });
      if (error) {
        throw new HttpError(503, "Library refresh is temporarily unavailable.");
      }
      return data === true;
    },
    sign: (bucket, key, seconds) =>
      presignGet(
        bucket === "uploads" ? R2_BUCKET_UPLOADS : R2_BUCKET_RENDERS,
        key,
        seconds,
      ),
    now: () => Date.now(),
  })(req);
});
