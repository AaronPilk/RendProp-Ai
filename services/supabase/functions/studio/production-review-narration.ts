import { assert, HttpError, json, readJsonLimited } from "../_shared/http.ts";
import { presignGet } from "../_shared/providers/common.ts";
import { R2_BUCKET_UPLOADS } from "../_shared/r2.ts";
import type { StudioContext } from "./context.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** A submitted reel grants access only to its selected, completed narration.
 * It never grants access to the author's creative-history inventory. */
export async function handleReviewNarration(req: Request, context: StudioContext, sign = presignGet) {
  assert(req.method === "POST", 405, "Request the narration selected in this review.");
  const input = await readJsonLimited(req, 4096);
  assert(typeof input.key === "string" && input.key.startsWith("edit:") && UUID.test(input.key.slice(5)), 400, "Choose a saved property reel.");
  const owner = input.document_user_id ?? context.userId;
  assert(typeof owner === "string" && UUID.test(owner) && typeof input.result_id === "string" && UUID.test(input.result_id), 400, "Choose a valid reel author and narration.");
  assert(Number.isSafeInteger(input.expected_document_revision) && Number(input.expected_document_revision) > 0, 400, "Refresh the saved reel revision before previewing narration.");
  const listing = input.key.slice(5);
  await context.authorizeListing(listing);
  const readReview = async () => {
    const {data, error} = await context.admin.rpc("studio_production_review", {
      p_actor: context.userId, p_org_id: context.orgId, p_document_user_id: owner, p_key: input.key, p_action: "get",
    }).abortSignal(req.signal);
    if (error) throw new HttpError(404, "This submitted narration is unavailable. Reload the review.");
    assert(data?.document && data.review?.status !== "draft" && data.review?.submitted_at, 404, "This reel is no longer submitted for review.");
    assert(data.document.revision === input.expected_document_revision && data.source_revision === input.expected_document_revision, 409, "This reel changed. Reload the review before previewing narration.");
    assert(data.document.payload?.draft?.narration?.resultId === input.result_id, 404, "This narration is not selected in the submitted reel.");
  };
  await readReview();
  const {data: row, error} = await context.admin.from("studio_creative_results").select("id,user_id,org_id,listing_id,kind,bucket,storage_key,metadata,provenance_id,created_at")
    .eq("id", input.result_id).eq("user_id", owner).eq("org_id", context.orgId).eq("listing_id", listing).eq("kind", "voice").abortSignal(req.signal).maybeSingle();
  if (error) throw new HttpError(503, "Review narration could not be loaded.");
  const metadata = row?.metadata;
  assert(row && metadata && metadata.state === "completed" && row.bucket === "uploads" &&
    typeof row.storage_key === "string" && new RegExp(`^ai-voice/${context.orgId}/${UUID.source.slice(1,-1)}\\.mp3$`).test(row.storage_key), 404, "The selected narration is not available for playback.");
  const url = await sign(R2_BUCKET_UPLOADS, row.storage_key, 600);
  await readReview(); // Do not return a newly minted capability for an invalidated revision.
  return json({result: {
    id: row.id, kind: "voice", listing_id: listing, created_at: row.created_at, state: "completed",
    label: metadata.label ?? "", provenance_id: row.provenance_id, disclosure: metadata.disclosure ?? null,
    video_kind: null, asset_id: null, source_asset_id: null, duration_s: metadata.duration_s ?? null,
    voice_name: metadata.voice_name ?? null, words: Array.isArray(metadata.words) ? metadata.words : [],
    message: metadata.message ?? null, url, expires_at: new Date(Date.now() + 600_000).toISOString(),
  }}, 200, {"Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff"});
}
