import { assert, HttpError, throwRpc } from "../_shared/http.ts";
import { isSpaceType } from "../_shared/spacetypes.ts";

export const PERSONAL_CARD_LIMITS: Record<string, number> = {
  name: 120, title: 120, brokerage: 160, phone: 80, email: 254,
  website: 2048, instagram: 500, linkedin: 500, tiktok: 500, space_type: 32,
};
const links = new Set(["website", "instagram", "linkedin", "tiktok"]);
function object(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}
function valueValid(key: string, value: unknown): boolean {
  if (value === null) return true;
  if (typeof value !== "string" || value.length > PERSONAL_CARD_LIMITS[key] || /[\u0000-\u001f\u007f]/.test(value)) return false;
  if (key === "space_type") return isSpaceType(value);
  if (key === "name" && value.includes("@")) return false;
  if (key === "email" && value && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) return false;
  if (links.has(key) && value) {
    try {
      const url = new URL(value);
      if (url.protocol !== "https:" || !url.hostname || url.username || url.password || /[\s\\]/.test(value)) return false;
    } catch { return false; }
  }
  return true;
}
function receipt(data: unknown, actor: string) {
  assert(object(data) && data.user_id === actor && (data.space_type === null || isSpaceType(data.space_type)) &&
    (data.public_card === null || (object(data.public_card) && Object.entries(data.public_card).every(([key,value]) => key !== "space_type" && key in PERSONAL_CARD_LIMITS && typeof value === "string" && valueValid(key,value)))),
    503, "Your personal card could not be verified. Please retry.");
  return { ok: true, user_id: actor, space_type: data.space_type, public_card: data.public_card };
}
// Auth supplies actor. The body can never select another profile or workspace.
// deno-lint-ignore no-explicit-any
export async function personalCard(admin: any, actor: string, body?: unknown) {
  let name = "read_personal_public_card", args: Record<string, unknown> = { p_actor: actor };
  if (body !== undefined) {
    assert(object(body) && Object.keys(body).length === 2 && object(body.changes) && object(body.expected), 400, "Use explicit personal card changes and their saved values.");
    const changes = body.changes, expected = body.expected, keys = Object.keys(changes);
    assert(keys.length > 0 && keys.length <= Object.keys(PERSONAL_CARD_LIMITS).length && Object.keys(expected).length === keys.length, 400, "Choose the personal card fields to save.");
    for (const key of keys) {
      assert(Object.hasOwn(PERSONAL_CARD_LIMITS,key) && valueValid(key,changes[key]), 400, "A personal card field is invalid. Links must use https.");
      const baseline = expected[key];
      assert(object(baseline) && typeof baseline.present === "boolean" &&
        (baseline.present ? Object.keys(baseline).length === 2 && Object.hasOwn(baseline,"value") && typeof baseline.value === "string" : Object.keys(baseline).length === 1),
        400, "Each changed field needs its exact saved value or an absent marker.");
    }
    name = "merge_personal_public_card"; args = { p_actor: actor, p_changes: changes, p_expected: expected };
  }
  const { data, error } = await admin.rpc(name,args);
  if (error) {
    if (/RP\d{3}:/.test(error.message)) throwRpc(error.message);
    throw new HttpError(503,"Your personal card could not be saved. Please retry.");
  }
  return receipt(data,actor);
}
