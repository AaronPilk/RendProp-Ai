// ai-chapters — the room vocabulary and the prompt built from it.
//
// PURE (imports only the frozen fairhousing constants), so a test can read the
// exact words we send.
//
// The vocabulary is not invented here: it MIRRORS `SpaceType.quickTags` in
// apps/ios/Rendprop/Models/Listing.swift, which is the list the agent already
// taps in the room tagger. A suggestion the tagger can't show as one of its own
// chips is a suggestion the agent has to retype, so the model is given the app's
// words, not the model's words.
//
// FAIR HOUSING. Room chapters are the one AI feature that WATCHES the agent's
// own footage of an occupied house — there will be family photos on the walls, a
// crucifix over a bed, a child's room, a wheelchair ramp. A description that
// mentions any of it is a fair-housing violation printed under the listing. So
// the system rule is a hard describe-the-property-only instruction on top of
// _shared/fairhousing.ts GUARDRAILS, and (belt and braces, because a system rule
// is a request, not a guarantee) every returned description is re-checked with
// assertMarketingCopy() in postprocess.ts before the app ever sees it.

import { GUARDRAILS } from "../_shared/fairhousing.ts";

/** The space types the app knows (mirrors SpaceType in Models/Listing.swift). */
export const SPACE_TYPES = ["real_estate", "venue", "restaurant", "retail", "fitness", "other"] as const;
export type SpaceType = typeof SPACE_TYPES[number];

/** Coerce a listing's stored space_type into a known one. */
export function spaceTypeOf(raw: string | null | undefined): SpaceType {
  const s = String(raw ?? "").trim().toLowerCase();
  return (SPACE_TYPES as readonly string[]).includes(s) ? (s as SpaceType) : "real_estate";
}

/**
 * MIRROR of SpaceType.quickTags. Keep in lockstep with Models/Listing.swift —
 * these two lists drifting apart is what turns a pre-filled chip into a typo.
 */
const QUICK_TAGS: Record<SpaceType, string[]> = {
  real_estate: ["Exterior", "Entry", "Living Room", "Kitchen", "Dining", "Primary", "Bedroom", "Bath", "Office", "Garage", "Backyard"],
  venue: ["Entrance", "Main Hall", "Stage", "Bar", "Lounge", "Patio", "Garden", "Kitchen", "Restrooms", "Green Room"],
  restaurant: ["Entrance", "Dining", "Bar", "Patio", "Private Room", "Kitchen", "Restrooms"],
  retail: ["Entrance", "Front", "Aisles", "Produce", "Deli", "Checkout", "Backroom"],
  fitness: ["Entrance", "Reception", "Main Floor", "Weights", "Studio", "Cardio", "Locker Room", "Showers"],
  other: ["Entrance", "Main Area", "Front", "Back", "Outside", "Restrooms"],
};

/** The allowed label set for a listing: its quick tags, plus the escape hatch. */
export function allowedLabels(space: SpaceType): string[] {
  return [...QUICK_TAGS[space], "Other"];
}

/** What the agent calls one of these places, for prompt copy that reads right. */
const SPACE_NOUN: Record<SpaceType, string> = {
  real_estate: "home",
  venue: "venue",
  restaurant: "restaurant",
  retail: "store",
  fitness: "gym",
  other: "space",
};

/**
 * The SYSTEM rule. `GUARDRAILS` is included verbatim (the same sentence every
 * other AI route in this repo sends) and then narrowed for a describe-only task:
 * the generation routes are told not to ADD people; this one has to be told not
 * to MENTION them, because the people are really there in the footage.
 */
export function systemInstruction(): string {
  return [
    "You are a real-estate media assistant. You watch a walkthrough video of a property and " +
      "identify the rooms and areas, so an agent can label the tour's chapters.",
    // GUARDRAILS is written for GENERATION prompts ("do not add…", "do not
    // change…"), and it is sent here verbatim because one sentence, everywhere,
    // is the whole point of a compliance lock. This line reframes it for a
    // describe-only task so the model does not read it as an editing brief.
    "You never edit or alter the video — you only watch it and describe what is there. " +
      "These rules bind everything you write:",
    GUARDRAILS,
    "You describe ONLY the property: the room, its layout, its finishes, its materials, its " +
      "light, its fixtures, its condition.",
    "NEVER mention, describe, count or allude to: any person or their appearance; children or " +
      "toys or a child's room as a child's room; pets; religious or cultural objects, art, " +
      "symbols or texts; flags or political items; family photographs or the people in them; " +
      "medical or mobility equipment; the neighborhood, the street, the area, schools, safety, " +
      "commute, or who the property would suit.",
    "Never say who would like the property or who lives there. Describe the space, never the occupant.",
    "If a room's only distinguishing feature is something you must not mention, describe the " +
      "room's size, light and finishes instead, or leave the description empty.",
    "Report timestamps as SECONDS from the start of the video, as numbers.",
  ].join(" ");
}

export interface PromptArgs {
  space: SpaceType;
  labels: string[];
  videoSeconds: number;
  maxChapters: number;
  /** BCP-47-ish tag; only used to say which language to write in. */
  language: string;
}

/** The USER turn: the task, the vocabulary, and the rules the post-processor enforces anyway. */
export function chaptersPrompt(args: PromptArgs): string {
  const noun = SPACE_NOUN[args.space];
  const duration = Math.round(args.videoSeconds);
  return [
    `This is a continuous walkthrough of one ${noun}, ${duration} seconds long.`,
    "",
    "Watch it and split it into CHAPTERS — one per distinct room or area the camera enters, in " +
      "the order they are entered.",
    "",
    "For each chapter give:",
    `  • label       — the room or area, chosen from this list: ${args.labels.join(", ")}.`,
    `                  Use "Other" if none of them fits. Use the list's exact spelling.`,
    "  • start_s     — seconds from the start of the video when the camera ENTERS that room.",
    "  • end_s       — seconds when the camera leaves it (the next chapter's start_s).",
    "  • confidence  — 0 to 1, how sure you are of the label.",
    "  • description — ONE sentence about the space itself: its finishes, light and layout. " +
      "Leave it out if you cannot write one without mentioning people, pets, religious or " +
      "cultural objects, or the neighborhood.",
    "",
    "Rules:",
    `  • At most ${args.maxChapters} chapters. Merge anything shorter than 3 seconds into the room around it.`,
    "  • A hallway or a staircase between two rooms is not a chapter — it belongs to the room " +
      "the camera is heading into.",
    "  • If the camera returns to a room it already visited, only add a second chapter when it " +
      "stays there; a glance through a doorway is not a visit.",
    `  • start_s must be between 0 and ${duration}. Never guess past the end of the video.`,
    "  • The first chapter starts at 0.",
    "",
    `Write the labels and descriptions in ${args.language}.`,
    "Return JSON matching the schema. No prose outside the JSON.",
  ].join("\n");
}
