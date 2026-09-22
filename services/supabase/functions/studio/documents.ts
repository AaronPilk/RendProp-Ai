import { assert, HttpError, json, readJsonLimited } from "../_shared/http.ts";
import type { StudioContext } from "./context.ts";
export const DOCUMENT_LIMIT = 2 * 1024 * 1024;
const fields = "key,kind,listing_id,revision,payload,updated_at";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function documentKey(value: unknown): string {
  assert(typeof value === "string" && /^(edit|planner|(?:edit|creative|native):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/.test(value), 400, "Choose a valid document.");
  return value;
}
export function documentInput(body: Record<string, unknown>) {
  const key = documentKey(body.key);
  const kind = key.split(":")[0];
  assert(body.kind === kind, 400, "Document type does not match.");
  const listing = body.listing_id ?? null;
  assert(listing === null || (typeof listing === "string" && UUID.test(listing)), 400, "Choose a valid listing.");
  assert(!key.includes(":") || key.split(":")[1] === listing, 400, "Document does not match this listing.");
  assert(Number.isSafeInteger(body.expected_revision) && Number(body.expected_revision) >= 0 && Number(body.expected_revision) < 2147483647, 400, "Document revision is invalid.");
  assert(body.payload && typeof body.payload === "object" && !Array.isArray(body.payload), 400, "Document content must be an object.");
  if (key.startsWith("edit:")) {
    assert((body.payload as Record<string, unknown>).listingId === listing, 400, "This edit belongs to a different listing.");
  }
  assert(new TextEncoder().encode(JSON.stringify(body.payload)).byteLength <= DOCUMENT_LIMIT - 1024, 413, "This draft is too large to sync.");
  return { key, kind, listing_id: listing as string | null, expected: Number(body.expected_revision), payload: body.payload };
}
export async function handleDocuments(req: Request, context: StudioContext): Promise<Response> {
  const { userId, orgId, db, admin } = context;
  if (req.method === "GET") {
    const key = documentKey(new URL(req.url).searchParams.get("key"));
    const { data, error } = await db.from("studio_documents").select(fields)
      .eq("user_id", userId).eq("org_id", orgId).eq("key", key).abortSignal(req.signal).maybeSingle();
    if (error) throw new HttpError(503, "Saved work is temporarily unavailable.");
    return json({ document: data }, 200, { "Cache-Control": "private, no-store" });
  }
  assert(req.method === "POST", 405, "Use Save to update this document.");
  const input = documentInput(await readJsonLimited(req, DOCUMENT_LIMIT));
  if (input.listing_id) await context.authorizeListing(input.listing_id);
  const row = { user_id: userId, org_id: orgId, key: input.key, kind: input.kind,
    listing_id: input.listing_id, revision: input.expected + 1, payload: input.payload, updated_at: new Date().toISOString() };
  const result = input.expected === 0
    ? await admin.from("studio_documents").insert(row).select(fields).abortSignal(req.signal).maybeSingle()
    : await admin.from("studio_documents").update(row).eq("user_id", userId).eq("org_id", orgId)
      .eq("key", input.key).eq("revision", input.expected).select(fields).abortSignal(req.signal).maybeSingle();
  if (result.error?.code === "23505" || (!result.error && !result.data))
    throw new HttpError(409, "This draft changed on another device. Reload its saved version before saving again.");
  if (result.error) throw new HttpError(503, "This draft could not be saved. Your local copy is still available.");
  return json({ document: result.data }, 200, { "Cache-Control": "private, no-store" });
}
