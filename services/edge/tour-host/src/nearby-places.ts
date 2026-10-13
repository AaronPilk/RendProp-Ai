import type { Env, Tour } from "./types";

// Optional public location enrichment, not an authority for property facts.
// Only the freshly authorized published tour may supply the origin. Never
// accept visitor coordinates, an address query, a provider URL or private IDs.
export interface NearbyPlace {
  name: string;
  category: "Restaurant" | "Cafe" | "Shop";
  lat: number;
  lng: number;
  distance_m: number;
  source_url: string;
}
export interface NearbyPlacesResult {
  status: "available" | "unavailable" | "empty";
  places: NearbyPlace[];
  attribution: string;
  fetched_at?: string;
}

export const NEARBY_ENDPOINT = "https://overpass.private.coffee/api/interpreter";
export const NEARBY_TIMEOUT_MS = 6_000;
export const NEARBY_MAX_BYTES = 256 * 1024;
export const NEARBY_DAILY_LOOKUPS = 100;
const RADIUS_M = 1_500;
const PREFIX = "public-location-v1/";
const POSITIVE_MS = 7 * 24 * 60 * 60 * 1000;
const EMPTY_MS = 24 * 60 * 60 * 1000;
const ERROR_MS = 10 * 60 * 1000;
const ATTRIBUTION = "© OpenStreetMap contributors";
const LICENSE = "https://www.openstreetmap.org/copyright";
const SHOP_TYPES = ["supermarket", "convenience", "bakery", "greengrocer", "clothes", "department_store", "mall", "butcher", "hardware", "florist", "books", "chemist"];
const unavailable = (): NearbyPlacesResult => ({ status: "unavailable", places: [], attribution: ATTRIBUTION });
const record = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
const number = (v: unknown, bound: number): v is number => typeof v === "number" && Number.isFinite(v) && Math.abs(v) <= bound;

interface CacheEntry {
  version: 1;
  expires_at: number;
  result: NearbyPlacesResult;
  license: string;
}
interface NearbyDependencies {
  fetch?: typeof fetch;
  now?: () => number;
  /** Closed test clock only; production callers use the fixed six-second cap. */
  timeoutMs?: number;
}

function distance(lat: number, lng: number, a: number, b: number): number {
  const rad = Math.PI / 180;
  const dl = (a - lat) * rad, dn = (b - lng) * rad;
  const h = Math.sin(dl / 2) ** 2 + Math.cos(lat * rad) * Math.cos(a * rad) * Math.sin(dn / 2) ** 2;
  return 6_371_008.8 * 2 * Math.asin(Math.sqrt(Math.min(1, Math.max(0, h))));
}

function category(tags: Record<string, unknown>): NearbyPlace["category"] | null {
  if (tags.access === "private" || tags.access === "no") return null;
  if (tags.amenity === "restaurant") return "Restaurant";
  if (tags.amenity === "cafe") return "Cafe";
  return typeof tags.shop === "string" && SHOP_TYPES.includes(tags.shop) ? "Shop" : null;
}

function place(v: unknown, lat: number, lng: number): NearbyPlace | null {
  if (!record(v) || !["node", "way", "relation"].includes(String(v.type)) ||
      !Number.isSafeInteger(v.id) || Number(v.id) <= 0 || !record(v.tags)) return null;
  const kind = category(v.tags);
  if (!kind || typeof v.tags.name !== "string") return null;
  const name = v.tags.name.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, 80);
  const point = v.type === "node" ? v : v.center;
  if (!name || !record(point) || !number(point.lat, 90) || !number(point.lon, 180)) return null;
  const metres = distance(lat, lng, point.lat, point.lon);
  if (!Number.isFinite(metres) || metres > RADIUS_M) return null;
  return { name, category: kind, lat: point.lat, lng: point.lon, distance_m: Math.round(metres),
    source_url: `https://www.openstreetmap.org/${v.type}/${v.id}` };
}

function parsePlaces(raw: unknown, lat: number, lng: number, now: number): NearbyPlacesResult {
  // Overpass can return partial elements alongside a timeout/memory remark.
  // A partial response must not masquerade as a complete empty search.
  if (!record(raw) || !Array.isArray(raw.elements) || raw.elements.length > 1_000 || raw.remark !== undefined) return unavailable();
  const sorted = raw.elements.map(v => place(v, lat, lng)).filter((v): v is NearbyPlace => v !== null)
    .sort((a, b) => a.distance_m - b.distance_m || a.source_url.localeCompare(b.source_url));
  const seen = new Set<string>(), counts = new Map<string, number>();
  const places = sorted.filter(p => {
    // A cafe may be mapped both as a node and a containing building.
    const key = `${p.category}|${p.name.toLowerCase()}|${Math.round(p.lat * 10_000)}|${Math.round(p.lng * 10_000)}`;
    if (seen.has(key) || (counts.get(p.category) || 0) >= 3) return false;
    seen.add(key); counts.set(p.category, (counts.get(p.category) || 0) + 1); return true;
  });
  return { status: places.length ? "available" : "empty", places, attribution: ATTRIBUTION,
    fetched_at: new Date(now).toISOString() };
}

function cacheEntry(raw: unknown, lat: number, lng: number): CacheEntry | null {
  if (!record(raw) || raw.version !== 1 || !number(raw.expires_at, Number.MAX_SAFE_INTEGER) ||
      raw.license !== LICENSE || !record(raw.result)) return null;
  const r = raw.result;
  if (!["available", "empty", "unavailable"].includes(String(r.status)) || !Array.isArray(r.places) ||
      r.places.length > 9 || r.attribution !== ATTRIBUTION ||
      (r.fetched_at !== undefined && (typeof r.fetched_at !== "string" || !Number.isFinite(Date.parse(r.fetched_at))))) return null;
  const ps: NearbyPlace[] = [];
  for (const p of r.places) {
    if (!record(p) || typeof p.name !== "string" || p.name.length < 1 || p.name.length > 80 ||
        !["Restaurant", "Cafe", "Shop"].includes(String(p.category)) || !number(p.lat, 90) || !number(p.lng, 180) ||
        typeof p.distance_m !== "number" || !Number.isFinite(p.distance_m) || p.distance_m < 0 || p.distance_m > RADIUS_M ||
        typeof p.source_url !== "string" || !/^https:\/\/www\.openstreetmap\.org\/(node|way|relation)\/[1-9][0-9]*$/.test(p.source_url) ||
        Math.abs(distance(lat, lng, p.lat, p.lng) - p.distance_m) > 1) return null;
    ps.push({ name: p.name, category: p.category as NearbyPlace["category"], lat: p.lat, lng: p.lng,
      distance_m: p.distance_m, source_url: p.source_url });
  }
  if ((r.status === "available") !== (ps.length > 0)) return null;
  return { version: 1, expires_at: raw.expires_at, license: LICENSE,
    result: { status: r.status as NearbyPlacesResult["status"], places: ps, attribution: ATTRIBUTION,
      ...(typeof r.fetched_at === "string" ? { fetched_at: r.fetched_at } : {}) } };
}

/** Caller must run this only on the branded Location GET after a fresh public
 * /tours lookup. The additional publication/type checks fail closed if reused.
 * The cache contains ODbL POIs only, not addresses, accounts or listing IDs.
 * A CAS lease suppresses the same-area stampede; a global daily CAS counter
 * bounds all provider attempts, including unsuccessful ones, across isolates.
 */
export async function lookupNearbyPlaces(tour: Tour, env: Env, dependencies: NearbyDependencies = {}): Promise<NearbyPlacesResult> {
  const now = dependencies.now || Date.now;
  const openedAt = now();
  if (tour.space_type !== "real_estate" || !tour.published_at || !Number.isFinite(Date.parse(tour.published_at)) ||
      Date.parse(tour.published_at) > openedAt || !number(tour.listing.lat, 90) || !number(tour.listing.lng, 180) ||
      !env.MEDIA_RENDERS) return unavailable();
  const lat = Math.round(tour.listing.lat * 1000) / 1000, lng = Math.round(tour.listing.lng * 1000) / 1000;
  const cacheKey = `${PREFIX}pois/${lat.toFixed(3)},${lng.toFixed(3)}.json`;
  const bucket = env.MEDIA_RENDERS;
  const controller = new AbortController();
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  let response: Response | undefined;
  const cancel = () => {
    if (reader) void reader.cancel().catch(() => {});
    else if (response?.body && !response.body.locked) void response.body.cancel().catch(() => {});
  };
  const alive = () => !controller.signal.aborted;
  const readJSON = async (body: ReadableStream<Uint8Array>, cap: number): Promise<unknown> => {
    reader = body.getReader();
    const bytes = new Uint8Array(cap);
    let size = 0, emptyChunks = 0;
    while (alive()) {
      const chunk = await reader.read();
      if (!alive()) throw new Error("deadline");
      if (chunk.done) {
        reader = undefined;
        return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes.subarray(0, size)));
      }
      if (!(chunk.value instanceof Uint8Array) || chunk.value.length > cap - size) throw new Error("body limit");
      if (chunk.value.length === 0) { if (++emptyChunks > 32) throw new Error("no progress"); continue; }
      emptyChunks = 0; bytes.set(chunk.value, size); size += chunk.value.length;
    }
    throw new Error("deadline");
  };
  const readObject = async (object: R2ObjectBody, cap: number): Promise<unknown> => {
    if (!Number.isFinite(object.size) || object.size > cap) throw new Error("cache limit");
    return readJSON(object.body, cap);
  };
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<NearbyPlacesResult>(resolve => {
    timer = setTimeout(() => { controller.abort(); cancel(); resolve(unavailable()); },
      Math.min(NEARBY_TIMEOUT_MS, Math.max(1, dependencies.timeoutMs || NEARBY_TIMEOUT_MS)));
  });
  const work = async (): Promise<NearbyPlacesResult> => {
    const cached = await bucket.get(cacheKey);
    if (!alive()) return unavailable();
    if (cached) {
      let entry: CacheEntry | null = null;
      try { entry = cacheEntry(await readObject(cached, 32 * 1024), lat, lng); } catch { cancel(); reader = undefined; }
      if (!alive()) return unavailable();
      if (entry && entry.expires_at > now()) return entry.result;
    }
    const lease: CacheEntry = { version: 1, expires_at: now() + ERROR_MS, result: unavailable(), license: LICENSE };
    const locked = await bucket.put(cacheKey, JSON.stringify(lease), {
      onlyIf: cached ? { etagMatches: cached.etag } : new Headers({ "If-None-Match": "*" }),
      httpMetadata: { contentType: "application/json" },
    });
    if (!alive() || !locked) return unavailable();

    const budgetDay = new Date(openedAt).toISOString().slice(0, 10);
    const budgetKey = `${PREFIX}budget/${budgetDay}.json`;
    let admitted = false;
    for (let attempt = 0; attempt < 4 && alive(); attempt++) {
      const current = await bucket.get(budgetKey);
      if (!alive()) return unavailable();
      let count = 0;
      if (current) {
        const raw = await readObject(current, 128);
        if (!record(raw) || !Number.isInteger(raw.count) || Number(raw.count) < 0) return unavailable();
        count = Number(raw.count);
      }
      if (!alive() || count >= NEARBY_DAILY_LOOKUPS) return unavailable();
      const updated = await bucket.put(budgetKey, JSON.stringify({ count: count + 1 }), {
        onlyIf: current ? { etagMatches: current.etag } : new Headers({ "If-None-Match": "*" }),
        httpMetadata: { contentType: "application/json" },
      });
      if (!alive()) return unavailable();
      if (updated) { admitted = true; break; }
    }
    if (!admitted || !alive() || new Date(now()).toISOString().slice(0, 10) !== budgetDay) return unavailable();
    // Only fixed query syntax and server-coarsened numeric origin reach OSM.
    const query = `[out:json][timeout:4][maxsize:16777216];(nwr(around:${RADIUS_M},${lat},${lng})[amenity~"^(restaurant|cafe)$"][name];nwr(around:${RADIUS_M},${lat},${lng})[shop~"^(${SHOP_TYPES.join("|")})$"][name];);out center 1000;`;
    let result = unavailable();
    try {
      response = await (dependencies.fetch || fetch)(NEARBY_ENDPOINT, {
        method: "POST", body: new URLSearchParams({ data: query }).toString(), redirect: "manual", cache: "no-store",
        headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json",
          "User-Agent": "Rendprop-nearby/1.0 (+https://rendprop.com/support)" }, signal: controller.signal,
      });
      if (!alive()) { cancel(); return unavailable(); }
      if (response.ok && response.body) result = parsePlaces(await readJSON(response.body, NEARBY_MAX_BYTES), lat, lng, now());
    } catch { cancel(); reader = undefined; }
    if (!alive()) return unavailable();
    const lifetime = result.status === "available" ? POSITIVE_MS : result.status === "empty" ? EMPTY_MS : ERROR_MS;
    // Losing the cache write cannot turn genuine data into invented data; the
    // original ten-minute lease still prevents repeated immediate requests.
    await bucket.put(cacheKey, JSON.stringify({ version: 1, expires_at: now() + lifetime, result, license: LICENSE }), {
      onlyIf: { etagMatches: locked.etag }, httpMetadata: { contentType: "application/json" },
    });
    return alive() ? result : unavailable();
  };
  try { return await Promise.race([work(), deadline]); }
  catch { return unavailable(); }
  finally { if (timer !== undefined) clearTimeout(timer); controller.abort(); cancel(); }
}
