export type Appearance = "system" | "light" | "dark";

export const APPEARANCE_STORAGE_KEY = "rendprop.studio.appearance.v1";

export function parseAppearance(value: unknown): Appearance {
  return value === "light" || value === "dark" ? value : "system";
}

export function readAppearance(): Appearance {
  try {
    return parseAppearance(window.localStorage.getItem(APPEARANCE_STORAGE_KEY));
  } catch {
    return "system";
  }
}

export function applyAppearance(appearance: Appearance): void {
  // System is resolved by CSS so the very first paint follows the device.
  document.documentElement.dataset.appearance = appearance;
}

export function saveAppearance(appearance: Appearance): void {
  applyAppearance(appearance);
  try {
    window.localStorage.setItem(APPEARANCE_STORAGE_KEY, appearance);
  } catch {
    // Appearance still works for this visit if storage is unavailable.
  }
}

// Runs before React paints, including when the saved setting differs from the OS.
if (typeof window !== "undefined" && typeof document !== "undefined") {
  applyAppearance(readAppearance());
}
