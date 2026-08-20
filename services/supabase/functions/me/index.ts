// me — the signed-in user, their org, plan, and a usage rollup (owner).
//
//   GET /me -> { user, org, plan, usage }
//
// usage: this-month AI/infra spend (sum of cost_ledger.total_cents for the org),
// plus lead / render / listing counts. All reads go through the user client so
// RLS scopes everything to the caller's org.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, json, respondError, round4 } from "../_shared/http.ts";
import { getUser, orgForUser, preferredOrg, userClient } from "../_shared/supabase.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    if (req.method !== "GET") throw new HttpError(405, "Only GET is supported");

    const user = await getUser(req);
    const db = userClient(req);
    const orgId = await orgForUser(user.id, preferredOrg(req));

    const now = new Date();
    const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();
    const month = monthStart.slice(0, 7); // YYYY-MM

    const [profileRes, orgRes, ledgerRes, leadsRes, rendersRes, listingsRes] = await Promise.all([
      db.from("profiles").select("id, email, name, avatar_url, phone").eq("id", user.id).maybeSingle(),
      db.from("orgs").select("id, name, handle, space_type, plan, brand_kit").eq("id", orgId).maybeSingle(),
      db.from("cost_ledger").select("total_cents").eq("org_id", orgId).gte("created_at", monthStart),
      db.from("leads").select("id", { count: "exact", head: true }).eq("org_id", orgId).gte("created_at", monthStart),
      // renders has no org_id; RLS already scopes it to the caller's org.
      db.from("renders").select("id", { count: "exact", head: true }).not("published_at", "is", null),
      db.from("listings").select("id", { count: "exact", head: true }).is("deleted_at", null),
    ]);

    if (orgRes.error) throw new HttpError(500, `Org lookup failed: ${orgRes.error.message}`);

    const costCents = round4(
      (ledgerRes.data ?? []).reduce((s, r) => s + Number(r.total_cents ?? 0), 0),
    );

    return json({
      user: profileRes.data ?? { id: user.id, email: user.email ?? null },
      org: orgRes.data,
      plan: orgRes.data?.plan ?? "free",
      usage: {
        month,
        cost_cents: costCents,
        leads: leadsRes.count ?? 0,
        renders: rendersRes.count ?? 0,
        listings: listingsRes.count ?? 0,
      },
    });
  } catch (err) {
    return respondError(err);
  }
});
