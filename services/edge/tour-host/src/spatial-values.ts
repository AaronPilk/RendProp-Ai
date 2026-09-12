/** Shared by server and browser validation. Keep this independent of either
 * runtime so the same finite bounds apply before a scene can allocate memory. */
export function isBoundedSpatialNumber(value: unknown, low: number, high: number): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= low && value <= high;
}
