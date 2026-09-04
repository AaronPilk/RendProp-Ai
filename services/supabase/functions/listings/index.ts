// listings — CRUD for listings (owner). RLS-scoped via the caller's JWT.
//
//   POST   /listings            create
//   GET    /listings?status=&space_type=   list (own org, newest first)
//   PATCH  /listings/:id         partial update — accepts every WRITABLE column,
//                                including `zillow_url`, `sold_at: null` (un-sell)
//                                and `status` from the DB set (validated, 400 with
//                                the accepted values otherwise — audit F-supabase-13)
//   DELETE /listings/:id         soft delete (sets deleted_at) AND takes the hosted
//                                tour down (renders.published_at = null) — the
//                                0011 trigger does the same, this is belt and braces
//                                (decision A3, audit F-supabase-07)
//
// Errors carry { error, code } (see _shared/http.ts).

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, pathSegments, readJson, respondError } from "../_shared/http.ts";
import { adminClient, assertNotDeleting, getUser, orgForUser, preferredOrg, userClient } from "../_shared/supabase.ts";

// Columns a client is allowed to set/patch. agent_id/org_id/id/created_at are
// server-controlled and never taken from the body. Must stay in sync with the
// column-level UPDATE grant (migrations 0008/0008b) — tests/invariants.sql checks.
const WRITABLE = [
  "space_type",
  "address",
  "tagline",
  "details",
  "beds",
  "baths",
  "sqft",
  "price_cents",
  "zillow_url",
  "main_photo_key",
  "lat",
  "lng",
  "status",
  "sold_at",
  "source",
  "mls_ref",
] as const;

// Exactly the DB check constraint (migration 0011). iOS sends
// draft|uploading|processing|ready|expired; the server additionally knows
// capturing|archived.
const STATUSES = ["draft", "capturing", "uploading", "processing", "ready", "expired", "archived"];
const SPACE_TYPES = ["real_estate", "venue", "restaurant", "retail", "fitness", "other"];
const SOURCES = ["manual", "url", "mls"];
const MAX_DETAILS_BYTES = 16_000;
const MAX_TEXT = 500;

function pick(body: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const k of WRITABLE) {
    if (body[k] !== undefined) out[k] = body[k]; // `null` is a legitimate value (clears the column)
  }
  return out;
}

/** Validate a picked patch/insert. Throws 400 with a precise message. */
function validate(patch: Record<string, unknown>, orgId: string, listingId: string | null) {
  if ("status" in patch) {
    assert(typeof patch.status === "string" && STATUSES.includes(patch.status), 400,
      `status must be one of ${STATUSES.join(", ")}`);
  }
  if ("space_type" in patch) {
    assert(typeof patch.space_type === "string" && SPACE_TYPES.includes(patch.space_type), 400,
      `space_type must be one of ${SPACE_TYPES.join(", ")}`);
  }
  if ("source" in patch) {
    assert(typeof patch.source === "string" && SOURCES.includes(patch.source), 400,
      `source must be one of ${SOURCES.join(", ")}`);
  }
  if ("sold_at" in patch && patch.sold_at !== null) {
    const t = typeof patch.sold_at === "string" ? Date.parse(patch.sold_at) : NaN;
    assert(Number.isFinite(t), 400, "sold_at must be an ISO-8601 timestamp or null");
    patch.sold_at = new Date(t).toISOString();
  }
  if ("zillow_url" in patch && patch.zillow_url !== null) {
    const raw = String(patch.zillow_url ?? "").trim();
    if (raw === "") {
      patch.zillow_url = null;
    } else {
      const withScheme = /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
      let ok = false;
      try {
        const u = new URL(withScheme);
        ok = (u.protocol === "https:" || u.protocol === "http:") && withScheme.length <= MAX_TEXT;
      } catch {
        ok = false;
      }
      assert(ok, 400, "zillow_url must be a valid http(s) URL");
      patch.zillow_url = withScheme;
    }
  }
  for (const k of ["address", "tagline", "mls_ref"] as const) {
    if (k in patch && patch[k] !== null) {
      assert(typeof patch[k] === "string", 400, `${k} must be a string`);
      assert((patch[k] as string).length <= MAX_TEXT, 400, `${k} is too long (max ${MAX_TEXT} chars)`);
    }
  }
  if ("details" in patch && patch.details !== null) {
    assert(typeof patch.details === "object" && !Array.isArray(patch.details), 400, "details must be an object");
    assert(JSON.stringify(patch.details).length <= MAX_DETAILS_BYTES, 400, `details is too large (max ${MAX_DETAILS_BYTES} bytes)`);
  }
  for (const k of ["beds", "sqft", "price_cents"] as const) {
    if (k in patch && patch[k] !== null) {
      const n = Number(patch[k]);
      assert(Number.isInteger(n) && n >= 0, 400, `${k} must be a non-negative integer`);
      patch[k] = n;
    }
  }
  if ("baths" in patch && patch.baths !== null) {
    const n = Number(patch.baths);
    assert(Number.isFinite(n) && n >= 0 && n <= 99, 400, "baths must be a number between 0 and 99");
  }
  for (const k of ["lat", "lng"] as const) {
    if (k in patch && patch[k] !== null) {
      const n = Number(patch[k]);
      const lim = k === "lat" ? 90 : 180;
      assert(Number.isFinite(n) && Math.abs(n) <= lim, 400, `${k} is out of range`);
    }
  }
  // Only keys of this org's own listing may be referenced (audit F-supabase-35).
  if ("main_photo_key" in patch && patch.main_photo_key !== null) {
    const key = String(patch.main_photo_key ?? "");
    const prefixOk = listingId
      ? key.startsWith(`uploads/${orgId}/${listingId}/`) || key.startsWith(`renders/${orgId}/${listingId}/`)
      : key.startsWith(`uploads/${orgId}/`) || key.startsWith(`renders/${orgId}/`);
    assert(prefixOk && key.length <= MAX_TEXT, 400,
      "main_photo_key must be an uploads/ or renders/ key belonging to this listing");
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const user = await getUser(req);
    const db = userClient(req);
    const seg = pathSegments(req, "listings");
    const id = seg[0];

    // ---- POST /listings ----
    if (req.method === "POST" && !id) {
      const body = await readJson<Record<string, unknown>>(req);
      await assertNotDeleting(user.id); // no new listings once deletion starts
      const org_id = await orgForUser(user.id, preferredOrg(req));
      const patch = pick(body);
      validate(patch, org_id, null);
      const row = { ...patch, org_id, agent_id: user.id };
      const { data, error } = await db.from("listings").insert(row).select().single();
      if (error) throw new HttpError(400, `Create failed: ${error.message}`);
      return json(data, 201);
    }

    // ---- GET /listings ----
    if (req.method === "GET" && !id) {
      const url = new URL(req.url);
      let q = db.from("listings").select("*").is("deleted_at", null);
      const status = url.searchParams.get("status");
      const spaceType = url.searchParams.get("space_type");
      if (status) q = q.eq("status", status);
      if (spaceType) q = q.eq("space_type", spaceType);
      const { data, error } = await q.order("created_at", { ascending: false });
      if (error) throw new HttpError(400, `List failed: ${error.message}`);
      return json(data ?? []);
    }

    // ---- PATCH /listings/:id ----
    if (req.method === "PATCH" && id) {
      const body = await readJson<Record<string, unknown>>(req);
      const patch = pick(body);
      assert(Object.keys(patch).length > 0, 400, `No writable fields in body (accepted: ${WRITABLE.join(", ")})`);

      // RLS-scoped read: proves membership and gives the org for key validation.
      const { data: existing, error: eErr } = await db
        .from("listings").select("id, org_id").eq("id", id).is("deleted_at", null).maybeSingle();
      if (eErr) throw new HttpError(400, `Listing lookup failed: ${eErr.message}`);
      if (!existing) throw new HttpError(404, "Listing not found");
      validate(patch, existing.org_id as string, id);

      const { data, error } = await db
        .from("listings")
        .update(patch)
        .eq("id", id)
        .is("deleted_at", null)
        .select()
        .maybeSingle();
      if (error) throw new HttpError(400, `Update failed: ${error.message}`);
      // Readable but not updatable → the RLS update policy (owner/admin/agent)
      // filtered the row: that is a role problem, not a missing listing.
      if (!data) throw new HttpError(403, "Your role does not permit editing listings");
      return json(data);
    }

    // ---- DELETE /listings/:id (soft) ----
    if (req.method === "DELETE" && id) {
      const { data: existing, error: eErr } = await db
        .from("listings").select("id").eq("id", id).is("deleted_at", null).maybeSingle();
      if (eErr) throw new HttpError(400, `Listing lookup failed: ${eErr.message}`);
      if (!existing) throw new HttpError(404, "Listing not found");

      const { data, error } = await db
        .from("listings")
        .update({ deleted_at: new Date().toISOString() })
        .eq("id", id)
        .is("deleted_at", null)
        .select("id")
        .maybeSingle();
      if (error) throw new HttpError(400, `Delete failed: ${error.message}`);
      if (!data) throw new HttpError(403, "Your role does not permit deleting listings");

      // Take the hosted tour down now (service role: tenants can't write
      // renders). The 0011 trigger already did this in the same transaction;
      // running it again is a harmless no-op and covers a DB without 0011.
      const { error: uErr } = await adminClient()
        .from("renders")
        .update({ published_at: null })
        .eq("listing_id", id)
        .not("published_at", "is", null);
      if (uErr) console.error("unpublish after delete failed:", uErr.message);
      return json({ ok: true, unpublished: !uErr });
    }

    throw new HttpError(405, `Method ${req.method} not allowed on this path`);
  } catch (err) {
    return respondError(err);
  }
});
