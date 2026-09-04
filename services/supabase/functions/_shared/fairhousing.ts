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

// ═════════════════════════════════════════════════════════════════════════════
// C. MARKETING COPY / SCRIPT CHECK  (added for ai-voice, wave 12)
// ═════════════════════════════════════════════════════════════════════════════
//
// WHY A SECOND CHECK. Everything above was built for IMAGE PROMPTS — an
// instruction to a diffusion model. Its contextual tier is deliberately gated
// behind an ADD VERB ("add a family in the living room") because in a photo
// edit, *removing* a family photo is legitimate and *adding* one is not.
//
// A VOICEOVER SCRIPT is not an instruction to a model. It is the advertisement
// itself — the words a buyer hears. 42 U.S.C. §3604(c) makes it unlawful to
// publish "any notice, statement, or advertisement … that indicates any
// preference, limitation, or discrimination" based on race, color, religion,
// sex, familial status, national origin or disability. HUD's guidance on AI in
// housing advertising says the medium does not matter: a spoken script is a
// statement exactly as a written listing description is. So "great for
// families" — which carries no ADD verb and would sail through the image
// denylist — is precisely the thing the statute names.
//
// HOW THE TWO COMPOSE. `assertMarketingCopy()` runs BOTH: the script rules
// below AND the original `assertFairHousing()` denylist. Nothing above is
// relaxed, re-scoped or made conditional — this tier is purely additive, and a
// script must clear both to be spoken.
//
// WHAT IT REFUSES (each rule names the phrase it matched, so the copy tells the
// agent which words to change and why):
//
//   • FAMILIAL STATUS — audience framing ("great for families", "perfect
//     starter home for a young couple", "ideal for young professionals"),
//     child exclusion ("no kids", "adults only", "childless"), and
//     "a great place to raise a family".
//   • RELIGION — saint-named landmarks reached by a proximity claim ("walk to
//     St. Mary's"), and religious institutions (parish, diocese, congregation,
//     masjid, mandir, gurdwara, madrasa, Bible study). Bare "church", "temple",
//     "mosque", "synagogue" etc. are already refused by tier A.
//   • RACE / ETHNICITY / NATIONAL ORIGIN — a race, color or ancestry word used
//     to qualify a group of PEOPLE ("black community", "Asian neighborhood",
//     "Spanish-speaking area"). Tier A already refuses "race", "ethnic",
//     "demographics", "immigrants" outright.
//   • DISABILITY — EXCLUSION only ("no wheelchairs", "not suitable for the
//     elderly", "able-bodied", "must be able to climb stairs"). Describing an
//     accessibility FEATURE is lawful, encouraged, and deliberately untouched:
//     "wheelchair accessible", "step-free entry", "roll-in shower", "elevator
//     to every floor" all pass.
//   • SEX — "bachelor pad", "female tenants only", "no single men".
//   • STEERING PROXIES that HUD and NAR treat as coded references to the people
//     in an area rather than the property: "safe neighborhood", "safe for
//     kids", "low crime", "crime-free", "exclusive community", "the right part
//     of town", "prestigious area", "blue-ribbon schools", "school catchment",
//     "no Section 8".
//
// DELIBERATE NON-MATCHES — the gate is worthless if agents route around it, so
// ordinary property copy must survive. All of these pass:
//     "single-family home"        — the property classification, not a
//                                   preference (no bare `family + home` rule)
//     "spacious family room"      — a room name
//     "great for entertaining"    — an activity, not an occupant
//     "wheelchair accessible"     — an accessibility feature (see above)
//     "black granite countertops" — a color; the race words only fire in front
//                                   of a PEOPLE noun
//     "white oak floors"          — same
//     "exclusive listing",
//     "exclusive amenities"       — terms of art; only "exclusive community /
//                                   neighborhood / enclave / clientele" steer
//     "walk to St. Charles Avenue"— a street, excluded by the street-suffix
//                                   lookahead ("walk to St. Mary's" is not)
//     "a couple of blocks away"   — the idiom, excluded from the audience rule
//     "safe and sound", "safety features", "home safe"
//                                 — only "safe <place noun>" / "safe for kids"
//                                   / "safe to raise" steer
//
// KNOWN LIMITS, stated rather than papered over: this is a phrase denylist, not
// a classifier. It cannot catch novel paraphrase ("you'll know your kind of
// people live here"), and it is English-only. It is a floor, not a ceiling.
//
// ONE INHERITED FALSE POSITIVE, kept deliberately. `assertMarketingCopy()` also
// runs tier B, whose CONTEXTUAL people rule fires on an ADD verb. A few script
// sentences use one of those verbs innocently — "the family gathering space
// SEATS twelve" trips `seat` + `family` and is refused with tier B's wording.
// That rule is not relaxed for scripts: a rare rewrite of one sentence is a far
// smaller cost than a hole in a fair-housing gate, and the refusal still names
// the term. Rephrase as "the gathering space seats twelve".

/** The protected class (or steering doctrine) a script rule protects. */
export type ScriptCategory =
  | "familial_status"
  | "religion"
  | "race"
  | "disability"
  | "sex"
  | "steering";

interface ScriptRule {
  category: ScriptCategory;
  re: RegExp;
}

/** Why each category is refused, and what to say instead. Written for the
 *  agent who typed the script: it has to be fixable in one rewrite. */
const CATEGORY_COPY: Record<ScriptCategory, { why: string; fix: string }> = {
  familial_status: {
    why:
      "describes who should live in the home rather than the home itself. " +
      "Familial status is a protected class, so a listing may not signal that " +
      "families with children — or buyers without them — are preferred or unwelcome",
    fix:
      "Describe the space and let the buyer decide it fits: \"three bedrooms and a " +
      "fenced yard\" instead of \"great for families\", \"a flexible bonus room\" " +
      "instead of \"perfect for a young couple\".",
  },
  religion: {
    why:
      "points the listener at a religious institution or congregation, which " +
      "signals a preferred religion for the neighborhood",
    fix:
      "Name secular landmarks and distances instead — \"a ten-minute walk to the " +
      "riverfront park\", \"two blocks from the Main Street shops\".",
  },
  race: {
    why:
      "describes the residents by race, color, ethnicity or national origin, " +
      "which is the clearest form of unlawful steering",
    fix:
      "Say nothing about who lives nearby. Describe the property, the finishes " +
      "and the walkable amenities.",
  },
  disability: {
    why:
      "excludes or discourages people with disabilities. (Describing an " +
      "accessibility FEATURE is lawful and welcome — it is the exclusion that is not)",
    fix:
      "Delete the exclusion. If you meant to describe the layout honestly, say what " +
      "IS there: \"a step-free entry and a first-floor bedroom\", or \"the only " +
      "bedrooms are up a flight of stairs\".",
  },
  sex: {
    why: "states a preferred sex or gender for the occupant",
    fix:
      "Describe the room or the property instead — \"a private ground-floor suite\" " +
      "rather than a preferred occupant.",
  },
  steering: {
    why:
      "makes a claim about the neighborhood's people, safety or schools rather " +
      "than about the property. HUD and NAR treat safety, school-quality and " +
      "\"exclusive\" language as proxies for the protected characteristics of who " +
      "lives there, and the claim is one you would also have to defend as fact",
    fix:
      "Cut the neighborhood judgement and keep the verifiable facts: distances, " +
      "street names, parks, transit, and what the property itself offers. Point " +
      "buyers to public school and crime data so they can draw their own conclusions.",
  },
};

/**
 * Script-only rules. Each is anchored with \b, case-insensitive, and written to
 * match the way an agent actually talks. Order is refusal priority: the most
 * specific and most clearly unlawful first.
 */
const SCRIPT_RULES: ScriptRule[] = [
  // ── Familial status ────────────────────────────────────────────────────────
  // "great for families", "perfect for young professionals", "made for retirees"
  {
    category: "familial_status",
    re:
      /\b(great|perfect|ideal|good|excellent|wonderful|best|nice|lovely|suited|suitable|made|built|designed|meant|tailored|geared|just\s+right)\s+(for|to)\s+(a\s+|an\s+|the\s+|your\s+)?(young|growing|new|large|small|busy|modern|professional)?\s*(famil(y|ies)|kids?|children|couples?|newlyweds?|singles?|bachelors?|bachelorettes?|professionals?|retirees?|seniors?|students?|empty[\s-]?nesters?|first[\s-]time\s+buyers?)\b/i,
  },
  // "…starter home for a young couple", "…backyard for a growing family".
  // The quality word may be far from the audience, so this rule stands alone on
  // "for <a> <audience>". Excluded: "for a couple of blocks", "for a family
  // gathering/dinner/photo/movie night" — activities, not occupants.
  {
    category: "familial_status",
    re:
      /\bfor\s+(a\s+|an\s+|the\s+|your\s+)?(young|growing|new|large|small|busy)?\s*(famil(y|ies)|couples?|newlyweds?|bachelors?|retirees?|empty[\s-]?nesters?)\b(?!\s+of\b)(?!\s+(gathering|gatherings|dinner|dinners|meal|meals|room|rooms|photos?|night|nights|movie|game|reunion|holidays?|entertaining))/i,
  },
  // "a growing family will love the yard"
  { category: "familial_status", re: /\b(young|growing|new|large)\s+famil(y|ies)\b/i },
  // "family-oriented community" ("family-friendly" is already tier A)
  { category: "familial_status", re: /\bfamily[\s-](oriented|focused|centered|centred)\b/i },
  { category: "familial_status", re: /\bfamily\s+(community|compound|enclave)\b/i },
  // Child exclusion
  {
    category: "familial_status",
    re: /\bno\s+(kids?|children|toddlers?|babies|infants?|teens?|teenagers?)\b/i,
  },
  { category: "familial_status", re: /\b(adults?|grown[\s-]?ups?)\s+only\b/i },
  { category: "familial_status", re: /\bchildless\b/i },
  {
    category: "familial_status",
    re: /\bnot\s+(suitable|ideal|great|appropriate|meant|designed|good)\s+for\s+(a\s+|the\s+)?(kids?|children|famil(y|ies)|toddlers?|babies)\b/i,
  },
  {
    category: "familial_status",
    re: /\b(mature|established|professional)\s+(buyers?|residents?|couples?|occupants?|tenants?)\s+only\b/i,
  },
  // "a great place to raise a family", "room to start a family"
  {
    category: "familial_status",
    re: /\b(raise|raising|rais'?n|start|starting|grow|growing|expand|expanding)\s+(a\s+|your\s+|their\s+|the\s+)?famil(y|ies)\b/i,
  },
  { category: "familial_status", re: /\bplace\s+to\s+raise\b/i },

  // ── Religion ───────────────────────────────────────────────────────────────
  // "walk to St. Mary's" / "steps from Saint Anne's". Proximity + a saint name.
  // A street NAMED for a saint is excluded by the street-suffix lookahead, so
  // "walk to St. Charles Avenue" is fine and "walk to St. Mary's" is not.
  {
    category: "religion",
    re:
      /\b(walk|walking|walkable|steps|stroll|strolling|minutes?|blocks?|close|near|nearby|next\s+door|around\s+the\s+corner|short\s+drive)\b[^.!?]{0,30}?\b(st\.?|saint)\s+[A-Za-z]+(?:'s|s')?\b(?!\s*(st\b|street|ave\b|avenue|rd\b|road|blvd|boulevard|dr\b|drive|ln\b|lane|way\b|ct\b|court|pl\b|place|cir\b|circle|terrace|pkwy|parkway|highway|hwy|park\b|square|sq\b))/i,
  },
  {
    category: "religion",
    re:
      /\b(parish(es)?|dioceses?|congregations?|ministr(y|ies)|gurdwaras?|mandirs?|masjids?|madrasas?|bible\s+study|prayer\s+(group|meeting|service)s?|sunday\s+school)\b/i,
  },

  // ── Race / ethnicity / national origin ─────────────────────────────────────
  // A race, color or ancestry word IN FRONT OF A PEOPLE NOUN. "black granite"
  // and "white oak" are colors and pass; "black community" does not.
  {
    category: "race",
    re:
      /\b(white|black|caucasian|anglo|hispanic|latino|latina|latinx|asian|oriental|arab|arabic|african[\s-]american|afro[\s-]caribbean|native|indigenous|european|foreign)\s+(famil(y|ies)|communit(y|ies)|neighbou?rhoods?|buyers?|residents?|owners?|tenants?|households?|professionals?|clientele|folks|people|persons?|crowd|enclave|population|block|street|area)\b/i,
  },
  { category: "race", re: /\bethnic\s+(enclave|pocket|corridor)\b/i },
  {
    category: "race",
    re: /\b(english|spanish|chinese|mandarin|cantonese|russian|korean|vietnamese|portuguese|french)[\s-]speaking\b/i,
  },
  { category: "race", re: /\bno\s+(foreigners?|outsiders?)\b/i },

  // ── Disability — EXCLUSION only (features are welcome; see header) ──────────
  {
    category: "disability",
    re: /\bno\s+(wheelchairs?|service\s+(animals?|dogs?)|disabled|handicapped?|walkers?\s+or\s+wheelchairs?)\b/i,
  },
  {
    category: "disability",
    re:
      /\bnot\s+(suitable|appropriate|ideal|designed|meant|good|great)\s+for\s+(the\s+)?(disabled|handicapped?|elderly|seniors?|wheelchairs?|blind|deaf|limited\s+mobility)\b/i,
  },
  { category: "disability", re: /\bable[\s-]bodied\b/i },
  { category: "disability", re: /\bmust\s+be\s+able\s+to\s+(walk|climb|stand|drive|see|hear|manage)\b/i },
  { category: "disability", re: /\bno\s+(mental|physical)\s+(illness|disabilit(y|ies)|impairments?)\b/i },

  // ── Sex / gender ───────────────────────────────────────────────────────────
  { category: "sex", re: /\bbachelor(ette)?\s+(pad|apartment|flat|unit)\b/i },
  {
    category: "sex",
    re: /\b(males?|females?|men|women|ladies|gentlemen|guys)\s+(only|preferred|tenants?|roommates?|occupants?|buyers?)\b/i,
  },
  { category: "sex", re: /\bno\s+(single\s+)?(men|women|males?|females?)\b/i },

  // ── Steering proxies (safety, schools, exclusivity) ────────────────────────
  // Tier A already refuses "safe area/part/side/block/street/community"; these
  // add the rest of the family, including "neighborhood" phrasings and the
  // "safe for kids" / "safe to raise" constructions.
  {
    category: "steering",
    re: /\b(safe|safest|safer)\s+(neighbou?rhoods?|places?|spots?|pockets?|side\s+of\s+town|part\s+of\s+town|schools?)\b/i,
  },
  { category: "steering", re: /\bsafe\s+(for|to\s+raise)\b/i },
  { category: "steering", re: /\b(feel|feels|you'?ll\s+feel)\s+safe\b/i },
  { category: "steering", re: /\b(low|no|zero|little|minimal)\s+crime\b/i },
  { category: "steering", re: /\bcrime[\s-]?(free|rate|rates|ridden|statistics)\b/i },
  { category: "steering", re: /\bcrime\s+is\s+(low|down|almost\s+nonexistent)\b/i },
  {
    category: "steering",
    re:
      /\bexclusive\s+(communit(y|ies)|neighbou?rhoods?|areas?|enclaves?|addresses|address|clientele|buyers?|residents?|pockets?|streets?|part\s+of\s+town|side\s+of\s+town|club)\b/i,
  },
  { category: "steering", re: /\b(private|exclusive|gated)\s+enclave\b/i },
  {
    category: "steering",
    re:
      /\b(desirable|prestigious|sought[\s-]after|elite|upscale|better|right|wrong|nicer|quieter)\s+(part\s+of\s+town|side\s+of\s+town|element|crowd|people|clientele|set)\b/i,
  },
  {
    category: "steering",
    re: /\b(blue[\s-]ribbon|award[\s-]winning|highly[\s-]rated|top[\s-]rated|nationally[\s-]ranked|A[\s-]rated|five[\s-]star)\s+(schools?|school\s+districts?|elementary|middle\s+school|high\s+school)\b/i,
  },
  { category: "steering", re: /\bschool\s+(zones?|catchments?|boundar(y|ies)|attendance\s+areas?)\b/i },
  { category: "steering", re: /\bno\s+(section\s*8|housing\s+vouchers?|vouchers?)\b/i },

  // ── General audience exclusion / preference ────────────────────────────────
  // 42 U.S.C. §3604(c) forbids STATING A PREFERENCE for — or against — an
  // audience, not only an audience with children. The rules above catch
  // "great for <audience>" (a quality word in front) and "no kids" (a CHILD
  // noun behind "no"). An ad that simply says "professionals only", "no
  // families" or "families need not apply" carries neither marker, and was
  // slipping through. These four rules close that hole for ADULT audience
  // nouns as well.
  //
  // They sit LAST on purpose. `checkMarketingCopy` returns the FIRST rule that
  // matches, so anything a narrower rule above already names — "no single men"
  // (sex), "professional buyers only", "young families" (familial_status) —
  // keeps that rule's more specific refusal copy. These fire only on what
  // nothing else caught, which makes them purely additive.
  //
  // Exclusion: "no <audience>". `pets` appears ONLY as "pets or kids" — a bare
  // "no pets" is a lawful occupancy policy and must keep passing.
  {
    category: "familial_status",
    re:
      /\bno\s+(famil(y|ies)|couples?|singles?|students?|seniors?|retirees?|professionals?|roommates?|pets?\s+or\s+kids)\b/i,
  },
  // Preference: "<audience> only | preferred | welcome only" — the mirror
  // image of the exclusion. The `\s+` after the noun is what keeps
  // "professional-grade appliances" out: that is a hyphenated product
  // adjective, not an audience.
  {
    category: "familial_status",
    re:
      /\b(professionals?|singles?|couples?|students?|seniors?|retirees?|famil(y|ies)|newlyweds?|bachelors?|empty[\s-]?nesters?)\s+(only|preferred|welcome\s+only)\b/i,
  },
  // "families need not apply" / "students need not apply" — the classic
  // exclusionary wording, unlawful whoever it names.
  { category: "familial_status", re: /\bneed\s+not\s+apply\b/i },
  // Audience framing, exactly like the "young famil(y|ies)" rule above.
  { category: "familial_status", re: /\byoung\s+professionals?\b/i },
];

export interface ScriptHit {
  /** The literal words the rule matched, quoted back to the agent. */
  phrase: string;
  category: ScriptCategory;
  why: string;
  fix: string;
}

/**
 * Inspect a marketing SCRIPT (voiceover narration, caption copy, listing blurb)
 * against the script rules only. Returns the first offending phrase, or null.
 * Pure — callers decide whether to throw.
 *
 * This is the additive tier. It does NOT replace `checkFairHousing()`; callers
 * that want the full gate should use `assertMarketingCopy()`, which runs both.
 */
export function checkMarketingCopy(raw: string | null | undefined): ScriptHit | null {
  const text = String(raw ?? "");
  if (!text.trim()) return null;
  for (const rule of SCRIPT_RULES) {
    const m = rule.re.exec(text);
    if (m) {
      const copy = CATEGORY_COPY[rule.category];
      return {
        phrase: m[0].replace(/\s+/g, " ").trim().slice(0, 80),
        category: rule.category,
        why: copy.why,
        fix: copy.fix,
      };
    }
  }
  return null;
}

/** The statute + guidance every script refusal cites, so the copy teaches the
 *  rule instead of just blocking. */
const SCRIPT_LAW =
  "Fair-housing law (42 U.S.C. §3604(c)) and HUD's guidance on AI in housing " +
  "advertising apply to a spoken script exactly as they do to a written listing " +
  "description: the ad may describe the PROPERTY, never a preferred or " +
  "discouraged occupant.";

/**
 * The FULL gate for marketing copy: the script rules AND the original
 * image-prompt denylist. Throws 400 `unsupported_edit` naming the offending
 * phrase and why, so the agent can fix it in one rewrite.
 *
 * Server-side only, and unbypassable from the client: there is no flag, header
 * or body field that skips it — see services/supabase/functions/ai-voice.
 */
export function assertMarketingCopy(raw: string | null | undefined, what = "This script"): void {
  const hit = checkMarketingCopy(raw);
  if (hit) {
    throw new HttpError(
      400,
      `${what} can't be voiced: the phrase "${hit.phrase}" ${hit.why}. ${SCRIPT_LAW} ${hit.fix}`,
      "unsupported_edit",
      { term: hit.phrase, category: hit.category },
    );
  }
  // Never weaken tier A/B: a script must clear the original denylist too
  // (neighborhood, school district, race, religion, places of worship …).
  assertFairHousing(raw, what);
}
