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
// Advance widths of the 12-unit label text, by character class. Measured on
// Inter 500, a slightly wide member of the system UI sans family the map uses,
// and rounded up, so the estimate errs wide rather than letting names collide.
const NARROW = new Set([..."iljI.,'’:;|!"]), SEMI = new Set([..."tfr()[]/"]);
function textWidth(text: string): number {
  let w = 0;
  for (const ch of text) {
    w += ch === " " ? 3.2 : ch === "…" ? 11 : NARROW.has(ch) ? 3.4 : SEMI.has(ch) ? 4.6 : ch === "-" ? 5.6
      : ch === "m" || ch === "w" ? 10.4 : ch === "M" || ch === "W" ? 11.6 : ch >= "0" && ch <= "9" ? 7.6
      : ch.codePointAt(0)! >= 0x2e80 ? 12 : ch !== ch.toLowerCase() ? 8.6 : 7;
  }
  return w;
}
// Glyph box of a 12-unit label from its baseline. The usual UI sans faces
// measure 14.3–14.6 units (ascent about 11.4–11.7, descent about 2.9–3.2), so
// the box spans 12 above and 3.5 below the baseline.
const LABEL_ASCENT = 12;
const LABEL_H = 15.5;
// Clear space kept between a label and any other label or marker when its
// spot is chosen: flush labels touch once a real font's metrics apply, and
// two stacked names read as one.
const LABEL_CLEAR = 3;
const overlap = (a: Box, b: Box) => Math.max(0, Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x)) * Math.max(0, Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y));
const grow = (b: Box, by: number): Box => ({ x: b.x - by, y: b.y - by, w: b.w + 2 * by, h: b.h + 2 * by });
/** How far a box reaches past the 4-unit paper margin (0 when inside). */
const outside = (b: Box) => Math.max(0, 4 - b.x) + Math.max(0, 4 - b.y) + Math.max(0, b.x + b.w - (SIZE - 4)) + Math.max(0, b.y + b.h - (SIZE - 4));
/** Text box from its baseline anchor: the same arithmetic the checks use. */
export function labelBox(text: string, tx: number, ty: number, anchor: Dot["anchor"]): Box {
  const w = textWidth(text) + 4;
  return { x: anchor === "end" ? tx - w : anchor === "middle" ? tx - w / 2 : tx, y: ty - LABEL_ASCENT, w, h: LABEL_H };
}
/** Box of a 10-unit ring distance label from its baseline anchor. */
export function ringLabelBox(text: string, x: number, y: number, end: boolean): Box {
  const w = textWidth(text) * 10 / 12 + 2;
  return { x: end ? x - w : x, y: y - 10, w, h: 12.5 };
}

const fmt = (n: number) => String(Math.round(n * 10) / 10);
const miles = (metres: number) => {
  const mi = metres / MILE;
  return `${Number.isInteger(mi) ? mi : mi.toFixed(2).replace(/0+$/, "").replace(/\.$/, "")} mi`;
};

/** Two or three rings that enclose every place, in the smallest of tenth-,
 *  quarter- or half-mile steps that needs no more than three: the scale fits
 *  the places, so a dense block spreads across the paper instead of crowding
 *  its labels into the middle of an oversized circle. */
function ringsFor(maxMetres: number): Ring[] {
  const step = [MILE / 10, MILE / 4].find(s => maxMetres <= s * 3) ?? MILE / 2;
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

function shorten(name: string, max = LABEL_MAX): string {
  const clean = name.replace(/\s+/g, " ").trim();
  return clean.length > max ? clean.slice(0, max - 1).trimEnd() + "…" : clean;
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
  // one that stays on the paper and keeps clear of every other marker and
  // label; three passes let earlier labels move out of the way of later ones.
  // A label still crowded after that is shortened (the list below keeps the
  // full name) and placed again. Ring distance labels go last, to the clearest
  // of six points on their ring. Deterministic: same places, same drawing.
  const positioned = places.map(place => {
    const east = (place.lng - lng0) * cosLat, north = place.lat - lat0;
    const bearing = east === 0 && north === 0 ? 0 : Math.atan2(east, north);
    const r = Math.min(OUTER, place.distance_m * scale);
    return { place, x: CENTER + r * Math.sin(bearing), y: CENTER - r * Math.cos(bearing), label: shorten(place.name) };
  }).sort((a, b) => a.y - b.y || a.x - b.x);
  // Obstacles: the property marker, each place's marker (index i + 1 for
  // place i) and the north arrow.
  const fixed: Box[] = [{ x: CENTER - 16, y: CENTER - 16, w: 32, h: 32 }, ...positioned.map(p => ({ x: p.x - 8, y: p.y - 8, w: 16, h: 16 })), { x: SIZE - 22, y: 6, w: 16, h: 24 }];
  const spots = (p: { x: number; y: number }): Array<{ tx: number; ty: number; anchor: Dot["anchor"] }> => [
    { tx: p.x + 11, ty: p.y + 4, anchor: "start" }, { tx: p.x - 11, ty: p.y + 4, anchor: "end" },
    { tx: p.x, ty: p.y + 21, anchor: "middle" }, { tx: p.x, ty: p.y - 13, anchor: "middle" },
    { tx: p.x + 9, ty: p.y - 9, anchor: "start" }, { tx: p.x - 9, ty: p.y - 9, anchor: "end" },
    { tx: p.x + 9, ty: p.y + 17, anchor: "start" }, { tx: p.x - 9, ty: p.y + 17, anchor: "end" },
    { tx: p.x, ty: p.y + 35, anchor: "middle" }, { tx: p.x, ty: p.y - 27, anchor: "middle" },
    // Farther fallbacks, chosen only when every nearer spot collides.
    { tx: p.x + 9, ty: p.y + 31, anchor: "start" }, { tx: p.x - 9, ty: p.y + 31, anchor: "end" },
    { tx: p.x + 9, ty: p.y - 23, anchor: "start" }, { tx: p.x - 9, ty: p.y - 23, anchor: "end" },
  ];
  const chosen: Array<{ tx: number; ty: number; anchor: Dot["anchor"]; box: Box } | null> = positioned.map(() => null);
  const settle = (i: number) => {
    const p = positioned[i], own = fixed[i + 1];
    // A label may sit right beside its own marker; everything else keeps the clearance.
    const others = [...fixed.filter(box => box !== own), ...chosen.filter((c, j): c is NonNullable<typeof c> => c !== null && j !== i).map(c => c.box)];
    // Staying on the paper comes first (an off-paper label is cropped), then
    // the least overlap; ties keep the nearest spot, in the order listed.
    chosen[i] = spots(p).map(c => { const box = labelBox(p.label, c.tx, c.ty, c.anchor), clear = grow(box, LABEL_CLEAR); return { ...c, box, off: outside(box), score: overlap(box, own) + others.reduce((sum, other) => sum + overlap(clear, other), 0) }; })
      .sort((a, b) => a.off - b.off || a.score - b.score)[0];
  };
  for (let pass = 0; pass < 3; pass++) for (let i = 0; i < positioned.length; i++) settle(i);
  // Crowded fallback: a label that still touches another label or marker is
  // shortened, first to 16 characters and then to 11, and everything settles again.
  const crowded = (i: number) => { const box = chosen[i]!.box, own = fixed[i + 1]; return fixed.some(f => f !== own && overlap(box, f) > 0) || chosen.some((c, j) => j !== i && c !== null && overlap(box, c.box) > 0); };
  for (const max of [16, 11]) {
    const tight = positioned.map((_, i) => i).filter(i => crowded(i) && positioned[i].label.length > max);
    if (!tight.length) continue;
    for (const i of tight) positioned[i].label = shorten(positioned[i].place.name, max);
    for (let pass = 0; pass < 2; pass++) for (let i = 0; i < positioned.length; i++) settle(i);
  }
  const dots: Dot[] = positioned.map((p, i) => ({ x: p.x, y: p.y, place: p.place, label: p.label, tx: chosen[i]!.tx, ty: chosen[i]!.ty, anchor: chosen[i]!.anchor }));
  // Ring distance labels (10-unit text): just north of the centre when that
  // is clear, otherwise beside the clearest of eleven other points on their
  // ring (outside the line, on the side away from the centre), never off the paper.
  const taken: Box[] = [...fixed, ...chosen.map(c => c!.box)];
  const ringMarkup = rings.map(ring => {
    const r = ring.metres * scale;
    const around = [180, 45, 315, 135, 225, 90, 270, 30, 330, 150, 210].map(deg => {
      const a = deg * Math.PI / 180, px = CENTER + r * Math.sin(a), py = CENTER - r * Math.cos(a), east = Math.sin(a) >= -1e-9;
      return { x: east ? px + 3 : px - 3, y: Math.cos(a) >= -1e-9 ? py - 3 : py + 11, end: !east };
    });
    const best = [{ x: CENTER + 4, y: CENTER - r - 4, end: false }, ...around]
      .map(o => { const box = ringLabelBox(ring.label, o.x, o.y, o.end); return { ...o, box, off: outside(box), score: taken.reduce((sum, other) => sum + overlap(grow(box, 2), other), 0) }; })
      .sort((a, b) => a.off - b.off || a.score - b.score)[0];
    taken.push(best.box);
    return `<circle class="nm-ring" cx="${CENTER}" cy="${CENTER}" r="${fmt(r)}"/><text class="nm-ring-label" x="${fmt(best.x)}" y="${fmt(best.y)}"${best.end ? ' text-anchor="end"' : ""}>${escapeHtml(ring.label)}</text>`;
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
