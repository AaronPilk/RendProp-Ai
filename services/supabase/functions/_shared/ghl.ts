// Legacy GoHighLevel cleanup attribution. Public inquiry capture no longer
// exports buyers into the global CRM location: contact upserts can merge buyers
// from different agencies. These tags remain necessary to safely remove only
// the deleting workspace's legacy records, without deleting another tenant's.
export function ghlOrgTag(orgId: string): string {
  return `rendprop_org:${orgId}`;
}

/** True for any tenant-attribution tag, this org's own or another tenant's. */
export function isGhlOrgTag(tag: string): boolean {
  return tag.startsWith("rendprop_org:");
}
