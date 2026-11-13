// What a customer is told when a photo edit ends without a usable picture.
// Words only: every sentence about charging restates what ai-photo/index.ts
// has ALREADY done by the time the failure phase was recorded.
//
//   provider_cost_incurred === false   nothing was sent to the AI service, and
//                                      the edit charge was handed back
//                                      (refundEditCharge) before the throw.
//   phase "generation"                 the AI service returned no picture and
//                                      the edit charge was handed back.
//   phase "photo_provider_wire_size"   the charge is KEPT (retain_feature_charge).
//   every later phase                  the picture was produced, so the edit was
//                                      counted (finishEditCredit "settled") and
//                                      is never handed back.

/** A finished edit that can never be used (422 photo_quality_closed). */
export function closedPhotoEditCopy(phase: unknown, providerCost: unknown): string {
  if (providerCost === false) return "This edit was not started, so you were not charged. Your original photo is unchanged. Try again.";
  if (phase === "generation") return "The AI service did not send back a picture for this photo. You were not charged, and your original photo is unchanged. Try again; if it keeps failing, use a different photo.";
  if (phase === "photo_provider_wire_size" || phase === "photo_output_size") return "The edited picture came back too large for us to save, so there is nothing to show. This attempt used one edit. Your original photo is unchanged. Try again with a smaller copy of the photo.";
  if (phase === "photo_output_validation" || phase === "photo_output_geometry") return "The AI service sent back a picture we could not use (wrong size or damaged), so there is nothing to show. This attempt used one edit. Your original photo is unchanged. Try the edit again.";
  if (phase === "evidence_persistence") return "The edit was made but we could not save it, so there is nothing to show. This attempt used one edit. Your original photo is unchanged. Try the edit again.";
  return "We could not finish checking this edit, so it stays private and cannot be used. This attempt used one edit. Your original photo is unchanged. Start the edit again.";
}

/** An edit the check turned down (422 photo_quality_refused). */
export const REFUSED_PHOTO_EDIT_COPY = "This edit changed parts of the property that must stay the same, such as walls, windows or floors, so it was not added to your listing. This attempt used one edit. Your original photo is unchanged. Try again with a simpler instruction.";

/** An edit waiting on us (409 photo_quality_hold). Nothing new is started. */
export function heldPhotoEditCopy(phase: unknown): string {
  if (phase === "photo_output_size" || phase === "photo_provider_wire_size") return "The edited picture came back too large and could not be saved. We are looking at it. No second edit was started and there is no new charge. Check this edit again in a few minutes.";
  return "This edit is on hold while we look at a problem with the result. No second edit was started and there is no new charge. Check this edit again in a few minutes.";
}

/** An edit that is made and still being checked (409 photo_quality_pending). */
export const PENDING_PHOTO_EDIT_COPY = "Your edit is made and saved, and we are still checking it. Check this edit again in a moment. You do not need to start a new one, and there is no new charge.";
