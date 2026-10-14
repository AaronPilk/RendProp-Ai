import type { SupabaseClient, User } from "npm:@supabase/supabase-js@2.116.0";
import { mediaVisibility } from "../_shared/media-source-access.ts";
import { HttpError } from "../_shared/http.ts";
import { PAGE_SIZE, type StudioDependencies, type PhotoEditProof } from "./handler.ts";

export interface StudioRepositoryDependencies {
  userClient(req: Request): SupabaseClient;
  getUser(req: Request): Promise<User>;
  assertNotDeleting(userId: string): Promise<void>;
  activeOrg(orgId: string): Promise<{data: {id:string}|null;error: unknown}>;
  listingScope(userId: string, listingId: string): Promise<{ actor_id: string; org_id: string; library_org_id: string; can_read: boolean }>;
}

/** Keep the real query/authorization adapter testable without credentials or Deno.serve. */
export function createStudioRepository(
  req: Request,
  deps: StudioRepositoryDependencies,
): Pick<StudioDependencies, "authorize" | "read" | "mediaVisibility"> {
  let client: SupabaseClient | undefined;
  const db = () => client ??= deps.userClient(req);
  return {
    mediaVisibility: (scope, refs) => mediaVisibility(db(), scope.listingId, refs),
    async authorize(request, orgId, listingId) {
      const user = await deps.getUser(request);
      await deps.assertNotDeleting(user.id);
      const scope = await deps.listingScope(user.id, listingId);
      const org = scope.org_id;
      if (scope.actor_id !== user.id || !scope.can_read || (org !== orgId && scope.library_org_id !== orgId)) {
        throw new HttpError(403, "Workspace authorization failed.");
      }
      const { data: activeOrg, error: orgError } = await deps.activeOrg(org);
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
          // The native/gallery sort is business state, not a display hint.
          // Apply it before pagination; UUID alone preserves the old order after
          // a successful reorder and puts the wrong photos on later pages.
          .eq("listing_id", scope.listingId).order("sort", { ascending: true })
          .order("id", { ascending: true })
          .range(offset, offset + PAGE_SIZE).abortSignal(req.signal),
        db().from("capture_assets")
          .select(
            "id,listing_id,storage_key,kind,bucket,uploaded,duration_s,created_at",
          )
          .eq("listing_id", scope.listingId).eq("uploaded", true)
          .not("storage_key", "like", "%/contact-%")
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
      // Gallery order and capture UUID order have different page boundaries.
      // Resolve only this bounded capture page's display-key aliases through
      // RLS, including gallery rows on other pages. Distinct untouched originals
      // of altered photos are intentionally retained as source assets.
      const assetKeys = [...new Set(assets.data.filter(asset => asset.kind === "photo" && asset.uploaded).map(asset => asset.storage_key))];
      const photoAssetAliases = new Set<string>();
      if (assetKeys.length) {
        if (assetKeys.length > PAGE_SIZE + 1) throw new HttpError(503, "Media lookup exceeded its page bound.");
        const references = await Promise.all(["original_key", "enhanced_key"].map(column =>
          db().from("photos").select("id,listing_id,original_key,enhanced_key")
            .eq("listing_id", scope.listingId).in(column, assetKeys)
            .limit(501).abortSignal(req.signal)));
        for (const reference of references) {
          if (reference.error || !Array.isArray(reference.data) || reference.data.length > 500 || reference.data.some(row => row.listing_id !== scope.listingId)) throw new HttpError(503, "Gallery references could not be verified.");
          for (const row of reference.data) {
            const visibleKey = row.enhanced_key || row.original_key;
            if (assetKeys.includes(visibleKey)) photoAssetAliases.add(visibleKey);
          }
        }
      }
      const selectedKeys = [...new Set([...photos.data.map(photo => photo.enhanced_key || photo.original_key),
        ...assets.data.filter(asset => asset.kind === "photo").map(asset => asset.storage_key)].filter((key): key is string => typeof key === "string" && key.startsWith(`renders/${scope.orgId}/${scope.listingId}/`)))];
      const photoEdits: Record<string, PhotoEditProof> = {};
      const conflictingEdits = new Set<string>();
      if (selectedKeys.length) {
        const proof = await db().from("media_provenance").select("org_id,listing_id,kind,edit,original_key,altered_key,qc")
          .eq("org_id", scope.orgId).eq("listing_id", scope.listingId).in("altered_key", selectedKeys).limit(205).abortSignal(req.signal);
        if (proof.error || !Array.isArray(proof.data) || proof.data.length > 204 || proof.data.some(row => row.org_id !== scope.orgId || row.listing_id !== scope.listingId || !selectedKeys.includes(row.altered_key))) throw new HttpError(503, "Saved photo history could not be verified.");
        for (const row of proof.data) {
          if (!["photo_edit", "virtual_stage", "declutter"].includes(row.kind) || row.qc?.publishable === false) continue;
          const edit = row.kind === "virtual_stage" ? "stage" : row.kind === "declutter" ? "declutter" : ["declutter", "stage", "sky", "twilight", "lawn", "custom"].includes(row.edit) ? row.edit : null;
          const next = { edit, originalKey: typeof row.original_key === "string" ? row.original_key : null } as PhotoEditProof;
          const previous = photoEdits[row.altered_key];
          // Conflicting legacy records are review-only, never inferred from a caption.
          if (previous && (previous.edit !== next.edit || previous.originalKey !== next.originalKey)) conflictingEdits.add(row.altered_key);
          photoEdits[row.altered_key] = conflictingEdits.has(row.altered_key) ? { edit: null, originalKey: null } : next;
        }
      }
      return {
        photos: photos.data,
        assets: assets.data,
        renders: renders.data,
        photoAssetAliases: [...photoAssetAliases],
        photoEdits,
      };
    },
  };
}
