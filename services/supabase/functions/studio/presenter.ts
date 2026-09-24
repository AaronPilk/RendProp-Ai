import { assert, HttpError, json, pathSegments, readJsonLimited } from "../_shared/http.ts";
import type { StudioContext } from "./context.ts";
import { presignGet } from "../_shared/providers/common.ts";
import { R2_BUCKET_UPLOADS } from "../_shared/r2.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const headers = { "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" };
export const presenterRuntime = {
  available: false,
  code: "enterprise_contract_required",
  reason: "AI generation is not connected. You can prepare drafts and edit original footage.",
};
function id(value: unknown) { assert(typeof value === "string" && UUID.test(value), 400, "Choose a valid property, profile or draft."); return value; }
function revision(value: unknown, minimum = 1) { assert(Number.isSafeInteger(value) && Number(value) >= minimum && Number(value) < 2147483647, 400, "Refresh the saved revision before continuing."); return Number(value); }
function text(value: unknown, max: number) { assert(typeof value === "string" && value.trim().length > 0 && value.length <= max && !/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(value), 400, `Use between 1 and ${max} characters.`); return value.trim(); }
function references(value: unknown) { assert(Array.isArray(value) && value.length >= 1 && value.length <= 8, 400, "Choose one to eight uploaded reference photos."); const ids = value.map(id); assert(new Set(ids).size === ids.length, 400, "Choose each reference photo once."); return ids; }
export function presenterInput(input: Record<string, unknown>) {
  const listing_id = id(input.listing_id);
  const action = input.action;
  assert(typeof action === "string" && ["save_profile", "approve_profile", "revoke_profile", "save_draft", "approve_draft", "generate"].includes(action), 400, "Choose a presenter action.");
  const expected_revision = revision(input.expected_revision, action.startsWith("save_") ? 0 : 1);
  if (action === "save_profile") return { listing_id, action, expected_revision, display_name: text(input.display_name, 80), reference_asset_ids: references(input.reference_asset_ids) };
  if (action === "approve_profile" || action === "revoke_profile") {
    if (action === "approve_profile") assert(input.likeness_consent === true, 400, "Confirm permission to use your likeness with these reference photos.");
    return { listing_id, action, expected_revision, profile_id: id(input.profile_id), ...(action === "approve_profile" ? { likeness_consent: true } : {}) };
  }
  const draft_id = id(input.draft_id), expected_profile_revision = revision(input.expected_profile_revision);
  if (action !== "save_draft") {
    if (action === "approve_draft") assert(input.source_performance_consent === true, 400, "Confirm permission to use the source performance for this video.");
    return { listing_id, action, draft_id, expected_revision, expected_profile_revision, ...(action === "approve_draft" ? { source_performance_consent: true } : {}) };
  }
  assert(["listing_intro", "property_tour", "market_update"].includes(String(input.format)), 400, "Choose a supported presenter format.");
  assert(["480p", "720p"].includes(String(input.resolution)), 400, "Choose 480p or 720p.");
  return { listing_id, action, draft_id, expected_revision, expected_profile_revision, profile_id: id(input.profile_id), title: text(input.title, 120), script: text(input.script, 2000), source_asset_id: id(input.source_asset_id), format: input.format as string, resolution: input.resolution as string };
}
export function presenterRpcError(error: { message?: string } | null) {
  if (!error) return;
  const match = /^RP(400|403|404|409|422|429): ([^\r\n]{1,240})$/.exec(error.message ?? "");
  throw new HttpError(match ? Number(match[1]) : 503, match ? match[2] : "Presenter workspace is temporarily unavailable. Reload before retrying.");
}
export async function presenterCall(context: StudioContext, req: Request, name: string, args: Record<string, unknown>) {
  const result = await context.admin.rpc(name, { ...args, p_actor: context.userId, p_org_id: context.orgId }).abortSignal(req.signal);
  presenterRpcError(result.error);
  return result.data;
}

/** Returns only expiring URLs for already authorized originals. Re-read after
 * signing so a concurrent revocation cannot return a newly issued capability. */
export async function handlePresenterMedia(req: Request, context: StudioContext, sign = presignGet) {
  assert(req.method === "POST", 405, "Use a presenter reference preview action.");
  const body = await readJsonLimited(req, 4096), listing = id(body.listing_id);
  await context.authorizeListing(listing);
  const payload = body.source_asset_id !== undefined ? { source_asset_id: id(body.source_asset_id) } : body.profile_id !== undefined
    ? { profile_id: id(body.profile_id), expected_profile_revision: revision(body.expected_profile_revision) }
    : { asset_ids: references(body.asset_ids) };
  const args = { p_listing_id: listing, p_payload: payload };
  const before = await presenterCall(context, req, "studio_presenter_media", args);
  assert(before?.org_id === context.orgId && before?.listing_id === listing && Array.isArray(before.assets) && before.assets.length >= 1 && before.assets.length <= 8, 503, "Presenter references could not be read.");
  const expires_at = new Date(Date.now() + 300_000).toISOString();
  const refs = await Promise.all(before.assets.map(async (asset: Record<string, unknown>) => {
    const asset_id = id(asset.id), source = id(asset.listing_id), key = asset.storage_key;
    assert(asset.bucket === "uploads" && typeof key === "string" && key.startsWith(`uploads/${context.orgId}/${source}/`) && !/[\\?#\u0000-\u001f]/.test(key) && !key.includes(".."), 503, "Presenter reference storage could not be verified.");
    return { asset_id, url: await sign(R2_BUCKET_UPLOADS, key, 300), expires_at };
  }));
  const after = await presenterCall(context, req, "studio_presenter_media", args);
  assert(JSON.stringify(before) === JSON.stringify(after), 409, "Presenter references changed. Reload before continuing.");
  return json({ org_id: context.orgId, listing_id: listing, profile_id: before.profile_id ?? null, profile_revision: before.profile_revision ?? null, ...(body.source_asset_id !== undefined ? { source: { ...refs[0], duration_s: before.assets[0].duration_s } } : { references: refs }) }, 200, headers);
}

export async function handlePresenter(req: Request, context: StudioContext): Promise<Response | null> {
  const seg = pathSegments(req, "studio");
  if (seg.length === 2 && seg[0] === "presenter" && seg[1] === "media") return handlePresenterMedia(req, context);
  if (seg.length !== 1 || seg[0] !== "presenter") return null;
  assert(req.method === "GET" || req.method === "POST", 405, "Use a presenter workspace action.");
  const mutation = req.method === "POST" ? presenterInput(await readJsonLimited(req, 16 * 1024)) : null;
  const listing = mutation?.listing_id ?? id(new URL(req.url).searchParams.get("listing_id"));
  await context.authorizeListing(listing);
  // No public action can reach the server-only generation claim RPC.
  if (mutation?.action === "generate") return json({ error: presenterRuntime.reason, code: presenterRuntime.code, runtime: presenterRuntime }, 409, headers);
  const data = await presenterCall(context, req, "studio_presenter_workspace", { p_listing_id: listing, p_action: mutation?.action ?? "get", p_payload: mutation ?? {} });
  assert(data?.org_id === context.orgId && data?.listing_id === listing && Array.isArray(data.profiles) && Array.isArray(data.drafts) && data.permissions, 503, "Presenter workspace could not be read.");
  return json({ ...data, runtime: presenterRuntime }, 200, headers);
}
