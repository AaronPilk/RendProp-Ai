import { HttpError } from "../_shared/http.ts";

// Topaz is FAL-only in this release and the FAL account is unfunded. Keep new
// requests off until an independently funded provider is explicitly enabled.
// Existing signed jobs retain their status and recovery paths.
export const TOPAZ_GENERATION_AVAILABLE = false;

export function assertTopazSupplierReady(): void {
  if (!TOPAZ_GENERATION_AVAILABLE) {
    throw new HttpError(
      503,
      "AI video enhancement is temporarily unavailable. Smooth rendering on your phone is still ready.",
      "upstream",
    );
  }
}
