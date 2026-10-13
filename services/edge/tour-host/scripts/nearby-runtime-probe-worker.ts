// Actual workerd/R2 conditional writes; provider data is a closed fixture.
// No credentials, production storage or network outside the local worker.
import { lookupNearbyPlaces } from "../src/nearby-places";
import type { Env, Tour } from "../src/types";

interface ProbeEnv { MEDIA_RENDERS: R2Bucket }
export default {
  async fetch(_request: Request, env: ProbeEnv): Promise<Response> {
    let assertions = 0;
    const check = (condition: boolean, message: string) => {
      assertions++;
      if (!condition) throw new Error(message);
    };
    const epoch = Date.parse("2026-10-13T12:00:00.000Z");
    const tour = (lat: number): Tour => ({ space_type: "real_estate", published_at: "2026-10-12T00:00:00Z",
      listing: { lat, lng: -80.843, address: "PRIVATE FIELD MUST NOT LEAVE" } } as Tour);
    let dispatches = 0;
    const provider: typeof fetch = async () => {
      dispatches++;
      return Response.json({ elements: [] });
    };
    const deps = { now: () => epoch, fetch: provider };
    const adapterEnv = env as Env;
    try {
      const create = await env.MEDIA_RENDERS.put("condition-probe", "first", { onlyIf: new Headers({ "If-None-Match": "*" }) });
      check(create !== null, "first conditional creation succeeds");
      const duplicate = await env.MEDIA_RENDERS.put("condition-probe", "duplicate", { onlyIf: new Headers({ "If-None-Match": "*" }) });
      check(duplicate === null, "existing-key If-None-Match refuses rather than overwrites");
      const changed = await env.MEDIA_RENDERS.put("condition-probe", "second", { onlyIf: { etagMatches: create!.etag } });
      check(changed !== null, "matching etag permits update");
      const stale = await env.MEDIA_RENDERS.put("condition-probe", "stale", { onlyIf: { etagMatches: create!.etag } });
      check(stale === null, "stale etag refuses rather than overwrites");
      check(await (await env.MEDIA_RENDERS.get("condition-probe"))!.text() === "second", "conditional failures preserve bytes");

      const simultaneous = await Promise.all(Array.from({ length: 20 }, () => lookupNearbyPlaces(tour(35.227), adapterEnv, deps)));
      check(dispatches === 1, "actual R2 area lease admits exactly one concurrent provider call");
      check(simultaneous.filter(r => r.status === "empty").length >= 1, "admitted result is genuine empty data");
      const budgetKey = "public-location-v1/budget/2026-10-13.json";
      check((await (await env.MEDIA_RENDERS.get(budgetKey))!.json<{ count: number }>()).count === 1, "actual daily counter counts the one provider call");
      const cached = await lookupNearbyPlaces(tour(35.227), adapterEnv, deps);
      check(cached.status === "empty" && dispatches === 1, "real R2 cache replay makes no provider call");

      await env.MEDIA_RENDERS.put(budgetKey, JSON.stringify({ count: 99 }));
      dispatches = 0;
      const competing = await Promise.all(Array.from({ length: 15 }, (_, i) => lookupNearbyPlaces(tour(35.3 + i * 0.02), adapterEnv, deps)));
      check(dispatches === 1, "actual R2 daily CAS admits exactly one at 99 of 100 across distinct cells");
      check(competing.filter(r => r.status === "empty").length === 1, "only the daily winner receives fetched empty data");
      check((await (await env.MEDIA_RENDERS.get(budgetKey))!.json<{ count: number }>()).count === 100, "actual daily counter stops at 100");
      const exhausted = await lookupNearbyPlaces(tour(36.1), adapterEnv, deps);
      check(exhausted.status === "unavailable" && dispatches === 1, "exhausted real counter prevents another provider call");
      return Response.json({ passed: true, assertions, storage: "local workerd R2", provider: "closed fixture", external_network: false });
    } catch (error) {
      return Response.json({ passed: false, assertions, error: error instanceof Error ? error.message : String(error) }, { status: 500 });
    }
  },
};
