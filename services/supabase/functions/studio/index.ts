// Browser owner media bridge. Same Supabase identity, membership and RLS as iOS;
// no storage key, role, org membership or publication state is accepted from the client.
import { createStudioHandler, PAGE_SIZE } from "./handler.ts";
import {
  getUser,
  orgForUser,
  userClient,
  assertNotDeleting,
  adminClient,
} from "../_shared/supabase.ts";
import { HttpError } from "../_shared/http.ts";
import { presignGet } from "../_shared/providers/common.ts";
import { R2_BUCKET_RENDERS, R2_BUCKET_UPLOADS } from "../_shared/r2.ts";

// Keep request-local RLS client ownership explicit: no global current-user client.
Deno.serve(async (req) => {
  const db = () => userClient(req);
  return await createStudioHandler({
    async authorize(request, orgId, listingId) {
      const user = await getUser(request);
      await assertNotDeleting(user.id);
      const org = await orgForUser(user.id, orgId);
      const { data: listing, error } = await db()
        .from("listings")
        .select("id,org_id")
        .eq("id", listingId)
        .eq("org_id", org)
        .is("deleted_at", null)
        .maybeSingle();
      if (error) throw new HttpError(503, "Listing lookup unavailable.");
      if (!listing)
        throw new HttpError(404, "Space not found in this workspace.");
      const { data: activeOrg, error: orgError } = await db()
        .from("orgs")
        .select("id")
        .eq("id", org)
        .is("deleted_at", null)
        .maybeSingle();
      if (orgError) throw new HttpError(503, "Workspace lookup unavailable.");
      if (!activeOrg) throw new HttpError(404, "Workspace unavailable.");
      return { userId: user.id, orgId: org, listingId: listing.id };
    },
    async rateLimit(scope) {
      const { data, error } = await adminClient().rpc("bump_rate", {
        p_key: `studio-read:${scope.userId}`,
        p_window_seconds: 60,
        p_max: 60,
        p_cost: 1,
      });
      if (error)
        throw new HttpError(503, "Library refresh is temporarily unavailable.");
      return data === true;
    },
    async read(scope, offset) {
      const client = db();
      const [photos, assets, renders] = await Promise.all([
        client
          .from("photos")
          .select(
            "id,listing_id,original_key,enhanced_key,caption,is_staged,sort,created_at",
          )
          .eq("listing_id", scope.listingId)
          .order("id")
          .range(offset, offset + PAGE_SIZE),
        client
          .from("capture_assets")
          .select(
            "id,listing_id,storage_key,kind,bucket,uploaded,duration_s,created_at",
          )
          .eq("listing_id", scope.listingId)
          .eq("uploaded", true)
          .order("id")
          .range(offset, offset + PAGE_SIZE),
        client
          .from("renders")
          .select("id,listing_id,video_key,duration_s,created_at")
          .eq("listing_id", scope.listingId)
          .order("id")
          .range(offset, offset + PAGE_SIZE),
      ]);
      if (photos.error || assets.error || renders.error)
        throw new HttpError(503, "Media lookup unavailable.");
      return {
        photos: photos.data ?? [],
        assets: assets.data ?? [],
        renders: renders.data ?? [],
      };
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
