// A signed StoreKit purchase option for an explicitly chosen full-price Pro
// subscription. This only suppresses Apple's introductory offer. It never
// creates an entitlement, releases a trial hold, or settles a receipt.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";
import { verifyAppleJWS } from "../_shared/applejws.ts";
import { assert, HttpError } from "../_shared/http.ts";
import { libraryAccess } from "../_shared/library-access.ts";
import type { WorkspaceDirectory } from "../_shared/workspaces.ts";

export const STANDARD_PRICE_PRODUCT = "com.rendprop.app.pro29.monthly";
const BUNDLE_ID = "com.rendprop.app";
// Public App Store app identifier; the Apple-signed AppTransaction must match it.
const APP_APPLE_ID = 6808982413;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const APP_TRANSACTION_ID = /^[0-9]{1,32}$/;
const MIN_RECEIPT_MS = Date.UTC(2014, 3, 30);
const MAX_FUTURE_SKEW_MS = 5 * 60 * 1000;
const MAX_APP_JWS_CHARS = 64 * 1024;
const unavailable = "Standard-price checkout is unavailable. Please try again later.";

type Signer = { keyId: string; issuerId: string; key: CryptoKey };
type VerifiedAppTransaction = { appTransactionId: string; receiptCreationDate: number };
type PrepareBody = { org_id?: unknown; product_id?: unknown; signed_app_transaction?: unknown } | null;
type PurchaseEnvironment = "Production" | "Sandbox";
type PreparedOption = {actor_id:string;org_id:string;product_id:string;app_transaction_id:string;
  compact_jws:string;issued_at:number;purchase_environment:PurchaseEnvironment};

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
function jsonPart(value: unknown): string {
  return base64url(new TextEncoder().encode(JSON.stringify(value)));
}
function untrustedReceiptDate(jws: string, nowMs: number): number {
  assert(jws.length > 0 && jws.length <= MAX_APP_JWS_CHARS, 400, "A signed Apple app transaction is required.");
  const parts = jws.split(".");
  assert(parts.length === 3 && /^[A-Za-z0-9_-]+$/.test(parts[1]), 401, "Apple app transaction could not be verified.");
  try {
    const raw = atob(parts[1].replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - parts[1].length % 4) % 4));
    const payload = JSON.parse(new TextDecoder().decode(Uint8Array.from(raw, (char) => char.charCodeAt(0))));
    const date = payload?.receiptCreationDate;
    assert(Number.isSafeInteger(date) && date >= MIN_RECEIPT_MS && date <= nowMs + MAX_FUTURE_SKEW_MS,
      401, "Apple app transaction could not be verified.");
    // The date is used only for certificate validity. The same payload must
    // then pass Apple's pinned-chain signature check before any field is used.
    return date;
  } catch {
    throw new HttpError(401, "Apple app transaction could not be verified.", "unauthorized");
  }
}

/** AppTransaction has receiptType/receiptCreationDate, unlike an IAP transaction. */
export function decodeVerifiedAppTransaction(payload: Record<string, unknown>, verifiedAt: number,
  environment: PurchaseEnvironment = "Production"): VerifiedAppTransaction {
  assert(payload.bundleId === BUNDLE_ID &&
    (environment === "Production" ? payload.appAppleId === APP_APPLE_ID :
      (payload.appAppleId === undefined || payload.appAppleId === APP_APPLE_ID)) &&
    payload.receiptType === environment &&
    typeof payload.appTransactionId === "string" && APP_TRANSACTION_ID.test(payload.appTransactionId) &&
    payload.receiptCreationDate === verifiedAt && typeof payload.originalApplicationVersion === "string" &&
    payload.originalApplicationVersion.length > 0 && Number.isSafeInteger(payload.originalPurchaseDate) &&
    (payload.originalPurchaseDate as number) <= verifiedAt && payload.productId === undefined,
    401, "Apple app transaction could not be verified.", "unauthorized");
  return { appTransactionId: payload.appTransactionId as string, receiptCreationDate: verifiedAt };
}

export async function verifyProductionAppTransaction(jws: string, nowMs = Date.now()): Promise<VerifiedAppTransaction> {
  const signedAt = untrustedReceiptDate(jws, nowMs);
  const payload = await verifyAppleJWS(jws, { now: new Date(signedAt) });
  return decodeVerifiedAppTransaction(payload, signedAt);
}

export async function verifySandboxAppTransaction(jws: string, nowMs = Date.now()): Promise<VerifiedAppTransaction> {
  const signedAt = untrustedReceiptDate(jws, nowMs);
  const payload = await verifyAppleJWS(jws, { now: new Date(signedAt) });
  return decodeVerifiedAppTransaction(payload, signedAt, "Sandbox");
}

async function loadIapSigner(): Promise<Signer | null> {
  const keyId = Deno.env.get("APPLE_IAP_KEY_ID")?.trim() ?? "";
  const issuerId = Deno.env.get("APPLE_IAP_ISSUER_ID")?.trim() ?? "";
  const pem = Deno.env.get("APPLE_IAP_PRIVATE_KEY_P8")?.replace(/\\n/g, "\n").trim() ?? "";
  if (!/^[A-Z0-9]{10}$/.test(keyId) || !UUID.test(issuerId) ||
      !/^-----BEGIN PRIVATE KEY-----[\s\S]+-----END PRIVATE KEY-----$/.test(pem)) return null;
  try {
    const encoded = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
    const raw = atob(encoded);
    const key = await crypto.subtle.importKey("pkcs8", Uint8Array.from(raw, (char) => char.charCodeAt(0)),
      { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    return { keyId, issuerId, key };
  } catch {
    return null;
  }
}

/** Capability for billing UI. A missing or malformed dedicated IAP key fails closed. */
export async function standardPriceSigningReady(): Promise<boolean> {
  return (await loadIapSigner()) !== null;
}

export async function signStandardPriceOption(appTransactionId: string, nowMs = Date.now()): Promise<{compact_jws: string; issued_at: number}> {
  const signer = await loadIapSigner();
  if (!signer) throw new HttpError(503, unavailable, "upstream");
  assert(APP_TRANSACTION_ID.test(appTransactionId), 401, "Apple app transaction could not be verified.", "unauthorized");
  const issuedAt = Math.floor(nowMs / 1000);
  const header = jsonPart({ alg: "ES256", kid: signer.keyId, typ: "JWT" });
  const payload = jsonPart({ iss: signer.issuerId, iat: issuedAt, aud: "introductory-offer-eligibility", bid: BUNDLE_ID,
    nonce: crypto.randomUUID(), productId: STANDARD_PRICE_PRODUCT, allowIntroductoryOffer: false, transactionId: appTransactionId });
  const input = `${header}.${payload}`;
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signer.key,
    new TextEncoder().encode(input)));
  assert(signature.length === 64, 503, unavailable, "upstream");
  return { compact_jws: `${input}.${base64url(signature)}`, issued_at: issuedAt };
}

/** Shared authorization shape for GET readiness and POST issuance. */
export function standardPriceOwnerContext(actor: string, directory: WorkspaceDirectory, org: string,
  access: { actor_id: string; org_id: string; role: string; access_mode: string; billing_org_id: string; can_manage_subscription: boolean },
  source: string | null): boolean {
  return directory.actor_id === actor && directory.active_org_id === org && directory.own_org_id === org &&
    directory.billing_org_id === org && access.actor_id === actor && access.org_id === org &&
    access.role === "owner" && access.access_mode === "own" && access.billing_org_id === org &&
    access.can_manage_subscription === true && source !== "manual";
}

export function standardPriceContext(actor: string, directory: WorkspaceDirectory, org: string,
  access: { actor_id: string; org_id: string; role: string; access_mode: string; billing_org_id: string; can_manage_subscription: boolean },
  effectivePlan: string, source: string | null): boolean {
  return standardPriceOwnerContext(actor, directory, org, access, source) && effectivePlan === "free";
}

export async function noActiveAppleChain(admin: SupabaseClient, actor: string, org: string): Promise<boolean> {
  const { data, error } = await admin.from("apple_subscriptions").select("original_transaction_id")
    .or(`org_id.eq.${org},app_account_token.eq.${actor},user_id.eq.${actor}`).in("status", ["active", "grace"]).limit(1);
  if (error) throw new HttpError(503, "Subscription status could not be verified. Please retry.", "upstream");
  return Array.isArray(data) && data.length === 0;
}

function validDate(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}
function cents(value: unknown): number | null {
  const parsed = typeof value === "number" ? value : typeof value === "string" && value.trim() ? Number(value) : NaN;
  return Number.isFinite(parsed) && parsed >= 0 && parsed <= 500 ? parsed : null;
}

/** A test purchase is issued only for a current, finite and independently
 * funded App Review workspace. These are reads; the signed Sandbox receipt
 * continues through the existing test-only settlement path. */
export async function sandboxStandardPriceAuthority(admin: SupabaseClient, actor: string, org: string,
  nowMs = Date.now()): Promise<boolean> {
  const now = new Date(nowMs).toISOString();
  const [review, internal, privateTest, fundingResult] = await Promise.all([
    admin.rpc("org_has_app_review_funding", { p_org: org }),
    admin.rpc("org_has_internal_testing_grant", { p_org: org }),
    admin.rpc("org_has_private_internal_testing", { p_org: org }),
    admin.from("serving_funding").select("id,org_id,source,actor_id,net_receipts_cents,sponsored_cents,starts_at,ends_at,retention_ends_at,service_months,recurring_reserve_cents,revoked_at")
      .eq("org_id", org).eq("source", "app_review").is("revoked_at", null)
      .lte("starts_at", now).gt("ends_at", now).limit(2),
  ]);
  if (review.error || internal.error || privateTest.error || fundingResult.error)
    throw new HttpError(503, "Current test purchase authority could not be verified. Please retry.", "upstream");
  if (review.data !== true || internal.data !== false || privateTest.data !== false ||
      !Array.isArray(fundingResult.data) || fundingResult.data.length !== 1) return false;
  const funding = fundingResult.data[0];
  const start = validDate(funding.starts_at), end = validDate(funding.ends_at);
  const retentionEnd = validDate(funding.retention_ends_at);
  const sponsored = cents(funding.sponsored_cents), recurring = cents(funding.recurring_reserve_cents);
  if (typeof funding.id !== "string" || !UUID.test(funding.id) || funding.org_id !== org ||
      funding.source !== "app_review" || funding.actor_id !== actor || funding.revoked_at !== null ||
      Number(funding.net_receipts_cents) !== 0 || funding.service_months !== 1 ||
      start === null || end === null || retentionEnd !== end || start > nowMs || end <= nowMs ||
      end <= start || end - start > 7 * 86_400_000 || sponsored === null || sponsored <= 0 ||
      recurring === null || recurring > sponsored) return false;
  const [sliceResult, budgetResult, spentResult] = await Promise.all([
    admin.from("serving_funding_slices").select("funding_id,slice_index,org_id,starts_at,ends_at,total_budget_cents,recurring_reserve_cents")
      .eq("funding_id", funding.id).eq("slice_index", 0).maybeSingle(),
    admin.from("media_delivery_budgets").select("funding_id,org_id,starts_at,ends_at,request_limit,byte_limit,storage_limit,account_reserve_ref")
      .eq("funding_id", funding.id).maybeSingle(),
    // Exact count detects PostgREST's row cap. If this read cannot prove a
    // complete supplier-spend total, the test purchase remains unavailable.
    admin.from("serving_cost_reservations").select("hold_cents", { count: "exact" }).eq("funding_id", funding.id)
      .eq("slice_index", 0).neq("state", "rejected").limit(1000),
  ]);
  if (sliceResult.error || budgetResult.error || spentResult.error)
    throw new HttpError(503, "Current test purchase authority could not be verified. Please retry.", "upstream");
  const slice = sliceResult.data, budget = budgetResult.data;
  if (!slice || !budget || !Array.isArray(spentResult.data) ||
      !Number.isSafeInteger(spentResult.count) || spentResult.count !== spentResult.data.length ||
      spentResult.data.length > 1000 ||
      slice.funding_id !== funding.id || slice.slice_index !== 0 || slice.org_id !== org ||
      validDate(slice.starts_at) !== start || validDate(slice.ends_at) !== end ||
      cents(slice.total_budget_cents) !== sponsored || cents(slice.recurring_reserve_cents) !== recurring ||
      budget.funding_id !== funding.id || budget.org_id !== org ||
      validDate(budget.starts_at) !== start || validDate(budget.ends_at) !== retentionEnd ||
      Number(budget.request_limit) < 1 || Number(budget.byte_limit) < 1 ||
      Number(budget.storage_limit) < 1 || typeof budget.account_reserve_ref !== "string" ||
      budget.account_reserve_ref.length < 8) return false;
  let spent = 0;
  for (const row of spentResult.data) {
    const hold = cents(row.hold_cents);
    if (hold === null) return false;
    spent += hold;
    if (spent > sponsored - recurring) return false;
  }
  return true;
}

export async function prepareStandardPrice(admin: SupabaseClient, actor: string, directory: WorkspaceDirectory,
  body: unknown): Promise<PreparedOption> {
  const request = body as PrepareBody;
  const org = directory.active_org_id;
  assert(request && request.org_id === org, 409, "Your workspace changed. Refresh before purchasing.", "conflict");
  assert(request.product_id === STANDARD_PRICE_PRODUCT, 400, "Choose the supported Pro monthly subscription.");
  assert(typeof request.signed_app_transaction === "string" && request.signed_app_transaction.length <= MAX_APP_JWS_CHARS,
    400, "A signed Apple app transaction is required.");
  const [access, orgResult, planResult] = await Promise.all([
    libraryAccess(admin, actor, org),
    admin.from("orgs").select("id,plan_source").eq("id", org).is("deleted_at", null).maybeSingle(),
    admin.rpc("effective_plan", { p_org: org }),
  ]);
  if (orgResult.error || planResult.error || orgResult.data?.id !== org || typeof planResult.data !== "string")
    throw new HttpError(503, "Subscription eligibility could not be verified. Please retry.", "upstream");
  assert(standardPriceContext(actor, directory, org, access, planResult.data, orgResult.data.plan_source ?? null),
    403, "Only the owner of this selected billing workspace can start this purchase.", "forbidden");
  assert(await noActiveAppleChain(admin, actor, org), 409, "This account or workspace already has an active App Store subscription.", "conflict");
  const app = await verifyProductionAppTransaction(request.signed_app_transaction);
  const signed = await signStandardPriceOption(app.appTransactionId);
  return { actor_id: actor, org_id: org, product_id: STANDARD_PRICE_PRODUCT,
    app_transaction_id: app.appTransactionId, ...signed, purchase_environment: "Production" };
}

export async function prepareSandboxStandardPrice(admin: SupabaseClient, actor: string, directory: WorkspaceDirectory,
  body: unknown, proof: { verify: typeof verifySandboxAppTransaction; sign: typeof signStandardPriceOption } =
    { verify: verifySandboxAppTransaction, sign: signStandardPriceOption }): Promise<PreparedOption> {
  const request = body as PrepareBody;
  const org = directory.active_org_id;
  assert(request && request.org_id === org, 409, "Your workspace changed. Refresh before purchasing.", "conflict");
  assert(request.product_id === STANDARD_PRICE_PRODUCT, 400, "Choose the supported Pro monthly subscription.");
  assert(typeof request.signed_app_transaction === "string" && request.signed_app_transaction.length <= MAX_APP_JWS_CHARS,
    400, "A signed Apple app transaction is required.");
  const [access, orgResult, planResult] = await Promise.all([
    libraryAccess(admin, actor, org),
    admin.from("orgs").select("id,plan_source").eq("id", org).is("deleted_at", null).maybeSingle(),
    admin.rpc("effective_plan", { p_org: org }),
  ]);
  if (orgResult.error || planResult.error || orgResult.data?.id !== org || typeof planResult.data !== "string")
    throw new HttpError(503, "Subscription eligibility could not be verified. Please retry.", "upstream");
  assert(standardPriceOwnerContext(actor, directory, org, access, orgResult.data.plan_source ?? null) &&
    planResult.data === "pro", 403, "Only the owner of this selected billing workspace can start this purchase.", "forbidden");
  assert(await noActiveAppleChain(admin, actor, org), 409,
    "This account or workspace already has an active App Store subscription.", "conflict");
  assert(await sandboxStandardPriceAuthority(admin, actor, org), 403,
    "Current bounded App Review test access is required for this test purchase.", "forbidden");
  const app = await proof.verify(request.signed_app_transaction);
  const signed = await proof.sign(app.appTransactionId);
  // Supplier authority can change while an Apple option is being signed.
  assert(await sandboxStandardPriceAuthority(admin, actor, org) && await noActiveAppleChain(admin, actor, org),
    403, "Current bounded App Review test access is required for this test purchase.", "forbidden");
  return { actor_id: actor, org_id: org, product_id: STANDARD_PRICE_PRODUCT,
    app_transaction_id: app.appTransactionId, ...signed, purchase_environment: "Sandbox" };
}
