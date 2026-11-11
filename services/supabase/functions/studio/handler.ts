import type { MediaSourceRefs, MediaVisibility } from "../_shared/media-source-access.ts";
import { handleOptions } from "../_shared/cors.ts";
import { assert, HttpError, json, pathSegments } from "../_shared/http.ts";

export const PAGE_SIZE = 50;
export const MEDIA_TTL_SECONDS = 600;
export const MAX_CAPTION_CHARS = 4_096;
export type MediaScope = { userId: string; orgId: string; listingId: string };
export type StudioMediaTiming = {
  event: "studio_media_timing";
  status: number;
  total_ms: number;
  authorize_initial_ms?: number;
  rate_limit_ms?: number;
  read_ms?: number;
  visibility_initial_ms?: number;
  signing_ms?: number;
  sign_calls?: number;
  unavailable_count?: number;
  photo_count?: number;
  video_count?: number;
  authorize_final_ms?: number;
  visibility_final_ms?: number;
  signing_policy_final_ms?: number;
};
export type PhotoEditKind = "declutter" | "stage" | "sky" | "twilight" | "lawn" | "custom";
export type PhotoEditProof = { edit: PhotoEditKind | null; originalKey: string | null };
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
  ): Promise<{ photos: PhotoRow[]; assets: AssetRow[]; renders: RenderRow[]; photoAssetAliases?: string[]; photoEdits?: Record<string, PhotoEditProof> }>;
  mediaVisibility(scope: MediaScope, refs: MediaSourceRefs): Promise<MediaVisibility>;
  sign(
    bucket: "uploads" | "renders",
    key: string,
    seconds: number,
    scope: MediaScope,
  ): Promise<string>;
  assertSigningPolicyFresh(): Promise<void>;
  now(): number;
  observeTiming?(timing: StudioMediaTiming): void;
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

/** Server-reserved video working copies/posters are not property photographs.
 * Keep untouched capture originals, gallery uploads and saved edits; never
 * infer a room/photo identity from captions or from the renders bucket alone. */
export function internalVideoPhoto(key: string, scope: MediaScope): boolean {
  const root = `${scope.orgId}/${scope.listingId}/`;
  const uuid = "[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}";
  return new RegExp(`^uploads/${root}prepared-video/${uuid}/${uuid}\\.jpg$`).test(key) ||
    new RegExp(`^renders/${root}background/${uuid}/${uuid}/first-clip\\.jpg$`).test(key);
}

export function createStudioHandler(deps: StudioDependencies) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return handleOptions();
    const started = performance.now();
    const phases: Partial<Omit<StudioMediaTiming, "event" | "status" | "total_ms">> = {};
    const elapsed = (at: number) => Math.max(0, Math.round(performance.now() - at));
    async function measured<T>(phase: keyof typeof phases, work: () => Promise<T>): Promise<T> {
      const at = performance.now();
      try { return await work(); }
      finally { phases[phase] = elapsed(at); }
    }
    function complete(response: Response): Response {
      // Diagnostic values and fixed field names only. Never log account, media,
      // request URL, token, or storage identity. Observation cannot alter serving.
      try { deps.observeTiming?.({ event: "studio_media_timing", status: response.status, total_ms: elapsed(started), ...phases }); }
      catch { /* Observability must not break media reads. */ }
      return response;
    }
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
      const scope = await measured("authorize_initial_ms", () => deps.authorize(req, orgId, listingId));
      assert(
        scope.orgId === orgId && scope.listingId === listingId,
        403,
        "Workspace authorization failed.",
      );
      assert(
        await measured("rate_limit_ms", () => deps.rateLimit(scope)),
        429,
        "Too many library refreshes. Please wait a minute.",
      );
      const rows = await measured("read_ms", () => deps.read(scope, offset));
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
      const pagePhotos = rows.photos.slice(0, PAGE_SIZE), pageAssets = rows.assets.slice(0, PAGE_SIZE), pageRenders = rows.renders.slice(0, PAGE_SIZE);
      const access = await measured("visibility_initial_ms", () => deps.mediaVisibility(scope, {
        assets: pageAssets.map(row => row.id), renders: pageRenders.map(row => row.id),
        keys: [...pagePhotos.flatMap(row => [row.original_key, row.enhanced_key]), ...pageAssets.map(row => row.storage_key), ...pageRenders.map(row => row.video_key)]
          .filter((key): key is string => bucketForKey(key, scope) !== null),
      }));
      const usedAssets: string[] = [], usedRenders: string[] = [];
      const expires_at = new Date(
        deps.now() + MEDIA_TTL_SECONDS * 1000,
      ).toISOString();
      const photos: Record<string, unknown>[] = [],
        videos: Record<string, unknown>[] = [];
      const signed = new Set<string>(), exposedKeys = new Set<string>();
      const signJobs: { bucket: "uploads" | "renders"; key: string; original?: { bucket: "uploads" | "renders"; key: string } }[] = [];
      let unavailable = 0;
      const queueSign = (bucket: "uploads" | "renders", key: string): number => signJobs.push({ bucket, key }) - 1;
      function sign(
        key: unknown,
        listing: string,
        expectedBucket?: string,
      ): number | null {
        assert(listing === listingId, 500, "Media scope did not match.");
        const bucket = bucketForKey(key, scope);
        if (!bucket || (expectedBucket && expectedBucket !== bucket)) {
          unavailable++;
          return null;
        }
        if (access.keys[key as string] !== true) { unavailable++; return null; }
        if (signed.has(key as string)) return null;
        signed.add(key as string);
        exposedKeys.add(key as string);
        return queueSign(bucket, key as string);
      }
      const photoPlans: { row: PhotoRow; urlJob: number; originalSource: "same" | "secondary" | null }[] = [];
      for (const photo of pagePhotos) {
        if (internalVideoPhoto(photo.enhanced_key || photo.original_key || "", scope)) continue;
        const urlJob = sign(
          photo.enhanced_key || photo.original_key,
          photo.listing_id,
        );
        if (urlJob !== null) {
          const originalBucket = bucketForKey(photo.original_key, scope);
          const originalSource = originalBucket && photo.original_key && access.keys[photo.original_key] === true
            ? photo.original_key === (photo.enhanced_key || photo.original_key) ? "same"
              : "secondary"
            : null;
          if (originalSource === "secondary" && originalBucket && photo.original_key) {
            signJobs[urlJob].original = { bucket: originalBucket, key: photo.original_key };
          }
          photoPlans.push({ row: photo, urlJob, originalSource });
        }
      }
      const assetPlans: { row: AssetRow; urlJob: number }[] = [];
      for (const asset of pageAssets) {
        if (/\/contact-[^/]+$/.test(asset.storage_key)) continue;
        if (access.assets[asset.id] !== true) { unavailable++; continue; }
        if (!asset.uploaded || !["photo", "video"].includes(asset.kind)) {
          continue;
        }
        // A reordered gallery row may be on another page than its capture ID.
        // Keep the canonical gallery identity and caption, not a second source
        // card whose only difference is the backing capture UUID.
        if (asset.kind === "photo" && photoAssetAliases.has(asset.storage_key)) continue;
        if (asset.kind === "photo" && internalVideoPhoto(asset.storage_key, scope)) continue;
        const urlJob = sign(
          asset.storage_key,
          asset.listing_id,
          asset.bucket,
        );
        if (urlJob !== null) assetPlans.push({ row: asset, urlJob });
      }
      const renderPlans: { row: RenderRow; urlJob: number }[] = [];
      for (const render of pageRenders) {
        if (access.renders[render.id] !== true) { unavailable++; continue; }
        if (!render.video_key) {
          unavailable++;
          continue;
        }
        const urlJob = sign(render.video_key, render.listing_id, "renders");
        if (urlJob !== null) renderPlans.push({ row: render, urlJob });
      }
      // Every job was admitted by the listing and visibility checks above.
      // Bound independent URL signing calls, then assemble in original row order.
      // A failure drains in-flight work before the generic error response; no
      // capability is released without the final membership and source fence.
      const urls = signJobs.length ? await measured("signing_ms", async () => {
        const results = new Array<{ url: string; originalURL: string | null }>(signJobs.length);
        let next = 0;
        let failure: unknown, failed = false;
        await Promise.all(Array.from({ length: Math.min(4, signJobs.length) }, async () => {
          while (!failed) {
            const index = next++;
            if (index >= signJobs.length) return;
            const job = signJobs[index];
            try {
              phases.sign_calls = (phases.sign_calls ?? 0) + 1;
              const url = await deps.sign(job.bucket, job.key, MEDIA_TTL_SECONDS, scope);
              let originalURL: string | null = null;
              if (url && job.original) {
                phases.sign_calls = (phases.sign_calls ?? 0) + 1;
                originalURL = await deps.sign(job.original.bucket, job.original.key, MEDIA_TTL_SECONDS, scope);
              }
              results[index] = { url, originalURL };
            } catch (error) { failure = error; failed = true; return; }
          }
        }));
        if (failed) throw failure;
        return results;
      }) : [];
      for (const { row: photo, urlJob, originalSource } of photoPlans) {
        const url = urls[urlJob].url;
        if (!url) continue;
        const originalURL = originalSource === "same" ? url : originalSource === "secondary" ? urls[urlJob].originalURL : null;
        if (originalURL && photo.original_key) exposedKeys.add(photo.original_key);
        photos.push({
          id: photo.id,
          listing_id: listingId,
          url,
          expires_at,
          caption: photo.caption,
          is_staged: photo.is_staged === true,
          is_altered: photo.is_staged === true || Boolean(photo.enhanced_key && photo.enhanced_key !== photo.original_key),
          original_url: originalURL,
          edit_kind: rows.photoEdits?.[photo.enhanced_key || photo.original_key || ""]?.edit ?? null,
          original_verified: !!originalURL && rows.photoEdits?.[photo.enhanced_key || photo.original_key || ""]?.originalKey === photo.original_key,
          sort: photo.sort,
        });
      }
      for (const { row: asset, urlJob } of assetPlans) {
        const url = urls[urlJob].url;
        if (!url) continue;
        usedAssets.push(asset.id);
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
            edit_kind: rows.photoEdits?.[asset.storage_key]?.edit ?? null,
            original_verified: false,
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
      for (const { row: render, urlJob } of renderPlans) {
        const url = urls[urlJob].url;
        if (!url) continue;
        usedRenders.push(render.id);
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
      // Membership/deletion can change while the page is being read or signed.
      // Recheck live state before releasing any capabilities, never reuse JWT
      // metadata or the initial lookup as a revocation cache.
      const finalScope = await measured("authorize_final_ms", () => deps.authorize(req, orgId, listingId));
      assert(
        finalScope.userId === scope.userId && finalScope.orgId === orgId &&
          finalScope.listingId === listingId,
        403,
        "Workspace authorization failed.",
      );
      const finalAccess = await measured("visibility_final_ms", () => deps.mediaVisibility(scope, { assets: usedAssets, renders: usedRenders, keys: [...exposedKeys] }));
      assert(usedAssets.every(id => finalAccess.assets[id] === true) && usedRenders.every(id => finalAccess.renders[id] === true) && [...exposedKeys].every(key => finalAccess.keys[key] === true), 404, "Media access changed. Refresh the library.");
      await measured("signing_policy_final_ms", () => deps.assertSigningPolicyFresh());
      assert(
        deps.now() < Date.parse(expires_at),
        503,
        "Media signing took too long.",
      );
      phases.unavailable_count = unavailable;
      phases.photo_count = photos.length;
      phases.video_count = videos.length;
      return complete(json(
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
      ));
    } catch (error) {
      // Database/provider details may contain object keys or query data; do not echo them.
      const known = error instanceof HttpError && error.status < 500;
      return complete(json(
        {
          error: known
            ? error.message
            : "The media library is temporarily unavailable. Please retry.",
          code: known ? error.code : "upstream",
        },
        error instanceof HttpError ? error.status : 503,
        headers,
      ));
    }
  };
}
