/** New choice UI; legacy Scandinavian remains a distinct accepted historical
 * value so old saved results/requests are never relabelled Contemporary. */
export const STAGING_STYLE_CHOICES = ["modern", "rustic", "minimalist", "contemporary"] as const;
export const ACCEPTED_STAGING_STYLES: readonly string[] = [...STAGING_STYLE_CHOICES, "scandinavian"];
