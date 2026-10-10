import { assert, HttpError, json, readJsonLimited, throwRpc } from "../_shared/http.ts";

type Admin = { rpc: (name: string, args: Record<string, unknown>) => PromiseLike<{data: unknown; error: {message: string} | null}> };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Called only AFTER getUser verifies this bearer against Supabase Auth. Parsing
 * derives the verified session identity; it is not a replacement for Auth. */
export function verifiedDeviceSession(req: Request, verifiedUser: string): string {
  try {
    const bearer = req.headers.get("authorization")?.match(/^Bearer\s+(\S+)$/i)?.[1];
    const parts = bearer?.split(".");
    if (!parts || parts.length !== 3 || parts[1].length > 16384) throw new Error();
    const encoded = parts[1].replace(/-/g,"+").replace(/_/g,"/");
    const claims = JSON.parse(atob(encoded.padEnd(Math.ceil(encoded.length / 4) * 4,"=")));
    if (claims.sub !== verifiedUser || typeof claims.session_id !== "string" || !UUID.test(claims.session_id)) throw new Error();
    return claims.session_id;
  } catch {
    throw new HttpError(401,"Sign in again before registering notifications.");
  }
}

export async function deviceBinding(req: Request, admin: Admin, verifiedUser: string): Promise<Response> {
  assert(req.method === "POST" || req.method === "DELETE",405,"Use POST or DELETE for notification registration.");
  const session = verifiedDeviceSession(req,verifiedUser);
  const body = await readJsonLimited<Record<string,unknown>>(req,4096);
  // Neither a supplied user nor session may be used as authority, even if it
  // happens to match today. This also prevents future clients relying on it.
  assert(!("user_id" in body) && !("session_id" in body),400,"Notification identity comes from your signed-in account.");
  const token = typeof body.device_token === "string" ? body.device_token.trim().toLowerCase() : "";
  assert(/^[0-9a-fA-F]{16,400}$/.test(token),400,"device_token must be the hexadecimal APNs token");
  const environment = String(body.environment ?? "production").trim().toLowerCase();
  assert(environment === "sandbox" || environment === "production",400,"environment must be sandbox or production");
  const clip = (value: unknown,limit: number) => typeof value === "string" ? value.trim().slice(0,limit) || null : null;
  const removing = req.method === "DELETE";
  const name = removing ? "notification_unregister_device" : "notification_register_device_session";
  const args: Record<string,unknown> = {p_user:verifiedUser,p_session:session,p_token:token,p_environment:environment};
  if (!removing) Object.assign(args,{p_bundle_id:clip(body.bundle_id,120),p_locale:clip(body.locale,32),p_app_version:clip(body.app_version,40)});
  const {data,error} = await admin.rpc(name,args);
  if (error) {
    if (/RP\d{3}:/.test(error.message)) throwRpc(error.message);
    // Database details can include tokens. Do not echo or log them.
    throw new HttpError(503,"Could not update this device’s notifications. Try again.","upstream");
  }
  if (removing) {
    assert(data && typeof data === "object" && !Array.isArray(data) && (data as Record<string,unknown>).unregistered === true,503,"Notification removal could not be confirmed.");
    return json({ok:true,unregistered:true});
  }
  const row = data && typeof data === "object" && !Array.isArray(data) ? data as Record<string,unknown> : null;
  assert(row && row.environment === environment && UUID.test(String(row.id ?? "")),503,"Notification registration could not be confirmed.");
  // Never echo the APNs token or the session credential.
  return json({ok:true,device:{id:row.id,bundle_id:row.bundle_id ?? null,environment:row.environment,last_seen_at:row.last_seen_at ?? null}});
}
