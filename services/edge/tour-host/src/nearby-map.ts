// Privacy-safe neighbourhood map: static inline SVG drawn on the server from
// the nearby-places result only. No tiles, no third-party script, no network
// call and no coordinates in the markup: the property sits at the centre of
// distance rings at the same coarsened origin the lookup already used, and
// each place is placed by its bearing and its published straight-line distance.
import { escapeHtml } from "./html";
import type { NearbyPlace, NearbyPlacesResult } from "./nearby-places";

const MILE = 1609.344;
const SIZE = 360;
const CENTER = SIZE / 2;
const OUTER = 150;
const LABEL_MAX = 24;
const MAX_PLACES = 12;
const CATEGORY_CLASS: Record<NearbyPlace["category"], string> = { Restaurant: "restaurant", Cafe: "cafe", Shop: "shop" };
const CATEGORY_PLURAL: Record<NearbyPlace["category"], string> = { Restaurant: "restaurants", Cafe: "cafés", Shop: "shops" };

interface Ring { metres: number; label: string }
interface Box { x: number; y: number; w: number; h: number }
interface Dot { x: number; y: number; place: NearbyPlace; label: string; tx: number; ty: number; anchor: "start" | "end" | "middle"; }
const LABEL_EM = 6.4;
const LABEL_H = 14;
const overlap = (a: Box, b: Box) => Math.max(0, Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x)) * Math.max(0, Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y));
const inside = (b: Box) => b.x >= 4 && b.y >= 4 && b.x + b.w <= SIZE - 4 && b.y + b.h <= SIZE - 4;
/** Text box from its baseline anchor: the same arithmetic the checks use. */
export function labelBox(text: string, tx: number, ty: number, anchor: Dot["anchor"]): Box {
  const w = text.length * LABEL_EM + 4;
  return { x: anchor === "end" ? tx - w : anchor === "middle" ? tx - w / 2 : tx, y: ty - 11, w, h: LABEL_H };
}

const fmt = (n: number) => String(Math.round(n * 10) / 10);
const miles = (metres: number) => {
  const mi = metres / MILE;
  return `${Number.isInteger(mi) ? mi : mi.toFixed(2).replace(/0+$/, "").replace(/\.$/, "")} mi`;
};

/** Two or three rings in quarter- or half-mile steps that enclose every place. */
function ringsFor(maxMetres: number): Ring[] {
  const quarter = MILE / 4, half = MILE / 2;
  const step = maxMetres <= quarter * 3 ? quarter : half;
  const count = Math.min(3, Math.max(2, Math.ceil(maxMetres / step)));
  return Array.from({ length: count }, (_, i) => ({ metres: step * (i + 1), label: miles(step * (i + 1)) }));
}

/** Marker shapes differ per category so colour is never the only signal. */
function marker(category: NearbyPlace["category"], x: number, y: number): string {
  const c = `class="nm-dot nm-${CATEGORY_CLASS[category]}"`;
  if (category === "Restaurant") return `<circle ${c} cx="${fmt(x)}" cy="${fmt(y)}" r="6"/>`;
  if (category === "Cafe") return `<rect ${c} x="${fmt(x - 5.5)}" y="${fmt(y - 5.5)}" width="11" height="11" rx="2"/>`;
  return `<polygon ${c} points="${fmt(x)},${fmt(y - 7)} ${fmt(x + 7)},${fmt(y)} ${fmt(x)},${fmt(y + 7)} ${fmt(x - 7)},${fmt(y)}"/>`;
}

function shorten(name: string): string {
  const clean = name.replace(/\s+/g, " ").trim();
  return clean.length > LABEL_MAX ? clean.slice(0, LABEL_MAX - 1).trimEnd() + "…" : clean;
}

export function nearbyMapSummary(places: NearbyPlace[]): string {
  const counts = new Map<NearbyPlace["category"], number>();
  for (const p of places) counts.set(p.category, (counts.get(p.category) || 0) + 1);
  const parts = (["Restaurant", "Cafe", "Shop"] as const).filter(c => counts.has(c))
    .map(c => `${counts.get(c)} ${counts.get(c) === 1 ? c.toLowerCase().replace("cafe", "café") : CATEGORY_PLURAL[c]}`);
  const furthest = Math.max(...places.map(p => p.distance_m));
  return `Map of ${places.length} nearby ${places.length === 1 ? "place" : "places"} within ${miles(ringsFor(furthest).at(-1)!.metres)} of the property: ${parts.join(", ")}. Positions are approximate.`;
}

/** "" when there is nothing to draw; callers hide the map container then. */
export function renderNearbyMap(result: Pick<NearbyPlacesResult, "status" | "places">, origin: { lat: number | null; lng: number | null }): string {
  const lat0 = origin.lat, lng0 = origin.lng;
  if (result.status !== "available" || !Array.isArray(result.places) || !result.places.length ||
      typeof lat0 !== "number" || typeof lng0 !== "number" || !Number.isFinite(lat0) || !Number.isFinite(lng0)) return "";
  const places = result.places.slice(0, MAX_PLACES).filter(p => Number.isFinite(p.lat) && Number.isFinite(p.lng) && Number.isFinite(p.distance_m) && p.distance_m >= 0);
  if (!places.length) return "";
  const rings = ringsFor(Math.max(...places.map(p => p.distance_m)));
  const scale = OUTER / rings[rings.length - 1].metres;
  const cosLat = Math.cos(lat0 * Math.PI / 180);
  // Label layout: each label tries the spots around its marker and takes the
  // one that stays on the paper and clears every marker and label placed so
  // far; two refinement passes then let earlier labels move out of the way of
  // later ones. Deterministic: same places, same drawing.
  const positioned = places.map(place => {
    const east = (place.lng - lng0) * cosLat, north = place.lat - lat0;
    const bearing = east === 0 && north === 0 ? 0 : Math.atan2(east, north);
    const r = Math.min(OUTER, place.distance_m * scale);
    return { place, x: CENTER + r * Math.sin(bearing), y: CENTER - r * Math.cos(bearing), label: shorten(place.name) };
  }).sort((a, b) => a.y - b.y || a.x - b.x);
  const fixed: Box[] = [{ x: CENTER - 16, y: CENTER - 16, w: 32, h: 32 }, ...positioned.map(p => ({ x: p.x - 8, y: p.y - 8, w: 16, h: 16 }))];
  const spots = (p: { x: number; y: number }): Array<{ tx: number; ty: number; anchor: Dot["anchor"] }> => [
    { tx: p.x + 11, ty: p.y + 4, anchor: "start" }, { tx: p.x - 11, ty: p.y + 4, anchor: "end" },
    { tx: p.x, ty: p.y + 21, anchor: "middle" }, { tx: p.x, ty: p.y - 13, anchor: "middle" },
    { tx: p.x + 9, ty: p.y - 9, anchor: "start" }, { tx: p.x - 9, ty: p.y - 9, anchor: "end" },
    { tx: p.x + 9, ty: p.y + 17, anchor: "start" }, { tx: p.x - 9, ty: p.y + 17, anchor: "end" },
    { tx: p.x, ty: p.y + 35, anchor: "middle" }, { tx: p.x, ty: p.y - 27, anchor: "middle" },
  ];
  const chosen: Array<{ tx: number; ty: number; anchor: Dot["anchor"]; box: Box } | null> = positioned.map(() => null);
  const settle = (i: number) => {
    const p = positioned[i];
    const others = [...fixed, ...chosen.filter((c, j): c is NonNullable<typeof c> => c !== null && j !== i).map(c => c.box)];
    chosen[i] = spots(p).map(c => { const box = labelBox(p.label, c.tx, c.ty, c.anchor); return { ...c, box, score: others.reduce((sum, other) => sum + overlap(box, other), 0) + (inside(box) ? 0 : 1_000) }; })
      .sort((a, b) => a.score - b.score)[0];
  };
  for (let pass = 0; pass < 3; pass++) for (let i = 0; i < positioned.length; i++) settle(i);
  const dots: Dot[] = positioned.map((p, i) => ({ x: p.x, y: p.y, place: p.place, label: p.label, tx: chosen[i]!.tx, ty: chosen[i]!.ty, anchor: chosen[i]!.anchor }));
  const ringMarkup = rings.map(ring => {
    const r = ring.metres * scale;
    return `<circle class="nm-ring" cx="${CENTER}" cy="${CENTER}" r="${fmt(r)}"/><text class="nm-ring-label" x="${fmt(CENTER + 4)}" y="${fmt(CENTER - r - 4)}">${escapeHtml(ring.label)}</text>`;
  }).join("");
  const placeMarkup = dots.map(dot => `<g class="nm-place">${marker(dot.place.category, dot.x, dot.y)}<text class="nm-label" x="${fmt(dot.tx)}" y="${fmt(dot.ty)}" text-anchor="${dot.anchor}">${escapeHtml(dot.label)}</text></g>`).join("");
  const home = `<g class="nm-home"><title>The property</title><circle class="nm-home-halo" cx="${CENTER}" cy="${CENTER}" r="14"/><circle class="nm-home-dot" cx="${CENTER}" cy="${CENTER}" r="7"/></g>`;
  const compass = `<text class="nm-compass" x="${SIZE - 14}" y="18" text-anchor="middle">N</text><path class="nm-compass-arrow" d="M${SIZE - 14} 22 l-3 6 h6 z"/>`;
  const legend = (["Restaurant", "Cafe", "Shop"] as const).filter(c => places.some(p => p.category === c))
    .map(c => `<span class="nm-key"><svg viewBox="0 0 16 16" aria-hidden="true" focusable="false">${marker(c, 8, 8)}</svg>${escapeHtml(CATEGORY_PLURAL[c].replace(/^./, ch => ch.toUpperCase()))}</span>`).join("");
  return `<figure class="property-nearby-map"><svg class="property-nearby-map-svg" viewBox="0 0 ${SIZE} ${SIZE}" role="img" aria-label="${escapeHtml(nearbyMapSummary(places))}" focusable="false"><rect class="nm-paper" x="0" y="0" width="${SIZE}" height="${SIZE}" rx="12"/>${ringMarkup}${compass}${placeMarkup}${home}</svg><figcaption class="property-nearby-legend">${legend}<span class="nm-key nm-key-home"><svg viewBox="0 0 16 16" aria-hidden="true" focusable="false"><circle class="nm-home-dot" cx="8" cy="8" r="5"/></svg>The property</span></figcaption></figure>`;
}

/** Shared list markup for the no-script render; the client builds the same shape. */
export function renderNearbyList(places: NearbyPlace[]): string {
  return places.map(place => `<li><a href="${escapeHtml(place.source_url)}" target="_blank" rel="noopener nofollow">${escapeHtml(place.name)}</a><span>${escapeHtml(place.category)} · approximately ${(place.distance_m / MILE).toFixed(1)} mi away</span></li>`).join("");
}
