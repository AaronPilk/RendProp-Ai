// uploads — create a capture_asset + hand back an R2 presigned PUT (owner).
// The app PUTs the file straight to R2, then calls the completion route with
// the probed metadata. Bytes never pass through Supabase.
//
//   POST /uploads                     { listing_id, filename, bytes, sha256, kind }
//                                       -> { asset_id, put_url, storage_key }
//   POST /uploads/:asset_id/complete  { duration_s, fps, width, height, codec, is_drone, has_gyro, sha256? }
//                                       -> asset

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, pathSegments, readJson, respondError } from "../_shared/http.ts";
import { getUser, userClient } from "../_shared/supabase.ts";
import { extFromFilename, presignPut, R2_BUCKET_UPLOADS } from "../_shared/r2.ts";

interface CreateBody {
  listing_id: string;
  filename?: string;
  bytes?: number;
  sha256?: string;
  kind?: "video" | "photo";
}

interface CompleteBody {
  duration_s?: number;
  fps?: number;
  width?: number;
  height?: number;
  codec?: string;
  is_drone?: boolean;
  has_gyro?: boolean;
  sha256?: string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const user = await getUser(req);
    void user; // auth required; row access is enforced by RLS on the user client
    const db = userClient(req);
    const seg = pathSegments(req, "uploads");

    // ---- POST /uploads/:asset_id/complete ----
    if (req.method === "POST" && seg.length === 2 && seg[1] === "complete") {
      const assetId = seg[0];
      const body = await readJson<CompleteBody>(req);
      const patch: Record<string, unknown> = { uploaded: true };
      for (const k of ["duration_s", "fps", "width", "height", "codec", "is_drone", "has_gyro", "sha256"] as const) {
        if (body[k] !== undefined) patch[k] = body[k];
      }
      const { data, error } = await db
        .from("capture_assets")
        .update(patch)
        .eq("id", assetId)
        .select()
        .maybeSingle();
      if (error) throw new HttpError(400, `Complete failed: ${error.message}`);
      if (!data) throw new HttpError(404, "Asset not found");
      return json(data);
    }

    // ---- POST /uploads ----
    if (req.method === "POST" && seg.length === 0) {
      const body = await readJson<CreateBody>(req);
      assert(body.listing_id, 400, "listing_id is required");
      const kind: "video" | "photo" = body.kind === "photo" ? "photo" : "video";

      // Confirm the listing is visible to this user (RLS) and grab its org for the key.
      const { data: listing, error: lErr } = await db
        .from("listings")
        .select("id, org_id")
        .eq("id", body.listing_id)
        .maybeSingle();
      if (lErr) throw new HttpError(400, `Listing lookup failed: ${lErr.message}`);
      if (!listing) throw new HttpError(404, "Listing not found");

      // Generate the asset id up front so it can key the storage path.
      const assetId = crypto.randomUUID();
      const ext = extFromFilename(body.filename, kind);
      const storageKey = `uploads/${listing.org_id}/${listing.id}/${assetId}.${ext}`;

      const { data: asset, error: aErr } = await db
        .from("capture_assets")
        .insert({
          id: assetId,
          listing_id: listing.id,
          kind,
          storage_key: storageKey,
          sha256: body.sha256 ?? null,
          bytes: body.bytes ?? null,
          uploaded: false,
        })
        .select()
        .single();
      if (aErr) throw new HttpError(400, `Asset create failed: ${aErr.message}`);

      const putUrl = await presignPut({ bucket: R2_BUCKET_UPLOADS, key: storageKey, expiresIn: 900 });

      return json({ asset_id: asset.id, put_url: putUrl, storage_key: storageKey }, 201);
    }

    throw new HttpError(405, `Method ${req.method} not allowed on this path`);
  } catch (err) {
    return respondError(err);
  }
});
