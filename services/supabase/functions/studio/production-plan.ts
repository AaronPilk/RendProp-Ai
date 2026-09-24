import { assert, HttpError } from "../_shared/http.ts";
import type { StudioContext } from "./context.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
type Row = Record<string, unknown>;
function object(value: unknown): Row {
  assert(value && typeof value === "object" && !Array.isArray(value), 400, "Capture plan content is invalid.");
  return value as Row;
}
function text(value: unknown, max: number, nonempty = false): string {
  assert(typeof value === "string" && value.length <= max && !value.includes("\0") && (!nonempty || value.trim().length > 0), 400, "Capture plan text is invalid or too long.");
  return value;
}
function ids(value: unknown): string[] {
  assert(Array.isArray(value) && value.length <= 12 && value.every(id => typeof id === "string" && UUID.test(id)) && new Set(value).size === value.length,
    400, "Choose up to 12 different saved files per shot.");
  return value;
}
/** Explicit schema: labels are planning intent, never a quality or capture receipt. */
export function productionPlanInput(value: unknown, listingId: string) {
  const input = object(value);
  assert(input.schema === 1 && input.listingId === listingId, 400, "Capture plan belongs to another property.");
  assert(typeof input.recipe === "string" && ["listing-highlight", "agent-tour", "market-update"].includes(input.recipe), 400, "Choose a capture recipe.");
  assert(typeof input.presentation === "string" && ["music", "voiceover", "on-camera"].includes(input.presentation), 400, "Choose a presentation style.");
  assert([30, 45, 60].includes(input.targetSeconds as number), 400, "Choose a 30, 45, or 60 second target.");
  assert(Array.isArray(input.shots) && input.shots.length >= 1 && input.shots.length <= 16, 400, "A capture plan needs between 1 and 16 shots.");
  const shots = input.shots.map(raw => {
    const shot = object(raw);
    assert(typeof shot.id === "string" && /^[a-z0-9-]{1,48}$/.test(shot.id), 400, "Shot identifier is invalid.");
    assert(typeof shot.required === "boolean" && typeof shot.status === "string" && ["needed", "captured", "not-needed"].includes(shot.status), 400, "Choose a shot status.");
    return {id: shot.id, title: text(shot.title, 120, true), guidance: text(shot.guidance, 500), required: shot.required,
      status: shot.status as "needed" | "captured" | "not-needed", sourcePhotoIds: ids(shot.sourcePhotoIds),
      sourceVideoIds: ids(shot.sourceVideoIds), notes: text(shot.notes, 500)};
  });
  assert(new Set(shots.map(shot => shot.id)).size === shots.length, 400, "Each shot needs a different identifier.");
  return {schema: 1, listingId, recipe: input.recipe, presentation: input.presentation, targetSeconds: input.targetSeconds,
    shots, notes: text(input.notes, 2000)};
}

export async function authorizeProductionPlan(plan: ReturnType<typeof productionPlanInput>, context: StudioContext, signal: AbortSignal) {
  const {data: member, error} = await context.db.from("memberships").select("role")
    .eq("user_id", context.userId).eq("org_id", context.orgId).abortSignal(signal).maybeSingle();
  if (error) throw new HttpError(503, "Capture plan permissions are temporarily unavailable.");
  assert(member && ["owner", "admin", "agent"].includes(member.role), 403, "Your role can view capture plans but cannot edit them.");
  const photoIds = [...new Set(plan.shots.flatMap(shot => shot.sourcePhotoIds))];
  const videoIds = [...new Set(plan.shots.flatMap(shot => shot.sourceVideoIds))];
  const all = [...new Set([...photoIds, ...videoIds])];
  if (!all.length) return;
  // Same identity choices exposed by /media: gallery photos, completed capture
  // assets (including photos without a gallery row), and completed renders.
  const queries = await Promise.all([
    photoIds.length ? context.db.from("photos").select("id").eq("listing_id", plan.listingId).in("id", photoIds).abortSignal(signal) : Promise.resolve({data: [], error: null}),
    context.db.from("capture_assets").select("id,kind").eq("listing_id", plan.listingId).eq("uploaded", true).in("id", all).abortSignal(signal),
    videoIds.length ? context.db.from("renders").select("id").eq("listing_id", plan.listingId).not("video_key", "is", null).in("id", videoIds).abortSignal(signal) : Promise.resolve({data: [], error: null}),
  ]);
  if (queries.some(result => result.error)) throw new HttpError(503, "Saved capture files could not be checked. Retry before saving.");
  const photos = new Set((queries[0].data ?? []).map((row: {id: string}) => row.id));
  const videos = new Set((queries[2].data ?? []).map((row: {id: string}) => row.id));
  for (const asset of queries[1].data ?? []) {
    if (asset.kind === "photo") photos.add(asset.id);
    if (asset.kind === "video") videos.add(asset.id);
  }
  assert(photoIds.every(id => photos.has(id)) && videoIds.every(id => videos.has(id)), 400, "Capture files must be uploaded to this property and match their media type.");
}
