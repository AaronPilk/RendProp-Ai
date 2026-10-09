import { assert, throwRpc } from "./http.ts";
import { libraryAccess } from "./library-access.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export async function listLibraryListings(admin: any, actor: string, org: string, params: URLSearchParams) {
  const integer = (name: string, fallback: number, max: number) => {
    const raw = params.get(name);
    assert(raw === null || /^(?:0|[1-9][0-9]*)$/.test(raw), 400, "Choose a valid listing page.");
    const value = raw === null ? fallback : Number(raw);
    assert(Number.isSafeInteger(value) && value >= (name === "limit" ? 1 : 0) && value <= max, 400, "Choose a bounded listing page.");
    return value;
  };
  assert([...params.keys()].every(key => ["library", "limit", "offset"].includes(key)), 400, "Library sync uses complete, unfiltered listing pages.");
  const limit = integer("limit", 500, 500), offset = integer("offset", 0, 100_000);
  await libraryAccess(admin, actor, org);
  const { data, error } = await admin.rpc("list_library_listings", { p_actor: actor, p_org: org, p_limit: limit, p_offset: offset });
  if (error) throwRpc(error.message);
  assert(data && data.actor_id === actor && Array.isArray(data.listings) && data.listings.length <= limit &&
    Number.isSafeInteger(data.total) && data.total >= 0 && offset + data.listings.length <= Math.max(offset, data.total) &&
    (offset + data.listings.length < data.total
      ? data.listings.length === limit && data.next_offset === offset + data.listings.length
      : data.next_offset === null) &&
    data.listings.every((row: any) => row && typeof row.id === "string" && UUID.test(row.id) && typeof row.org_id === "string" && UUID.test(row.org_id) &&
      row.library_org_id === org && typeof row.agent_id === "string" && UUID.test(row.agent_id) && row.deleted_at === null) &&
    new Set(data.listings.map((row: any) => row.id)).size === data.listings.length,
    503, "Listing library sync returned inconsistent data.", "upstream");
  await libraryAccess(admin, actor, org);
  return data;
}
