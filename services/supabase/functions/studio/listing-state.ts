import { assert, HttpError, json } from "../_shared/http.ts";
import type { StudioContext } from "./context.ts";
import { projectAssetQuality } from "./creative-quality.ts";
const PAGE = 100;
export async function handleListingState(req: Request, context: StudioContext): Promise<Response> {
  assert(req.method === "GET", 405, "Use a listing action to make changes.");
  const url = new URL(req.url);
  const listingId = url.searchParams.get("listing_id") ?? "";
  await context.authorizeListing(listingId);
  const rawOffset = url.searchParams.get("offset") ?? "0";
  assert(/^(0|[1-9]\d{0,4})$/.test(rawOffset) && Number(rawOffset) % PAGE === 0 && Number(rawOffset) <= 10000, 400, "Invalid listing page.");
  const offset = Number(rawOffset);
  const { db } = context;
  const rows = await Promise.all([
    db.from("capture_assets").select("id,listing_id,storage_key,kind,bucket,uploaded,duration_s,bytes,created_at,presenter_job_id")
      .eq("listing_id", listingId).order("created_at", { ascending: false }).order("id").range(offset, offset + PAGE).abortSignal(req.signal),
    db.from("render_jobs").select("id,listing_id,capture_asset_id,status,progress,current_step,tier,error,enhancements,created_at")
      .eq("listing_id", listingId).order("created_at", { ascending: false }).order("id").range(offset, offset + PAGE).abortSignal(req.signal),
    db.from("renders").select("id,listing_id,job_id,slug,published_at,duration_s,created_at,staged")
      .eq("listing_id", listingId).order("created_at", { ascending: false }).order("id").range(offset, offset + PAGE).abortSignal(req.signal),
    db.from("photos").select("id,listing_id,original_key,enhanced_key,caption,is_staged,is_main,sort,created_at")
      .eq("listing_id", listingId).order("created_at", { ascending: false }).order("id").range(offset, offset + PAGE).abortSignal(req.signal),
  ]);
  if (rows.some(r => r.error || !Array.isArray(r.data))) throw new HttpError(503, "Listing activity is temporarily unavailable.");
  const more = rows.some(r => r.data!.length > PAGE);
  assert(!(more && offset === 10000), 422, "This listing exceeds the activity paging limit. Contact support.");
  const assets = rows[0].data!.slice(0, PAGE), jobs = rows[1].data!.slice(0, PAGE),
    renders = rows[2].data!.slice(0, PAGE), photos = rows[3].data!.slice(0, PAGE);
  // Provider errors can contain private capability URLs. The dedicated job route
  // provides the detailed recovery reason; the listing summary exposes only status.
  for (const job of jobs) job.error = job.error ? "This render needs attention. Open it for recovery options." : null;
  const chapterIds = [...new Set([...assets.map(a => a.id), ...jobs.map(j => j.capture_asset_id)].filter(Boolean))];
  let chapters: unknown[] = [];
  if (chapterIds.length) {
    const result = await db.from("capture_chapters").select("asset_id,label,t_ms,sort")
      .in("asset_id", chapterIds).order("asset_id").order("sort").limit(2001).abortSignal(req.signal);
    if (result.error || !Array.isArray(result.data)) throw new HttpError(503, "Room chapters are temporarily unavailable.");
    assert(result.data.length <= 2000, 422, "This listing has too many room chapters to load at once.");
    chapters = result.data;
  }
  await projectAssetQuality(context, listingId, assets);
  await context.authorizeListing(listingId);
  return json({ org_id: context.orgId, listing_id: listingId, assets, jobs, renders, photos, chapters,
    next_offset: more ? offset + PAGE : null }, 200, { "Cache-Control": "private, no-store" });
}
