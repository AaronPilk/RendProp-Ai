import { handleOptions } from "../_shared/cors.ts";
import { assert, HttpError, json, pathSegments } from "../_shared/http.ts";

export const PAGE_SIZE = 50;
export const MEDIA_TTL_SECONDS = 600;
export const MAX_CAPTION_CHARS = 4_096;
export type MediaScope = { userId: string; orgId: string; listingId: string };
export type PhotoRow = {
  id: string;
  listing_id: string;
  original_key: string | null;
  enhanced_key: string | null;
  caption: string | null;
  is_staged: boolean;
  sort: number;
  created_at: string;
};
export type AssetRow = {
  id: string;
  listing_id: string;
  storage_key: string;
  kind: string;
  bucket: string;
  uploaded: boolean;
  duration_s: number | null;
  created_at: string;
};
export type RenderRow = {
  id: string;
  listing_id: string;
  video_key: string | null;
  duration_s: number | null;
  created_at: string;
};
export interface StudioDependencies {
  authorize(
    req: Request,
    orgId: string,
    listingId: string,
  ): Promise<MediaScope>;
  rateLimit(scope: MediaScope): Promise<boolean>;
  read(
    scope: MediaScope,
    offset: number,
  ): Promise<{ photos: PhotoRow[]; assets: AssetRow[]; renders: RenderRow[]; photoAssetAliases?: string[] }>;
  sign(
    bucket: "uploads" | "renders",
    key: string,
    seconds: number,
  ): Promise<string>;
  now(): number;
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const headers = {
  "Cache-Control": "private, no-store",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "X-Robots-Tag": "noindex, nofollow",
};

/** Client-editable photo references must not become arbitrary R2 read capabilities.
 * Only a database-linked object in THIS listing's canonical tenant prefix qualifies.
 * AI-router outputs without a trusted listing association are deliberately omitted. */
export function bucketForKey(
  key: unknown,
  scope: Pick<MediaScope, "orgId" | "listingId">,
): "uploads" | "renders" | null {
  if (
    typeof key !== "string" ||
    key.length > 1024 ||
    /[\\%?#\u0000-\u001f]/.test(key)
  ) {
    return null;
  }
  if (
    key
      .split("/")
      .some((segment) => !segment || segment === "." || segment === "..")
  ) {
    return null;
  }
  for (const bucket of ["uploads", "renders"] as const) {
    if (key.startsWith(`${bucket}/${scope.orgId}/${scope.listingId}/`)) {
      return bucket;
    }
  }
  return null;
}

export function createStudioHandler(deps: StudioDependencies) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return handleOptions();
    try {
      assert(req.method === "GET", 405, "Studio media is read-only.");
      const seg = pathSegments(req, "studio");
      assert(
        seg.length === 1 && seg[0] === "media",
        404,
        "Studio route not found.",
      );
      const url = new URL(req.url);
      const orgId = url.searchParams.get("org_id") ?? "";
      const listingId = url.searchParams.get("listing_id") ?? "";
      assert(
        UUID.test(orgId) && UUID.test(listingId),
        400,
        "A valid workspace and listing are required.",
      );
      assert(
        !req.headers.has("x-org-id") || req.headers.get("x-org-id") === orgId,
        400,
        "Workspace selectors disagree.",
      );
      const rawOffset = url.searchParams.get("offset") ?? "0";
      assert(/^(0|[1-9]\d{0,5})$/.test(rawOffset), 400, "Invalid media page.");
      const offset = Number(rawOffset);
      assert(
        offset % PAGE_SIZE === 0 && offset <= 10000,
        400,
        "Invalid media page.",
      );
      const scope = await deps.authorize(req, orgId, listingId);
      assert(
        scope.orgId === orgId && scope.listingId === listingId,
        403,
        "Workspace authorization failed.",
      );
      assert(
        await deps.rateLimit(scope),
        429,
        "Too many library refreshes. Please wait a minute.",
      );
      const rows = await deps.read(scope, offset);
      // Validate the complete page (including its lookahead) before creating
      // even the first capability. A broken query must fail, not be truncated.
      for (const list of [rows.photos, rows.assets, rows.renders]) {
        assert(
          Array.isArray(list) && list.length <= PAGE_SIZE + 1,
          500,
          "Media page exceeded its query bound.",
        );
        assert(
          list.every((row) => row.listing_id === listingId),
          500,
          "Media scope did not match.",
        );
      }
      const photoAssetAliases = new Set(rows.photoAssetAliases ?? []);
      assert(photoAssetAliases.size <= PAGE_SIZE + 1 && [...photoAssetAliases].every(key => bucketForKey(key, scope) !== null), 500, "Media aliases did not match.");
      // User-writable text must not expand a bounded row page into an unbounded
      // browser payload. Reject instead of silently truncating business content.
      assert(rows.photos.every((photo) => photo.caption === null ||
        (typeof photo.caption === "string" && photo.caption.length <= MAX_CAPTION_CHARS)),
        422, "A media caption is too large for Studio. Shorten it in the app and refresh.");
      const more = [rows.photos, rows.assets, rows.renders].some(
        (list) => list.length > PAGE_SIZE,
      );
      assert(
        !(more && offset === 10000),
        422,
        "This space exceeds the Studio library paging limit. Contact support to access the remaining media.",
      );
      const expires_at = new Date(
        deps.now() + MEDIA_TTL_SECONDS * 1000,
      ).toISOString();
      const photos: Record<string, unknown>[] = [],
        videos: Record<string, unknown>[] = [];
      const signed = new Set<string>();
      let unavailable = 0;
      async function sign(
        key: unknown,
        listing: string,
        expectedBucket?: string,
      ): Promise<string | null> {
        assert(listing === listingId, 500, "Media scope did not match.");
        const bucket = bucketForKey(key, scope);
        if (!bucket || (expectedBucket && expectedBucket !== bucket)) {
          unavailable++;
          return null;
        }
        if (signed.has(key as string)) return null;
        signed.add(key as string);
        return await deps.sign(bucket, key as string, MEDIA_TTL_SECONDS);
      }
      // Sequential signing is intentionally bounded (at most 200 objects per page).
      // It does no object download, provider work, mutation, or publication.
      for (const photo of rows.photos.slice(0, PAGE_SIZE)) {
        const url = await sign(
          photo.enhanced_key || photo.original_key,
          photo.listing_id,
        );
        if (url) {
          const originalBucket = bucketForKey(photo.original_key, scope);
          const originalURL = originalBucket && photo.original_key
            ? photo.original_key === (photo.enhanced_key || photo.original_key) ? url
              : await deps.sign(originalBucket, photo.original_key, MEDIA_TTL_SECONDS)
            : null;
          photos.push({
            id: photo.id,
            listing_id: listingId,
            url,
            expires_at,
            caption: photo.caption,
            is_staged: photo.is_staged === true,
            is_altered: photo.is_staged === true || Boolean(photo.enhanced_key && photo.enhanced_key !== photo.original_key),
            original_url: originalURL,
            sort: photo.sort,
          });
        }
      }
      for (const asset of rows.assets.slice(0, PAGE_SIZE)) {
        if (!asset.uploaded || !["photo", "video"].includes(asset.kind)) {
          continue;
        }
        // A reordered gallery row may be on another page than its capture ID.
        // Keep the canonical gallery identity and caption, not a second source
        // card whose only difference is the backing capture UUID.
        if (asset.kind === "photo" && photoAssetAliases.has(asset.storage_key)) continue;
        const url = await sign(
          asset.storage_key,
          asset.listing_id,
          asset.bucket,
        );
        if (!url) continue;
        if (asset.kind === "photo") {
          photos.push({
            id: asset.id,
            listing_id: listingId,
            url,
            expires_at,
            caption: null,
            is_staged: false,
            // Publication assets may already contain an edit. Only capture/original
            // bucket assets can be offered as an unaltered source without provenance.
            is_altered: asset.bucket === "renders",
            original_url: asset.bucket === "uploads" ? url : null,
            sort: 0,
          });
        } else {
          videos.push({
            id: asset.id,
            listing_id: listingId,
            url,
            expires_at,
            kind: "video",
            created_at: asset.created_at,
            duration_s: asset.duration_s,
          });
        }
      }
      for (const render of rows.renders.slice(0, PAGE_SIZE)) {
        if (!render.video_key) {
          unavailable++;
          continue;
        }
        const url = await sign(render.video_key, render.listing_id, "renders");
        if (url) {
          videos.push({
            id: render.id,
            listing_id: listingId,
            url,
            expires_at,
            kind: "video",
            created_at: render.created_at,
            duration_s: render.duration_s,
          });
        }
      }
      // Membership/deletion can change while the page is being read or signed.
      // Recheck live state before releasing any capabilities, never reuse JWT
      // metadata or the initial lookup as a revocation cache.
      const finalScope = await deps.authorize(req, orgId, listingId);
      assert(
        finalScope.userId === scope.userId && finalScope.orgId === orgId &&
          finalScope.listingId === listingId,
        403,
        "Workspace authorization failed.",
      );
      assert(
        deps.now() < Date.parse(expires_at),
        503,
        "Media signing took too long.",
      );
      return json(
        {
          org_id: orgId,
          listing_id: listingId,
          photos,
          videos,
          next_offset: more ? offset + PAGE_SIZE : null,
          unavailable_count: unavailable,
        },
        200,
        headers,
      );
    } catch (error) {
      // Database/provider details may contain object keys or query data; do not echo them.
      const known = error instanceof HttpError && error.status < 500;
      return json(
        {
          error: known
            ? error.message
            : "The media library is temporarily unavailable. Please retry.",
          code: known ? error.code : "upstream",
        },
        error instanceof HttpError ? error.status : 503,
        headers,
      );
    }
  };
}
