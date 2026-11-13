// Surgical removal from the supplied photograph; never a furnishing/design
// brief. Prompt policy is not visual proof: retained outputs still require QC.
// https://ai.google.dev/gemini-api/docs/image-generation#image_editing
export function buildRealEstateDeclutterPrompt(propertyLock:string,reflectionClause:string):string {
 if(typeof propertyLock!=="string"||!propertyLock.trim()||typeof reflectionClause!=="string"||!reflectionClause.trim()
  ||new TextEncoder().encode(propertyLock+reflectionClause).byteLength>6000)throw Error("Use the bounded existing property and reflection preservation rules.");
 return "Retouch this supplied real-estate photograph with a REMOVE-ONLY cleanup. The source photograph is the authority; make the smallest local changes needed. " +
  "Remove only clearly identifiable loose clutter such as discarded packaging, laundry, loose papers, stray cords and dishes on surfaces. If an object's purpose or whether it is clutter is uncertain, leave it unchanged. Keep existing furniture and intentional decor in their original positions, shapes, designs, materials and colors. Decluttering is not virtual staging. " +
  "DO NOT ADD ANY OBJECT: no new mirror, shelf, lamp, light, plant, furniture, decor, appliance or installation. Never replace, restyle or relocate existing furniture or decor. Preserve every wall-mounted, ceiling-mounted and built-in item and its exact outline, position and material. " +
  "Fill only the small image areas directly occupied by a removed loose object, continuing adjacent already-visible surface texture and the same light. Do not repaint, resurface, repair defects, redesign the room, invent hidden structure, or reveal a newly imagined view. If safe local continuation is uncertain, leave the original object and area unchanged. " +
  "Keep the full source framing, aspect ratio, camera position, perspective, room geometry, daylight direction and exposure. No crop, zoom, wider view, room restyling or global reconstruction. Existing glossy surfaces may lose only reflections of the removed loose item or person; retain their actual geometry and material. " +
  reflectionClause + propertyLock + " Return this same photograph with only the permitted local removals; everything else stays unchanged.";
}
