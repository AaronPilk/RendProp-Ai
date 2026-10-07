import { assert, HttpError, throwRpc } from "../_shared/http.ts";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function failure(error: { message?: string }): never {
  if (error.message && /RP\d{3}:/.test(error.message)) throwRpc(error.message);
  throw new HttpError(
    503,
    "Client email delivery could not be verified. Please retry.",
  );
}
// Private recipient details are only returned to members of the selected workspace.
// deno-lint-ignore no-explicit-any
export async function deliverySummaries(
  admin: any,
  user: string,
  org: string,
  leads: string[],
) {
  if (!leads.length) return {} as Record<string, unknown>;
  const { data, error } = await admin.rpc("client_lead_delivery_list", {
    p_user: user,
    p_org: org,
    p_leads: leads,
  });
  if (error) failure(error);
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    throw new HttpError(503, "Client email status could not be verified.");
  }
  return data as Record<string, unknown>;
}
// deno-lint-ignore no-explicit-any
export async function resendClientLead(
  admin: any,
  user: string,
  org: string,
  lead: string,
  raw: unknown,
) {
  assert(UUID.test(lead), 400, "Choose a valid inquiry.");
  assert(
    raw && typeof raw === "object" && !Array.isArray(raw) &&
      Object.keys(raw).length === 2 && "request_id" in raw &&
      "expected_recipient_email" in raw &&
      typeof raw.request_id === "string" && UUID.test(raw.request_id) &&
      typeof raw.expected_recipient_email === "string" &&
      raw.expected_recipient_email.length <= 200,
    400,
    "Review the client email before sending.",
  );
  const { data, error } = await admin.rpc("client_lead_resend", {
    p_user: user,
    p_org: org,
    p_lead: lead,
    p_request: raw.request_id,
    p_expected_email: raw.expected_recipient_email,
  });
  if (error) failure(error);
  if (!data || data.ok !== true || !data.delivery) {
    throw new HttpError(503, "The requested email could not be confirmed.");
  }
  return data;
}
