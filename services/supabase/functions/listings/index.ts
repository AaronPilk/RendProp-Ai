// listings — CRUD for listings (owner). RLS-scoped via the caller's JWT.
//
//   POST   /listings            create
//   GET    /listings?status=&space_type=   list (own org, newest first)
//   PATCH  /listings/:id         partial update
//   DELETE /listings/:id         soft delete (sets deleted_at)

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, pathSegments, readJson, respondError } from "../_shared/http.ts";
import { getUser, orgForUser, preferredOrg, userClient } from "../_shared/supabase.ts";

// Columns a client is allowed to set/patch. agent_id/org_id/id/created_at are
// server-controlled and never taken from the body.
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

function pick(body: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const k of WRITABLE) {
    if (body[k] !== undefined) out[k] = body[k];
  }
  return out;
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
      const org_id = await orgForUser(user.id, preferredOrg(req));
      const row = { ...pick(body), org_id, agent_id: user.id };
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
      assert(Object.keys(patch).length > 0, 400, "No writable fields in body");
      const { data, error } = await db
        .from("listings")
        .update(patch)
        .eq("id", id)
        .is("deleted_at", null)
        .select()
        .maybeSingle();
      if (error) throw new HttpError(400, `Update failed: ${error.message}`);
      if (!data) throw new HttpError(404, "Listing not found");
      return json(data);
    }

    // ---- DELETE /listings/:id (soft) ----
    if (req.method === "DELETE" && id) {
      const { data, error } = await db
        .from("listings")
        .update({ deleted_at: new Date().toISOString() })
        .eq("id", id)
        .is("deleted_at", null)
        .select("id")
        .maybeSingle();
      if (error) throw new HttpError(400, `Delete failed: ${error.message}`);
      if (!data) throw new HttpError(404, "Listing not found");
      return json({ ok: true });
    }

    throw new HttpError(405, `Method ${req.method} not allowed on this path`);
  } catch (err) {
    return respondError(err);
  }
});
