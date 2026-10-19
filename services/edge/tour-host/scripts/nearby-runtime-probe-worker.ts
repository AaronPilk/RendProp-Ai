// Actual workerd/R2 conditional writes; provider data is a closed fixture.
// No credentials, production storage or network outside the local worker.
import { lookupNearbyPlaces, peekNearbyPlaces } from "../src/nearby-places";
import { renderNearbyMap } from "../src/nearby-map";
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

      // A dead isolate must not strand an area for the ten-minute completed
      // error backoff. Its paid-free provider attempt remains counted.
      let clock = epoch + 24 * 60 * 60 * 1000;
      const recoveryDeps = { now: () => clock, timeoutMs: 20, fetch: (async () => new Promise<Response>(() => {})) as typeof fetch };
      check((await lookupNearbyPlaces(tour(37.1), adapterEnv, recoveryDeps)).status === "unavailable", "actual timed-out attempt refuses promptly");
      clock += 30_001;
      const recovered = await lookupNearbyPlaces(tour(37.1), adapterEnv, { now: () => clock, fetch: provider });
      check(recovered.status === "empty", "actual expired thirty-second execution lease permits recovery");
      check((await (await env.MEDIA_RENDERS.get("public-location-v1/budget/2026-10-14.json"))!.json<{ count: number }>()).count === 2, "timeout and later recovery both remain in the actual next-day meter");

      // Nine-place closed OSM fixture through the real adapter, then the
      // server-drawn neighbourhood map and the cache-only page read.
      const origin = { lat: 38.4, lng: -80.843 };
      const degree = 6_371_008.8 * Math.PI / 180;
      const element = (id: number, name: string, tags: Record<string, string>, bearing: number, metres: number) => {
        const rad = bearing * Math.PI / 180;
        return { type: "node", id, lat: origin.lat + metres * Math.cos(rad) / degree, lon: origin.lng + metres * Math.sin(rad) / (degree * Math.cos(origin.lat * Math.PI / 180)), tags: { name, ...tags } };
      };
      const elements = [
        element(11, "Harbor Grill", { amenity: "restaurant" }, 35, 420), element(12, "Trattoria Luna", { amenity: "restaurant" }, 120, 760), element(13, "The Longest Restaurant Name In Town Ever", { amenity: "restaurant" }, 200, 1180),
        element(14, "Kahwa Coffee", { amenity: "cafe" }, 60, 300), element(15, "Bandit Coffee Co.", { amenity: "cafe" }, 250, 640), element(16, "Black Crow Café", { amenity: "cafe" }, 300, 1320),
        element(17, "Publix", { shop: "supermarket" }, 170, 980), element(18, "Rollin' Oats Market", { shop: "greengrocer" }, 320, 450), element(19, "Haslam's Books", { shop: "books" }, 90, 1450),
        element(20, "Fourth restaurant beyond the per-category cap", { amenity: "restaurant" }, 10, 1490), element(21, "Private club", { amenity: "restaurant", access: "private" }, 80, 200),
      ];
      let nineDispatches = 0;
      const nineProvider: typeof fetch = async () => { nineDispatches++; return Response.json({ elements }); };
      const nineClock = epoch + 2 * 24 * 60 * 60 * 1000;
      const nineTour = { space_type: "real_estate", published_at: "2026-10-12T00:00:00Z", listing: { lat: origin.lat + 0.0004, lng: origin.lng - 0.0004, address: "PRIVATE FIELD MUST NOT LEAVE" } } as unknown as Tour;
      check((await peekNearbyPlaces(nineTour, adapterEnv, { now: () => nineClock })) === null && nineDispatches === 0, "cache-only page read of a cold cell returns nothing and never calls the provider");
      check((await env.MEDIA_RENDERS.get("public-location-v1/pois/38.400,-80.843.json")) === null, "cache-only page read leaves no lease behind");
      const nine = await lookupNearbyPlaces(nineTour, adapterEnv, { now: () => nineClock, fetch: nineProvider });
      check(nine.status === "available" && nine.places.length === 9 && nineDispatches === 1, "actual adapter admits nine places (three per category) from the closed fixture");
      check(nine.places.every(p => p.distance_m <= 1500 && /^https:\/\/www\.openstreetmap\.org\/node\/1[1-9]$/.test(p.source_url)) && !JSON.stringify(nine).includes("PRIVATE FIELD"), "fixture places keep OSM identity only; the private address never enters the result");
      const map = renderNearbyMap(nine, { lat: 38.4, lng: -80.843 });
      check(map.startsWith('<figure class="property-nearby-map"><svg class="property-nearby-map-svg" viewBox="0 0 360 360" role="img" aria-label="Map of 9 nearby places within 1 mi of the property: 3 restaurants, 3 cafés, 3 shops. Positions are approximate." focusable="false">'), "server-drawn map names its nine places and categories");
      check((map.match(/<g class="nm-place">/g) || []).length === 9 && !/https?:|xlink|<image|<use|<script|<a\b|href=|38\.4|80\.84|PRIVATE/.test(map), "map holds nine markers and no host, link, script, tile, coordinate or private field");
      const peeked = await peekNearbyPlaces(nineTour, adapterEnv, { now: () => nineClock });
      check(peeked !== null && peeked.status === "available" && peeked.places.length === 9 && nineDispatches === 1 && renderNearbyMap(peeked, { lat: 38.4, lng: -80.843 }) === map, "cache-only page read replays the real R2 entry with no provider call and draws the identical map");
      check((await peekNearbyPlaces(nineTour, adapterEnv, { now: () => nineClock + 8 * 24 * 60 * 60 * 1000 })) === null, "cache-only page read refuses an expired entry");
      return Response.json({ passed: true, assertions, storage: "local workerd R2", provider: "closed fixture", external_network: false, map_bytes: map.length });
    } catch (error) {
      return Response.json({ passed: false, assertions, error: error instanceof Error ? error.message : String(error) }, { status: 500 });
    }
  },
};
