// property — what the public record says about an address.
//
//   GET /property?address=<full address>   OWNER
//     -> { configured: true,  cached: bool, source: "rentcast", facts: {...} }
//     -> { configured: true,  facts: null }          no record for that address
//     -> { configured: false }                       no provider credential here
//
// THE ASK: "I want one of our Ai programs to find the zillow listing and pull
// everything over. i dont think zillow even has an API i can get."
//
// He is right — Zillow retired its public API in 2021 and what remains (Bridge
// Interactive) is Zillow Group's and MLS-gated. But the DATA he wants is not
// Zillow's: beds, baths, square footage, year built, lot size and sale history
// are county public record, and licensed vendors have already aggregated all of
// it nationwide. So this asks a vendor rather than scraping a portal, which is
// the difference between a feature and a liability — Zillow's terms prohibit
// automated queries, and a tour published on rendprop.com would put that
// exposure on this company rather than on the agent who tapped the button.
//
// PHOTOS ARE NOT HERE AND WILL NOT BE. No vendor licenses a listing's
// photographs; they belong to the photographer or the MLS. `PropertyFacts` has
// no photo field so nothing downstream can start expecting one.
//
// EVERY CALL COSTS MONEY, so three guards, in this order:
//   1. CACHE FIRST, on a normalised address. The second lookup of a house we
//      already bought is free, for every org — re-buying a public record we
//      already own would spend the owner's money to enforce a boundary that
//      protects nobody.
//   2. A DURABLE RATE LIMIT per org. The in-memory fallback is not enough for a
//      route with a real invoice behind it, so this one fails CLOSED.
//   3. A LEDGER ROW per real call, so it shows up in the spend console beside
//      every other unit cost instead of arriving as a surprise line item.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, respondError } from "../_shared/http.ts";
import { adminClient, getUser, orgForUser, preferredOrg } from "../_shared/supabase.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { recordAppAiCost } from "../_shared/ledger.ts";
import { addressKey, hasSubstance, PropertyFacts, PropertyProvider } from "../_shared/property/provider.ts";
import { rentcast } from "../_shared/property/rentcast.ts";

/** Tried in order; the first CONFIGURED one answers. An MLS/IDX provider slots
 *  in at the front of this array and nothing else changes. */
const PROVIDERS: PropertyProvider[] = [rentcast];

/** A house does not gain a bedroom overnight. Long enough that an agent
 *  re-opening a listing never re-buys it, short enough that a sale recorded
 *  last month shows up. */
const CACHE_DAYS = 30;

/** Per org. Generous for a person typing addresses, ruinous for a loop. */
const RATE_MAX = 40;
const RATE_WINDOW_S = 3600;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return handleOptions();
  try {
    assert(req.method === "GET", 405, "Use GET /property?address=…");

    const url = new URL(req.url);
    const address = (url.searchParams.get("address") ?? "").trim();
    assert(address.length >= 6, 400, "Pass a full street address");
    assert(address.length <= 300, 400, "That address is too long");

    const provider = PROVIDERS.find((p) => p.configured()) ?? null;
    if (!provider) {
      // NOT an error. A deploy without the credential is a normal state, and
      // the app hides the button rather than showing a failure for something
      // the agent did not do wrong.
      return json({ configured: false });
    }

    const user = await getUser(req);
    const orgId = await orgForUser(user.id, preferredOrg(req));

    const admin = adminClient();
    const akey = addressKey(address);

    // 1 — cache.
    const { data: hit } = await admin
      .from("property_lookups")
      .select("facts, provider, fetched_at")
      .eq("address_key", akey)
      .gt("fetched_at", new Date(Date.now() - CACHE_DAYS * 86_400_000).toISOString())
      .maybeSingle();
    if (hit?.facts) {
      return json({ configured: true, cached: true, source: hit.provider, facts: hit.facts });
    }

    // 2 — rate limit. Fails CLOSED: `durableRateLimit` returning false because
    // the RPC is unavailable is exactly when an unbounded paid route is most
    // dangerous, so there is no in-memory fallback here on purpose.
    const allowed = await durableRateLimit(`property:${orgId}`, RATE_MAX, RATE_WINDOW_S);
    if (!allowed) {
      throw new HttpError(429, "That's a lot of address lookups — try again in a little while.", "rate_limited");
    }

    let facts: PropertyFacts | null = null;
    try {
      facts = await provider.lookup(address);
    } catch (e) {
      console.error("property: provider threw:", e instanceof Error ? e.message : String(e));
      // No custom code: `ErrorCode` is a closed union and 502 already maps to
      // the right one via `codeForStatus`. Inventing a member here would be a
      // contract the app has no case for.
      throw new HttpError(502, "The property records service didn't answer. Try again in a moment.");
    }

    if (!facts || !hasSubstance(facts)) {
      // A miss is still a call the provider billed for, so it is still a ledger
      // row — silent losses are how a cost line goes unexplained.
      await recordAppAiCost(admin, {
        orgId, provider: provider.id, feature: "property_lookup",
        model: "properties", units: 1, unitCents: provider.unitCents,
        meta: { result: "no_record" },
      });
      return json({ configured: true, cached: false, source: provider.id, facts: null });
    }

    // 3 — ledger, then cache. In that order: a ledger failure must not stop the
    // agent getting the answer they are waiting for, and a cache row written
    // before the charge is recorded would hide the charge forever.
    await recordAppAiCost(admin, {
      orgId, provider: provider.id, feature: "property_lookup",
      model: "properties", units: 1, unitCents: provider.unitCents,
      meta: { result: "hit", has_sqft: facts.sqft != null, has_beds: facts.beds != null },
    });

    await admin.from("property_lookups").upsert({
      address_key: akey,
      address_input: address.slice(0, 300),
      provider: provider.id,
      facts,
      paid_by_org: orgId,
      fetched_at: new Date().toISOString(),
    }, { onConflict: "address_key" });

    return json({ configured: true, cached: false, source: provider.id, facts });
  } catch (err) {
    return respondError(err);
  }
});
