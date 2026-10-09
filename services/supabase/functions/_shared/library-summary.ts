import { assert, HttpError, throwRpc } from "./http.ts";
import { libraryAccess, listingLibraryScope } from "./library-access.ts";

type Authority = { rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }> };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function rpcError(error: unknown): never {
  const message = error && typeof error === "object" ? (error as { message?: unknown }).message : null;
  if (typeof message === "string" && /RP\d{3}:/.test(message)) throwRpc(message);
  throw new HttpError(503, "Listing library summary could not be verified. Please retry.", "upstream");
}
export interface LibraryUsageSummary {
  actor_id: string; org_id: string; billing_org_id: string;
  listings: number; leads: number; leads_new: number; render_count: number; cost_cents: number;
}
/** Content counts follow the selected library; financial usage follows the
 * immutable billing stamp. Removing a seat cannot reset the old Team's meter. */
export async function libraryUsageSummary(admin: Authority, actor: string, org: string, since: string): Promise<LibraryUsageSummary> {
  const access = await libraryAccess(admin, actor, org);
  const {data, error} = await admin.rpc("library_usage_summary", {p_actor: actor, p_org: org, p_since: since});
  if (error) rpcError(error);
  const row = data as Record<string, unknown> | null;
  assert(row && row.actor_id === actor && row.org_id === org && row.billing_org_id === access.billing_org_id &&
    ["listings", "leads", "leads_new", "render_count"].every(key => Number.isSafeInteger(row[key]) && Number(row[key]) >= 0) &&
    (typeof row.cost_cents === "number" || typeof row.cost_cents === "string" && row.cost_cents.trim() !== "") && Number.isFinite(Number(row.cost_cents)) && Number(row.cost_cents) >= 0, 503, "Listing library usage returned inconsistent data.", "upstream");
  const current = await libraryAccess(admin, actor, org);
  assert(current.billing_org_id === access.billing_org_id, 409, "Team access changed while loading. Refresh your library.");
  return {...row, cost_cents: Number(row.cost_cents)} as unknown as LibraryUsageSummary;
}

export async function libraryProvenance(admin: Authority, actor: string, org: string, options: {from: string | null; to: string | null; listing: string | null; limit: number}): Promise<Array<Record<string, unknown>>> {
  assert(Number.isSafeInteger(options.limit) && options.limit >= 1 && options.limit <= 5001 && (!options.listing || UUID.test(options.listing)), 400, "Choose a bounded disclosure export.");
  await libraryAccess(admin, actor, org);
  const {data, error} = await admin.rpc("list_library_provenance", {p_actor: actor, p_org: org, p_from: options.from, p_to: options.to, p_listing: options.listing, p_limit: options.limit});
  if (error) rpcError(error);
  assert(Array.isArray(data) && data.length <= options.limit, 503, "Disclosure export returned inconsistent data.", "upstream");
  const ids = new Set<string>(), scopes = new Map<string, string>();
  for (const row of data) {
    assert(row && typeof row === "object" && typeof row.id === "string" && UUID.test(row.id) && !ids.has(row.id) && row.library_org_id === org &&
      typeof row.org_id === "string" && UUID.test(row.org_id) && (row.listing_id === null || typeof row.listing_id === "string" && UUID.test(row.listing_id)) &&
      (!options.listing || row.listing_id === options.listing), 503, "Disclosure identities could not be verified.", "upstream");
    if (row.listing_id === null) {
      assert(row.org_id === org && !options.listing,503,"Unassigned disclosure identity is inconsistent."); ids.add(row.id); continue;
    }
    if (!scopes.has(row.listing_id)) {
      const scope = await listingLibraryScope(admin, actor, row.listing_id);
      assert(scope.library_org_id === org, 404, "Disclosure listing is no longer in this library.");
      scopes.set(row.listing_id, scope.org_id);
    }
    assert(scopes.get(row.listing_id) === row.org_id, 503, "Disclosure media and listing identity differ.");
    ids.add(row.id);
  }
  await libraryAccess(admin, actor, org);
  return data;
}
