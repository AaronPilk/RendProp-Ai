import { assert } from "./http.ts";

const POLICY = "one-gemini-1k-4096-plus-one-kontext-20261007";
const TARIFF = "published-standard-20261006";
const finiteInteger = (v: unknown, max: number) => typeof v === "number" && Number.isSafeInteger(v) && v >= 0 && v <= max;

/** Display authority comes from the same service-only funded interval. This
 * metadata grants neither money nor provider access and exposes no receipt IDs. */
export async function photoPackageContext(admin: any, actor: string, org: string, now = Date.now()) {
  const { data, error } = await admin.rpc("serving_photo_package_context", { p_actor: actor, p_org: org });
  assert(!error, 503, "Photo allowance could not be verified. Please retry.");
  if (data === null) return null;
  const p = data?.photo_admissions, a = data?.other_ai;
  assert(data && data.org_id === org && data.policy === POLICY && data.tariff_version === TARIFF
    && typeof data.starts_at === "string" && typeof data.ends_at === "string"
    && Date.parse(data.starts_at) <= now && Date.parse(data.ends_at) > now
    && p && [p.cap,p.used,p.remaining].every((v) => finiteInteger(v,10000))
    && p.used <= p.cap && p.remaining === p.cap-p.used
    && data.photo_hold_cents === 35.1296 && data.protected_photo_cents === Math.ceil(p.cap*35.1296)
    && a && [a.cap_cents,a.used_cents,a.remaining_cents].every((v) => finiteInteger(v,100000000))
    && a.used_cents <= a.cap_cents && a.remaining_cents === a.cap_cents-a.used_cents,
    503, "Photo allowance could not be verified. Please retry.");
  return { org_id: org, policy: POLICY, tariff_version: TARIFF, starts_at: data.starts_at, ends_at: data.ends_at,
    photo_admissions: { cap:p.cap, used:p.used, remaining:p.remaining },
    photo_hold_cents:35.1296, protected_photo_cents:data.protected_photo_cents,
    other_ai:{ cap_cents:a.cap_cents,used_cents:a.used_cents,remaining_cents:a.remaining_cents } };
}
