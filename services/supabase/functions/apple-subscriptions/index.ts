// apple-subscriptions — App Store Server Notifications V2, verified and applied.
//
//   POST /apple-subscriptions/notify   -> 200 { ok, duplicate?, applied?, ignored?, pending? }
//        { "signedPayload": "<App Store Server Notification V2 JWS>" }
//        Body is capped at 128 KB before it is buffered (413 past that) —
//        this route has no JWT in front of it, so an unbounded req.json() is
//        an out-of-memory kill that no per-IP limiter can catch.
//   GET  /apple-subscriptions/health   -> { ok, configured, schema_ready, bundle_id,
//                                           products[], checked_at }
//
// ── DEPLOY WITH --no-verify-jwt ─────────────────────────────────────────────
//
// Apple has no Supabase JWT and never will. With the gateway's JWT check on,
// every notification is rejected at the edge before this code runs, Apple
// retries for a day and then gives up, and subscriptions silently stop syncing.
// So:  supabase functions deploy apple-subscriptions --no-verify-jwt
// (or `verify_jwt = false` in config.toml). See README.md in this directory.
//
// That makes this the only PUBLIC route in the product that can change a plan,
// so the authentication moved from the gateway into the payload: nothing here
// is trusted until verifyAppleJWS() has walked the x5c chain to the pinned
// Apple Root CA - G3 and checked the leaf's signature. An unsigned or
// wrongly-signed body is a 401 and touches nothing.
//
// ── THE FOUR THINGS THIS FUNCTION IS CAREFUL ABOUT ──────────────────────────
//
// 1. IT NEVER 5xxs APPLE FOR SOMETHING APPLE DID RIGHT. Apple retries a
//    non-2xx for about a day, and a notification type we have not taught this
//    function about is not an error — it is Apple shipping a feature. Unknown
//    types are stored, logged by NAME, and answered 200. Only a genuinely
//    broken signature (401), a malformed body (400) or OUR database failing
//    (5xx, so the retry is useful) leaves the 200 path.
//
// 2. A RETRY IS A NO-OP. Apple resends with the SAME notificationUUID, so the
//    uuid is the primary key of apple_notifications and the insert happens
//    BEFORE any entitlement write. A unique violation answers
//    `{ ok: true, duplicate: true }` and stops. If the entitlement write then
//    fails, the ledger row is removed again so Apple's retry can do real work.
//
// 3. A NOTIFICATION CAN ARRIVE BEFORE THE APP DOES. StoreKit hands the device a
//    transaction and Apple posts here at roughly the same moment; either can
//    win. When the originalTransactionId is not linked to an org yet, the row
//    is stored with `pending = true` and POST /me/entitlement replays it the
//    moment the app links the workspace. Nothing is dropped.
//
// 4. SANDBOX CANNOT MOVE PRODUCTION. A Sandbox notification for a subscription
//    stored as Production (or the reverse) is recorded and ignored, never
//    applied. A TestFlight tester with a sandbox account must not be able to
//    change what a paying customer gets. Since migration 0021 the same rule is
//    enforced inside apply_apple_entitlement() as well, so POST /me/entitlement
//    — which had no such check — cannot flip an environment either.
//
// 5. A DETERMINISTIC REFUSAL IS NOT AN OUTAGE. apply_apple_entitlement() raises
//    `RPnnn:` when it will not take the input at all (a subscription bound to a
//    different workspace, a mismatched environment). Retrying that for a day
//    changes nothing, so it answers 200 { applied: false, ignored: "refused" }
//    and the ledger row stays, which makes Apple's retry a duplicate no-op.
//    Only an unreachable database still 5xxs.
//
// Env (NAMES only, no values anywhere in this file):
//   APPLE_BUNDLE_ID   the app's bundle id; defaults to com.rendprop.app.
// No App Store Server API credentials are needed: the JWS Apple signs carries
// everything this design uses. (APPLE_ASC_ISSUER_ID / _KEY_ID / _PRIVATE_KEY_P8
// would only be needed to POLL Apple's /inApps/v1 endpoints — see the README.)
//
// Logging: notification type, subtype, uuid and environment. Never a payload,
// never a transaction's account token, never a credential.

import { handleOptions } from "../_shared/cors.ts";
import {
  HttpError,
  assert,
  json,
  pathSegments,
  readJsonLimited,
  respondError,
} from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import {
  type AppleRenewalInfo,
  type AppleTransaction,
  decodeRenewalInfo,
  decodeTransaction,
  knownProductIds,
  productToPlan,
  verifyAppleJWS,
} from "../_shared/applejws.ts";
// The decisions this handler makes, as pure functions — see logic.ts for why
// they live next door (they are the part notify.test.ts can exercise).
import {
  computeEntitlement,
  lookupVerdict,
  type NotificationFacts,
  type PendingEntitlement,
  resolveVerdict,
  summariseNotification,
} from "./logic.ts";

const APPLE_BUNDLE_ID = (Deno.env.get("APPLE_BUNDLE_ID") ?? "com.rendprop.app").trim();
const BUNDLE_ID_FROM_ENV = (Deno.env.get("APPLE_BUNDLE_ID") ?? "").trim().length > 0;

// Apple's own retry storm is a handful of requests; 240/minute per source IP is
// far above anything real and still bounds a flood from a spoofed sender. The
// limiter runs BEFORE signature verification because ECDSA is the expensive part.
const NOTIFY_MAX_PER_WINDOW = 240;
const NOTIFY_WINDOW_SECONDS = 60;

// A signedPayload is a few KB. Anything past this is not Apple.
const MAX_SIGNED_PAYLOAD_CHARS = 64 * 1024;
/** Hard ceiling on the bytes read off the wire, before any JSON parsing. */
const MAX_NOTIFY_BODY_BYTES = 128 * 1024;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const seg = pathSegments(req, "apple-subscriptions");
    const route = seg[0] ?? "";

    if (route === "health") {
      if (req.method !== "GET") throw new HttpError(405, "GET /apple-subscriptions/health");
      return await handleHealth();
    }
    if (route === "notify") {
      if (req.method !== "POST") throw new HttpError(405, "POST /apple-subscriptions/notify");
      return await handleNotify(req);
    }
    throw new HttpError(
      404,
      "Unknown route — POST /apple-subscriptions/notify or GET /apple-subscriptions/health",
    );
  } catch (err) {
    return respondError(err);
  }
});

// ── GET /apple-subscriptions/health ─────────────────────────────────────────
//
// "Is this endpoint ready for the URL I am about to paste into App Store
// Connect?" — answered without a single secret. `bundle_id` is the value the
// app ships in its Info.plist and the App Store lists publicly, so it is a
// diagnostic, not a disclosure; `schema_ready` proves migration 0019 landed,
// which is the failure this route exists to catch before Apple finds it.

async function handleHealth(): Promise<Response> {
  let schemaReady = false;
  try {
    const { error } = await adminClient()
      .from("apple_subscriptions")
      .select("original_transaction_id", { count: "exact", head: true })
      .limit(1);
    schemaReady = !error;
  } catch {
    schemaReady = false;
  }

  return json({
    ok: true,
    configured: BUNDLE_ID_FROM_ENV && schemaReady,
    schema_ready: schemaReady,
    bundle_id_from_env: BUNDLE_ID_FROM_ENV,
    bundle_id: APPLE_BUNDLE_ID,
    products: knownProductIds(),
    checked_at: new Date().toISOString(),
  });
}

// ── POST /apple-subscriptions/notify ────────────────────────────────────────

async function handleNotify(req: Request): Promise<Response> {
  // PUBLIC route: only Cloudflare's own header names the caller. The generic
  // clientIp() falls back to x-forwarded-for, which the caller controls — on a
  // route with no JWT that would let one machine rotate limiter keys at will
  // (or burn Apple's own bucket by spoofing Apple). No CF header → one shared
  // "unknown" bucket, which is the conservative choice.
  const ip = req.headers.get("cf-connecting-ip")?.trim() || "unknown";
  if (!(await durableRateLimit(`applenotify:${ip}`, NOTIFY_MAX_PER_WINDOW, NOTIFY_WINDOW_SECONDS))) {
    throw new HttpError(429, "Too many notifications — try again shortly.", "rate_limited");
  }

  // Capped BEFORE it is buffered. This route is deployed --no-verify-jwt, so
  // anyone on the internet can POST to it, and `req.json()` would happily read
  // a 500 MB body into the isolate's memory before the length check below ever
  // ran. 128 KB is twice the largest envelope this handler will accept.
  const body = await readJsonLimited<{ signedPayload?: unknown }>(req, MAX_NOTIFY_BODY_BYTES);
  const signedPayload = body.signedPayload;
  assert(
    typeof signedPayload === "string" && signedPayload.length > 0 &&
      signedPayload.length <= MAX_SIGNED_PAYLOAD_CHARS,
    400,
    "signedPayload is required",
  );

  // 401 on anything that is not genuinely Apple-signed.
  const outer = await verifyAppleJWS(signedPayload as string);
  const facts = await readFacts(outer);

  if (facts.bundleId !== APPLE_BUNDLE_ID) {
    // Correctly signed, but for another app. Nothing to store and nothing to do.
    throw new HttpError(400, "This notification is for a different app", "validation");
  }

  const verdictKind = resolveVerdict(facts);
  if (lookupVerdict(facts.type) === null) {
    // Apple shipped something new. Stored, named in the logs, answered 200.
    console.log(`apple notification type not handled yet: ${facts.type}`);
  }
  console.log(
    `apple notification ${facts.type}` +
      `${facts.subtype ? `/${facts.subtype}` : ""} ${facts.uuid} ${facts.environment} -> ${verdictKind}`,
  );

  const admin = adminClient();
  const originalTransactionId = facts.transaction?.originalTransactionId ?? null;

  // Who does this subscription belong to? Set by the app's first
  // POST /me/entitlement; null until then (see header note 3).
  let orgId: string | null = null;
  let storedEnvironment: string | null = null;
  if (originalTransactionId) {
    const { data, error } = await admin
      .from("apple_subscriptions")
      .select("org_id, environment")
      .eq("original_transaction_id", originalTransactionId)
      .maybeSingle();
    if (error) throw new HttpError(503, "Subscription lookup failed — retry", "upstream");
    orgId = (data?.org_id as string | null) ?? null;
    storedEnvironment = (data?.environment as string | null) ?? null;
  }

  // Header note 4: sandbox must never move a production subscription.
  const environmentMismatch = storedEnvironment !== null &&
    storedEnvironment !== facts.environment;

  // A product id we do not map is a product added in App Store Connect that this
  // build has never heard of. Store it and say so — do NOT guess a plan, and do
  // NOT downgrade an org because an unrecognised subscription lapsed.
  const unknownProduct = facts.transaction !== null &&
    productToPlan(facts.transaction.productId) === null;
  if (unknownProduct) {
    console.log(`apple notification for an unmapped product: ${facts.transaction!.productId}`);
  }

  const entitlementRelevant = verdictKind !== "ignore" && facts.transaction !== null &&
    !environmentMismatch && !unknownProduct;
  const pending = entitlementRelevant && orgId === null;
  const entitlement = entitlementRelevant ? computeEntitlement(facts, verdictKind) : null;

  // Header note 2: the ledger row goes in FIRST, so a retry is a no-op.
  const { error: insertError } = await admin.from("apple_notifications").insert({
    notification_uuid: facts.uuid,
    original_transaction_id: originalTransactionId,
    org_id: orgId,
    notification_type: facts.type,
    subtype: facts.subtype,
    environment: facts.environment,
    pending,
    payload: {
      notification: summariseNotification(outer, facts),
      transaction: facts.transaction,
      renewal: facts.renewal,
      verdict: verdictKind,
      // The exact RPC arguments a replay will re-use (see PendingEntitlement).
      entitlement,
    },
  });
  if (insertError) {
    const code = (insertError as { code?: string }).code;
    if (code === "23505" || /duplicate key/i.test(insertError.message)) {
      return json({ ok: true, duplicate: true });
    }
    // Our failure, not Apple's — 5xx so the retry is worth something.
    throw new HttpError(503, "Could not record the notification — retry", "upstream");
  }

  if (environmentMismatch) {
    return json({ ok: true, applied: false, ignored: "environment_mismatch" });
  }
  if (!entitlementRelevant) {
    return json({
      ok: true,
      applied: false,
      ignored: unknownProduct
        ? "unmapped_product"
        : (verdictKind === "ignore" ? "no_entitlement_change" : "no_transaction"),
    });
  }
  if (pending) {
    // Stored and waiting for POST /me/entitlement to link the workspace.
    return json({ ok: true, applied: false, pending: true });
  }

  let applied: boolean;
  try {
    applied = await applyEntitlement(entitlement!, orgId!);
  } catch (err) {
    // The ledger row would otherwise dedupe Apple's retry into a no-op and the
    // entitlement would never land. Best effort; a failure here just means the
    // retry answers `duplicate: true` and the owner sees it in the console.
    await admin.from("apple_notifications").delete().eq("notification_uuid", facts.uuid);
    throw err;
  }

  // `applied: false` here is a deterministic refusal, not an outage — the row
  // stays, so Apple's retry is a `duplicate: true` no-op instead of a loop.
  return applied ? json({ ok: true, applied: true }) : json({ ok: true, applied: false, ignored: "refused" });
}

/** Verify the two nested JWS blobs and pull out everything the handler branches on. */
async function readFacts(outer: Record<string, unknown>): Promise<NotificationFacts> {
  const uuid = typeof outer.notificationUUID === "string" ? outer.notificationUUID.trim() : "";
  const type = typeof outer.notificationType === "string" ? outer.notificationType.trim() : "";
  assert(uuid.length > 0 && uuid.length <= 200, 400, "notificationUUID is missing");
  assert(type.length > 0 && type.length <= 100, 400, "notificationType is missing");

  const data = outer.data;
  assert(
    typeof data === "object" && data !== null && !Array.isArray(data),
    400,
    "notification has no data object",
  );
  const d = data as Record<string, unknown>;

  const bundleId = typeof d.bundleId === "string" ? d.bundleId.trim() : "";
  assert(bundleId.length > 0, 400, "notification has no bundleId");

  // Sandbox and Production are BOTH accepted — a TestFlight tester is a real
  // customer of the sandbox — but the value is stored so the two can never mix.
  const environment = typeof d.environment === "string" ? d.environment.trim() : "";
  assert(
    environment === "Sandbox" || environment === "Production",
    400,
    "notification environment must be Sandbox or Production",
  );

  // The nested blobs are separately signed; verifying the envelope says nothing
  // about them, so each gets the full chain check of its own.
  let transaction: AppleTransaction | null = null;
  if (typeof d.signedTransactionInfo === "string" && d.signedTransactionInfo.length > 0) {
    transaction = decodeTransaction(await verifyAppleJWS(d.signedTransactionInfo));
    assert(transaction.bundleId === bundleId, 400, "nested transaction is for a different app");
  }
  let renewal: AppleRenewalInfo | null = null;
  if (typeof d.signedRenewalInfo === "string" && d.signedRenewalInfo.length > 0) {
    renewal = decodeRenewalInfo(await verifyAppleJWS(d.signedRenewalInfo));
  }

  const rawSubtype = typeof outer.subtype === "string" ? outer.subtype.trim() : "";
  return {
    uuid,
    type,
    subtype: rawSubtype.length > 0 ? rawSubtype.slice(0, 100) : null,
    environment,
    bundleId,
    transaction,
    renewal,
  };
}

/**
 * @returns true when the RPC actually ran. `false` means it REFUSED the input
 * deterministically (an `RPnnn:` exception — a subscription bound to another
 * workspace, an environment that disagrees with the stored one, a status the
 * function will not take). Those are not worth a day of Apple retries: the
 * notification is already recorded, and answering 200 stops the storm. Only a
 * database that could not be reached throws, so the retry has something to do.
 */
async function applyEntitlement(e: PendingEntitlement, orgId: string): Promise<boolean> {
  const { error } = await adminClient().rpc("apply_apple_entitlement", {
    p_org: orgId,
    p_user: null,
    p_original_transaction_id: e.original_transaction_id,
    p_transaction_id: e.transaction_id,
    p_product_id: e.product_id,
    p_plan: e.plan,
    p_environment: e.environment,
    p_status: e.status,
    p_expires_at: e.expires_at,
    p_auto_renew: e.auto_renew,
    p_notification_type: e.notification_type,
  });
  if (!error) return true;
  if (/RP\d{3}:/.test(error.message)) {
    // The message names a check, never a payload value or a credential.
    console.log(`apple notification refused by apply_apple_entitlement: ${error.message}`);
    return false;
  }
  throw new HttpError(503, "Could not apply the entitlement — retry", "upstream");
}

