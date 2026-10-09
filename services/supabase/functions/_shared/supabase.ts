// Supabase clients + auth helpers.
//
// Two client flavors, and it matters which one you use:
//   adminClient()  -> service role, BYPASSES RLS. Use only on public routes
//                     (tours/leads/beacon) where we manually restrict to a
//                     safe, published subset, or for trusted server ops
//                     (cost ledger writes, membership lookups).
//   userClient(req) -> bound to the caller's JWT, so Postgres RLS runs as that
//                     user. Use for every owner route so a user can only ever
//                     touch their own org's rows.

import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import type { SupabaseClient, User } from "npm:@supabase/supabase-js@2.116.0";
import { HttpError } from "./http.ts";
import { runtimeApiKey, serviceKeyMatches } from "./api-key-config.ts";
import { workspaceDirectory } from "./workspaces.ts";
import { listingLibraryScope, requireLibraryWrite } from "./library-access.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const LEGACY_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const SERVICE_ROLE_KEY = runtimeApiKey(Deno.env.get("SUPABASE_SECRET_KEYS"), Deno.env.get("RENDPROP_SECRET_KEY_NAME") ?? "default", "secret", LEGACY_SERVICE_ROLE_KEY);
const ANON_KEY = runtimeApiKey(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS"), Deno.env.get("RENDPROP_PUBLISHABLE_KEY_NAME") ?? "default", "publishable", Deno.env.get("SUPABASE_ANON_KEY"));

function requireEnv(name: string, value: string | undefined): string {
  if (!value) throw new HttpError(500, `Missing required env var: ${name}`);
  return value;
}

let _admin: SupabaseClient | null = null;

/** Service-role client (bypasses RLS). Cached per instance. */
export function adminClient(): SupabaseClient {
  if (_admin) return _admin;
  _admin = createClient(
    requireEnv("SUPABASE_URL", SUPABASE_URL),
    requireEnv("SUPABASE_SECRET_KEYS", SERVICE_ROLE_KEY),
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  return _admin;
}

/** Per-request client bound to the caller's JWT → RLS applies as that user. */
export function userClient(req: Request): SupabaseClient {
  const authHeader = req.headers.get("Authorization") ?? "";
  return createClient(
    requireEnv("SUPABASE_URL", SUPABASE_URL),
    publicApiKey(),
    {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    },
  );
}

/** Extract the raw bearer token, or null. */
export function getBearer(req: Request): string | null {
  const h = req.headers.get("Authorization");
  if (!h) return null;
  const [scheme, token] = h.split(" ");
  if (scheme?.toLowerCase() !== "bearer" || !token) return null;
  return token.trim();
}

export function publicApiKey(): string { return requireEnv("SUPABASE_PUBLISHABLE_KEYS", ANON_KEY); }

/** Exact server credential, never a caller's unverified JWT role claim. */
export function isServiceRole(req: Request): boolean {
  return serviceKeyMatches(req, SERVICE_ROLE_KEY, LEGACY_SERVICE_ROLE_KEY, Deno.env.get("RENDPROP_LEGACY_SERVICE_AUTH"));
}

/** Validate the bearer JWT against Supabase Auth and return the auth user, or 401. */
export async function getUser(req: Request): Promise<User> {
  const token = getBearer(req);
  if (!token) throw new HttpError(401, "Missing Authorization bearer token");
  const { data, error } = await adminClient().auth.getUser(token);
  if (error || !data?.user) throw new HttpError(401, "Invalid or expired token");
  return data.user;
}

export type PaidAiCaller = Pick<User, "id" | "is_anonymous">;

/**
 * A free allowance cannot be renewed by minting another anonymous account.
 * Use the Auth-validated user and the route's already resolved workspace, before
 * charging a meter. An explicit StoreKit purchase remains usable by its guest
 * owner: only a current, server-bound Apple subscription permits that exception.
 * General getUser() deliberately continues to support anonymous local work.
 */
export async function assertPaidAiIdentity(user: PaidAiCaller, orgId: string): Promise<void> {
  if (user.is_anonymous === false) return;
  // 403, not 401: the public 1.0.3 build treats a repeated 401 as a dead session
  // and signs the guest out, orphaning their workspace. This is a refusal of
  // the action, not of the session.
  const denied = () => new HttpError(403, "Sign in with Apple to use AI tools (Settings → Account), or restore your active subscription.", "forbidden");
  if (user.is_anonymous !== true) throw denied();
  const unavailable = () => new HttpError(503, "Subscription access could not be verified. Please retry.", "upstream");
  // The SQL operation/reservation/result readers use this identical retail
  // predicate. A loose active/grace row cannot admit an unfunded guest first.
  const { data, error } = await adminClient().rpc("org_has_verified_retail_guest", {
    p_actor: user.id, p_org: orgId,
  });
  if (error) throw unavailable();
  if (data !== true) throw denied();
}

/**
 * Resolve a currently authorized content library, including explicit Team-owner
 * delegation. The SQL directory is the authority; raw memberships or a cached
 * selection cannot give an invited agent another member's private library.
 */
export async function orgForUser(userId: string, preferredOrgId?: string): Promise<string> {
  return (await workspaceDirectory(adminClient(), userId, preferredOrgId)).active_org_id;
}

/** Resolve one authorized listing's real storage org without exposing the rest
 * of an old shared Team org. The selected logical library and the row's real
 * org are both accepted only after the fresh listing-specific SQL authority. */
export async function contentOrgForUser(userId: string, preferredOrgId?: string, listingId?: string | null, write = false): Promise<string> {
  if (listingId != null) {
    const scope = await listingLibraryScope(adminClient(), userId, listingId, write);
    if (preferredOrgId && preferredOrgId !== scope.org_id && preferredOrgId !== scope.library_org_id) {
      throw new HttpError(403, "This listing belongs to a different library.", "forbidden");
    }
    return scope.org_id;
  }
  const org = await orgForUser(userId, preferredOrgId);
  if (write) await requireLibraryWrite(adminClient(), userId, org);
  return org;
}

/** Read an optional preferred org from the request header. */
export function preferredOrg(req: Request): string | undefined {
  return req.headers.get("x-org-id") ?? undefined;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * The business type (`listings.space_type`) of one listing, read through the
 * given client — pass `userClient(req)` so RLS limits it to the caller's own
 * org. What the fair-housing gate (_shared/fairhousing.ts) scopes itself on:
 * the LISTING's type, not whatever the request claims.
 *
 * NEVER throws and never blocks a request: a missing/invalid id, a row the
 * caller can't see, or a database error all answer null, and null means the
 * gate falls back to its stricter housing rules.
 */
export async function listingSpaceType(client: SupabaseClient, listingId: unknown): Promise<string | null> {
  if (typeof listingId !== "string" || !UUID_RE.test(listingId.trim())) return null;
  try {
    const { data, error } = await client
      .from("listings")
      .select("space_type")
      .eq("id", listingId.trim())
      .maybeSingle();
    if (error || !data) return null;
    const t = (data as { space_type?: unknown }).space_type;
    return typeof t === "string" && t.trim() ? t.trim() : null;
  } catch {
    return null;
  }
}

/**
 * Refuse writes once account deletion has started for this user.
 *
 * DELETE /me enumerates everything, THEN destroys it. A request that slipped in
 * between could create a listing or upload whose R2 object was never in the
 * tombstone — surviving the deletion as an orphan (audit round 4). Every
 * write-creating route calls this first.
 */
export async function assertNotDeleting(userId: string): Promise<void> {
  const { data, error } = await adminClient()
    .from("deletion_requests")
    .select("id")
    .eq("user_id", userId)
    .in("status", ["pending", "processing"])
    .limit(1)
    .maybeSingle();
  // Fail CLOSED on lookup failure: a write during deletion is worse than a
  // rejected write.
  if (error) throw new HttpError(503, "Account state is being updated — try again shortly");
  if (data) throw new HttpError(409, "This account is being deleted; new content can't be created");
}
