// Fair-housing guardrails for every AI generation prompt (compliance wave, W2-B3).
//
// WHY. HUD's May 2024 guidance on algorithms and AI in housing advertising makes
// three things live risks in AI-generated listing media:
//   1. generated PEOPLE, implying a neighborhood's demographic character;
//   2. AI-inserted lifestyle / religious / cultural cues that function as steering;
//   3. copy that describes a preferred OCCUPANT ("great school district",
//      "family-friendly area") rather than the PROPERTY.
// The practical rule from the research brief (§5, "Fair housing"): never render
// people, never render religious or cultural objects, never generate
// neighborhood narration.
//
// TWO MECHANISMS, both applied server-side so the client cannot opt out:
//
//   A. LOCKS appended to every prompt we build (canned edits AND user prompts):
//        FAIR_HOUSING_LOCK   — people/pets/religious+cultural objects/flags/signage
//        PERMANENCE_LOCK     — exterior, view out of windows, permanent features
//      Exterior edits (twilight | sky | lawn) get EXTERIOR_PERMANENCE_LOCK
//      instead of PERMANENCE_LOCK: those edits exist to change the sky, the
//      light and the landscaping, so "do not change the exterior" would fight
//      the instruction. The scoped variant still forbids changing the building,
//      its permanent features and its signage — everything the rule is for.
//
//   B. A DENYLIST refusing free-text prompts (edit:"custom", improve_prompt,
//      reel-clip `prompt`, video declutter `prompt`, aerial `style`) → 400
//      `unsupported_edit`.
//
// THE DENYLIST, in full (word-boundary matching, case-insensitive, applied to
// the raw user text):
//
//   ALWAYS blocked — these are never a legitimate instruction about a property,
//   whatever the verb:
//     • steering / demographics: neighborhood, neighbourhood, demographic(s),
//       ethnic(ity), racial, race, nationality, immigrant(s), gentrif*,
//       "school district", "good/great/top/bad schools", "school rating(s)",
//       "family friendly", "family-friendly", "kid friendly", "child friendly",
//       "up and coming", "safe area", "safe part of town", "the right crowd",
//       "type of people", "kind of people"
//     • protected-class descriptors: religion, religious, christian, muslim,
//       jewish, hindu, buddhist, catholic
//     • places of worship / religious objects: church, mosque, synagogue,
//       chapel, temple, shrine, altar, crucifix, menorah, nativity, rosary,
//       hijab, yarmulke, kippah, prayer rug
//
//   CONTEXTUAL — blocked only when the prompt also carries an ADD verb (add,
//   insert, place, put, include, show, generate, create, render, populate, fill,
//   stage, seat, depict, feature, imagine, invent, draw, paint, photoshop,
//   "make it look like", "make it appear", "bring in"). Removing these is a
//   legitimate, common edit ("remove the family photos", "take down the flag"),
//   so only ADDING them is refused:
//     • people: person, people, human(s), family, families, child(ren), kid(s),
//       toddler(s), baby/babies, infant(s), man, men, woman, women, boy(s),
//       girl(s), teenager(s), couple(s), resident(s), occupant(s), tenant(s),
//       guest(s), shopper(s), diner(s), crowd(s), model(s), figure(s),
//       silhouette(s), portrait(s)
//     • pets: pet(s), dog(s), cat(s), puppy/puppies, kitten(s)
//     • cultural / political objects: flag(s), flagpole, cross(es), christmas,
//       hanukkah, "holiday decorations", "political sign", "campaign sign",
//       "religious art"
//
//   DELIBERATE NON-MATCHES (the denylist must not be brittle — these all pass):
//     • "remove the personal items"      — \bperson\b does not match "personal"
//     • "brighten the flag stone patio"  — flag(s) is excluded before "stone",
//                                          and "flagstone" is one word anyway
//     • "improve the cross ventilation"  — cross is excluded before
//                                          ventilation/breeze/beam/walk/bar/…
//     • "remove the family photos"       — no ADD verb, so the contextual tier
//                                          does not fire
//     • "declutter the kids' room"       — no ADD verb (and the canned
//                                          declutter edit never goes near this)
//
// The refusal is a 400 with code `unsupported_edit` and copy that names the
// term and says what to do instead — an agent must be able to fix it in one go.

import { HttpError } from "./http.ts";

/** Appended to EVERY generation prompt. Verbatim across photo and video. */
export const FAIR_HOUSING_LOCK =
  "Do not add or alter people, pets, religious or cultural objects, flags, or signage.";

/** Appended to interior / whole-scene edits alongside FAIR_HOUSING_LOCK. */
export const PERMANENCE_LOCK =
  "Do not change the exterior, the view out of windows, or any permanent feature.";

/**
 * The twilight / sky / lawn edits exist to change the sky, the light and the
 * landscaping, so the blanket "do not change the exterior" would contradict the
 * instruction and degrade a proven prompt. This scoped variant keeps everything
 * the rule protects — the building, its permanent features, its signage.
 */
export const EXTERIOR_PERMANENCE_LOCK =
  "Do not change the building, its permanent features, its signage, or anything " +
  "beyond the sky, lighting and landscaping described above.";

/** Both locks, for a prompt that edits an interior or the whole scene. */
export const GUARDRAILS = `${FAIR_HOUSING_LOCK} ${PERMANENCE_LOCK}`;

/** Fair-housing lock + the scoped permanence clause, for exterior edits. */
export const EXTERIOR_GUARDRAILS = `${FAIR_HOUSING_LOCK} ${EXTERIOR_PERMANENCE_LOCK}`;

/** The canned edits whose subject IS the exterior/sky/landscaping. */
const EXTERIOR_EDITS = new Set(["twilight", "sky", "lawn"]);

/** Pick the right guardrail suffix for a canned edit id. */
export function guardrailsFor(edit: string): string {
  return EXTERIOR_EDITS.has(edit.trim().toLowerCase()) ? EXTERIOR_GUARDRAILS : GUARDRAILS;
}

// ── The denylist ─────────────────────────────────────────────────────────────
//
// Every pattern is anchored with \b so a term only matches as a whole word.
// `label` is what the refusal message names, so it must read like something the
// agent actually typed.

interface Rule {
  label: string;
  re: RegExp;
}

/** Never legitimate, whatever the verb. */
const ALWAYS: Rule[] = [
  { label: "neighborhood", re: /\bneighbou?rhoods?\b/i },
  { label: "school district", re: /\bschool\s+districts?\b/i },
  { label: "school quality", re: /\b(good|great|top|best|bad|poor|excellent)\s+schools?\b/i },
  { label: "school ratings", re: /\bschool\s+(ratings?|scores?|rankings?)\b/i },
  { label: "demographics", re: /\bdemographics?\b/i },
  { label: "ethnicity", re: /\bethnic(ity|ities)?\b/i },
  { label: "race", re: /\b(races?|racial|racially)\b/i },
  { label: "nationality", re: /\bnationalit(y|ies)\b/i },
  { label: "immigrants", re: /\bimmigrants?\b/i },
  { label: "gentrification", re: /\bgentrif\w*\b/i },
  { label: "family-friendly", re: /\b(family|kid|child|children)[\s-]friendly\b/i },
  { label: "up and coming", re: /\bup[\s-]and[\s-]coming\b/i },
  { label: "safe area", re: /\bsafe\s+(area|part|side|block|street|community)\b/i },
  { label: "a type of people", re: /\b(type|kind|sort)\s+of\s+(people|person|buyers?|families|tenants?)\b/i },
  { label: "the right crowd", re: /\bright\s+(crowd|clientele|sort|kind)\b/i },
  { label: "religion", re: /\breligions?\b|\breligious\b/i },
  { label: "a religious affiliation", re: /\b(christian|muslim|islamic|jewish|hindu|buddhist|catholic|protestant|mormon)s?\b/i },
  { label: "a place of worship", re: /\b(church(es)?|mosques?|synagogues?|chapels?|temples?|shrines?|altars?)\b/i },
  { label: "a religious object", re: /\b(crucifix(es)?|menorahs?|nativity|rosar(y|ies)|hijabs?|yarmulkes?|kippahs?|prayer\s+rugs?)\b/i },
];

/** Only a problem when the prompt is ADDING them — removing is legitimate. */
const CONTEXTUAL: Rule[] = [
  {
    label: "people",
    re: /\b(persons?|people|humans?|famil(y|ies)|child(ren)?|kids?|toddlers?|bab(y|ies)|infants?|man|men|woman|women|boys?|girls?|teenagers?|couples?|residents?|occupants?|tenants?|guests?|shoppers?|diners?|crowds?|models?|figures?|silhouettes?|portraits?)\b/i,
  },
  { label: "pets", re: /\b(pets?|dogs?|cats?|pupp(y|ies)|kittens?)\b/i },
  // "flag stone"/"flagstone" is a paving material, not a flag.
  { label: "flags", re: /\bflags?\b(?!\s*stones?\b)|\bflag[\s-]?poles?\b/i },
  // cross-ventilation / crossbeam / crosswalk / crossing / crossover / crossbar…
  { label: "a cross", re: /\bcross(es)?\b(?![\s-]?(ventilat|breeze|beam|walk|ing|over|bar|hatch|section|wind|street|road))/i },
  { label: "holiday or religious decoration", re: /\b(christmas|hanukkah|holiday\s+decorations?|religious\s+art(work)?)\b/i },
  { label: "political signage", re: /\b(political|campaign|election)\s+(signs?|posters?|banners?)\b/i },
];

/** Verbs that mean "put this into the picture". */
const ADD_VERB =
  /\b(add(s|ed|ing)?|insert(s|ed|ing)?|place(s|d|ing)?|put(s|ting)?|includ(e|es|ed|ing)|show(s|n|ing)?|generat(e|es|ed|ing)|creat(e|es|ed|ing)|render(s|ed|ing)?|populat(e|es|ed|ing)|fill(s|ed|ing)?|stag(e|es|ed|ing)|seat(s|ed|ing)?|depict(s|ed|ing)?|featur(e|es|ed|ing)|imagin(e|es|ed|ing)|invent(s|ed|ing)?|draw(s|ing|n)?|paint(s|ed|ing)?|photoshop(s|ped|ping)?|bring\s+in|make\s+it\s+(look|appear|seem)|turn\s+it\s+into)\b/i;

export interface DenylistHit {
  label: string;
  tier: "always" | "add";
}

/**
 * Inspect a free-text prompt. Returns the first offending term, or null when the
 * prompt is fine. Pure — callers decide whether to throw.
 */
export function checkFairHousing(raw: string | null | undefined): DenylistHit | null {
  const text = String(raw ?? "");
  if (!text.trim()) return null;

  for (const r of ALWAYS) {
    if (r.re.test(text)) return { label: r.label, tier: "always" };
  }
  if (ADD_VERB.test(text)) {
    for (const r of CONTEXTUAL) {
      if (r.re.test(text)) return { label: r.label, tier: "add" };
    }
  }
  return null;
}

/**
 * Throw the 400 `unsupported_edit` when a free-text prompt trips the denylist.
 * The copy names the term and says what to do instead — the agent must be able
 * to fix it in one edit, not guess.
 */
export function assertFairHousing(raw: string | null | undefined, what = "This edit"): void {
  const hit = checkFairHousing(raw);
  if (!hit) return;

  const why = hit.tier === "always"
    ? `mentions ${hit.label}, which describes the people or the neighborhood rather than the property`
    : `asks to add ${hit.label} to the image`;

  const fix = hit.tier === "always"
    ? "Describe the space itself — the room, the light, the materials, the landscaping — and leave the neighborhood and its residents out of it."
    : `Rewrite it without adding ${hit.label}. Removing or tidying is fine (for example "remove the family photos"); adding is not.`;

  throw new HttpError(
    400,
    `${what} can't be generated: it ${why}. Fair-housing rules (HUD guidance on AI in ` +
      `housing advertising) mean Rendprop never generates people, pets, religious or ` +
      `cultural objects, or neighborhood claims in listing media. ${fix}`,
    "unsupported_edit",
    { term: hit.label },
  );
}
