/** Allocated aerial working/review objects have a typed opening workflow. They
 * are never generic photo sources, posters or recorded walkthroughs, including
 * after acceptance. This classifies purpose; existing row/RLS checks own access. */
const UUID = "[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}";
const ID = new RegExp(`^${UUID}$(?![\\s\\S])`);
export type PropertyMediaScope = { orgId: string; listingId: string };
export function internalAerialMediaPatterns(scope: PropertyMediaScope): string[] {
  if (!ID.test(scope.orgId) || !ID.test(scope.listingId)) throw new Error("Invalid property media scope.");
  const root = `renders/${scope.orgId}/${scope.listingId}/`;
  return ["aerial-input", "aerial-provider", "aerial-opening", "aerial-review"].map(tree => `${root}${tree}/%`);
}
export function isInternalAerialMedia(key: unknown, scope: PropertyMediaScope): boolean {
  if (typeof key !== "string" || !ID.test(scope.orgId) || !ID.test(scope.listingId)) return false;
  const root = `renders/${scope.orgId}/${scope.listingId}/`;
  return new RegExp(`^${root}(?:aerial-input/${UUID}\\.jpg|aerial-provider/${UUID}\\.mp4|aerial-opening/${UUID}\\.(?:mp4|jpg)|aerial-review/${UUID}/frame-(?:0|60|119|120)\\.jpg)$(?![\\s\\S])`).test(key);
}
