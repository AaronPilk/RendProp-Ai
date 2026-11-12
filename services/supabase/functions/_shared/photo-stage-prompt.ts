// Virtual staging of one listing photograph.
//
// Revision of 12 Nov 2026. The earlier prompt was three numbered blocks of
// "preserve / never / do not" lists with one quoted style sentence in the
// middle. Production reviews of its output found the model's usual mistakes
// untouched by all of that: shelving added to a pillar, the floor tone
// shifted, a console swapped for a plant. Image models follow a short, concrete
// description of what to make far better than a long stack of prohibitions, so
// this version says, in order: what the job is, how to read the room, what to
// put in each kind of room, how an empty room differs from a furnished one,
// where pieces go and how big they are, how to light them, and then one short
// paragraph on what stays. It is prompt policy, not verified geometry.

/** Look, palette and materials per style. The pieces themselves come from the
 * room list in the prompt, so every style can furnish every kind of room.
 * Nothing here may ask for something attached to a wall or ceiling. */
export const REAL_ESTATE_STAGE_STYLES: Record<string, string> = {
  modern:
    "Modern: clean straight lines and low profiles. Colors: warm white, soft grey and charcoal with one muted accent such as rust or olive. " +
    "Materials: light oak, matte black metal, glass and textured woven fabric. Seating and bed frames are upholstered in light grey; tables are oak or black metal in simple shapes.",
  rustic:
    "Rustic farmhouse: sturdy, comfortable, slightly weathered pieces. Colors: cream, warm beige, soft brown and sage green. " +
    "Materials: knotty or reclaimed wood, linen, wool, wrought iron and woven baskets. Seating is cream linen with a knit throw; tables are chunky wood; the rug is jute or braided.",
  minimalist:
    "Minimalist: only the essential pieces, with open floor left around them. Colors: white, pale grey and light natural wood, almost no pattern. " +
    "Materials: pale ash or birch, matte white surfaces, plain cotton and wool. One low simple sofa or bed, one small table, one plain rug and at most two decor objects.",
  contemporary:
    "Contemporary: soft curved shapes and layered textures. Colors: ivory, taupe and greige with one deep accent such as navy or forest green. " +
    "Materials: boucle and linen upholstery, walnut, brushed brass and stone-look tabletops. A curved sofa or rounded armchairs, a round or oval coffee table and a thick textured rug.",
  scandinavian:
    "Scandinavian: light, simple and cozy. Colors: white, pale grey and soft pastels. " +
    "Materials: light birch or ash, wool, cotton and sheepskin. Slim wooden legs on seating and tables, a wool throw and a light woven rug.",
};

export function buildRealEstateStagePrompt(styleDescription: string): string {
  if (typeof styleDescription !== "string" || !styleDescription.trim() || new TextEncoder().encode(styleDescription).length > 1200 || /[\u0000-\u001f]/.test(styleDescription)) {
    throw new Error("Use a bounded furniture style description.");
  }
  return "This is a real photograph of a home for sale. Virtually stage it: furnish it so a buyer can picture living here, and return this same photograph with only the furnishings changed. " +
    "STEP 1, READ THE ROOM. Work out from the photo which kind of space this is and how much open floor it has. " +
    "STEP 2, CHOOSE THE PIECES for that space. " +
    "Living or family room: a sofa (a sectional if the room is large), one or two armchairs, a coffee table, an area rug, a side table, a floor lamp and one potted plant. " +
    "Bedroom: a bed with a headboard, full bedding and pillows, two nightstands with table lamps, an area rug, and a bench or chair if there is space. " +
    "Dining area: a dining table with four to six chairs, a simple centerpiece and a rug under the table. " +
    "Kitchen: stools at an island or peninsula that is already there, plus a fruit bowl, a cutting board and a small plant on the existing counters. " +
    "Bathroom: folded towels, a bath mat, a small plant and a tray with soap on the existing vanity. " +
    "Office or spare room: a desk, a chair, a desk lamp, a rug and a plant. " +
    "Entry, hallway or landing: a narrow console table or a bench, a runner rug and a plant. " +
    "Patio, deck, balcony or yard: outdoor seating with a low table, an outdoor rug and planters. " +
    "A front or street view with no sitting area: two or three potted plants beside the entrance and nothing else. " +
    "In a small space use fewer and smaller pieces. " +
    "STEP 3, STYLE. Make every piece in this style (quoted style data): " + JSON.stringify(styleDescription.trim()) + ". " +
    "STEP 4, EMPTY OR FURNISHED. If the space is empty or nearly empty, furnish the open floor. If it already has furniture, replace the existing movable furniture and loose decor with the new set in about the same positions. Anything attached to the building stays as it is. " +
    "PLACEMENT AND SIZE. Every piece stands on the existing floor at true-to-life size, judged against the doors, windows and ceiling height in the photo. Put large pieces along walls or grouped on the rug and leave doorways, stairs and walking paths open. Decor is freestanding: it stands on the floor or sits on the furniture you add. The floor stays visible around the rug. " +
    "LIGHT. Light the new pieces with the light already in the photo: the same direction, color and brightness, with soft contact shadows on the floor and faint reflections on glossy floors. " +
    "WHAT STAYS. Everything that is part of the property looks exactly as it does in the photo: walls and their paint color, the ceiling, the floor material and its color tone, every window and the view through it, doors, trim, stairs and railings, cabinets, counters, appliances, sinks, the fireplace, built-ins, ceiling fans, and every existing light fixture, shelf, mirror, picture, switch and vent. Walls and ceiling carry exactly what they carry now and nothing more. Keep the same camera position, framing, lens and aspect ratio, and the same overall exposure and white balance. Marks, stains, cracks, wear and damage stay visible as photographed. " +
    "If you cannot tell whether something is furniture or part of the building, leave it. " +
    "FINAL CHECK before you answer: the same number of windows and doors in the same places; the same floor; the same walls, ceiling and light fixtures; furniture and decor are the only difference.";
}
