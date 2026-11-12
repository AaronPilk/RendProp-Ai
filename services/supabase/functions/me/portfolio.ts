import { assert, HttpError, throwRpc } from "../_shared/http.ts";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export function portfolioReceipt(data: unknown, actor: string, org: string) {
  const r = data as Record<string, unknown> | null;
  assert(r && r.user_id === actor && r.org_id === org && (r.id === null || typeof r.id === "string" && UUID.test(r.id)) && Number.isSafeInteger(r.revision) && Number(r.revision) >= 0 && Array.isArray(r.listing_ids) && r.listing_ids.length <= 100 && r.listing_ids.every(id => typeof id === "string" && UUID.test(id)) && new Set(r.listing_ids).size === r.listing_ids.length, 503, "Your portfolio could not be confirmed. Reload before saving.");
  const base = (Deno.env.get("TOUR_PUBLIC_BASE_URL") ?? "https://rendprop.com").replace(/\/+$/, "");
  return { ok: true, user_id: actor, org_id: org, id: r.id as string | null, revision: r.revision as number, listing_ids: r.listing_ids as string[], portfolio_url: r.id ? `${base}/a/member-${r.id}` : null };
}
// Auth supplies actor and the explicit X-Org-Id supplies workspace.
// deno-lint-ignore no-explicit-any
export async function memberPortfolio(admin: any, actor: string, org: string, body?: unknown) {
  let name = "read_member_portfolio", args: Record<string, unknown> = { p_actor: actor, p_org: org };
  if (body !== undefined) {
    const b = body as Record<string, unknown>;
    assert(b && typeof b === "object" && !Array.isArray(b) && Object.keys(b).length === 2 && Number.isSafeInteger(b.expected_revision) && Number(b.expected_revision) >= 0 && Array.isArray(b.listing_ids) && b.listing_ids.length <= 100 && b.listing_ids.every(id => typeof id === "string" && UUID.test(id)) && new Set(b.listing_ids).size === b.listing_ids.length, 400, "Choose up to 100 distinct listings and their saved portfolio revision.");
    name = "save_member_portfolio"; args = { ...args, p_expected: b.expected_revision, p_ids: b.listing_ids };
  }
  const { data, error } = await admin.rpc(name, args);
  if (error) {
    if (/RP\d{3}:/.test(error.message)) throwRpc(error.message);
    throw new HttpError(503, "Your portfolio is temporarily unavailable. Your selection is kept.");
  }
  return portfolioReceipt(data, actor, org);
}
