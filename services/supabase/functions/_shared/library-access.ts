import { assert, HttpError, throwRpc } from "./http.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export interface LibraryAccess {
  actor_id: string;
  org_id: string;
  library_owner_user_id: string;
  role: "owner" | "admin" | "agent" | "marketing" | "team_owner";
  access_mode: "own" | "team_owner";
  can_read: boolean;
  can_write: boolean;
  can_manage_subscription: boolean;
  billing_org_id: string;
  team_org_id: string | null;
}
type Authority = { rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }> };
function rpcError(error: unknown): never {
  const message = error && typeof error === "object" ? (error as { message?: unknown }).message : null;
  if (typeof message === "string" && /RP\d{3}:/.test(message)) throwRpc(message);
  throw new HttpError(503, "Listing library access could not be verified. Please retry.", "upstream");
}

/** Never turn a Team relationship into a fabricated content membership. The
 * service-only predicate rechecks the actual owner, binding and deletion state
 * on every call. Billing authority remains distinct from the viewed library. */
export async function libraryAccess(admin: Authority, actor: string, org: string): Promise<LibraryAccess> {
  assert(UUID.test(actor) && UUID.test(org), 400, "Choose a valid listing library.");
  const { data, error } = await admin.rpc("library_access", { p_actor: actor, p_org: org });
  if (error) rpcError(error);
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    throw new HttpError(403, "This listing library is no longer available.", "forbidden");
  }
  const value = data as Record<string, unknown>;
  assert(value.actor_id === actor && value.org_id === org && typeof value.library_owner_user_id === "string" && UUID.test(value.library_owner_user_id) &&
    ["owner", "admin", "agent", "marketing", "team_owner"].includes(String(value.role)) &&
    ["own", "team_owner"].includes(String(value.access_mode)) &&
    typeof value.can_read === "boolean" && typeof value.can_write === "boolean" && typeof value.can_manage_subscription === "boolean" &&
    typeof value.billing_org_id === "string" && UUID.test(value.billing_org_id) &&
    (value.team_org_id === null || typeof value.team_org_id === "string" && UUID.test(value.team_org_id)) &&
    (value.access_mode !== "team_owner" || value.role === "team_owner" && value.can_manage_subscription === false) &&
    (value.access_mode !== "own" || value.library_owner_user_id === actor) &&
    (!value.can_write || value.can_read), 503, "Listing library authority returned inconsistent data.", "upstream");
  assert(value.can_read, 403, "This listing library is no longer available.", "forbidden");
  return value as unknown as LibraryAccess;
}

export async function requireLibraryWrite(admin: Authority, actor: string, org: string): Promise<LibraryAccess> {
  const access = await libraryAccess(admin, actor, org);
  assert(access.can_write, 403, "Your access does not permit editing this listing library.", "forbidden");
  return access;
}

/** Listing scope is required even after library scope: retained legacy Team
 * rows share an org ID, but an invited agent may access only their own rows. */
export async function requireListingAccess(admin: Authority, actor: string, listing: string, write = false): Promise<void> {
  assert(UUID.test(actor) && UUID.test(listing), 400, "Choose a valid listing.");
  const { data, error } = await admin.rpc(write ? "can_write_listing" : "can_read_listing", { p_actor: actor, p_listing: listing });
  if (error) rpcError(error);
  assert(data === true, 404, "This listing is not available in your library.", "not_found");
}

export interface ListingLibraryScope extends LibraryAccess {
  listing_id: string;
  library_org_id: string;
  listing_owner_user_id: string;
}
export async function listingLibraryScope(admin: Authority, actor: string, listing: string, write = false): Promise<ListingLibraryScope> {
  assert(UUID.test(actor) && UUID.test(listing), 400, "Choose a valid listing.");
  const { data, error } = await admin.rpc("listing_library_scope", { p_actor: actor, p_listing: listing });
  if (error) rpcError(error);
  const value = data as ListingLibraryScope | null;
  assert(value && value.actor_id === actor && value.listing_id === listing && typeof value.org_id === "string" && UUID.test(value.org_id) &&
    typeof value.library_org_id === "string" && UUID.test(value.library_org_id) &&
    typeof value.billing_org_id === "string" && UUID.test(value.billing_org_id) &&
    (value.team_org_id === null || typeof value.team_org_id === "string" && UUID.test(value.team_org_id)) &&
    typeof value.library_owner_user_id === "string" && UUID.test(value.library_owner_user_id) &&
    typeof value.listing_owner_user_id === "string" && UUID.test(value.listing_owner_user_id) &&
    typeof value.can_read === "boolean" && typeof value.can_write === "boolean" && typeof value.can_manage_subscription === "boolean" &&
    ["owner", "admin", "agent", "marketing", "team_owner"].includes(value.role) &&
    ["own", "team_owner"].includes(value.access_mode) &&
    (value.access_mode !== "own" || value.library_owner_user_id === actor) &&
    (value.access_mode !== "team_owner" || value.role === "team_owner" && value.can_manage_subscription === false) &&
    (!value.can_write || value.can_read), 503, "Listing identity returned inconsistent data.", "upstream");
  assert(value.can_read, 404, "This listing is not available in your library.", "not_found");
  assert(!write || value.can_write, 403, "Your role does not permit editing this listing.", "forbidden");
  return value;
}
/** An actual Team-org legacy row requires its listing-specific authority. A
 * broad library-role lookup must never convert that exception into access to
 * other agents' records in the same old org. */
export async function requireContentWrite(admin: Authority, actor: string, org: string, listing: string | null): Promise<void> {
  assert(admin && typeof admin.rpc === "function",503,"Listing editing is temporarily unavailable.","upstream");
  if (listing === null) { await requireLibraryWrite(admin, actor, org); return; }
  const scope = await listingLibraryScope(admin, actor, listing, true);
  assert(scope.org_id === org, 404, "Listing and upload library do not match.", "not_found");
}

/** Financial counters are pooled at the subscription's Team org. This is only
 * a trusted billing identity; it never grants access to that org's content. */
export async function libraryBillingOrg(admin: Authority, org: string, actor?: string): Promise<string> {
  assert(UUID.test(org), 400, "Choose a valid listing library.");
  assert(actor === undefined || UUID.test(actor),400,"Sign in to a valid account.");
  const { data, error } = await admin.rpc(actor ? "library_actor_billing_org" : "library_billing_org", actor ? {p_actor:actor,p_org:org} : { p_org: org });
  if (error) rpcError(error);
  assert(typeof data === "string" && UUID.test(data), 503, "Team billing authority could not be verified.", "upstream");
  return data;
}
