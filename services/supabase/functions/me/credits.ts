import type { SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";
import { decodeTransaction, verifyAppleJWS } from "../_shared/applejws.ts";
import { assert, HttpError, json, readJsonLimited, throwRpc } from "../_shared/http.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { requestedWorkspace, workspaceDirectory, workspaceID } from "../_shared/workspaces.ts";

const APPLE_BUNDLE_ID = (Deno.env.get("APPLE_BUNDLE_ID") ?? "com.rendprop.app").trim();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NO_STORE = { "cache-control": "no-store" };

function appleEnvironment(value: unknown): "Production" | "Sandbox" {
  assert(value === "Production" || value === "Sandbox", 400, "Choose the App Store environment.");
  return value;
}

function rpcError(error: { message: string } | null, fallback: string): void {
  if (!error) return;
  if (/RP\d{3}:/.test(error.message)) throwRpc(error.message);
  throw new HttpError(503, fallback, "upstream");
}

async function memberOrg(admin: SupabaseClient, actor: string, org: string): Promise<string> {
  const [membership, workspace] = await Promise.all([
    admin.from("memberships").select("role").eq("user_id", actor).eq("org_id", org).maybeSingle(),
    admin.from("orgs").select("id").eq("id", org).is("deleted_at", null).maybeSingle(),
  ]);
  assert(!membership.error && !workspace.error, 503, "Credit workspace could not be verified.");
  assert(membership.data && workspace.data?.id === org, 403, "Choose a current workspace you belong to.");
  assert(typeof membership.data.role === "string", 503, "Credit workspace role could not be verified.");
  return membership.data.role;
}

async function wallet(admin: SupabaseClient, org: string, environment: string): Promise<Record<string, unknown>> {
  const { data, error } = await admin.rpc("credit_wallet_state", { p_org: org, p_environment: environment });
  rpcError(error, "Credit balance could not be loaded. Please retry.");
  assert(data && typeof data === "object" && !Array.isArray(data) && data.org_id === org &&
    data.environment === environment && Number.isInteger(data.total_available) &&
    Number.isInteger(data.monthly_available) && Number.isInteger(data.topup_available) &&
    Number.isInteger(data.held), 503, "Credit balance could not be verified.");
  return data as Record<string, unknown>;
}

/** An org-scoped customer-credit API. Every amount comes from server catalog
 * rows and verified Apple data; neither the actor nor a client price is used
 * as a billing authority. The production and TestFlight ledgers are separate. */
export async function creditsRoute(
  req: Request, admin: SupabaseClient, actor: string,
  segment: string | undefined, subsegment: string | undefined,
): Promise<Response> {
  if (segment === undefined && subsegment === undefined && req.method === "GET") {
    const url = new URL(req.url);
    const environment = appleEnvironment(url.searchParams.get("environment") ?? "Production");
    const org = url.searchParams.has("org_id") ? workspaceID(url.searchParams.get("org_id")) :
      (await workspaceDirectory(admin, actor, requestedWorkspace(req))).billing_org_id;
    const role = await memberOrg(admin, actor, org);
    const [balance, products, quotes, primary, effective, trial] = await Promise.all([
      wallet(admin, org, environment),
      admin.from("credit_products").select("product_id,credits").eq("active", true).order("credits"),
      admin.from("credit_tariffs").select("operation,version,credits").eq("active", true).order("operation"),
      admin.rpc("credit_primary_subscription",{p_org:org,p_environment:environment}),
      admin.rpc("effective_plan",{p_org:org}),
      admin.rpc("subscription_trial_context",{p_actor:actor,p_org:org}),
    ]);
    assert(!products.error && !quotes.error && !primary.error && !effective.error && !trial.error &&
      typeof primary.data === "boolean" && typeof effective.data === "string", 503,
      "Credit catalog could not be loaded.");
    const trialUsage=trial.data && typeof trial.data === "object" && !Array.isArray(trial.data)
      ? (trial.data as Record<string,unknown>).trial_usage : null;
    const trialActive=trialUsage && typeof trialUsage === "object" && !Array.isArray(trialUsage) &&
      (trialUsage as Record<string,unknown>).status === "active";
    const fundingMode=primary.data?"credit_primary":trialActive?"included":
      effective.data==="free"?"topup_only":"included";
    return json({ org_id: org, environment, balance,
      funding_mode:fundingMode,
      can_purchase:role === "owner" || role === "admin",
      products: products.data ?? [],
      quotes: (quotes.data ?? []).map((q) => ({ operation: q.operation, credits: q.credits,
        tariff_version: q.version })) }, 200, NO_STORE);
  }

  if (segment === "purchase-intents" && subsegment === undefined && req.method === "GET") {
    const { data, error } = await admin.from("credit_purchase_intents")
      .select("id,org_id,product_id,app_account_token,state,created_at")
      .eq("actor_id", actor).eq("state", "open").order("created_at", { ascending: false }).limit(20);
    assert(!error, 503, "Pending credit purchases could not be loaded.");
    return json({ intents: (data ?? []).map((r) => ({ intent_id: r.id, org_id: r.org_id,
      product_id: r.product_id, app_account_token: r.app_account_token,
      state: r.state, created_at: r.created_at, expires_at: null })) },
      200, NO_STORE);
  }

  if (segment === "purchase-intent" && subsegment === undefined && req.method === "POST") {
    assert(await durableRateLimit(`credit-intent:${actor}`, 12, 300), 429,
      "Please wait before starting another credit purchase.");
    const body = await readJsonLimited<{ expected_org_id?: unknown; product_id?: unknown }>(req, 2048);
    const org = workspaceID(body.expected_org_id);
    assert(typeof body.product_id === "string" && body.product_id.length <= 160, 400,
      "Choose an available credit pack.");
    const { data, error } = await admin.rpc("credit_purchase_intent_create", {
      p_actor: actor, p_org: org, p_product: body.product_id,
    });
    rpcError(error, "Credit purchase could not be prepared. Please retry.");
    assert(data?.org_id === org && data?.product_id === body.product_id &&
      typeof data.intent_id === "string" && UUID.test(data.intent_id) &&
      typeof data.app_account_token === "string" && UUID.test(data.app_account_token), 503,
      "Credit purchase binding could not be verified.");
    return json({ intent_id: data.intent_id, org_id: org, product_id: body.product_id,
      app_account_token: data.app_account_token, created_at: data.created_at, expires_at: null,
      replay: data.replay === true }, 200, NO_STORE);
  }

  if (segment === "purchase-intent" && subsegment === "abandon" && req.method === "POST") {
    const body = await readJsonLimited<{ intent_id?: unknown; expected_org_id?: unknown }>(req, 2048);
    const intent = workspaceID(body.intent_id), org = workspaceID(body.expected_org_id);
    const { data, error } = await admin.rpc("credit_purchase_intent_abandon", {
      p_actor: actor, p_intent: intent, p_expected_org: org,
    });
    rpcError(error, "Credit purchase could not be dismissed. Please retry.");
    assert(data?.intent_id === intent && data?.org_id === org &&
      (data?.state === "abandoned" || data?.state === "fulfilled"), 503,
      "Credit purchase state could not be verified.");
    return json(data, 200, NO_STORE);
  }

  if (segment === "purchase" && subsegment === undefined && req.method === "POST") {
    assert(await durableRateLimit(`credit-purchase:${actor}`, 30, 300), 429,
      "Please wait before checking this credit purchase again.");
    const body = await readJsonLimited<{
      signed_transaction?: unknown; expected_org_id?: unknown; intent_id?: unknown;
    }>(req, 70_000);
    assert(typeof body.signed_transaction === "string" && body.signed_transaction.length > 0 &&
      body.signed_transaction.length <= 64 * 1024, 400, "Apple's signed purchase is required.");
    const tx = decodeTransaction(await verifyAppleJWS(body.signed_transaction));
    assert(tx.bundleId === APPLE_BUNDLE_ID, 400, "That purchase belongs to a different app.");
    assert(tx.type === "Consumable" && tx.expiresDate === null, 400,
      "That Apple transaction is not a credit purchase.");
    assert(tx.quantity === undefined || tx.quantity === 1, 400,
      "Only one credit pack can be delivered per Apple transaction.");
    assert(tx.inAppOwnershipType === null || tx.inAppOwnershipType === "PURCHASED", 403,
      "That credit pack belongs to another Apple account.");
    assert(typeof tx.appAccountToken === "string" && UUID.test(tx.appAccountToken), 403,
      "This credit purchase has no Rendprop purchase binding.");
    assert(tx.purchaseDate !== null, 400, "Apple's purchase date is missing.");
    const expectedOrg = body.expected_org_id === undefined ? null : workspaceID(body.expected_org_id);
    const intent = body.intent_id === undefined ? null : workspaceID(body.intent_id);
    // A revoked JWS must return an acknowledged zero-credit receipt so
    // StoreKit can finish it. Persist the refund before the grant RPC; that
    // RPC then binds the original intent but cannot create spendable credit.
    if (tx.revocationDate !== null) {
      const bytes = new TextEncoder().encode(body.signed_transaction);
      const digest = await crypto.subtle.digest("SHA-256", bytes);
      const evidence = Array.from(new Uint8Array(digest), (n) => n.toString(16).padStart(2, "0")).join("");
      const revoked = await admin.rpc("credit_purchase_refund", {
        p_environment: tx.environment, p_transaction: tx.transactionId,
        p_evidence_sha256: evidence, p_revoked_at: tx.revocationDate,
      });
      rpcError(revoked.error, "Credit refund could not be recorded. Please retry.");
      assert(revoked.data?.refunded === true, 503, "Credit refund could not be verified.");
    }
    const { data, error } = await admin.rpc("credit_purchase_grant", {
      p_actor: actor, p_expected_org: expectedOrg, p_intent: intent,
      p_product: tx.productId, p_environment: tx.environment,
      p_transaction: tx.transactionId, p_purchased_at: tx.purchaseDate,
      p_signed_at: tx.signedDate, p_account_token: tx.appAccountToken,
      p_price_milliunits: tx.priceMilliunits, p_currency: tx.currency,
      p_storefront: tx.storefront,
    });
    rpcError(error, "Credit purchase could not be recorded. Please retry.");
    assert(data && typeof data.org_id === "string" && UUID.test(data.org_id) &&
      data.transaction_id === tx.transactionId && data.environment === tx.environment &&
      Number.isInteger(data.credits_granted), 503,
      "Credit purchase receipt could not be verified.");
    const balance = await wallet(admin, data.org_id, tx.environment);
    return json({ transaction_id: tx.transactionId, org_id: data.org_id,
      environment: tx.environment, credits_granted: data.credits_granted,
      refunded: data.refunded === true, replay: data.replay === true, balance }, 200, NO_STORE);
  }
  throw new HttpError(404, "Unknown credit route.");
}
