import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";
import { creditsRoute } from "./credits.ts";

const org = "91111111-1111-4111-8111-111111111111";
const actor = "92222222-2222-4222-8222-222222222222";

function db(role: string, trial = false, primary = true,
            catalogActive = true, sandboxAuthorized = false): SupabaseClient {
  const from = (table: string) => {
    const query = {
      select: () => query, eq: () => query, is: () => query,
      order: () => query, limit: () => query,
      maybeSingle: async () => ({ data: table === "memberships" ? { role } : { id: org }, error: null }),
      then: (resolve: (value: unknown) => void) => resolve({ data: table === "credit_products"
        ? [{ product_id: "com.rendprop.app.credits.100", credits: 100, active: catalogActive }]
        : [{ operation: "photo.declutter", version: "photo-declutter-v1", credits: 10 }], error: null }),
    };
    return query;
  };
  const rpc = async (name: string, args?: Record<string, unknown>) => ({ data: name === "credit_wallet_state"
    ? { org_id: org, environment: args?.p_environment, total_available: 0,
      monthly_available: 0, topup_available: 0, held: 0 }
    : name === "credit_sandbox_pack_authorized" ? sandboxAuthorized
    : name === "credit_primary_subscription" ? primary
    : name === "subscription_trial_context" ? { trial_usage: trial
      ? { org_id: org, status: "active" } : null }
    : primary ? "max" : "free", error: null });
  return { from, rpc } as unknown as SupabaseClient;
}

Deno.test("credit wallet shows only current owners/admins a purchase action", async () => {
  for (const role of ["owner", "admin", "agent", "marketing"]) {
    const response = await creditsRoute(
      new Request(`https://example.invalid/me/credits?org_id=${org}&environment=Production`),
      db(role), actor, undefined, undefined);
    assertEquals(response.status, 200);
    const result = await response.json();
    assertEquals(result.can_purchase, role === "owner" || role === "admin");
    assertEquals(result.funding_mode, "credit_primary");
    assertEquals(result.quotes[0].credits, 10);
  }
});

Deno.test("active funded trial keeps its included photo path; Free top-ups use credits", async () => {
  const url = `https://example.invalid/me/credits?org_id=${org}&environment=Production`;
  const trial = await creditsRoute(new Request(url), db("owner", true, false), actor, undefined, undefined);
  assertEquals((await trial.json()).funding_mode, "included");
  const free = await creditsRoute(new Request(url), db("owner", false, false), actor, undefined, undefined);
  assertEquals((await free.json()).funding_mode, "topup_only");
});

Deno.test("claiming Sandbox alone never exposes a dormant credit pack", async () => {
  for (const environment of ["Sandbox", "Production"]) {
    const response = await creditsRoute(
      new Request(`https://example.invalid/me/credits?org_id=${org}&environment=${environment}`),
      db("owner", false, true, false, false), actor, undefined, undefined);
    assertEquals(response.status, 200);
    assertEquals((await response.json()).products, []);
  }
});

Deno.test("operator-authorized dormant pack is marked Sandbox-only regardless of query claim", async () => {
  for (const environment of ["Sandbox", "Production"]) {
    const response = await creditsRoute(
      new Request(`https://example.invalid/me/credits?org_id=${org}&environment=${environment}`),
      db("owner", false, true, false, true), actor, undefined, undefined);
    assertEquals(response.status, 200);
    assertEquals((await response.json()).products, [{
      product_id: "com.rendprop.app.credits.100", credits: 100, sandbox_only: true,
    }]);
  }
});
