// Twilight, sky, lawn and free-text photo edits.
//
// Revision of 12 Nov 2026. Each prompt names the one thing to change, in
// concrete visual terms, then says in one short paragraph what stays. The
// earlier prompts ended in a ~200-word block of prohibitions shared by every
// edit, and the twilight prompt itself asked for "subtle landscape/path
// lighting", which is exactly what production reviews then flagged as invented
// path lights, uplights and wall lights (3 of 4 judged twilight edits).
// Prompt policy only; the result is still compared with the original.

export interface PhotoSubject {
  /** "real-estate photo", "restaurant photo" */
  photo: string;
  /** "house", "storefront" */
  exterior: string;
  /** What the lawn edit improves, as the profile already words it. */
  greenery: string;
  /** True for a home listing; other businesses keep their signage wording. */
  housing: boolean;
}

function bounded(subject: PhotoSubject): void {
  for (const value of [subject.photo, subject.exterior, subject.greenery]) {
    if (typeof value !== "string" || !value.trim() || value.length > 300 || /[\u0000-\u001f]/.test(value)) throw new Error("Use a bounded photo subject.");
  }
}

/** One paragraph, stated as what the finished picture shows. */
function staysOutdoors(subject: PhotoSubject): string {
  return "WHAT STAYS. Everything else looks exactly as it does in the photo: the " + subject.exterior +
    "'s shape, roof, walls, paint colors, windows, doors and garage door, trim" + (subject.housing ? "" : ", signs and lettering") +
    ", the driveway, paths, steps, fences and walls, every tree, shrub and planting bed in its place, vehicles, neighboring buildings, poles and wires. " +
    "Keep the same camera position, framing and aspect ratio. Cracks, stains, wear and damage stay visible as photographed, because this photo has to show the property's real condition.";
}

export function buildTwilightPrompt(subject: PhotoSubject): string {
  bounded(subject);
  return "Show this same " + subject.photo + " as it would look at dusk, about twenty minutes after sunset. Change the time of day and nothing else. " +
    "SKY. A clear twilight sky: deep blue overhead, fading to a soft warm orange and pink glow low on the horizon. " +
    "DAYLIGHT. Lower the daylight so the " + subject.exterior + " and its grounds sit in soft, even blue-hour light. Surfaces keep their real colors, only dimmer and slightly cooler, and details stay readable. " +
    "WINDOWS. The windows that are in the photo glow warm yellow-white from inside, as if the lights indoors are on. " +
    "LIGHTS. A light fixture that is already visible in the photo, such as a porch light, a wall lantern or a lamp post, may be switched on with a small warm glow. Light comes only from those windows and those existing fixtures. Lawns, planting beds, paths and the driveway get ambient dusk light and the soft spill from the windows; they have exactly the fixtures they have in the photo. " +
    "If the photo was taken indoors, keep the room as it is, show the dusk sky through its windows and switch on only the lamps and light fixtures that are already in the room. " +
    staysOutdoors(subject);
}

export function buildSkyPrompt(subject: PhotoSubject): string {
  bounded(subject);
  return "Replace the sky in this " + subject.photo + " with a bright, clear blue daytime sky with a few soft white clouds. Change the sky and nothing else. " +
    "The new sky fills exactly the area the old sky fills now, with a clean edge along the roofline, chimneys, trees, poles and wires; fine branches and wires stay whole in front of it. " +
    "Lift the daylight on the scene only slightly so it matches a sunny day, with the sun in the same direction and the existing shadows in the same places. Glass and water that reflect the sky reflect the new one. " +
    "If the sky is visible only through a window, change it only there. " +
    staysOutdoors(subject);
}

export function buildLawnPrompt(subject: PhotoSubject): string {
  bounded(subject);
  return (subject.housing
    ? "Make the lawn in this " + subject.photo + " look healthy and well kept. Change the grass and nothing else. "
    : "Make the greenery in this " + subject.photo + " look healthy and well kept: " + subject.greenery + ". Change the greenery and nothing else. ") +
    "The grass becomes an even, natural medium green, freshly mown, with real blade texture and the same shadows lying across it. Brown, yellow, thin and bare patches inside the existing lawn fill in with matching grass. " +
    "The lawn keeps its exact outline: its edges along the driveway, paths, beds, curbs and fences stay where they are, and soil, mulch, gravel and paving outside the lawn stay as they are. Existing trees, shrubs and flowers stay the same plants in the same places and may only look a little fresher. " +
    "If no grass or planting is visible, return the photo unchanged. " +
    staysOutdoors(subject);
}

/** `request` is the prepared text from analyzeCustomPhotoPrompt (the quoted
 * request plus the fixed-feature sentence). */
export function buildCustomEditPrompt(subject: PhotoSubject, request: string): string {
  bounded(subject);
  if (typeof request !== "string" || !request.trim() || new TextEncoder().encode(request).length > 6000) throw new Error("Use a bounded prepared photo request.");
  return "Edit this " + subject.photo + " of a real " + (subject.housing ? "property that is for sale" : "place that is being marketed") + ". " +
    request.trim() + " " +
    "Make the change look like part of the original photograph: the same light direction and color, matching shadows and reflections, the same perspective and sharpness. " +
    "Everything the request does not mention stays exactly as photographed, including the camera position, framing and aspect ratio, the view through windows, and the surroundings of the property such as neighboring buildings, poles, wires, fences and paving.";
}
