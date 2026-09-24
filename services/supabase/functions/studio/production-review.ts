import { assert, HttpError, json, pathSegments, readJsonLimited } from "../_shared/http.ts";
import type { StudioContext } from "./context.ts";
import { handleProductionVersions } from "./production-versions.ts";
import { handleReviewNarration } from "./production-review-narration.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const actions = ["submit", "comment", "request_changes", "approve", "withdraw"];
const headers = {"Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff"};
function scope(input: Record<string, unknown>, userId: string) {
  assert(typeof input.key === "string" && input.key.startsWith("edit:") && UUID.test(input.key.slice(5)), 400, "Choose a saved property reel.");
  const owner = input.document_user_id ?? userId;
  assert(typeof owner === "string" && UUID.test(owner), 400, "Choose a valid reel author.");
  return {key: input.key, owner, listing: input.key.slice(5)};
}
export function reviewInput(input: Record<string, unknown>, userId: string) {
  const binding = scope(input, userId);
  assert(typeof input.action === "string" && actions.includes(input.action), 400, "Choose a review action.");
  for (const [key, min] of [["expected_document_revision", 1], ["expected_review_revision", 0]] as const)
    assert(Number.isSafeInteger(input[key]) && Number(input[key]) >= min && Number(input[key]) < 2147483647, 400, "Refresh saved reel and review revisions before changing them.");
  assert(input.message === undefined || input.message === null || typeof input.message === "string" && input.message.length <= 2000 && !input.message.includes("\0"), 400, "Use a review comment of 2000 characters or fewer.");
  const message = typeof input.message === "string" ? input.message.trim() || null : null;
  assert(!["comment", "request_changes"].includes(input.action) || message, 400, "Add a comment explaining the requested change.");
  const position = input.position_ms ?? null;
  assert(position === null || Number.isSafeInteger(position) && Number(position) >= 0 && Number(position) <= 180000, 400, "Choose a valid reel timestamp.");
  return {...binding, action: input.action, documentRevision: Number(input.expected_document_revision), reviewRevision: Number(input.expected_review_revision), message, position};
}
function rpcError(error: {message?: string} | null) {
  if (!error) return;
  const match = /^RP(400|403|404|409|422): ([^\r\n]{1,240})$/.exec(error.message ?? "");
  throw new HttpError(match ? Number(match[1]) : 503, match ? match[2] : "Production review is temporarily unavailable. Reload before retrying.");
}
/** Review actions are separate from media generation/publication. Explicit
 * version-copy and selected-narration routes enforce their own narrow scopes. */
export async function handleProductionReview(req: Request, context: StudioContext): Promise<Response | null> {
  const version = await handleProductionVersions(req, context);
  if (version) return version;
  const seg = pathSegments(req, "studio");
  if (seg.length === 2 && seg[0] === "production-review" && seg[1] === "narration") return handleReviewNarration(req, context);
  if (seg.length !== 1 || !["production-review", "production-review-queue"].includes(seg[0])) return null;
  const url = new URL(req.url);
  if (seg[0] === "production-review-queue") {
    assert(req.method === "GET", 405, "The review queue is read-only.");
    const listing = url.searchParams.get("listing_id");
    assert(listing === null || UUID.test(listing), 400, "Choose a valid property.");
    const offset = url.searchParams.get("offset") ?? "0";
    assert(/^(0|[1-9][0-9]{0,4})$/.test(offset) && Number(offset) <= 10000 && Number(offset) % 50 === 0, 400, "Choose a valid review queue page.");
    if (listing) await context.authorizeListing(listing);
    const result = await context.admin.rpc("studio_production_review_queue", {
      p_actor: context.userId, p_org_id: context.orgId, p_listing_id: listing, p_offset: Number(offset),
    }).abortSignal(req.signal);
    rpcError(result.error);
    assert(result.data && Array.isArray(result.data.reviews), 503, "Review queue could not be read.");
    return json(result.data, 200, headers);
  }
  assert(req.method === "GET" || req.method === "POST", 405, "Use a review action to update this saved reel.");
  const mutation = req.method === "POST" ? reviewInput(await readJsonLimited(req, 16 * 1024), context.userId) : null;
  const input = mutation ?? scope(Object.fromEntries(url.searchParams), context.userId);
  await context.authorizeListing(input.listing);
  const result = await context.admin.rpc("studio_production_review", {
    p_actor: context.userId, p_org_id: context.orgId, p_document_user_id: input.owner, p_key: input.key,
    p_action: mutation?.action ?? "get", p_expected_document_revision: mutation?.documentRevision ?? null,
    p_expected_review_revision: mutation?.reviewRevision ?? null, p_message: mutation?.message ?? null,
    p_position_ms: mutation?.position ?? null,
  }).abortSignal(req.signal);
  rpcError(result.error);
  assert(result.data?.review && result.data?.permissions, 503, "Production review could not be read.");
  return json(result.data, 200, headers);
}
