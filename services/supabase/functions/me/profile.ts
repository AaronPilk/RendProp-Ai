import { assert, HttpError, throwRpc } from "../_shared/http.ts";
export const REAL_ESTATE_ROLES = [
  "agent",
  "photographer_videographer",
] as const;
// A product preference only; membership roles remain the authorization authority.
// deno-lint-ignore no-explicit-any
export async function saveProfileRole(admin: any, user: string, body: unknown) {
  assert(
    body && typeof body === "object" && !Array.isArray(body) &&
      Object.keys(body).length === 1 &&
      "real_estate_role" in body &&
      (REAL_ESTATE_ROLES as readonly unknown[]).includes(body.real_estate_role),
    400,
    "Choose Agent or Photographer / videographer.",
  );
  const { data, error } = await admin.rpc("set_real_estate_role", {
    p_user: user,
    p_role: body.real_estate_role,
  });
  if (error) {
    if (/RP\d{3}:/.test(error.message)) throwRpc(error.message);
    throw new HttpError(
      503,
      "Your account preference could not be saved. Please retry.",
    );
  }
  return { ok: true, user: data };
}
