// Temporary owner-only reseller comparison. This is not a public route switch:
// normal tenants retain the table's disabled KIE/privacy policy. The operator
// records explicit consent for their own listing in admin-only app_config.
import { adminClient } from "../_shared/supabase.ts";
import type { RouteStep } from "../_shared/router.ts";
import type { GenerateInput } from "../_shared/providers/types.ts";
import { decodeDataUrl, ProviderError } from "../_shared/providers/common.ts";

export const OWNER_REEL_QA_KEY = "owner_reel_provider_qa";
export const KIE_REEL_QA_MODEL = "bytedance/v1-pro-fast-image-to-video";
export const KIE_KLING_REEL_QA_MODEL = "kling-3.0/video";
export const OWNER_REEL_QA_CONSENT = "owner-authorized-kie-media-qa-2026-10-12";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_QA_WINDOW_MS = 24 * 60 * 60 * 1000;
function canonicalUuid(value: unknown): string | null {
  return typeof value === "string" && UUID.test(value) ? value.toLowerCase() : null;
}

export async function ownerQaReelStep(
  args: { actorId: string; orgId: string; listingId?: string | null; seconds: number; framing?: "preserve_photo" },
  db = adminClient(),
  now = new Date(),
): Promise<RouteStep | null> {
  // No request-body provider, model, pricing, consent or is_admin claim enters
  // this function. Even an administrator needs an exact, fresh server grant.
  // Foundation UUID.uuidString is uppercase; Postgres UUID text is lowercase.
  // Compare the validated UUID identity, never case-sensitive presentation.
  const actorId = canonicalUuid(args.actorId), orgId = canonicalUuid(args.orgId), listingId = canonicalUuid(args.listingId);
  if (!actorId || !orgId || !listingId || args.seconds !== 5) return null;
  const { data, error } = await db.from("app_config").select("value")
    .eq("key", OWNER_REEL_QA_KEY).maybeSingle();
  if (error || !data?.value || typeof data.value !== "object" || Array.isArray(data.value)) return null;
  const grant = data.value as Record<string, unknown>;
  if (grant.enabled !== true || canonicalUuid(grant.actor_id) !== actorId || canonicalUuid(grant.org_id) !== orgId ||
      canonicalUuid(grant.listing_id) !== listingId || grant.provider !== "kie" ||
      (grant.model !== KIE_REEL_QA_MODEL && grant.model !== KIE_KLING_REEL_QA_MODEL) ||
      grant.consent !== OWNER_REEL_QA_CONSENT || canonicalUuid(grant.changed_by) !== actorId) return null;
  const kling = grant.model === KIE_KLING_REEL_QA_MODEL;
  if (kling && (args.framing !== "preserve_photo" || !["pro", "4K"].includes(String(grant.mode)) || grant.sound !== false)) return null;
  const fourK = kling && grant.mode === "4K";
  const start = typeof grant.created_at === "string" ? Date.parse(grant.created_at) : NaN;
  const end = typeof grant.expires_at === "string" ? Date.parse(grant.expires_at) : NaN;
  const clock = now.getTime();
  if (![start, end, clock].every(Number.isFinite) || start > clock || end <= clock ||
      end <= start || end - start > MAX_QA_WINDOW_MS) return null;
  const admin = await db.from("profiles").select("is_admin").eq("id", actorId).maybeSingle();
  if (admin.error || admin.data?.is_admin !== true) return null;
  // Published 2026-10-12: 36 credits/$0.18 for 1080p/5 s. Do not use the
  // top-up bonus or marketing speed claim as a billing/latency guarantee.
  // https://kie.ai/seedance-1-0-pro-fast
  // Kling3 Pro silent:18credits/s=$0.09/s. Its comparison is opt-in only;
  // installed clients without preserve_photo keep their ordinary route.
  // https://kie.ai/kling-3-0
  return {
    route_id: fourK ? "owner-qa-kie-kling3-4k-20261015" : kling ? "owner-qa-kie-kling3-pro-20261012" : "owner-qa-kie-seedance-fast-20261012", task: "video.reel_clip",
    provider: "kie", model: String(grant.model), unit: "second", unit_cents: fourK ? 33.5 : kling ? 9 : 3.6,
    capabilities: ["i2v", "1080p", "5s"], max_latency_s: 900, min_plan: "free",
    same_model_as: kling ? "kling_3_pro" : "seedance_v1_pro_fast", privacy_tier: "trains_by_default", enabled: true,
    ...(kling ? { params: { kie_mode: fourK ? "4K" : "pro", sound: false } } : {}),
  };
}

interface OwnerQaInputDependencies {
  authorize(): Promise<boolean>;
  register(key: string, bytes: number): Promise<void>;
  put(key: string, bytes: Uint8Array<ArrayBuffer>, mime: string): Promise<{ key: string; bytes: number }>;
  head(key: string): Promise<{ exists: boolean; bytes: number | null }>;
  sign(key: string): Promise<string>;
}

/** URL-only vendors need an owned source, not the generic unjournaled staging
 * helper. The same existing SQL inventory participates in listing/account
 * deletion and storage metering. Registration precedes every byte write and
 * capability; only the server-authorized owner QA path calls this helper. */
export async function prepareOwnerQaReelInput(
  identity: { actorId: string; orgId: string; listingId: string },
  input: GenerateInput,
  deps: OwnerQaInputDependencies,
): Promise<GenerateInput> {
  try {
    const actorId = canonicalUuid(identity.actorId), orgId = canonicalUuid(identity.orgId), listingId = canonicalUuid(identity.listingId);
    if (!actorId || !orgId || !listingId ||
        !await deps.authorize()) throw new Error("QA source unavailable");
    // This HTTPS source was resolved by the normal current asset-authority
    // path before admission. There is no client-supplied URL field in ReelBody.
    if (input.image_url?.startsWith("https://")) return input;
    const decoded = input.image_url ? decodeDataUrl(input.image_url) : null;
    if (!decoded || decoded.bytes.byteLength < 1 || decoded.bytes.byteLength > 10 * 1024 * 1024) {
      throw new Error("QA source unavailable");
    }
    const ext = ({ "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" } as Record<string, string>)[decoded.mime];
    if (!ext) throw new Error("QA source unavailable");
    const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", decoded.bytes)))
      .map(byte => byte.toString(16).padStart(2, "0")).join("");
    const key = `ai-router/${orgId}/owner-qa-input/${actorId}/${listingId}/${hash}.${ext}`;
    await deps.register(key, decoded.bytes.byteLength);
    const stored = await deps.put(key, decoded.bytes, decoded.mime);
    const head = await deps.head(key);
    if (stored.key !== key || stored.bytes !== decoded.bytes.byteLength || !head.exists ||
        head.bytes !== decoded.bytes.byteLength || !await deps.authorize()) throw new Error("QA source unavailable");
    await deps.register(key, decoded.bytes.byteLength);
    const imageUrl = await deps.sign(key);
    if (typeof imageUrl !== "string" || !imageUrl.startsWith("https://")) throw new Error("QA source unavailable");
    return { ...input, image_url: imageUrl, image_b64: undefined };
  } catch {
    // No provider HTTP call has occurred. A failed source preparation releases
    // its supplier holds; any staged bytes stay in the deletion/storage journal.
    throw new ProviderError("kie", "validation", "Owner QA source preparation could not be verified", 0, true);
  }
}
