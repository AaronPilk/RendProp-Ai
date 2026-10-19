/** The eight "Needs work" reasons, in the owner's order (feedback contract §3.2).
 * The first six are property-fidelity defects, personal_style_preference is
 * taste and other is neither; the report keeps those groups apart. */
export const FEEDBACK_REASONS = ["changed_permanent_features", "moved_or_changed_appliance", "blocked_doorway_or_opening",
  "inconsistent_furniture_between_views", "visible_visual_artifacts", "requested_edit_incomplete", "personal_style_preference", "other"];
/** Labels in the same order as FEEDBACK_REASONS. */
export const REASON_LABELS = ["Changed permanent property features", "Moved or changed an appliance", "Blocked a doorway or opening",
  "Inconsistent furniture between views", "Visible visual artifacts", "Requested edit was incomplete", "Personal style preference", "Other"];
