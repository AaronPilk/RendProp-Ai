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
//                                (decision A3, audit F-supabase-07). Build 58: also
//                                opens a 30-day restore window (trash_expires_at);
//                                storage cleanup waits for the window to close.
//   GET    /listings/trash       the selected library's Recently deleted listings
//   POST   /listings/:id/restore undelete within the window; brings the same tour
//                                link back (build 58)
//
// Errors carry { error, code } (see _shared/http.ts).

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, canonicalTimestamps, json, pathSegments, readJson, readJsonLimited, respondError, throwRpc } from "../_shared/http.ts";
import { SPACE_TYPES } from "../_shared/spacetypes.ts";
import { adminClient, assertNotDeleting, getUser, orgForUser, preferredOrg, userClient } from "../_shared/supabase.ts";
import { requestedWorkspace, workspaceDirectory } from "../_shared/workspaces.ts";
import { createListingRow } from "./create.ts";
import { listLibraryListings } from "../_shared/library-listings.ts";
import { listingLibraryScope, requireLibraryWrite } from "../_shared/library-access.ts";
import { clientContact, saveClientContact } from "./client-contact.ts";
import { appendPublishedPhotos, publishedPhotoPatch } from "../_shared/property-cover.ts";
import { publishedGallerySnapshot, removePublishedPhotos } from "./gallery-remove.ts";

/** How long a deleted listing can be restored (build 58). Mirrors the app copy. */
// The 30-day restore window is opened by the trash_listing RPC (build 59);
// the number lives in SQL so the sweep and the route cannot disagree.


// Creation fields; ordinary updates use explicit per-field intent at PUT /:id/facts.
// The legacy PATCH route accepts only the dedicated photo/gallery operations.
// Ownership columns are server controlled.
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
  "gallery_asset_ids",
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
// SPACE_TYPES comes from _shared/spacetypes.ts — the same six values PATCH
// /me/brand accepts for orgs.space_type and the 0044 DB CHECK enforces.
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
function validate(patch: Record<string, unknown>) {
  if ("status" in patch) {
    assert(typeof patch.status === "string" && STATUSES.includes(patch.status), 400,
      `status must be one of ${STATUSES.join(", ")}`);
  }
  if ("space_type" in patch) {
    assert(typeof patch.space_type === "string" && (SPACE_TYPES as readonly string[]).includes(patch.space_type), 400,
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
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const user = await getUser(req);
    const db = userClient(req);
    const seg = pathSegments(req, "listings");
    const id = seg[0];
    // No header keeps the complete cross-workspace snapshot older native sync
    // merges depend on. Explicit selection is validated and never falls back.
    const requested = requestedWorkspace(req);

    // ---- Recently deleted (build 58) ----
    // A trashed listing is invisible to listingLibraryScope on purpose (every
    // live-content predicate refuses it), so these two routes resolve their own
    // authority through the service-only RPCs before the ordinary scope lookup.
    if (seg.length === 1 && id === "trash") {
      assert(req.method === "GET", 405, "Use GET for Recently deleted.");
      assert(requested !== undefined, 409, "Choose a workspace to see Recently deleted.");
      const { data, error } = await adminClient().rpc("list_trashed_listings", { p_actor: user.id, p_org: requested });
      if (error) throwRpc(error.message);
      const value = data as { actor_id?: unknown; org_id?: unknown; listings?: unknown } | null;
      assert(value && value.actor_id === user.id && value.org_id === requested && Array.isArray(value.listings), 503, "Recently deleted returned inconsistent data.", "upstream");
      return json({ org_id: requested, listings: value.listings });
    }
    if (seg.length === 2 && seg[1] === "restore") {
      assert(req.method === "POST", 405, "Use POST to restore a listing.");
      assert(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id), 400, "Choose a valid listing.");
      await assertNotDeleting(user.id);
      const { data, error } = await adminClient().rpc("restore_listing", { p_actor: user.id, p_listing: id });
      if (error) throwRpc(error.message);
      const value = data as Record<string, unknown> | null;
      assert(value && value.ok === true && value.actor_id === user.id && value.listing_id === id && typeof value.org_id === "string" && typeof value.library_org_id === "string", 503, "Listing restore returned inconsistent data.", "upstream");
      if (requested !== undefined) assert(requested === value.org_id || requested === value.library_org_id, 404, "This listing belongs to another library.");
      // The restored row must now answer to the ordinary authority, or the app would show a listing it cannot open.
      const fresh = await listingLibraryScope(adminClient(), user.id, id);
      assert(fresh.org_id === value.org_id, 503, "Listing identity changed during restore.", "upstream");
      return json({
        ok: true, id, org_id: value.org_id, library_org_id: value.library_org_id, address: value.address ?? null,
        republished_renders: Number(value.republished_renders ?? 0), cancelled_client_deliveries: Number(value.cancelled_client_deliveries ?? 0),
        restored_at: value.restored_at ?? null,
      });
    }

    const scope = id ? await listingLibraryScope(adminClient(), user.id, id, req.method !== "GET") : null;
    if (scope && requested !== undefined) assert(requested === scope.org_id || requested === scope.library_org_id, 404, "This listing belongs to another library.");
    const explicitOrg = scope?.org_id ?? (requested === undefined ? undefined :
      (await workspaceDirectory(adminClient(), user.id, requested)).active_org_id);
    const responseListing = async (row: Record<string, unknown>) => {
      assert(typeof row?.id === "string" && typeof row.org_id === "string", 503, "Listing update returned inconsistent data.");
      const fresh = await listingLibraryScope(adminClient(), user.id, row.id);
      assert(fresh.org_id === row.org_id, 503, "Listing identity changed during this request.");
      return {...canonicalTimestamps(row), library_org_id: fresh.library_org_id};
    };

    if (seg.length === 2 && seg[1] === "facts") {
      assert(req.method === "PUT", 405, "Use PUT for listing details.");
      assert(requested !== undefined, 409, "Choose a workspace before saving listing details.");
      assert(explicitOrg, 409, "Choose a workspace before saving listing details.");
      assert(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id), 400, "Choose a valid listing.");
      await assertNotDeleting(user.id);
      const body = await readJsonLimited<Record<string, unknown>>(req, 45000);
      const names = ["expected", "changes", "details_expected", "details_changes"];
      assert(Object.keys(body).length === names.length && names.every(k => Object.hasOwn(body,k)), 400,
        "Send explicit edits with their cached values.");
      for (const name of names) assert(body[name] !== null && typeof body[name] === "object" && !Array.isArray(body[name]), 400,
        "Invalid listing edit.");
      const changes = body.changes as Record<string, unknown>;
      validate(changes);
      const { data, error } = await adminClient().rpc("save_listing_facts", {
        p_actor: user.id, p_org: explicitOrg, p_listing: id,
        p_expected: body.expected, p_changes: changes,
        p_details_expected: body.details_expected, p_details_changes: body.details_changes,
      });
      if (error) {
        if (error.code === "PT409" || error.code === "40001") throw new HttpError(409, "Listing details changed elsewhere. Your edits have been kept. Review both versions before saving.");
        if (error.code === "42501") throw new HttpError(403, "Your role does not permit editing listings.");
        if (error.code === "P0002") throw new HttpError(404, "Listing not found in this workspace.");
        throw new HttpError(400, "These listing edits could not be saved.");
      }
      return json(await responseListing(data));
    }

    if (seg.length === 2 && seg[1] === "measurements") {
      assert(req.method === "PUT", 405, "Use PUT for measurements.");
      assert(requested !== undefined, 409, "Choose a workspace before saving measurements.");
      assert(explicitOrg, 409, "Choose a workspace before saving measurements.");
      assert(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id), 400, "Choose a valid listing.");
      await assertNotDeleting(user.id);
      const body = await readJsonLimited<Record<string, unknown>>(req, 45000);
      assert(Object.keys(body).every(k => ["expected", "value"].includes(k)) && Object.hasOwn(body,"expected"),
        400, "Send only the cached measurement value and the new plan.");
      assert(body.expected === null || (typeof body.expected === "string" && new TextEncoder().encode(body.expected).length <= 10000), 400, "Invalid cached plan.");
      assert(typeof body.value === "string" && new TextEncoder().encode(body.value).length <= 10000,
        400, "Measurements are too large.");
      const {data,error} = await adminClient().rpc("save_listing_measurements", {
        p_actor:user.id,p_org:explicitOrg,p_listing:id,p_expected:body.expected,p_value:body.value,
      });
      if(error) {
        if(error.code==="PT409" || error.code==="40001") throw new HttpError(409,"Measurements changed elsewhere. Your local copy is safe. Reload the shared version before saving again.");
        if(error.code==="42501") throw new HttpError(403,"Your role does not permit editing measurements.");
        if(error.code==="P0002") throw new HttpError(404,"Listing not found in this workspace.");
        throw new HttpError(400,"The measurement plan could not be saved.");
      }
      return json(await responseListing(data));
    }

    if (seg.length === 2 && seg[1] === "client-contact") {
      assert(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id), 400, "Choose a valid listing.");
      const org = explicitOrg ?? await orgForUser(user.id, preferredOrg(req));
      if (req.method === "GET") return json({ contact: await clientContact(adminClient(), user.id, org, id) });
      if (req.method === "PUT") { await assertNotDeleting(user.id); return json({ contact: await saveClientContact(adminClient(), user.id, org, id, await readJsonLimited(req, 6000)) }); }
      throw new HttpError(405, "Use GET or PUT for the client contact.");
    }

    // ---- POST /listings ----
    if (req.method === "POST" && !id) {
      const body = await readJson<Record<string, unknown>>(req);
      await assertNotDeleting(user.id); // no new listings once deletion starts
      const org_id = explicitOrg ?? await orgForUser(user.id, preferredOrg(req));
      const patch = pick(body);
      // A new listing has no uploaded gallery assets yet. Choose its cover
      // after the gallery upload completes, through the scoped PATCH contract.
      assert(!Object.hasOwn(body,"main_photo_asset_id") &&
        !Object.hasOwn(body,"gallery_add_asset_ids") &&
        (patch.main_photo_key === undefined || patch.main_photo_key === null),400,
        "Create the listing and upload its gallery photo before choosing the main photo.");
      if(Object.hasOwn(body,"gallery_asset_ids")) {
        assert(body.gallery_asset_ids===null || (Array.isArray(body.gallery_asset_ids)&&body.gallery_asset_ids.length===0),400,
          "Create the listing and upload its photos before choosing the published gallery.");
      }
      validate(patch);
      const access = await requireLibraryWrite(adminClient(), user.id, org_id);
      const result = await createListingRow(db, patch, user.id, org_id, req.headers.get("Idempotency-Key"), access.library_owner_user_id);
      return json({ ...await responseListing(result.data), create_replayed: result.replayed }, result.replayed ? 200 : 201);
    }

    // ---- GET /listings ----
    if (req.method === "GET" && !id) {
      const url = new URL(req.url);
      if (url.searchParams.get("library") === "1") {
        assert(explicitOrg, 409, "Choose your listing library before syncing.");
        const page = await listLibraryListings(adminClient(), user.id, explicitOrg, url.searchParams);
        return json({ ...page, listings: (page.listings as Record<string, unknown>[]).map(canonicalTimestamps) });
      }
      let q = db.from("listings").select("*").is("deleted_at", null);
      if (explicitOrg) q = q.eq("org_id", explicitOrg);
      const status = url.searchParams.get("status");
      const spaceType = url.searchParams.get("space_type");
      if (status) q = q.eq("status", status);
      if (spaceType) q = q.eq("space_type", spaceType);
      const { data, error } = await q.order("created_at", { ascending: false });
      if (error) throw new HttpError(400, `List failed: ${error.message}`);
      return json((data ?? []).map(canonicalTimestamps));
    }

    if (req.method === "GET" && id && seg.length === 1) {
      if (new URL(req.url).searchParams.get("gallery_selection") === "1") {
        assert(explicitOrg, 409, "Choose your listing library before reviewing its photos.");
        return json(await responseListing(await publishedGallerySnapshot(adminClient(),
          {orgId: explicitOrg, listingId: id}, user.id)), 200, {"cache-control": "no-store"});
      }
      const {data,error} = await db.from("listings").select("*").eq("id",id).is("deleted_at",null).maybeSingle();
      assert(!error,503,"This listing could not be loaded.");
      assert(data,404,"Listing not found in this library.");
      return json(await responseListing(data));
    }

    // ---- PATCH /listings/:id ----
    if (req.method === "PATCH" && id) {
      const body = await readJson<Record<string, unknown>>(req);
      if (Object.keys(body).some(k => k.startsWith("gallery_remove_") || k === "expected_gallery_asset_ids" || k === "expected_main_photo_key")) {
        assert(seg.length === 1, 404, "Choose the listing's photo-removal route.");
        await assertNotDeleting(user.id);
        assert(explicitOrg, 409, "Choose your listing library before removing a photo.");
        return json(await responseListing(await removePublishedPhotos(adminClient(),
          {orgId: explicitOrg, listingId: id}, user.id, body, req.headers.get("Idempotency-Key"))));
      }
      const patch = pick(body);
      assert(Object.keys(patch).every(k => ["main_photo_key", "gallery_asset_ids"].includes(k)), 426,
        "Update Rendprop to sync listing details safely. Your local edits are saved on your phone.");
      assert(Object.keys(patch).length > 0 || Object.hasOwn(body,"main_photo_asset_id") || Object.hasOwn(body,"gallery_add_asset_ids"), 400,
        `No writable fields in body (accepted: ${WRITABLE.join(", ")}, main_photo_asset_id, gallery_add_asset_ids)`);

      // RLS-scoped read: proves membership and gives the org for key validation.
      const { data: existing, error: eErr } = await db
        .from("listings").select("id, org_id, main_photo_key, gallery_asset_ids").eq("id", id).is("deleted_at", null).maybeSingle();
      if (eErr) throw new HttpError(400, `Listing lookup failed: ${eErr.message}`);
      if (!existing || (explicitOrg && existing.org_id !== explicitOrg)) throw new HttpError(404, "Listing not found in this workspace");
      if(Object.hasOwn(body,"gallery_add_asset_ids")) {
        assert(Object.keys(patch).every(k=>k==="main_photo_key"),400,
          "Save listing details separately when adding published photos.");
        await assertNotDeleting(user.id);
        return json(await responseListing(await appendPublishedPhotos(adminClient(),{orgId:existing.org_id as string,listingId:id},user.id,body)));
      }
      if (Object.hasOwn(body,"main_photo_asset_id") || Object.hasOwn(body,"main_photo_key") || Object.hasOwn(body,"gallery_asset_ids")) {
        await assertNotDeleting(user.id);
        Object.assign(patch,await publishedPhotoPatch(adminClient(),{orgId:existing.org_id as string,listingId:id},body,existing));
      }
      validate(patch);

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
      return json(await responseListing(data));
    }

    // ---- DELETE /listings/:id (soft) ----
    if (req.method === "DELETE" && id) {
      const { data: existing, error: eErr } = await db
        .from("listings").select("id, org_id").eq("id", id).is("deleted_at", null).maybeSingle();
      if (eErr) throw new HttpError(400, `Listing lookup failed: ${eErr.message}`);
      if (!existing || (explicitOrg && existing.org_id !== explicitOrg)) throw new HttpError(404, "Listing not found in this workspace");
      await assertNotDeleting(user.id);

      // Build 58 opened a 30-day restore window here with a tenant-client
      // update of deleted_at + trash_expires_at. `authenticated` has no column
      // grant on trash_expires_at, so every delete on TestFlight 58/59 came
      // back "permission denied" (400) and the phone, which fires and forgets
      // this call, showed an empty Recently deleted. Build 59: the window is
      // opened by the service-only trash_listing RPC, which applies the same
      // authority the RLS policy did (listing_content_access, write). The
      // unpublish trigger still takes the tour down at once; storage cleanup is
      // queued when the window closes (listing_trash_sweep).
      const { data, error } = await adminClient().rpc("trash_listing", { p_actor: user.id, p_listing: id });
      if (error) throwRpc(error.message);
      assert(data && typeof data === "object" && (data as Record<string, unknown>).ok === true
        && typeof (data as Record<string, unknown>).restorable_until === "string", 503, "Delete returned inconsistent data.");
      const restorableUntil = new Date((data as Record<string, unknown>).restorable_until as string).toISOString();

      // Take the hosted tour down now (service role: tenants can't write
      // renders). The 0011 trigger already did this in the same transaction;
      // running it again is a harmless no-op and covers a DB without 0011.
      const { error: uErr } = await adminClient()
        .from("renders")
        .update({ published_at: null })
        .eq("listing_id", id)
        .not("published_at", "is", null);
      if (uErr) console.error("unpublish after delete failed:", uErr.message);
      return json({ ok: true, unpublished: !uErr, restorable_until: restorableUntil });
    }

    throw new HttpError(405, `Method ${req.method} not allowed on this path`);
  } catch (err) {
    return respondError(err);
  }
});
