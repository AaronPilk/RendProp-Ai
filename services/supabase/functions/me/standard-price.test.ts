import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";
import { HttpError } from "../_shared/http.ts";
import type { WorkspaceDirectory } from "../_shared/workspaces.ts";
import { decodeVerifiedAppTransaction, noActiveAppleChain, prepareStandardPrice, signStandardPriceOption,
  STANDARD_PRICE_PRODUCT, standardPriceContext, standardPriceSigningReady, verifyProductionAppTransaction } from "./standard-price.ts";

const ACTOR = "a0000000-0000-4000-8000-000000000001";
const ORG = "a0000000-0000-4000-8000-000000000002";
const OTHER = "a0000000-0000-4000-8000-000000000003";
const TRANSACTION = "1000000123456789";
const directory: WorkspaceDirectory = { actor_id: ACTOR, own_org_id: ORG, billing_org_id: ORG,
  can_switch_agent_libraries: false, active_org_id: ORG, workspaces: [] };
const access = { actor_id: ACTOR, org_id: ORG, library_owner_user_id: ACTOR, role: "owner" as const,
  access_mode: "own" as const, billing_org_id: ORG, team_org_id: null,
  can_read: true, can_write: true, can_manage_subscription: true };
const appPayload = (date: number): Record<string, unknown> => ({ appAppleId: 6808982413,
  appTransactionId: TRANSACTION, bundleId: "com.rendprop.app", receiptType: "Production",
  receiptCreationDate: date, originalPurchaseDate: date - 86_400_000, originalApplicationVersion: "1.0" });

function decodePart(part: string): Record<string, unknown> {
  const raw = atob(part.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - part.length % 4) % 4));
  return JSON.parse(new TextDecoder().decode(Uint8Array.from(raw, (c) => c.charCodeAt(0))));
}
function decodeBytes(part: string): Uint8Array<ArrayBuffer> {
  const raw = atob(part.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - part.length % 4) % 4));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}
function pem(bytes: Uint8Array): string {
  let raw = ""; for (const byte of bytes) raw += String.fromCharCode(byte);
  return `-----BEGIN PRIVATE KEY-----\n${btoa(raw)}\n-----END PRIVATE KEY-----`;
}

Deno.test("standard-price JWS has Apple's exact no-intro claims and a real ES256 signature", async () => {
  const names = ["APPLE_IAP_KEY_ID", "APPLE_IAP_ISSUER_ID", "APPLE_IAP_PRIVATE_KEY_P8"];
  const prior = names.map((name) => Deno.env.get(name));
  try {
    for (const name of names) Deno.env.delete(name);
    assertEquals(await standardPriceSigningReady(), false);
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const privateBytes = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
    Deno.env.set("APPLE_IAP_KEY_ID", "TESTKEY123");
    Deno.env.set("APPLE_IAP_ISSUER_ID", "f0000000-0000-4000-8000-000000000001");
    Deno.env.set("APPLE_IAP_PRIVATE_KEY_P8", pem(privateBytes));
    assertEquals(await standardPriceSigningReady(), true);
    const first = await signStandardPriceOption(TRANSACTION, 1_800_000_000_000);
    const second = await signStandardPriceOption(TRANSACTION, 1_800_000_000_000);
    assertEquals(first.issued_at, 1_800_000_000);
    const parts = first.compact_jws.split(".");
    assertEquals(parts.length, 3);
    assertEquals(decodePart(parts[0]), { alg: "ES256", kid: "TESTKEY123", typ: "JWT" });
    const payload = decodePart(parts[1]);
    assertEquals(payload.iss, "f0000000-0000-4000-8000-000000000001");
    assertEquals(payload.iat, first.issued_at);
    assertEquals(payload.aud, "introductory-offer-eligibility");
    assertEquals(payload.bid, "com.rendprop.app");
    assertEquals(payload.productId, STANDARD_PRICE_PRODUCT);
    assertEquals(payload.allowIntroductoryOffer, false);
    assertEquals(payload.transactionId, TRANSACTION);
    assert(!("exp" in payload) && !("actor_id" in payload) && !("org_id" in payload));
    assert(typeof payload.nonce === "string" && /^[0-9a-f-]{36}$/.test(payload.nonce));
    assert((await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey,
      decodeBytes(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`))));
    assert(decodePart(second.compact_jws.split(".")[1]).nonce !== payload.nonce);
    Deno.env.set("APPLE_IAP_PRIVATE_KEY_P8", "malformed");
    assertEquals(await standardPriceSigningReady(), false);
    await assertRejects(() => signStandardPriceOption(TRANSACTION), HttpError, "unavailable");
  } finally {
    names.forEach((name, i) => prior[i] === undefined ? Deno.env.delete(name) : Deno.env.set(name, prior[i]!));
  }
});

Deno.test("AppTransaction decoder rejects wrong app, sandbox, transaction-shaped and missing signed time", async () => {
  const date = Date.now() - 60_000;
  assertEquals(decodeVerifiedAppTransaction(appPayload(date), date).appTransactionId, TRANSACTION);
  for (const changed of [
    { bundleId: "com.other.app" }, { appAppleId: 1 }, { receiptType: "Sandbox" },
    { appTransactionId: "not-a-transaction" }, { receiptCreationDate: date + 1 },
    { originalPurchaseDate: date + 1 }, { originalApplicationVersion: "" }, { productId: STANDARD_PRICE_PRODUCT },
  ]) {
    await assertRejects(async () => decodeVerifiedAppTransaction({ ...appPayload(date), ...changed }, date), HttpError);
  }
  const unsigned = `${btoa("{}")}.${
    btoa(JSON.stringify(appPayload(Date.now() + 10 * 60_000))).replace(/=/g, "")}.signature`;
  await assertRejects(() => verifyProductionAppTransaction(unsigned), HttpError);
});

Deno.test("full-price authority is exact actor, selected own billing workspace, owner and free plan", () => {
  assert(standardPriceContext(ACTOR, directory, ORG, access, "free", "trial"));
  assert(!standardPriceContext(ACTOR, { ...directory, active_org_id: OTHER }, ORG, access, "free", null));
  assert(!standardPriceContext(ACTOR, { ...directory, own_org_id: OTHER }, ORG, access, "free", null));
  assert(!standardPriceContext(OTHER, directory, ORG, access, "free", null));
  assert(!standardPriceContext(ACTOR, directory, ORG, { ...access, role: "admin" }, "free", null));
  assert(!standardPriceContext(ACTOR, directory, ORG, { ...access, billing_org_id: OTHER }, "free", null));
  assert(!standardPriceContext(ACTOR, directory, ORG, access, "trial", null));
  assert(!standardPriceContext(ACTOR, directory, ORG, access, "free", "manual"));
});

Deno.test("active Apple chain guard includes legacy user ownership when token is absent", async () => {
  let predicate = "";
  const chain = {
    select() { return chain; },
    or(value: string) { predicate = value; return chain; },
    in() { return chain; },
    limit() { return Promise.resolve({ data: [{ original_transaction_id: "legacy-active" }], error: null }); },
  };
  const admin = { from(table: string) { assertEquals(table, "apple_subscriptions"); return chain; } } as unknown as SupabaseClient;
  assertEquals(await noActiveAppleChain(admin, ACTOR, ORG), false);
  assertEquals(predicate, `org_id.eq.${ORG},app_account_token.eq.${ACTOR},user_id.eq.${ACTOR}`);
});

function adminFixture(options: {role?:string; plan?:string; active?:boolean} = {}) {
  const calls: string[] = [];
  const admin = {
    rpc(name: string) {
      calls.push(name);
      if (name === "library_access") return Promise.resolve({ data: { ...access, role: options.role ?? "owner" }, error: null });
      if (name === "effective_plan") return Promise.resolve({ data: options.plan ?? "free", error: null });
      throw new Error(`Unexpected RPC ${name}`);
    },
    from(table: string) {
      calls.push(table);
      const chain = {
        select() { return chain; }, eq() { return chain; }, or() { return chain; }, is() { return chain; }, in() { return chain; },
        maybeSingle() { return Promise.resolve({ data: { id: ORG, plan_source: "trial" }, error: null }); },
        limit() { return Promise.resolve({ data: options.active ? [{ original_transaction_id: "existing" }] : [], error: null }); },
      };
      return chain;
    },
  } as unknown as SupabaseClient;
  return { admin, calls };
}

Deno.test("prepare refuses changed workspace, non-owner, paid plan and active chain before Apple proof or signing", async () => {
  const body = { org_id: ORG, product_id: STANDARD_PRICE_PRODUCT, signed_app_transaction: "unsigned" };
  const mismatch = adminFixture();
  await assertRejects(() => prepareStandardPrice(mismatch.admin, ACTOR, directory, { ...body, org_id: OTHER }), HttpError, "workspace changed");
  assertEquals(mismatch.calls, []);
  for (const options of [{ role: "agent" }, { plan: "pro" }, { active: true }]) {
    const fixture = adminFixture(options);
    await assertRejects(() => prepareStandardPrice(fixture.admin, ACTOR, directory, body), HttpError);
    assert(!fixture.calls.some((name) => /fund|trial|entitlement|grant|apply/.test(name)));
  }
  const exact = adminFixture();
  await assertRejects(() => prepareStandardPrice(exact.admin, ACTOR, directory, body), HttpError,
    "Apple app transaction could not be verified");
});
