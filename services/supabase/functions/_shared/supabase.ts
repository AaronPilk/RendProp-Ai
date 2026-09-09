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

import { createClient } from "npm:@supabase/supabase-js@2";
import type { SupabaseClient, User } from "npm:@supabase/supabase-js@2";
import { HttpError } from "./http.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");

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
    requireEnv("SUPABASE_SERVICE_ROLE_KEY", SERVICE_ROLE_KEY),
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  return _admin;
}

/** Per-request client bound to the caller's JWT → RLS applies as that user. */
export function userClient(req: Request): SupabaseClient {
  const authHeader = req.headers.get("Authorization") ?? "";
  return createClient(
    requireEnv("SUPABASE_URL", SUPABASE_URL),
    requireEnv("SUPABASE_ANON_KEY", ANON_KEY),
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

/** True when the caller presented the service-role key as its bearer (worker path). */
export function isServiceRole(req: Request): boolean {
  const token = getBearer(req);
  return !!token && !!SERVICE_ROLE_KEY && token === SERVICE_ROLE_KEY;
}

/** Validate the bearer JWT against Supabase Auth and return the auth user, or 401. */
export async function getUser(req: Request): Promise<User> {
  const token = getBearer(req);
  if (!token) throw new HttpError(401, "Missing Authorization bearer token");
  const { data, error } = await adminClient().auth.getUser(token);
  if (error || !data?.user) throw new HttpError(401, "Invalid or expired token");
  return data.user;
}

// Prefer owner > admin > agent > marketing when a user has multiple memberships.
const ROLE_RANK: Record<string, number> = { owner: 0, admin: 1, agent: 2, marketing: 3 };

/**
 * Resolve the org a user is acting under.
 * If `preferredOrgId` is given (e.g. from an `X-Org-Id` header) we verify the
 * user is a member of it; otherwise we pick their highest-privilege membership.
 * Uses the admin client so it works regardless of the caller's RLS context.
 */
export async function orgForUser(userId: string, preferredOrgId?: string): Promise<string> {
  const admin = adminClient();
  if (preferredOrgId) {
    const { data, error } = await admin
      .from("memberships")
      .select("org_id")
      .eq("user_id", userId)
      .eq("org_id", preferredOrgId)
      .maybeSingle();
    if (error) throw new HttpError(500, `Membership lookup failed: ${error.message}`);
    if (!data) throw new HttpError(403, "Not a member of the requested org");
    return preferredOrgId;
  }

  // The active workspace first (migration 0033). Joining a team no longer
  // deletes the joiner's personal workspace, so a person can hold two
  // memberships — and role rank alone would send an agent back to their own
  // owner-role personal org instead of the team they just joined.
  // active_org_for_user re-checks that the recorded choice is still a real
  // membership in a live org, and falls back to highest privilege, which is
  // also what makes a REMOVED member land somewhere instead of nowhere.
  const { data: active, error: activeErr } = await admin
    .rpc("active_org_for_user", { p_user: userId });
  if (!activeErr && typeof active === "string" && active) return active;

  const { data, error } = await admin
    .from("memberships")
    .select("org_id, role")
    .eq("user_id", userId);
  if (error) throw new HttpError(500, `Membership lookup failed: ${error.message}`);
  if (!data || data.length === 0) throw new HttpError(403, "User has no org membership");

  data.sort((a, b) => (ROLE_RANK[a.role] ?? 9) - (ROLE_RANK[b.role] ?? 9));
  return data[0].org_id as string;
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
