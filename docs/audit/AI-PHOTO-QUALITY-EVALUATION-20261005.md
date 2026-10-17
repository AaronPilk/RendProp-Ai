# AI photo quality evaluation

The October beta reports show real generation defects: furniture intersecting walls or doors, moved appliances, invented windows, inconsistent furnishings between views, and an apparent artifact. The current changes strengthen prompts, add a shared furnishing brief and require explicit staged-output review. These are safeguards, not evidence that the defects have been fixed. No paid generation or customer-image evaluation was performed for this change.

Same-room image references are **Coming soon**. The API rejects them before quota consumption or provider dispatch. The existing Gemini route price accounts for one output image; it does not model additional input tokens. The bounded, target-first adapter request is tested offline but remains behind this cost fence. Google documents separate input and output charges in its [Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing#gemini-3.1-flash-image) and supports multiple images in [image generation requests](https://ai.google.dev/gemini-api/docs/image-generation). Neither capability establishes output fidelity.

## Inputs and reproducibility

Before any paid evaluation, the owner must approve a conservative preflight cost model, the total evaluation budget and consented test images. Verify the active route, retirement/privacy eligibility, model identifier and 1K output setting; do not silently enable another provider or change global flags. Record actual input/output usage and reconcile it against the approved cost estimate.

Create a held-out corpus of ten rooms, with three overlapping views per room. Include at least three kitchens, three bedrooms, two small rooms with door swings and two reflective or irregular rooms. Use consenting owners or synthetic training fixtures. Include visible windows, fixed appliances, built-ins, damage and narrow access routes. Keep identifiers pseudonymous. Do not include beta screenshots, customer photos, addresses or private receipts in this document or public test artifacts.

Annotate each source view before generation: visible door/window boundaries, appliance/built-in positions, defects that must remain, door swings and accessible walking routes. Record camera framing and which furniture is visible across views. Mark obscured features as unobservable; they cannot earn a passing score. Keep originals unchanged and hash all input bytes, annotations, prompts, route settings and model responses.

Run the existing no-reference staging workflow first, using the same furnishing brief across the three views. If references later receive cost approval, stage the first view, review it against its source, and supply it only as a movable-furnishing reference for the other two views. The target remains authoritative for architecture, appliances and camera framing. Run three independent repetitions per room without selecting the best result. Evaluate decluttering separately on ten annotated sources, including appliance clutter, reflections and property defects. Retain failed outputs and charged attempts in the denominator.

## Proposed acceptance gates

Two reviewers compare source and output without seeing which prompt variant produced it. They score independently; disagreements require adjudication and remain unresolved until reviewed. Automated overlap or landmark measurements assist this review but cannot certify hidden geometry or physical accessibility.

| Check | Proposed gate |
| --- | --- |
| Visible door and window count | No additions, removals or substituted openings in any output |
| Fixed-feature position and shape | No moved appliances, built-ins or walls; normalized annotated boundary displacement no more than 2% of source diagonal, with reviewer confirmation |
| Property condition | No removed, repaired or concealed annotated defect or permanent feature |
| Furniture intersections and access | No furniture entering a visible wall, blocking an opening, door swing or annotated walking route |
| Room and camera identity | Same photographed room and view in every output; no invented wider field of view |
| Furnishings across views | At least 95% of jointly visible furniture identities, materials and relative positions agree; all original reported consistency cases pass |
| Image artifacts | No visible unexplained object or material artifact in any reported case; at least 95% of held-out outputs acceptable to both reviewers |
| Recovery and preservation | Failed or rejected generations preserve original bytes, separate Decluttered/Staged histories and prior selected publication versions |

A single critical architecture, appliance, condition or access failure blocks acceptance even when the aggregate score is high. Every original beta quality case needs a reviewed pass before that feedback is marked resolved. Do not describe an unobservable feature as preserved or equate a review checkbox with certified correctness. These thresholds are proposed product acceptance criteria, not statistical or architectural certification.

## Results to retain

Save a sanitized manifest containing source/output hashes, prompt hashes, exact route/model, input and output usage, costs, each attempt's status, per-feature scores, reviewer decisions and unresolved discrepancies. Store consented media privately. Publish only aggregate counts and the precise limitations in the release report. Record a zero-attempt result as **not evaluated**, not passed.

JPEG export can apply manual rotation and crop to a copy while leaving source bytes unchanged. It cannot correct perspective automatically, widen a room view or recover unseen parts of the room. Physical capture quality and actual phone Files/Photos delivery still require controlled device acceptance. No claim of resolved generation quality is justified until the output evaluation above has been run and reviewed.
