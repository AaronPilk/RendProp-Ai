// Presenter privacy follows derived edits, reflection outputs and published
// renders. Quality flags alone must never authorize a fresh media capability.
import { HttpError } from "./http.ts";
export type MediaSourceRefs = { assets?: readonly string[]; renders?: readonly string[]; keys?: readonly string[] };
export type MediaVisibility = { assets: Record<string, boolean>; renders: Record<string, boolean>; keys: Record<string, boolean> };
export type MediaAccessClient = { rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }> };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function refs(input: MediaSourceRefs): MediaVisibility {
  const out: MediaVisibility = { assets: Object.create(null), renders: Object.create(null), keys: Object.create(null) };
  for (const kind of ["assets", "renders", "keys"] as const) {
    const list = input[kind] ?? [];
    if (!Array.isArray(list) || list.some((v) => typeof v !== "string" || (kind !== "keys" ? !UUID.test(v) : !v.length || v.length > 1024))) throw new HttpError(503, "Media source identity could not be verified.");
    for (const value of list) out[kind][value] = false;
  }
  if (Object.values(out).reduce((n, values) => n + Object.keys(values).length, 0) > 500) throw new HttpError(503, "Media source lookup exceeded its bound.");
  return out;
}

export async function mediaVisibility(db: MediaAccessClient, listing: string, input: MediaSourceRefs): Promise<MediaVisibility> {
  if (!UUID.test(listing)) throw new HttpError(503, "Media source property could not be verified.");
  const out = refs(input), entries = (["assets", "renders", "keys"] as const).flatMap((kind) => Object.keys(out[kind]).map((value) => ({ kind, value })));
  // At most three independently bounded database calls for a complete page.
  const batches: typeof entries[] = [];
  for (let index = 0; index < entries.length; index += 200) batches.push(entries.slice(index, index + 200));
  await Promise.all(batches.map(async (batch) => {
    const payload: Record<string, unknown> = { p_listing: listing, p_assets: [], p_renders: [], p_keys: [] };
    for (const { kind, value } of batch) (payload[`p_${kind}`] as string[]).push(value);
    const { data, error } = await db.rpc("studio_presenter_media_visibility", payload);
    if (error || !data || typeof data !== "object" || Array.isArray(data)) throw new HttpError(503, "Media source access could not be verified. Please refresh.");
    for (const { kind, value } of batch) {
      const group = (data as Record<string, unknown>)[kind];
      if (!group || typeof group !== "object" || Array.isArray(group) || !Object.hasOwn(group, value) || typeof (group as Record<string, unknown>)[value] !== "boolean") throw new HttpError(503, "Media source access returned an incomplete result.");
      out[kind][value] = (group as Record<string, boolean>)[value];
    }
  }));
  return out;
}

export async function assertMediaVisible(db: MediaAccessClient, listing: string, input: MediaSourceRefs): Promise<void> {
  const visible = await mediaVisibility(db, listing, input);
  if (Object.values(visible).some((group) => Object.values(group).some((allowed) => !allowed))) throw new HttpError(404, "This media is no longer available.");
}

/** Check before minting, then check again before releasing capabilities. A
 * revocation during signing discards the signed result instead of returning it. */
export async function withVisibleMedia<T>(db: MediaAccessClient, listing: string, input: MediaSourceRefs, produce: () => Promise<T>): Promise<T> {
  await assertMediaVisible(db, listing, input);
  const value = await produce();
  await assertMediaVisible(db, listing, input);
  return value;
}
