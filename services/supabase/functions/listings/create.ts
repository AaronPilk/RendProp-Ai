import { HttpError } from "../_shared/http.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Only the explicit per-draft contract opts in; older callers keep their
 * existing create behavior. The server, never the payload, chooses the ID. */
export async function draftListingID(key: string | null, userId: string, orgId: string): Promise<string | null> {
  if (!key?.startsWith("listing-create:")) return null;
  const localId = key.slice("listing-create:".length);
  if (key.length !== 51 || !UUID.test(localId) || !UUID.test(userId) || !UUID.test(orgId))
    throw new HttpError(400, "The listing sync key is invalid.");
  const input = `rendprop:listing-create:v1:${userId.toLowerCase()}:${orgId.toLowerCase()}:${localId.toLowerCase()}`;
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input))).slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x80;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = [...bytes].map((v) => v.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}

/** Caller-scoped client preserves the existing insert/select RLS. A replay
 * reads the saved row; it cannot overwrite office edits or revive deletion. */
export async function createListingRow(db: any, patch: Record<string, unknown>, userId: string, orgId: string, key: string | null) {
  const id = await draftListingID(key, userId, orgId);
  const row = { ...patch, org_id: orgId, agent_id: userId, ...(id ? { id } : {}) };
  const inserted = await db.from("listings").insert(row).select().single();
  if (!inserted.error) return { data: inserted.data, replayed: false };
  if (id && inserted.error.code === "23505") {
    const replay = await db.from("listings").select("*").eq("id", id).eq("org_id", orgId).eq("agent_id", userId).is("deleted_at", null).maybeSingle();
    if (replay.error) throw new HttpError(503, "The saved listing could not be checked. Refresh before trying again.");
    if (!replay.data) throw new HttpError(409, "This listing was deleted or is no longer available. Create a new listing to start again.");
    return { data: replay.data, replayed: true };
  }
  throw new HttpError(400, "The listing could not be created. Check your workspace access and listing details.");
}
