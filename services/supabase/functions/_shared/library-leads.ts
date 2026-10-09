import { assert, HttpError, throwRpc } from "./http.ts";
import { libraryAccess, listingLibraryScope, type ListingLibraryScope } from "./library-access.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Authority = { rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }> };
function rpcError(error: unknown): never {
  const message = error && typeof error === "object" ? (error as { message?: unknown }).message : null;
  if (typeof message === "string" && /RP\d{3}:/.test(message)) throwRpc(message);
  throw new HttpError(503, "Inquiries could not be verified. Please retry.", "upstream");
}

/** Preserve the stored lead org ID. A logical library is a grouping authority,
 * never a new owner for a historic inquiry or its delivery receipt. */
export async function leadLibraryScope(admin: Authority, actor: string, lead: string, selected: string | null | undefined, write = false): Promise<ListingLibraryScope> {
  assert(UUID.test(actor) && UUID.test(lead), 400, "Choose a valid inquiry.");
  const {data, error} = await admin.rpc("lead_library_scope", {p_actor: actor, p_lead: lead});
  if (error) rpcError(error);
  const row = data as Record<string, unknown> | null;
  assert(row && row.actor_id === actor && row.lead_id === lead && typeof row.listing_id === "string" && UUID.test(row.listing_id), 503, "Inquiry identity returned inconsistent data.", "upstream");
  const scope = await listingLibraryScope(admin, actor, row.listing_id, write);
  assert(row.org_id === scope.org_id && row.library_org_id === scope.library_org_id, 503, "Inquiry and listing identity do not match.", "upstream");
  assert(selected == null || selected === scope.org_id || selected === scope.library_org_id, 404, "Inquiry not found in this listing library.", "not_found");
  return scope;
}

export async function listLibraryLeads(admin: Authority, actor: string, org: string, options: {limit: number; since: string | null; status: string | null; listing: string | null}): Promise<Array<Record<string, unknown>>> {
  assert(Number.isSafeInteger(options.limit) && options.limit >= 1 && options.limit <= 500 && (options.listing === null || UUID.test(options.listing)), 400, "Choose a bounded inquiry list.");
  await libraryAccess(admin, actor, org);
  const {data, error} = await admin.rpc("list_library_leads", {p_actor: actor, p_org: org, p_limit: options.limit, p_since: options.since, p_status: options.status, p_listing: options.listing});
  if (error) rpcError(error);
  assert(Array.isArray(data) && data.length <= options.limit, 503, "Inquiry list returned inconsistent data.", "upstream");
  const ids = new Set<string>();
  for (const row of data) {
    assert(row && typeof row === "object" && typeof row.id === "string" && UUID.test(row.id) && !ids.has(row.id) &&
      typeof row.listing_id === "string" && UUID.test(row.listing_id) && typeof row.org_id === "string" && UUID.test(row.org_id) &&
      row.library_org_id === org && (!options.listing || row.listing_id === options.listing), 503, "Inquiry list returned inconsistent identities.", "upstream");
    ids.add(row.id);
  }
  // Revocation while the query is in flight must not return a cached library.
  await libraryAccess(admin, actor, org);
  return data;
}

export async function libraryListingIds(admin: Authority, actor: string, org: string): Promise<string[]> {
  await libraryAccess(admin, actor, org);
  const {data, error} = await admin.rpc("library_listing_ids", {p_actor: actor, p_org: org});
  if (error) rpcError(error);
  assert(Array.isArray(data) && data.length <= 100000 && data.every(id => typeof id === "string" && UUID.test(id)) && new Set(data).size === data.length, 503, "Listing export scope could not be verified.", "upstream");
  await libraryAccess(admin, actor, org);
  return data;
}
