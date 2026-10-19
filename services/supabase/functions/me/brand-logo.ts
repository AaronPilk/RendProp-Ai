import { assert, HttpError, json, readJsonLimited } from "../_shared/http.ts";
import { brandImage } from "./brand-image.ts";
import { row, uploadRPC, type UploadAdmin } from "../uploads/transport.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export interface LogoStorage {
  publicURL(key: string): string | null;
  write(key: string, bytes: Uint8Array<ArrayBuffer>, type: string, sha256: string): Promise<void>;
  inspect(key: string): Promise<{ bytes: number; type: string; sha256: string; etag: string } | null>;
}
function expected(body: Record<string, unknown>): string | null {
  assert("expected_logo_url" in body && (body.expected_logo_url === null || typeof body.expected_logo_url === "string" && body.expected_logo_url.length <= 500), 400, "Reload your brand card before changing its logo.");
  return body.expected_logo_url as string | null;
}

/** The handler supplies Auth-verified actor and membership-verified selected org.
 * SQL checks write authority again both before storage and at publication. */
export async function brandLogo(req: Request, admin: UploadAdmin, actor: string, org: string, storage: LogoStorage, action: "upload" | "clear" = "upload"): Promise<Response> {
  assert(req.method === "POST", 405, "Use POST for a business logo.");
  const body = await readJsonLimited<Record<string, unknown>>(req, 710_000);
  assert(body && typeof body === "object" && !Array.isArray(body), 400, "Enter a logo upload.");
  const baseline = expected(body);
  if (action === "clear") {
    assert(Object.keys(body).every((k) => k === "expected_logo_url"), 400, "Unexpected logo fields.");
    const receipt = row(await uploadRPC(admin, "clear_org_brand_logo", { p_actor: actor, p_org: org, p_expected: baseline }));
    assert(receipt.org_id === org && receipt.business_logo_url === null, 503, "Logo removal receipt could not be verified.");
    return json({ ok: true, org_id: org, business_logo_url: null });
  }
  assert(req.method === "POST", 405, "Use POST or DELETE for a business logo.");
  assert(Object.keys(body).every((k) => ["image_base64", "content_type", "expected_logo_url", "client_operation_id"].includes(k)), 400, "Unexpected logo fields.");
  assert(typeof body.client_operation_id === "string" && UUID.test(body.client_operation_id), 400, "Choose a new logo operation.");
  const operation = body.client_operation_id.toLowerCase();
  const image = await brandImage(body.image_base64, body.content_type);
  const key = `renders/${org}/brand/${operation}.${image.type === "image/png" ? "png" : "jpg"}`;
  const url = storage.publicURL(key);
  assert(url && /^https:\/\//.test(url) && url.length <= 500, 503, "Public logo storage is not configured.");
  const prepared = row(await uploadRPC(admin, "prepare_org_brand_logo", {
    p_actor: actor, p_org: org, p_operation: operation, p_expected: baseline,
    p_bytes: image.bytes.length, p_type: image.type, p_sha256: image.sha256, p_url: url,
  }));
  assert(prepared.org_id === org && prepared.actor_id === actor && prepared.object_key === key && prepared.public_url === url, 503, "Logo upload receipt could not be verified.");
  if (prepared.replayed === true) return json({ ok: true, org_id: org, business_logo_url: url, replayed: true });
  if (prepared.dispatch === true) await storage.write(key, image.bytes, image.type, image.sha256);
  const observed = await storage.inspect(key);
  if (!observed) throw new HttpError(409, "The logo upload is not confirmed. Reload your brand card and retry with a new upload.", "conflict");
  assert(observed.bytes === image.bytes.length && observed.type === image.type && observed.sha256 === image.sha256 && observed.etag.length > 0 && observed.etag.length <= 256, 409, "The stored image could not be verified. Reload your brand card before retrying.");
  const published = row(await uploadRPC(admin, "publish_org_brand_logo", { p_actor: actor, p_org: org, p_operation: operation, p_etag: observed.etag }));
  assert(published.org_id === org && published.business_logo_url === url, 503, "Logo publication receipt could not be verified.");
  return json({ ok: true, org_id: org, business_logo_url: url, replayed: published.replayed === true });
}
