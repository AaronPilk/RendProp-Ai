import type { SupabaseClient, User } from "npm:@supabase/supabase-js@2";
import { HttpError } from "../_shared/http.ts";
import { PAGE_SIZE, type StudioDependencies } from "./handler.ts";

export interface StudioRepositoryDependencies {
  userClient(req: Request): SupabaseClient;
  getUser(req: Request): Promise<User>;
  assertNotDeleting(userId: string): Promise<void>;
  orgForUser(userId: string, preferredOrgId: string): Promise<string>;
}

/** Keep the real query/authorization adapter testable without credentials or Deno.serve. */
export function createStudioRepository(
  req: Request,
  deps: StudioRepositoryDependencies,
): Pick<StudioDependencies, "authorize" | "read"> {
  let client: SupabaseClient | undefined;
  const db = () => client ??= deps.userClient(req);
  return {
    async authorize(request, orgId, listingId) {
      const user = await deps.getUser(request);
      await deps.assertNotDeleting(user.id);
      const org = await deps.orgForUser(user.id, orgId);
      if (org !== orgId) {
        throw new HttpError(403, "Workspace authorization failed.");
      }
      const { data: activeOrg, error: orgError } = await db()
        .from("orgs").select("id").eq("id", org)
        .is("deleted_at", null).abortSignal(req.signal).maybeSingle();
      if (orgError) throw new HttpError(503, "Workspace lookup unavailable.");
      if (!activeOrg) throw new HttpError(404, "Workspace unavailable.");
      const { data: listing, error } = await db()
        .from("listings").select("id,org_id")
        .eq("id", listingId).eq("org_id", org)
        .is("deleted_at", null).abortSignal(req.signal).maybeSingle();
      if (error) throw new HttpError(503, "Listing lookup unavailable.");
      if (!listing) {
        throw new HttpError(404, "Space not found in this workspace.");
      }
      if (
        activeOrg.id !== org || listing.id !== listingId ||
        listing.org_id !== org
      ) {
        throw new HttpError(
          503,
          "Workspace lookup returned inconsistent data.",
        );
      }
      return { userId: user.id, orgId: org, listingId: listing.id };
    },
    async read(scope, offset) {
      const [photos, assets, renders] = await Promise.all([
        db().from("photos")
          .select(
            "id,listing_id,original_key,enhanced_key,caption,is_staged,sort,created_at",
          )
          .eq("listing_id", scope.listingId).order("id", { ascending: true })
          .range(offset, offset + PAGE_SIZE).abortSignal(req.signal),
        db().from("capture_assets")
          .select(
            "id,listing_id,storage_key,kind,bucket,uploaded,duration_s,created_at",
          )
          .eq("listing_id", scope.listingId).eq("uploaded", true)
          .order("id", { ascending: true }).range(offset, offset + PAGE_SIZE)
          .abortSignal(req.signal),
        db().from("renders")
          .select("id,listing_id,video_key,duration_s,created_at")
          .eq("listing_id", scope.listingId).order("id", { ascending: true })
          .range(offset, offset + PAGE_SIZE).abortSignal(req.signal),
      ]);
      if (photos.error || assets.error || renders.error) {
        throw new HttpError(503, "Media lookup unavailable.");
      }
      // A null body is not the same as a valid empty page.
      if (
        !Array.isArray(photos.data) || !Array.isArray(assets.data) ||
        !Array.isArray(renders.data)
      ) {
        throw new HttpError(503, "Media lookup returned inconsistent data.");
      }
      return {
        photos: photos.data,
        assets: assets.data,
        renders: renders.data,
      };
    },
  };
}
