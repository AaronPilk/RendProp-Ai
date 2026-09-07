// GoHighLevel (GHL) CRM constants shared by every function that touches it.
//
// Every tenant is pushed into the SAME GHL_LOCATION_ID (leads/index.ts) — there
// is one shared CRM location for the whole product, not one per org — so a
// contact is attributed to a tenant ONLY by a tag, never by which location it
// lives in. `rendprop_org:<org_id>` is that tag. It must be built the exact
// same way everywhere it is read or written, or a reader silently stops
// recognizing what a writer just wrote — which is exactly how account deletion
// deleted a DIFFERENT tenant's contact that happened to share a lead's email
// (external release audit). Import this from both sides instead of retyping
// the prefix.
export function ghlOrgTag(orgId: string): string {
  return `rendprop_org:${orgId}`;
}

/** True for any tenant-attribution tag, this org's own or another tenant's. */
export function isGhlOrgTag(tag: string): boolean {
  return tag.startsWith("rendprop_org:");
}
