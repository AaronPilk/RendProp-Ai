import { HttpError } from "./http.ts";

interface OutputIntent { userId: string; orgId: string; listingId?: string; key: string; bytes: number }
interface Journal { rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }> }

/** Journal the planned canonical object before PUT. A lost PUT response can
 * leave a blob, but cannot leave a blob unknown to listing/account cleanup. */
export async function persistPhotoOutput(
  db: Journal, intent: OutputIntent,
  persist: () => Promise<{ key: string; bytes: number }>,
): Promise<{ key: string; bytes: number }> {
  if (!Number.isSafeInteger(intent.bytes) || intent.bytes <= 0) throw new HttpError(503, "Edited photo could not be stored.");
  const { data, error } = await db.rpc("register_private_ai_output", {
    p_user: intent.userId, p_org: intent.orgId, p_listing: intent.listingId ?? null,
    p_bucket: "renders", p_key: intent.key, p_bytes: intent.bytes,
  });
  const receipt = data as { ok?: unknown; key?: unknown } | null;
  if (error || receipt?.ok !== true || receipt.key !== intent.key) throw new HttpError(503, "Edited photo could not be stored.");
  const stored = await persist();
  if (stored.key !== intent.key || stored.bytes !== intent.bytes) throw new HttpError(503, "Edited photo storage could not be verified.");
  return stored;
}
