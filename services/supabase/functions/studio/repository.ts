import type { SupabaseClient, User } from "npm:@supabase/supabase-js@2.116.0";
import { mediaVisibility } from "../_shared/media-source-access.ts";
import type { PublicationHeadIO } from "../_shared/photo-publication-visibility.ts";
import { HttpError } from "../_shared/http.ts";
import { PAGE_SIZE, type StudioDependencies, type PhotoEditProof } from "./handler.ts";

export interface StudioRepositoryDependencies {
  userClient(req: Request): SupabaseClient;
  adminClient(): SupabaseClient;
  publicationHeadIO?: PublicationHeadIO;
  getUser(req: Request): Promise<User>;
  assertNotDeleting(userId: string): Promise<void>;
  activeOrg(orgId: string): Promise<{data: {id:string}|null;error: unknown}>;
  listingScope(userId: string, listingId: string): Promise<{ actor_id: string; org_id: string; library_org_id: string; can_read: boolean }>;
}

// These are server-reserved namespaces, not ordinary photo filenames. Apply
// exclusions before range/lookahead so internal rows never consume a photo page.
function videoPhotoPatterns(scope: {orgId:string;listingId:string}): string[] {
  return [`uploads/${scope.orgId}/${scope.listingId}/prepared-video/%`,
    `renders/${scope.orgId}/${scope.listingId}/background/%/first-clip.jpg`];
}
function visiblePhotoFilter(scope: {orgId:string;listingId:string}): string {
  const excluded = videoPhotoPatterns(scope);
  const keep = (column:string) => excluded.map(pattern => `${column}.not.like.${pattern}`).join(",");
  // Match the handler's enhanced_key || original_key, including legacy empty
  // enhanced keys and null unavailable rows (which retain their honest error).
  return `and(enhanced_key.not.is.null,enhanced_key.neq.,${keep("enhanced_key")}),` +
    `and(or(enhanced_key.is.null,enhanced_key.eq.),or(original_key.is.null,and(${keep("original_key")})))`;
}

/** Keep the real query/authorization adapter testable without credentials or Deno.serve. */
export function createStudioRepository(
  req: Request,
  deps: StudioRepositoryDependencies,
): Pick<StudioDependencies, "authorize" | "read" | "mediaVisibility"> {
  let client: SupabaseClient | undefined;
  const db = () => client ??= deps.userClient(req);
  return {
    mediaVisibility: (scope, refs) => mediaVisibility(db(), scope.listingId, refs, {
      admissionClient: deps.adminClient(),
      headIO: deps.publicationHeadIO,
    }),
    async authorize(request, orgId, listingId) {
      const user = await deps.getUser(request);
      // These actor checks do not depend on each other. Drain both before
      // advancing; deletion still takes precedence if both reject.
      const [deletion, membership] = await Promise.allSettled([
        deps.assertNotDeleting(user.id),
        deps.listingScope(user.id, listingId),
      ]);
      if (deletion.status === "rejected") throw deletion.reason;
      if (membership.status === "rejected") throw membership.reason;
      const scope = membership.value;
      const org = scope.org_id;
      if (scope.actor_id !== user.id || !scope.can_read || (org !== orgId && scope.library_org_id !== orgId)) {
        throw new HttpError(403, "Workspace authorization failed.");
      }
      // The live workspace and listing reads are independent once the actor's
      // scope is known. Keep workspace failure precedence and require both
      // results before returning an authorized scope.
      const [workspace, scopedListing] = await Promise.allSettled([
        Promise.resolve().then(() => deps.activeOrg(org)),
        Promise.resolve().then(() => db()
          .from("listings").select("id,org_id")
          .eq("id", listingId).eq("org_id", org)
          .is("deleted_at", null).abortSignal(req.signal).maybeSingle()),
      ]);
      if (workspace.status === "rejected") throw workspace.reason;
      const { data: activeOrg, error: orgError } = workspace.value;
      if (orgError) throw new HttpError(503, "Workspace lookup unavailable.");
      if (!activeOrg) throw new HttpError(404, "Workspace unavailable.");
      if (scopedListing.status === "rejected") throw scopedListing.reason;
      const { data: listing, error } = scopedListing.value;
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
    async read(scope, offset, preview) {
      // An ordinary page reads 50 rows of each kind. A preview (Home card) reads
      // `size` rows; with `cover` it reads photos only and the chosen cover.
      const size = preview?.limit ?? PAGE_SIZE, coverFirst = preview?.cover === true;
      const [photos, assets, renders, chosen] = await Promise.all([
        db().from("photos")
          .select(
            "id,listing_id,original_key,enhanced_key,caption,is_staged,sort,created_at",
          )
          // The native/gallery sort is business state, not a display hint.
          // Apply it before pagination; UUID alone preserves the old order after
          // a successful reorder and puts the wrong photos on later pages.
          // Legacy rows share sort 0: attach time, never a random UUID, keeps
          // them in upload order (studio_gallery_update_v2 compares the same).
          .eq("listing_id", scope.listingId).or(visiblePhotoFilter(scope))
          .order("sort", { ascending: true })
          .order("created_at", { ascending: true })
          .order("id", { ascending: true })
          .range(offset, offset + size).abortSignal(req.signal),
        (() => {
          const page = db().from("capture_assets")
            .select(
              "id,listing_id,storage_key,kind,bucket,uploaded,duration_s,created_at",
            )
            .eq("listing_id", scope.listingId).eq("uploaded", true)
            .not("storage_key", "like", "%/contact-%")
            .not("storage_key", "like", videoPhotoPatterns(scope)[0])
            .not("storage_key", "like", videoPhotoPatterns(scope)[1]);
          return (coverFirst ? page.eq("kind", "photo") : page)
            // Source photos follow upload order; UUID only breaks exact ties.
            .order("created_at", { ascending: true }).order("id", { ascending: true }).range(offset, offset + size)
            .abortSignal(req.signal);
        })(),
        // A cover preview shows one picture: it never reads or signs a video.
        coverFirst ? { data: [], error: null } : db().from("renders")
          .select("id,listing_id,video_key,duration_s,created_at")
          .eq("listing_id", scope.listingId).order("id", { ascending: true })
          .range(offset, offset + size).abortSignal(req.signal),
        // The cover is the server's own record, read through the caller's RLS;
        // no storage key is ever accepted from the browser.
        coverFirst ? db().from("listings").select("id,org_id,main_photo_key")
          .eq("id", scope.listingId).eq("org_id", scope.orgId)
          .is("deleted_at", null).abortSignal(req.signal).maybeSingle() : null,
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
      if (chosen) {
        if (chosen.error) throw new HttpError(503, "Media lookup unavailable.");
        const coverKey = chosen.data?.main_photo_key;
        // A chosen cover may sit anywhere in the gallery. Read its own rows and
        // put them first, so one row is enough to show the right picture. Each
        // row is still fenced and re-checked by the handler like any other.
        if (typeof coverKey === "string" && coverKey && coverKey.length <= 1024) {
          const coverPhotos = (column: "enhanced_key" | "original_key") => db().from("photos")
            .select("id,listing_id,original_key,enhanced_key,caption,is_staged,sort,created_at")
            .eq("listing_id", scope.listingId).eq(column, coverKey)
            .order("sort", { ascending: true }).order("created_at", { ascending: true }).order("id", { ascending: true })
            // A source photo can have several saved edits; only the row that
            // shows this exact file is the cover.
            .limit(20).abortSignal(req.signal);
          const [enhanced, original, asset] = await Promise.all([
            coverPhotos("enhanced_key"), coverPhotos("original_key"),
            db().from("capture_assets")
              .select("id,listing_id,storage_key,kind,bucket,uploaded,duration_s,created_at")
              .eq("listing_id", scope.listingId).eq("uploaded", true).eq("kind", "photo").eq("storage_key", coverKey)
              .order("created_at", { ascending: true }).order("id", { ascending: true })
              .limit(1).abortSignal(req.signal),
          ]);
          if (enhanced.error || original.error || asset.error || !Array.isArray(enhanced.data) || !Array.isArray(original.data) || !Array.isArray(asset.data)) {
            throw new HttpError(503, "Media lookup unavailable.");
          }
          // Same rule as the page: a gallery photo shows enhanced_key || original_key.
          const coverPhoto = [...enhanced.data, ...original.data].find(row => (row.enhanced_key || row.original_key) === coverKey);
          const first = <T extends { id: string }>(lead: T | undefined, rows: T[]) =>
            (lead ? [lead, ...rows.filter(row => row.id !== lead.id)] : rows).slice(0, size + 1);
          photos.data = first(coverPhoto, photos.data);
          assets.data = first(asset.data[0], assets.data);
        }
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
